import 'package:flutter/services.dart';

import 'analytics_logger.dart';
import 'platform_reads.g.dart';
import '../models/ota_shield.dart';
import 'platform_service.dart';

class DevicePlatformService implements PlatformService {
  static const _channel = MethodChannel('in.abhijithvijayan.opendash.platform');

  /// A call the Android side could not carry out answers null, which every
  /// caller already reads as "no" or "nothing". Thrown, it would surface
  /// seconds later in whatever was waiting on it, an install or an update
  /// started by a tap, as an unhandled error: OpenDash's error screen over
  /// the dashboard (seen on a scooter, from a late answer of another
  /// kind).
  static Future<T?> _invoke<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } catch (e) {
      logEvent('platform', 'error', {'method': method, 'error': e.toString()});
      return null;
    }
  }

  static PlatformReadsApiForNativeInterop? _reads;
  static const directSlowMicros = 4000;

  /// A read Kotlin answers directly, with no channel and no Future. Looked
  /// up on first use, not at start: before `main()` the direct link is not
  /// up. A failure answers [otherwise] and is logged, as `_invoke` does.
  static T _read<T>(String method, T Function(PlatformReadsApiForNativeInterop reads) call, T otherwise) {
    try {
      final first = _reads == null;
      final started = AnalyticsLogger.instance.monoMicros;
      final result = call(_reads ??= PlatformReadsApiForNativeInterop.getInstance()!);
      if (first) logEvent('platform', 'direct_ok', {'method': method});
      // A direct read holds the thread that builds frames: one that takes
      // this long does not belong among them.
      final took = AnalyticsLogger.instance.monoMicros - started;
      if (took >= directSlowMicros) logEvent('platform', 'direct_slow', {'method': method, 'took_ms': took ~/ 1000});
      return result;
    } catch (e) {
      logEvent('platform', 'error', {'method': method, 'direct': true, 'error': e.toString()});
      return otherwise;
    }
  }

  @override
  bool isInstalled(String packageName) => _read('isInstalled', (r) => r.isInstalled(packageName), false);

  @override
  Future<bool> launchApp(String packageName) async {
    final result = await _invoke<bool>('launchApp', packageName);
    return result ?? false;
  }

  @override
  Future<bool> openHomeSettings() async {
    final result = await _invoke<bool>('openHomeSettings');
    return result ?? false;
  }

  @override
  bool isDefaultHome() => _read('isDefaultHome', (r) => r.isDefaultHome(), false);

  @override
  Future<bool> installApk(String filePath) async {
    final result = await _invoke<bool>('installApk', filePath);
    return result ?? false;
  }

  @override
  bool canInstallApks() => _read('canInstallApks', (r) => r.canInstallApks(), false);

  @override
  Future<bool> openInstallPermissionSettings() async =>
      await _invoke<bool>('openInstallPermissionSettings') ?? false;

  @override
  bool canDrawOverlays() => _read('canDrawOverlays', (r) => r.canDrawOverlays(), false);

  @override
  Future<bool> openOverlayPermissionSettings() async =>
      await _invoke<bool>('openOverlayPermissionSettings') ?? false;

  @override
  Future<bool> openHotspotSettings() async => await _invoke<bool>('openHotspotSettings') ?? false;

  @override
  Future<bool> openWifiPanel() async => await _invoke<bool>('openWifiPanel') ?? false;

  @override
  Future<bool> openNotificationAccessSettings() async =>
      await _invoke<bool>('openNotificationAccessSettings') ?? false;

  @override
  Future<bool> openUsageAccessSettings() async => await _invoke<bool>('openUsageAccessSettings') ?? false;

  @override
  String? foregroundPackage() => _read('foregroundPackage', (r) => r.foregroundPackage(), null);

  @override
  bool hasUsageAccess() => foregroundPackage() != null;

  @override
  bool hasNotificationAccess() => _read('hasNotificationAccess', (r) => r.hasNotificationAccess(), false);



  @override
  Future<bool> bringToFront() async => await _invoke<bool>('bringToFront') ?? false;

  @override
  Future<String?> downloadFile(String url, String filename, {String version = '', String asset = ''}) async {
    final result = await _invoke<String>('downloadFile', {
      'url': url,
      'filename': filename,
      'version': version,
      'asset': asset,
    });
    return result;
  }

  @override
  Future<void> cancelDownload(String filename) => _invoke<bool>('cancelDownload', filename);

  @override
  Future<({String version, String asset})?> latestRelease(String url, {String asset = ''}) async {
    final m = await _invoke<Map<Object?, Object?>>('latestRelease', {'url': url, 'asset': asset});
    final version = m?['version'] as String?;
    final name = m?['asset'] as String?;
    return version == null || name == null ? null : (version: version, asset: name);
  }

  @override
  Future<ApkInfo?> apkInfo(String filePath) async =>
      ApkInfo.fromMap(await _invoke<Map<Object?, Object?>>('apkInfo', filePath));

  @override
  Future<ApkInfo?> installedInfo(String packageName) async =>
      ApkInfo.fromMap(await _invoke<Map<Object?, Object?>>('installedInfo', packageName));

  @override
  String? externalFilesDir() => _read('externalFilesDir', (r) => r.externalFilesDir(), null);

  @override
  Future<OtaShieldReport> otaShieldStatus() async =>
      OtaShieldReport.fromMap(await _invoke<Map<Object?, Object?>>('otaShieldStatus'));

  @override
  Future<bool> otaShieldActivate() async => await _invoke<bool>('otaShieldActivate') ?? false;

  @override
  Future<bool> otaShieldDisableFailsafe() async => await _invoke<bool>('otaShieldDisableFailsafe') ?? false;

  @override
  Future<List<Map<String, Object?>>> networkCheck() async {
    final result = await _invoke<List<Object?>>('networkCheck');
    Map<String, Object?> typed(Object? m) => {for (final e in (m as Map).entries) '${e.key}': e.value};
    return [
      for (final n in result ?? const [])
        {
          ...typed(n),
          if ((n as Map)['cloudflare'] != null) 'cloudflare': typed(n['cloudflare']),
          'hosts': [for (final h in n['hosts'] as List? ?? const []) typed(h)],
        },
    ];
  }

  static Map<String, Object?> _typed(Map<Object?, Object?>? m) => {for (final e in (m ?? const {}).entries) '${e.key}': e.value};

  @override
  Future<Map<String, Object?>> selfUpdateCheck(String repo, {String? etag}) async =>
      _typed(await _invoke<Map<Object?, Object?>>('selfUpdateCheck', {'repo': repo, 'etag': etag}));

  @override
  Future<int> usagePing(String url, String body) async => await _invoke<int>('usagePing', {'url': url, 'body': body}) ?? 0;

  @override
  Future<String?> selfUpdateDownload(String url) => _invoke<String>('selfUpdateDownload', url);

  @override
  int downloadProgress(String filename) => _read('downloadProgress', (r) => r.downloadProgress(filename), 0);

  @override
  Future<String?> fileSha256(String filePath) => _invoke<String>('fileSha256', filePath);

  @override
  Future<bool> deleteFile(String filePath) async => await _invoke<bool>('deleteFile', filePath) ?? false;

  @override
  Future<String?> selfUpdateInstall(String filePath, int build) =>
      _invoke<String>('selfUpdateInstall', {'path': filePath, 'build': build});

  @override
  Map<String, Object?> updateRecord() => _read('updateRecord', (r) => r.updateRecord(), const {});

  @override
  Future<void> updateRecordClear({bool resultOnly = false}) => _invoke<bool>('updateRecordClear', resultOnly ? 'result' : 'all');

  @override
  Future<void> companionPublish(String json) => _invoke<bool>('companionPublish', json);

  @override
  Future<String?> companionIncomingRelease() => _invoke<String>('companionIncomingRelease');

  @override
  Future<String?> companionIncomingCopy(int build) => _invoke<String>('companionIncomingCopy', build);

  @override
  Future<void> companionIncomingClear() => _invoke<bool>('companionIncomingClear');

  @override
  Map<String, String> deviceInfo() {
    final known = _device;
    if (known != null) return known;
    final read = _read('deviceInfo', (r) => r.deviceInfo(), const <String, String>{});
    if (read.isNotEmpty) _device = read;
    return read;
  }

  /// Read once a run: it takes about 40 ms on the head unit (measured
  /// twice: at start and again from the Apps list as the scooter unlocked).
  /// Nothing in it changes but the uptime, which only start-up reads.
  static Map<String, String>? _device;
}
