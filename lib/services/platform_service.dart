import 'dart:async';
import 'package:flutter/foundation.dart';

import '../models/ota_shield.dart';
import 'analytics_logger.dart';

/// A package's name, version and the SHA-256 of its signing certificate
/// (null when Android would not say).
class ApkInfo {
  const ApkInfo({required this.package, required this.versionCode, required this.versionName, required this.signer});
  final String package;
  final int versionCode;
  final String versionName;
  final String? signer;

  static ApkInfo? fromMap(Map<Object?, Object?>? m) => m == null
      ? null
      : ApkInfo(
          package: m['package'] as String? ?? '',
          versionCode: (m['versionCode'] as num?)?.toInt() ?? 0,
          versionName: m['versionName'] as String? ?? '',
          signer: m['signer'] as String?,
        );
}

abstract class PlatformService {
  // The reads Android answers at once are plain calls, not Futures: on
  // the scooter they go to Kotlin directly (pigeons/platform_reads.dart).
  bool isInstalled(String packageName);
  Future<bool> launchApp(String packageName);

  /// The system "default home app" chooser, so switching launchers is an
  /// explicit, reversible choice the user makes in Android's own UI.
  Future<bool> openHomeSettings();

  /// Whether OpenDash is the current HOME launcher.
  /// Boot-time force-stops skip when this is false so a user who switched
  /// launchers isn't fought with.
  bool isDefaultHome();
  Future<bool> installApk(String filePath);

  /// Android's per-app "Install unknown apps" permission for OpenDash.
  bool canInstallApks();
  Future<bool> openInstallPermissionSettings();

  /// "Display over other apps": the island, which is the way back to
  /// OpenDash from an app opened in Apps (the head unit has no Back / Home
  /// buttons).
  bool canDrawOverlays();
  Future<bool> openOverlayPermissionSettings();
  /// Android's hotspot page and its notification-access page, opened on top
  /// of the dashboard in our own task so their back arrow returns here.
  Future<bool> openHotspotSettings();

  /// Android's Wi-Fi panel (Android 10+): the network list and its password
  /// prompt, without the rest of Android Settings.
  Future<bool> openWifiPanel();
  Future<bool> openNotificationAccessSettings();

  /// Android's "Usage access" page, where the rider lets OpenDash see which
  /// app is in front.
  Future<bool> openUsageAccessSettings();

  bool hasUsageAccess();

  /// The package in front: null without that access, empty when Android has
  /// not said yet.
  String? foregroundPackage();

  /// Notification access is what lets the media bridge see the music a
  /// phone-projection app is playing.
  bool hasNotificationAccess();
  Future<bool> bringToFront();

  /// Downloads an APK to the app's cache. For a GitHub releases page,
  /// [version] picks the release; without one it is the newest.
  /// [asset] is a pattern for the one APK to take where a release carries
  /// several.
  Future<String?> downloadFile(String url, String filename, {String version = '', String asset = ''});

  /// The newest release of a GitHub project and the APK in it that
  /// [downloadFile] would fetch; null when there is none or GitHub cannot be
  /// reached. Downloads nothing.
  Future<({String version, String asset})?> latestRelease(String url, {String asset = ''});

  /// What a downloaded APK, or an installed app, is: the facts an update is
  /// checked on. Null when the file is not an APK or the app is not there.
  /// Stops the download being written to [filename], if there is one.
  Future<void> cancelDownload(String filename);
  Future<ApkInfo?> apkInfo(String filePath);
  Future<ApkInfo?> installedInfo(String packageName);


  /// The package's external files dir (`Android/data/<pkg>/files`), readable
  /// by `adb pull` without root; null where there is none.
  String? externalFilesDir();

  /// What each network the head unit is on can reach of GitHub: one map per
  /// network (`transport`, `default`, `validated`, `dns`, `private_dns`) with
  /// a `hosts` list (`host`, `stage`, and the time each stage took).
  Future<List<Map<String, Object?>>> networkCheck();

  /// What OTA Shield's daemon says on its local control port (not running
  /// when nothing answers), and what its service says where it has one.
  Future<OtaShieldReport> otaShieldStatus();

  /// Asks OTA Shield to activate its block; true when it was asked. Its
  /// progress comes back in [otaShieldStatus].
  Future<bool> otaShieldActivate();

  /// Asks OTA Shield to lift its engaged boot fail-safe; its answer.
  Future<bool> otaShieldDisableFailsafe();

  /// `{model, release}` from `android.os.Build`.
  Map<String, String> deviceInfo();

  // ---- OpenDash updating itself (`lib/state/ota_state.dart`) ----

  /// Asks GitHub for the newest full release of [repo]. `status` is the
  /// HTTP status, or 0 for no answer; a 200 carries the release (see
  /// `SelfUpdate.check` in the Android code).
  Future<Map<String, Object?>> selfUpdateCheck(String repo, {String? etag});

  /// Posts the anonymous usage ping [body] to [url]; the HTTP status, or 0
  /// for no answer.
  Future<int> usagePing(String url, String body);

  /// Downloads OpenDash's own update from [url]; the file's path, or null.
  /// [cancelDownload] with [selfUpdateFile] stops it.
  Future<String?> selfUpdateDownload(String url);
  static const selfUpdateFile = 'opendash-update.apk';

  /// Bytes written so far by the download of [filename].
  int downloadProgress(String filename);
  Future<String?> fileSha256(String filePath);
  Future<bool> deleteFile(String filePath);

  /// Hands the checked file to Android's installer as build [build]. Null
  /// when Android took it (its own confirmation follows), else why not.
  Future<String?> selfUpdateInstall(String filePath, int build);

  /// The update handed to the installer and not yet seen to run: `from`,
  /// `to`, `starts`, `installed`, and the installer's `status` / `message`
  /// when it has answered. `to` is 0 when nothing is pending.
  Map<String, Object?> updateRecord();
  Future<void> updateRecordClear({bool resultOnly = false});

  // ---- updates the companion phone app sends (`companion/` in the external files dir) ----

  /// Writes OpenDash's answer for the companion app (`companion/accepts.json`).
  Future<void> companionPublish(String json);

  /// The release file the companion left; null while it or the APK it
  /// names is missing. Cheap, read on every look.
  Future<String?> companionIncomingRelease();

  /// Copies the APK the release file names into OpenDash's private cache,
  /// one file per [build] (what is checked and installed); its path, or null.
  Future<String?> companionIncomingCopy(int build);

  /// Removes what the companion left.
  Future<void> companionIncomingClear();
}

/// Runs a platform call and logs `platform.call` with its outcome. The
/// arguments are reduced to a short hash so URLs and file paths stay out
/// of the log while repeated calls still group together. A boolean answer
/// is logged as `result`: for a query (`canDrawOverlays`, `isInstalled`)
/// `success` only says the call went through.
Future<T> tracedPlatformCall<T>(
  String method,
  FutureOr<T> Function() call, {
  Object? args,
  bool Function(T result)? ok,
}) async {
  final started = AnalyticsLogger.instance.monoMicros;
  int tookMs() => (AnalyticsLogger.instance.monoMicros - started) ~/ 1000;
  final hash = args == null ? null : argsHash(args);
  try {
    final result = await call();
    final success = ok == null ? result != false && result != null : ok(result);
    logEvent('platform', 'call', {
      'method': method,
      'args_hash': hash,
      'success': success,
      if (result is bool) 'result': result,
      'took_ms': tookMs(),
    });
    return result;
  } catch (e) {
    logEvent('platform', 'call', {
      'method': method,
      'args_hash': hash,
      'success': false,
      'took_ms': tookMs(),
      'error': e.toString(),
    });
    rethrow;
  }
}

/// FNV-1a over the argument text, eight hex chars.
@visibleForTesting
String argsHash(Object args) {
  var h = 0x811c9dc5;
  for (final unit in args.toString().codeUnits) {
    h ^= unit;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}
