package `in`.abhijithvijayan.opendash

import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import `in`.abhijithvijayan.opendash.hhmis.StockContract
import `in`.abhijithvijayan.opendash.hhmis.HhmisService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.Executors

/// What outlives any one [VehicleChannel]: the binding to HHMIS, the
/// system status watcher, every value heard so far, and which channel the
/// news goes to. Main thread only.
private object Link {
    val snapshot = HashMap<String, Any?>()
    var service: HhmisService? = null
    var status: SystemStatus? = null
    var live: VehicleChannel? = null
}

/// Flutter bridge: vehicle updates stream out over [EVENTS]; commands come
/// in as [VehicleLinkApi], which is generated, like its Dart caller, from
/// `pigeons/vehicle_link.dart`. Every command answers `true` when it
/// reached HHMIS, `false` when it did not go, and a [HHMIS_ERROR] error
/// when HHMIS threw, so Flutter can tell the rider which.
class VehicleChannel(context: Context, messenger: BinaryMessenger) : VehicleLinkApi {
    companion object {
        const val EVENTS = "in.abhijithvijayan.opendash.vehicle/events"
        const val HHMIS_ERROR = "hhmis_error"
        private val ONE_SHOT_KEYS = setOf(
            "_passcode", "_unlocked", "_vdpMissing", "_notificationPopup", "_popupCommand",
            // A firmware notice is news once; HOTA sends it again by itself.
            "_fw",
            "INT_BT_MUSIC_COMMAND", "INT_VEHICLE_COMMAND", "BOOL_PROFILE_PASSCODE_CHANGED_ACK",
            // A replayed switch-cube answer would pick up the next call by itself.
            "BOOL_BT_CALL_HANDLE_REQUEST",
            // A reattach must not replay a thermal-runaway /
            // tow-theft alert that already fired on this ride. HHMIS re-sends
            // the snapshot when the callback slot is retaken.
            "INT_THERMAL_RUNAWAY", "INT_TOW_THEFT_DETECTION_ALERT",
            // The same for the accident and fall screens: an
            // answered "Are you safe?" must not come back on the next listen.
            "BOOL_ACCIDENT_SEVERITY_STAT", "INT_FALL_DETECTION_ALERT",
            // A phone-app riding-setting request is carried out once.
            "INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST",
        )
    }

    private var events: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private val passcodeExecutor = Executors.newSingleThreadExecutor()

    /// For the calls that wait for HHMIS's reply (brightness, the volumes,
    /// re-registering, the update subscription): the main thread also builds
    /// frames. One thread, so they reach HHMIS in the order Dart sent them.
    /// Not the passcode's: that one can wait ~3 s.
    private val replyExecutor = Executors.newSingleThreadExecutor()

    private fun offMain(callback: (Result<Boolean>) -> Unit, call: () -> Boolean) {
        try {
            replyExecutor.execute {
                val result = runCatching(call)
                main.post { callback(result) }
            }
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            // Disposed: the engine this answer was for is going away.
            callback(Result.success(false))
        }
    }

    /// Every value seen so far, sent on listen. HHMIS's `addCallback` only
    /// replays volume and a forced `INT_VEHICLE_STATE=LOCK`; real state
    /// accumulates from change notifications after that, often before Dart
    /// has subscribed, so a cold start (or a crash-recovery restart) would
    /// otherwise sit on stale values until each one next changes.
    private val snapshot get() = Link.snapshot

    // The connection to the scooter belongs to the process, not to one
    // dashboard. When Android made a second dashboard on a scooter,
    // the first was retired and let go of HHMIS before the second had
    // bound; with the stock dashboard stopped OpenDash was HHMIS's only
    // client, so HHMIS was destroyed and took 44 s to come back: a start-up
    // screen for 38 s, then two passcodes answered "Couldn't reach the
    // scooter". A new channel now takes over the live connection and
    // everything it has heard; only the last channel to go closes it.
    private val adopted = Link.service != null
    private val service: HhmisService =
        Link.service ?: HhmisService(context) { batch -> Link.live?.publish(batch) }.also { Link.service = it }
    private val status: SystemStatus =
        Link.status ?: SystemStatus(context) { key, on -> Link.live?.publish(mapOf(key to on)) }.also { Link.status = it }
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    init {
        EventChannel(messenger, EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                events = sink
                val initial = HashMap(snapshot)
                initial["_connected"] = service.connected
                initial["_wifi"] = status.wifi
                initial["_bt"] = status.bluetooth
                sink.success(initial)
            }

            override fun onCancel(arguments: Any?) {
                events = null
            }
        })
        VehicleLinkApi.setUp(messenger, this)
        Link.live = this
        if (adopted) {
            Analytics.log("hhmis", "kotlin_link_adopted", mapOf("connected" to service.connected, "values" to snapshot.size))
        } else {
            service.start()
            status.start()
        }
        BackgroundTouch.attach { on ->
            // Stock ignores touches above 1 km/h (touch is disabled there).
            val moving = ((snapshot["INT_VEHICLE_SPEED"] as? Int) ?: 0) > 1
            service.send(StockContract.TOUCH_STATUS) { boolCmd(it, on && !moving) }
        }
    }

    /// Main thread. The Bluetooth flag is re-read when the activity resumes
    /// and when `MediaBridge` sees a playing session or an HFP device.
    fun refreshBluetooth(trigger: String) = status.refresh(trigger)

    fun bluetoothWitness(source: String, on: Boolean) = status.witness(source, on)

    fun dispose() {
        passcodeExecutor.shutdown()
        replyExecutor.shutdown()
        events = null
        // A newer channel has the connection: nothing of it is touched.
        if (Link.live !== this) return
        Link.live = null
        BackgroundTouch.attach(null)
        service.stop()
        status.stop()
        Link.service = null
        Link.status = null
        Link.snapshot.clear()
    }

    /// Main thread only (both sources post there).
    internal fun publish(batch: Map<String, Any?>) {
        for ((key, value) in batch) {
            // One-shot events must not replay on the next listen: a replayed
            // music key would toggle playback on a crash restart.
            if (key in ONE_SHOT_KEYS) continue
            snapshot[key] = value
        }
        // The display supply was cut (LOCK): the island goes without waiting
        // for Dart to say so.
        if (batch["BOOL_HEAD_UNIT_POWER_FLAG"] == false) DashIsland.hide("display_off")
        events?.success(batch)
    }

    /// The commands OpenDash never sends, and the update check, which has
    /// its own method: refused here before anything else looks at them.
    private fun refused(cmd: String, method: String): Boolean {
        if (cmd !in StockContract.NEVER_SENT && cmd != StockContract.CHECK_FOR_UPDATE) return false
        Analytics.log("hhmis", "kotlin_cmd_refused", mapOf("cmd" to cmd, "method" to method))
        return true
    }

    /// True: it reached HHMIS. False: it did not go. HHMIS reached and
    /// threw: an error, so the rider is not told "not connected".
    private fun sent(method: String, result: Boolean?): Boolean =
        result ?: throw VehicleLinkError(HHMIS_ERROR, "HHMIS rejected $method", null)

    override fun sendVoid(cmd: String) =
        !refused(cmd, "sendVoid") && sent("sendVoid", service.send(cmd) { voidCmd(it) })

    override fun sendBool(cmd: String, value: Boolean) =
        !refused(cmd, "sendBool") && sent("sendBool", service.send(cmd) { boolCmd(it, value) })

    override fun sendInt(cmd: String, value: Long) =
        !refused(cmd, "sendInt") && sent("sendInt", service.send(cmd) { intCmd(it, value.toInt()) })

    override fun sendString(cmd: String, value: String) =
        !refused(cmd, "sendString") && sent("sendString", service.send(cmd) { stringCmd(it, value) })

    // The one place VOID_CHECK_FOR_UPDATE is sent: the rider's "Check now".
    // HHMIS asks HOTA whether an update is waiting.
    override fun checkFirmwareUpdate() = sent("checkFirmwareUpdate", service.send(StockContract.CHECK_FOR_UPDATE) { voidCmd(it) })

    override fun subscribeFirmware(callback: (Result<Boolean>) -> Unit) = offMain(callback) { service.subscribeUpdates() }

    // Stock persists the level to the profile only when the slider is
    // released (SettingsInfoManager ACTION_SLIDER_BRIGHTNESS_FINISHED).
    override fun setBrightness(value: Long, persist: Boolean, callback: (Result<Boolean>) -> Unit) =
        offMain(callback) { sent("setBrightness", service.command { updateSystemBrightness(value.toInt(), persist) }) }

    override fun setVolume(level: Long, callback: (Result<Boolean>) -> Unit) =
        offMain(callback) { sent("setVolume", service.command { updateVolume(level.toInt()) }) }

    override fun setMotorVolume(level: Long, callback: (Result<Boolean>) -> Unit) =
        offMain(callback) { sent("setMotorVolume", service.command { updateMotorVolume(level.toInt()) }) }

    override fun setChimeVolume(level: Long, callback: (Result<Boolean>) -> Unit) =
        offMain(callback) { sent("setChimeVolume", service.command { updateChimeVolume(level.toInt()) }) }

    override fun btSnapshot(trigger: String): Boolean {
        status.snapshotAfter(trigger)
        return true
    }

    override fun reattachCallback(callback: (Result<Boolean>) -> Unit) = offMain(callback) { service.reattachCallback() }

    /// The challenge is a synchronous binder call that waits for HPMS's
    /// SCrypt check and, on a match, HVDP's unlock frame until the VCU acks:
    /// up to ~3 s with no ack. Off the main thread so the UI keeps drawing;
    /// the answer goes back on the main thread, as the channel requires.
    override fun verifyPasscode(code: String, verifyOnly: Boolean, callback: (Result<Boolean>) -> Unit) {
        passcodeExecutor.execute {
            val reached = service.command { onPasscodeEntered(code, verifyOnly) }
            main.post { callback(runCatching { sent("verifyPasscode", reached) }) }
        }
    }

    /// Media transport goes to whichever session is active (the phone over
    /// AVRCP), the same route the physical media keys take.
    override fun mediaKey(key: String): Boolean {
        val code = when (key) {
            "play" -> KeyEvent.KEYCODE_MEDIA_PLAY
            "pause" -> KeyEvent.KEYCODE_MEDIA_PAUSE
            "playPause" -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
            "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
            "prev" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
            else -> return false
        }
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
        audio.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
        return true
    }
}
