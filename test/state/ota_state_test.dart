import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/build_info.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:opendash/services/trusted_clock.dart';
import 'package:opendash/state/access_state.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/firmware_state.dart';
import 'package:opendash/state/ota_state.dart';
import 'package:opendash/state/passcode_gate.dart';
import 'package:opendash/state/prompt_surface.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// OpenDash updating itself, against the mock platform's fake release
/// source: installed build 100, a release of build 120 unless a test says
/// otherwise.
void main() {
  final noon = DateTime(2026, 11, 16, 12);

  setUp(() async {
    AnalyticsLogger.instance.resetForTest();
    SharedPreferences.setMockInitialValues({});
    await PrefsService.init();
    TrustedClock.resetForTest();
    BuildInfo.number = 100;
  });
  tearDown(() {
    PrefsService.resetForTest();
    TrustedClock.resetForTest();
    BuildInfo.number = null;
  });

  List<Map<String, Object?>> log(String evt) =>
      [for (final e in AnalyticsLogger.instance.recent('selfupdate', evt)) (e['data'] as Map).cast<String, Object?>()];

  void run(
    void Function(FakeAsync async, ProviderContainer c, MockPlatformService p, OtaNotifier o, VehicleNotifier v) body, {
    void Function(MockPlatformService p)? before,
  }) {
    fakeAsync((async) {
      TrustedClock.wall = () => noon.add(async.elapsed);
      final p = MockPlatformService();
      before?.call(p);
      final c = ProviderContainer(overrides: [platformServiceProvider.overrideWithValue(p)]);
      for (final x in [sessionProvider, toastProvider, appManagerProvider, accessProvider, firmwareProvider, otaProvider]) {
        c.listen(x, (_, _) {});
      }
      final v = c.read(vehicleProvider.notifier)
        ..setConnected(true)
        ..setVehicleState(VehicleState.parked)
        ..setLocked(false)
        ..setWifi(true);
      async.flushMicrotasks();
      body(async, c, p, c.read(otaProvider.notifier), v);
      async.flushMicrotasks();
      c.dispose();
    });
  }

  OtaData s(ProviderContainer c) => c.read(otaProvider);
  String? toast(ProviderContainer c) => c.read(toastProvider)?.message;

  void toReady(FakeAsync async, OtaNotifier o) {
    o.check();
    async.flushMicrotasks();
    o.startDownload();
    async.elapse(const Duration(seconds: 5));
  }

  void passcode(FakeAsync async, ProviderContainer c) {
    expect(c.read(passcodeGateProvider).open, isTrue);
    for (final d in [1, 2, 3, 4, 5, 6]) {
      c.read(passcodeGateProvider.notifier).enterDigit(d);
    }
    async.elapse(const Duration(seconds: 2));
  }

  group('the release check', () {
    test('automatic: not before ten minutes, then once, with no toast', () {
      run((async, c, p, o, v) {
        async.elapse(OtaNotifier.bootDelay - const Duration(seconds: 1));
        expect(p.checks, isEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(p.checks, hasLength(1));
        expect(s(c).status, OtaStatus.available);
        expect(s(c).release!.build, 120);
        expect(toast(c), isNull, reason: 'no popup, no toast');
        expect(log('check').single, {'ok': true, 'status': 200, 'newer': true, 'auto': true});
        expect(log('available').single, {'version': '0.2.0', 'build': 120});
        async.elapse(const Duration(hours: 19));
        expect(p.checks, hasLength(1), reason: 'not within twenty hours');
        expect(log('check').last, containsPair('held', 'recent'));
        expect(log('check').where((e) => e['held'] == 'recent'), hasLength(1), reason: 'said once, not every hour');
        async.elapse(const Duration(hours: 2));
        expect(p.checks, hasLength(2), reason: 'a dashboard that keeps running still looks again');
      });
    });

    // 2026-11-25: the owner's dashboard ran from one update to the next
    // release without a restart and never saw it.
    test('automatic: a failed check is tried again within the hour, not at the next start', () {
      run((async, c, p, o, v) {
        p.checkStatus = 0;
        async.elapse(OtaNotifier.bootDelay + const Duration(seconds: 1));
        expect(p.checks, hasLength(1));
        p.checkStatus = 200;
        async.elapse(OtaNotifier.autoEvery);
        expect(p.checks, hasLength(2));
        expect(s(c).status, OtaStatus.available);
        expect(toast(c), isNull);
      });
    });

    test('automatic: joining Wi-Fi looks again within a minute, still under the twenty-hour rule', () {
      run((async, c, p, o, v) {
        v.setWifi(false);
        p.checkStatus = 0;
        async.elapse(OtaNotifier.bootDelay + const Duration(seconds: 1));
        expect(p.checks, hasLength(1), reason: 'on mobile data, no answer');
        p.checkStatus = 200;
        v.setWifi(true);
        async.elapse(OtaNotifier.wifiSettle - const Duration(seconds: 1));
        expect(p.checks, hasLength(1));
        async.elapse(const Duration(seconds: 2));
        expect(p.checks, hasLength(2));
        expect(s(c).status, OtaStatus.available);
        v.setWifi(false);
        v.setWifi(true);
        async.elapse(const Duration(minutes: 5));
        expect(p.checks, hasLength(2), reason: 'answered a minute ago');
      });
    });

    test('automatic: joining Wi-Fi sends nothing while riding or with "Only when I ask"', () {
      run((async, c, p, o, v) {
        o.setAuto(false);
        v.setWifi(false);
        v.setWifi(true);
        async.elapse(const Duration(minutes: 5));
        expect(p.checks, isEmpty);
        o.setAuto(true);
        v.setVehicleState(VehicleState.riding);
        v.setWifi(false);
        v.setWifi(true);
        async.elapse(const Duration(minutes: 1));
        expect(p.checks, isEmpty);
      });
    });

    test('automatic: "Check now" restarts the twenty hours', () {
      run((async, c, p, o, v) {
        async.elapse(OtaNotifier.bootDelay + const Duration(seconds: 1));
        async.elapse(const Duration(hours: 10));
        o.check();
        async.flushMicrotasks();
        expect(p.checks, hasLength(2));
        async.elapse(const Duration(hours: 19));
        expect(p.checks, hasLength(2));
        async.elapse(const Duration(hours: 2));
        expect(p.checks, hasLength(3));
      });
    });

    test('automatic: not within twenty hours of the last answered check', () {
      run((async, c, p, o, v) {
        async.elapse(OtaNotifier.bootDelay + const Duration(seconds: 1));
        expect(p.checks, hasLength(1));
      });
      // The next start, an hour later by the clock: held. A day later: asked.
      for (final (later, asked) in [(const Duration(hours: 1), 0), (const Duration(hours: 21), 1)]) {
        fakeAsync((async) {
          TrustedClock.wall = () => noon.add(later).add(async.elapsed);
          final p = MockPlatformService();
          final c = ProviderContainer(overrides: [platformServiceProvider.overrideWithValue(p)]);
          c.listen(otaProvider, (_, _) {});
          c.read(vehicleProvider.notifier).setLocked(false);
          async.elapse(OtaNotifier.bootDelay + const Duration(seconds: 1));
          expect(p.checks, hasLength(asked), reason: '$later');
          c.dispose();
        });
      }
    });

    test('an untrusted clock sends nothing, automatic or asked', () {
      run((async, c, p, o, v) {
        final firmware = DateTime(2024, 9, 3);
        TrustedClock.resetForTest();
        TrustedClock.configure(firmwareBuildMs: firmware.millisecondsSinceEpoch, elapsedRealtimeMs: 40000);
        TrustedClock.wall = () => firmware.add(const Duration(seconds: 35));
        async.elapse(OtaNotifier.bootDelay + const Duration(seconds: 1));
        o.check();
        async.flushMicrotasks();
        expect(p.checks, isEmpty);
        expect(log('check').every((e) => e['held'] == 'clock'), isTrue);
        async.elapse(const Duration(seconds: 10));
      });
    });

    // The automatic check once went out six minutes into a ride, at a
    // standstill.
    test('never during a ride, a stop at a light included; it waits for the park', () {
      run((async, c, p, o, v) {
        v.setVehicleState(VehicleState.riding);
        v.setSpeed(30);
        async.elapse(OtaNotifier.bootDelay + const Duration(seconds: 1));
        v.setSpeed(0);
        async.elapse(OtaNotifier.bootDelay * 3);
        expect(p.checks, isEmpty, reason: 'stopped, but not parked');
        expect(log('check').single, containsPair('held', 'riding'), reason: 'said once, not every ten minutes');
        v.setVehicleState(VehicleState.parked);
        async.elapse(OtaNotifier.bootDelay + const Duration(seconds: 30));
        expect(p.checks, hasLength(1));
        async.elapse(const Duration(hours: 3));
        expect(p.checks, hasLength(1));
      });
    });

    test('nothing is Wi-Fi only: the check and the download go out on mobile data too', () {
      run((async, c, p, o, v) {
        v.setWifi(false);
        async.elapse(OtaNotifier.bootDelay + const Duration(seconds: 1));
        expect(p.checks, hasLength(1));
        expect(log('check').single, containsPair('ok', true));
        o.startDownload();
        expect(s(c).status, OtaStatus.downloading);
        async.elapse(const Duration(seconds: 5));
        expect(s(c).status, OtaStatus.ready);
      });
    });

    test('"Only when I ask": no automatic check; "Check now" still asks', () {
      run((async, c, p, o, v) {
        o.setAuto(false);
        async.elapse(const Duration(hours: 1));
        expect(p.checks, isEmpty);
        o.check();
        async.flushMicrotasks();
        expect(p.checks, hasLength(1));
        expect(toast(c), 'OpenDash 0.2.0 is available');
        async.elapse(const Duration(seconds: 10));
      });
    });

    for (final status in [0, 403, 429, 500, 404]) {
      test('a failure ($status) is silent, logged, and tried again once an hour', () {
        run(before: (p) => p.checkStatus = status, (async, c, p, o, v) {
          async.elapse(OtaNotifier.bootDelay + const Duration(seconds: 1));
          expect(s(c).status, OtaStatus.upToDate);
          expect(toast(c), isNull);
          expect(log('check').single, {'ok': false, 'status': status, 'newer': false, 'auto': true});
          expect(s(c).checkedAtMs, isNull, reason: 'not an answered check');
          async.elapse(const Duration(hours: 5));
          expect(p.checks, hasLength(6), reason: 'once an hour, not more');
          expect(toast(c), isNull);
        });
      });
    }

    test('bad release facts: nothing is offered', () {
      run(before: (p) => p.release = {...MockPlatformService.fakeRelease(), 'release': '{not json'}, (async, c, p, o, v) {
        o.check();
        async.flushMicrotasks();
        expect(s(c).status, OtaStatus.upToDate);
        expect(log('check').single, containsPair('newer', false));
        async.elapse(const Duration(seconds: 10));
      });
    });

    test('newer means a higher build that may install over this one', () {
      for (final (build, minBuild, newer) in [(120, 0, true), (100, 0, false), (90, 0, false), (120, 100, true), (120, 101, false)]) {
        run(before: (p) => p.release = MockPlatformService.fakeRelease(build: build, minBuild: minBuild), (async, c, p, o, v) {
          o.check();
          async.flushMicrotasks();
          expect(s(c).status, newer ? OtaStatus.available : OtaStatus.upToDate, reason: 'build $build, min $minBuild');
          async.elapse(const Duration(seconds: 10));
        });
      }
    });

    test('the answer is remembered: "not modified" keeps the release that was found', () {
      run((async, c, p, o, v) {
        o.check();
        async.flushMicrotasks();
        expect(PrefsService.getString(PrefsKeys.updateEtag, ''), 'W/"mock"');
        p.checkStatus = 304;
        o.check();
        async.flushMicrotasks();
        expect(p.checks.last, 'W/"mock"', reason: 'the ETag goes back');
        expect(s(c).status, OtaStatus.available);
        async.elapse(const Duration(seconds: 10));
      });
    });
  });

  group('the notice', () {
    test('the bell lights once per release; seen and skipped put it out', () {
      run((async, c, p, o, v) {
        c.listen(bellProvider, (_, _) {});
        o.check();
        async.flushMicrotasks();
        expect(c.read(bellProvider), isTrue);
        c.read(otaScreenOpenProvider.notifier).open();
        expect(c.read(bellProvider), isFalse);
        c.read(otaScreenOpenProvider.notifier).close();
        expect(c.read(bellProvider), isFalse, reason: 'seen once');
        o.skip();
        expect(s(c).offered, isFalse);

        p.release = MockPlatformService.fakeRelease(build: 130, version: '0.3.0');
        o.check();
        async.flushMicrotasks();
        expect(s(c).offered, isTrue);
        expect(c.read(bellProvider), isTrue, reason: 'a newer one than the skipped');
        async.elapse(const Duration(seconds: 10));
      });
    });
  });

  group('download and verify', () {
    test('downloaded, checked on all four counts, ready', () {
      run((async, c, p, o, v) {
        toReady(async, o);
        expect(s(c).status, OtaStatus.ready);
        expect(log('download').single, containsPair('ok', true));
        expect(log('verify').single, {'sha': true, 'pkg': true, 'build': true, 'sig': true});
        expect(p.deleted, isEmpty);
      });
    });

    test('cancel stops it and nothing is kept', () {
      run((async, c, p, o, v) {
        o.check();
        async.flushMicrotasks();
        o.startDownload();
        async.elapse(const Duration(seconds: 1));
        expect(s(c).status, OtaStatus.downloading);
        o.cancelDownload();
        expect(s(c).status, OtaStatus.available);
        async.elapse(const Duration(seconds: 5));
        expect(s(c).status, OtaStatus.available);
        expect(p.deleted, [MockPlatformService.updatePath]);
        expect(log('verify'), isEmpty);
      });
    });

    test('a failed download says so and is not installed', () {
      run(before: (p) => p.downloadFails = true, (async, c, p, o, v) {
        toReady(async, o);
        expect(s(c).status, OtaStatus.failed);
        expect(log('download').single, containsPair('ok', false));
        o.retry();
        expect(s(c).status, OtaStatus.available);
      });
    });

    for (final (name, break_, field) in <(String, void Function(MockPlatformService), String)>[
      ('a different checksum', (p) => p.downloadedSha = 'beef', 'sha'),
      ('another package', (p) => p.downloadedPackage = 'com.example.other', 'pkg'),
      ('another build than the release names', (p) => p.downloadedBuild = 121, 'build'),
      ('a build that is not newer', (p) {
        p.release = MockPlatformService.fakeRelease(build: 120);
        p.downloadedBuild = 100;
      }, 'build'),
      ('another signing certificate', (p) => p.downloadedSigner = 'bb22', 'sig'),
    ]) {
      test('$name: the file is deleted and nothing is installed', () {
        run(before: break_, (async, c, p, o, v) {
          toReady(async, o);
          expect(s(c).status, OtaStatus.failed);
          expect(s(c).error, isNotEmpty);
          expect(log('verify').single[field], isFalse);
          expect(p.deleted, [MockPlatformService.updatePath]);
          o.startInstall();
          async.elapse(const Duration(seconds: 2));
          expect(p.selfInstalls, isEmpty);
          expect(c.read(passcodeGateProvider).open, isFalse);
        });
      });
    }
  });

  group('install', () {
    test('parked: passcode, then Android\'s installer, with the record written', () {
      run((async, c, p, o, v) {
        toReady(async, o);
        o.startInstall();
        expect(p.selfInstalls, isEmpty, reason: 'the passcode comes first');
        passcode(async, c);
        expect(p.selfInstalls.single, (MockPlatformService.updatePath, 120));
        expect(s(c).status, OtaStatus.installing);
        expect(log('install_start').single, {'from': 100, 'to': 120});
        expect(p.record, {'from': 100, 'to': 120, 'starts': 0});
        // Nothing closes the screen while Android has it.
        c.read(otaScreenOpenProvider.notifier).open();
        c.read(otaScreenOpenProvider.notifier).close();
        expect(c.read(otaScreenOpenProvider), isTrue);
      });
    });

    test('"Install apps" is asked for first when it is off, and required', () {
      run(before: (p) => p.installAllowed = false, (async, c, p, o, v) {
        c.read(accessProvider.notifier).done();
        toReady(async, o);
        o.startInstall();
        passcode(async, c);
        expect(p.selfInstalls, isEmpty);
        final request = c.read(accessProvider).request!;
        expect(request.required, {Access.install});
        c.read(accessProvider.notifier).done();
        expect(p.selfInstalls, isEmpty, reason: 'not without it');
        async.elapse(const Duration(seconds: 5));
      });
    });

    for (final (name, make, reason) in <(String, void Function(ProviderContainer, VehicleNotifier), String)>[
      ('locked', (c, v) => v.setLocked(true), 'locked'),
      ('out of Park', (c, v) => v.setVehicleState(VehicleState.ready), 'not_parked'),
      ('on a call', (c, v) => v.setCallActive(true), 'call'),
      ('behind another app', (c, v) => c.read(promptSurfaceVisibleProvider.notifier).screenShown(false), 'background'),
    ]) {
      test('refused while $name', () {
        run((async, c, p, o, v) {
          toReady(async, o);
          make(c, v);
          async.elapse(const Duration(seconds: 1));
          expect(o.installRefusal(), reason);
          o.startInstall();
          async.elapse(const Duration(seconds: 2));
          expect(c.read(passcodeGateProvider).open, isFalse);
          expect(p.selfInstalls, isEmpty);
          expect(log('refused').last, {'reason': reason});
          async.elapse(const Duration(seconds: 10));
        });
      });
    }

    test('refused while moving', () {
      run((async, c, p, o, v) {
        toReady(async, o);
        v.setVehicleState(VehicleState.riding);
        v.setSpeed(12);
        async.elapse(const Duration(seconds: 1));
        o.startInstall();
        expect(p.selfInstalls, isEmpty);
        expect(log('refused').last['reason'], anyOf('moving', 'riding'));
        async.elapse(const Duration(seconds: 30));
      });
    });

    test('setting off while the passcode is typed stops the hand-over', () {
      run((async, c, p, o, v) {
        toReady(async, o);
        o.startInstall();
        v.setVehicleState(VehicleState.ready);
        passcode(async, c);
        expect(p.selfInstalls, isEmpty);
        expect(log('refused').last, {'reason': 'not_parked'});
        async.elapse(const Duration(seconds: 10));
      });
    });

    test('Android refuses the file: said, the record cleared, the running build untouched', () {
      run(before: (p) => p.installError = 'IOException', (async, c, p, o, v) {
        toReady(async, o);
        o.startInstall();
        passcode(async, c);
        expect(s(c).status, OtaStatus.failed);
        expect(log('install_result').single, {'status': 'refused', 'message': 'IOException'});
        expect(p.record['to'], 0);
      });
    });

    test('cancelled on Android\'s confirmation: back to "ready", and it says so', () {
      run((async, c, p, o, v) {
        toReady(async, o);
        o.startInstall();
        passcode(async, c);
        final screen = c.read(promptSurfaceVisibleProvider.notifier);
        screen.screenShown(false);
        p.record = {...p.record, 'status': OtaNotifier.installerAborted, 'message': 'User rejected'};
        screen.screenShown(true);
        async.elapse(const Duration(seconds: 1));
        expect(s(c).status, OtaStatus.ready);
        expect(log('install_result').single, {'status': 3, 'message': 'User rejected'});
        expect(p.record['to'], 0);
        expect(toast(c), 'Update not installed');
        async.elapse(const Duration(seconds: 10));
      });
    });

    test('an installer that fails before its confirmation ever shows is still heard', () {
      run((async, c, p, o, v) {
        toReady(async, o);
        o.startInstall();
        passcode(async, c);
        expect(s(c).status, OtaStatus.installing);
        p.record = {...p.record, 'status': 1, 'message': 'confirm: ActivityNotFoundException'};
        async.elapse(OtaNotifier.answerEvery + const Duration(seconds: 1));
        expect(s(c).status, OtaStatus.failed);
        expect(log('install_result').single['status'], 1);
        c.read(otaScreenOpenProvider.notifier).close();
        async.elapse(const Duration(seconds: 10));
      });
    });

    test('any other installer failure: failed, with the reason logged', () {
      run((async, c, p, o, v) {
        toReady(async, o);
        o.startInstall();
        passcode(async, c);
        final screen = c.read(promptSurfaceVisibleProvider.notifier);
        screen.screenShown(false);
        p.record = {...p.record, 'status': 4, 'message': 'INSTALL_FAILED_INVALID_APK'};
        screen.screenShown(true);
        async.elapse(const Duration(seconds: 1));
        expect(s(c).status, OtaStatus.failed);
        expect(log('install_result').single['status'], 4);
      });
    });
  });

  group('coming back', () {
    test('the new build is running: confirmed after ten stable seconds, the record cleared, a toast', () {
      run(before: (p) {
        p.installedBuild = 120;
        p.record = {'from': 100, 'to': 120, 'starts': 1};
      }, (async, c, p, o, v) {
        expect(s(c).pendingBuild, 120);
        async.elapse(OtaNotifier.confirmAfter - const Duration(seconds: 1));
        expect(log('confirmed'), isEmpty);
        expect(p.record['to'], 120);
        async.elapse(const Duration(seconds: 2));
        expect(log('confirmed').single, {'from': 100, 'to': 120, 'starts': 1});
        expect(p.record['to'], 0);
        expect(s(c).pendingBuild, 0);
        expect(toast(c), startsWith('Updated to OpenDash'));
        async.elapse(const Duration(seconds: 10));
      });
    });

    test('the old build is still running: not replaced, the record cleared', () {
      run(before: (p) => p.record = {'from': 100, 'to': 120, 'starts': 0}, (async, c, p, o, v) {
        expect(log('install_result').single, {'status': 'not_replaced', 'message': null});
        expect(p.record['to'], 0);
        expect(s(c).pendingBuild, 0);
        expect(log('confirmed'), isEmpty);
      });
    });

    test('several starts before a stable one are reported', () {
      run(before: (p) {
        p.installedBuild = 120;
        p.record = {'from': 100, 'to': 120, 'starts': 3};
      }, (async, c, p, o, v) {
        expect(log('unconfirmed').single, {'starts': 3});
        async.elapse(OtaNotifier.confirmAfter + const Duration(seconds: 1));
        expect(log('confirmed').single['starts'], 3);
        async.elapse(const Duration(seconds: 10));
      });
    });

    test('a start after the stock-dashboard fallback is folded into the log', () {
      run(before: (p) {
        p.installedBuild = 120;
        p.record = {'from': 100, 'to': 120, 'starts': 5, 'fallback_log': '\n1794837397000 4'};
      }, (async, c, p, o, v) {
        expect(log('fallback_stock').single, {'starts': 5});
        async.elapse(const Duration(seconds: 30));
      });
    });

    test('with nothing pending, nothing is logged', () {
      run((async, c, p, o, v) {
        async.elapse(const Duration(seconds: 30));
        expect(log('confirmed') + log('install_result') + log('unconfirmed'), isEmpty);
      });
    });

    test('a release found before, that this build now is, is forgotten', () {
      run((async, c, p, o, v) {
        o.check();
        async.flushMicrotasks();
        expect(s(c).status, OtaStatus.available);
        async.elapse(const Duration(seconds: 10));
      });
      BuildInfo.number = 120;
      run(before: (p) => p.installedBuild = 120, (async, c, p, o, v) {
        expect(s(c).status, OtaStatus.upToDate);
        expect(s(c).release, isNull);
      });
    });
  });

  group('sent from the phone', () {
    String copyOf(int build) => MockPlatformService.incomingCopyPathFor(build);
    const copy = '/cache/apks/opendash-incoming-130.apk';
    String sent({int build = 130, String sha = 'c0ffee', String version = '0.3.0', bool manual = false}) => jsonEncode({
          'version': version,
          'build': build,
          'apk': 'opendash-$version.apk',
          'sha256': sha,
          'notes': 'Sent from the phone.',
          'published': '2026-11-30',
          if (manual) 'manual': true,
        });
    void stage(MockPlatformService p,
        {int build = 130, String sha = 'c0ffee', String signer = MockPlatformService.ownSigner, bool manual = false, String version = '0.3.0'}) {
      p.incoming = sent(build: build, sha: sha, manual: manual, version: version);
      p.apkInfos[copyOf(build)] = ApkInfo(package: MockPlatformService.ownPackage, versionCode: build, versionName: version, signer: signer);
    }

    Map<String, Object?> published(MockPlatformService p) => (jsonDecode(p.published.last) as Map).cast<String, Object?>();

    test('tells the phone whether it may send updates by itself', () {
      run((async, c, p, o, v) {
        expect(published(p), {'v': 1, 'auto': true, 'installed': 100, 'skipped': 0});
        o.setAuto(false);
        expect(published(p)['auto'], false);
        o.check();
        async.flushMicrotasks();
        o.skip();
        expect(published(p)['skipped'], 120);
        async.elapse(const Duration(seconds: 10));
      });
    });

    test('a good update from the phone is ready to install, with one toast', () {
      run(before: (p) => stage(p), (async, c, p, o, v) {
        expect(s(c).status, OtaStatus.ready);
        expect(s(c).release!.build, 130);
        expect(s(c).release!.notes, 'Sent from the phone.');
        expect(s(c).bell, isTrue);
        expect(toast(c), 'OpenDash 0.3.0 is ready to install. Sent from your phone');
        expect(p.incomingCleared, 0, reason: 'kept until it is installed');
        async.elapse(OtaNotifier.incomingEvery * 3);
        expect(p.incomingCopies, 1, reason: 'not copied again while it is ready');
        expect(log('incoming').where((e) => e['result'] == 'ready'), hasLength(1));
      });
    });

    test('survives a restart, toasts once', () {
      run(before: (p) => stage(p), (async, c, p, o, v) {
        expect(s(c).status, OtaStatus.ready);
        async.elapse(const Duration(seconds: 10));
      });
      run(before: (p) => stage(p), (async, c, p, o, v) {
        expect(s(c).status, OtaStatus.ready);
        expect(toast(c), isNull);
      });
    });

    test('a bad push leaves the update state alone', () {
      for (final bad in [(sha: 'deadbeef', signer: MockPlatformService.ownSigner), (sha: 'c0ffee', signer: 'zz99')]) {
        run((async, c, p, o, v) {
          o.check();
          async.flushMicrotasks();
          expect(s(c).status, OtaStatus.available);
          stage(p, sha: bad.sha, signer: bad.signer);
          async.elapse(OtaNotifier.incomingEvery + const Duration(seconds: 1));
          expect(s(c).status, OtaStatus.available);
          expect(s(c).release!.build, 120);
          expect(p.incomingCleared, 1);
          expect(p.deleted, contains(copy));
          expect(log('incoming').last['result'], 'rejected');
          expect(toast(c), isNull);
        });
      }
    });

    test('no release file, nothing happens', () {
      run((async, c, p, o, v) {
        async.elapse(OtaNotifier.incomingEvery + const Duration(seconds: 1));
        expect(p.incomingCopies, 0);
        expect(p.incomingCleared, 0);
        expect(s(c).status, OtaStatus.upToDate);
      });
    });

    test('an update that is not newer than this build is cleared', () {
      run(before: (p) => stage(p, build: 100), (async, c, p, o, v) {
        expect(p.incomingCleared, 1);
        expect(p.incomingCopies, 0);
        expect(s(c).status, OtaStatus.upToDate);
        expect(log('incoming').single['result'], 'obsolete');
      });
    });

    test('no pickup while downloading', () {
      run((async, c, p, o, v) {
        o.check();
        async.flushMicrotasks();
        o.startDownload();
        stage(p);
        o.checkIncoming();
        async.flushMicrotasks();
        expect(p.incomingCopies, 0);
        expect(s(c).status, OtaStatus.downloading);
        async.elapse(const Duration(seconds: 5));
      });
    });

    test('sending a version skipped on the dashboard by hand un-skips it', () {
      run((async, c, p, o, v) {
        o.check();
        async.flushMicrotasks();
        o.skip();
        stage(p, build: 120, manual: true);
        async.elapse(OtaNotifier.incomingEvery + const Duration(seconds: 1));
        expect(s(c).status, OtaStatus.ready);
        expect(s(c).skippedBuild, 0);
        expect(s(c).offered, isTrue);
      });
    });

    test('a version skipped on the dashboard and sent by itself stays skipped', () {
      run((async, c, p, o, v) {
        o.check();
        async.flushMicrotasks();
        o.skip();
        stage(p, build: 120);
        async.elapse(OtaNotifier.incomingEvery + const Duration(seconds: 1));
        expect(s(c).status, OtaStatus.available);
        expect(s(c).skippedBuild, 120);
        expect(p.incomingCleared, 1);
      });
    });

    test('a newer update from the phone that fails leaves the ready one intact', () {
      run(before: (p) => stage(p), (async, c, p, o, v) {
        expect(s(c).status, OtaStatus.ready);
        stage(p, build: 140, sha: 'deadbeef');
        async.elapse(OtaNotifier.incomingEvery + const Duration(seconds: 1));
        expect(s(c).status, OtaStatus.ready);
        expect(s(c).release!.build, 130);
        expect(p.deleted, isNot(contains(copyOf(130))), reason: 'the ready file is not the one thrown away');
        expect(p.deleted, contains(copyOf(140)));
      });
    });

    test('a newer update from the phone that passes replaces the ready one', () {
      run(before: (p) => stage(p), (async, c, p, o, v) {
        stage(p, build: 140, version: '0.4.0');
        async.elapse(OtaNotifier.incomingEvery + const Duration(seconds: 1));
        expect(s(c).status, OtaStatus.ready);
        expect(s(c).release!.build, 140);
        expect(p.deleted, contains(copyOf(130)));
        o.startInstall();
        passcode(async, c);
        expect(p.selfInstalls.last.$1, copyOf(140));
      });
    });

    test('an older update from the phone does not push out a newer release', () {
      run((async, c, p, o, v) {
        p.release = MockPlatformService.fakeRelease(build: 150, version: '0.5.0');
        o.check();
        async.flushMicrotasks();
        stage(p, build: 130);
        async.elapse(OtaNotifier.incomingEvery + const Duration(seconds: 1));
        expect(s(c).status, OtaStatus.available);
        expect(s(c).release!.build, 150);
        expect(p.incomingCopies, 0);
        expect(p.incomingCleared, 1);
      });
    });

    test('after Android refused it, the same update is not copied in again and again', () {
      run(before: (p) => stage(p), (async, c, p, o, v) {
        p.installError = 'refused';
        o.startInstall();
        passcode(async, c);
        expect(s(c).status, OtaStatus.failed);
        async.elapse(OtaNotifier.incomingEvery * 4);
        expect(p.incomingCopies, 1);
        expect(s(c).status, OtaStatus.failed);
      });
    });
  });
}
