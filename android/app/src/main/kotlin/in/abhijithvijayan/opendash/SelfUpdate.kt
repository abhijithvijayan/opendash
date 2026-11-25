package `in`.abhijithvijayan.opendash

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.os.SystemClock
import okhttp3.Request
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/// OpenDash updating itself from its GitHub releases: the question asked of
/// GitHub, the hand-over to Android's installer, and the record of an
/// update that has not yet been seen to start. What is offered, when, and
/// whether it may be installed is decided in Dart (`lib/state/ota_state.dart`).
///
/// Nothing here installs silently, uninstalls anything, or runs a shell
/// command: Android's own confirmation screen is the last word.
object SelfUpdate {
    const val RELEASE_FILE = "opendash-release.json"
    const val APK_FILE = "opendash-update.apk"
    private const val NOTES_CAP = 1500

    /// The one request that asks whether a newer release exists. Exactly
    /// these headers, and nothing about the rider or the scooter: no token,
    /// no query, no version (`SelfUpdateRequestTest`). `releases/latest` is
    /// the newest release that is neither a draft nor a pre-release.
    fun latestRequest(repo: String, etag: String?): Request {
        val b = Request.Builder()
            .url("https://api.github.com/repos/$repo/releases/latest")
            .header("User-Agent", "OpenDash")
            .header("Accept", "application/vnd.github+json")
        if (!etag.isNullOrEmpty()) b.header("If-None-Match", etag)
        return b.build()
    }

    /// `{status}` always; for a 200 also the release: `etag`, `tag`, `notes`
    /// (plain text, capped), `url`, `published`, `release` (the text of
    /// opendash-release.json), `apk_url`, `apk_size`. A status of 0 is "no
    /// answer": no network, a timeout, anything thrown.
    fun check(repo: String, etag: String?): Map<String, Any?> = try {
        Net.quick.newCall(latestRequest(repo, etag)).execute().use { response ->
            if (response.code != 200) return@use mapOf<String, Any?>("status" to response.code)
            val release = JSONObject(response.body!!.string())
            val assets = release.optJSONArray("assets")
            val byName = HashMap<String, JSONObject>()
            if (assets != null) for (i in 0 until assets.length()) assets.getJSONObject(i).let { byName[it.optString("name")] = it }
            val facts = byName[RELEASE_FILE]?.optString("browser_download_url").orEmpty()
            val text = if (facts.isEmpty()) null else fetchText(facts)
            val apkName = try {
                JSONObject(text ?: "{}").optString("apk")
            } catch (_: Exception) {
                ""
            }
            val apk = byName[apkName]
            mapOf<String, Any?>(
                "status" to 200,
                "etag" to response.header("ETag"),
                "tag" to release.optString("tag_name"),
                "notes" to release.optString("body").take(NOTES_CAP),
                "url" to release.optString("html_url"),
                "published" to release.optString("published_at"),
                "release" to text,
                "apk_url" to apk?.optString("browser_download_url"),
                "apk_size" to apk?.optLong("size"),
            )
        }
    } catch (e: Exception) {
        mapOf<String, Any?>("status" to 0, "error" to e.javaClass.simpleName)
    }

    private fun fetchText(url: String): String? =
        Net.quick.newCall(Request.Builder().url(url).header("User-Agent", "OpenDash").build()).execute().use { r ->
            if (r.code == 200) r.body!!.string().take(4096) else null
        }

    fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(1 shl 16)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                digest.update(buffer, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /// Hands [apk] to Android's package installer as an update of this app.
    /// Android then shows its own confirmation (`InstallResultReceiver`
    /// opens it); nothing is installed until the rider confirms there.
    /// The record of the pending update is written first: the process does
    /// not survive a successful install to write it afterwards.
    fun install(context: Context, apk: File, toBuild: Long): String? = try {
        UpdateRecord.pending(context, from = UpdateRecord.installedBuild(context), to = toBuild)
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(context.packageName)
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("opendash", 0, apk.length()).use { out ->
                    input.copyTo(out)
                    session.fsync(out)
                }
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            val result = PendingIntent.getBroadcast(context, id, Intent(context, InstallResultReceiver::class.java), flags)
            session.commit(result.intentSender)
        }
        null
    } catch (e: Exception) {
        UpdateRecord.result(context, PackageInstaller.STATUS_FAILURE, e.javaClass.simpleName)
        e.javaClass.simpleName
    }
}

/// What Android's installer says about the session `SelfUpdate.install`
/// committed. "Pending user action" is the normal first answer: it carries
/// the confirmation screen, which is opened. Any other answer that reaches
/// a live process is a failure or a cancel, kept for Dart to read.
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            @Suppress("DEPRECATION")
            val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
            try {
                context.startActivity(confirm!!.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                Analytics.log("selfupdate", "confirm_shown", mapOf<String, Any?>())
            } catch (e: Exception) {
                UpdateRecord.result(context, PackageInstaller.STATUS_FAILURE, "confirm: ${e.javaClass.simpleName}")
            }
            return
        }
        UpdateRecord.result(context, status, intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE).orEmpty())
    }
}

/// Android has replaced this package with a newer one of ours. As the HOME
/// app OpenDash is started again by Android itself (seen on a scooter); this
/// covers a scooter where it is not.
class PackageReplacedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        try {
            context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: RuntimeException) {
        }
    }
}

/// An update handed to the installer and not yet seen to run: which build
/// it was to be, how many times that build has started without reaching a
/// stable dashboard, and the installer's last answer. Kept outside Flutter's
/// preferences so it can be read before the Flutter engine exists: a build
/// whose Dart side never comes up is exactly what it is for.
object UpdateRecord {
    private const val PREFS = "opendash_update"
    const val MAX_STARTS = 3
    private var counted = false

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun installedBuild(context: Context): Long = try {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        @Suppress("DEPRECATION")
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    } catch (_: Exception) {
        0
    }

    fun pending(context: Context, from: Long, to: Long) {
        prefs(context).edit()
            .putLong("from", from).putLong("to", to).putLong("at", SystemClock.elapsedRealtime())
            .putInt("starts", 0).remove("status").remove("message")
            .commit()
    }

    fun result(context: Context, status: Int, message: String) {
        prefs(context).edit().putInt("status", status).putString("message", message.take(200)).commit()
        Analytics.log("selfupdate", "installer_answer", mapOf("status" to status))
    }

    /// Called once per process, before the Flutter engine is created. Counts
    /// a start of the build an update was to install; returns that count (0
    /// when no update is pending, or another build is the one running).
    fun noteStart(context: Context): Int {
        val p = prefs(context)
        val to = p.getLong("to", 0)
        if (to == 0L || installedBuild(context) != to) return 0
        if (counted) return p.getInt("starts", 0)
        counted = true
        val starts = p.getInt("starts", 0) + 1
        p.edit().putInt("starts", starts).commit()
        return starts
    }

    /// More starts than [MAX_STARTS] with none of them reaching a stable
    /// dashboard: the stock dashboard is opened so the rider is not left
    /// with a build that does not start and no laptop.
    fun fallbackNote(context: Context, starts: Int) {
        val p = prefs(context)
        val log = p.getString("fallback_log", "").orEmpty()
        p.edit().putString("fallback_log", (log + "\n" + System.currentTimeMillis() + " " + starts).takeLast(400)).commit()
    }

    fun read(context: Context): Map<String, Any?> {
        val p = prefs(context)
        return mapOf(
            "from" to p.getLong("from", 0),
            "to" to p.getLong("to", 0),
            "starts" to p.getInt("starts", 0),
            "installed" to installedBuild(context),
            "status" to (if (p.contains("status")) p.getInt("status", 0) else null),
            "message" to p.getString("message", null),
            "fallback_log" to p.getString("fallback_log", null),
        )
    }

    /// The update is settled (the new build ran, or the install failed and
    /// the rider has been told): nothing is pending.
    fun clear(context: Context) {
        prefs(context).edit().clear().commit()
    }

    /// The installer's answer has been read; the pending update stays.
    fun clearResult(context: Context) {
        prefs(context).edit().remove("status").remove("message").commit()
    }
}
