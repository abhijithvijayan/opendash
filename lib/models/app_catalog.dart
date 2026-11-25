import '../constants.dart';

enum AppStatus {
  notInstalled,

  /// Waiting its turn: downloads run one at a time.
  queued,
  downloading,

  /// Downloaded and checked; Android's installer has not been opened for
  /// it yet (the scooter was moving or locked, or the rider backed out).
  ready,
  installing,
  installed,
  updateAvailable;

  /// On the head unit and able to be opened.
  bool get present => this == installed || this == updateAvailable;
}

class CatalogApp {
  const CatalogApp({
    required this.id,
    required this.name,
    required this.package,
    required this.description,
    required this.releaseUrl,
    required this.license,
    this.signer = '',
    this.requiresPhone,
    this.comingSoon = false,
    this.systemApp = false,
    this.projection = false,
    this.passcode = false,
    this.asset = '',
    this.appName = '',
    this.abiAssets = const {},
    this.shortName = '',
  });

  /// For a button no wider than the boot button, where the full name was
  /// shrunk to fit: "Android Settings" came out about 11 px high on the
  /// dashboard's way back, too small to read.
  final String shortName;

  /// The name for a narrow button: at most [chipNameMax] characters.
  String get chipName => shortName.isEmpty ? name : shortName;
  static const chipNameMax = 8;

  static const stockDashboardId = 'stock-dashboard';
  static const androidSettingsId = 'android-settings';
  static const otaShieldId = 'ota-shield';

  final String id;
  final String name;
  final String package;
  final String description;
  final String releaseUrl;

  /// Lower-case SHA-256 of the certificate the app's releases are signed
  /// with. This is what an install is held to: the newest release of
  /// [releaseUrl] is downloaded, and installed only if it is [package] and
  /// signed with this certificate. No version and no file is named here, so
  /// a new release needs no new OpenDash; what is trusted is the developer's
  /// key. An entry without one is not installable at all. To read a
  /// certificate, run `apksigner verify --print-certs` on a release APK.
  final String signer;
  final String license;
  final String? requiresPhone;
  final bool comingSoon;

  /// Part of the system image: always installed, nothing to download.
  final bool systemApp;

  /// Phone projection (Android Auto, CarPlay): meant to stay up while riding,
  /// so moving off does not snap back to the dashboard.
  final bool projection;

  /// Opens only after the passcode (Android Settings can change the home
  /// app, disable apps, or reset the head unit).
  final bool passcode;

  /// The release asset to download, as a pattern its whole file name must
  /// match, for projects that publish several APKs in one release (a
  /// pattern, because the name carries the version). Empty: the first one
  /// that is not a debug build.
  final String asset;

  /// A smaller build for one processor type, by ABI name, for projects that
  /// publish one. [asset] is the build that runs anywhere and is what a head
  /// unit not listed here gets: OpenDash is installed on scooters of more
  /// than one generation.
  final Map<String, String> abiAssets;

  /// The asset pattern for a head unit that supports [abis], most preferred
  /// first.
  String assetFor(List<String> abis) {
    for (final abi in abis) {
      final pattern = abiAssets[abi];
      if (pattern != null) return pattern;
    }
    return asset;
  }

  /// What the app itself is called, shown under [name] when the tile is
  /// named for what it does ("Browser", by DuckDuckGo).
  final String appName;

  /// Where its releases are published, as the rider is told before an
  /// install.
  String get source => releaseUrl.startsWith('https://codeberg.org/') ? 'Codeberg' : 'GitHub';

  /// Fetched and installed by OpenDash, as opposed to part of the image.
  bool get downloadable => !systemApp && !comingSoon;

  /// Has a signing certificate to hold a download to.
  bool get pinned => signer.length == 64;
}

const otaShieldPackage = 'com.hxmst.otablocker';

// Every signer below was read with `apksigner verify --print-certs` from a
// release APK downloaded from the project's GitHub releases. For the first
// six, that file's SHA-256 equalled the checksum the catalog pinned
// before. None
// but Android Auto and CarPlay has been installed on the scooter.
const appCatalog = [
  CatalogApp(
    id: 'android-auto',
    name: 'Android Auto',
    shortName: 'Auto',
    package: 'com.andrerinas.headunitrevived',
    description: 'Mirror Android Auto from your phone to the scooter display',
    releaseUrl: 'https://github.com/andreknieriem/open-headunit/releases',
    signer: '615bc3c7a74839918d01517e49397f503a5473f89266af55a26d485c1e86155d',
    license: 'AGPL-3.0',
    appName: 'Headunit Revived',
    requiresPhone: 'Android 10+ with Android Auto',
    projection: true,
  ),
  CatalogApp(
    id: 'carplay',
    name: 'CarPlay',
    package: 'com.shihab.diplay',
    description: 'Mirror Apple CarPlay from your iPhone to the scooter display',
    releaseUrl: 'https://github.com/shihabal3amri/DiPlay/releases',
    signer: '87b38b12788dcb202a961215f2572e30ec2dc9d8ef4bc070d05f77e49291a363',
    license: 'GPL-3.0',
    appName: 'DiPlay',
    requiresPhone: 'iPhone with CarPlay',
    projection: true,
  ),
  // None of the five below is phone projection, so moving off returns to
  // the dashboard as it does from Android Settings.
  CatalogApp(
    id: 'browser',
    name: 'Browser',
    package: 'com.duckduckgo.mobile.android',
    description: 'A private web browser',
    releaseUrl: 'https://github.com/duckduckgo/Android/releases',
    signer: 'bb7bb31c573c46a1da7fc5c528a6acf432108456feec50810c7f33694eb3d2d4',
    license: 'Apache-2.0',
    appName: 'DuckDuckGo',
  ),
  CatalogApp(
    id: 'maps',
    name: 'Maps',
    package: 'app.organicmaps.web',
    description: 'Offline maps and navigation, no phone needed',
    releaseUrl: 'https://github.com/organicmaps/organicmaps/releases',
    signer: 'b9c7ae79a5a90270df08a132e536b9c666f5bef1f59b304fcecf8687865e4b5b',
    license: 'Apache-2.0',
    appName: 'Organic Maps',
  ),
  CatalogApp(
    id: 'newpipe',
    name: 'NewPipe',
    package: 'org.schabi.newpipe',
    description: 'Watch YouTube while parked or charging',
    releaseUrl: 'https://github.com/TeamNewPipe/NewPipe/releases',
    signer: 'cb84069bd68116bafae5ee4ee5b08a567aa6d898404e7cb12f9e756df5cf5cab',
    license: 'GPL-3.0',
    asset: r'NewPipe_v[0-9.]+\.apk',
  ),
  // Material Files over Amaze: the more starred of the two on GitHub
  // (9,490 against 6,469 when chosen). Behind the passcode, like Android
  // Settings: it reaches every file the head unit lets an app see.
  CatalogApp(
    id: 'file-manager',
    name: 'File Manager',
    shortName: 'Files',
    package: 'me.zhanghai.android.files',
    description: 'Browse files on the head unit',
    releaseUrl: 'https://github.com/zhanghai/MaterialFiles/releases',
    signer: '873b9b60c77cf7f3cd5fae66d0fe112c4a86973e118ee8a29c346c4c673c97f0',
    license: 'GPL-3.0',
    asset: r'app-release-universal\.apk',
    appName: 'Material Files',
    passcode: true,
  ),
  // Termux's GitHub builds: every asset is named "…github-debug…" and all
  // are signed with the project's shared test key, so the asset is named
  // here. The universal APK runs on any head unit; one that is 64-bit, as
  // a Gen 1 is (`ro.product.cpu.abilist` = arm64-v8a,armeabi-v7a,armeabi),
  // gets the arm64-v8a APK instead, a third of the size.
  // Behind the passcode: it is a shell on the head unit.
  CatalogApp(
    id: 'terminal',
    name: 'Terminal',
    package: 'com.termux',
    description: 'A shell on the head unit',
    releaseUrl: 'https://github.com/termux/termux-app/releases',
    signer: 'b6da01480eefd5fbf2cd3771b8d1021ec791304bdd6c4bf41d3faabad48ee5e1',
    license: 'GPL-3.0',
    asset: r'termux-app_v[0-9.]+\+github-debug_universal\.apk',
    abiAssets: {'arm64-v8a': r'termux-app_v[0-9.]+\+github-debug_arm64-v8a\.apk'},
    appName: 'Termux',
    passcode: true,
  ),
  // OTA Shield, by its own developer (Codeberg, not GitHub): keeps Ola's
  // firmware updates off the scooter with a root daemon on the head unit.
  // OpenDash installs and opens it, reads its status for Settings → Updates
  // (`ota_shield_state.dart`) and can ask it to activate; turning the block
  // off is OTA Shield's alone. Signer read with `apksigner` from v1.0.0
  // (CN=Jacob). Behind the passcode: it can take the block down.
  CatalogApp(
    id: CatalogApp.otaShieldId,
    name: 'OTA Shield',
    shortName: 'Shield',
    package: otaShieldPackage,
    description: 'Keeps Ola firmware updates off the scooter',
    releaseUrl: 'https://codeberg.org/pitzel/ota-shield/releases',
    signer: '4244c54f0d5e847d72d9dbbf0db00252040e1cb60806cc7a1f5cccf74fe05adb',
    license: 'GPL-3.0',
    passcode: true,
  ),
  CatalogApp(
    id: CatalogApp.androidSettingsId,
    name: 'Android Settings',
    shortName: 'Settings',
    package: 'com.android.settings',
    description: 'Wi-Fi, apps, permissions and other system settings',
    releaseUrl: '',
    license: '',
    systemApp: true,
    passcode: true,
  ),
  CatalogApp(
    id: CatalogApp.stockDashboardId,
    name: 'Stock Dashboard',
    shortName: 'Stock',
    package: stockDashboardPackage,
    description: 'Return to the original Ola dashboard',
    releaseUrl: '',
    license: '',
    systemApp: true,
  ),
];
