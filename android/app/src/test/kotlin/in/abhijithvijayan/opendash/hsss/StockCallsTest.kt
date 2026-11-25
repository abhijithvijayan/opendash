package `in`.abhijithvijayan.opendash.hsss

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class StockCallsTest {
    private val builtin = HsssCalls.resolve(null)

    /// HSSS as read, with [changes] laid over the built-in tables: a null
    /// number takes the name out.
    private fun read(table: String, vararg changes: Pair<String, Int?>): StockCalls {
        val tables = HsssCalls.BUILTIN.toMutableMap()
        val names = tables.getValue(table).toMutableMap()
        for ((name, number) in changes) if (number == null) names.remove(name) else names[name] = number
        tables[table] = names
        return HsssCalls.resolve(tables)
    }

    @Test
    fun `the built-in HSSS numbers are the ones OpenDash has always sent`() {
        assertEquals(StockCalls.BUILTIN, builtin.source)
        assertEquals(6, builtin.need(HsssCalls.SYSTEM, HsssCalls.GET_BLUETOOTH_SETTINGS))
        assertEquals(0x2, builtin.need(HsssCalls.BLUETOOTH, HsssCalls.SET_BT_INFO_MANAGER))
        assertEquals(0x4, builtin.need(HsssCalls.BLUETOOTH, HsssCalls.REGISTER_RECEIVERS))
        assertEquals(0x2c, builtin.need(HsssCalls.BLUETOOTH, HsssCalls.SUBSCRIBE_CALL_STATUS))
        val data = mapOf(
            "enableBT" to 0x8, "isBtEnabled" to 0xa, "pairingAction" to 0xb, "forgetDevice" to 0x15,
            "disconnectDevice" to 0x16, "connectDevice" to 0x17, "callAction" to 0x18, "registerAllBtProfiles" to 0x19,
            "setScanMode" to 0x1c, "setAllBtProfilesPriority" to 0x1f, "getBondedDevices" to 0x25, "isBTProfileNull" to 0x33,
            "getConnectionState" to 0x35, "getScanMode" to 0x37, "enablePhoneCalls" to 0x38,
        )
        assertEquals(data.keys, HsssCalls.ALLOWED)
        assertEquals(data, HsssCalls.ALLOWED.associateWith { HsssCalls.dataCall(builtin, it) })
        assertEquals(mapOf(1 to "dismiss", 2 to "fail", 3 to "pin", 4 to "popup"), HsssCalls.pairingEvents(builtin))
        assertEquals(1, builtin.code(HsssCalls.CALL, HsssCalls.ON_CALL_STATE_CHANGED))
        assertEquals(2, builtin.code(HsssCalls.CALL, HsssCalls.ON_CALL_AUTO_REJECTED))
        assertEquals(HsssCalls.INTERFACES.toSet(), HsssCalls.BUILTIN.keys)
    }

    @Test
    fun `the built-in HPMS numbers are the ones OpenDash has always sent`() {
        val hpms = HpmsCalls.resolve(null)
        assertEquals(8 to 38, HpmsCalls.updateInt(hpms, "INT_SYNC_CONTACTS"))
        assertEquals(8 to 39, HpmsCalls.updateInt(hpms, "INT_SYNC_CONTACTS_PERMISSION"))
    }

    @Test
    fun `a service read with the built-in numbers reports no difference`() {
        val same = HsssCalls.resolve(HsssCalls.BUILTIN)
        assertEquals(StockCalls.READ, same.source)
        assertTrue(same.differences(HsssCalls.BUILTIN).isEmpty())
        assertTrue(builtin.differences(HsssCalls.BUILTIN).isEmpty())
    }

    @Test
    fun `a number read from the service wins, and the difference is reported`() {
        val moved = read(HsssCalls.BLUETOOTH, "disconnectDevice" to 0x40, "extraCallOpenDashNeverMakes" to 0x16)
        assertEquals(0x40, HsssCalls.dataCall(moved, "disconnectDevice"))
        assertEquals(0x17, HsssCalls.dataCall(moved, "connectDevice"))
        assertEquals(
            listOf(mapOf("name" to "IBluetoothSettings.disconnectDevice", "builtin" to 0x16, "read" to 0x40)),
            moved.differences(HsssCalls.BUILTIN),
        )
    }

    @Test
    fun `a moved callback is heard at its new number only`() {
        val moved = read(HsssCalls.PAIRING, "updateBTPairingPin" to 5, "showPairFailPopUp" to null)
        assertEquals(mapOf(1 to "dismiss", 5 to "pin", 4 to "popup"), HsssCalls.pairingEvents(moved))
        assertEquals(
            setOf("IPairingStatusUpdate.updateBTPairingPin", "IPairingStatusUpdate.showPairFailPopUp"),
            moved.differences(HsssCalls.BUILTIN).map { it["name"] }.toSet(),
        )
    }

    @Test
    fun `a name the service does not have is refused, not guessed`() {
        val without = read(HsssCalls.BLUETOOTH, "setAllBtProfilesPriority" to null, HsssCalls.REGISTER_RECEIVERS to null)
        assertThrows(NoSuchMethodException::class.java) { HsssCalls.dataCall(without, "setAllBtProfilesPriority") }
        assertThrows(NoSuchMethodException::class.java) { without.need(HsssCalls.BLUETOOTH, HsssCalls.REGISTER_RECEIVERS) }
        assertNull(without.code(HsssCalls.BLUETOOTH, "setAllBtProfilesPriority"))
        assertEquals(
            listOf(null, null),
            without.differences(HsssCalls.BUILTIN).map { it["read"] },
        )
        assertEquals(0x8, HsssCalls.dataCall(without, "enableBT"))

        val profile = HpmsCalls.resolve(mapOf(HpmsCalls.SERVICE to mapOf("updateInt" to 8), HpmsCalls.CMD to mapOf("INT_SYNC_CONTACTS" to 41)))
        assertEquals(8 to 41, HpmsCalls.updateInt(profile, "INT_SYNC_CONTACTS"))
        assertThrows(NoSuchMethodException::class.java) { HpmsCalls.updateInt(profile, "INT_SYNC_CONTACTS_PERMISSION") }
    }

    @Test
    fun `a name outside the allow-list is refused whatever the table says`() {
        val everything = read(
            HsssCalls.BLUETOOTH,
            "unregisterReceivers" to 0x3, "pairingPopUp" to 0xc, "unregisterAllBtProfiles" to 0x14, "disableBT" to 0x9,
        )
        for (name in listOf("unregisterReceivers", "pairingPopUp", "unregisterAllBtProfiles", "disableBT")) {
            assertFalse(name, name in HsssCalls.ALLOWED)
            assertTrue(name, everything.code(HsssCalls.BLUETOOTH, name) != null)
            assertThrows(name, IllegalArgumentException::class.java) { HsssCalls.dataCall(everything, name) }
            assertThrows(name, IllegalArgumentException::class.java) { HsssCalls.dataCall(builtin, name) }
        }
        // The calls Kotlin makes itself are not Dart's to make.
        for (name in listOf(HsssCalls.SET_BT_INFO_MANAGER, HsssCalls.REGISTER_RECEIVERS, HsssCalls.SUBSCRIBE_CALL_STATUS, "", "8")) {
            assertThrows(name, IllegalArgumentException::class.java) { HsssCalls.dataCall(builtin, name) }
        }

        val profile = HpmsCalls.resolve(mapOf(HpmsCalls.SERVICE to mapOf("updateInt" to 8), HpmsCalls.CMD to mapOf("INT_PASSCODE" to 3)))
        assertThrows(IllegalArgumentException::class.java) { HpmsCalls.updateInt(profile, "INT_PASSCODE") }
    }
}
