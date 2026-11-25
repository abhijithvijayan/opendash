package `in`.abhijithvijayan.opendash

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import opendash.reads.PlatformReadsApi
import opendash.reads.PlatformReadsApiRegistrar
import java.io.File
import java.io.FileInputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject

class PlatformPlugin private constructor(
    private val activity: Activity,
    private val channel: MethodChannel
) : MethodChannel.MethodCallHandler, PlatformReadsApi {

    companion object {
        private val STOCK_PREFIXES = listOf("com.olaelectric", "com.ola.", "com.android.hmiserverapp")

        /// Read for the scooter survey, and nothing else is: what the head
        /// unit is and which build it runs. No serial number, no radio or
        /// SIM identifier, no time zone.
        private val SURVEY_PROPS = listOf(
            "ro.product.brand", "ro.product.name", "ro.product.device", "ro.product.board", "ro.board.platform",
            "ro.hardware", "ro.boot.hardware.revision", "ro.bootloader", "ro.product.cpu.abi",
            "ro.build.flavor", "ro.build.type", "ro.build.tags", "ro.build.version.incremental",
            "ro.build.version.release", "ro.build.version.sdk", "ro.build.version.security_patch",
            "ro.build.date.utc", "ro.vendor.build.date.utc", "ro.vendor.build.version.incremental",
            "ro.sf.lcd_density", "gsm.version.baseband",
        )
        private const val CHANNEL = "in.abhijithvijayan.opendash.platform"

        // Both: on Android 9 and 10 an APK file read with the newer flag
        // alone can come back with no signing info.
        @Suppress("DEPRECATION")
        private const val SIGNER_FLAGS = PackageManager.GET_SIGNING_CERTIFICATES or PackageManager.GET_SIGNATURES

        private val direct = java.util.WeakHashMap<FlutterEngine, PlatformPlugin>()

        /// The direct reads are kept in a process-wide table, which would
        /// otherwise hold a finished activity through its plugin.
        fun unregister(engine: FlutterEngine) {
            direct.remove(engine)?.let { PlatformReadsApiRegistrar().unregister(it, engine) }
        }

        fun register(activity: Activity, engine: FlutterEngine) {
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            val plugin = PlatformPlugin(activity, channel)
            channel.setMethodCallHandler(plugin)
            PlatformReadsApiRegistrar().register(plugin, engine)
            direct[engine] = plugin
            Analytics.attach(channel)
            Net.watch(activity)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isInstalled" -> result.success(isInstalled(call.arguments as String))
            "launchApp" -> launchApp(call.arguments as String, result)
            "openHomeSettings" -> openHomeSettings(result)
            "isDefaultHome" -> result.success(isDefaultHome())
            "installApk" -> installApk(call.arguments as String, result)
            "canInstallApks" -> result.success(canInstallApks())
            "openInstallPermissionSettings" -> openInstallPermissionSettings(result)
            "canDrawOverlays" -> result.success(canDrawOverlays())
            "openOverlayPermissionSettings" -> openSettingsFor(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, result)
            "openHotspotSettings" -> openInOurTask(
                result,
                Intent().setClassName("com.android.settings", "com.android.settings.TetherSettings"),
                Intent(Settings.ACTION_WIRELESS_SETTINGS),
            )
            "openNotificationAccessSettings" -> openInOurTask(result, Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            // Android 10's Wi-Fi panel: networks, their password prompt and
            // nothing else of Android Settings (opened on the Gen 1 head unit
            // with `am start -a android.settings.panel.action.WIFI`).
            "openWifiPanel" ->
                if (Build.VERSION.SDK_INT >= 29) openInOurTask(result, Intent(Settings.Panel.ACTION_WIFI)) else result.success(false)
            "openUsageAccessSettings" -> openInOurTask(result, Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
            "foregroundPackage" -> result.success(foregroundPackage())
            "hasNotificationAccess" -> result.success(hasNotificationAccess())
            "bringToFront" -> result.success(
                try {
                    ReturnOverlay.bringToFront(activity)
                    true
                } catch (e: Exception) {
                    false
                },
            )
            "downloadFile" -> {
                val url = call.argument<String>("url")!!
                val filename = call.argument<String>("filename")!!
                downloadFile(url, filename, call.argument<String>("version").orEmpty(), call.argument<String>("asset").orEmpty(), result)
            }
            "selfUpdateCheck" -> {
                val repo = call.argument<String>("repo")!!
                val etag = call.argument<String>("etag")
                Thread {
                    val answer = SelfUpdate.check(repo, etag)
                    activity.runOnUiThread { result.success(answer) }
                }.start()
            }
            "usagePing" -> {
                val url = call.argument<String>("url")!!
                val body = call.argument<String>("body")!!
                Thread {
                    val status = UsagePing.send(url, body)
                    activity.runOnUiThread { result.success(status) }
                }.start()
            }
            "selfUpdateDownload" -> downloadDirect(call.arguments as String, SelfUpdate.APK_FILE, result)
            "downloadProgress" -> result.success(downloadProgress(call.arguments as String))
            "fileSha256" -> {
                val file = File(call.arguments as String)
                Thread {
                    val sum = try {
                        SelfUpdate.sha256(file)
                    } catch (_: Exception) {
                        null
                    }
                    activity.runOnUiThread { result.success(sum) }
                }.start()
            }
            "deleteFile" -> result.success(
                // Only our own downloads.
                File(call.arguments as String).let { it.parentFile == File(activity.cacheDir, "apks") && it.delete() },
            )
            "selfUpdateInstall" -> {
                val file = File(call.argument<String>("path")!!)
                val to = (call.argument<Number>("build")!!).toLong()
                Thread {
                    val error = SelfUpdate.install(activity.applicationContext, file, to)
                    activity.runOnUiThread { result.success(error) }
                }.start()
            }
            "companionPublish" -> {
                val json = call.arguments as String
                Thread {
                    val ok = CompanionInbox.publish(activity.applicationContext, json)
                    activity.runOnUiThread { result.success(ok) }
                }.start()
            }
            "companionIncomingRelease" -> Thread {
                val json = CompanionInbox.release(activity.applicationContext)
                activity.runOnUiThread { result.success(json) }
            }.start()
            "companionIncomingCopy" -> Thread {
                val path = CompanionInbox.copy(activity.applicationContext, (call.arguments as Number).toInt())
                activity.runOnUiThread { result.success(path) }
            }.start()
            "companionIncomingClear" -> Thread {
                val ok = CompanionInbox.clear(activity.applicationContext)
                activity.runOnUiThread { result.success(ok) }
            }.start()
            "updateRecord" -> result.success(updateRecord())
            "updateRecordClear" -> {
                if (call.arguments == "result") UpdateRecord.clearResult(activity) else UpdateRecord.clear(activity)
                result.success(true)
            }
            "cancelDownload" -> {
                downloads[call.arguments as String]?.cancel()
                result.success(true)
            }
            "apkInfo" -> result.success(
                packageFacts(activity.packageManager.getPackageArchiveInfo(call.arguments as String, SIGNER_FLAGS)),
            )
            "installedInfo" -> result.success(
                try {
                    packageFacts(activity.packageManager.getPackageInfo(call.arguments as String, SIGNER_FLAGS))
                } catch (_: PackageManager.NameNotFoundException) {
                    null
                },
            )
            "networkCheck" -> networkCheck(result)
            "otaShieldStatus" -> OtaShield.status(activity, result)
            "otaShieldActivate" -> OtaShield.activate(activity, result)
            "otaShieldDisableFailsafe" -> OtaShield.disableFailsafe(activity, result)
            "latestRelease" -> latestRelease(call.argument<String>("url")!!, call.argument<String>("asset").orEmpty(), result)
            "externalFilesDir" -> result.success(externalFilesDir())
            "deviceInfo" -> result.success(deviceInfo())
            "analyticsReady" -> {
                Analytics.ready()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // Dart's boot-time force-stop skips when OpenDash is not the current
    // HOME launcher.
    override fun isDefaultHome(): Boolean {
        val homeIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val info = activity.packageManager.resolveActivity(homeIntent, PackageManager.MATCH_DEFAULT_ONLY)
        return info?.activityInfo?.packageName == activity.packageName
    }

    override fun foregroundPackage(): String? = try {
        readForegroundPackage()
    } catch (e: Exception) {
        null
    }

    override fun updateRecord(): Map<String, Any?> = UpdateRecord.read(activity)

    // build_time_ms / elapsed_realtime_ms: Android starts a clock that was
    // never set at the firmware build date (ro.build.date.utc), so "wall -
    // build time <= uptime" is how Dart's TrustedClock tells a default
    // clock from a real one on any firmware.
    override fun deviceInfo(): Map<String, String> = ScreenFacts.of(activity) + mapOf(
                "model" to Build.MODEL,
                "release" to Build.VERSION.RELEASE,
                // Most preferred first: what an app with a build per
                // processor type is picked by.
                "abis" to Build.SUPPORTED_ABIS.joinToString(","),
                // For the scooter survey (`survey.device`): which head unit
                // and which stock software this is. No serial, no identifier.
                "manufacturer" to Build.MANUFACTURER,
                "board" to Build.BOARD,
                "hardware" to Build.HARDWARE,
                "sdk" to Build.VERSION.SDK_INT.toString(),
                "security_patch" to Build.VERSION.SECURITY_PATCH,
                "build_id" to Build.DISPLAY,
                "stock_packages" to stockPackages(),
                "system_props" to systemProps(),
                "sensors" to sensors(),
                "ram_mb" to ramMb(),
                "build_time_ms" to Build.TIME.toString(),
                "elapsed_realtime_ms" to android.os.SystemClock.elapsedRealtime().toString(),
                // Our own installed build number, for About and the log.
                "version_code" to (try {
                    packageFacts(activity.packageManager.getPackageInfo(activity.packageName, 0))?.get("versionCode")?.toString()
                } catch (_: PackageManager.NameNotFoundException) {
                    null
                }).orEmpty(),
            )

    // Per-app external storage needs no permission on API 29 and is what
    // `adb pull` can reach without root. Internal storage is the fallback
    // when the external volume is missing; the log then says so.
    override fun externalFilesDir(): String? {
        val external = try {
            activity.getExternalFilesDir(null)
        } catch (_: Exception) {
            null
        }
        return (external ?: activity.filesDir)?.absolutePath
    }

    // The reads Dart also calls directly (pigeons/platform_reads.dart). They
    // run on the thread that builds frames: nothing here may block.
    override fun isInstalled(packageName: String): Boolean = try {
        activity.packageManager.getPackageInfo(packageName, 0)
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    override fun canInstallApks(): Boolean = activity.packageManager.canRequestPackageInstalls()

    override fun canDrawOverlays(): Boolean = ReturnOverlay.allowed(activity)

    override fun hasNotificationAccess(): Boolean =
        Settings.Secure.getString(activity.contentResolver, "enabled_notification_listeners")
            .orEmpty().split(":").any { it.startsWith(activity.packageName + "/") }

    override fun downloadProgress(filename: String): Long = progress[filename]?.get() ?: 0L

    private fun launchApp(packageName: String, result: MethodChannel.Result) {
        val pm = activity.packageManager
        var intent = pm.getLaunchIntentForPackage(packageName)
        if (intent == null) {
            // Some HOME launchers (Launcher3 among them) register only
            // CATEGORY_HOME, not CATEGORY_LAUNCHER, so the launch intent
            // lookup misses them. Resolve by HOME intent and match the package.
            val home = Intent(Intent.ACTION_MAIN).apply { addCategory(Intent.CATEGORY_HOME) }
            val match = pm.queryIntentActivities(home, 0)
                .firstOrNull { it.activityInfo.packageName == packageName }
            if (match != null) {
                intent = Intent(Intent.ACTION_MAIN).apply {
                    addCategory(Intent.CATEGORY_HOME)
                    setClassName(packageName, match.activityInfo.name)
                }
            }
        }
        if (intent != null) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivity(intent)
            result.success(true)
        } else {
            result.success(false)
        }
    }

    // The system "default home" chooser: an explicit, reversible choice in
    // Android's own UI rather than a silent launcher switch.
    /// Android's per-source "Install unknown apps" switch for OpenDash. The
    /// installer otherwise stops at "For your security, your phone is not
    /// allowed to install unknown apps from this source".
    private fun openInstallPermissionSettings(result: MethodChannel.Result) =
        openSettingsFor(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, result)

    /// A per-app system permission screen for OpenDash, started from our own
    /// activity with no NEW_TASK so it lands on top of the dashboard and Back
    /// returns here. With NEW_TASK it joined the Settings task a rider had
    /// left open from Apps, and Back went to that Settings page instead.
    private fun openSettingsFor(action: String, result: MethodChannel.Result) {
        try {
            val intent = Intent(action, Uri.parse("package:${activity.packageName}"))
            activity.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    /// Without NEW_TASK, like the permission screens: the page sits on top of
    /// the dashboard in our own task, so its own back arrow comes back here
    /// even where Android hides the island and the pill (the hotspot page).
    /// The first intent that resolves is used.
    private fun openInOurTask(result: MethodChannel.Result, vararg intents: Intent) {
        for (intent in intents) {
            try {
                activity.startActivity(intent)
                result.success(true)
                return
            } catch (_: Exception) {
            }
        }
        result.success(false)
    }

    private fun openHomeSettings(result: MethodChannel.Result) {
        try {
            val intent = Intent(Settings.ACTION_HOME_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    private fun installApk(filePath: String, result: MethodChannel.Result) {
        try {
            val file = File(filePath)
            if (!file.exists()) {
                result.success(false)
                return
            }
            val uri = FileProvider.getUriForFile(
                activity,
                "${activity.packageName}.fileprovider",
                file
            )
            // In our task, like the permission screens, so finishing or
            // cancelling the installer lands back on the dashboard.
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    /// The catalog points at GitHub release pages; once the page's
    /// HTML was saved as the .apk and the installer said "problem parsing the
    /// package". Resolve a release page to the APK asset of the catalog's
    /// tested version, require HTTP 200, and only hand over a file that
    /// starts like a zip (an APK is one). Dart then checks its SHA-256.
    private var front = ""
    private var frontReadUntil = 0L

    /// The package whose screen is in front, as Android's usage log has it:
    /// null without "Usage access" for OpenDash, "" when it has not said
    /// yet. Only the events since the last call are read.
    private fun readForegroundPackage(): String? {
        val ops = activity.getSystemService(android.app.AppOpsManager::class.java)
        @Suppress("DEPRECATION")
        val mode = ops.checkOpNoThrow(android.app.AppOpsManager.OPSTR_GET_USAGE_STATS, android.os.Process.myUid(), activity.packageName)
        if (mode != android.app.AppOpsManager.MODE_ALLOWED) return null
        val usage = activity.getSystemService(android.app.usage.UsageStatsManager::class.java) ?: return null
        val now = System.currentTimeMillis()
        // The clock is set from the network after boot and can jump.
        val from = if (frontReadUntil in (now - 60_000)..now) frontReadUntil else now - 60_000
        val events = usage.queryEvents(from, now)
        val event = android.app.usage.UsageEvents.Event()
        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            @Suppress("DEPRECATION")
            if (event.eventType == android.app.usage.UsageEvents.Event.MOVE_TO_FOREGROUND) front = event.packageName
        }
        frontReadUntil = now
        return front
    }

    /// The download in flight for each file name, for "cancelDownload".
    private val downloads = java.util.concurrent.ConcurrentHashMap<String, okhttp3.Call>()

    /// Bytes written so far for each direct download, for "downloadProgress".
    private val progress = java.util.concurrent.ConcurrentHashMap<String, java.util.concurrent.atomic.AtomicLong>()

    /// [url] as it is, to the downloads folder: OpenDash's own update,
    /// whose address came from the release it was found in. No resume.
    private fun downloadDirect(url: String, filename: String, result: MethodChannel.Result) {
        Thread {
            val written = java.util.concurrent.atomic.AtomicLong(0)
            progress[filename] = written
            val path = try {
                val dir = File(activity.cacheDir, "apks")
                dir.mkdirs()
                val outFile = File(dir, filename)
                outFile.delete()
                val download = Net.download.newCall(request(url).build())
                downloads[filename] = download
                try {
                    download.execute().use { response ->
                        if (response.code != HttpURLConnection.HTTP_OK) throw IllegalStateException("HTTP ${response.code}")
                        response.body!!.byteStream().use { input ->
                            outFile.outputStream().use { out ->
                                val buffer = ByteArray(1 shl 16)
                                while (true) {
                                    val n = input.read(buffer)
                                    if (n < 0) break
                                    out.write(buffer, 0, n)
                                    written.addAndGet(n.toLong())
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    outFile.delete()
                    throw e
                } finally {
                    downloads.remove(filename)
                }
                if (!looksLikeApk(outFile)) {
                    outFile.delete()
                    throw IllegalStateException("not an APK")
                }
                outFile.absolutePath
            } catch (e: Exception) {
                Analytics.log("platform", "direct_download", mapOf("ok" to false, "error" to e.javaClass.simpleName))
                null
            }
            activity.runOnUiThread { result.success(path) }
        }.start()
    }

    private fun downloadFile(url: String, filename: String, version: String, asset: String, result: MethodChannel.Result) {
        Thread {
            val path = try {
                val apkUrl = resolveApkUrl(url, version, asset)
                val dir = File(activity.cacheDir, "apks")
                dir.mkdirs()
                val outFile = File(dir, filename)
                outFile.delete()
                val download = Net.download.newCall(request(apkUrl).build())
                downloads[filename] = download
                try {
                    download.execute().use { response ->
                        if (response.code != HttpURLConnection.HTTP_OK) throw IllegalStateException("HTTP ${response.code}")
                        response.body!!.byteStream().use { input -> outFile.outputStream().use { input.copyTo(it) } }
                    }
                } catch (e: Exception) {
                    // Cancelled or cut off: what was written is no use.
                    outFile.delete()
                    throw e
                } finally {
                    downloads.remove(filename)
                }
                if (!looksLikeApk(outFile)) {
                    outFile.delete()
                    throw IllegalStateException("not an APK")
                }
                Analytics.log("platform", "apk_download", mapOf("ok" to true, "bytes" to outFile.length()))
                outFile.absolutePath
            } catch (e: Exception) {
                Analytics.log("platform", "apk_download", mapOf("ok" to false, "error" to e.toString()))
                null
            }
            activity.runOnUiThread { result.success(path) }
        }.start()
    }

    /// [quick] is for the small questions asked of GitHub's API: they answer
    /// in well under a second or not at all, and the rider is looking at a
    /// spinner. A download keeps the long limits; its read timeout is per
    /// read, so only a stalled transfer runs into it.
    private fun request(url: String) = okhttp3.Request.Builder().url(url).header("User-Agent", "OpenDash")

    /// `https://github.com/<owner>/<repo>/releases` → the first non-debug
    /// `.apk` asset of the release tagged for [version], never a newer one
    /// ("latest" has been seen to move from 4.0.0-beta2 to 4.0.0 within a
    /// day). With no version: the latest release, or, for projects that only
    /// publish pre-releases (DiPlay; `/releases/latest` is a 404 for them),
    /// the newest non-draft release. Anything else is used as given.
    /// Where the APK of a release is, as the release lookup found it: the
    /// download that follows asks GitHub's API nothing more. Unauthenticated
    /// requests are limited to 60 an hour, and a round of
    /// installs spent them (HTTP 403 on the next download).
    private val found = java.util.concurrent.ConcurrentHashMap<Triple<String, String, String>, String>()

    private fun resolveApkUrl(url: String, version: String, asset: String): String {
        val api = releasesApi(url) ?: return url
        if (version.isNotEmpty()) {
            found[Triple(url, version, asset)]?.let { return it }
            val release = taggedRelease(api, version) ?: throw IllegalStateException("no release $version")
            return apkAsset(release, asset) ?: throw IllegalStateException("no APK in release $version")
        }
        githubJson("$api/latest")?.let { latest -> apkAsset(JSONObject(latest), asset)?.let { return it } }
        val all = JSONArray(githubJson(page(api, 10)) ?: throw IllegalStateException("no releases"))
        for (i in 0 until all.length()) {
            val r = all.getJSONObject(i)
            if (r.optBoolean("draft")) continue
            apkAsset(r, asset)?.let { return it }
        }
        throw IllegalStateException("no APK in any recent release")
    }

    /// Upstream tag styles differ: `v0.2.22` (DiPlay), `v.4.0.0-beta2`
    /// (Headunit Revived). Try the usual spellings, then look through the
    /// release list for a tag that is the version behind a `v` / `v.` prefix.
    private fun taggedRelease(api: String, version: String): JSONObject? {
        for (tag in listOf("v$version", "v.$version", version)) {
            githubJson("$api/tags/$tag")?.let { return JSONObject(it) }
        }
        val all = JSONArray(githubJson(page(api, 100)) ?: return null)
        for (i in 0 until all.length()) {
            val r = all.getJSONObject(i)
            if (!r.optBoolean("draft") && r.optString("tag_name").trimStart('v', 'V', '.') == version) return r
        }
        return null
    }

    /// The releases API of a project's releases page: GitHub's, or that of
    /// Codeberg (Forgejo), whose release JSON has the same fields
    /// (`tag_name`, `draft`, `prerelease`, `assets[].name`,
    /// `assets[].browser_download_url`) and the same `/latest` and
    /// `/tags/<tag>`. Null for anything else.
    private fun releasesApi(url: String): String? {
        Regex("^https://github\\.com/([^/]+)/([^/]+)/releases/?$").find(url)?.let { m ->
            return "https://api.github.com/repos/${m.groupValues[1]}/${m.groupValues[2]}/releases"
        }
        Regex("^https://codeberg\\.org/([^/]+)/([^/]+)/releases/?$").find(url)?.let { m ->
            return "https://codeberg.org/api/v1/repos/${m.groupValues[1]}/${m.groupValues[2]}/releases"
        }
        return null
    }

    /// GitHub pages with `per_page`, Forgejo with `limit`; each ignores the other's.
    private fun page(api: String, n: Int) = "$api?per_page=$n&limit=$n"

    /// The body for HTTP 200, null for 404, an error otherwise.
    private fun githubJson(url: String): String? {
        val call = Net.quick.newCall(request(url).header("Accept", "application/vnd.github+json").build())
        call.execute().use { response ->
            return when (response.code) {
                HttpURLConnection.HTTP_OK -> response.body!!.string()
                HttpURLConnection.HTTP_NOT_FOUND -> null
                else -> throw IllegalStateException("${response.request.url.host} HTTP ${response.code}")
            }
        }
    }

    /// The asset whose whole name matches [wanted], a regular expression,
    /// when the catalog gives one (a release with several APKs; a pattern
    /// because the name changes with the version); otherwise the first APK
    /// that is not a debug build.
    private fun apkAsset(release: JSONObject, wanted: String): String? = pickAsset(release, wanted)?.getString("browser_download_url")

    private fun assetName(release: JSONObject, wanted: String): String? = pickAsset(release, wanted)?.getString("name")

    private fun pickAsset(release: JSONObject, wanted: String): JSONObject? {
        val assets = release.optJSONArray("assets") ?: return null
        val pattern = if (wanted.isNotEmpty()) Regex(wanted) else null
        for (i in 0 until assets.length()) {
            val a = assets.getJSONObject(i)
            val name = a.getString("name")
            val match = pattern?.matches(name) ?: (name.endsWith(".apk") && !name.contains("debug", ignoreCase = true))
            if (match) return a
        }
        return null
    }

    private fun looksLikeApk(file: File): Boolean {
        if (file.length() < 4) return false
        val head = ByteArray(4)
        FileInputStream(file).use { it.read(head) }
        return head[0] == 'P'.code.toByte() && head[1] == 'K'.code.toByte() && head[2] == 3.toByte() && head[3] == 4.toByte()
    }

    // ~20 MB to read and hash: off the platform main thread, which also
    // carries the HHMIS callbacks.
    /// What an update is checked against: the package, its version and the
    /// SHA-256 of the certificate it is signed with. Android refuses an
    /// update signed by anyone but the installed app's signer; reading it
    /// here lets the Apps screen say so before the installer does.
    /// `package=versionName(versionCode)` for every installed package of
    /// the scooter's maker, `;`-joined: the versions a pulled log has to be
    /// read against.
    private fun stockPackages(): String = try {
        @Suppress("DEPRECATION")
        activity.packageManager.getInstalledPackages(0)
            .filter { p -> STOCK_PREFIXES.any { p.packageName.startsWith(it) } }
            .sortedBy { it.packageName }
            .joinToString(";") { p ->
                @Suppress("DEPRECATION")
                val code = if (Build.VERSION.SDK_INT >= 28) p.longVersionCode else p.versionCode.toLong()
                "${p.packageName}=${p.versionName.orEmpty()}($code)"
            }
    } catch (_: Exception) {
        ""
    }

    /// `name=value` lines for [SURVEY_PROPS] that are set. `SystemProperties`
    /// is not public API, so a head unit that refuses it gives nothing.
    private fun systemProps(): String = try {
        val get = Class.forName("android.os.SystemProperties").getMethod("get", String::class.java)
        SURVEY_PROPS.mapNotNull { name ->
            val value = (get.invoke(null, name) as? String).orEmpty().replace("\n", " ")
            if (value.isEmpty()) null else "$name=$value"
        }.joinToString("\n")
    } catch (_: Exception) {
        ""
    }

    /// `type name (vendor)` for each sensor the head unit has: the ambient
    /// light value is not a light sensor on every scooter.
    private fun sensors(): String = try {
        val manager = activity.getSystemService(android.content.Context.SENSOR_SERVICE) as android.hardware.SensorManager
        manager.getSensorList(android.hardware.Sensor.TYPE_ALL)
            .joinToString("\n") { "${it.stringType} ${it.name} (${it.vendor})" }
    } catch (_: Exception) {
        ""
    }

    private fun ramMb(): String = try {
        val info = android.app.ActivityManager.MemoryInfo()
        (activity.getSystemService(android.content.Context.ACTIVITY_SERVICE) as android.app.ActivityManager).getMemoryInfo(info)
        (info.totalMem / (1024 * 1024)).toString()
    } catch (_: Exception) {
        ""
    }

    private fun packageFacts(info: android.content.pm.PackageInfo?): Map<String, Any?>? {
        if (info == null) return null
        @Suppress("DEPRECATION")
        val cert = (if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners?.firstOrNull() else null)
            ?: info.signatures?.firstOrNull()
        @Suppress("DEPRECATION")
        return mapOf(
            "package" to info.packageName,
            "versionCode" to (if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()),
            "versionName" to info.versionName.orEmpty(),
            "signer" to cert?.let { c ->
                MessageDigest.getInstance("SHA-256").digest(c.toByteArray()).joinToString("") { "%02x".format(it) }
            },
        )
    }

    /// The newest release of a GitHub project and the APK in it that the
    /// catalog would download: `{version, asset}`, or null when there is
    /// none or GitHub cannot be reached. Never downloads anything.
    private fun latestRelease(url: String, asset: String, result: MethodChannel.Result) {
        Thread {
            val found: Map<String, Any?>? = try {
                val api = releasesApi(url)
                if (api == null) {
                    null
                } else {
                    newestWithApk(api, asset)?.let { (release, name) ->
                        val version = release.optString("tag_name").trimStart('v', 'V', '.')
                        apkAsset(release, asset)?.let { found[Triple(url, version, asset)] = it }
                        mapOf("version" to version, "asset" to name)
                    }
                }
            } catch (e: Exception) {
                Analytics.log("platform", "latest_release", mapOf("ok" to false, "error" to e.toString()))
                null
            }
            activity.runOnUiThread { result.success(found) }
        }.start()
    }

    /// The newest release that actually carries the APK asked for. A
    /// project's newest release sometimes has none (notes only, a source
    /// tag, assets still uploading), so the search goes back through the
    /// recent ones: the one GitHub calls latest first, then the other full
    /// releases newest first, then pre-releases (all some projects publish).
    private fun newestWithApk(api: String, asset: String): Pair<JSONObject, String>? {
        val latest = githubJson("$api/latest")?.let { JSONObject(it) }
        latest?.let { r -> assetName(r, asset)?.let { return r to it } }
        val all = JSONArray(githubJson(page(api, 15)) ?: "[]")
        val recent = (0 until all.length()).map { all.getJSONObject(it) }
            .filter { !it.optBoolean("draft") && it.optString("tag_name") != latest?.optString("tag_name") }
        var passed = if (latest == null) 0 else 1
        for (r in recent.filter { !it.optBoolean("prerelease") } + recent.filter { it.optBoolean("prerelease") }) {
            val name = assetName(r, asset)
            if (name != null) {
                if (passed > 0) Analytics.log("platform", "latest_release", mapOf("ok" to true, "passed_over" to passed))
                return r to name
            }
            passed++
        }
        return null
    }

    /// What each network the head unit is on can reach of GitHub, a stage at
    /// a time: the name looked up, a connection opened, an answer over
    /// HTTPS. On a scooter every release lookup away from Wi-Fi
    /// timed out and nothing said which of the three it was. Reads only;
    /// the head unit's own address is left out.
    private fun networkCheck(result: MethodChannel.Result) {
        // An exception that leaves a bare thread ends the whole app, not
        // just the check.
        Thread {
            val found = try {
                checkNetworks()
            } catch (e: Exception) {
                Analytics.log("net", "check_error", mapOf("error" to e.toString()))
                emptyList()
            }
            activity.runOnUiThread { result.success(found) }
        }.start()
    }

    private fun checkNetworks(): List<Map<String, Any?>> {
        run {
            val cm = activity.getSystemService(android.net.ConnectivityManager::class.java)
            // GitHub's three, then four that are not GitHub, to tell "GitHub
            // is not let through" from "nothing is": two ordinary sites,
            // and Cloudflare by address over IPv4 and over IPv6 (GitHub has
            // IPv4 only). On mobile data, GitHub's names have
            // resolved and connected, and then nothing came back.
            val hosts = listOf(
                "api.github.com", "github.com", "release-assets.githubusercontent.com",
                "www.google.com", "example.com", "1.1.1.1", "2606:4700:4700::1111",
            )
            val rows = mutableListOf<Pair<Map<String, Any?>, List<java.util.concurrent.ConcurrentHashMap<String, Any>>>>()
            val threads = mutableListOf<Thread>()
            for (network in cm?.allNetworks.orEmpty()) {
                val facts = Net.facts(cm, network) ?: continue
                // Whether 1.1.1.1 can be reached over this network and
                // resolves the name; OpenDash's own requests rely on it.
                val fallback = java.util.concurrent.ConcurrentHashMap<String, Any>()
                threads += Thread {
                    val t = android.os.SystemClock.elapsedRealtime()
                    try {
                        fallback["addresses"] = Net.cloudflare(network.socketFactory).lookup(hosts.first()).size
                        fallback["ok"] = true
                    } catch (e: Exception) {
                        fallback["ok"] = false
                        fallback["error"] = (e.cause ?: e).let { c -> c.javaClass.simpleName + (c.message?.let { ": " + it.take(80) } ?: "") }
                    }
                    fallback["took_ms"] = android.os.SystemClock.elapsedRealtime() - t
                    // Port 853 is what Android's own Private DNS setting would
                    // use: whether a system-wide switch could work here.
                    try {
                        network.socketFactory.createSocket().use { it.connect(java.net.InetSocketAddress(Net.CLOUDFLARE_DNS.first(), 853), 5_000) }
                        fallback["dot"] = true
                    } catch (e: Exception) {
                        fallback["dot"] = false
                    }
                }.also { it.isDaemon = true; it.start() }
                val checks = hosts.map { host ->
                    val row = java.util.concurrent.ConcurrentHashMap<String, Any>(mapOf("host" to host, "stage" to "dns"))
                    threads += Thread { reach(network, host, row) }.also { it.isDaemon = true; it.start() }
                    row
                }
                rows += (facts + ("cloudflare" to fallback)) to checks
            }
            // A name lookup has no timeout of its own: what has not answered
            // by now is reported as stuck at the stage it reached.
            val until = android.os.SystemClock.elapsedRealtime() + 20_000
            for (t in threads) t.join(maxOf(1, until - android.os.SystemClock.elapsedRealtime()))
            val found = rows.map { (facts, checks) ->
                facts + ("cloudflare" to HashMap(facts["cloudflare"] as Map<*, *>)) + ("hosts" to checks.map { HashMap(it) })
            }
            return found
        }
    }

    /// One host over one network. `stage` is where it is, or where it
    /// stopped: dns, connect, https, then done.
    private fun reach(network: android.net.Network, host: String, row: MutableMap<String, Any>) {
        fun now() = android.os.SystemClock.elapsedRealtime()
        var t = now()
        try {
            val addresses = network.getAllByName(host)
            row["dns_ms"] = now() - t
            row["addresses"] = addresses.size
            row["v6"] = addresses.count { it is java.net.Inet6Address }
            row["stage"] = "connect"
            t = now()
            network.socketFactory.createSocket().use { it.connect(java.net.InetSocketAddress(addresses.first(), 443), 8_000) }
            row["connect_ms"] = now() - t
            row["stage"] = "https"
            t = now()
            val conn = network.openConnection(URL(if (host.contains(':')) "https://[$host]/" else "https://$host/")) as HttpURLConnection
            try {
                conn.connectTimeout = 8_000
                conn.readTimeout = 8_000
                conn.requestMethod = "HEAD"
                conn.instanceFollowRedirects = false
                conn.setRequestProperty("User-Agent", "OpenDash")
                row["status"] = conn.responseCode
            } finally {
                conn.disconnect()
            }
            row["https_ms"] = now() - t
            row["stage"] = "done"
        } catch (e: Exception) {
            row["error"] = e.javaClass.simpleName + (e.message?.let { ": " + it.take(80) } ?: "")
            row["failed_ms"] = now() - t
        }
    }
}
