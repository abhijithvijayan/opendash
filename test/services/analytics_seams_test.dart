import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/constants.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/battery_diagnostics_provider.dart';
import 'package:opendash/providers/grpc_diagnostics_provider.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/analytics_transitions.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/services/platform_service.dart';
import 'package:opendash/state/analytics_settings.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/error_state.dart';
import 'package:opendash/state/passcode_gate.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/safety_watchdog.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/widgets/debug/bookmark_gesture.dart';
import '../helpers/stock.dart';

class _Session implements FrameSession {
  _Session(this.stream);
  @override
  final Stream<List<int>> stream;
  final dump = StreamController<List<int>>();
  @override
  Stream<List<int>> openDump() => dump.stream;
  @override
  Future<void> close() async {}
}

void main() {
  setUp(() => AnalyticsLogger.instance.resetForTest());

  List<Map<String, Object?>> recent(String cat, [String? evt]) => AnalyticsLogger.instance.recent(cat, evt);
  List<String> names(String cat) => [for (final e in recent(cat)) '${e['evt']}'];

  group('hhmis', () {
    test('toggleHazard emits cmd_send with cmd 50 value 1 and a paired cmd_result', () {
      fakeAsync((async) {
        final events = StreamController<dynamic>();
        final c = ProviderContainer(overrides: [
          vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: events.stream, invoke: (m, a) async => true)),
        ]);
        c.read(vehicleProvider.notifier).toggleHazard();
        async.flushMicrotasks();
        final send = recent('hhmis', 'cmd_send').single['data'] as Map;
        expect(send['cmd'], HhmisCmd.hazardToggle);
        expect(send['value'], 1);
        expect(send['name'], 'hazardToggle');
        expect(send['type'], 'int');
        final result = recent('hhmis', 'cmd_result').single['data'] as Map;
        expect(result['seq'], send['seq']);
        expect(result['success'], isTrue);
        c.dispose();
        events.close();
      });
    });

    test('a refused bridge call logs the failure instead of throwing', () {
      fakeAsync((async) {
        final events = StreamController<dynamic>();
        final c = ProviderContainer(overrides: [
          vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: events.stream, invoke: (m, a) async => throw StateError('unbound'))),
        ]);
        (c.read(vehicleProvider.notifier) as AidlVehicleNotifier).onEvent({'_connected': true});
        c.read(vehicleProvider.notifier).lockScooter();
        async.flushMicrotasks();
        final result = recent('hhmis', 'cmd_result').single['data'] as Map;
        expect(result['success'], isFalse);
        expect(result['error'], contains('unbound'));
        c.dispose();
        events.close();
      });
    });

    test('passcode never reaches the log', () {
      fakeAsync((async) {
        final events = StreamController<dynamic>();
        final c = ProviderContainer(overrides: [
          vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: events.stream, invoke: (m, a) async => true)),
        ]);
        final n = c.read(vehicleProvider.notifier) as AidlVehicleNotifier;
        n.changePasscode('123456');
        n.verifyPasscode('123456');
        async.flushMicrotasks();
        for (final e in recent('hhmis')) {
          expect(e.toString(), isNot(contains('123456')));
        }
        expect((recent('hhmis', 'cmd_send').first['data'] as Map)['value'], '<redacted>');
        c.dispose();
        events.close();
      });
    });

    test('batches log a summary, raw transitions, bind and unknown keys', () {
      fakeAsync((async) {
        final events = StreamController<dynamic>();
        final c = ProviderContainer(overrides: [
          vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: events.stream, invoke: (m, a) async => true)),
        ]);
        final n = c.read(vehicleProvider.notifier) as AidlVehicleNotifier;
        n.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, 'STR_VEHICLE_DRIVE_MODE': 'ECO', 'INT_NEW_FIRMWARE_THING': 1});
        n.onEvent({'INT_VEHICLE_STATE': 4, 'INT_VEHICLE_ESCL_STATUS': 1, 'STR_VEHICLE_DRIVE_MODE': 'ECO'});
        n.onEvent({'STR_VEHICLE_DRIVE_MODE': 'LIMPHOME'});
        expect(names('hhmis'), containsAll(['batch', 'bind_success', 'state_change', 'escl_change', 'drive_mode']));
        expect(recent('hhmis', 'drive_mode').length, 2, reason: 'only on change');
        final state = recent('hhmis', 'state_change');
        expect((state.first['data'] as Map)['to'], 3);
        expect((state.last['data'] as Map)['from'], 3);
        expect((state.last['data'] as Map)['to'], 4);
        expect(recent('boot', 'mark').single['data'], containsPair('stage', 'hhmis_connected'));
        async.elapse(AidlVehicleNotifier.unknownKeysRollup);
        expect((recent('hhmis', 'unknown_keys').single['data'] as Map)['keys'], ['INT_NEW_FIRMWARE_THING']);
        n.onEvent({'_connected': false});
        expect((recent('hhmis', 'unbind').single['data'] as Map)['reason'], 'bridge');
        c.dispose();
        events.close();
      });
    });
  });

  group('safety', () {
    test('scenario B emits arm, five ticks, fire and lock_now_sent', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        c.listen(safetyWatchdogProvider, (_, _) {});
        c.read(ridingSettingsProvider.notifier).setAutoLockEnabled(true);
        final v = c.read(vehicleProvider.notifier);
        v.setConnected(true);
        v.setLocked(false);
        v.setVehicleState(VehicleState.ready);
        v.setSpeed(20);
        v.setSideStand(true);
        v.setSpeed(0);
        async.elapse(const Duration(seconds: 5));
        expect(names('safety'), [
          'watchdog_arm',
          'watchdog_tick',
          'watchdog_tick',
          'watchdog_tick',
          'watchdog_tick',
          'watchdog_tick',
          'watchdog_fire',
          'lock_now_sent',
        ]);
        expect(recent('safety', 'lock_now_sent').single['data'], {'cmd': 'INT_SIDE_STAND_STATUS', 'value': 1});
        // The modal doesn't dismiss on fire any more; it
        // transitions to Locking… and only dismisses when the vehicle
        // confirms or the rider chooses Keep riding.
        expect(names('modal'), ['show']);
        c.dispose();
      });
    });

    test('keep riding logs a user cancel', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        c.listen(safetyWatchdogProvider, (_, _) {});
        c.read(ridingSettingsProvider.notifier).setAutoLockEnabled(true);
        final v = c.read(vehicleProvider.notifier);
        v.setConnected(true);
        v.setLocked(false);
        v.setVehicleState(VehicleState.ready);
        v.setSpeed(20);
        v.setSideStand(true);
        v.setSpeed(0);
        async.elapse(const Duration(seconds: 2));
        c.read(safetyWatchdogProvider.notifier).cancel();
        expect((recent('safety', 'watchdog_cancel').single['data'] as Map)['reason'], 'user');
        expect(recent('safety', 'watchdog_fire'), isEmpty);
        c.dispose();
      });
    });
  });

  group('grpc', () {
    test('a stream that closes before any frame logs close_fallback', () {
      fakeAsync((async) {
        final primary = StreamController<List<int>>();
        final c = ProviderContainer(overrides: [
          batteryDiagnosticsProvider.overrideWith(() => GrpcDiagnosticsNotifier(source: () async => _Session(primary.stream))),
        ]);
        c.read(batteryDiagnosticsProvider);
        async.flushMicrotasks();
        primary.close();
        async.flushMicrotasks();
        expect(names('grpc'), ['connect', 'init_ok', 'close_fallback']);
        expect((recent('grpc', 'close_fallback').single['data'] as Map)['why'], 'stream closed');
        expect(AnalyticsLogger.instance.context['grpc_dump'], isTrue);
        c.dispose();
      });
    });

    test('a refused Init logs init_fail then lost with the backoff', () {
      fakeAsync((async) {
        final c = ProviderContainer(overrides: [
          batteryDiagnosticsProvider.overrideWith(() => GrpcDiagnosticsNotifier(source: () async => throw StateError('Init refused'))),
        ]);
        c.read(batteryDiagnosticsProvider);
        async.flushMicrotasks();
        expect(names('grpc'), ['connect', 'init_fail', 'lost']);
        expect((recent('grpc', 'lost').single['data'] as Map)['backoff_s'], GrpcDiagnosticsNotifier.retryMin.inSeconds);
        c.dispose();
      });
    });
  });

  group('platform', () {
    test('launchStockApp emits platform.call with method launchApp', () async {
      final platform = MockPlatformService()..setInstalled(stockDashboardPackage);
      final c = ProviderContainer(overrides: [platformServiceProvider.overrideWithValue(platform)]);
      addTearDown(c.dispose);
      await c.read(crashRecoveryProvider.notifier).launchStockApp();
      // Now followed by showReturnOverlay, so filter.
      final call = recent('platform', 'call')
          .map((e) => e['data'] as Map)
          .firstWhere((d) => d['method'] == 'launchApp');
      expect(call['success'], isTrue);
      expect(call['args_hash'], argsHash(stockDashboardPackage));
      expect(call.toString(), isNot(contains(stockDashboardPackage)), reason: 'arguments are hashed, not logged');
    });
  });

  group('state and modals', () {
    test('transitions log vehicle state, lock, drive mode, screen and boot_complete', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      installAnalyticsTransitions(c);
      c.read(screenStateProvider);
      final v = c.read(vehicleProvider.notifier);
      v.setConnected(true);
      v.setLocked(false);
      v.setVehicleState(VehicleState.ready);
      v.setDriveMode(DriveMode.sport);
      // Derived providers rebuild on the container's scheduler, not inline.
      await Future<void>.delayed(Duration.zero);
      expect((recent('state', 'vehicle_state').last['data'] as Map)['to'], 'ready');
      expect((recent('state', 'lock_change').single['data'] as Map), {'from': 4, 'to': 0});
      expect((recent('state', 'drive_mode').single['data'] as Map)['to'], 'sport');
      expect(names('ui'), contains('screen'));
      expect(recent('boot', 'mark').map((e) => (e['data'] as Map)['stage']), contains('boot_complete'));
    });

    test('passcode gate logs show, digit counts and the dismiss reason', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final gate = c.read(passcodeGateProvider.notifier);
      gate.request(purpose: 'Enter passcode for service mode', onSuccess: () {});
      gate.enterDigit(1);
      gate.enterDigit(2);
      gate.cancel();
      expect((recent('modal', 'show').single['data'] as Map)['name'], 'lock_passcode_gate');
      final taps = recent('ui', 'tap');
      expect(taps.map((t) => (t['data'] as Map)['count']), [1, 2]);
      expect(taps.first.toString(), isNot(contains('"digit"')));
      expect((recent('modal', 'dismiss').single['data'] as Map)['reason'], 'user');
    });

    test('error reports are mirrored', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(appErrorProvider.notifier).report(StateError('Dev panel test error'));
      expect((recent('error', 'shown').single['data'] as Map)['error'], 'Dev panel test error');
    });
  });

  group('settings', () {
    test('toggling a riding feature emits one settings.change with from and to', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final riding = c.read(ridingSettingsProvider.notifier);
      final before = c.read(ridingSettingsProvider).isOn(RidingFeature.adaptivePowerBoost);
      riding.setFeature(RidingFeature.adaptivePowerBoost, !before);
      final change = recent('settings', 'change').single['data'] as Map;
      expect(change, {'key': 'riding.adaptivePowerBoost', 'from': before, 'to': !before});
    });

    test('brightness, units and speed limit changes are recorded; no-ops are not', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(brightnessProvider.notifier).set(80);
      expect(recent('settings'), isEmpty, reason: '80 is already the value');
      c.read(brightnessProvider.notifier).set(40);
      c.read(ridingSettingsProvider.notifier).setSpeedLimit(60);
      expect(recent('settings').map((e) => (e['data'] as Map)['key']), ['brightness', 'riding.speedLimit']);
    });

    test('the analytics switch straddles the flip with log events and persists the setting', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final a = c.read(analyticsEnabledProvider.notifier);
      expect(c.read(analyticsEnabledProvider), isTrue, reason: 'on by default');
      a.set(false);
      expect(AnalyticsLogger.instance.enabled, isFalse);
      expect(names('log'), ['disabled']);
      expect(recent('settings', 'change').single['data'], {'key': 'analytics', 'from': true, 'to': false});
      a.set(true);
      expect(AnalyticsLogger.instance.enabled, isTrue);
      expect(names('log'), ['disabled', 'enabled']);
      expect(recent('settings', 'change').length, 2);
    });
  });

  group('bookmark', () {
    test('three taps within 500 ms emit user.bookmark with incrementing seq; two do not', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final b = c.read(bookmarkProvider.notifier);
      final t0 = DateTime(2026, 11, 9, 10, 0, 0);
      b.tap(t0);
      b.tap(t0.add(const Duration(milliseconds: 200)));
      expect(recent('user', 'bookmark'), isEmpty);
      b.tap(t0.add(const Duration(seconds: 2)));
      b.tap(t0.add(const Duration(seconds: 2, milliseconds: 100)));
      expect(recent('user', 'bookmark'), isEmpty, reason: 'the stale tap does not count');
      b.tap(t0.add(const Duration(seconds: 2, milliseconds: 200)));
      expect((recent('user', 'bookmark').single['data'] as Map)['seq'], 1);
      b.add();
      expect((recent('user', 'bookmark').last['data'] as Map)['seq'], 2);
      expect(c.read(bookmarkProvider), 2);
    });
  });
}
