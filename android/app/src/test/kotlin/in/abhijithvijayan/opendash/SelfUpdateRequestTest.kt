package `in`.abhijithvijayan.opendash

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/// The request that asks GitHub for the newest release carries nothing
/// about the rider or the scooter: three headers at most, no token, no
/// query, no version.
class SelfUpdateRequestTest {
    @Test
    fun exactlyTheThreeHeaders() {
        val r = SelfUpdate.latestRequest("owner/repo", "W/\"abc\"")
        assertEquals("GET", r.method)
        assertEquals("https://api.github.com/repos/owner/repo/releases/latest", r.url.toString())
        assertNull(r.url.query)
        assertEquals(setOf("User-Agent", "Accept", "If-None-Match"), r.headers.names())
        assertEquals("OpenDash", r.header("User-Agent"))
        assertEquals("application/vnd.github+json", r.header("Accept"))
        assertEquals("W/\"abc\"", r.header("If-None-Match"))
        assertNull(r.header("Authorization"))
        assertNull(r.body)
    }

    @Test
    fun withoutAnEtagOnlyTwo() {
        for (etag in listOf(null, "")) {
            val r = SelfUpdate.latestRequest("owner/repo", etag)
            assertEquals(setOf("User-Agent", "Accept"), r.headers.names())
        }
    }
}
