package `in`.abhijithvijayan.opendash.hhmis

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StockContractTest {
    private val four = StockFixtures.ALL.first { it.name == "gen1-moveos4-4.6.14" }
    private val five = StockFixtures.ALL.first { it.name == "gen1-moveos5-5.0.2" }
    private val gen3 = StockFixtures.ALL.first { it.name == "gen3-moveos5-7.1.30" }

    private fun asRead(c: StockContract, version: String = c.version) = StockContract(
        name = "", version = version, source = "read", checked = false,
        commands = c.commands, events = c.events, states = c.states, vehicleCommands = c.vehicleCommands, calls = c.calls,
    )

    @Test
    fun `the digest is the one the script recorded for every fixture`() {
        for (fixture in StockFixtures.ALL) assertEquals(fixture.name, fixture.recordedDigest, fixture.digest)
        assertEquals(StockFixtures.ALL.size, StockFixtures.ALL.map { it.digest to it.version }.toSet().size)
    }

    @Test
    fun `a command has the number of the build in front of it`() {
        assertEquals(53, four.command("AUTODOWNLOAD_UPDATE"))
        assertEquals(55, five.command("AUTODOWNLOAD_UPDATE"))
        assertEquals(55, four.command("VACATION_MODE_TOGGLE"))
        assertEquals(57, five.command("VACATION_MODE_TOGGLE"))
        assertEquals(30, four.command("PARTY_MODE_HIGH_BEAM_OFF"))
        assertEquals(32, five.command("PARTY_MODE_HIGH_BEAM_OFF"))
        assertEquals(2, four.command(StockContract.TOUCH_STATUS))
        assertEquals(2, five.command(StockContract.TOUCH_STATUS))
        assertNull(four.command("SMART_PARK_TOGGLE"))
        assertEquals(78, five.command("SMART_PARK_TOGGLE"))
        assertNull(five.command("NO_SUCH_COMMAND"))
    }

    @Test
    fun `the firmware commands sit where they always have on every recorded build`() {
        for (fixture in StockFixtures.ALL) {
            assertEquals(1, fixture.command("BOOL_INSTALL_ERROR_STAT"))
            assertEquals(20, fixture.command("VOID_CANCEL_DOWNLOAD"))
            assertEquals(21, fixture.command(StockContract.CHECK_FOR_UPDATE))
            assertEquals(22, fixture.command("VOID_CHECK_INSTALL_ERROR_STAT"))
            assertEquals(24, fixture.command("VOID_RETRY_DOWNLOAD"))
            val client = fixture.calls.getValue("IClientServiceInterface")
            assertEquals(8, client["download"])
            assertEquals(9, client["install"])
            assertEquals(10, client["triggerReceviedOnHMI"])
        }
    }

    @Test
    fun `vehicle states become the app's numbers by name`() {
        assertEquals(listOf(0, 1, 2, 3, 4, 5, 6, -1), (0..7).map { four.appState(it) })
        assertEquals(listOf(0, 1, 2, 3, 4, 7, 6, 5), (0..7).map { five.appState(it) })
        assertEquals(-1, five.appState(8))
        assertEquals(-1, four.appState(-1))
    }

    @Test
    fun `vehicle commands keep the numbers Dart already uses, and the new ones follow`() {
        for (wire in four.vehicleCommands.indices) assertEquals(wire, four.appVehicleCommand(wire))
        for (wire in five.vehicleCommands.indices) assertEquals(wire, five.appVehicleCommand(wire))
        for (wire in gen3.vehicleCommands.indices) assertEquals(wire, gen3.appVehicleCommand(wire))
        assertEquals(-1, four.appVehicleCommand(four.vehicleCommands.size))
    }

    @Test
    fun `events are named from the build's own list`() {
        assertEquals("BOOL_BT_LOCK", four.event(0))
        assertEquals("SERVER_CMD_178", four.event(178))
        assertEquals("CUSTOM_RIDE_SPEED", five.event(178))
        // Gen 3 MoveOS 5 (7.1.30) reuses 198 to 202 for other events.
        assertEquals("INT_JOB_OPEN_DIST_LEFT", five.event(198))
        assertEquals("BOOL_ABS_STATUS", gen3.event(198))
        assertEquals("STR_ABS_VERSION", gen3.event(204))
    }

    @Test
    fun `a service that was read and is a recorded checked build is checked`() {
        val c = StockContract.identify("4.6.14", asRead(four))
        assertEquals("read", c.source)
        assertEquals("gen1-moveos4-4.6.14", c.name)
        assertTrue(c.checked)
    }

    @Test
    fun `a service that was read and is not recorded is used as read, unchecked`() {
        val odd = StockContract(
            name = "", version = "4.9.0", source = "read", checked = false,
            commands = listOf("BOOL_SOMETHING_NEW") + four.commands, events = four.events, states = four.states,
            vehicleCommands = four.vehicleCommands, calls = four.calls,
        )
        val c = StockContract.identify("4.9.0", odd)
        assertEquals("read", c.source)
        assertEquals("", c.name)
        assertFalse(c.checked)
        assertEquals(54, c.command("AUTODOWNLOAD_UPDATE"))
    }

    @Test
    fun `the recorded MoveOS 5 lists are recognised and stay unchecked`() {
        val c = StockContract.identify("5.0.2", asRead(five))
        assertEquals("gen1-moveos5-5.0.2", c.name)
        assertFalse(c.checked)
    }

    @Test
    fun `a build with the lists of another build is still its own build`() {
        val gen2 = StockContract.identify("5.0.4", asRead(five, version = "5.0.4"))
        assertEquals("gen2-moveos5-5.0.4", gen2.name)
        val ridden = StockFixtures.ALL.map {
            if (it.name != five.name) it
            else StockContract(
                name = it.name, version = it.version, source = it.source, checked = true, fallbackFor = it.fallbackFor,
                commands = it.commands, events = it.events, states = it.states, vehicleCommands = it.vehicleCommands, calls = it.calls,
            )
        }
        assertTrue(StockContract.identify("5.0.2", asRead(five), ridden).checked)
        assertFalse(StockContract.identify("5.0.4", asRead(five, version = "5.0.4"), ridden).checked)
    }

    @Test
    fun `an unreadable service falls back to the recorded build of its version`() {
        val same = StockContract.identify("4.6.14", null)
        assertEquals("fixture", same.source)
        assertTrue(same.checked)
        val five = StockContract.identify("5.1.3", null)
        assertEquals("gen1-moveos5-5.0.2", five.name)
        assertEquals("fixture", five.source)
        assertFalse(five.checked)
        assertEquals(55, five.command("AUTODOWNLOAD_UPDATE"))
        val gen3 = StockContract.identify("7.2.0", null)
        assertEquals("gen3-moveos5-7.1.30", gen3.name)
        assertEquals("fixture", gen3.source)
        assertFalse(gen3.checked)
        assertEquals(55, gen3.command("AUTODOWNLOAD_UPDATE"))
    }

    @Test
    fun `the recorded Gen 3 lists are recognised and stay unchecked`() {
        val c = StockContract.identify("7.1.30", asRead(gen3))
        assertEquals("gen3-moveos5-7.1.30", c.name)
        assertFalse(c.checked)
        assertEquals(79, c.command("REGEN_BBW_UPDATE"))
    }

    @Test
    fun `an unreadable service of a version nobody recorded is assumed, never checked`() {
        for (version in listOf("4.9.0", "", "6.0.0")) {
            val c = StockContract.identify(version, null)
            assertEquals("assumed", c.source)
            assertFalse(c.checked)
            assertEquals(version, c.version)
        }
    }

    @Test
    fun `what Dart is told carries names and no numbers`() {
        val facts = StockContract.identify("4.6.14", asRead(four)).facts()
        assertEquals(setOf("version", "source", "name", "checked", "digest", "commands", "states"), facts.keys)
        assertEquals(four.commands, facts["commands"])
    }
}
