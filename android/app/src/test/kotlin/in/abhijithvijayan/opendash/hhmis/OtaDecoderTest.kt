package `in`.abhijithvijayan.opendash.hhmis

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/// Each callback is fed the values HHMIS 4.6.14 writes, in the order its
/// `IOTAInterface$Stub$Proxy` writes them, and must come out as the right
/// fields with nothing left over. The reader fails on a read of the wrong
/// type, so a layout that drifts from the smali fails here.
class OtaDecoderTest {
    private class Values(vararg values: Any?) : OtaReader {
        private val queue = ArrayDeque(values.toList())
        val left get() = queue.size

        override fun int(): Int = queue.removeFirst() as Int
        override fun long(): Long = queue.removeFirst() as Long
        override fun string(): String? = queue.removeFirst() as String?
    }

    private fun decode(code: Int, vararg values: Any?): Map<String, Any?> {
        val reader = Values(*values)
        val out = OtaDecoder.decode(code, reader)!!
        assertEquals("values left unread", 0, reader.left)
        return out
    }

    private val address = "https://updates.example.invalid/bundle?sig=SIGNED"
    private val path = "/storage/emulated/0/Android/data/pkg/files/bundle.zip"
    private val identifier = 987654321012345L

    /// `DownloadStatus.writeToParcel`, after the presence flag.
    private fun downloadStatus(): Array<Any?> = arrayOf(
        1, // present
        7, // id
        address,
        path,
        1000L, // downloaded
        4000L, // total
        "com.android.hmiserverapp.parcelables.DownloadState", 2, // DOWNLOADING
        "com.android.hmiserverapp.parcelables.DownloadError", 0, // NONE
        25, // progress
        identifier,
        1, // downloadOnEnqueue
        60000L, // etaInMilliSeconds
        5000L, // downloadedBytesPerSecond
        3, // autoRetryMaxAttempts
        1, // autoRetryAttempts
    )

    private fun assertNoAddress(out: Map<String, Any?>) {
        val text = out.toString()
        assertFalse(text.contains("example.invalid"))
        assertFalse(text.contains("SIGNED"))
        assertFalse(text.contains("bundle.zip"))
        assertFalse(text.contains(identifier.toString()))
        assertFalse(out.containsKey("url"))
        assertFalse(out.containsKey("file"))
        assertFalse(out.containsKey("identifier"))
    }

    @Test
    fun tx1_installationProgress() {
        val out = decode(1, 1, 3, "Installing", 42)
        assertEquals(mapOf("kind" to "install_progress", "state" to 3, "status" to "Installing", "progress" to 42), out)
    }

    @Test
    fun tx1_nullState() {
        val out = decode(1, 0, null, 5)
        assertNull(out["state"])
        assertEquals(5, out["progress"])
    }

    @Test
    fun tx2_firstBootAfterInstall() {
        val out = decode(2, 1, 0)
        assertEquals(mapOf("kind" to "first_boot", "autoDownload" to true, "autoInstall" to false), out)
    }

    @Test
    fun tx3_installationFailed() {
        val out = decode(3, 1, 6, "reason text", "4.7.1", "431000000", "notes")
        assertEquals(
            mapOf("kind" to "install_failed", "state" to 6, "status" to "reason text", "version" to "4.7.1", "size" to "431000000", "notes" to "notes"),
            out,
        )
    }

    @Test
    fun tx4_everythingUpToDate() {
        val out = decode(4, "System is up-to-date", "4.6.14", "notes")
        assertEquals(mapOf("kind" to "up_to_date", "status" to "System is up-to-date", "version" to "4.6.14", "notes" to "notes"), out)
    }

    @Test
    fun tx5_updateAvailable() {
        val out = decode(5, 0, 1, 4, "status", "4.7.1", "431000000", "notes")
        assertEquals(
            mapOf(
                "kind" to "available", "button" to false, "reason" to 4, "status" to "status",
                "version" to "4.7.1", "size" to "431000000", "notes" to "notes",
            ),
            out,
        )
    }

    @Test
    fun tx6_downloadCompleted() {
        val out = decode(6, 1, 1, 0, "4.7.1", *downloadStatus(), "431000000", "notes")
        assertEquals("download_done", out["kind"])
        assertEquals(true, out["button"])
        assertEquals(0, out["reason"])
        assertEquals("4.7.1", out["version"])
        assertEquals("431000000", out["size"])
        assertEquals("notes", out["notes"])
        assertEquals(2, out["dlState"])
        assertEquals(25, out["dlProgress"])
        assertEquals(4000L, out["dlTotal"])
        assertNoAddress(out)
    }

    @Test
    fun tx6_withoutDownloadStatus() {
        val out = decode(6, 0, 0, "4.7.1", 0, "1", "notes")
        assertEquals(false, out["button"])
        assertNull(out["reason"])
        assertFalse(out.containsKey("dlState"))
    }

    @Test
    fun tx7_downloadStatusChanged() {
        val out = decode(7, 1, 2, *downloadStatus(), "4.7.1", "431000000", "notes", 1)
        assertEquals("download_status", out["kind"])
        assertEquals(2, out["state"])
        assertEquals("4.7.1", out["version"])
        assertEquals("431000000", out["size"])
        assertEquals(true, out["wifiOnly"])
        assertEquals(1000L, out["dlBytes"])
        assertEquals(0, out["dlError"])
        assertNoAddress(out)
    }

    @Test
    fun tx7_nullStateAndErrorInsideTheRecord() {
        val status = downloadStatus()
        // writeParcelable(null) writes a null class name and no body.
        val withNulls = status.take(6) + listOf<Any?>(null, null) + status.drop(10)
        val out = decode(7, 0, *withNulls.toTypedArray(), "v", "s", "n", 0)
        assertNull(out["state"])
        assertNull(out["dlState"])
        assertNull(out["dlError"])
        assertEquals(25, out["dlProgress"])
        assertEquals(false, out["wifiOnly"])
        assertNoAddress(out)
    }

    @Test
    fun tx8_downloadRetryFailed() {
        val out = decode(8, 1, 1, "status", "4.7.1", "431000000", "notes")
        assertEquals(
            mapOf("kind" to "retry_failed", "state" to 1, "status" to "status", "version" to "4.7.1", "size" to "431000000", "notes" to "notes"),
            out,
        )
    }

    @Test
    fun unknownTransactionIsDropped() {
        assertNull(OtaDecoder.decode(9, Values()))
        assertTrue(OtaDecoder.decode(0, Values()) == null)
    }
}
