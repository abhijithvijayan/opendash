package `in`.abhijithvijayan.opendash.hhmis

import android.os.IBinder
import android.os.Parcel

/// Client side of `com.android.hmiserverapp.IClientServiceInterface`.
///
/// Hand-rolled instead of generated from .aidl: the real interface carries
/// Parcelable enums and five foreign parcelable types (sound customisations,
/// ProfileData, PopUpCommand) that we would otherwise have to reproduce
/// byte-for-byte. Transaction codes and parcel layout come from the stock
/// HHMIS stub. The HMI command methods are oneway there; the rest expect a
/// reply with `writeNoException`.
class HhmisProxy(private val remote: IBinder) {
    companion object {
        const val DESCRIPTOR = "com.android.hmiserverapp.IClientServiceInterface"
        private const val TX_ADD_CALLBACK = 1
        private const val TX_REMOVE_CALLBACK = 2
        private const val TX_PASSCODE_ENTERED = 3
        private const val TX_SYSTEM_BRIGHTNESS = 4
        private const val TX_SUBSCRIBE_UPDATES = 5

        // Never sent, and no method here may be added for them:
        //   8  download()              the dashboard's consent to a firmware download
        //   9  install()               its consent to the install
        //   10 triggerReceviedOnHMI()  "the dashboard has shown the notice", which
        //                              also unlocks the phone app's download button
        // HOTA has no "decline": it waits, with no timeout, for a dashboard to
        // make these calls. Not making them is how OpenDash says no. A rider who wants the
        // update makes them in the stock dashboard.
        // test/firmware_never_sent_test.dart fails if they appear.
        private const val TX_UPDATE_VOLUME = 11
        private const val TX_UPDATE_MOTOR_VOLUME = 12
        private const val TX_UPDATE_CHIME_VOLUME = 13
        private const val TX_VOID_CMD = 14
        private const val TX_BOOL_CMD = 15
        private const val TX_INT_CMD = 16
        private const val TX_STRING_CMD = 17
    }

    val isAlive: Boolean get() = remote.isBinderAlive

    fun addCallback(callback: IBinder) = transact(TX_ADD_CALLBACK, oneway = false) { writeStrongBinder(callback) }

    fun removeCallback(callback: IBinder) = transact(TX_REMOVE_CALLBACK, oneway = false) { writeStrongBinder(callback) }

    /// Registers [callback] (an `IOTAInterface`) in HHMIS's one update slot.
    /// HHMIS only stores it (`OtaManager.setToClient`): the stock dashboard
    /// overwrites it when it next connects.
    fun subscribeToUpdateTrigger(callback: IBinder) =
        transact(TX_SUBSCRIBE_UPDATES, oneway = false) { writeStrongBinder(callback) }

    fun voidCmd(cmd: Int) = transact(TX_VOID_CMD, oneway = true) { writeCmd(cmd) }

    fun intCmd(cmd: Int, value: Int) = transact(TX_INT_CMD, oneway = true) {
        writeCmd(cmd)
        writeInt(value)
    }

    fun boolCmd(cmd: Int, value: Boolean) = transact(TX_BOOL_CMD, oneway = true) {
        writeCmd(cmd)
        writeInt(if (value) 1 else 0)
    }

    fun stringCmd(cmd: Int, value: String) = transact(TX_STRING_CMD, oneway = true) {
        writeCmd(cmd)
        writeString(value)
    }

    fun updateVolume(level: Int) = transact(TX_UPDATE_VOLUME, oneway = false) { writeInt(level) }

    /// [level] is stock's 0-14 slider. HHMIS sets alarm-stream volume
    /// round(level / 2) (0-7), persists it as INT_ENGINE_SOUND, and mutes
    /// the engine sound at 0 (`SettingsServerConnection.setMotorVolume`).
    fun updateMotorVolume(level: Int) = transact(TX_UPDATE_MOTOR_VOLUME, oneway = false) { writeInt(level) }

    /// As [updateMotorVolume] for the notification stream / INT_CHIME_VOLUME
    /// (`SettingsServerConnection.setChimeVolume`).
    fun updateChimeVolume(level: Int) = transact(TX_UPDATE_CHIME_VOLUME, oneway = false) { writeInt(level) }

    fun updateSystemBrightness(level: Int, persist: Boolean) = transact(TX_SYSTEM_BRIGHTNESS, oneway = false) {
        writeInt(level)
        writeInt(if (persist) 1 else 0)
    }

    /// [verifyOnly] mirrors the stock change-passcode flow: true checks the
    /// code without unlocking; false is the lock-screen unlock.
    fun onPasscodeEntered(code: String, verifyOnly: Boolean) = transact(TX_PASSCODE_ENTERED, oneway = false) {
        writeString(code)
        writeInt(if (verifyOnly) 1 else 0)
    }

    private fun Parcel.writeCmd(ordinal: Int) {
        writeInt(1)
        writeInt(ordinal)
    }

    private inline fun transact(code: Int, oneway: Boolean, write: Parcel.() -> Unit) {
        val data = Parcel.obtain()
        val reply = if (oneway) null else Parcel.obtain()
        try {
            data.writeInterfaceToken(DESCRIPTOR)
            data.write()
            remote.transact(code, data, reply, if (oneway) IBinder.FLAG_ONEWAY else 0)
            reply?.readException()
        } finally {
            reply?.recycle()
            data.recycle()
        }
    }
}
