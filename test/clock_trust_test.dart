import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show TimeOfDay;
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/screens/charging/charging_screen.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/trusted_clock.dart';
import 'package:opendash/state/greeting_state.dart';
import 'package:opendash/state/passcode_gate.dart';
import 'package:opendash/state/passcode_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/theme_state.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:opendash/theme/dash_theme.dart';
import 'helpers/stock.dart';

/// What the head unit's clock read after a cold boot (its firmware build
/// date, 3 Sep 2024), and the real time 47 s later.
final _bootClock = DateTime.utc(2024, 9, 3, 13, 47, 33).toLocal();
final _realClock = DateTime.utc(2026, 11, 14, 9, 14, 57).toLocal();
final _lastGood = DateTime.utc(2026, 11, 14, 9, 6).toLocal();

/// That firmware's `ro.build.date.utc`: the session began 5 s after it.
final _firmwareBuild = DateTime.utc(2024, 9, 3, 13, 47, 28);

List<Map<Object?, Object?>> _logged(String cat, String evt) =>
    [for (final e in AnalyticsLogger.instance.recent(cat, evt)) e['data']! as Map];

class _Bridge {
  _Bridge() {
    container = ProviderContainer(overrides: [
      vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), 
            events: events.stream,
            invoke: (method, args) async {
              if (args is Map && args['cmd'] == HhmisCmd.triggerSmartLight) calls.add('night=${args['value']}');
              return true;
            },
          )),
    ]);
    container.listen(toastProvider, (_, _) {});
  }

  final events = StreamController<dynamic>();
  final calls = <String>[];
  late final ProviderContainer container;
  AidlVehicleNotifier get vehicle => container.read(vehicleProvider.notifier) as AidlVehicleNotifier;

  void ambient(int value) => vehicle.applySensorUpdate(
        ambientBrightness: value,
        serviceIndicator: null,
        regenPowerLimitW: null,
        dischargePowerLimitW: null,
        rangeEcoCan: null,
        regenAvailability: null,
        towTheftState: null,
        busVoltage: null,
        packVoltage: null,
        packCurrent: null,
        trunkClosed: null,
        vehicleLockStateBcm: null,
      );

  void dispose() {
    container.dispose();
    events.close();
  }
}

void main() {
  setUp(() {
    AnalyticsLogger.instance.resetForTest();
    TrustedClock.resetForTest();
    TrustedClock.configure(firmwareBuildMs: _firmwareBuild.millisecondsSinceEpoch, elapsedRealtimeMs: 25000);
  });
  tearDown(() {
    TrustedClock.resetForTest();
    AidlVehicleNotifier.clock = DateTime.now;
    AutoThemeScheduler.clock = () => DateTime(2026, 1, 1, 12);
    AnalyticsLogger.instance.resetForTest();
  });

  group('TrustedClock', () {
    test('a clock still counting up from the firmware build date is not believed', () {
      TrustedClock.wall = () => _bootClock;
      expect(TrustedClock.trusted, isFalse);
      expect(TrustedClock.now(), _bootClock, reason: 'nothing better to offer yet');
      TrustedClock.wall = () => _realClock;
      expect(TrustedClock.trusted, isTrue);
      expect(TrustedClock.now(), _realClock);
    });

    test('the rule holds no date: another firmware has another default', () {
      for (final firmware in [DateTime.utc(2023, 2, 1), DateTime.utc(2027, 6, 15, 8), DateTime.utc(2031)]) {
        TrustedClock.resetForTest();
        TrustedClock.configure(firmwareBuildMs: firmware.millisecondsSinceEpoch, elapsedRealtimeMs: 40000);
        TrustedClock.wall = () => firmware.add(const Duration(seconds: 35));
        expect(TrustedClock.trusted, isFalse, reason: 'default of $firmware');
        TrustedClock.wall = () => firmware.add(const Duration(hours: 6));
        expect(TrustedClock.trusted, isFalse, reason: 'left on for hours, still never set');
        TrustedClock.wall = () => firmware.add(const Duration(days: 90));
        expect(TrustedClock.trusted, isTrue, reason: 'set: months past the build, up for seconds');
      }
    });

    test('with no firmware date (web, tests) only the last good reading is checked', () {
      TrustedClock.resetForTest();
      TrustedClock.wall = () => _bootClock;
      expect(TrustedClock.trusted, isTrue);
      TrustedClock.debugSetLastGood(_lastGood);
      expect(TrustedClock.trusted, isFalse);
    });

    test('unknown time is estimated from the last good reading, never from 2024', () {
      TrustedClock.debugSetLastGood(_lastGood);
      TrustedClock.wall = () => _bootClock;
      final estimate = TrustedClock.now();
      expect(estimate.isBefore(_lastGood), isFalse);
      expect(estimate.difference(_lastGood), lessThan(const Duration(seconds: 5)));
    });

    test('a step back of more than a day against the last good reading is a reset', () {
      TrustedClock.resetForTest();
      TrustedClock.debugSetLastGood(DateTime.utc(2026, 12, 1));
      TrustedClock.wall = () => DateTime.utc(2026, 11, 20);
      expect(TrustedClock.trusted, isFalse);
      TrustedClock.wall = () => DateTime.utc(2026, 11, 30, 12);
      expect(TrustedClock.trusted, isTrue, reason: 'a correction, not a reset');
    });

    test('logs the boot state, the jump and the moment it became trusted', () {
      TrustedClock.debugSetLastGood(_lastGood);
      TrustedClock.wall = () => _bootClock;
      expect(TrustedClock.tick(() => {'wifi': false}), isFalse);
      final boot = _logged('time', 'boot').single;
      expect(boot['trusted'], isFalse);
      expect(boot['wall'], startsWith('2024-09-03T13:47:33'));
      expect(boot['estimate'], startsWith('2026-11-14T09:06'));
      expect(boot['wifi'], isFalse);
      expect(boot.containsKey('tz_offset_min'), isTrue);
      expect(boot['firmware_build'], startsWith('2024-09-03T13:47:28'));
      expect(boot['since_firmware_s'], 5);

      TrustedClock.wall = () => _realClock;
      expect(TrustedClock.tick(() => {'wifi': true}), isTrue);
      final jump = _logged('time', 'jump').single;
      expect(jump['from'], startsWith('2024-09-03'));
      expect(jump['step_s'], closeTo(_realClock.difference(_bootClock).inSeconds, 2));
      final trusted = _logged('time', 'trusted').single;
      expect(trusted['on'], isTrue);
      expect(trusted['wifi'], isTrue);
      expect(trusted['estimate_error_s'], closeTo(_realClock.difference(_lastGood).inSeconds, 2),
          reason: 'how long the scooter was off');

      TrustedClock.tick();
      expect(_logged('time', 'jump'), hasLength(1), reason: 'a steady clock logs nothing');
    });

    test('log lines carry the estimate and say so', () {
      TrustedClock.debugSetLastGood(_lastGood);
      TrustedClock.wall = () => _bootClock;
      logEvent('test', 'line');
      final line = AnalyticsLogger.instance.recent('test', 'line').single;
      expect(line['ts'], startsWith('2026-11-14T09:06'));
      expect(line['clk'], 'est');
      TrustedClock.wall = () => _realClock;
      logEvent('test', 'line2');
      expect(AnalyticsLogger.instance.recent('test', 'line2').single.containsKey('clk'), isFalse);
    });
  });

  group('while the clock is unknown', () {
    test('the clock reads --:-- and comes back when the time arrives', () {
      fakeAsync((async) {
        TrustedClock.wall = () => _bootClock;
        final c = ProviderContainer();
        c.listen(vehicleProvider, (_, _) {});
        async.elapse(const Duration(seconds: 1));
        expect(c.read(vehicleProvider).time, VehicleNotifier.unknownClock);
        TrustedClock.wall = DateTime.now;
        async.elapse(const Duration(seconds: 1));
        expect(c.read(vehicleProvider).time, isNot(VehicleNotifier.unknownClock));
        c.dispose();
      });
    });

    test('the time-based theme holds, then follows the real time at once', () {
      fakeAsync((async) {
        TrustedClock.wall = () => _bootClock;
        AutoThemeScheduler.clock = () => _bootClock;
        final c = ProviderContainer();
        for (final p in [vehicleProvider, autoThemeProvider, toastProvider]) {
          c.listen(p, (_, _) {});
        }
        c.read(autoDarkModeProvider.notifier).setMode(AutoThemeMode.timeBased);
        c.read(themeProvider.notifier).setTheme(DashTheme.light);
        async.elapse(const Duration(seconds: 3));
        expect(c.read(themeProvider), DashTheme.light, reason: '19:17 on a 2024 date decides nothing');

        // The real time is the afternoon: still light. Then a real evening.
        TrustedClock.wall = DateTime.now;
        AutoThemeScheduler.clock = () => DateTime(2026, 11, 14, 14, 45);
        async.elapse(const Duration(seconds: 1));
        expect(c.read(themeProvider), DashTheme.light);
        AutoThemeScheduler.clock = () => DateTime(2026, 11, 14, 23);
        c.read(autoThemeProvider.notifier).evaluate(const TimeOfDay(hour: 23, minute: 0));
        expect(c.read(themeProvider).isLight, isFalse);
        c.dispose();
      });
    });

    test('smart headlight goes by the stand-in time, and by the clock again the moment it arrives', () {
      fakeAsync((async) {
        // Last good reading 14:36 IST: the stand-in says day, where the
        // 2024 clock said 19:17 and lit the headlight.
        TrustedClock.debugSetLastGood(_lastGood);
        TrustedClock.wall = () => _bootClock;
        AidlVehicleNotifier.clock = () => _bootClock;
        final b = _Bridge();
        b.vehicle.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, 'INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT': 1});
        async.flushMicrotasks();
        expect(b.calls, ['night=false']);
        final first = _logged('hhmis', 'smart_light_trigger').single;
        expect((first['basis'], first['night']), ('estimate', false));

        // "ambient" is not a light sensor on this hardware; it decides nothing.
        b.ambient(10);
        async.elapse(AidlVehicleNotifier.smartLightEvery);
        expect(b.calls.toSet(), {'night=false'});

        TrustedClock.wall = DateTime.now;
        AidlVehicleNotifier.clock = () => DateTime(2026, 11, 14, 23, 42);
        async.elapse(const Duration(seconds: 1));
        final last = _logged('hhmis', 'smart_light_trigger').last;
        expect((last['reason'], last['basis'], last['night']), ('clock', 'clock', true));
        expect(b.calls.last, 'night=true');
        b.dispose();
      });
    });

    test('smart headlight with no stand-in at all counts as night', () {
      fakeAsync((async) {
        TrustedClock.wall = () => _bootClock;
        AidlVehicleNotifier.clock = () => DateTime(2024, 9, 3, 12);
        final b = _Bridge();
        b.vehicle.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, 'INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT': 1});
        async.flushMicrotasks();
        expect(b.calls, ['night=true']);
        expect(_logged('hhmis', 'smart_light_trigger').single['basis'], 'failsafe');
        b.dispose();
      });
    });

    test('no finish time and no time-of-day greeting', () {
      TrustedClock.wall = () => _bootClock;
      expect(chargeEta(90, _bootClock, use24Hour: true), '—');
      final c = ProviderContainer();
      c.listen(greetingProvider, (_, _) {});
      fakeAsync((async) {
        c.read(greetingProvider.notifier).show();
        expect(c.read(greetingProvider), startsWith('Hello'));
        async.elapse(const Duration(seconds: 10));
      });
      TrustedClock.wall = DateTime.now;
      expect(chargeEta(90, DateTime(2026, 11, 14, 18), use24Hour: true), '19:30');
      c.dispose();
    });
  });

  group('passcode lockout', () {
    test('the countdown never exceeds one lockout, whatever the clock does', () {
      final now = _bootClock;
      final farEnd = _realClock.add(PasscodeNotifier.lockoutDuration);
      expect(PasscodeState(lockoutEndTime: farEnd).lockoutRemaining(now), PasscodeNotifier.lockoutDuration);
      expect(PasscodeGateState(lockoutEndTime: farEnd).lockoutRemaining(now), PasscodeGate.lockoutDuration);
      final soon = now.add(const Duration(seconds: 10));
      expect(PasscodeState(lockoutEndTime: soon).lockoutRemaining(now), const Duration(seconds: 10));
      expect(PasscodeState(lockoutEndTime: now.subtract(const Duration(days: 800))).lockoutRemaining(now), Duration.zero);
    });
  });

  group('charge complete', () {
    test('command 111 is no toast: the vehicle repeats it on every wake', () {
      fakeAsync((async) {
        final b = _Bridge();
        b.vehicle.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 6});
        for (var i = 0; i < 5; i++) {
          b.vehicle.onEvent({'INT_VEHICLE_COMMAND': 111});
        }
        async.flushMicrotasks();
        expect(b.container.read(toastProvider), isNull);
        expect(_logged('hhmis', 'vehicle_command').last, containsPair('known', true));
        b.dispose();
      });
    });
  });
}
