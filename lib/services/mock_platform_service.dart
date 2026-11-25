import '../models/app_catalog.dart';
import '../models/ota_shield.dart';
import 'platform_service.dart';

class MockPlatformService implements PlatformService {
  final Set<String> _installed = {};
  final launched = <String>[];
  int homeSettingsOpened = 0;

  Set<String> get installedPackages => _installed;

  void setInstalled(String packageName, {bool installed = true}) {
    if (installed) {
      _installed.add(packageName);
    } else {
      _installed.remove(packageName);
    }
  }

  @override
  bool isInstalled(String packageName) => _installed.contains(packageName);

  @override
  Future<bool> launchApp(String packageName) async {
    launched.add(packageName);
    return _installed.contains(packageName);
  }

  @override
  Future<bool> openHomeSettings() async {
    homeSettingsOpened++;
    return true;
  }

  bool defaultHome = true;
  @override
  bool isDefaultHome() => defaultHome;

  /// Tests flip this to exercise the "Install unknown apps" detour.
  bool installAllowed = true;
  int permissionScreens = 0;

  @override
  bool canInstallApks() => installAllowed;

  @override
  Future<bool> openInstallPermissionSettings() async {
    permissionScreens++;
    return true;
  }

  bool overlayAllowed = true;
  int overlayScreens = 0;
  int broughtToFront = 0;

  @override
  bool canDrawOverlays() => overlayAllowed;

  @override
  Future<bool> openOverlayPermissionSettings() async {
    overlayScreens++;
    return true;
  }

  final systemPages = <String>[];
  bool notificationAccess = true;

  @override
  Future<bool> openWifiPanel() async {
    systemPages.add('wifi');
    return true;
  }

  @override
  Future<bool> openHotspotSettings() async {
    systemPages.add('hotspot');
    return true;
  }

  @override
  Future<bool> openNotificationAccessSettings() async {
    systemPages.add('notification_access');
    return true;
  }

  @override
  bool hasNotificationAccess() => notificationAccess;

  @override
  Future<bool> openUsageAccessSettings() async {
    systemPages.add('usage_access');
    return true;
  }

  /// What Android would say is in front; null plays "no usage access".
  String? frontPackage;

  @override
  String? foregroundPackage() => frontPackage;

  bool usageAccess = true;

  @override
  bool hasUsageAccess() => usageAccess;

  /// Plays the head unit's command service refusing every grant, so a test
  /// reaches Android's own pages.
  bool grantsRefused = false;

  /// What `Access.grant` would do on the head unit, by access name.
  bool grant(String access) {
    if (grantsRefused) return false;
    switch (access) {
      case 'overlay':
        overlayAllowed = true;
      case 'install':
        installAllowed = true;
      case 'music':
        notificationAccess = true;
      case 'front':
        usageAccess = true;
      case 'home':
        defaultHome = true;
    }
    return true;
  }



  @override
  Future<bool> bringToFront() async {
    broughtToFront++;
    return true;
  }

  /// Test counters.
  int downloads = 0;
  int installs = 0;

  @override
  Future<bool> installApk(String filePath) async {
    installs++;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return true;
  }

  @override
  Future<String?> downloadFile(String url, String filename, {String version = '', String asset = ''}) async {
    downloads++;
    downloadedVersions.add(version);
    downloadedAssets.add(asset);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (cancelledDownloads.remove(filename)) return null;
    return '/mock/cache/apks/$filename';
  }

  final cancelledDownloads = <String>{};

  @override
  Future<void> cancelDownload(String filename) async => cancelledDownloads.add(filename);

  /// What GitHub would answer, by release URL; nothing is "newer" until a
  /// test or the dev panel says so.
  final latest = <String, ({String version, String asset})>{};

  /// Installed apps and downloaded files, by package and by path.
  final installedInfos = <String, ApkInfo>{};
  final apkInfos = <String, ApkInfo>{};

  /// GitHub cannot be reached.
  bool releasesUnreachable = false;

  /// Unless a test says otherwise, the newest release is the one that is
  /// installed (or "mock" when nothing is), so nothing looks out of date.
  @override
  Future<({String version, String asset})?> latestRelease(String url, {String asset = ''}) async {
    if (releasesUnreachable) return null;
    final set = latest[url];
    if (set != null) return set;
    final app = appCatalog.where((a) => a.releaseUrl == url).firstOrNull;
    return (version: installedInfos[app?.package]?.versionName ?? 'mock', asset: 'mock.apk');
  }

  /// Unless a test says otherwise, a catalog app's download is that app,
  /// signed with the catalog's certificate, so mock installs go through.
  @override
  Future<ApkInfo?> apkInfo(String filePath) async {
    if (apkUnreadable) return null;
    if (filePath == updatePath) {
      final build = downloadedBuild ?? (RegExp(r'"build": (\d+)').firstMatch('${release?['release']}')?.group(1));
      return ApkInfo(package: downloadedPackage, versionCode: int.tryParse('$build') ?? 0, versionName: 'mock', signer: downloadedSigner);
    }
    final set = apkInfos[filePath];
    if (set != null) return set;
    final name = filePath.split('/').last;
    for (final app in appCatalog) {
      if (name == '${app.id}.apk' || name == '${app.id}-update.apk') {
        return ApkInfo(package: app.package, versionCode: 1, versionName: 'mock', signer: signerOverride ?? app.signer);
      }
    }
    return null;
  }

  @override
  Future<ApkInfo?> installedInfo(String packageName) async => packageName == ownPackage
      ? ApkInfo(package: ownPackage, versionCode: installedBuild, versionName: 'mock', signer: ownSigner)
      : installedInfos[packageName];

  /// The version asked for by each download, in order.
  final downloadedVersions = <String>[];
  final downloadedAssets = <String>[];

  /// Plays a download that is not an APK at all.
  bool apkUnreadable = false;

  /// Plays a download signed by someone else.
  String? signerOverride;

  @override
  String? externalFilesDir() => null;

  List<Map<String, Object?>> networks = [
    {
      'transport': 'wifi',
      'default': true,
      'internet': true,
      'validated': true,
      'dns': ['192.168.1.1'],
      'private_dns': 'off',
      'ipv4': true,
      'ipv6': false,
      'mtu': 1500,
      'cloudflare': {'ok': true, 'addresses': 2, 'took_ms': 120, 'dot': true},
      'hosts': [
        {'host': 'api.github.com', 'stage': 'done', 'dns_ms': 41, 'addresses': 1, 'v6': 0, 'connect_ms': 38, 'status': 200, 'https_ms': 310},
        {'host': 'github.com', 'stage': 'https', 'dns_ms': 12, 'addresses': 1, 'v6': 0, 'connect_ms': 35, 'error': 'SocketTimeoutException: timeout', 'failed_ms': 8003},
        {'host': 'release-assets.githubusercontent.com', 'stage': 'dns', 'error': 'UnknownHostException', 'failed_ms': 5020},
      ],
    },
  ];

  @override
  Future<List<Map<String, Object?>>> networkCheck() async => networks;

  /// What OTA Shield's daemon answers; the dev panel and tests set it.
  OtaShieldReport otaShield = OtaShieldReport.notRunning;

  @override
  Future<OtaShieldReport> otaShieldStatus({bool serviceWhenRunning = true}) async {
    otaShieldStatusCalls.add(serviceWhenRunning);
    return otaShield;
  }

  /// Each status read, by whether the service was asked while running.
  final List<bool> otaShieldStatusCalls = [];

  /// Calls OpenDash made to OTA Shield's service, in order.
  final List<String> otaShieldCalls = [];

  @override
  Future<bool> otaShieldActivate() async {
    otaShieldCalls.add('activate');
    return otaShield.service != null;
  }

  @override
  Future<bool> otaShieldDisableFailsafe() async {
    otaShieldCalls.add('disableFailsafe');
    return otaShield.service != null;
  }

  @override
  Map<String, String> deviceInfo() => {'model': 'mock', 'release': 'mock', 'abis': abis};

  /// Empty, like a platform that does not say.
  String abis = '';

  // ---- OpenDash updating itself: a fake release source ----

  static const ownPackage = 'in.abhijithvijayan.opendash';
  static const ownSigner = 'aa11';
  static const updatePath = '/cache/apks/opendash-update.apk';

  /// The build that is "installed", and what GitHub "answers".
  int installedBuild = 100;
  int checkStatus = 200;
  Map<String, Object?>? release = fakeRelease();
  final checks = <String?>[];

  /// What the downloaded file turns out to be.
  bool downloadFails = false;
  String downloadedSha = 'c0ffee';
  String downloadedPackage = ownPackage;
  int? downloadedBuild;
  String downloadedSigner = ownSigner;
  final deleted = <String>[];

  /// The installer: null takes the file, a string refuses it.
  String? installError;
  final selfInstalls = <(String, int)>[];
  Map<String, Object?> record = {'from': 0, 'to': 0, 'starts': 0};

  static Map<String, Object?> fakeRelease({int build = 120, String version = '0.2.0', int minBuild = 0, String sha = 'c0ffee'}) => {
        'tag': 'v$version',
        'notes': 'A simulated release.\nNothing real is downloaded.',
        'url': 'https://github.com/owner/repo/releases/tag/v$version',
        'published': '2026-11-16T10:00:00Z',
        'release': '{"version": "$version", "build": $build, "apk": "opendash-$version.apk", "sha256": "$sha", "git_sha": "abc1234", "min_build": $minBuild}',
        'apk_url': 'https://example.invalid/opendash-$version.apk',
        'apk_size': 24000000,
      };

  final usagePings = <String>[];
  int usagePingStatus = 204;

  @override
  Future<int> usagePing(String url, String body) async {
    usagePings.add(body);
    return usagePingStatus;
  }

  @override
  Future<Map<String, Object?>> selfUpdateCheck(String repo, {String? etag}) async {
    checks.add(etag);
    if (checkStatus != 200 || release == null) return {'status': release == null && checkStatus == 200 ? 404 : checkStatus};
    return {'status': 200, 'etag': 'W/"mock"', ...release!};
  }

  @override
  Future<String?> selfUpdateDownload(String url) async {
    await Future<void>.delayed(const Duration(seconds: 3));
    return downloadFails ? null : updatePath;
  }

  @override
  int downloadProgress(String filename) => 12000000;

  @override
  Future<String?> fileSha256(String filePath) async => downloadedSha;

  @override
  Future<bool> deleteFile(String filePath) async {
    deleted.add(filePath);
    return true;
  }

  @override
  Future<String?> selfUpdateInstall(String filePath, int build) async {
    selfInstalls.add((filePath, build));
    if (installError != null) return installError;
    record = {'from': installedBuild, 'to': build, 'starts': 0};
    return null;
  }

  @override
  Map<String, Object?> updateRecord() => {...record, 'installed': installedBuild};

  @override
  Future<void> updateRecordClear({bool resultOnly = false}) async {
    record = resultOnly ? ({...record}..remove('status')..remove('message')) : {'from': 0, 'to': 0, 'starts': 0};
  }

  /// What OpenDash wrote for the companion app, in order.
  final published = <String>[];

  /// The release file the companion app left, and how often its APK was
  /// copied out.
  String? incoming;
  static String incomingCopyPathFor(int build) => '/cache/apks/opendash-incoming-$build.apk';
  int incomingCopies = 0;
  int incomingCleared = 0;

  @override
  Future<void> companionPublish(String json) async => published.add(json);

  @override
  Future<String?> companionIncomingRelease() async => incoming;

  @override
  Future<String?> companionIncomingCopy(int build) async {
    if (incoming == null) return null;
    incomingCopies++;
    return incomingCopyPathFor(build);
  }

  @override
  Future<void> companionIncomingClear() async {
    incomingCleared++;
    incoming = null;
  }
}
