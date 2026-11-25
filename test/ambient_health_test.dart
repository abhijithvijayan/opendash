import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/ambient_health.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/trusted_clock.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/theme_state.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:opendash/theme/dash_theme.dart';
import 'package:opendash/state/auto_brightness.dart';
import 'helpers/stock.dart';

const _halfSecond = 500000;

/// Feeds [value] every 500 ms for [d], continuing from [from] micros.
int _feed(AmbientHealth h, int value, Duration d, int from) {
  var t = from;
  final end = from + d.inMicroseconds;
  while (t < end) {
    h.add(value, t);
    t += _halfSecond;
  }
  return t;
}

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
  VehicleData get state => container.read(vehicleProvider);

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

List<Map<Object?, Object?>> _logged(String cat, String evt) =>
    [for (final e in AnalyticsLogger.instance.recent(cat, evt)) e['data']! as Map];

void main() {
  setUp(() => AnalyticsLogger.instance.resetForTest());
  tearDown(() {
    AidlVehicleNotifier.debugAmbientHealth = null;
    AidlVehicleNotifier.clock = DateTime.now;
    TrustedClock.resetForTest();
  });

  group('AmbientHealth', () {
    test("a Gen 1 scooter on 4.6.14: 10 at boot, then 60 for ever, is never usable and ends up stuck", () {
      final h = AmbientHealth();
      var t = _feed(h, 10, const Duration(seconds: 5), 0);
      t = _feed(h, 60, const Duration(hours: 1), t);
      expect(h.verdict, AmbientVerdict.unknown);
      expect(h.levels, [60]);
      t = _feed(h, 60, const Duration(hours: 5, minutes: 2), t);
      expect(h.verdict, AmbientVerdict.stuck);
    });

    test('the boot value does not add up over many restarts', () {
      final h = AmbientHealth();
      var t = 0;
      for (var boot = 0; boot < 200; boot++) {
        t = _feed(h, 10, const Duration(seconds: 5), t);
        t = _feed(h, 60, const Duration(seconds: 100), t);
        t += const Duration(minutes: 10).inMicroseconds;
      }
      expect(h.levels, [60], reason: 'the first minute of each connection is left out');
      expect(h.verdict, isNot(AmbientVerdict.usable));
    });

    test('a value that sits at two clearly different levels is a light sensor', () {
      final h = AmbientHealth();
      var t = _feed(h, 85, AmbientHealth.settle + AmbientHealth.dwell + const Duration(seconds: 5), 0);
      expect(h.verdict, AmbientVerdict.unknown, reason: 'one level so far');
      t = _feed(h, 4, AmbientHealth.dwell + const Duration(seconds: 5), t);
      expect(h.verdict, AmbientVerdict.usable);
      expect(h.levels, [0, 85]);
    });

    test('wobble around one level is not movement', () {
      final h = AmbientHealth();
      var t = _feed(h, 58, AmbientHealth.settle + AmbientHealth.dwell * 2, 0);
      t = _feed(h, 62, AmbientHealth.dwell * 2, t);
      expect(h.levels, [55, 60]);
      expect(h.verdict, AmbientVerdict.unknown, reason: 'neighbouring steps');
    });

    test('a flicker shorter than the dwell does not count', () {
      final h = AmbientHealth();
      var t = _feed(h, 60, AmbientHealth.settle + AmbientHealth.dwell * 2, 0);
      t = _feed(h, 5, const Duration(seconds: 30), t);
      _feed(h, 60, AmbientHealth.dwell, t);
      expect(h.verdict, AmbientVerdict.unknown);
    });

    test('time with no readings is not counted, and a wake starts the settle again', () {
      final h = AmbientHealth();
      var t = _feed(h, 60, AmbientHealth.settle + const Duration(seconds: 10), 0);
      final before = h.observedMs;
      t += const Duration(hours: 3).inMicroseconds;
      t = _feed(h, 60, const Duration(seconds: 30), t);
      expect(h.observedMs, before, reason: 'the gap and the 30 s after it');
    });

    test('a sensor that stops moving is noticed once the old time has faded', () {
      final h = AmbientHealth.proven();
      expect(h.verdict, AmbientVerdict.usable);
      var t = 0;
      for (var day = 0; day < 20 && h.verdict == AmbientVerdict.usable; day++) {
        t = _feed(h, 60, const Duration(hours: 24), t);
      }
      expect(h.verdict, AmbientVerdict.stuck);
    });

    // Seen on a scooter: the value followed every brightness step a second or two
    // behind. With auto brightness at 60 by day and 30 at night that is two
    // levels, five minutes each: it must not pass for a sensor.
    test('a value that repeats the screen brightness is an echo, never usable', () {
      final h = AmbientHealth();
      var t = 0;
      void run(int brightness, Duration d, {int? lagFrom}) {
        final end = t + d.inMicroseconds;
        final lagEnd = t + const Duration(seconds: 2).inMicroseconds;
        while (t < end) {
          h.add(lagFrom != null && t < lagEnd ? lagFrom : brightness, t, brightness: brightness);
          t += _halfSecond;
        }
      }

      run(30, const Duration(hours: 2));
      for (var day = 0; day < 5; day++) {
        run(60, const Duration(hours: 3), lagFrom: 30);
        run(100, const Duration(minutes: 20), lagFrom: 60);
        run(30, const Duration(hours: 3), lagFrom: 100);
      }
      expect(h.levels, isEmpty, reason: 'nothing credited to a level');
      expect(h.verdict, AmbientVerdict.echo);
      expect(h.echoMs, greaterThan(const Duration(hours: 20).inMilliseconds));
    });

    // On a real scooter the ambient-theme + auto-brightness
    // feedback loop drove brightness up and down faster than the echo settled,
    // so the echoed value sat a few seconds behind each change (longer than the
    // old 5 s guard). The detector counted those lagging reads as two levels
    // and wrongly said "usable", which kept the loop alive. A value that only
    // moves when the brightness moves must never be called a sensor.
    test('a brightness loop with a long lag is still an echo, not usable', () {
      final h = AmbientHealth();
      var t = 0;
      void block(int brightness, int prevBrightness) {
        final end = t + const Duration(seconds: 20).inMicroseconds;
        final lagEnd = t + const Duration(seconds: 8).inMicroseconds; // echo trails 8 s
        while (t < end) {
          h.add(t < lagEnd ? prevBrightness : brightness, t, brightness: brightness);
          t += _halfSecond;
        }
      }

      var prev = 20;
      for (var i = 0; i < 1200; i++) {
        final b = i.isEven ? 20 : 60; // brightness flips every 20 s, ~6.6 h total
        block(b, prev);
        prev = b;
      }
      expect(h.verdict, isNot(AmbientVerdict.usable), reason: 'lagging echo is not independent movement');
    });

    test('a real sensor is still usable with the brightness known', () {
      final h = AmbientHealth();
      var t = 0;
      for (final (light, brightness) in [(85, 60), (4, 30)]) {
        final end = t + (AmbientHealth.settle + AmbientHealth.dwell + const Duration(seconds: 10)).inMicroseconds;
        while (t < end) {
          h.add(light, t, brightness: brightness);
          t += _halfSecond;
        }
      }
      expect(h.verdict, AmbientVerdict.usable);
    });

    test('survives a save and a load; rubbish starts from nothing', () {
      final h = AmbientHealth.proven([10, 90]);
      final again = AmbientHealth.fromJson(h.toJson());
      expect(again.verdict, AmbientVerdict.usable);
      expect(again.levels, [10, 90]);
      for (final raw in ['', 'x', '[1,2]', '{"a":1}', '{"ms":[${List.filled(21, -1).join(',')}]}', '[${List.filled(21, 400000).join(',')}]']) {
        expect(AmbientHealth.fromJson(raw).observedMs, 0, reason: raw);
      }
    });
  });

  group('on the bridge', () {
    test('an unproven sensor gives no reading: brightness goes by the time of day, health logged', () {
      final b = _Bridge();
      b.container.read(autoBrightnessProvider);
      b.container.read(brightnessProvider.notifier).set(80);
      b.container.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoBrightness, true);
      expect(b.container.read(brightnessProvider), AutoBrightness.defaultDay, reason: 'noon: the day level');
      b.ambient(0);
      expect(b.state.ambientKnown, isTrue);
      expect(b.state.ambientUsable, isFalse);
      expect(b.state.ambientReading, isNull);
      expect(b.container.read(brightnessProvider), AutoBrightness.defaultDay,
          reason: 'not dimmed by a value that may be a constant');
      final health = _logged('sensor', 'ambient_health').single;
      expect((health['verdict'], health['value']), ('unknown', 0));
      b.dispose();
    });

    test('a proven sensor is used', () {
      AidlVehicleNotifier.debugAmbientHealth = AmbientHealth.proven;
      final b = _Bridge();
      b.container.read(autoBrightnessProvider);
      b.container.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoBrightness, true);
      b.ambient(0);
      expect(b.state.ambientReading, 0);
      expect(b.container.read(brightnessProvider), 30, reason: 'the sensor, not the clock');
      b.dispose();
    });

    test('unknown clock: a proven sensor decides day or night, before the stand-in time', () {
      fakeAsync((async) {
        AidlVehicleNotifier.debugAmbientHealth = AmbientHealth.proven;
        TrustedClock.resetForTest();
        TrustedClock.configure(
            firmwareBuildMs: DateTime.utc(2024, 9, 3, 13, 47, 28).millisecondsSinceEpoch, elapsedRealtimeMs: 25000);
        TrustedClock.debugSetLastGood(DateTime(2026, 11, 14, 14, 36));
        TrustedClock.wall = () => DateTime.utc(2024, 9, 3, 13, 47, 33);
        final b = _Bridge();
        b.ambient(8);
        b.vehicle.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, 'INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT': 1});
        async.flushMicrotasks();
        expect(b.calls, ['night=true'], reason: 'dark by the sensor, though the stand-in time says afternoon');
        final e = _logged('hhmis', 'smart_light_trigger').single;
        expect((e['basis'], e['ambient']), ('ambient', 8));
        b.dispose();
      });
    });
  });

  group('settings and defaults', () {
    testWidgets('the sensor mode stays the rider\'s choice, with a note while the sensor is unproven', (tester) async {
      await tester.pumpWidget(const ProviderScope(child: OpenDashApp()));
      await tester.pump();
      final container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 500));
      final v = container.read(vehicleProvider.notifier);
      v.setLocked(false);
      await tester.pump(const Duration(seconds: 5));
      container.read(settingsScreenOpenProvider.notifier).open();
      await tester.pump(const Duration(milliseconds: 500));
      Finder note() => find.byKey(const ValueKey('auto-theme-sensor-note'));
      expect(note(), findsNothing, reason: 'time-based by default');

      v.setAmbientUsable(false);
      container.read(autoDarkModeProvider.notifier).setMode(AutoThemeMode.ambientSensor);
      await tester.pump(const Duration(milliseconds: 500));
      expect(note(), findsOneWidget);
      expect(container.read(autoDarkModeProvider).mode, AutoThemeMode.ambientSensor, reason: 'not switched behind their back');

      v.setAmbientUsable(true);
      await tester.pump(const Duration(milliseconds: 500));
      expect(note(), findsNothing);
      await tester.pump(const Duration(seconds: 4));
    });

    test('defaults: Light, time-based switching, speed limit on at 80', () {
      final c = ProviderContainer();
      expect(c.read(themeProvider), DashTheme.light);
      expect(c.read(autoDarkModeProvider).mode, AutoThemeMode.timeBased);
      final riding = c.read(ridingSettingsProvider);
      expect((riding.speedLimitEnabled, riding.speedLimit), (true, 80));
      c.dispose();
    });

    test('a start after dark goes to the dark theme at once, not at the next minute', () async {
      AutoThemeScheduler.clock = () => DateTime(2026, 11, 14, 23, 42);
      addTearDown(() => AutoThemeScheduler.clock = () => DateTime(2026, 1, 1, 12));
      final c = ProviderContainer();
      c.listen(autoThemeProvider, (_, _) {});
      c.listen(toastProvider, (_, _) {});
      expect(c.read(themeProvider), DashTheme.light);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(themeProvider), DashTheme.dark);
      c.dispose();
    });
  });
}
