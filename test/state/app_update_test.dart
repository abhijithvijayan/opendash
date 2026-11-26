import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/app_catalog.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/services/platform_service.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/toast_state.dart';

/// Updating an app that is already installed. The first install is pinned
/// to one exact file; an update is taken from the same project if it is the
/// same package, newer, and signed by the installed copy's signer.
void main() {
  setUp(AnalyticsLogger.instance.resetForTest);

  final browser = appCatalog.firstWhere((a) => a.id == 'browser');
  final signer = browser.signer;
  final installed = ApkInfo(package: 'com.duckduckgo.mobile.android', versionCode: 530300, versionName: '5.303.0', signer: signer);
  const path = '/mock/cache/apks/browser-update.apk';

  void apps(void Function(FakeAsync async, ProviderContainer c, MockPlatformService platform) body, {bool wifi = true}) {
    fakeAsync((async) {
      final platform = MockPlatformService()
        ..setInstalled(browser.package)
        ..installedInfos[browser.package] = installed;
      final c = ProviderContainer(overrides: [platformServiceProvider.overrideWithValue(platform)]);
      for (final p in [sessionProvider, toastProvider, appManagerProvider, mockAppProvider]) {
        c.listen(p, (_, _) {});
      }
      c.read(vehicleProvider.notifier)
        ..setConnected(true)
        ..setLocked(false)
        ..setVehicleState(VehicleState.parked)
        ..setWifi(wifi);
      body(async, c, platform);
      c.dispose();
    });
  }

  List<Map<Object?, Object?>> logged(String evt) =>
      [for (final e in AnalyticsLogger.instance.recent('apps', evt)) e['data']! as Map];
  String? toast(ProviderContainer c) => c.read(toastProvider)?.message;

  /// Opens Apps, which is when GitHub is asked.
  void refresh(FakeAsync async, ProviderContainer c) {
    c.read(appManagerProvider.notifier).refresh();
    async.elapse(const Duration(seconds: 1));
  }

  void offer(MockPlatformService platform, String version) =>
      platform.latest[browser.releaseUrl] = (version: version, asset: 'duckduckgo-$version-play-release.apk');

  group('checking', () {
    test('a newer release marks the app; nothing is downloaded', () {
      apps((async, c, platform) {
        offer(platform, '5.310.0');
        refresh(async, c);
        expect(c.read(appManagerProvider)[browser.id], AppStatus.updateAvailable);
        expect(c.read(appManagerProvider.notifier).newerVersion(browser.id), '5.310.0');
        expect(platform.downloads, 0);
        expect(logged('update_check').single, {'id': 'browser', 'latest': '5.310.0', 'installed': '5.303.0', 'available': true, 'wifi': true, 'signal': 3});
      });
    });

    test('the release that is installed is not an update', () {
      apps((async, c, platform) {
        offer(platform, '5.303.0');
        refresh(async, c);
        expect(c.read(appManagerProvider)[browser.id], AppStatus.installed);
      });
    });

    test('it is asked on mobile data too', () {
      apps(wifi: false, (async, c, platform) {
        offer(platform, '5.310.0');
        refresh(async, c);
        expect(c.read(appManagerProvider)[browser.id], AppStatus.updateAvailable);
        expect(logged('update_check').single['wifi'], isFalse);
      });
    });

    test('the first app GitHub does not answer for ends the round', () {
      apps((async, c, platform) {
        final maps = appCatalog.firstWhere((a) => a.id == 'maps');
        platform
          ..setInstalled(maps.package)
          ..releasesUnreachable = true;
        refresh(async, c);
        async.elapse(const Duration(seconds: 5));
        expect(logged('update_check'), hasLength(1), reason: 'not a timeout for every installed app');
      });
    });

    test('it is asked at most once every half hour', () {
      apps((async, c, platform) {
        refresh(async, c);
        offer(platform, '5.310.0');
        refresh(async, c);
        expect(c.read(appManagerProvider)[browser.id], AppStatus.installed, reason: 'asked a second ago');
      });
    });

    test('a GitHub that does not answer is asked again after five minutes, not at every return and not after half an hour', () {
      apps((async, c, platform) {
        platform.releasesUnreachable = true;
        refresh(async, c);
        expect(c.read(appManagerProvider)[browser.id], AppStatus.installed);
        platform.releasesUnreachable = false;
        offer(platform, '5.310.0');
        refresh(async, c);
        expect(c.read(appManagerProvider)[browser.id], AppStatus.installed,
            reason: 'asking again at once is how the hourly limit was spent');
        AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
        addTearDown(() => AnalyticsLogger.instance.monoOverride = null);
        async.elapse(const Duration(minutes: 5));
        refresh(async, c);
        expect(c.read(appManagerProvider)[browser.id], AppStatus.updateAvailable, reason: 'not held off for half an hour');
      });
    });

    test('tags and version names are compared as versions', () {
      expect(AppManagerNotifier.sameVersion('v0.29.3', '0.29.3'), isTrue);
      expect(AppManagerNotifier.sameVersion('v.4.0.0-beta2', '4.0.0-beta2'), isTrue);
      expect(AppManagerNotifier.sameVersion('2026.11.11-39-android', '2026.11.11-39'), isTrue);
      expect(AppManagerNotifier.sameVersion('5.310.0', '5.303.0'), isFalse);
      expect(AppManagerNotifier.sameVersion('5.310.0', ''), isFalse);
      expect(AppManagerNotifier.sameVersion('4.0.0', '4.0.0-beta2'), isFalse,
          reason: 'the scooter had the beta and was not offered the release');
      expect(AppManagerNotifier.sameVersion('5.310.0', '5.31'), isFalse);
      expect(AppManagerNotifier.sameVersion('2026.11.11-39-android', '2026.11.11-39-Web'), isTrue,
          reason: 'Organic Maps was offered as an update to itself');
      expect(AppManagerNotifier.sameVersion('v4.0.0-rc1', '4.0.0-beta2'), isFalse);
      expect(AppManagerNotifier.sameVersion('1.7.5', '1.7.5'), isTrue);
    });
  });

  group('a build per processor type', () {
    final terminal = appCatalog.firstWhere((a) => a.id == 'terminal');

    test('a 64-bit head unit fetches the 64-bit build', () {
      apps((async, c, platform) {
        platform.abis = 'arm64-v8a,armeabi-v7a,armeabi';
        c.read(appManagerProvider.notifier).install(terminal);
        async.elapse(const Duration(seconds: 3));
        expect(platform.downloadedAssets.single, contains('arm64-v8a'));
      });
    });

    test('any other head unit fetches the build that runs anywhere', () {
      apps((async, c, platform) {
        platform.abis = 'armeabi-v7a,armeabi';
        c.read(appManagerProvider.notifier).install(terminal);
        async.elapse(const Duration(seconds: 3));
        expect(platform.downloadedAssets.single, contains('universal'));
      });
    });

    test('so does one that does not say what it runs', () {
      apps((async, c, platform) {
        c.read(appManagerProvider.notifier).install(terminal);
        async.elapse(const Duration(seconds: 3));
        expect(platform.downloadedAssets.single, contains('universal'));
      });
    });
  });

  group('updating', () {
    void update(FakeAsync async, ProviderContainer c, MockPlatformService platform, ApkInfo? file) {
      offer(platform, '5.310.0');
      refresh(async, c);
      if (file != null) platform.apkInfos[path] = file;
      c.read(appManagerProvider.notifier).update(browser);
      async.elapse(const Duration(seconds: 3));
    }

    test('same package, newer, same signer: handed to the installer', () {
      apps((async, c, platform) {
        update(async, c, platform,
            ApkInfo(package: 'com.duckduckgo.mobile.android', versionCode: 531000, versionName: '5.310.0', signer: signer));
        expect(platform.downloadedVersions, ['5.310.0']);
        expect(platform.installs, 1);
        expect(logged('update_verify').single, {'id': 'browser', 'version': '5.310.0', 'package': true, 'signer': true});
        expect(logged('update_refused'), isEmpty);
      });
    });

    test('back from the installer: updated if the new version is in, still an update if not; GitHub is not asked again', () {
      apps((async, c, platform) {
        final newer = ApkInfo(package: 'com.duckduckgo.mobile.android', versionCode: 531000, versionName: '5.310.0', signer: signer);
        update(async, c, platform, newer);
        final n = c.read(appManagerProvider.notifier);
        final asked = logged('update_check').length;
        // Backed out of the installer.
        n.onResume();
        async.elapse(const Duration(seconds: 2));
        expect(c.read(appManagerProvider)[browser.id], AppStatus.updateAvailable);
        // Second go: installed this time.
        n.update(browser);
        async.elapse(const Duration(seconds: 3));
        platform.installedInfos[browser.package] = newer;
        n.onResume();
        async.elapse(const Duration(seconds: 2));
        expect(c.read(appManagerProvider)[browser.id], AppStatus.installed);
        expect(toast(c), 'Browser updated');
        expect(platform.deleted, ['/mock/cache/apks/browser-update.apk'], reason: 'the file goes once the update is in, not when backed out of');
        expect(logged('update_check'), hasLength(asked),
            reason: 'a check of every app after every installer spent GitHub\'s hourly limit');
      });
    });

    test('a different signer is refused, and says so', () {
      apps((async, c, platform) {
        update(async, c, platform,
            ApkInfo(package: 'com.duckduckgo.mobile.android', versionCode: 531000, versionName: '5.310.0', signer: 'bb22'));
        expect(platform.installs, 0);
        expect(logged('update_refused').single['reason'], 'signer');
        expect(toast(c), contains("isn't signed by its developer's key"));
        expect(c.read(appManagerProvider)[browser.id], AppStatus.updateAvailable);
      });
    });

    test('a signer Android would not name is refused', () {
      apps((async, c, platform) {
        update(async, c, platform,
            ApkInfo(package: 'com.duckduckgo.mobile.android', versionCode: 531000, versionName: '5.310.0', signer: null));
        expect(platform.installs, 0);
        expect(logged('update_refused').single['reason'], 'signer');
      });
    });

    test('another package is refused', () {
      apps((async, c, platform) {
        update(async, c, platform, ApkInfo(package: 'com.example.other', versionCode: 531000, versionName: '5.310.0', signer: signer));
        expect(platform.installs, 0);
        expect(logged('update_refused').single['reason'], 'package');
      });
    });

    test('a file that is not an APK is refused', () {
      apps((async, c, platform) {
        platform.apkUnreadable = true;
        update(async, c, platform, null);
        expect(platform.installs, 0);
        expect(logged('update_refused').single['reason'], 'unreadable');
      });
    });

    test('a release that is not newer after all is put down quietly', () {
      apps((async, c, platform) {
        update(async, c, platform,
            ApkInfo(package: 'com.duckduckgo.mobile.android', versionCode: 530300, versionName: '5.303.0', signer: signer));
        expect(platform.installs, 0);
        expect(toast(c), 'Browser is already up to date');
        expect(c.read(appManagerProvider)[browser.id], AppStatus.installed);
      });
    });

    test('not on the move', () {
      apps((async, c, platform) {
        offer(platform, '5.310.0');
        refresh(async, c);
        c.read(vehicleProvider.notifier)
          ..setVehicleState(VehicleState.riding)
          ..setSpeed(20);
        async.elapse(const Duration(milliseconds: 100));
        c.read(appManagerProvider.notifier).update(browser);
        async.elapse(const Duration(seconds: 3));
        expect(platform.downloads, 0);
      });
    });

    test('nothing is fetched for an app with no update on offer', () {
      apps((async, c, platform) {
        refresh(async, c);
        c.read(appManagerProvider.notifier).update(browser);
        async.elapse(const Duration(seconds: 3));
        expect(platform.downloads, 0);
      });
    });
  });
}
