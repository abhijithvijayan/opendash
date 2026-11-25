package `in`.abhijithvijayan.opendash

/// Where the stock dashboard reads the scooter's software versions, per
/// generation, first found wins (`VersionInfoManager` in each stock build):
/// Gen 1 keeps them in /vendor/etc and /data/ola; Gen 3 (7.1.30) moved them
/// under an `ola` folder.
object VersionFiles {
    private val moveOs = listOf("/vendor/etc/SW_version.txt", "/vendor/etc/ola/SW_version.txt")
    private val vsw = listOf("/data/ola/vsw.txt", "/data/vendor/ola/vsw.txt", "/vendor/etc/vsw.txt", "/vendor/etc/ola/vsw.txt")

    fun moveOs(read: (String) -> String): String = first(moveOs, read)
    fun vsw(read: (String) -> String): String = first(vsw, read)

    private fun first(paths: List<String>, read: (String) -> String): String =
        paths.firstNotNullOfOrNull { read(it).ifEmpty { null } } ?: ""
}
