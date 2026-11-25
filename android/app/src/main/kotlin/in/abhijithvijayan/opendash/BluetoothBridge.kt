package `in`.abhijithvijayan.opendash

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import `in`.abhijithvijayan.opendash.hsss.ProfileManagerClient
import `in`.abhijithvijayan.opendash.hsss.SystemSettingsClient
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/// Bluetooth settings for the Flutter side: the adapter's own state (what
/// the plain BLUETOOTH permission can read), the HSSS client for what needs
/// system rights, and the HPMS write behind "calls on the dashboard".
/// Dart names each HSSS call (`hsss`: `{method, data}`) and each profile
/// value (`profileUpdateInt`: `{cmd, value}`) by its stock name; the
/// numbers are found here, for the services installed on this scooter.
///
/// Events on [EVENTS], main thread, one key each:
///  - `hsss` (Boolean): the HSSS Bluetooth binder is usable
///  - `state`: `{enabled, scanMode, name, devices: [{address, name,
///    connected}]}`, the bonded classic / dual-mode phones
///  - `pairing`: `{event, value}` from HSSS `IPairingStatusUpdate`
///  - `bond`: `{address, state, prev, reason}` from BOND_STATE_CHANGED
///  - `callName`: `{state, name}` from HSSS `ICallState`
///
/// Names, addresses and pairing codes go to Dart only; nothing here logs them.
class BluetoothBridge(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, SystemSettingsClient.Listener {
    companion object {
        const val EVENTS = "in.abhijithvijayan.opendash.bt/events"
        const val COMMANDS = "in.abhijithvijayan.opendash.bt/commands"
        private const val EXTRA_REASON = "android.bluetooth.device.extra.REASON"
        private const val RECHECK_MS = 2500L

        @Volatile
        private var receiversRegistered = false
    }

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val hsss = SystemSettingsClient(context, this)
    private val profile = ProfileManagerClient(context)
    private var events: EventChannel.EventSink? = null
    private var lastState: Map<String, Any?>? = null

    private val recheck = Runnable { publishState() }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == BluetoothDevice.ACTION_BOND_STATE_CHANGED) {
                val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
                events?.success(mapOf("bond" to mapOf(
                    "address" to (device?.address ?: ""),
                    "state" to intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1),
                    "prev" to intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, -1),
                    "reason" to intent.getIntExtra(EXTRA_REASON, -1),
                )))
            }
            publishState()
            // The profiles settle a second or two after the ACL link.
            main.removeCallbacks(recheck)
            main.postDelayed(recheck, RECHECK_MS)
        }
    }

    init {
        EventChannel(messenger, EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                events = sink
                lastState = null
                sink.success(mapOf("hsss" to hsss.isBound))
                publishState()
            }

            override fun onCancel(arguments: Any?) {
                events = null
            }
        })
        MethodChannel(messenger, COMMANDS).setMethodCallHandler(this)
        context.registerReceiver(receiver, IntentFilter().apply {
            addAction(BluetoothAdapter.ACTION_STATE_CHANGED)
            addAction(BluetoothAdapter.ACTION_SCAN_MODE_CHANGED)
            addAction(BluetoothAdapter.ACTION_LOCAL_NAME_CHANGED)
            addAction(BluetoothAdapter.ACTION_CONNECTION_STATE_CHANGED)
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
            addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        })
        hsss.start()
    }

    fun dispose() {
        main.removeCallbacks(recheck)
        try {
            context.unregisterReceiver(receiver)
        } catch (_: IllegalArgumentException) {
        }
        hsss.stop()
        worker.shutdown()
        events = null
    }

    /// Main thread, on activity resume: the phone may have been paired or
    /// dropped from the stock dashboard meanwhile.
    fun refresh() = publishState()

    override fun onBound(bound: Boolean) {
        events?.success(mapOf("hsss" to bound))
    }

    override fun onPairing(event: String, value: String?) {
        events?.success(mapOf("pairing" to mapOf("event" to event, "value" to value)))
    }

    override fun onCallState(state: Int, name: String?) {
        events?.success(mapOf("callName" to mapOf("state" to state, "name" to name)))
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hsss" -> {
                val method = call.argument<String>("method")!!
                val data = call.argument<ByteArray>("data") ?: ByteArray(0)
                onWorker(result) { hsss.call(method, data) }
            }
            "hsssRegisterCallbacks" -> onWorker(result) {
                hsss.registerCallbacks()
                true
            }
            // Once per process, so a rebuilt Flutter engine does not stack a
            // registration on HSSS each time; `force` is for after a visit to
            // the stock dashboard, whose onStop unregistered them.
            "hsssRegisterReceivers" -> onWorker(result) {
                if (call.arguments == true || !receiversRegistered) {
                    hsss.registerReceivers()
                    receiversRegistered = true
                }
                true
            }
            "profileUpdateInt" -> profile.updateInt(call.argument<String>("cmd")!!, call.argument<Int>("value")!!) { error ->
                if (error == null) result.success(true) else result.error("hpms_error", error, null)
            }
            "removeBond" -> result.success(removeBond(call.arguments as String))
            "refresh" -> {
                lastState = null
                publishState()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    /// Binder calls into HSSS block (it answers from its main thread), so
    /// they queue on one worker; the answer goes back on the main thread.
    private fun onWorker(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("hsss_error", e.toString(), null) }
            }
        }
    }

    /// Stock HHMIC unpairs with `BluetoothDevice.removeBond()` itself (HSSS
    /// `forgetDevice` only clears its phonebook). The method is hidden;
    /// it needs BLUETOOTH_ADMIN and a hidden-API list that lets it through,
    /// and the log says whether this firmware's does.
    private fun removeBond(address: String): Boolean {
        var error: String? = null
        val ok = try {
            val device = BluetoothAdapter.getDefaultAdapter()?.getRemoteDevice(address)
            if (device == null) {
                error = "no adapter"
                false
            } else {
                BluetoothDevice::class.java.getMethod("removeBond").invoke(device) == true
            }
        } catch (e: Exception) {
            error = (e.cause ?: e).toString()
            false
        }
        Analytics.log("bt", "remove_bond", mapOf("ok" to ok, "error" to error))
        return ok
    }

    private fun publishState() {
        val adapter = BluetoothAdapter.getDefaultAdapter()
        val state: Map<String, Any?> = try {
            val enabled = adapter != null && adapter.isEnabled
            val devices = if (enabled) {
                adapter!!.bondedDevices.orEmpty()
                    .filter { it.type != BluetoothDevice.DEVICE_TYPE_LE }
                    .map { mapOf("address" to it.address, "name" to (it.name ?: ""), "connected" to (isConnected(it) == true)) }
                    .sortedBy { it["address"] as String }
            } else {
                emptyList()
            }
            mapOf(
                "enabled" to enabled,
                "scanMode" to (adapter?.scanMode ?: BluetoothAdapter.SCAN_MODE_NONE),
                "name" to (adapter?.name ?: ""),
                "devices" to devices,
            )
        } catch (e: SecurityException) {
            mapOf("enabled" to false, "scanMode" to BluetoothAdapter.SCAN_MODE_NONE, "name" to "", "devices" to emptyList<Any>())
        }
        if (state == lastState) return
        lastState = state
        events?.success(mapOf("state" to state))
    }

    /// As in `SystemStatus`: hidden, not blocked on API 29.
    private fun isConnected(device: BluetoothDevice): Boolean? = try {
        BluetoothDevice::class.java.getMethod("isConnected").invoke(device) as? Boolean
    } catch (_: Exception) {
        null
    }
}
