package `in`.abhijithvijayan.opendash.hsss

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import `in`.abhijithvijayan.opendash.Analytics

/// `IProfileManagerService.updateInt` on HPMS
/// (`com.olaelectric.profilemanagerservice`), for the two profile values
/// behind "phone calls on the dashboard", each named by its
/// `ProfileManagerCmd` constant. The transaction code and the constant's
/// ordinal are those of the HPMS installed on this scooter, read before
/// each write ([StockCallsReader]), or [HpmsCalls.BUILTIN] when that
/// cannot be read; `bt.stock_calls` says which. Stock HHMIC writes them the same
/// way (`TelephonyInfoManager.setPhoneCallAllowed` /
/// `setPhoneCallConsentAccepted`); HHMIS has no ClientCmd for them and only
/// replays them at unlock (`INT_PERSISTED_SYNC_CONTACT` / `_CONSENT`).
///
/// The service is exported with no permission and `ProfileController.
/// updateInt` checks no caller. Bound for the one call and released, so
/// HPMS sees a client only while a value is being written.
class ProfileManagerClient(private val context: Context) {
    companion object {
        val COMPONENT = ComponentName(HpmsCalls.PACKAGE, "${HpmsCalls.PACKAGE}.services.ProfileManagerService")
        private const val DESCRIPTOR = "com.olaelectric.pmservice.IProfileManagerService"
        private const val TIMEOUT_MS = 5000L
    }

    private val main = Handler(Looper.getMainLooper())

    /// Main thread. [done] gets null on success, else what went wrong.
    fun updateInt(cmd: String, value: Int, done: (String?) -> Unit) {
        if (cmd !in HpmsCalls.ALLOWED || value !in 0..1) {
            done("not allowed")
            return
        }
        var finished = false
        lateinit var connection: ServiceConnection
        fun finish(error: String?) {
            if (finished) return
            finished = true
            main.removeCallbacksAndMessages(connection)
            try {
                context.unbindService(connection)
            } catch (_: IllegalArgumentException) {
            }
            done(error)
        }
        connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, service: IBinder) {
                Thread {
                    val error = try {
                        write(service, cmd, value)
                        null
                    } catch (e: Exception) {
                        e.toString()
                    }
                    main.post { finish(error) }
                }.start()
            }

            override fun onServiceDisconnected(name: ComponentName) = finish("disconnected")

            override fun onNullBinding(name: ComponentName) = finish("null binding")
        }
        val ok = try {
            context.bindService(Intent().setComponent(COMPONENT), connection, Context.BIND_AUTO_CREATE)
        } catch (e: SecurityException) {
            false
        }
        if (!ok) {
            finish("bind refused")
            return
        }
        main.postAtTime({ finish("timeout") }, connection, android.os.SystemClock.uptimeMillis() + TIMEOUT_MS)
    }

    /// The enum parcels as a presence int and its ordinal, then the value.
    /// A value this HPMS has no constant for is not written.
    private fun write(service: IBinder, cmd: String, value: Int) {
        val calls = HpmsCalls.resolve(StockCallsReader.hpms(context))
        Analytics.log(
            "bt", "stock_calls",
            mapOf("service" to "hpms", "source" to calls.source, "differs" to calls.differences(HpmsCalls.BUILTIN)),
        )
        val (code, ordinal) = HpmsCalls.updateInt(calls, cmd)
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(DESCRIPTOR)
            data.writeInt(1)
            data.writeInt(ordinal)
            data.writeInt(value)
            service.transact(code, data, reply, 0)
            reply.readException()
        } finally {
            reply.recycle()
            data.recycle()
        }
    }
}
