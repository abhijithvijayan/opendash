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
    test('day level all day, night level from sunset, eased around sunrise and over the hour before sunset', () {
      int level(DateTime t) => AutoBrightness.timeLevel(t, _sun, day: 60, night: 30);
      expect(level(_at(12)), 60);
      expect(level(_at(23, 42)), 30);
      expect(level(_at(3)), 30);
      expect(level(_at(5, 50)), 30, reason: 'half an hour before sunrise');
      expect(level(_at(6, 20)), 45, reason: 'half way at sunrise');
      expect(level(_at(6, 50)), 60, reason: 'the day level once the sunrise hour is over');
      expect(level(_at(9)), 60, reason: 'flat by day: no climb to a midday peak');
      expect(level(_at(17, 0)), 60, reason: 'an hour before sunset it starts to ease');
      expect(level(_at(17, 30)), 45);
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

    test('the day level by day and the night level at night, out of the box', () {
      for (final h in [8, 12, 16]) {
        start(now: _at(h));
        expect(brightness(), 90, reason: '$h:00');
      }
      start(now: _at(17, 30));
      expect(brightness(), 60, reason: 'easing down in the hour before sunset (18:00 without the vehicle\'s times)');
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

  group('the day and night levels are the rider\'s', () {
    test('the day level shows by day and the night level at night', () {
      start(now: _at(12));
      auto().setDay(75);
      expect((c.read(autoBrightnessProvider).day, c.read(autoBrightnessProvider).night), (75, 30));
      expect(brightness(), 75);

      AutoBrightness.clock = () => _at(22);
      auto().apply();
      expect(brightness(), 30, reason: 'night keeps its own level');
      auto().setDay(50);
      expect(brightness(), 30, reason: 'a new day level waits for the day');
      auto().setNight(20);
      expect(brightness(), 20);

      AutoBrightness.clock = () => _at(12);
      auto().apply();
      expect(brightness(), 50);
    });

    test('a day level set in the morning holds through the day: no drift towards noon', () {
      start(now: _at(8));
      auto().setDay(70);
      expect(brightness(), 70);
      for (final t in [_at(10), _at(12), _at(15), _at(17)]) {
        AutoBrightness.clock = () => t;
        auto().apply();
        expect(brightness(), 70, reason: 'set to 70, still 70 at ${t.hour}:${t.minute}');
      }
    });

    test('and still drops to the night level in the evening', () {
      start(now: _at(12));
      auto().setDay(80);
      AutoBrightness.clock = () => _at(17, 30);
      auto().apply();
      expect(brightness(), 55, reason: 'half way down in the hour before sunset');
      AutoBrightness.clock = () => _at(18, 30);
      auto().apply();
      expect(brightness(), 30);
    });

    test('the screen follows a drag in progress', () {
      start(now: _at(12));
      auto().setDay(65, commit: false);
      expect(brightness(), 65);
      expect(c.read(autoBrightnessProvider).day, 65);
    });

    test('changing a level in settings ends a boost, so the rider sees it', () {
      start(now: _at(12));
      c.read(brightnessProvider.notifier).cyclePreset();
      expect(brightness(), 100);
      auto().setDay(60);
      expect(c.read(autoBrightnessProvider).boost, isNull);
      expect(brightness(), 60);
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
      auto().setDay(60);
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
      auto().setDay(60);
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
      auto().setDay(60);
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
      auto().setDay(60);
      c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoBrightness, false);
      c.read(brightnessProvider.notifier).cyclePreset();
      expect(c.read(toastProvider)!.message, 'Brightness: High');
      expect(c.read(autoBrightnessProvider).boost, isNull);
    });
  });
}
