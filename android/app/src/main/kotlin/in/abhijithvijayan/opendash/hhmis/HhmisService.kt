package `in`.abhijithvijayan.opendash.hhmis

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.RemoteException
import android.util.Log
import `in`.abhijithvijayan.opendash.Analytics
import kotlin.math.min

/// Finds out which build of HHMIS this scooter has ([StockContract]), and
/// only then binds it, registers the callback, and hands every update to [sink]
/// on the main thread as a `{name: value}` map keyed by ServerCmd name.
/// Bursts of binder callbacks are coalesced into one map per main-looper
/// turn so the Flutter side sees at most one event per frame, except that
/// a repeat of an [EVENT_KEYS] key starts a new map: those are events, and
/// keeping only the last would drop one (two vehicle commands, a double
/// music press, ESCL fail then success).
///
/// Special keys, all prefixed with `_`: `_connected` (Boolean),
/// `_passcode` (`{success, remaining}`), `_unlocked`, `_volume`,
/// `_rangeByMode` (`[eco, normal, sport, hyper]`), `_vdpMissing`,
/// `_hwInfo_<id>` (TX 2 hardware info, one String key per id),
/// `_notificationPopup` (TX 14, `{id, type, status}`),
/// `_sunTimes` (TX 8, `{sunrise, sunset}`), `_motorVolume` and
/// `_chimeVolume` (TX 10 / 11, 0-7), `_popupCommand` (TX 12,
/// `{id, header, content, icon}`), `_fw` (a firmware update callback, see
/// `OtaDecoder`).
class HhmisService(
    private val context: Context,
    private val sink: (Map<String, Any?>) -> Unit,
) : HhmisListener {
    companion object {
        private const val TAG = "HhmisService"
        val COMPONENT = ComponentName("com.android.hmiserverapp", "com.android.hmiserverapp.VehicleParserService")
        private val BACKOFF_SECONDS = longArrayOf(1, 2, 4, 8, 16, 30)
        val EVENT_KEYS = setOf(
            "INT_VEHICLE_COMMAND", "INT_BT_MUSIC_COMMAND", "INT_VEHICLE_ESCL_STATUS",
            "INT_VEHICLE_STATE",
            "INT_TOW_THEFT_DETECTION_ALERT", "INT_THERMAL_RUNAWAY", "BOOL_PROFILE_PASSCODE_CHANGED_ACK",
            "INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST", "BOOL_BT_CALL_HANDLE_REQUEST",
            "_passcode", "_unlocked", "_notificationPopup", "_popupCommand", "_fw",
        )
    }

    private val main = Handler(Looper.getMainLooper())
    private val callback = HhmisCallback(this)
    private val otaCallback = HhmisOtaCallback { emit("_fw", it) }
    private val pending = ArrayList<HashMap<String, Any?>>()
    private var flushQueued = false
    @Volatile
    private var proxy: HhmisProxy? = null
    private var binder: IBinder? = null
    private var bound = false
    private var started = false

    /// Null until the scooter's service has been identified: no event is
    /// named and no command numbered before that.
    @Volatile
    private var contract: StockContract? = null
    private var attempt = 0
    private var connectedAt = 0L

    /// A HHMIS death can deliver both the death recipient and
    /// onServiceDisconnected; only the first one counts until the next bind.
    private var lost = false

    @Volatile
    var connected = false
        private set

    private val deathRecipient = IBinder.DeathRecipient { main.post { onLost("binder died") } }

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, service: IBinder) {
            val p = HhmisProxy(service)
            try {
                service.linkToDeath(deathRecipient, 0)
            } catch (e: RemoteException) {
                Log.w(TAG, "linkToDeath failed: $e")
                Analytics.log("hhmis", "kotlin_remote_exception", mapOf("method" to "linkToDeath", "error" to e.toString()))
                onLost("linkToDeath failed")
                return
            }
            // Stored before addCallback so dropBinder can unlink on any failure.
            binder = service
            proxy = p
            // addCallback runs HHMIS's setStarTup on its side (SharedPrefs
            // write + callback); anything it throws comes back through
            // readException and would otherwise kill us on the main thread.
            try {
                p.addCallback(callback)
            } catch (e: RemoteException) {
                Log.w(TAG, "addCallback failed: $e")
                Analytics.log("hhmis", "kotlin_remote_exception", mapOf("method" to "addCallback", "error" to e.toString()))
                onLost("addCallback failed")
                return
            } catch (e: RuntimeException) {
                Log.w(TAG, "addCallback threw: $e")
                Analytics.log("hhmis", "kotlin_runtime_exception", mapOf("method" to "addCallback", "error" to e.toString()))
                onLost("addCallback threw")
                return
            }
            // Only now: while addCallback keeps throwing the backoff must grow,
            // since each failed pass unbinds (and restarts HHMIS when we are
            // its only client).
            attempt = 0
            connectedAt = System.currentTimeMillis()
            Analytics.log("hhmis", "kotlin_bind_ok", mapOf("components" to name.flattenToShortString()))
            setConnected(true)
        }

        override fun onServiceDisconnected(name: ComponentName) = onLost("disconnected")

        override fun onBindingDied(name: ComponentName) = onLost("binding died")

        override fun onNullBinding(name: ComponentName) {
            Analytics.log("hhmis", "kotlin_bind_failed", mapOf("error" to "null binding", "selinux" to Analytics.selinux()))
            onLost("null binding")
        }
    }

    private val rebind = Runnable { bind() }

    fun start() {
        started = true
        attempt = 0
        if (contract != null) {
            bind()
            return
        }
        // Reading another package's classes is disk work: off the main
        // thread, and the bind waits for it.
        Thread {
            val version = StockReader.version(context)
            val identified = StockContract.identify(version, StockReader.read(context, version))
            main.post {
                contract = identified
                Analytics.log(
                    "hhmis", "kotlin_contract",
                    mapOf(
                        "version" to identified.version, "source" to identified.source, "name" to identified.name,
                        "checked" to identified.checked, "digest" to identified.digest,
                        "commands" to identified.commands.size, "events" to identified.events.size,
                    ),
                )
                emit("_contract", identified.facts())
                bind()
            }
        }.start()
    }

    fun stop() {
        started = false
        main.removeCallbacks(rebind)
        // No removeCallback: HHMIS clears its single client slot whoever
        // holds it, which would silence the stock dashboard too.
        dropBinder()
        unbind()
        setConnected(false)
    }

    /// Re-registers our callback on the live binder so HHMIS points its single
    /// client slot back at us (HHMIC's addCallback overwrites it). No unbind
    /// and no removeCallback: those would silence the stock dashboard or
    /// destroy HHMIS when we are its only client.
    ///
    /// HHMIS's addCallback runs setStarTup -> setPark -> fire(), which forces
    /// INT_VEHICLE_STATE=LOCK until the next vehicle-mode frame (~100 ms)
    /// restores the real state. Only call this when the data is already
    /// suspect, never as a routine ping.
    fun reattachCallback(): Boolean {
        val p = proxy ?: return false
        return try {
            p.addCallback(callback)
            Analytics.log("hhmis", "kotlin_reattach_ok", mapOf<String, Any?>())
            true
        } catch (e: RemoteException) {
            Log.w(TAG, "reattachCallback failed: $e")
            Analytics.log("hhmis", "kotlin_remote_exception", mapOf("method" to "reattachCallback", "error" to e.toString()))
            false
        } catch (e: RuntimeException) {
            Log.w(TAG, "reattachCallback threw: $e")
            Analytics.log("hhmis", "kotlin_runtime_exception", mapOf("method" to "reattachCallback", "error" to e.toString()))
            false
        }
    }

    /// Puts our update callbacks in HHMIS's one update slot, to watch only.
    /// Asked for by Dart after each bind and each reattach, so the rider's
    /// "restore stock update settings" can stop it.
    fun subscribeUpdates(): Boolean = command { subscribeToUpdateTrigger(otaCallback) } == true

    /// Sends the stock command called [name] under the number this
    /// scooter's service has for it. False when the service has not been
    /// identified yet, has no such command, or the command is one OpenDash
    /// never sends.
    fun send(name: String, block: HhmisProxy.(Int) -> Unit): Boolean? {
        val number = if (name in StockContract.NEVER_SENT) null else contract?.command(name)
        if (number == null) {
            Analytics.log("hhmis", "kotlin_cmd_no_number", mapOf("cmd" to name, "identified" to (contract != null)))
            return false
        }
        return command { block(number) }
    }

    /// Runs [block] against the live proxy; false when HHMIS is not bound
    /// or the binder call failed, null when HHMIS itself threw (it was
    /// reachable, so "not connected" would be the wrong thing to tell the rider).
    fun command(block: HhmisProxy.() -> Unit): Boolean? {
        val p = proxy ?: return false
        return try {
            p.block()
            true
        } catch (e: RemoteException) {
            Log.w(TAG, "command failed: $e")
            Analytics.log("hhmis", "kotlin_remote_exception", mapOf("method" to "command", "error" to e.toString()))
            false
        } catch (e: RuntimeException) {
            Log.w(TAG, "command threw: $e")
            Analytics.log("hhmis", "kotlin_runtime_exception", mapOf("method" to "command", "error" to e.toString()))
            null
        }
    }

    private fun bind() {
        if (!started) return
        lost = false
        Analytics.log("hhmis", "bind_attempt", mapOf("attempt" to attempt))
        var error: String? = null
        val ok = try {
            context.bindService(Intent().setComponent(COMPONENT), connection, Context.BIND_AUTO_CREATE)
        } catch (e: SecurityException) {
            // HHMIS 4.6.14 exports the service with an empty permission, so
            // this does not fire on current firmware. Another build could
            // guard it; keep retrying so a later grant is picked up.
            Log.w(TAG, "bind refused: $e")
            error = e.toString()
            false
        }
        bound = ok
        if (!ok) {
            Analytics.log(
                "hhmis", "kotlin_bind_failed",
                mapOf("error" to (error ?: "bindService returned false"), "selinux" to Analytics.selinux()),
            )
            // The platform asks for the connection to be released even when
            // bindService returns false; unbind() would skip it (bound is false).
            try {
                context.unbindService(connection)
            } catch (_: IllegalArgumentException) {
            }
            scheduleRebind()
        }
    }

    private fun onLost(reason: String) {
        if (lost) return
        lost = true
        Log.i(TAG, "HHMIS lost: $reason")
        val upFor = if (connectedAt == 0L) -1 else (System.currentTimeMillis() - connectedAt) / 1000
        connectedAt = 0L
        Analytics.log("hhmis", "kotlin_lost", mapOf("reason" to reason, "up_for_s" to upFor))
        dropBinder()
        unbind()
        setConnected(false)
        scheduleRebind()
    }

    private fun dropBinder() {
        try {
            binder?.unlinkToDeath(deathRecipient, 0)
        } catch (_: NoSuchElementException) {
        }
        binder = null
        proxy = null
    }

    private fun unbind() {
        if (!bound) return
        bound = false
        try {
            context.unbindService(connection)
        } catch (_: IllegalArgumentException) {
        }
    }

    private fun scheduleRebind() {
        if (!started) return
        main.removeCallbacks(rebind)
        val delay = BACKOFF_SECONDS[min(attempt, BACKOFF_SECONDS.size - 1)]
        attempt++
        Analytics.log("hhmis", "rebind_scheduled", mapOf("delay_s" to delay, "attempt" to attempt))
        main.postDelayed(rebind, delay * 1000)
    }

    private fun setConnected(on: Boolean) {
        connected = on
        emit("_connected", on)
    }

    /// Last INT_VEHICLE_STATE value we logged; stable-state repeats are
    /// dropped (one ride log: 43k events in 33 min when logging every
    /// emission, 85% of the log file). A real 6->0->6 collapse still shows
    /// as three transitions here vs one in Dart.
    @Volatile
    private var lastRawState: Int? = null

    override fun onUpdate(ordinal: Int, value: Any?) {
        val contract = contract ?: return
        val name = contract.event(ordinal)
        // Proves the raw sequence pre-coalescing. Log only when the
        // value actually changes, otherwise a steady CHARGING state spams
        // the log at the HHMIS tick rate.
        if (name == "INT_VEHICLE_STATE" && value is Int && value != lastRawState) {
            Analytics.log("hhmis", "kotlin_raw_state", mapOf("from" to lastRawState, "to" to value))
            lastRawState = value
        }
        // The two values that are positions in a stock list leave here as
        // the app's own numbers.
        val out = when {
            value !is Int -> value
            name == "INT_VEHICLE_STATE" -> contract.appState(value)
            name == "INT_VEHICLE_COMMAND" -> contract.appVehicleCommand(value).also {
                if (it < 0) {
                    Analytics.log(
                        "hhmis", "kotlin_vehicle_command_unknown",
                        mapOf("wire" to value, "name" to contract.vehicleCommands.getOrNull(value)),
                    )
                }
            }
            else -> value
        }
        emit(name, out ?: true)
    }

    override fun onPasscodeVerify(success: Boolean, remainingAttempts: Int) =
        emit("_passcode", mapOf("success" to success, "remaining" to remainingAttempts))

    override fun onScooterUnlocked() = emit("_unlocked", true)

    override fun onVolumeUpdate(level: Int) = emit("_volume", level)

    override fun onRangeByMode(normal: Int, hyper: Int, sport: Int, eco: Int) =
        emit("_rangeByMode", listOf(eco, normal, sport, hyper))

    override fun onVdpCallbackMissing() = emit("_vdpMissing", true)

    // One key per id: HHMIS sends ids in pairs 1-3 ms apart, which a single
    // `_hwInfo` key would coalesce down to the last one (and the VIN, sent
    // rarely, could be lost for the whole session).
    override fun onHardwareInfo(id: Int, value: String) = emit("_hwInfo_$id", value)

    override fun onNotificationPopup(id: Int, type: Int, status: Boolean) =
        emit("_notificationPopup", mapOf("id" to id, "type" to type, "status" to status))

    // One key per id, as for hardware info: the two ids arrive 1 ms apart.

    override fun onSunTimes(sunrise: String, sunset: String) =
        emit("_sunTimes", mapOf("sunrise" to sunrise, "sunset" to sunset))

    override fun onMotorVolume(level: Int) = emit("_motorVolume", level)

    override fun onChimeVolume(level: Int) = emit("_chimeVolume", level)

    override fun onPopUpCommand(id: Int?, header: String?, content: String?, iconId: Int?) =
        emit("_popupCommand", mapOf("id" to id, "header" to header, "content" to content, "icon" to iconId))

    private fun emit(key: String, value: Any?) {
        synchronized(pending) {
            val last = pending.lastOrNull()
            val batch = if (last == null || (key in EVENT_KEYS && last.containsKey(key))) {
                HashMap<String, Any?>().also { pending.add(it) }
            } else {
                last
            }
            batch[key] = value
            if (flushQueued) return
            flushQueued = true
        }
        main.post(flush)
    }

    private val flush = Runnable {
        val batches: List<Map<String, Any?>>
        synchronized(pending) {
            batches = ArrayList(pending)
            pending.clear()
            flushQueued = false
        }
        for (batch in batches) sink(batch)
    }
}
