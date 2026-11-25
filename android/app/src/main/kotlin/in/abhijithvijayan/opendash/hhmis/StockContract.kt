package `in`.abhijithvijayan.opendash.hhmis

import java.security.MessageDigest

/// The numbering of one build of the stock vehicle service: its commands,
/// events, vehicle states and vehicle commands as lists of stock names in
/// their own order (a name's place is its number on the wire), and the
/// transaction codes of its three interfaces.
///
/// Dart never sees one of these numbers. It sends a command by name and
/// receives events by name; the two values that are themselves positions
/// in a stock list, the vehicle state and the vehicle command, are turned
/// here into the app's own numbers ([APP_STATES],
/// [StockFixtures.APP_VEHICLE_COMMANDS]), which never change.
///
/// [source] says where the lists came from: `read` from the service
/// installed on this scooter, `fixture` from a recorded build of the same
/// version when that could not be read, `assumed` when neither was
/// possible and the checked build's lists are used so the screen has
/// something to show. Whether commands may then be sent is Dart's decision.
class StockContract(
    val name: String,
    val version: String,
    val source: String,
    val checked: Boolean,
    val fallbackFor: String = "",
    val recordedDigest: String = "",
    val commands: List<String>,
    val events: List<String>,
    val states: List<String>,
    val vehicleCommands: List<String>,
    val calls: Map<String, Map<String, Int>>,
) {
    companion object {
        /// The vehicle states as the app numbers them: stock 4.6.14's
        /// first seven, then what later software added.
        val APP_STATES = listOf("LOCK", "ALARM", "PASSCODE", "PARK", "MOTOR_ON", "REVERSE", "CHARGING", "PARK_ASSIST")

        /// Never sent by OpenDash, whatever Dart asks for: each one acts on
        /// a firmware download or install in HOTA.
        val NEVER_SENT = setOf(
            "BOOL_INSTALL_ERROR_STAT",
            "VOID_CANCEL_DOWNLOAD",
            "VOID_CHECK_INSTALL_ERROR_STAT",
            "VOID_RETRY_DOWNLOAD",
        )

        /// Sent only by the rider's "Check now", through its own method.
        const val CHECK_FOR_UPDATE = "VOID_CHECK_FOR_UPDATE"
        const val TOUCH_STATUS = "BOOL_TOUCH_STATUS"

        val INTERFACES = listOf("IClientServiceInterface", "IClientServiceInterfaceCallback", "IOTAInterface")

        /// The contract to work with on a scooter whose service reports
        /// [version] and whose own lists are [read] (null: unreadable).
        fun identify(version: String, read: StockContract?, fixtures: List<StockContract> = StockFixtures.ALL): StockContract {
            if (read != null) {
                // Lists alone do not make a build: two builds can share them
                // (Gen 2's 5.0.4 and Gen 1's 5.0.2), and "checked" belongs to
                // the build that was ridden.
                val same = fixtures.firstOrNull { it.digest == read.digest && it.version == version }
                return read.copy(name = same?.name ?: "", checked = same?.checked ?: false)
            }
            val stand = fixtures.firstOrNull { it.fallbackFor.isNotEmpty() && version.startsWith(it.fallbackFor) }
            if (stand != null) return stand.copy(version = version, checked = stand.checked && stand.version == version)
            return fixtures.first { it.checked }.copy(name = "", version = version, source = "assumed", checked = false)
        }
    }

    /// The same text, line for line, as `digest` in
    /// scripts/check-head-unit-contract.py: two builds with one digest
    /// number everything alike, though each is still its own build.
    val digest: String by lazy {
        val lines = listOf("commands" to commands, "events" to events, "states" to states, "vehicleCommands" to vehicleCommands)
            .map { (key, names) -> "$key:${names.joinToString(",")}" } +
            calls.toSortedMap().flatMap { (iface, methods) -> methods.toSortedMap().map { (m, code) -> "$iface.$m=$code" } }
        MessageDigest.getInstance("SHA-256").digest(lines.joinToString("\n").toByteArray())
            .joinToString("") { "%02x".format(it) }
    }

    /// The number of the command called [name] on this build; null when it
    /// has none.
    fun command(name: String): Int? = commands.indexOf(name).takeIf { it >= 0 }

    fun event(ordinal: Int): String = events.getOrNull(ordinal) ?: "SERVER_CMD_$ordinal"

    /// A vehicle state number from this build as the app's own; -1 for one
    /// the app has no name for.
    fun appState(wire: Int): Int = APP_STATES.indexOf(states.getOrNull(wire))

    /// The same for a vehicle command (`INT_VEHICLE_COMMAND`).
    fun appVehicleCommand(wire: Int): Int = StockFixtures.APP_VEHICLE_COMMANDS.indexOf(vehicleCommands.getOrNull(wire))

    /// What Dart is told, as `_contract`: who the scooter is and which
    /// commands it has. Names only, no numbers.
    fun facts(): Map<String, Any?> = mapOf(
        "version" to version,
        "source" to source,
        "name" to name,
        "checked" to checked,
        "digest" to digest,
        "commands" to commands,
        "states" to states,
    )

    private fun copy(
        name: String = this.name,
        version: String = this.version,
        source: String = this.source,
        checked: Boolean = this.checked,
    ) = StockContract(name, version, source, checked, fallbackFor, recordedDigest, commands, events, states, vehicleCommands, calls)
}
