import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/app_catalog.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/platform_service.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/passcode_gate.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/toast_state.dart';

void main() {
  late ProviderContainer c;
  late MockPlatformService mockPlatform;

  void setUp_() {
    mockPlatform = MockPlatformService();
    c = ProviderContainer(
      overrides: [platformServiceProvider.overrideWithValue(mockPlatform)],
    );
    for (final p in [
      sessionProvider, toastProvider, appManagerProvider, mockAppProvider,
      appLauncherOpenProvider, settingsScreenOpenProvider,
    ]) {
      c.listen(p, (_, _) {});
    }
    c.read(vehicleProvider.notifier).setConnected(true);
    c.read(vehicleProvider.notifier).setLocked(false);
  }

  tearDown(() => c.dispose());

  final autoApp = appCatalog.firstWhere((a) => a.id == 'android-auto');
  // The catalog has no placeholder tile any more; the handling stays.
  final comingSoonApp = const CatalogApp(
    id: 'not-yet',
    name: 'Not Yet',
    package: '',
    description: '',
    releaseUrl: '',
    license: '',
    comingSoon: true,
  );

  group('AppManagerNotifier', () {
    test('initial state has every downloadable app as notInstalled and system apps installed', () {
      setUp_();
      final statuses = c.read(appManagerProvider);
      for (final app in appCatalog) {
        expect(statuses[app.id], app.systemApp ? AppStatus.installed : AppStatus.notInstalled, reason: app.id);
      }
    });

    test('refresh keeps system apps installed without asking the platform', () {
      fakeAsync((async) {
        setUp_();
        c.read(appManagerProvider.notifier).refresh();
        async.elapse(const Duration(milliseconds: 100));
        expect(c.read(appManagerProvider)['stock-dashboard'], AppStatus.installed);
      });
    });

    test('refresh detects installed apps', () {
      fakeAsync((async) {
        setUp_();
        mockPlatform.setInstalled(autoApp.package);
        c.read(appManagerProvider.notifier).refresh();
        async.elapse(const Duration(milliseconds: 100));
        expect(c.read(appManagerProvider)[autoApp.id], AppStatus.installed);
      });
    });

    test('install flow: downloading -> installing; installed only once the package manager says so', () {
      fakeAsync((async) {
        setUp_();
        final toasts = <String>[];
        c.listen(toastProvider, (_, t) {
          if (t != null) toasts.add(t.message);
        });
        final states = <AppStatus>[];
        c.listen(appManagerProvider, (_, s) {
          final status = s[autoApp.id];
          if (status != null && (states.isEmpty || states.last != status)) {
            states.add(status);
          }
        });
        c.read(appManagerProvider.notifier).install(autoApp);
        async.elapse(const Duration(seconds: 5));
        expect(c.read(appManagerProvider)[autoApp.id], AppStatus.installing, reason: 'the installer is up; not an install yet');
        c.read(appManagerProvider.notifier).onResume();
        async.flushMicrotasks();
        expect(states, containsAllInOrder([AppStatus.queued, AppStatus.downloading, AppStatus.installing, AppStatus.ready]),
            reason: 'back from the installer without installing');
      });
    });

    test('reopening Apps mid-download keeps the download status; a second tap is ignored', () {
      fakeAsync((async) {
        setUp_();
        final n = c.read(appManagerProvider.notifier);
        n.install(autoApp);
        async.flushMicrotasks();
        expect(c.read(appManagerProvider)[autoApp.id], AppStatus.downloading);
        n.refresh();
        async.flushMicrotasks();
        expect(c.read(appManagerProvider)[autoApp.id], AppStatus.downloading);
        n.install(autoApp);
        async.elapse(const Duration(seconds: 5));
        expect(mockPlatform.downloads, 1, reason: 'one download, not two into the same file');
      });
    });

    test('a download that finishes while riding is kept, and the installer waits for a tap', () {
      fakeAsync((async) {
        setUp_();
        final v = c.read(vehicleProvider.notifier);
        final n = c.read(appManagerProvider.notifier);
        n.install(autoApp);
        v.setSpeed(30);
        async.elapse(const Duration(seconds: 2));
        expect(c.read(appManagerProvider)[autoApp.id], AppStatus.ready);
        expect(c.read(toastProvider)!.message, 'Android Auto is downloaded. Tap Install when parked');
        expect(mockPlatform.installs, 0);
        v.setSpeed(0);
        async.elapse(const Duration(seconds: 30));
        expect(mockPlatform.installs, 0, reason: 'stopping (a traffic light) does not put the installer on the screen');
        n.install(autoApp);
        async.elapse(const Duration(seconds: 3));
        expect(mockPlatform.installs, 1);
        expect(mockPlatform.downloads, 1, reason: 'the same file');
      });
    });

    test('several installs download one at a time, in order; each installer waits for the one before', () {
      fakeAsync((async) {
        setUp_();
        final n = c.read(appManagerProvider.notifier);
        final three = [for (final id in ['browser', 'maps', 'newpipe']) appCatalog.firstWhere((a) => a.id == id)];
        for (final app in three) {
          n.install(app);
        }
        async.flushMicrotasks();
        expect([for (final a in three) c.read(appManagerProvider)[a.id]],
            [AppStatus.downloading, AppStatus.queued, AppStatus.queued]);
        async.elapse(const Duration(seconds: 1));
        expect(mockPlatform.installs, 1, reason: 'the first one finished and the scooter is parked');
        expect(c.read(appManagerProvider)[three[1].id], AppStatus.downloading);
        async.elapse(const Duration(seconds: 10));
        expect(mockPlatform.downloads, 3);
        expect(mockPlatform.installs, 1, reason: 'one installer at a time');
        expect([for (final a in three.skip(1)) c.read(appManagerProvider)[a.id]], [AppStatus.ready, AppStatus.ready]);
        expect(c.read(toastProvider)?.message ?? '', isNot(contains('when parked')),
            reason: 'parked already: they are next in line behind the installer that is up');

        mockPlatform.setInstalled(three[0].package);
        n.onResume();
        async.elapse(const Duration(seconds: 2));
        expect(mockPlatform.installs, 2, reason: 'back from the first installer: the next one is offered');
        mockPlatform.setInstalled(three[1].package);
        n.onResume();
        async.elapse(const Duration(seconds: 2));
        expect(mockPlatform.installs, 3);
      });
    });

    test('Cancel takes a queued app out of the line and stops a download; neither says it failed', () {
      fakeAsync((async) {
        setUp_();
        AnalyticsLogger.instance.resetForTest();
        final n = c.read(appManagerProvider.notifier);
        final browser = appCatalog.firstWhere((a) => a.id == 'browser');
        final maps = appCatalog.firstWhere((a) => a.id == 'maps');
        n.install(autoApp);
        n.install(browser);
        n.install(maps);
        async.flushMicrotasks();
        n.cancel(browser);
        expect(c.read(appManagerProvider)[browser.id], AppStatus.notInstalled);
        n.cancel(autoApp);
        expect(c.read(appManagerProvider)[autoApp.id], AppStatus.notInstalled);
        async.elapse(const Duration(seconds: 5));
        expect(mockPlatform.installs, 1, reason: 'only Maps was left');
        expect(c.read(appManagerProvider)[maps.id], AppStatus.installing);
        expect([c.read(appManagerProvider)[autoApp.id], c.read(appManagerProvider)[browser.id]],
            [AppStatus.notInstalled, AppStatus.notInstalled]);
        expect(AnalyticsLogger.instance.recent('apps', 'install_refused'), isEmpty);
        expect(AnalyticsLogger.instance.recent('apps', 'download_cancelled'), hasLength(2));

        // Cancelled, then wanted after all.
        n.install(browser);
        async.elapse(const Duration(seconds: 5));
        expect(c.read(appManagerProvider)[browser.id], AppStatus.ready, reason: 'downloaded; the Maps installer is still up');
      });
    });

    test('any app left from the island or by setting off keeps a way back on the dashboard; a lock ends it', () {
      fakeAsync((async) {
        setUp_();
        final v = c.read(vehicleProvider.notifier);
        final n = c.read(appManagerProvider.notifier);
        final browser = appCatalog.firstWhere((a) => a.id == 'browser');
        mockPlatform.setInstalled(browser.package);
        c.listen(projectionResumeProvider, (_, _) {});
        n.launch(browser);
        async.elapse(const Duration(seconds: 1));
        expect(c.read(projectionResumeProvider), isNull);
        n.returnFromIsland();
        expect(c.read(projectionResumeProvider), browser);
        v.setVehicleState(VehicleState.ready);
        v.setVehicleState(VehicleState.parked);
        expect(c.read(projectionResumeProvider), browser, reason: 'it is an app for when parked');
        n.resumeProjection();
        async.elapse(const Duration(seconds: 1));
        expect(c.read(projectionResumeProvider), isNull, reason: 'back in the app');
        v.setSpeed(20);
        async.elapse(const Duration(seconds: 3));
        expect(c.read(projectionResumeProvider), browser, reason: 'setting off took the rider out of it');
        v.setSpeed(0);
        v.setLocked(true);
        expect(c.read(projectionResumeProvider), isNull);
      });
    });

    test('Android settings pages and the stock dashboard leave no way-back button', () {
      fakeAsync((async) {
        setUp_();
        final n = c.read(appManagerProvider.notifier);
        c.listen(projectionResumeProvider, (_, _) {});
        n.install(autoApp);
        async.elapse(const Duration(seconds: 3));
        expect(c.read(outsideAppProvider)?.id, 'system-installer');
        n.returnFromIsland();
        expect(c.read(projectionResumeProvider), isNull);
      });
    });

    test('a failed download does not hold up the ones queued behind it', () {
      fakeAsync((async) {
        setUp_();
        final n = c.read(appManagerProvider.notifier);
        final browser = appCatalog.firstWhere((a) => a.id == 'browser');
        mockPlatform.releasesUnreachable = true;
        n.install(autoApp);
        async.flushMicrotasks();
        mockPlatform.releasesUnreachable = false;
        n.install(browser);
        async.elapse(const Duration(seconds: 5));
        expect(c.read(appManagerProvider)[autoApp.id], AppStatus.notInstalled);
        expect(c.read(appManagerProvider)[browser.id], AppStatus.installing);
      });
    });

    test('setting off with the installer up brings the dashboard back; the file is kept', () {
      fakeAsync((async) {
        setUp_();
        final v = c.read(vehicleProvider.notifier);
        final n = c.read(appManagerProvider.notifier);
        n.install(autoApp);
        async.elapse(const Duration(seconds: 3));
        expect(c.read(outsideAppProvider)?.id, 'system-installer');
        v.setSpeed(20);
        async.elapse(const Duration(seconds: 3));
        expect(mockPlatform.broughtToFront, 1);
        n.onResume();
        async.elapse(const Duration(seconds: 2));
        expect(c.read(appManagerProvider)[autoApp.id], AppStatus.ready);
        expect(mockPlatform.installs, 1, reason: 'not offered again by itself while moving');
        // Android finished the install behind the dashboard.
        mockPlatform.setInstalled(autoApp.package);
        async.elapse(const Duration(seconds: 25));
        expect(c.read(appManagerProvider)[autoApp.id], AppStatus.installed);
      });
    });

    test('back from the installer with the app installed: the button flips without reopening Apps', () {
      fakeAsync((async) {
        setUp_();
        final n = c.read(appManagerProvider.notifier);
        n.install(autoApp);
        async.elapse(const Duration(seconds: 3));
        mockPlatform.setInstalled(autoApp.package);
        n.onResume();
        async.flushMicrotasks();
        expect(c.read(appManagerProvider)[autoApp.id], AppStatus.installed);
      });
    });

    test('"Install unknown apps" detour: opens the setting, then installs the same file on return', () {
      fakeAsync((async) {
        setUp_();
        mockPlatform.installAllowed = false;
        final n = c.read(appManagerProvider.notifier);
        n.install(autoApp);
        async.elapse(const Duration(seconds: 3));
        expect(mockPlatform.permissionScreens, 1);
        expect(c.read(outsideAppProvider)?.id, 'system-install-permission', reason: 'the way back from the permission screen');
        expect(mockPlatform.installs, 0);
        expect(c.read(appManagerProvider)[autoApp.id], AppStatus.ready);
        mockPlatform.installAllowed = true;
        n.onResume();
        async.elapse(const Duration(seconds: 2));
        expect(mockPlatform.installs, 1);
        expect(mockPlatform.downloads, 1, reason: 'no second download');
      });
    });

    test('a second Install tap after a cancelled installer reuses the download', () {
      fakeAsync((async) {
        setUp_();
        final n = c.read(appManagerProvider.notifier);
        n.install(autoApp);
        async.elapse(const Duration(seconds: 3));
        n.onResume();
        async.flushMicrotasks();
        n.install(autoApp);
        async.elapse(const Duration(seconds: 3));
        expect(mockPlatform.downloads, 1);
        expect(mockPlatform.installs, 2);
      });
    });

    group('the way back (no Back / Home on the head unit)', () {
      final settingsApp = appCatalog.firstWhere((a) => a.id == 'android-settings');

      test('opening an app hands it to the island, not the pill; coming back clears it', () {
        fakeAsync((async) {
          setUp_();
          final n = c.read(appManagerProvider.notifier);
          n.launch(autoApp);
          async.flushMicrotasks();
          expect(c.read(mockAppProvider), autoApp);
          expect(c.read(outsideAppProvider), autoApp);
          n.onResume();
          async.flushMicrotasks();
          expect(c.read(outsideAppProvider), isNull);
        });
      });

      test('no overlay permission: asks for it first, opens the app on return', () {
        fakeAsync((async) {
          setUp_();
          mockPlatform.overlayAllowed = false;
          final n = c.read(appManagerProvider.notifier);
          n.launch(autoApp);
          async.flushMicrotasks();
          expect(mockPlatform.overlayScreens, 1);
          expect(c.read(mockAppProvider), isNull, reason: 'not opened without a way back');
          mockPlatform.overlayAllowed = true;
          n.onResume();
          async.flushMicrotasks();
          expect(c.read(mockAppProvider), autoApp);
          expect(c.read(outsideAppProvider), autoApp);
        });
      });

      test('still refused on return: the app stays closed', () {
        fakeAsync((async) {
          setUp_();
          mockPlatform.overlayAllowed = false;
          final n = c.read(appManagerProvider.notifier);
          n.launch(autoApp);
          async.flushMicrotasks();
          n.onResume();
          async.flushMicrotasks();
          expect(c.read(mockAppProvider), isNull);
        });
      });

      test('Android Settings needs the passcode', () {
        fakeAsync((async) {
          setUp_();
          c.listen(passcodeGateProvider, (_, _) {});
          c.read(appManagerProvider.notifier).launch(settingsApp);
          async.flushMicrotasks();
          expect(c.read(passcodeGateProvider).open, isTrue);
          expect(c.read(mockAppProvider), isNull);
          for (final d in [1, 2, 3, 4, 5, 6]) {
            c.read(passcodeGateProvider.notifier).enterDigit(d);
          }
          async.elapse(const Duration(seconds: 1));
          expect(c.read(mockAppProvider), settingsApp);
        });
      });

      test('a red alert brings the dashboard back from Android Auto, once per alert, and offers the way back', () {
        fakeAsync((async) {
          setUp_();
          final n = c.read(appManagerProvider.notifier);
          final v = c.read(vehicleProvider.notifier);
          c.listen(projectionResumeProvider, (_, _) {});
          v.setVehicleState(VehicleState.riding);
          v.setSpeed(30);
          n.launch(autoApp);
          async.flushMicrotasks();
          v.setBattery(8);
          async.flushMicrotasks();
          expect(mockPlatform.broughtToFront, 0, reason: 'low battery is a warning, not an emergency');
          v.setSideStand(true);
          async.flushMicrotasks();
          expect(mockPlatform.broughtToFront, 1);
          expect(c.read(projectionResumeProvider), autoApp);
          v.setSpeed(29);
          async.flushMicrotasks();
          expect(mockPlatform.broughtToFront, 1, reason: 'the same alert does not pull again');

          n.resumeProjection();
          async.flushMicrotasks();
          expect(c.read(mockAppProvider), autoApp, reason: 'back to navigation while riding');
          expect(c.read(projectionResumeProvider), isNull);
          v.setFault(true);
          async.flushMicrotasks();
          expect(mockPlatform.broughtToFront, 2, reason: 'a new red alert does');
        });
      });

      test('the way back clears when the ride is over', () {
        fakeAsync((async) {
          setUp_();
          c.listen(projectionResumeProvider, (_, _) {});
          final v = c.read(vehicleProvider.notifier);
          v.setVehicleState(VehicleState.riding);
          c.read(projectionResumeProvider.notifier).offer(autoApp);
          v.setSpeed(0);
          v.setVehicleState(VehicleState.parked);
          async.flushMicrotasks();
          expect(c.read(projectionResumeProvider), isNull);
        });
      });

      test('moving off brings the dashboard back, except from phone projection', () {
        fakeAsync((async) {
          setUp_();
          c.listen(passcodeGateProvider, (_, _) {});
          final n = c.read(appManagerProvider.notifier);
          final v = c.read(vehicleProvider.notifier);
          n.launch(autoApp);
          async.flushMicrotasks();
          v.setSpeed(20);
          async.flushMicrotasks();
          expect(mockPlatform.broughtToFront, 0, reason: 'Android Auto is for riding');
          v.setSpeed(0);
          n.onResume();
          async.flushMicrotasks();
          n.launch(settingsApp);
          for (final d in [1, 2, 3, 4, 5, 6]) {
            c.read(passcodeGateProvider.notifier).enterDigit(d);
          }
          async.elapse(const Duration(seconds: 1));
          v.setSpeed(20);
          async.flushMicrotasks();
          expect(mockPlatform.broughtToFront, 1);
        });
      });
    });

    test('install of coming-soon app is a no-op', () {
      fakeAsync((async) {
        setUp_();
        c.read(appManagerProvider.notifier).install(comingSoonApp);
        async.elapse(const Duration(seconds: 2));
        expect(c.read(appManagerProvider)[comingSoonApp.id], isNull, reason: 'never downloading or installing');
        expect(mockPlatform.downloads, 0);
      });
    });

    group('installs are held to the developer\'s signing key', () {
      Map<Object?, Object?> verify() =>
          AnalyticsLogger.instance.recent('apps', 'install_verify').single['data']! as Map<Object?, Object?>;
      Map<Object?, Object?> refused() =>
          AnalyticsLogger.instance.recent('apps', 'install_refused').single['data']! as Map<Object?, Object?>;

      test('the newest release is fetched, checked, and handed to the installer', () {
        fakeAsync((async) {
          setUp_();
          AnalyticsLogger.instance.resetForTest();
          mockPlatform.latest[autoApp.releaseUrl] = (version: '4.1.0', asset: 'headunit-4.1.0.apk');
          c.read(appManagerProvider.notifier).install(autoApp);
          async.elapse(const Duration(seconds: 2));
          expect(mockPlatform.downloadedVersions, ['4.1.0'], reason: 'no version is written into the catalog');
          expect(mockPlatform.installs, 1);
          expect(verify(), {'id': 'android-auto', 'version': '4.1.0', 'package': true, 'signer': true});
        });
      });

      test('a download signed by someone else is not installed, and is not kept', () {
        fakeAsync((async) {
          setUp_();
          AnalyticsLogger.instance.resetForTest();
          mockPlatform.signerOverride = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
          c.read(appManagerProvider.notifier).install(autoApp);
          async.elapse(const Duration(seconds: 2));
          expect(mockPlatform.installs, 0);
          expect(c.read(appManagerProvider)[autoApp.id], AppStatus.notInstalled);
          expect(c.read(toastProvider)!.type, ToastType.error);
          expect(c.read(toastProvider)!.message, contains("isn't signed by its developer's key"));
          expect(verify()['signer'], isFalse);
          expect(refused()['reason'], 'signer');

          // The bad file is not kept: the next tap downloads again.
          mockPlatform.signerOverride = null;
          c.read(appManagerProvider.notifier).install(autoApp);
          async.elapse(const Duration(seconds: 2));
          expect(mockPlatform.downloads, 2);
          expect(mockPlatform.installs, 1);
        });
      });

      test('a download that is another package is not installed', () {
        fakeAsync((async) {
          setUp_();
          AnalyticsLogger.instance.resetForTest();
          mockPlatform.apkInfos['/mock/cache/apks/android-auto.apk'] =
              ApkInfo(package: 'com.example.other', versionCode: 1, versionName: '1', signer: autoApp.signer);
          c.read(appManagerProvider.notifier).install(autoApp);
          async.elapse(const Duration(seconds: 2));
          expect(mockPlatform.installs, 0);
          expect(refused()['reason'], 'package');
        });
      });

      test('a file that is not an APK is not installed', () {
        fakeAsync((async) {
          setUp_();
          AnalyticsLogger.instance.resetForTest();
          mockPlatform.apkUnreadable = true;
          c.read(appManagerProvider.notifier).install(autoApp);
          async.elapse(const Duration(seconds: 2));
          expect(mockPlatform.installs, 0);
          expect(c.read(appManagerProvider)[autoApp.id], AppStatus.notInstalled);
          expect(refused()['reason'], 'unreadable');
        });
      });

      test('with GitHub out of reach nothing is downloaded', () {
        fakeAsync((async) {
          setUp_();
          AnalyticsLogger.instance.resetForTest();
          mockPlatform.releasesUnreachable = true;
          c.read(appManagerProvider.notifier).install(autoApp);
          async.elapse(const Duration(seconds: 2));
          expect(mockPlatform.downloads, 0);
          expect(c.read(appManagerProvider)[autoApp.id], AppStatus.notInstalled);
          expect(refused()['reason'], 'release');
          final net = AnalyticsLogger.instance.recent('net', 'check').single['data'] as Map;
          expect(net['auto'], isTrue, reason: 'the log did not say which DNS servers had been asked');
          expect((net['networks'] as List).single['dns'], isNotEmpty);
          c.read(appManagerProvider.notifier).install(autoApp);
          async.elapse(const Duration(seconds: 2));
          expect(AnalyticsLogger.instance.recent('net', 'check'), hasLength(1), reason: 'at most once a minute');
        });
      });

      test('a GitHub that never answers is given up on, and nothing is downloaded', () {
        fakeAsync((async) {
          final platform = _SilentGitHubPlatform();
          final c2 = ProviderContainer(overrides: [platformServiceProvider.overrideWithValue(platform)]);
          addTearDown(c2.dispose);
          for (final p in [sessionProvider, toastProvider, appManagerProvider]) {
            c2.listen(p, (_, _) {});
          }
          c2.read(vehicleProvider.notifier).setLocked(false);
          c2.read(appManagerProvider.notifier).install(autoApp);
          async.elapse(AppManagerNotifier.releaseAnswerWithin - const Duration(seconds: 1));
          expect(c2.read(appManagerProvider)[autoApp.id], AppStatus.downloading, reason: 'still asking');
          async.elapse(const Duration(seconds: 2));
          expect(c2.read(appManagerProvider)[autoApp.id], AppStatus.notInstalled);
          expect(c2.read(toastProvider)!.message, contains("Couldn't find"));
          expect(platform.downloads, 0);
          setUp_();
        });
      });

      test('an entry with no signing key is refused before anything is downloaded', () {
        fakeAsync((async) {
          setUp_();
          AnalyticsLogger.instance.resetForTest();
          const unpinned = CatalogApp(
            id: 'unpinned',
            name: 'Unpinned',
            package: 'com.example.unpinned',
            description: '',
            releaseUrl: 'https://github.com/example/unpinned/releases',
            license: 'MIT',
          );
          expect(unpinned.pinned, isFalse);
          c.read(appManagerProvider.notifier).install(unpinned);
          async.elapse(const Duration(seconds: 2));
          expect(mockPlatform.downloads, 0);
          expect(mockPlatform.installs, 0);
          expect(c.read(toastProvider)!.type, ToastType.warning);
          expect(c.read(toastProvider)!.message, contains('unverified'));
          expect(refused()['reason'], 'unpinned');
        });
      });
    });

    test('download failure resets to notInstalled and toasts error', () {
      fakeAsync((async) {
        setUp_();
        final failPlatform = _FailDownloadPlatform();
        final c2 = ProviderContainer(
          overrides: [platformServiceProvider.overrideWithValue(failPlatform)],
        );
        for (final p in [sessionProvider, toastProvider, appManagerProvider, mockAppProvider, appLauncherOpenProvider, settingsScreenOpenProvider]) {
          c2.listen(p, (_, _) {});
        }
        c2.read(vehicleProvider.notifier).setConnected(true);
        c2.read(vehicleProvider.notifier).setLocked(false);

        c2.read(appManagerProvider.notifier).install(autoApp);
        async.elapse(const Duration(seconds: 2));
        expect(c2.read(appManagerProvider)[autoApp.id], AppStatus.notInstalled);
        expect(c2.read(toastProvider)!.message, 'Android Auto: download failed');
        expect(c2.read(toastProvider)!.type, ToastType.error);
        c2.dispose();
      });
    });

    test('install failure resets to notInstalled and toasts error', () {
      fakeAsync((async) {
        setUp_();
        final failPlatform = _FailInstallPlatform();
        final c2 = ProviderContainer(
          overrides: [platformServiceProvider.overrideWithValue(failPlatform)],
        );
        for (final p in [sessionProvider, toastProvider, appManagerProvider, mockAppProvider, appLauncherOpenProvider, settingsScreenOpenProvider]) {
          c2.listen(p, (_, _) {});
        }
        c2.read(vehicleProvider.notifier).setConnected(true);
        c2.read(vehicleProvider.notifier).setLocked(false);

        c2.read(appManagerProvider.notifier).install(autoApp);
        async.elapse(const Duration(seconds: 2));
        expect(c2.read(appManagerProvider)[autoApp.id], AppStatus.notInstalled);
        expect(c2.read(toastProvider)!.message, 'Android Auto: installation failed');
        c2.dispose();
      });
    });

    test('launch coming-soon app shows toast', () {
      fakeAsync((async) {
        setUp_();
        c.read(appManagerProvider.notifier).launch(comingSoonApp);
        async.elapse(const Duration(milliseconds: 100));
        expect(c.read(toastProvider)!.message, 'Coming soon');
      });
    });

    test('mock launch shows placeholder and closes launcher', () {
      fakeAsync((async) {
        setUp_();
        c.read(appLauncherOpenProvider.notifier).open();
        expect(c.read(appLauncherOpenProvider), isTrue);
        c.read(appManagerProvider.notifier).launch(autoApp);
        async.elapse(const Duration(milliseconds: 100));
        expect(c.read(mockAppProvider)?.id, autoApp.id);
        expect(c.read(appLauncherOpenProvider), isFalse);
      });
    });
  });
}

class _FailDownloadPlatform extends MockPlatformService {
  @override
  Future<String?> downloadFile(String url, String filename, {String version = '', String asset = ''}) async => null;
}

class _SilentGitHubPlatform extends MockPlatformService {
  @override
  Future<({String version, String asset})?> latestRelease(String url, {String asset = ''}) =>
      Completer<({String version, String asset})?>().future;
}

class _FailInstallPlatform extends MockPlatformService {
  @override
  Future<bool> installApk(String filePath) async => false;
}
