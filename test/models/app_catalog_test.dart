import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/app_catalog.dart';

void main() {
  group('App catalog', () {
    test('catalog has entries', () {
      expect(appCatalog, isNotEmpty);
    });

    test('no duplicate ids', () {
      final ids = appCatalog.map((a) => a.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('no duplicate packages among non-coming-soon entries', () {
      final packages = appCatalog.where((a) => !a.comingSoon).map((a) => a.package).toList();
      expect(packages.toSet().length, packages.length);
    });

    test('non-coming-soon entries have a package', () {
      for (final app in appCatalog.where((a) => !a.comingSoon)) {
        expect(app.package, isNotEmpty, reason: '${app.id} package');
        if (app.systemApp) continue;
        expect(app.releaseUrl, isNotEmpty, reason: '${app.id} releaseUrl');
        expect(app.license, isNotEmpty, reason: '${app.id} license');
      }
    });

    test('every downloadable entry is pinned to its developer\'s signing certificate', () {
      final downloadable = appCatalog.where((a) => a.downloadable).toList();
      expect(downloadable.map((a) => a.id), ['android-auto', 'carplay', 'browser', 'maps', 'newpipe', 'file-manager', 'terminal', 'ota-shield']);
      for (final app in downloadable) {
        expect(app.pinned, isTrue, reason: app.id);
        expect(app.signer, matches(RegExp(r'^[0-9a-f]{64}$')), reason: '${app.id}: lower-case hex, as Android reports it');
        // The two release hosts Kotlin knows the API of (`releasesApi`).
        expect(app.releaseUrl, matches(RegExp(r'^https://(github\.com|codeberg\.org)/[^/]+/[^/]+/releases$')), reason: app.id);
      }
      // One key per developer.
      expect(downloadable.map((a) => a.signer).toSet(), hasLength(downloadable.length));
      // The empty-input digest was the mock's placeholder; it must never be a pin.
      expect(downloadable.map((a) => a.signer), isNot(contains('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')));
    });

    test('only phone projection stays up on the move; the file manager and the shell are behind the passcode', () {
      expect(appCatalog.where((a) => a.projection).map((a) => a.id), ['android-auto', 'carplay']);
      expect(appCatalog.firstWhere((a) => a.id == 'file-manager').passcode, isTrue);
      expect(appCatalog.firstWhere((a) => a.id == 'terminal').passcode, isTrue);
      // OTA Shield can take the firmware block down.
      expect(appCatalog.firstWhere((a) => a.id == CatalogApp.otaShieldId).passcode, isTrue);
    });

    test('OTA Shield is offered to nobody new, but stays for a rider who has it', () {
      final shield = appCatalog.firstWhere((a) => a.id == CatalogApp.otaShieldId);
      expect(shield.shownWith(null), isFalse);
      expect(shield.shownWith(AppStatus.notInstalled), isFalse);
      for (final s in AppStatus.values.where((s) => s != AppStatus.notInstalled)) {
        expect(shield.shownWith(s), isTrue, reason: s.name);
      }
      expect(appCatalog.where((a) => a.hiddenUnlessInstalled).map((a) => a.id), [CatalogApp.otaShieldId]);
    });

    test('the rider is told where an app comes from', () {
      expect(appCatalog.firstWhere((a) => a.id == CatalogApp.otaShieldId).source, 'Codeberg');
      expect(appCatalog.firstWhere((a) => a.id == 'terminal').source, 'GitHub');
    });

    test('an entry that names its asset names an APK, as a pattern that survives a new version', () {
      for (final app in appCatalog) {
        for (final pattern in [app.asset, ...app.abiAssets.values].where((p) => p.isNotEmpty)) {
          expect(pattern, endsWith(r'\.apk'), reason: app.id);
          expect(() => RegExp(pattern), returnsNormally, reason: app.id);
        }
      }
      bool takes(String pattern, String name) => RegExp('^$pattern\$').hasMatch(name);
      final newpipe = appCatalog.firstWhere((a) => a.id == 'newpipe');
      expect(takes(newpipe.asset, 'NewPipe_v0.29.3.apk'), isTrue);
      expect(takes(newpipe.asset, 'NewPipe_v0.30.0.apk'), isTrue);
      expect(takes(newpipe.asset, 'NewPipe_v0.29.3_apksigner31.apk'), isFalse);
    });

    test('a head unit gets the build for its processor, and the one that runs anywhere otherwise', () {
      bool takes(String pattern, String name) => RegExp('^$pattern\$').hasMatch(name);
      final termux = appCatalog.firstWhere((a) => a.id == 'terminal');
      const universal = 'termux-app_v0.118.3+github-debug_universal.apk';
      const arm64 = 'termux-app_v0.118.3+github-debug_arm64-v8a.apk';
      expect(takes(termux.assetFor(const []), universal), isTrue);
      expect(takes(termux.assetFor(const ['armeabi-v7a', 'armeabi']), universal), isTrue);
      expect(takes(termux.assetFor(const ['arm64-v8a', 'armeabi-v7a', 'armeabi']), arm64), isTrue);
      expect(takes(termux.assetFor(const ['arm64-v8a']), universal), isFalse);
    });

    test('pinned needs a whole certificate digest', () {
      CatalogApp app(String signer) =>
          CatalogApp(id: 'x', name: 'X', package: 'x', description: '', releaseUrl: '', license: '', signer: signer);
      expect(app('a' * 64).pinned, isTrue);
      expect(app('').pinned, isFalse);
      expect(app('abc123').pinned, isFalse);
    });

    test('no version and no file is written into the catalog', () {
      // What is trusted is the signer; which release is newest is GitHub's
      // to say. A version here would need a new OpenDash for every release.
      for (final app in appCatalog) {
        expect(app.releaseUrl, isNot(contains('/download/')), reason: app.id);
        expect(app.releaseUrl, isNot(contains('/tag/')), reason: app.id);
      }
    });

    test('system apps are part of the image and have nothing to download', () {
      final stock = appCatalog.firstWhere((a) => a.id == 'stock-dashboard');
      expect(stock.systemApp, isTrue);
      expect(stock.releaseUrl, isEmpty);
      expect(appCatalog.where((a) => a.systemApp && a.comingSoon), isEmpty);
    });

    test('no placeholder tiles: everything in Apps can be installed or opened', () {
      expect(appCatalog.where((a) => a.comingSoon), isEmpty);
    });

    test('catalog has expected apps', () {
      final ids = appCatalog.map((a) => a.id).toSet();
      expect(ids, containsAll(['android-auto', 'carplay', 'browser', 'maps', 'newpipe', 'file-manager', 'terminal', 'stock-dashboard']));
    });
  });
}
