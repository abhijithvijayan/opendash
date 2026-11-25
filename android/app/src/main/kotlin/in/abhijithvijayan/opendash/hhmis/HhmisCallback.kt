package `in`.abhijithvijayan.opendash.hhmis

import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.util.Log
import `in`.abhijithvijayan.opendash.Analytics

interface HhmisListener {
    /// [value] is Int, Float, String, Boolean, or null for a void update.
    fun onUpdate(ordinal: Int, value: Any?)
    fun onPasscodeVerify(success: Boolean, remainingAttempts: Int)
    fun onScooterUnlocked()
    fun onVolumeUpdate(level: Int)
    fun onRangeByMode(normal: Int, hyper: Int, sport: Int, eco: Int)
    fun onVdpCallbackMissing()

    /// TX 2 `onUpdateHardwareInfo(int id, String value)`. [id] is one of the
    /// `HardwareInfoId` constants (0 BCM, 1 BMS, 2 BLE, 3 HU, 4 HBC, 5 MCU,
    /// 6 VIN, 0x14-0x16 bootloaders). The field is persistent on the vehicle
    /// but HHMIS re-broadcasts it periodically (observed ~1 Hz), so a cold
    /// start sees every id within seconds.
    fun onHardwareInfo(id: Int, value: String)

    /// TX 14 `showNotificationPopup(int id, int type, boolean status)`. [id]
    /// is stock HHMIC's `Constants.NotificationPopupId` (6 = unplug charger to
    /// ride, 4 = hold brakes, ...); [type] 1 is a state popup shown while
    /// [status] holds, anything else a timed toast.
    fun onNotificationPopup(id: Int, type: Int, status: Boolean)

    /// TX 8 `onSunriseSunsetTimeUpdate(String, String)`, both
    /// "yyyy-MM-dd HH:mm:ss" local time (stock `SettingsInfoManager.df`).
    fun onSunTimes(sunrise: String, sunset: String)

    /// TX 10 `onMotorVolumeUpdate(int)` / TX 11 `onPersistedChimeVolumeUpdate(int)`:
    /// the persisted stream level, 0-7.
    fun onMotorVolume(level: Int)
    fun onChimeVolume(level: Int)

    /// TX 12 `onPopUpCommandReceived(PopUpCommand)`. Its only sender is the
    /// cloud battery-health popup; stock HHMIC's handler is empty.
    fun onPopUpCommand(id: Int?, header: String?, content: String?, iconId: Int?)
}

/// Server side of `com.android.hmiserverapp.IClientServiceInterfaceCallback`.
/// Codes 16-20 are oneway in the stock stub; the others reply with
/// `writeNoException`, which is what `reply != null` tells us. Calls we do
/// not model (profile data, party mode) are acknowledged and dropped.
class HhmisCallback(private val listener: HhmisListener) : Binder() {
    companion object {
        const val DESCRIPTOR = "com.android.hmiserverapp.IClientServiceInterfaceCallback"
        private const val TAG = "HhmisCallback"
        private const val TX_PASSCODE_VERIFY = 1
        private const val TX_HARDWARE_INFO = 2
        private const val TX_WIDGET_INFO = 3
        private const val TX_SCOOTER_UNLOCKED = 6
        private const val TX_SUN_TIMES = 8
        private const val TX_VOLUME_UPDATE = 9
        private const val TX_MOTOR_VOLUME = 10
        private const val TX_CHIME_VOLUME = 11
        private const val TX_POPUP_COMMAND = 12
        private const val TX_RANGE_BY_MODE = 13
        private const val TX_NOTIFICATION_POPUP = 14
        private const val TX_VDP_MISSING = 15
        private const val TX_VOID_UPDATE = 16
        private const val TX_BOOL_UPDATE = 17
        private const val TX_INT_UPDATE = 18
        private const val TX_STRING_UPDATE = 19
        private const val TX_FLOAT_UPDATE = 20
        private const val MAX_DROPPED_LOGS = 20
    }

    private val droppedLogged = HashMap<Int, Int>()

    init {
        attachInterface(null, DESCRIPTOR)
    }

    override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
        if (code < IBinder.FIRST_CALL_TRANSACTION || code > IBinder.LAST_CALL_TRANSACTION) {
            return super.onTransact(code, data, reply, flags)
        }
        try {
            data.enforceInterface(DESCRIPTOR)
            when (code) {
                TX_PASSCODE_VERIFY -> {
                    val ok = data.readInt() != 0
                    listener.onPasscodeVerify(ok, data.readInt())
                }
                TX_HARDWARE_INFO -> {
                    val id = data.readInt()
                    val v = data.readString() ?: ""
                    listener.onHardwareInfo(id, v)
                }
                // CO2 avoided / tree growth: not used, and stock only logs it.
                TX_WIDGET_INFO -> {}
                TX_SCOOTER_UNLOCKED -> listener.onScooterUnlocked()
                TX_SUN_TIMES -> {
                    val sunrise = data.readString() ?: ""
                    listener.onSunTimes(sunrise, data.readString() ?: "")
                }
                TX_VOLUME_UPDATE -> listener.onVolumeUpdate(data.readInt())
                TX_MOTOR_VOLUME -> listener.onMotorVolume(data.readInt())
                TX_CHIME_VOLUME -> listener.onChimeVolume(data.readInt())
                // Presence flag, then HHMIS's `PopUpCommand.writeToParcel`:
                // four `writeValue`s (popUpId, popUpHeader, popUpContent,
                // iconId). Not HHMIC's class of the same name, which reads
                // a different layout.
                TX_POPUP_COMMAND -> if (data.readInt() != 0) {
                    val id = data.readValue(null) as? Int
                    val header = data.readValue(null) as? String
                    val content = data.readValue(null) as? String
                    listener.onPopUpCommand(id, header, content, data.readValue(null) as? Int)
                }
                TX_RANGE_BY_MODE -> {
                    val a = data.readInt()
                    val b = data.readInt()
                    val c = data.readInt()
                    listener.onRangeByMode(a, b, c, data.readInt())
                }
                TX_VDP_MISSING -> listener.onVdpCallbackMissing()
                TX_NOTIFICATION_POPUP -> {
                    val id = data.readInt()
                    val type = data.readInt()
                    listener.onNotificationPopup(id, type, data.readInt() != 0)
                }
                TX_VOID_UPDATE -> readCmd(data)?.let { listener.onUpdate(it, null) }
                TX_BOOL_UPDATE -> {
                    val cmd = readCmd(data)
                    val v = data.readInt() != 0
                    cmd?.let { listener.onUpdate(it, v) }
                }
                TX_INT_UPDATE -> {
                    val cmd = readCmd(data)
                    val v = data.readInt()
                    cmd?.let { listener.onUpdate(it, v) }
                }
                TX_STRING_UPDATE -> {
                    val cmd = readCmd(data)
                    val v = data.readString() ?: ""
                    cmd?.let { listener.onUpdate(it, v) }
                }
                TX_FLOAT_UPDATE -> {
                    val cmd = readCmd(data)
                    val v = data.readFloat()
                    cmd?.let { listener.onUpdate(it, v) }
                }
                else -> noteDropped(code, data)
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "dropped callback $code: $e")
        }
        reply?.writeNoException()
        return true
    }

    /// Unmodelled callbacks are acknowledged and dropped; the first few of
    /// each code are logged with the payload size and a best-effort guess
    /// at the first few scalars so a later decompile can line up the
    /// structure. We capture ints and the start of any string; floats look
    /// identical to ints at this level, so interpret with care.
    // TODO(unmodelled-callbacks): the logged scalars are a guess at the layout. Read each code's real parcel from
    // the stock service before using any of it.
    private fun noteDropped(code: Int, data: Parcel) {
        // onTransact runs on the binder pool; synchronous callbacks from
        // different HHMIS threads can overlap.
        synchronized(droppedLogged) {
            val seen = droppedLogged[code] ?: 0
            if (seen >= MAX_DROPPED_LOGS) return
            droppedLogged[code] = seen + 1
        }
        val len = data.dataAvail()
        // Snapshot the parcel so the reads don't consume the real data.
        val pos = data.dataPosition()
        val ints = ArrayList<Int>()
        try {
            repeat(minOf(4, len / 4)) { ints.add(data.readInt()) }
        } catch (_: RuntimeException) {
        }
        data.setDataPosition(pos)
        Analytics.log("hhmis", "callback_unmodelled", mapOf("tx" to code, "len" to len, "ints" to ints))
    }

    /// A parcelled enum is a presence flag followed by its ordinal.
    private fun readCmd(data: Parcel): Int? = if (data.readInt() != 0) data.readInt() else null
}
