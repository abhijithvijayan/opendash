package `in`.abhijithvijayan.opendash

import org.junit.Assert.assertEquals
import org.junit.Test

class VersionFilesTest {
    private fun reader(files: Map<String, String>): (String) -> String = { files[it] ?: "" }

    @Test
    fun gen1ReadsItsOwnFiles() {
        val read = reader(mapOf("/vendor/etc/SW_version.txt" to "4.66.0.4", "/data/ola/vsw.txt" to "1.2.3"))
        assertEquals("4.66.0.4", VersionFiles.moveOs(read))
        assertEquals("1.2.3", VersionFiles.vsw(read))
    }

    @Test
    fun gen3ReadsTheFilesUnderOla() {
        val read = reader(mapOf("/vendor/etc/ola/SW_version.txt" to "7.1.30", "/data/vendor/ola/vsw.txt" to "7.0.1"))
        assertEquals("7.1.30", VersionFiles.moveOs(read))
        assertEquals("7.0.1", VersionFiles.vsw(read))
    }

    @Test
    fun theVendorCopyOfVswIsTheLastResort() {
        assertEquals("9", VersionFiles.vsw(reader(mapOf("/vendor/etc/ola/vsw.txt" to "9"))))
        assertEquals("8", VersionFiles.vsw(reader(mapOf("/vendor/etc/vsw.txt" to "8"))))
        assertEquals("", VersionFiles.moveOs(reader(emptyMap())))
    }
}
