import 'package:material_ui/material_ui.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/theme_state.dart';
import 'package:opendash/theme/dash_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('AutoDarkMode modes', () {
    test('defaults to time-based and keeps the enabled shorthand', () {
      const d = AutoDarkMode();
      expect(d.mode, AutoThemeMode.timeBased);
      expect(d.enabled, isTrue);
      expect(d.copyWith(mode: AutoThemeMode.off).enabled, isFalse);
      expect(d.ambientLightThreshold, 40);
      expect(d.ambientDarkThreshold, 25);
      expect(const AutoDarkMode(mode: AutoThemeMode.ambientSensor).enabled, isTrue);
    });

    test('setEnabled maps onto time-based and off', () {
      final c = ProviderContainer();
      final n = c.read(autoDarkModeProvider.notifier);
      n.setEnabled(true);
      expect(c.read(autoDarkModeProvider).mode, AutoThemeMode.timeBased);
      n.setMode(AutoThemeMode.ambientSensor);
      expect(c.read(autoDarkModeProvider).mode, AutoThemeMode.ambientSensor);
      n.setEnabled(false);
      expect(c.read(autoDarkModeProvider).mode, AutoThemeMode.off);
      c.dispose();
    });

    test('JSON carries the mode and reads the legacy enabled flag', () {
      expect(const AutoDarkMode(mode: AutoThemeMode.ambientSensor).toJson()['mode'], 'ambientSensor');
      expect(AutoDarkMode.fromJsonObject({'enabled': true, 'darkAfter': '18:30', 'lightAfter': '06:30'}).mode, AutoThemeMode.timeBased);
      expect(AutoDarkMode.fromJsonObject({'mode': 'ambientSensor', 'darkAfter': '18:30', 'lightAfter': '06:30'}).mode, AutoThemeMode.ambientSensor);
      expect(AutoDarkMode.fromJsonObject({'mode': 'sideways', 'darkAfter': '18:30', 'lightAfter': '06:30'}).mode, AutoThemeMode.off);
    });
  });

  group('ambient sensor auto theme', () {
    late ProviderContainer c;
    late AutoThemeScheduler s;

    setUp(() {
      // Pin the clock so time-based evaluation is deterministic
      // (previously the test depended on wall-clock hour and flaked in the
      // small hours of the morning).
      AutoThemeScheduler.clock = () => DateTime(2026, 1, 1, 22, 0);
      c = ProviderContainer();
      c.read(themeProvider.notifier).setTheme(DashTheme.ember);
      c.read(autoDarkModeProvider.notifier).setMode(AutoThemeMode.ambientSensor);
      s = c.read(autoThemeProvider.notifier);
    });

    tearDown(() {
      c.dispose();
      AutoThemeScheduler.clock = DateTime.now;
    });

    test('crossing 40% switches to light, falling below 25% switches back', () {
      s.evaluateAmbient(24);
      s.evaluateAmbient(39);
      expect(c.read(themeProvider), DashTheme.ember, reason: 'inside the hysteresis band');
      s.evaluateAmbient(41);
      expect(c.read(themeProvider), DashTheme.light);
      s.evaluateAmbient(26);
      expect(c.read(themeProvider), DashTheme.light, reason: 'inside the hysteresis band');
      s.evaluateAmbient(24);
      expect(c.read(themeProvider), DashTheme.ember);
    });

    test('does not flap between 25 and 40', () {
      s.evaluateAmbient(24);
      for (final a in [30, 38, 26, 35, 39]) {
        s.evaluateAmbient(a);
        expect(c.read(themeProvider), DashTheme.ember);
      }
      s.evaluateAmbient(45);
      for (final a in [38, 27, 33, 26]) {
        s.evaluateAmbient(a);
        expect(c.read(themeProvider), DashTheme.light);
      }
    });

    test('follows the vehicle ambient sensor', () {
      final v = c.read(vehicleProvider.notifier);
      v.setAmbient(80);
      expect(c.read(themeProvider), DashTheme.light);
      v.setAmbient(10);
      expect(c.read(themeProvider), DashTheme.ember);
    });

    test('a sensor that only echoes the screen brightness: the schedule decides', () {
      final v = c.read(vehicleProvider.notifier);
      AutoThemeScheduler.clock = () => DateTime(2026, 1, 1, 12, 0);
      v.setAmbient(5);
      expect(c.read(themeProvider), DashTheme.ember, reason: 'a proven reading of 5 is dark');
      v.setAmbientUsable(false);
      expect(c.read(themeProvider), DashTheme.light, reason: 'noon is light hours, whatever the echo says');
      AutoThemeScheduler.clock = () => DateTime(2026, 1, 1, 22, 0);
      v.setAmbientUsable(true);
      v.setAmbient(90);
      expect(c.read(themeProvider), DashTheme.light);
      v.setAmbientUsable(false);
      expect(c.read(themeProvider), DashTheme.ember, reason: '22:00 is dark hours');
    });

    test('time-based mode ignores the sensor and the clock still works', () {
      c.read(autoDarkModeProvider.notifier).setMode(AutoThemeMode.timeBased);
      s.evaluateAmbient(90);
      expect(c.read(themeProvider), DashTheme.ember);
      s.evaluate(const TimeOfDay(hour: 12, minute: 0));
      expect(c.read(themeProvider), DashTheme.light);
      c.read(autoDarkModeProvider.notifier).setMode(AutoThemeMode.off);
      s.evaluateAmbient(5);
      expect(c.read(themeProvider), DashTheme.light, reason: 'off never switches');
    });
  });

  group('a theme picked by hand', () {
    late ProviderContainer c;
    AutoThemeScheduler s() => c.read(autoThemeProvider.notifier);
    TimeOfDay at(int h, [int m = 0]) => TimeOfDay(hour: h, minute: m);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await PrefsService.init();
      AutoThemeScheduler.clock = () => DateTime(2026, 1, 1, 22, 0);
      c = ProviderContainer();
      c.read(themeProvider.notifier).setTheme(DashTheme.ember);
      c.read(autoDarkModeProvider.notifier).setMode(AutoThemeMode.timeBased);
      s().evaluate(at(22));
    });

    tearDown(() {
      c.dispose();
      PrefsService.resetForTest();
      AutoThemeScheduler.clock = DateTime.now;
    });

    test('holds through the minutes that follow, until the schedule next switches', () {
      c.read(themeProvider.notifier).setTheme(DashTheme.light);
      for (final t in [at(22, 1), at(22, 2), at(23, 30), at(3)]) {
        s().evaluate(t);
        expect(c.read(themeProvider), DashTheme.light, reason: 'picked at night, still night at $t');
      }
      s().evaluate(at(7));
      expect(c.read(themeProvider), DashTheme.light, reason: 'morning: light by the schedule too');
      s().evaluate(at(22));
      expect(c.read(themeProvider), DashTheme.ember, reason: 'the next evening the schedule takes over again');
    });

    test('a dark theme picked by day holds until evening, then light the next morning', () {
      s().evaluate(at(12));
      expect(c.read(themeProvider), DashTheme.light);
      c.read(themeProvider.notifier).setTheme(DashTheme.dark);
      s().evaluate(at(12, 1));
      s().evaluate(at(17));
      expect(c.read(themeProvider), DashTheme.dark);
      s().evaluate(at(22));
      s().evaluate(at(7));
      expect(c.read(themeProvider), DashTheme.light);
    });

    test('holds across a restart in the same stretch of the schedule', () async {
      c.read(themeProvider.notifier).setTheme(DashTheme.light);
      c.dispose();
      c = ProviderContainer();
      c.read(autoThemeProvider);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(themeProvider), DashTheme.light, reason: 'still night: the pick stands');
      s().evaluate(at(22, 5));
      expect(c.read(themeProvider), DashTheme.light);
    });

    test('a sunrise or sunset that passed while off ends the pick', () async {
      c.read(themeProvider.notifier).setTheme(DashTheme.light);
      c.dispose();
      AutoThemeScheduler.clock = () => DateTime(2026, 1, 2, 22, 0);
      c = ProviderContainer();
      c.read(autoThemeProvider);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(themeProvider), DashTheme.ember, reason: 'off through the next morning: the schedule decides');
    });

    test('switch times between two moments', () {
      const mode = AutoDarkMode();
      final night = DateTime(2026, 1, 1, 22);
      expect(AutoThemeScheduler.switchedBetween(night, DateTime(2026, 1, 2, 3), mode), isFalse);
      expect(AutoThemeScheduler.switchedBetween(night, DateTime(2026, 1, 2, 9), mode), isTrue);
      expect(AutoThemeScheduler.switchedBetween(night, DateTime(2026, 1, 3, 22), mode), isTrue);
      expect(AutoThemeScheduler.switchedBetween(night, night, mode), isFalse);
    });

    test('changing the auto setting applies the schedule at once', () {
      c.read(themeProvider.notifier).setTheme(DashTheme.light);
      c.read(autoDarkModeProvider.notifier).setDarkAfter(const TimeOfDay(hour: 21, minute: 0));
      expect(c.read(themeProvider), DashTheme.ember);
    });
  });
}
