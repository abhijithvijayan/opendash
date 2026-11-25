import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/app_catalog.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/services/recovery_service.dart';
import 'package:opendash/services/wifican_codec.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/control_panel.dart';
import 'package:opendash/state/passcode_gate.dart';
import 'package:opendash/state/prompt_surface.dart';
import 'package:opendash/state/recovery_panel.dart';
import 'package:opendash/state/riding_lockout.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/safety_watchdog.dart';
import 'package:opendash/state/scooter_restart.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/toast_state.dart';
import '../helpers/stock.dart';

class _Live extends VehicleNotifier {
  int locks = 0;
  int autoParks = 0;
  int reboots = 0;

  @override
  VehicleData build() => super.build().copyWith(hhmisBacked: true, hhmisConnected: true);

  @override
  void lockScooter() => locks++;

  @override
  void autoPark() => autoParks++;

  @override
  Future<bool> rebootScooter() async {
    reboots++;
    return true;
  }
}

class _Shell implements RecoveryClient {
  final executed = <String>[];

  @override
  Future<WifiCanResponse> execute(String command, Duration timeout) async {
    executed.add(command);
    return WifiCanResponse(1, '');
  }

  @override
  Future<void> shutdown() async {}
}

List<Map<String, Object?>> _data(String cat, String evt) =>
    [for (final e in AnalyticsLogger.instance.recent(cat, evt)) Map<String, Object?>.from(e['data'] as Map)];
List<Map<String, Object?>> _cancels() => _data('safety', 'untrusted_cancel');
List<Object?> _watchdogCancels() => [for (final d in _data('safety', 'watchdog_cancel')) d['reason']];

CatalogApp _app(String id) => appCatalog.firstWhere((a) => a.id == id);

void main() {
  setUp(AnalyticsLogger.instance.resetForTest);

  void live(void Function(FakeAsync async, ProviderContainer c, _Live v, MockPlatformService platform) body) {
    fakeAsync((async) {
      final v = _Live();
      final platform = MockPlatformService();
      final c = ProviderContainer(overrides: [
        vehicleProvider.overrideWith(() => v),
        platformServiceProvider.overrideWithValue(platform),
      ]);
      c.listen(toastProvider, (_, _) {});
      c.listen(sessionProvider, (_, _) {});
      c.listen(ridingLockoutProvider, (_, _) {});
      c.listen(appManagerProvider, (_, _) {});
      v.setLocked(false);
      v.setVehicleState(VehicleState.parked);
      async.flushMicrotasks();
      body(async, c, v, platform);
      c.dispose();
    });
  }

  void shown(ProviderContainer c, bool on) => c.read(promptSurfaceVisibleProvider.notifier).screenShown(on);

  void enterGate(ProviderContainer c) {
    for (final d in [1, 2, 3, 4, 5, 6]) {
      c.read(passcodeGateProvider.notifier).enterDigit(d);
    }
  }

  test('the mock is always showing', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(promptSurfaceVisibleProvider), isTrue);
  });

  group('auto-park', () {
    void standDown(ProviderContainer c, _Live v) {
      c.listen(safetyWatchdogProvider, (_, _) {});
      c.read(ridingSettingsProvider.notifier).setAutoLockEnabled(true);
      v.setVehicleState(VehicleState.ready);
      v.setSpeed(20);
      v.setSideStand(true);
      v.setSpeed(0);
    }

    test('behind another app: no countdown, the dashboard is asked forward, the full countdown starts once it is there', () {
      live((async, c, v, platform) {
        shown(c, false);
        standDown(c, v);
        expect(c.read(safetyWatchdogProvider).armed, isFalse);
        expect(platform.broughtToFront, 1);
        expect(_data('apps', 'prompt_return'), [{'id': null, 'prompt': 'auto_park'}]);
        expect(_data('safety', 'watchdog_arm'), isEmpty);

        async.elapse(const Duration(milliseconds: 200));
        shown(c, true);
        expect(c.read(safetyWatchdogProvider).armed, isTrue);
        expect(c.read(safetyWatchdogProvider).remainingSeconds, SafetyWatchdog.delay.inSeconds);
        async.elapse(SafetyWatchdog.delay - const Duration(seconds: 1));
        expect(v.autoParks, 0);
        async.elapse(const Duration(seconds: 1));
        expect(v.autoParks, 1);
        expect(_watchdogCancels(), isEmpty);
      });
    });

    test('the dashboard does not come forward in time: nothing is locked, logged as background', () {
      live((async, c, v, platform) {
        shown(c, false);
        standDown(c, v);
        async.elapse(SafetyWatchdog.frontBound - const Duration(milliseconds: 100));
        expect(_watchdogCancels(), isEmpty);
        async.elapse(const Duration(minutes: 5));
        expect(_watchdogCancels(), ['background']);
        expect(v.autoParks, 0);
        expect(c.read(safetyWatchdogProvider).armed, isFalse);
        expect(platform.broughtToFront, 1, reason: 'asked once, not in a loop');

        shown(c, true);
        expect(c.read(safetyWatchdogProvider).remainingSeconds, SafetyWatchdog.delay.inSeconds,
            reason: 'the stand is still down when the rider is back');
      });
    });

    test('losing the screen mid-countdown cancels it; it never fires behind, and restarts in full', () {
      live((async, c, v, platform) {
        standDown(c, v);
        async.elapse(const Duration(seconds: 3));
        expect(c.read(safetyWatchdogProvider).remainingSeconds, 2);
        shown(c, false);
        expect(c.read(safetyWatchdogProvider).armed, isFalse);
        expect(_watchdogCancels(), ['background']);
        expect(_cancels(), [{'flow': 'auto_park', 'reason': 'background'}]);
        expect(c.read(toastProvider), isNull, reason: 'nobody is there to read a toast');
        expect(platform.broughtToFront, 1);
        async.elapse(const Duration(minutes: 1));
        expect(v.autoParks, 0);

        shown(c, true);
        expect(c.read(safetyWatchdogProvider).remainingSeconds, SafetyWatchdog.delay.inSeconds);
        shown(c, false);
        expect(platform.broughtToFront, 1, reason: 'one request per stand episode');
        async.elapse(const Duration(minutes: 1));
        expect(v.autoParks, 0);
      });
    });

    test('the stand going up while behind drops the request', () {
      live((async, c, v, platform) {
        shown(c, false);
        standDown(c, v);
        v.setSideStand(false);
        async.elapse(const Duration(minutes: 1));
        expect(_watchdogCancels(), isEmpty);
        shown(c, true);
        expect(c.read(safetyWatchdogProvider).armed, isFalse);
      });
    });

    test('"Keep riding" still holds after a trip behind another app', () {
      live((async, c, v, platform) {
        standDown(c, v);
        c.read(safetyWatchdogProvider.notifier).cancel();
        shown(c, false);
        shown(c, true);
        async.elapse(const Duration(minutes: 1));
        expect(c.read(safetyWatchdogProvider).armed, isFalse);
        expect(platform.broughtToFront, 0);
        expect(v.autoParks, 0);
      });
    });

    test('Retry after a failed lock is refused behind another app', () {
      live((async, c, v, platform) {
        standDown(c, v);
        async.elapse(SafetyWatchdog.delay);
        expect(v.autoParks, 1);
        shown(c, false);
        c.read(safetyWatchdogProvider.notifier).retryLock();
        expect(v.autoParks, 1);
        expect(_data('safety', 'untrusted_refused'), [{'flow': 'auto_park_retry', 'reason': 'background'}]);
      });
    });

    test('phone projection in front is pulled back too, with the way back offered', () {
      live((async, c, v, platform) {
        c.listen(mockAppProvider, (_, _) {});
        c.listen(projectionResumeProvider, (_, _) {});
        c.read(appManagerProvider.notifier).launch(_app('android-auto'));
        async.elapse(const Duration(milliseconds: 500));
        expect(c.read(mockAppProvider)?.id, 'android-auto');
        shown(c, false);
        standDown(c, v);
        expect(_data('apps', 'prompt_return'), [{'id': 'android-auto', 'prompt': 'auto_park'}]);
        expect(platform.broughtToFront, greaterThanOrEqualTo(1));
        expect(c.read(mockAppProvider), isNull);
        expect(c.read(projectionResumeProvider)?.id, 'android-auto');
        expect(c.read(safetyWatchdogProvider).armed, isFalse);
        shown(c, true);
        expect(c.read(safetyWatchdogProvider).armed, isTrue);
      });
    });
  });

  group('pending actions cancel when the screen is lost', () {
    test('restart confirm, with live data', () {
      live((async, c, v, platform) {
        c.listen(passcodeGateProvider, (_, _) {});
        c.listen(scooterRestartProvider, (_, _) {});
        c.read(scooterRestartProvider.notifier).request('test');
        enterGate(c);
        async.flushMicrotasks();
        expect(c.read(scooterRestartProvider)?.liveData, isTrue);
        shown(c, false);
        expect(c.read(scooterRestartProvider), isNull);
        expect(_cancels(), [{'flow': 'restart_confirm', 'reason': 'background'}]);
        c.read(scooterRestartProvider.notifier).confirm();
        async.elapse(const Duration(seconds: 30));
        expect(v.reboots, 0);
      });
    });

    test('restart confirm, rider vouching without live data', () {
      live((async, c, v, platform) {
        final shell = _Shell();
        recoveryService = RecoveryService(clientFactory: (_, _) => shell);
        addTearDown(() => recoveryService = RecoveryService());
        c.listen(passcodeGateProvider, (_, _) {});
        c.listen(scooterRestartProvider, (_, _) {});
        v.setConnected(false);
        c.read(scooterRestartProvider.notifier).request('test');
        enterGate(c);
        async.flushMicrotasks();
        expect(c.read(scooterRestartProvider)?.liveData, isFalse);
        shown(c, false);
        expect(c.read(scooterRestartProvider), isNull);
        expect(_cancels(), [{'flow': 'restart_confirm', 'reason': 'background'}]);
        async.elapse(const Duration(seconds: 30));
        expect(v.reboots, 0);
        expect(shell.executed, isEmpty);
      });
    });

    test('a lock in flight', () {
      live((async, c, v, platform) {
        c.listen(lockingProvider, (_, _) {});
        c.read(lockingProvider.notifier).start();
        expect(c.read(lockingProvider), isTrue);
        shown(c, false);
        expect(c.read(lockingProvider), isFalse);
        expect(_cancels(), [{'flow': 'lock', 'reason': 'background'}]);
        async.elapse(const Duration(seconds: 10));
        expect(v.locks, 0);

        c.read(lockingProvider.notifier).start();
        expect(c.read(lockingProvider), isFalse, reason: 'and none starts behind another app');
        expect(_data('safety', 'untrusted_refused'), [{'flow': 'lock', 'reason': 'background'}]);
      });
    });

    test('the passcode gate, even one that tolerates unknown data', () {
      live((async, c, v, platform) {
        c.listen(passcodeGateProvider, (_, _) {});
        var ran = 0;
        c.read(passcodeGateProvider.notifier).request(purpose: 'test', onSuccess: () => ran++, allowUnknown: true);
        expect(c.read(passcodeGateProvider).open, isTrue);
        shown(c, false);
        expect(c.read(passcodeGateProvider).open, isFalse);
        expect(_cancels(), [{'flow': 'passcode_gate', 'reason': 'background'}]);
        shown(c, true);
        enterGate(c);
        async.flushMicrotasks();
        expect(ran, 0);
      });
    });

    test('the recovery stock-restart confirm; once confirmed, the launch does not cancel itself', () {
      live((async, c, v, platform) {
        final shell = _Shell();
        recoveryService = RecoveryService(clientFactory: (_, _) => shell);
        addTearDown(() => recoveryService = RecoveryService());
        c.listen(recoveryPanelProvider, (_, _) {});
        final p = c.read(recoveryPanelProvider.notifier);
        p.askRestartStock();
        expect(c.read(recoveryPanelProvider), isTrue);
        shown(c, false);
        expect(c.read(recoveryPanelProvider), isFalse);
        expect(_cancels(), [{'flow': 'recovery_restart_stock', 'reason': 'background'}]);
        p.confirmRestartStock();
        async.flushMicrotasks();
        expect(shell.executed, isEmpty);

        shown(c, true);
        p.askRestartStock();
        p.confirmRestartStock();
        async.flushMicrotasks();
        shown(c, false);
        async.elapse(const Duration(seconds: 1));
        expect(shell.executed, isNotEmpty, reason: 'the stock dashboard was started');
        expect(_cancels(), hasLength(1), reason: 'nothing new was cancelled');
        expect(_data('apps', 'opened').last['id'], CatalogApp.stockDashboardId);
      });
    });

    test('opening an app behind its passcode: the launch takes the screen and cancels nothing', () {
      live((async, c, v, platform) {
        c.listen(passcodeGateProvider, (_, _) {});
        c.listen(mockAppProvider, (_, _) {});
        c.read(appManagerProvider.notifier).launch(_app('android-settings'));
        async.flushMicrotasks();
        enterGate(c);
        async.elapse(const Duration(milliseconds: 500));
        shown(c, false);
        async.elapse(const Duration(seconds: 30));
        expect(c.read(mockAppProvider)?.id, 'android-settings');
        expect(_cancels(), isEmpty);
        expect(_data('apps', 'auto_return'), isEmpty, reason: 'parked, with live data: it stays');
        expect(platform.broughtToFront, 0);
      });
    });
  });

  group('AidlVehicleNotifier behind another app', () {
    const parked = {'_connected': true, 'INT_VEHICLE_STATE': 3, 'INT_VEHICLE_ESCL_STATUS': 1, 'INT_VEHICLE_SPEED': 0, 'INT_VEHICLE_MOTOR_RPM': 0};
    const tick = Duration(milliseconds: 200);

    void aidl(void Function(FakeAsync async, ProviderContainer c, AidlVehicleNotifier n, List<String> calls, MockPlatformService platform) body) {
      fakeAsync((async) {
        AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
        final events = StreamController<dynamic>();
        final calls = <String>[];
        final platform = MockPlatformService();
        final c = ProviderContainer(overrides: [
          vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), 
                events: events.stream,
                invoke: (method, args) async {
                  final heartbeat = args is Map && (args['cmd'] == HhmisCmd.touchStatus || args['cmd'] == HhmisCmd.projectLoaded);
                  if (!heartbeat) calls.add(args is Map ? '$method $args' : method);
                  return true;
                },
              )),
          platformServiceProvider.overrideWithValue(platform),
        ]);
        c.listen(toastProvider, (_, _) {});
        c.listen(sessionProvider, (_, _) {});
        c.listen(ridingLockoutProvider, (_, _) {});
        c.listen(appManagerProvider, (_, _) {});
        final n = c.read(vehicleProvider.notifier) as AidlVehicleNotifier;
        n.onEvent(parked);
        async.flushMicrotasks();
        body(async, c, n, calls, platform);
        c.dispose();
        events.close();
        AnalyticsLogger.instance.monoOverride = null;
      });
    }

    /// HHMIS keeps streaming to us, as it did with Android Auto and Android
    /// Settings in front (~100 batches a second).
    void stream(FakeAsync async, AidlVehicleNotifier n, Duration length, {int speed = 0, int rpm = 0}) {
      for (var t = Duration.zero; t < length; t += tick) {
        async.elapse(tick);
        n.onEvent({'INT_VEHICLE_SPEED': speed, 'INT_VEHICLE_MOTOR_RPM': rpm});
      }
    }

    int reattaches(List<String> calls) => calls.where((c) => c == 'reattachCallback').length;
    List<Object?> staleFlags() => [for (final d in _data('hhmis', 'stale')) (d['on'], d['in_front'])];

    test('the lifecycle feeds the surface', () {
      aidl((async, c, n, calls, platform) {
        expect(c.read(promptSurfaceVisibleProvider), isTrue);
        n.onLifecyclePause();
        expect(c.read(promptSurfaceVisibleProvider), isFalse);
        n.onLifecycleResume();
        expect(c.read(promptSurfaceVisibleProvider), isTrue);
      });
    });

    test('data frozen while paused is not a proven stop, without the badge and without a reattach', () {
      aidl((async, c, n, calls, platform) {
        n.onLifecyclePause();
        async.elapse(AidlVehicleNotifier.staleAfter - const Duration(milliseconds: 600));
        expect(c.read(vehicleProvider).provenStopped, isTrue);
        async.elapse(const Duration(seconds: 1));
        final v = c.read(vehicleProvider);
        expect(v.hhmisSilent, isTrue);
        expect(v.provenStopped, isFalse);
        expect(v.speedUntrustedReason, 'stale');
        expect(v.hhmisStale, isFalse, reason: 'the "Reconnecting…" badge is for the screen in front');
        expect(v.hhmisKnown, isTrue);
        async.elapse(const Duration(minutes: 10));
        expect(reattaches(calls), 0, reason: 'the stock dashboard may hold the slot on purpose');
        expect(staleFlags(), [(true, false)], reason: 'logged once');

        n.lockScooter();
        n.autoPark();
        async.flushMicrotasks();
        expect(calls.where((c) => c.startsWith('sendIntCmd')), isEmpty);
      });
    });

    test('data that keeps flowing behind another app stays trusted', () {
      aidl((async, c, n, calls, platform) {
        n.onLifecyclePause();
        stream(async, n, const Duration(seconds: 10));
        expect(c.read(vehicleProvider).hhmisSilent, isFalse);
        expect(c.read(vehicleProvider).provenStopped, isTrue);
        expect(c.read(ridingLockoutProvider), isFalse);
        expect(staleFlags(), isEmpty);
      });
    });

    // Seen in a log: paused 4012 s with no batches, resumed, reattach
    // at once, live data 0.03-1.0 s later. Seven hourly wakes like it.
    test('an hourly doze wake: no badge flash, one reattach, proven again with the first data', () {
      aidl((async, c, n, calls, platform) {
        for (var wake = 0; wake < 3; wake++) {
          n.onLifecyclePause();
          async.elapse(const Duration(seconds: 4012));
          expect(c.read(vehicleProvider).provenStopped, isFalse);
          final before = reattaches(calls);
          n.onLifecycleResume();
          async.flushMicrotasks();
          expect(reattaches(calls), before + 1);
          expect(_data('hhmis', 'reattach_scheduled').last['gap_s'], 4012);
          async.elapse(const Duration(milliseconds: 35));
          n.onEvent({'INT_VEHICLE_STATE': 0, '_volume': 5});
          expect(c.read(vehicleProvider).provenStopped, isFalse, reason: 'the reattach echo proves nothing');
          async.elapse(const Duration(milliseconds: 930));
          expect(c.read(vehicleProvider).hhmisStale, isFalse);
          n.onEvent(parked);
          expect(c.read(vehicleProvider).hhmisSilent, isFalse);
          expect(c.read(vehicleProvider).provenStopped, isTrue);
          stream(async, n, const Duration(seconds: 30));
        }
        expect(staleFlags().where((f) => f == (true, null)), isEmpty, reason: 'the badge never came up');
        expect(c.read(vehicleProvider).hhmisStale, isFalse);
      });
    });

    test('a short trip to an app that leaves us the feed changes nothing on the way back', () {
      aidl((async, c, n, calls, platform) {
        c.listen(lockingProvider, (_, _) {});
        n.onLifecyclePause();
        stream(async, n, const Duration(milliseconds: 9800));
        n.onLifecycleResume();
        stream(async, n, const Duration(seconds: 5));
        expect(staleFlags(), isEmpty);
        expect(reattaches(calls), 0);
        expect(c.read(ridingLockoutProvider), isFalse);
        c.read(lockingProvider.notifier).start();
        expect(c.read(lockingProvider), isTrue);
      });
    });

    test('riding off behind an app with the data frozen brings the dashboard back, once', () {
      aidl((async, c, n, calls, platform) {
        c.read(appManagerProvider.notifier).trackOutsidePackage('android-settings', 'Settings', 'com.android.settings');
        async.flushMicrotasks();
        n.onLifecyclePause();
        async.elapse(AidlVehicleNotifier.staleAfter + RidingLockout.grace - const Duration(seconds: 1));
        expect(platform.broughtToFront, 0);
        async.elapse(const Duration(seconds: 2));
        expect(c.read(ridingLockoutProvider), isTrue);
        expect(platform.broughtToFront, 1);
        expect(_data('apps', 'auto_return'), [{'id': 'android-settings', 'reason': 'unknown'}]);
        async.elapse(const Duration(minutes: 5));
        expect(platform.broughtToFront, 1, reason: 'one attempt for the episode');
        expect(reattaches(calls), 0);

        n.onLifecycleResume();
        async.flushMicrotasks();
        n.onEvent({'INT_VEHICLE_SPEED': 32, 'INT_VEHICLE_MOTOR_RPM': 10});
        expect(c.read(vehicleProvider).speedTrusted, isTrue);
        expect(c.read(ridingLockoutProvider), isTrue, reason: 'now because it is moving');
        expect(platform.broughtToFront, 1);
      });
    });

    test('riding off with the feed intact brings it back on the speed', () {
      aidl((async, c, n, calls, platform) {
        c.read(appManagerProvider.notifier).trackOutsidePackage('android-settings', 'Settings', 'com.android.settings');
        async.flushMicrotasks();
        n.onLifecyclePause();
        stream(async, n, const Duration(seconds: 20));
        expect(platform.broughtToFront, 0);
        n.onEvent({'INT_VEHICLE_SPEED': 6, 'INT_VEHICLE_MOTOR_RPM': 2});
        expect(platform.broughtToFront, 1);
        expect(_data('apps', 'auto_return'), [{'id': 'android-settings', 'reason': 'moving'}]);
      });
    });

    // Seen in a log: 30 s and 39 s behind the stock dashboard,
    // not one batch for us in either.
    test('the stock dashboard opened while parked takes the feed and is left alone', () {
      aidl((async, c, n, calls, platform) {
        c.listen(safetyWatchdogProvider, (_, _) {});
        c.read(appManagerProvider.notifier).trackOutsideStock();
        async.flushMicrotasks();
        n.onLifecyclePause();
        async.elapse(const Duration(minutes: 10));
        expect(c.read(vehicleProvider).provenStopped, isFalse, reason: 'unknown, and treated as such');
        expect(c.read(ridingLockoutProvider), isTrue);
        expect(platform.broughtToFront, 0);
        expect(_data('apps', 'auto_return'), isEmpty);
        expect(_data('apps', 'auto_return_skipped'), [{'id': CatalogApp.stockDashboardId, 'reason': 'stock_holds_feed'}]);
        expect(reattaches(calls), 0);
        expect(c.read(safetyWatchdogProvider).armed, isFalse);
      });
    });

    test('phone projection stays in front on frozen data', () {
      aidl((async, c, n, calls, platform) {
        c.listen(mockAppProvider, (_, _) {});
        c.read(appManagerProvider.notifier).launch(_app('android-auto'));
        async.elapse(const Duration(milliseconds: 500));
        n.onLifecyclePause();
        async.elapse(const Duration(minutes: 1));
        expect(c.read(ridingLockoutProvider), isTrue);
        expect(platform.broughtToFront, 0);
        expect(c.read(mockAppProvider)?.id, 'android-auto');
      });
    });
  });
}
