package `in`.abhijithvijayan.opendash

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.MessageDigest

class UsagePingTest {
    @Test
    fun onlyTheAppNameRidesAlong() {
        val r = UsagePing.request("https://example.invalid/v1/ping", "{}")
        assertEquals("POST", r.method)
        assertEquals(setOf("User-Agent"), r.headers.names())
    }

    @Test
    fun theProofHoldsForItsPing() {
        val ping = """{"v":2,"week":"2026-W48"}"""
        val body = UsagePing.body(ping, bits = 12)
        val n = Regex(""","n":(\d+)}$""").find(body)!!.groupValues[1]
        assertEquals("""{"ping":${UsagePing.quote(ping)},"n":$n}""", body)
        val d = MessageDigest.getInstance("SHA-256").digest("$ping:$n".toByteArray())
        assertTrue(UsagePing.leadingZeroBits(d) >= 12)
    }

    @Test
    fun quotesLikeJson() {
        assertEquals("\"{\\\"a\\\":\\\"b\\\\\\u000a\\\"}\"", UsagePing.quote("{\"a\":\"b\\\n\"}"))
    }

    @Test
    fun countsZeroBits() {
        assertEquals(0, UsagePing.leadingZeroBits(byteArrayOf(0x80.toByte())))
        assertEquals(7, UsagePing.leadingZeroBits(byteArrayOf(0x01, 0)))
        assertEquals(12, UsagePing.leadingZeroBits(byteArrayOf(0, 0x08)))
        assertEquals(16, UsagePing.leadingZeroBits(byteArrayOf(0, 0)))
    }
}
