package `in`.abhijithvijayan.opendash.hsss

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Binder
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import `in`.abhijithvijayan.opendash.Analytics

/// Client of HSSS (`com.olaelectric.connectivityservice`, system uid), the
/// service stock HHMIC drives Bluetooth through. Binds its exported
/// `SystemSettings` service (no permission, no caller check in `onBind` or
/// `SystemSettingsImpl`), asks `ISystemSettings.getBluetoothSettings` for
/// the `IBluetoothSettings` binder, and carries transactions to it.
///
/// Every call is made by its stock method name. The transaction codes
/// are those of the HSSS installed on this scooter, read on each bind
/// before anything is sent ([StockCallsReader]), or [HsssCalls.BUILTIN]
/// when that cannot be read; `bt.stock_calls` says which.
///
/// The request and reply layouts live in Dart (`lib/services/
/// hsss_bluetooth.dart`), where the tests can reach them: [call] adds the
/// interface token to a ready-made payload and returns what follows the
/// reply's exception header. Only the methods in [HsssCalls.ALLOWED] pass.
/// Binder arguments cannot travel as bytes, so the two callback
/// registrations and `registerReceivers` are written here.
///
/// HSSS keeps one slot per callback type for all its clients and never
/// clears it: registering ours displaces stock HHMIC's until HHMIC's
/// process next starts and registers again. A null slot is worse than a
/// stale one (`handlePairingFailed` calls `showPairFailPopUp` on it
/// unguarded), so once registered we stay registered.
///
/// Binder calls block; everything but [start] / [stop] runs on the
/// caller's worker thread. The listener is called on the main thread.
class SystemSettingsClient(private val context: Context, private val listener: Listener) {
    interface Listener {
        fun onBound(bound: Boolean)

        /// `IPairingStatusUpdate`: [event] is `popup` (value = the phone's
        /// name), `pin` (value = the six-digit code, "000000" when HSSS
        /// clears it), `dismiss` or `fail`.
        fun onPairing(event: String, value: String?)

        /// `ICallState.onCallStateChanged`: the `BluetoothHeadsetClientCall`
        /// state and the name HSSS found for the number in the phonebook it
        /// pulled (the number itself when it found none).
        fun onCallState(state: Int, name: String?)
    }

    companion object {
        val COMPONENT = ComponentName(HsssCalls.PACKAGE, "${HsssCalls.PACKAGE}.SystemSettings")
        const val ACTION = "com.olaelectric.settings.SystemSettings"
        private const val SYSTEM_DESCRIPTOR = "com.olaelectric.systemsettings.ISystemSettings"
        private const val BT_DESCRIPTOR = "com.olaelectric.systemsettings.IBluetoothSettings"
        private const val PAIRING_DESCRIPTOR = "com.olaelectric.systemsettings.IPairingStatusUpdate"
        private const val CALL_DESCRIPTOR = "com.olaelectric.systemsettings.ICallState"
    }

    private val main = Handler(Looper.getMainLooper())
    private var bound = false

    @Volatile
    private var bluetooth: IBinder? = null

    @Volatile
    private var calls = HsssCalls.resolve(null)

    @Volatile
    private var pairingEvents = HsssCalls.pairingEvents(calls)

    val isBound: Boolean get() = bluetooth != null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            // getBluetoothSettings builds a BTInfoManager over HSSS's one
            // shared repository; quick, but still a binder call.
            Thread {
                val bt = try {
                    readCalls()
                    bluetoothSettings(service)
                } catch (e: Exception) {
                    log("failed", e.toString())
                    null
                }
                if (bt == null) {
                    main.post { rebindLater("no_bluetooth_settings") }
                    return@Thread
                }
                bluetooth = bt
                log("bound")
                main.post {
                    attempts = 0
                    listener.onBound(true)
                }
            }.start()
        }

        override fun onServiceDisconnected(name: ComponentName) = lost("disconnected")

        override fun onBindingDied(name: ComponentName) {
            lost("binding_died")
            main.post { rebindLater("binding_died") }
        }

        override fun onNullBinding(name: ComponentName) {
            log("null_binding")
            main.post { rebindLater("null_binding") }
        }
    }

    private var attempts = 0
    private val rebind = Runnable {
        if (bluetooth == null) start()
    }

    /// Main thread. Android reconnects a binding whose service died, but not
    /// one that died for good or was answered with nothing: on a scooter
    /// HSSS went down twice in 40 s, came back the second time with a null
    /// binding, and Bluetooth settings stayed read-only until the next
    /// start of OpenDash. Those are bound afresh, a little later each time.
    private fun rebindLater(reason: String) {
        if (bluetooth != null) return
        stop(quiet = true)
        val delay = longArrayOf(2_000, 5_000, 10_000, 30_000)[minOf(attempts, 3)]
        attempts++
        Analytics.log("bt", "hsss_rebind", mapOf("reason" to reason, "attempt" to attempts, "in_ms" to delay))
        main.removeCallbacks(rebind)
        main.postDelayed(rebind, delay)
    }

    fun start() {
        var error: String? = null
        bound = try {
            context.bindService(Intent(ACTION).setComponent(COMPONENT), connection, Context.BIND_AUTO_CREATE)
        } catch (e: SecurityException) {
            error = e.toString()
            false
        }
        if (!bound) {
            log("bind_refused", error ?: "bindService returned false")
            try {
                context.unbindService(connection)
            } catch (_: IllegalArgumentException) {
            }
            if (attempts > 0) main.post { rebindLater("bind_refused") }
        }
    }

    fun stop(quiet: Boolean = false) {
        if (!quiet) main.removeCallbacks(rebind)
        bluetooth = null
        if (!bound) return
        bound = false
        try {
            context.unbindService(connection)
        } catch (_: IllegalArgumentException) {
        }
        if (!quiet) log("unbound")
    }

    /// The binding stays; Android reconnects it when HSSS is back, and
    /// `onServiceConnected` runs again.
    private fun lost(reason: String) {
        if (bluetooth == null) return
        bluetooth = null
        log("lost", reason)
        main.post { listener.onBound(false) }
    }

    private fun log(state: String, error: String? = null) =
        Analytics.log("bt", "hsss", mapOf("state" to state, "error" to error, "selinux" to Analytics.selinux()))

    private fun readCalls() {
        val found = HsssCalls.resolve(StockCallsReader.hsss(context))
        pairingEvents = HsssCalls.pairingEvents(found)
        calls = found
        Analytics.log(
            "bt", "stock_calls",
            mapOf("service" to "hsss", "source" to found.source, "differs" to found.differences(HsssCalls.BUILTIN)),
        )
    }

    private fun bluetoothSettings(service: IBinder): IBinder? {
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(SYSTEM_DESCRIPTOR)
            service.transact(calls.need(HsssCalls.SYSTEM, HsssCalls.GET_BLUETOOTH_SETTINGS), data, reply, 0)
            reply.readException()
            val bt = reply.readStrongBinder()
            if (bt == null) log("no_binder")
            return bt
        } finally {
            reply.recycle()
            data.recycle()
        }
    }

    /// One `IBluetoothSettings` call, by stock method name. [payload] is
    /// the flat parcel data after the interface token; the return is the
    /// reply after its exception header. Throws what HSSS threw,
    /// IllegalStateException when not bound, and, before anything is sent,
    /// for a method that is not allowed or that this HSSS does not have.
    fun call(method: String, payload: ByteArray): ByteArray {
        val code = try {
            HsssCalls.dataCall(calls, method)
        } catch (e: Exception) {
            // Only an allowed name is known to be a stock method name; anything else is logged by its length.
            Analytics.log(
                "bt", "hsss_refused",
                mapOf("method" to (if (method in HsssCalls.ALLOWED) method else "len:${method.length}"), "error" to e.javaClass.simpleName),
            )
            throw e
        }
        val reply = transactCode(code) {
            if (payload.isNotEmpty()) {
                val args = Parcel.obtain()
                try {
                    args.unmarshall(payload, 0, payload.size)
                    appendFrom(args, 0, args.dataSize())
                } finally {
                    args.recycle()
                }
            }
        }
        try {
            val all = reply.marshall()
            return all.copyOfRange(reply.dataPosition(), all.size)
        } finally {
            reply.recycle()
        }
    }

    /// `setBTInfoManager` and `subscribeCallStatusCallback`: the pairing
    /// prompt and the caller's name come to [listener].
    fun registerCallbacks() {
        transact(HsssCalls.SET_BT_INFO_MANAGER) { writeStrongBinder(pairingCallback) }.recycle()
        transact(HsssCalls.SUBSCRIBE_CALL_STATUS) { writeStrongBinder(callCallback) }.recycle()
    }

    /// `registerReceivers`: HSSS registers its pairing-request and
    /// Bluetooth-event receivers. Its repository does this once when it is
    /// built, and stock HHMIC again on every `onStart`; HHMIC's `onStop`
    /// calls `unregisterReceivers`, after which HSSS hears no pairing
    /// request until somebody registers again. A registration on top of a
    /// live one only makes HSSS handle each broadcast twice (stock is in
    /// that state from its first `onStart`).
    fun registerReceivers() = transact(HsssCalls.REGISTER_RECEIVERS) {}.recycle()

    private inline fun transact(method: String, write: Parcel.() -> Unit): Parcel =
        transactCode(calls.need(HsssCalls.BLUETOOTH, method), write)

    private inline fun transactCode(code: Int, write: Parcel.() -> Unit): Parcel {
        val bt = bluetooth ?: throw IllegalStateException("HSSS not bound")
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(BT_DESCRIPTOR)
            data.write()
            bt.transact(code, data, reply, 0)
            reply.readException()
            return reply
        } catch (e: Throwable) {
            reply.recycle()
            throw e
        } finally {
            data.recycle()
        }
    }

    // HSSS calls both stubs synchronously from its broadcast receiver, on
    // its main thread, and reads the reply's exception header: answer at
    // once and do the work on our own main thread.
    private val pairingCallback = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            val event = pairingEvents[code] ?: return super.onTransact(code, data, reply, flags)
            data.enforceInterface(PAIRING_DESCRIPTOR)
            val value = if (event == "pin" || event == "popup") data.readString() else null
            reply?.writeNoException()
            main.post { listener.onPairing(event, value) }
            return true
        }
    }

    private val callCallback = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            val changed = code == calls.code(HsssCalls.CALL, HsssCalls.ON_CALL_STATE_CHANGED)
            if (!changed && code != calls.code(HsssCalls.CALL, HsssCalls.ON_CALL_AUTO_REJECTED)) {
                return super.onTransact(code, data, reply, flags)
            }
            data.enforceInterface(CALL_DESCRIPTOR)
            if (changed) {
                val state = data.readInt()
                val name = data.readString()
                main.post { listener.onCallState(state, name) }
            }
            reply?.writeNoException()
            return true
        }
    }
}
