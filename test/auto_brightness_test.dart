import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/trusted_clock.dart';
import 'package:opendash/state/auto_brightness.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/sun_times.dart';
import 'package:opendash/state/toast_state.dart';

final _sun = SunTimes.parse('2026-11-14 06:20:00', '2026-11-14 18:00:00');
DateTime _at(int h, [int m = 0]) => DateTime(2026, 11, 14, h, m);

void main() {
  late ProviderContainer c;
  int brightness() => c.read(brightnessProvider);
  AutoBrightness auto() => c.read(autoBrightnessProvider.notifier);

  /// A scooter with no working light sensor, unlocked, auto brightness on.
  void start({DateTime? now}) {
    AutoBrightness.clock = () => now ?? _at(12);
    c.dispose();
    c = ProviderContainer();
    c.listen(toastProvider, (_, _) {});
    c.read(autoBrightnessProvider);
    final v = c.read(vehicleProvider.notifier);
    v.setAmbientUsable(false);
    v.setLocked(false);
    c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoBrightness, true);
  }

  setUp(() {
    AnalyticsLogger.instance.resetForTest();
    c = ProviderContainer();
  });
  tearDown(() {
    c.dispose();
    AutoBrightness.clock = () => DateTime(2026, 1, 1, 12);
    TrustedClock.resetForTest();
  });

  group('time of day', () {
    test('day level by day, night level from sunset, eased around sunrise and over the hour before sunset', () {
      int level(DateTime t) => AutoBrightness.timeLevel(t, _sun, day: 60, night: 30);
      expect(level(_at(12)), 60);
      expect(level(_at(23, 42)), 30);
      expect(level(_at(3)), 30);
      expect(level(_at(5, 50)), 30, reason: 'half an hour before sunrise');
      expect(level(_at(6, 50)), inInclusiveRange(45, 50), reason: 'day, with the sun still low');
      expect(level(_at(9)), inInclusiveRange(53, 57));
      expect(level(_at(17, 0)), inInclusiveRange(45, 50), reason: 'an hour before sunset');
      expect(level(_at(18, 0)), 30, reason: 'at sunset it is already the night level');
      final morning = [for (var h = 5; h <= 12; h++) level(_at(h))];
      expect([...morning]..sort(), morning, reason: 'never dimmer as the sun climbs');
      expect(level(_at(18, 6)), 30, reason: '42 here was too bright');
      final dusk = [for (var m = -2; m <= 64; m += 6) level(_at(17, 2).add(Duration(minutes: m)))];
      expect([...dusk]..sort((a, b) => b.compareTo(a)), dusk, reason: 'never brighter as it gets darker');
    });

    test('without the vehicle\'s sunrise and sunset it is 06:00 and 18:00', () {
      const none = SunTimes();
      expect(AutoBrightness.dayWeight(_at(6), none), 0.5);
      expect(AutoBrightness.dayWeight(_at(17, 30), none), 0.5);
      expect(AutoBrightness.dayWeight(_at(18), none), 0);
      expect(AutoBrightness.dayWeight(_at(12), none), 1);
    });

    test('builds up to the day level at midday, low at night, out of the box', () {
      start(now: _at(12));
      expect(brightness(), 90);
      start(now: _at(11, 30));
      expect(brightness(), greaterThan(85), reason: 'at 11:30, 60 was dim in sunlight');
      start(now: _at(8));
      expect(brightness(), inInclusiveRange(65, 80), reason: 'a low sun does not need the midday level');
      start(now: _at(16));
      expect(brightness(), inInclusiveRange(65, 80));
      start(now: _at(23));
      expect(brightness(), 30);
    });

    test('a clock that cannot be right changes nothing', () {
      AutoBrightness.clock = () => _at(23);
      c.read(autoBrightnessProvider);
      c.read(vehicleProvider.notifier).setAmbientUsable(false);
      c.read(brightnessProvider.notifier).set(80);
      TrustedClock.debugSetLastGood(DateTime(2026, 11, 14, 14));
      TrustedClock.wall = () => DateTime(2024, 9, 3, 19, 17);
      c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoBrightness, true);
      expect(brightness(), 80, reason: 'held until the real time arrives');
      TrustedClock.wall = DateTime.now;
      auto().apply();
      expect(brightness(), 30);
    });
  });

  group('the slider teaches the level for that part of the day', () {
    test('by day it sets the day level, at night the night level', () {
      start(now: _at(12));
      c.read(brightnessProvider.notifier).set(75);
      auto().learn(75);
      expect((c.read(autoBrightnessProvider).day, c.read(autoBrightnessProvider).night), (75, 30));
      expect(brightness(), 75);

      AutoBrightness.clock = () => _at(22);
      auto().apply();
      expect(brightness(), 30, reason: 'night keeps its own level');
      c.read(brightnessProvider.notifier).set(20);
      auto().learn(20);
      expect((c.read(autoBrightnessProvider).day, c.read(autoBrightnessProvider).night), (75, 20));

      AutoBrightness.clock = () => _at(12);
      auto().apply();
      expect(brightness(), 75);
    });

    test('a level set in the morning stays put, and midday is worked back from it', () {
      start(now: _at(8));
      c.read(brightnessProvider.notifier).set(50);
      auto().learn(50);
      expect(brightness(), 50, reason: 'the slider does not spring back');
      expect(c.read(autoBrightnessProvider).day, inInclusiveRange(55, 62));
      c.read(brightnessProvider.notifier).set(100);
      auto().learn(100);
      expect(brightness(), 100, reason: 'more than a midday of 100 allows at this hour: held until lock');
      expect(c.read(autoBrightnessProvider).day, 100);
    });

    test('nothing is learned with auto off, or on a scooter with a working sensor', () {
      start();
      c.read(vehicleProvider.notifier).setAmbientUsable(true);
      auto().learn(90);
      expect(c.read(autoBrightnessProvider).day, AutoBrightness.defaultDay);
      c.read(vehicleProvider.notifier).setAmbientUsable(false);
      c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoBrightness, false);
      auto().learn(90);
      expect(c.read(autoBrightnessProvider).day, AutoBrightness.defaultDay);
    });
  });

  // At unlock the vehicle replayed the profile's 60 over the
  // night level and the screen sat at 60 for 45 s, until the minute tick.
  group('the level the vehicle replays at unlock', () {
    test('does not stand while auto brightness is on', () {
      start(now: _at(0, 34));
      expect(brightness(), 30);
      c.read(brightnessProvider.notifier).mirror(60);
      expect(brightness(), 30, reason: 'taken back at once, not at the next minute');
    });

    test('does not replace a boost either', () {
      start(now: _at(12));
      auto().learn(60);
      c.read(brightnessProvider.notifier).cyclePreset();
      expect(brightness(), 100);
      c.read(brightnessProvider.notifier).mirror(60);
      expect(brightness(), 100);
    });

    test('stands with auto off', () {
      start(now: _at(0, 34));
      c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoBrightness, false);
      c.read(brightnessProvider.notifier).mirror(60);
      expect(brightness(), 60);
    });
  });

  group('the control panel button is a boost', () {
    test('one tap to high, held until lock, then the usual level again', () {
      start(now: _at(12));
      auto().learn(60);
      c.read(brightnessProvider.notifier).cyclePreset();
      expect(brightness(), 100);
      expect(c.read(toastProvider)!.message, 'Brightness: High until you lock');
      expect(c.read(ridingSettingsProvider).isOn(RidingFeature.autoBrightness), isTrue);
      expect(c.read(autoBrightnessProvider).day, 60, reason: 'the usual level is not overwritten');
      auto().apply();
      expect(brightness(), 100, reason: 'auto leaves a boost alone');
      c.read(vehicleProvider.notifier).setLocked(true);
      expect(brightness(), 60);
      expect(c.read(autoBrightnessProvider).boost, isNull);
    });

    test('three presets, then the fourth tap is back to auto', () {
      start(now: _at(12));
      auto().learn(60);
      final seen = <int>[];
      for (var i = 0; i < 3; i++) {
        c.read(brightnessProvider.notifier).cyclePreset();
        seen.add(brightness());
      }
      expect(seen, [100, 30, 60]);
      c.read(brightnessProvider.notifier).cyclePreset();
      expect(c.read(toastProvider)!.message, 'Brightness: Auto');
      expect(c.read(autoBrightnessProvider).boost, isNull);
      expect(brightness(), 60);
    });

    test('with auto off the button is the plain preset cycle', () {
      start();
      auto().learn(60);
      c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoBrightness, false);
      c.read(brightnessProvider.notifier).cyclePreset();
      expect(c.read(toastProvider)!.message, 'Brightness: High');
      expect(c.read(autoBrightnessProvider).boost, isNull);
    });
  });
}
