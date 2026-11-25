package `in`.abhijithvijayan.opendash

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.media.MediaMetadata
import android.media.browse.MediaBrowser
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.os.Parcelable
import android.service.media.MediaBrowserService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// The phone's music and calls, as the head unit's own Bluetooth stack sees
/// them. The head unit is the sink: A2DP sink + AVRCP controller for music,
/// HFP client for calls.
///
/// Stock HHMIC gets both from HSSS, which is a system app:
/// `MediaSessionManager.getActiveSessions` for the Bluetooth app's media
/// session, and `BluetoothHeadsetClient` for calls. Neither is open to us
/// that way (active sessions need MEDIA_CONTENT_CONTROL or notification
/// access), so:
///  - music: a `MediaBrowser` on the Bluetooth app's own browser service,
///    which hands any client the token of that same session;
///  - calls: the `AG_CALL_CHANGED` broadcast (guarded by BLUETOOTH, which
///    we hold) and the HFP-client profile proxy for answer / hang up. Both
///    carry hidden-API types, read by reflection; every miss is logged so
///    the next log pull says what this firmware allows.
///
/// Events on [EVENTS], all main thread: `_volumeMax` (STREAM_MUSIC steps),
/// `_media` (`{connected, playing, title, artist, durationMs, positionMs}`)
/// and `_call` (`{state, number, outgoing, inBand, id}`, state being the
/// `BluetoothHeadsetClientCall` state: 0 active, 1 held, 2 dialing,
/// 3 alerting, 4 incoming, 5 waiting, 7 terminated; id -1 = HFP link lost).
///
/// [onWitness] tells `SystemStatus` what this bridge can prove about a phone
/// being connected: `media` while the session is playing, `hfp` while the
/// HFP client has a device.
class MediaBridge(
    private val context: Context,
    messenger: BinaryMessenger,
    private val onWitness: (String, Boolean) -> Unit,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val AUDIO_LOGS = 40
        const val EVENTS = "in.abhijithvijayan.opendash.media/events"
        const val COMMANDS = "in.abhijithvijayan.opendash.media/commands"
        private const val BLUETOOTH_PACKAGE = "com.android.bluetooth"
        private val PROJECTION_PACKAGES = setOf("com.shihab.diplay", "com.andrerinas.headunitrevived")
        private const val HEADSET_CLIENT = 16
        private const val ACTION_AG_CALL_CHANGED = "android.bluetooth.headsetclient.profile.action.AG_CALL_CHANGED"
        private const val ACTION_HFP_CONNECTION = "android.bluetooth.headsetclient.profile.action.CONNECTION_STATE_CHANGED"
        private const val ACTION_HFP_AUDIO = "android.bluetooth.headsetclient.profile.action.AUDIO_STATE_CHANGED"
        private const val ACTION_A2DP_SINK_PLAYING = "android.bluetooth.a2dp-sink.profile.action.PLAYING_STATE_CHANGED"
        private const val A2DP_SINK_PLAYING = 10
        private const val EXTRA_CALL = "android.bluetooth.headsetclient.extra.CALL"
        private const val CALL_TERMINATED = 7
        private const val RETRY_MS = 30_000L
        private const val MAX_RETRIES = 5
        private val CALL_STATES = listOf(
            "ACTIVE", "HELD", "DIALING", "ALERTING", "INCOMING", "WAITING", "HELD_BY_RESPONSE_AND_HOLD", "TERMINATED",
        )
    }

    private val main = Handler(Looper.getMainLooper())
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var events: EventChannel.EventSink? = null
    private var browser: MediaBrowser? = null
    private var controller: MediaController? = null
    private var retries = 0
    private var lastMedia: Map<String, Any?>? = null
    private var lastCall: Map<String, Any?>? = null
    private var lastCallObject: Parcelable? = null
    private var hfp: BluetoothProfile? = null
    private var started = false

    /// Music playing through a phone-projection app (CarPlay, Android Auto).
    /// Those apps publish it as their own media session, which Android only
    /// lists for an app with notification access ([ProjectionMediaListener],
    /// granted once by the rider). Shown while it is playing; the Bluetooth
    /// session is the source otherwise.
    private val sessions = context.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
    private val listener = ComponentName(context, ProjectionMediaListener::class.java)
    private var projection: MediaController? = null
    private var watching = false
    private val sessionsChanged = MediaSessionManager.OnActiveSessionsChangedListener { pickProjection(it.orEmpty()) }
    private val projectionCallback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) = publishMedia()
        override fun onPlaybackStateChanged(state: PlaybackState?) = publishMedia()
    }

    private fun watchProjection() {
        if (watching) return
        try {
            sessions.addOnActiveSessionsChangedListener(sessionsChanged, listener, main)
            watching = true
            Analytics.log("media", "projection", mapOf("access" to true))
            pickProjection(sessions.getActiveSessions(listener))
        } catch (_: SecurityException) {
            Analytics.log("media", "projection", mapOf("access" to false))
        }
    }

    private fun pickProjection(active: List<MediaController>) {
        val next = active.firstOrNull { it.packageName in PROJECTION_PACKAGES }
        if (next?.sessionToken == projection?.sessionToken) return
        try {
            projection?.unregisterCallback(projectionCallback)
        } catch (_: Exception) {
        }
        projection = next
        next?.registerCallback(projectionCallback, main)
        Analytics.log("media", "projection", mapOf("session" to next?.packageName))
        publishMedia()
    }

    private val retry = Runnable { connectBrowser() }

    private val connection = object : MediaBrowser.ConnectionCallback() {
        override fun onConnected() {
            val b = browser ?: return
            retries = 0
            try {
                val c = MediaController(context, b.sessionToken)
                c.registerCallback(controllerCallback, main)
                controller = c
                Analytics.log("media", "browser", mapOf("state" to "connected", "session" to c.packageName))
                publishMedia()
            } catch (e: Exception) {
                Analytics.log("media", "browser", mapOf("state" to "controller_failed", "error" to e.toString()))
            }
        }

        override fun onConnectionSuspended() {
            Analytics.log("media", "browser", mapOf("state" to "suspended"))
            dropController()
        }

        override fun onConnectionFailed() {
            Analytics.log("media", "browser", mapOf("state" to "failed", "attempt" to retries))
            dropController()
            browser = null
            scheduleRetry()
        }
    }

    private val controllerCallback = object : MediaController.Callback() {
        override fun onMetadataChanged(metadata: MediaMetadata?) = publishMedia()
        override fun onPlaybackStateChanged(state: PlaybackState?) = publishMedia()
        override fun onSessionDestroyed() {
            Analytics.log("media", "browser", mapOf("state" to "session_destroyed"))
            dropController()
            disconnectBrowser()
            scheduleRetry()
        }
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                ACTION_AG_CALL_CHANGED -> onCallChanged(intent.getParcelableExtra(EXTRA_CALL))
                // On a ride no call event arrived: the HFP client was
                // disconnected 0.7 s after it came up (HSSS does that while
                // calls are not enabled for the phone, `enablePhoneCalls` in
                // BTPairingManagerRepo.smali) and our log could not say so.
                ACTION_HFP_CONNECTION -> {
                    val state = intent.getIntExtra(BluetoothProfile.EXTRA_STATE, -1)
                    logHfp("connection", intent)
                    onWitness("hfp", state == BluetoothProfile.STATE_CONNECTED)
                    if (state == BluetoothProfile.STATE_DISCONNECTED) {
                        lastCallObject = null
                        publishCall(mapOf("state" to CALL_TERMINATED, "number" to "", "outgoing" to false, "inBand" to false, "id" to -1))
                    }
                }
                ACTION_HFP_AUDIO -> logHfp("audio", intent)
                // Navigation prompts and app audio stream over A2DP without
                // touching the AVRCP play state; this is all that marks them.
                ACTION_A2DP_SINK_PLAYING -> Analytics.log("media", "a2dp_stream", mapOf(
                    "playing" to (intent.getIntExtra(BluetoothProfile.EXTRA_STATE, -1) == A2DP_SINK_PLAYING),
                ))
                // The phone went: what its session last said is not live.
                BluetoothDevice.ACTION_ACL_DISCONNECTED -> main.postDelayed({ publishMedia() }, 500)
                // The browser service only exists while the stack is up, and
                // a phone connecting is the moment a session appears.
                else -> if (controller == null) {
                    retries = 0
                    main.removeCallbacks(retry)
                    main.postDelayed(retry, 1000)
                }
            }
        }
    }

    private val hfpListener = object : BluetoothProfile.ServiceListener {
        override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
            hfp = proxy
            val devices = hfpDevices()
            Analytics.log("call", "hfp_proxy", mapOf("connected" to true, "devices" to devices))
            onWitness("hfp", devices > 0)
        }

        override fun onServiceDisconnected(profile: Int) {
            hfp = null
            Analytics.log("call", "hfp_proxy", mapOf("connected" to false))
            onWitness("hfp", false)
        }
    }

    /// Phones the HFP client is connected to; -1 when the proxy is missing
    /// or refuses.
    private fun hfpDevices(): Int = try {
        hfp?.connectedDevices?.size ?: -1
    } catch (_: Exception) {
        -1
    }

    private fun logHfp(kind: String, intent: Intent) {
        Analytics.log("call", "hfp_state", mapOf(
            "kind" to kind,
            "state" to intent.getIntExtra(BluetoothProfile.EXTRA_STATE, -1),
            "prev" to intent.getIntExtra(BluetoothProfile.EXTRA_PREVIOUS_STATE, -1),
        ))
    }

    /// Main thread, on activity resume: the HFP link may have come or gone
    /// with no broadcast reaching us.
    fun refresh() {
        if (hfp != null) onWitness("hfp", hfpDevices() > 0)
        // The rider may have just granted notification access.
        if (started) watchProjection()
        if (controller == null && started) {
            retries = 0
            main.removeCallbacks(retry)
            main.post(retry)
        }
    }

    init {
        EventChannel(messenger, EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                events = sink
                val initial = HashMap<String, Any?>()
                initial["_volumeMax"] = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                lastMedia?.let { initial["_media"] = it }
                // A finished call must not replay; a live one must, or a
                // restarted engine would miss a call that is still up.
                lastCall?.takeIf { it["state"] != CALL_TERMINATED }?.let { initial["_call"] = it }
                sink.success(initial)
            }

            override fun onCancel(arguments: Any?) {
                events = null
            }
        })
        MethodChannel(messenger, COMMANDS).setMethodCallHandler(this)
        start()
    }

    private fun start() {
        if (started) return
        started = true
        context.registerReceiver(receiver, IntentFilter().apply {
            addAction(ACTION_AG_CALL_CHANGED)
            addAction(ACTION_HFP_CONNECTION)
            addAction(ACTION_HFP_AUDIO)
            addAction(ACTION_A2DP_SINK_PLAYING)
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        })
        try {
            val ok = BluetoothAdapter.getDefaultAdapter()?.getProfileProxy(context, hfpListener, HEADSET_CLIENT)
            if (ok != true) Analytics.log("call", "hfp_proxy", mapOf("connected" to false, "error" to "getProfileProxy=$ok"))
        } catch (e: Exception) {
            Analytics.log("call", "hfp_proxy", mapOf("connected" to false, "error" to e.toString()))
        }
        connectBrowser()
        watchProjection()
    }

    fun dispose() {
        main.removeCallbacks(retry)
        if (watching) {
            watching = false
            sessions.removeOnActiveSessionsChangedListener(sessionsChanged)
        }
        try {
            projection?.unregisterCallback(projectionCallback)
        } catch (_: Exception) {
        }
        projection = null
        if (started) {
            started = false
            try {
                context.unregisterReceiver(receiver)
            } catch (_: IllegalArgumentException) {
            }
        }
        dropController(publish = false)
        disconnectBrowser()
        hfp?.let {
            try {
                BluetoothAdapter.getDefaultAdapter()?.closeProfileProxy(HEADSET_CLIENT, it)
            } catch (_: Exception) {
            }
        }
        hfp = null
        events = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "callAction" -> result.success(callAction(call.arguments as String))
            else -> result.notImplemented()
        }
    }

    private fun connectBrowser() {
        if (browser != null) return
        try {
            val service = context.packageManager
                .queryIntentServices(Intent(MediaBrowserService.SERVICE_INTERFACE), 0)
                .firstOrNull { it.serviceInfo?.packageName == BLUETOOTH_PACKAGE }
                ?.serviceInfo
            if (service == null) {
                Analytics.log("media", "source", mapOf("found" to false))
                scheduleRetry()
                return
            }
            Analytics.log("media", "source", mapOf("found" to true, "service" to service.name, "exported" to service.exported))
            val b = MediaBrowser(context, ComponentName(service.packageName, service.name), connection, null)
            browser = b
            b.connect()
        } catch (e: Exception) {
            Analytics.log("media", "browser", mapOf("state" to "error", "error" to e.toString()))
            browser = null
            scheduleRetry()
        }
    }

    private fun disconnectBrowser() {
        try {
            browser?.disconnect()
        } catch (_: Exception) {
        }
        browser = null
    }

    private fun scheduleRetry() {
        if (!started || retries >= MAX_RETRIES) return
        retries++
        main.removeCallbacks(retry)
        main.postDelayed(retry, RETRY_MS)
    }

    private fun dropController(publish: Boolean = true) {
        try {
            controller?.unregisterCallback(controllerCallback)
        } catch (_: Exception) {
        }
        controller = null
        if (publish) publishMedia()
    }

    private fun playing(c: MediaController?): Boolean = try {
        c?.playbackState?.state == PlaybackState.STATE_PLAYING
    } catch (_: Exception) {
        false
    }

    private fun publishMedia() {
        val c = projection?.takeIf { playing(it) } ?: controller ?: projection
        val media: Map<String, Any?> = if (c == null) {
            mapOf("connected" to false)
        } else {
            val md = try { c.metadata } catch (_: Exception) { null }
            val st = try { c.playbackState } catch (_: Exception) { null }
            mapOf(
                "connected" to true,
                "source" to if (c === projection) "projection" else "bluetooth",
                // The phone's own session stays at "playing" after the phone
                // has gone (seen on a scooter: the dashboard showed a video playing
                // that was not). With no paired phone linked it is not.
                "playing" to (st?.state == PlaybackState.STATE_PLAYING && !(c === controller && anyPhoneLinked() == false)),
                "title" to (md?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: ""),
                "artist" to (md?.getString(MediaMetadata.METADATA_KEY_ARTIST)
                    ?: md?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST) ?: ""),
                "durationMs" to (md?.getLong(MediaMetadata.METADATA_KEY_DURATION) ?: 0L),
                "positionMs" to (st?.position ?: -1L),
            )
        }
        // A playing AVRCP session is proof of a connected phone, whatever
        // the adapter's profile states say. Projection music proves nothing
        // about Bluetooth.
        onWitness("media", media["playing"] == true && c === controller)
        if (media == lastMedia) return
        if (media["playing"] != lastMedia?.get("playing")) logAudio(media)
        lastMedia = media
        events?.success(mapOf("_media" to media))
    }

    private var audioLogged = 0
    private var audioWindowAt = 0L

    /// Who else has the head unit's audio at the moment playback starts or
    /// stops. On a scooter a video on the phone was paused again within a
    /// second of every play, twelve times in a minute, with the phone on the
    /// scooter's hotspot for CarPlay and on Bluetooth at once; OpenDash sent
    /// no pause, and nothing in the log said what did. This is that record:
    /// every media session Android lists (which app, in which state), how
    /// many players are active and for what, and the audio mode. No titles.
    /// At most [AUDIO_LOGS] per ten minutes: a flapping session is the case
    /// it is for, and also the one that would fill the log.
    // TODO(video-pause): logging only. Video over CarPlay paused by itself on a scooter and OpenDash had sent no
    // pause; the cause is not known. Read media.audio around the next pause: who held the audio, and in which mode.
    private fun logAudio(media: Map<String, Any?>) {
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - audioWindowAt > 600_000L) {
            audioWindowAt = now
            audioLogged = 0
        }
        if (audioLogged++ >= AUDIO_LOGS) return
        val listed = try {
            sessions.getActiveSessions(listener).map { c ->
                val state = try { c.playbackState?.state } catch (_: Exception) { null }
                "${c.packageName}:${state ?: "none"}"
            }
        } catch (_: SecurityException) {
            null
        }
        val players = try {
            audio.activePlaybackConfigurations.map { it.audioAttributes.usage }
        } catch (_: Exception) {
            emptyList()
        }
        Analytics.log("media", "audio", mapOf(
            "playing" to media["playing"],
            "source" to media["source"],
            "position_ms" to media["positionMs"],
            "sessions" to listed,
            "player_usages" to players,
            "music_active" to audio.isMusicActive,
            "mode" to audio.mode,
            "bt_a2dp_on" to audio.isBluetoothA2dpOn,
        ))
    }

    private fun onCallChanged(call: Parcelable?) {
        if (call == null) {
            Analytics.log("call", "raw", mapOf("via" to "none"))
            return
        }
        var via = "reflect"
        val state: Int
        var number = ""
        var outgoing = false
        var inBand = false
        var id = 0
        val reflected = try {
            call.javaClass.getMethod("getState").invoke(call) as Int
        } catch (_: Exception) {
            null
        }
        if (reflected != null) {
            state = reflected
            number = optional(call, "getNumber") as? String ?: ""
            outgoing = optional(call, "isOutgoing") as? Boolean ?: false
            inBand = optional(call, "isInBandRing") as? Boolean ?: false
            id = optional(call, "getId") as? Int ?: 0
        } else {
            // toString() is public; it names the state but hashes the number.
            via = "string"
            val text = call.toString()
            state = CALL_STATES.indexOf(Regex("mState: (\\w+)").find(text)?.groupValues?.get(1))
            outgoing = text.contains("mOutgoing: true")
            inBand = text.contains("mInBandRing: true")
            id = Regex("mId: (\\d+)").find(text)?.groupValues?.get(1)?.toIntOrNull() ?: 0
        }
        Analytics.log("call", "raw", mapOf("via" to via, "state" to state, "outgoing" to outgoing, "in_band" to inBand, "id" to id))
        if (state < 0) return
        lastCallObject = if (state == CALL_TERMINATED) null else call
        publishCall(mapOf("state" to state, "number" to number, "outgoing" to outgoing, "inBand" to inBand, "id" to id))
    }

    private fun optional(target: Any, method: String): Any? = try {
        target.javaClass.getMethod(method).invoke(target)
    } catch (_: Exception) {
        null
    }

    private fun publishCall(call: Map<String, Any?>) {
        lastCall = call
        events?.success(mapOf("_call" to call))
    }

    /// `accept`, `reject` (a ringing call) or `end` (the call in progress),
    /// through the hidden `BluetoothHeadsetClient` methods of the same name.
    private fun callAction(action: String): Boolean {
        val proxy = hfp
        var error: String? = null
        var ok = false
        try {
            val device = proxy?.connectedDevices?.firstOrNull()
            if (proxy == null || device == null) {
                error = if (proxy == null) "no hfp proxy" else "no hfp device"
            } else {
                val type = proxy.javaClass
                val answer = when (action) {
                    "accept" -> type.getMethod("acceptCall", BluetoothDevice::class.java, Int::class.javaPrimitiveType)
                        .invoke(proxy, device, 0)
                    "reject" -> type.getMethod("rejectCall", BluetoothDevice::class.java).invoke(proxy, device)
                    "end" -> {
                        val current = lastCallObject
                        if (current == null) {
                            error = "no call"
                            false
                        } else {
                            type.getMethod("terminateCall", BluetoothDevice::class.java, current.javaClass)
                                .invoke(proxy, device, current)
                        }
                    }
                    else -> {
                        error = "unknown action"
                        false
                    }
                }
                ok = answer == true
            }
        } catch (e: Exception) {
            error = (e.cause ?: e).toString()
        }
        Analytics.log("call", "action", mapOf("action" to action, "ok" to ok, "error" to error))
        return ok
    }
}

/// Exists only so Android will list other apps' media sessions for
/// [MediaBridge]: it reads no notification.
class ProjectionMediaListener : android.service.notification.NotificationListenerService()
