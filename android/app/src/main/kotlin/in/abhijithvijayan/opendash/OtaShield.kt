package `in`.abhijithvijayan.opendash

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.SystemClock
import io.flutter.plugin.common.MethodChannel
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import org.json.JSONArray
import org.json.JSONObject

/// What OTA Shield (com.hxmst.otablocker, https://codeberg.org/pitzel/ota-shield)
/// reports about its firmware block, from two places:
///
/// - the control port its root daemon opens on 127.0.0.1:5376
///   (`DaemonControlServer`), open exactly while the daemon runs: the only
///   proof the block is up, and where the counts come from. Only GET_STATS
///   and GET_FOTA_UPDATES are sent, never FLUSH_STATS or CLEAR_FOTA_UPDATES.
/// - its exported service (`IOtaShieldService`), used only where its
///   `getApiVersion()` says 2 or later (1.1.0 on): whether it is activated,
///   whether its boot fail-safe has cut the scooter off from Ola's cloud,
///   and where an activation is. The port still decides "running".
///
/// 1.1.0 put `getApiVersion()` first, which renumbered every method: what
/// is "deactivateBlocker" there was "disableFailsafe" in 1.0.0. So nothing
/// is sent to a service that does not answer 2 or later to transaction 0
/// (which is `isActivated` on 1.0.0, a 0 or a 1): a 1.0.0 is treated as
/// having no service at all.
///
/// The only things OpenDash asks the service to do are activate the block
/// and turn off an engaged fail-safe; never deactivate it or change its boot
/// setting. An offer's download address, release notes, topic and asset id
/// are dropped here and never reach Dart.
object OtaShield {
    private const val PORT = 5376
    private const val MAX_OFFERS = 5
    private const val PACKAGE = "com.hxmst.otablocker"
    private const val SERVICE_ACTION = "com.hxmst.otablocker.SERVICE"
    private const val SERVICE_CLASS = "com.hxmst.otablocker.service.OtaShieldService"
    private const val DESCRIPTOR = "com.hxmst.otablocker.IOtaShieldService"
    private const val CALLBACK_DESCRIPTOR = "com.hxmst.otablocker.IOtaShieldCallback"
    private const val BIND_WAIT_MS = 2_000L

    // IOtaShieldService's methods in declaration order, as API version 2
    // numbers them (0 getApiVersion, 1 isActivated, 2 isFailsafeEngaged,
    // 3 isBootFailsafeEnabled, 4 getActivationStep, 5 getStatsReportJson,
    // 6 getFotaLogsJson, 7 activateBlocker, 8 deactivateBlocker,
    // 9 disableFailsafe, 10 setBootFailsafeEnabled, 11 isDaemonRunning).
    // These six are the only ones sent.
    private const val TX_GET_API_VERSION = IBinder.FIRST_CALL_TRANSACTION + 0
    private const val TX_IS_ACTIVATED = IBinder.FIRST_CALL_TRANSACTION + 1
    private const val TX_IS_FAILSAFE_ENGAGED = IBinder.FIRST_CALL_TRANSACTION + 2
    private const val TX_GET_ACTIVATION_STEP = IBinder.FIRST_CALL_TRANSACTION + 4
    private const val TX_ACTIVATE_BLOCKER = IBinder.FIRST_CALL_TRANSACTION + 7
    private const val TX_DISABLE_FAILSAFE = IBinder.FIRST_CALL_TRANSACTION + 9

    /// The first API version whose numbering is the one above.
    private const val API = 2

    @Volatile private var service: IBinder? = null
    @Volatile private var binding = false
    private val bindLock = Object()

    /// The activation OpenDash started, as OTA Shield's callback reports it:
    /// "running" with its step, then "done" or "failed" with its message.
    @Volatile private var activation: Map<String, Any?>? = null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            synchronized(bindLock) {
                service = binder
                bindLock.notifyAll()
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            service = null
            lost()
        }

        override fun onBindingDied(name: ComponentName?) {
            synchronized(bindLock) {
                service = null
                binding = false
            }
            lost()
        }
    }

    /// OTA Shield's process went away mid-activation: no callback will come.
    private fun lost() {
        if (activation?.get("phase") == "running") activation = mapOf("phase" to "failed", "error" to "OTA Shield stopped")
    }

    fun status(activity: Activity, result: MethodChannel.Result) {
        val context = activity.applicationContext
        Thread {
            val found = try {
                readPort()
            } catch (e: Exception) {
                mapOf("running" to false)
            }
            val fromService = try {
                readService(context)
            } catch (e: Exception) {
                null
            }
            activity.runOnUiThread { result.success(found + ("service" to fromService)) }
        }.start()
    }

    /// Starts OTA Shield's own activation; true when it was asked (or one
    /// OpenDash started is still going). Its progress shows in [status].
    fun activate(activity: Activity, result: MethodChannel.Result) {
        val context = activity.applicationContext
        Thread {
            val asked = try {
                if (activation?.get("phase") == "running") {
                    true
                } else {
                    val binder = compatible(context)
                    if (binder == null) {
                        false
                    } else {
                        activation = mapOf("phase" to "running", "step" to "CHECKING_STATUS")
                        call(binder, TX_ACTIVATE_BLOCKER, { it.writeStrongBinder(Progress()) }) { }
                        true
                    }
                }
            } catch (e: Exception) {
                activation = null
                false
            }
            activity.runOnUiThread { result.success(asked) }
        }.start()
    }

    /// Lifts the boot fail-safe's firewall; OTA Shield's answer.
    fun disableFailsafe(activity: Activity, result: MethodChannel.Result) {
        val context = activity.applicationContext
        Thread {
            val done = try {
                compatible(context)?.let { call(it, TX_DISABLE_FAILSAFE) { r -> r.readInt() != 0 } } ?: false
            } catch (e: Exception) {
                false
            }
            activity.runOnUiThread { result.success(done) }
        }.start()
    }

    private fun readService(context: Context): Map<String, Any?>? {
        val binder = compatible(context) ?: return null
        return mapOf(
            "activated" to call(binder, TX_IS_ACTIVATED) { it.readInt() != 0 },
            "failsafe" to call(binder, TX_IS_FAILSAFE_ENGAGED) { it.readInt() != 0 },
            "step" to call(binder, TX_GET_ACTIVATION_STEP) { it.readString() },
            "activation" to activation,
        )
    }

    private fun <T> call(binder: IBinder, code: Int, write: (Parcel) -> Unit = {}, read: (Parcel) -> T): T {
        val data = Parcel.obtain()
        val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(DESCRIPTOR)
            write(data)
            binder.transact(code, data, reply, 0)
            reply.readException()
            return read(reply)
        } finally {
            data.recycle()
            reply.recycle()
        }
    }

    /// The service, only when it numbers its methods as above: asked before
    /// every use, as OTA Shield can be updated while OpenDash runs.
    private fun compatible(context: Context): IBinder? {
        val binder = bound(context) ?: return null
        val api = call(binder, TX_GET_API_VERSION) { it.readInt() }
        return if (api >= API) binder else null
    }

    /// OTA Shield's service, bound once and kept for the life of the
    /// process; null when this build of it has none.
    private fun bound(context: Context): IBinder? {
        service?.takeIf { it.isBinderAlive }?.let { return it }
        synchronized(bindLock) {
            if (!binding) binding = bind(context)
            if (!binding) return null
            val until = SystemClock.uptimeMillis() + BIND_WAIT_MS
            while (service?.isBinderAlive != true) {
                val left = until - SystemClock.uptimeMillis()
                if (left <= 0) return null
                bindLock.wait(left)
            }
            return service
        }
    }

    /// By its action first; started by name when that is refused (a
    /// package Android holds as stopped), as OTA Shield's README says.
    private fun bind(context: Context): Boolean {
        val byAction = Intent(SERVICE_ACTION).setPackage(PACKAGE)
        if (runCatching { context.bindService(byAction, connection, Context.BIND_AUTO_CREATE) }.getOrDefault(false)) return true
        val byName = Intent().setComponent(ComponentName(PACKAGE, SERVICE_CLASS))
        runCatching { context.startService(byName) }
        return runCatching { context.bindService(byName, connection, Context.BIND_AUTO_CREATE) }.getOrDefault(false)
    }

    /// IOtaShieldCallback: onProgress(step, message), onSuccess(message),
    /// onError(message).
    private class Progress : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code == INTERFACE_TRANSACTION) {
                reply?.writeString(CALLBACK_DESCRIPTOR)
                return true
            }
            if (code !in IBinder.FIRST_CALL_TRANSACTION..IBinder.FIRST_CALL_TRANSACTION + 2) return super.onTransact(code, data, reply, flags)
            data.enforceInterface(CALLBACK_DESCRIPTOR)
            activation = when (code - IBinder.FIRST_CALL_TRANSACTION) {
                0 -> mapOf("phase" to "running", "step" to data.readString())
                1 -> mapOf("phase" to "done")
                else -> mapOf("phase" to "failed", "error" to data.readString()?.take(200))
            }
            reply?.writeNoException()
            return true
        }
    }

    private fun readPort(): Map<String, Any?> {
        Socket().use { socket ->
            socket.connect(InetSocketAddress(InetAddress.getByName("127.0.0.1"), PORT), 500)
            socket.soTimeout = 2_000
            val reader = socket.getInputStream().bufferedReader()
            val writer = socket.getOutputStream().bufferedWriter()
            fun ask(command: String): String? = try {
                writer.write(command)
                writer.newLine()
                writer.flush()
                reader.readLine()
            } catch (_: Exception) {
                null
            }
            val stats = ask("GET_STATS")?.let { runCatching { JSONObject(it) }.getOrNull() }
            val offers = ask("GET_FOTA_UPDATES")?.let { runCatching { JSONArray(it) }.getOrNull() }
            return mapOf(
                "running" to true,
                "blocked" to stats?.optLong("blocked"),
                "inBytes" to stats?.optLong("incBytes"),
                "outBytes" to stats?.optLong("outBytes"),
                "offerCount" to offers?.length(),
                "offers" to offers?.let { arr -> (0 until minOf(arr.length(), MAX_OFFERS)).mapNotNull { offer(arr.optJSONObject(it)) } },
            )
        }
    }

    private fun offer(o: JSONObject?): Map<String, Any?>? {
        if (o == null) return null
        val upgrades = o.optJSONArray("upgrades") ?: JSONArray()
        return mapOf(
            "at" to o.optLong("timestamp"),
            "reminder" to o.optBoolean("isReminder"),
            "upgrades" to (0 until upgrades.length()).mapNotNull { i ->
                upgrades.optJSONObject(i)?.let { u ->
                    mapOf(
                        "component" to u.optString("componentType"),
                        "from" to u.optString("currentVersion"),
                        "to" to u.optString("nextVersion"),
                        "size" to u.optLong("packageSize"),
                    )
                }
            },
        )
    }
}
