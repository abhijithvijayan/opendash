import 'dart:convert';

import 'package:material_ui/material_ui.dart' show Color, TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:opendash/state/format_settings.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/sound_settings.dart';
import 'package:opendash/state/theme_state.dart';
import 'package:opendash/theme/dash_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> boot(Map<String, Object> stored) async {
  SharedPreferences.setMockInitialValues(stored);
  await PrefsService.init();
}

Future<SharedPreferences> stored() => SharedPreferences.getInstance();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(PrefsService.resetForTest);

  test('a side-stand bypass the rider did not choose (an old vehicle mirror) is undone at start', () async {
    await boot({'riding_sideStandCutOff': false});
    expect(RidingSettings.fromPrefs().isOn(RidingFeature.sideStandCutOff), isTrue);
    PrefsService.resetForTest();
    await boot({'riding_sideStandCutOff': false, 'standBypassConfirmed': true});
    expect(RidingSettings.fromPrefs().isOn(RidingFeature.sideStandCutOff), isFalse, reason: 'the rider bypassed it with the passcode');
  });

  test('settings restore from prefs on a fresh container', () async {
    await boot({
      'riding_hillHold': true,
      'riding_apb': false,
      'riding': jsonEncode({'regenLevel': 3, 'autoTurnOffMinutes': 30, 'speedLimitEnabled': true, 'speedLimit': 60}),
      'brightness': 45,
      'theme': 'Ember',
      'customAccent': jsonEncode({'SPORT': 0xFFFF0000}),
      'use24h': true,
      'useMiles': true,
      'useFahrenheit': true,
      'lockDate': 'monthDay',
      'autoDark': jsonEncode({'enabled': true, 'darkAfter': '19:15', 'lightAfter': '05:45'}),
      'volume': 23,
      'fence': jsonEncode({
        'timeEnabled': true,
        'geoEnabled': true,
        'geoRadiusKm': 3.5,
        'modeRestrictEnabled': true,
        'allowedModes': ['eco', 'sport'],
        'week': {'1': {'enabled': false, 'from': '07:00', 'to': '21:00'}},
      }),
      'sound': jsonEncode({'preset': 'eclipse', 'chimeVolume': 15, 'motorVolume': 80}),
    });
    final c = ProviderContainer();
    final riding = c.read(ridingSettingsProvider);
    expect(riding.isOn(RidingFeature.hillHold), isTrue);
    expect(riding.isOn(RidingFeature.adaptivePowerBoost), isFalse, reason: 'read from the pre-rename riding_apb key');
    expect(riding.isOn(RidingFeature.tamper), isTrue, reason: 'unsaved features keep their default');
    expect(riding.regenMode, RegenMode.off, reason: 'a legacy regenLevel is the same wire value');
    expect(riding.speedLimitEnabled, isTrue);
    expect(riding.speedLimit, 60);
    expect(c.read(brightnessProvider), 45);
    final theme = c.read(themeProvider);
    expect(theme.name, 'Ember');
    expect(theme.sport, const Color(0xFFFF0000));
    expect(theme.eco, DashTheme.ember.eco);
    expect(c.read(use24HourProvider), isTrue);
    expect(c.read(useMilesProvider), isTrue);
    expect(c.read(useFahrenheitProvider), isTrue);
    expect(c.read(dateOrderProvider), DateOrder.monthDay);
    final auto = c.read(autoDarkModeProvider);
    expect(auto.enabled, isTrue);
    expect(auto.darkAfter, const TimeOfDay(hour: 19, minute: 15));
    expect(auto.lightAfter, const TimeOfDay(hour: 5, minute: 45));
    expect(c.read(vehicleProvider).volume, 23);
    final sound = c.read(soundSettingsProvider);
    expect(sound.preset, SoundPreset.eclipse);
    expect(sound.chimeVolume, 15);
    expect(sound.motorVolume, 80);
    expect(sound.boltBite, 50, reason: 'unsaved fields keep their default');
    c.dispose();
  });

  test('changes are written back', () async {
    await boot({});
    final c = ProviderContainer();
    c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.tamper, false);
    c.read(ridingSettingsProvider.notifier).setRegenMode(RegenMode.highway);
    c.read(brightnessProvider.notifier).set(70);
    c.read(themeProvider.notifier).setTheme(DashTheme.midnight);
    c.read(themeProvider.notifier).setAccent('ECO', const Color(0xFF123456));
    c.read(use24HourProvider.notifier).set(true);
    c.read(useMilesProvider.notifier).set(true);
    c.read(useFahrenheitProvider.notifier).set(true);
    c.read(dateOrderProvider.notifier).set(DateOrder.monthDay);
    c.read(autoDarkModeProvider.notifier).setEnabled(true);
    c.read(autoDarkModeProvider.notifier).setDarkAfter(const TimeOfDay(hour: 20, minute: 0));
    c.read(vehicleProvider.notifier).setVolume(12, announce: false);
    c.read(soundSettingsProvider.notifier).setChimeVolume(73);
    final p = await stored();
    expect(p.getBool('riding_tamper'), isFalse);
    expect(jsonDecode(p.getString('riding')!)['regenMode'], 'highway');
    expect(jsonDecode(p.getString('riding')!), isNot(contains('autoTurnOffMinutes')), reason: 'the unused duration is not written back');
    expect(p.getInt('brightness'), 70);
    expect(p.getString('theme'), 'Midnight');
    expect(jsonDecode(p.getString('customAccent')!), {'ECO': 0xFF123456});
    expect(p.getBool('use24h'), isTrue);
    expect(p.getBool('useMiles'), isTrue);
    expect(p.getBool('useFahrenheit'), isTrue);
    expect(p.getString('lockDate'), 'monthDay');
    expect(jsonDecode(p.getString('autoDark')!), {'mode': 'timeBased', 'darkAfter': '20:00', 'lightAfter': '06:30'});
    expect(p.getInt('volume'), 12);
    expect(jsonDecode(p.getString('sound')!)['chimeVolume'], 73);
    c.dispose();
  });

  test('switching theme drops saved accents', () async {
    await boot({'customAccent': jsonEncode({'ECO': 0xFF123456})});
    final c = ProviderContainer();
    expect(c.read(themeProvider).eco, const Color(0xFF123456));
    c.read(themeProvider.notifier).setTheme(DashTheme.light);
    expect((await stored()).getString('customAccent'), isNull);
    c.dispose();
  });

  test('corrupt or unknown values fall back to defaults', () async {
    await boot({
      'riding': 'not json',
      'theme': 'Neon',
      'customAccent': '[1,2]',
      'lockDate': 'sideways',
      'autoDark': '{"enabled": "yes", "darkAfter": "late"}',
      'fence': '{"allowedModes": ["warp"], "week": {"9": 1}, "geoRadiusKm": "far"}',
      'sound': '{"preset": "jazz", "chimeVolume": "loud"}',
    });
    final c = ProviderContainer();
    expect(c.read(ridingSettingsProvider).regenMode, RegenMode.standard);
    expect(c.read(themeProvider), DashTheme.light);
    expect(c.read(dateOrderProvider), DateOrder.dayMonth);
    expect(c.read(autoDarkModeProvider), const AutoDarkMode());
    expect(c.read(soundSettingsProvider), const SoundSettings());
    c.dispose();
  });

  test('wrong-typed riding values fall back field by field', () async {
    await boot({
      'riding': jsonEncode({'regenLevel': 'high', 'autoTurnOffMinutes': 7, 'speedLimitEnabled': 'yes', 'speedLimit': 60, 'alarmSound': 3}),
    });
    final c = ProviderContainer();
    final r = c.read(ridingSettingsProvider);
    expect(r.regenMode, RegenMode.standard);
    expect(r.speedLimitEnabled, isTrue, reason: 'the default: on');
    expect(r.speedLimit, 60);
    expect(r.alarmSound, AlarmSound.alert1);
    c.dispose();
  });

  test('without prefs everything keeps the Phase 1 defaults', () {
    final c = ProviderContainer();
    expect(c.read(brightnessProvider), 80);
    expect(c.read(themeProvider), DashTheme.light);
    expect(c.read(use24HourProvider), isFalse);
    expect(c.read(vehicleProvider).volume, 50);
    c.dispose();
  });
}
