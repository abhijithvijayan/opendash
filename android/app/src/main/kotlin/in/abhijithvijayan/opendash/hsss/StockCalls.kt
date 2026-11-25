package `in`.abhijithvijayan.opendash.hsss

/// The numbers behind the stock names OpenDash uses on one service: per
/// table (an AIDL interface, or an enum), each name's transaction code or
/// ordinal. Dart sends names; a number is looked up here, in the table of
/// the service installed on this scooter when that could be read
/// ([source] `read`), else in the built-in one (`builtin`).
///
/// A name the table does not have has no number: nothing is guessed from
/// the built-in table once the service itself has been read.
class StockCalls(val source: String, private val tables: Map<String, Map<String, Int>>) {
    companion object {
        const val READ = "read"
        const val BUILTIN = "builtin"

        fun of(builtin: Map<String, Map<String, Int>>, read: Map<String, Map<String, Int>>?) =
            if (read == null) StockCalls(BUILTIN, builtin) else StockCalls(READ, read)
    }

    fun code(table: String, name: String): Int? = tables[table]?.get(name)

    fun need(table: String, name: String): Int =
        code(table, name) ?: throw NoSuchMethodException("$table.$name is not in this scooter's service")

    /// Every name of [builtin] whose number here is another one, or which
    /// is not here at all (`read` null): what goes to the log on each bind.
    fun differences(builtin: Map<String, Map<String, Int>>): List<Map<String, Any?>> =
        builtin.flatMap { (table, names) ->
            names.filter { (name, number) -> code(table, name) != number }
                .map { (name, number) -> mapOf("name" to "$table.$name", "builtin" to number, "read" to code(table, name)) }
        }
}

/// HSSS (`com.olaelectric.connectivityservice`): the four interfaces
/// `SystemSettingsClient` speaks, by stock method name.
object HsssCalls {
    const val PACKAGE = "com.olaelectric.connectivityservice"
    const val CLASSES = "com.olaelectric.systemsettings"
    const val SYSTEM = "ISystemSettings"
    const val BLUETOOTH = "IBluetoothSettings"
    const val PAIRING = "IPairingStatusUpdate"
    const val CALL = "ICallState"
    val INTERFACES = listOf(SYSTEM, BLUETOOTH, PAIRING, CALL)

    const val GET_BLUETOOTH_SETTINGS = "getBluetoothSettings"
    const val SET_BT_INFO_MANAGER = "setBTInfoManager"
    const val REGISTER_RECEIVERS = "registerReceivers"
    const val SUBSCRIBE_CALL_STATUS = "subscribeCallStatusCallback"
    const val ON_CALL_STATE_CHANGED = "onCallStateChanged"
    const val ON_CALL_AUTO_REJECTED = "onCallAutoRejected"

    /// The data calls `hsss_bluetooth.dart` builds (a test compares the two
    /// lists). Not here, and so never sent whatever the service's table
    /// says: `unregisterReceivers` and `unregisterAllBtProfiles`, which
    /// silence HSSS for every client, and `pairingPopUp`, which always
    /// throws.
    val ALLOWED = setOf(
        "enableBT", "isBtEnabled", "pairingAction", "forgetDevice", "disconnectDevice", "connectDevice", "callAction",
        "registerAllBtProfiles", "setScanMode", "setAllBtProfilesPriority", "getBondedDevices", "isBTProfileNull",
        "getConnectionState", "getScanMode", "enablePhoneCalls",
    )

    /// `IPairingStatusUpdate` methods as the events Dart hears.
    val PAIRING_EVENTS = mapOf(
        "disablePairingPopUp" to "dismiss",
        "showPairFailPopUp" to "fail",
        "updateBTPairingPin" to "pin",
        "enablePairingPopUp" to "popup",
    )

    /// The numbers in HSSS 4.6.x, which the 5.0.2 dashboard's copy of the
    /// interfaces also has.
    val BUILTIN = mapOf(
        SYSTEM to mapOf(GET_BLUETOOTH_SETTINGS to 6),
        BLUETOOTH to mapOf(
            SET_BT_INFO_MANAGER to 0x2,
            REGISTER_RECEIVERS to 0x4,
            SUBSCRIBE_CALL_STATUS to 0x2c,
            "enableBT" to 0x8,
            "isBtEnabled" to 0xa,
            "pairingAction" to 0xb,
            "forgetDevice" to 0x15,
            "disconnectDevice" to 0x16,
            "connectDevice" to 0x17,
            "callAction" to 0x18,
            "registerAllBtProfiles" to 0x19,
            "setScanMode" to 0x1c,
            "setAllBtProfilesPriority" to 0x1f,
            "getBondedDevices" to 0x25,
            "isBTProfileNull" to 0x33,
            "getConnectionState" to 0x35,
            "getScanMode" to 0x37,
            "enablePhoneCalls" to 0x38,
        ),
        PAIRING to mapOf("disablePairingPopUp" to 1, "showPairFailPopUp" to 2, "updateBTPairingPin" to 3, "enablePairingPopUp" to 4),
        CALL to mapOf(ON_CALL_STATE_CHANGED to 1, ON_CALL_AUTO_REJECTED to 2),
    )

    fun resolve(read: Map<String, Map<String, Int>>?) = StockCalls.of(BUILTIN, read)

    /// The code of a data call Dart asked for by name. Throws for a name
    /// outside [ALLOWED], and for one this scooter's service does not have.
    fun dataCall(calls: StockCalls, method: String): Int {
        require(method in ALLOWED) { "$method is not allowed" }
        return calls.need(BLUETOOTH, method)
    }

    /// The pairing callback's transaction codes on this service, each with
    /// its event.
    fun pairingEvents(calls: StockCalls): Map<Int, String> =
        PAIRING_EVENTS.mapNotNull { (method, event) -> calls.code(PAIRING, method)?.let { it to event } }.toMap()
}

/// HPMS (`com.olaelectric.profilemanagerservice`): `updateInt` and the two
/// profile values behind "calls on the dashboard", by `ProfileManagerCmd`
/// name.
object HpmsCalls {
    const val PACKAGE = "com.olaelectric.profilemanagerservice"
    const val CLASSES = "com.olaelectric.pmservice"
    const val SERVICE = "IProfileManagerService"
    const val CMD = "ProfileManagerCmd"
    const val UPDATE_INT = "updateInt"

    /// The only profile values OpenDash writes.
    val ALLOWED = setOf("INT_SYNC_CONTACTS", "INT_SYNC_CONTACTS_PERMISSION")

    /// The numbers in HPMS 4.6.x; the 5.0.2 dashboard's copy has the same
    /// three.
    val BUILTIN = mapOf(
        SERVICE to mapOf(UPDATE_INT to 8),
        CMD to mapOf("INT_SYNC_CONTACTS" to 38, "INT_SYNC_CONTACTS_PERMISSION" to 39),
    )

    fun resolve(read: Map<String, Map<String, Int>>?) = StockCalls.of(BUILTIN, read)

    /// `updateInt`'s transaction code and the ordinal of [cmd]. Throws for
    /// a value outside [ALLOWED], and for a name this scooter's service
    /// does not have.
    fun updateInt(calls: StockCalls, cmd: String): Pair<Int, Int> {
        require(cmd in ALLOWED) { "$cmd is not allowed" }
        return calls.need(SERVICE, UPDATE_INT) to calls.need(CMD, cmd)
    }
}
