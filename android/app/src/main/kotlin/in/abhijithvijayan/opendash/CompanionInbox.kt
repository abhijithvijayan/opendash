package `in`.abhijithvijayan.opendash

import android.content.Context
import java.io.File

/// The folder the companion phone app shares with OpenDash, in OpenDash's own
/// external files dir (an adb shell can write there): OpenDash's answer to
/// "may the phone send updates by itself", and the update the phone sent.
/// Only files move here; whether to offer, and every check, is Dart's
/// (`lib/state/ota_state.dart`).
object CompanionInbox {
    private const val RELEASE = "opendash-release.json"
    private const val MAX_RELEASE_BYTES = 64 * 1024

    private fun root(context: Context): File? = context.getExternalFilesDir(null)?.let { File(it, "companion") }

    fun publish(context: Context, json: String): Boolean = try {
        val dir = root(context) ?: throw IllegalStateException("no external files dir")
        dir.mkdirs()
        val tmp = File(dir, "accepts.json.tmp")
        tmp.writeText(json)
        tmp.renameTo(File(dir, "accepts.json"))
    } catch (_: Exception) {
        false
    }

    private fun incoming(context: Context): File? = root(context)?.let { File(it, "incoming") }

    private fun apkNamed(json: String): String? = Regex("\"apk\"\\s*:\\s*\"([^\"/]+)\"").find(json)?.groupValues?.get(1)

    /// The release file the companion left, or null while there is none or
    /// the APK it names isn't there yet (a send writes the release file
    /// last). Cheap: read on every look.
    fun release(context: Context): String? = try {
        val release = incoming(context)?.let { File(it, RELEASE) }
        if (release == null || !release.isFile || release.length() > MAX_RELEASE_BYTES) {
            null
        } else {
            val json = release.readText()
            val apk = apkNamed(json)?.let { File(incoming(context), it) }
            if (apk != null && apk.isFile) json else null
        }
    } catch (_: Exception) {
        null
    }

    /// A private copy of the APK the release file names, which is what gets
    /// checked and installed, so the shared file can't be swapped in between.
    /// One file per build: a newer send never overwrites the one already
    /// offered.
    fun copy(context: Context, build: Int): String? = try {
        val json = release(context)
        val apk = json?.let { apkNamed(it) }?.let { File(incoming(context), it) }
        if (apk == null) {
            null
        } else {
            val dir = File(context.cacheDir, "apks")
            dir.mkdirs()
            val out = File(dir, "opendash-incoming-$build.apk")
            apk.copyTo(out, overwrite = true)
            out.path
        }
    } catch (_: Exception) {
        null
    }

    fun clear(context: Context): Boolean = root(context)?.let { File(it, "incoming").deleteRecursively() } ?: false
}
