import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/theme_state.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:opendash/state/auto_brightness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('autoScreenBrightness maps ambient onto a 30-100 screen range', () {
    expect(autoScreenBrightness(0), 30);
    expect(autoScreenBrightness(50), 65);
    expect(autoScreenBrightness(100), 100);
    expect(autoScreenBrightness(-5), 30);
    expect(autoScreenBrightness(200), 100);
  });

  test('auto brightness feature exists, on by default, with its caption', () {
    expect(RidingFeature.autoBrightness.defaultOn, isFalse, reason: 'pinned off for the suite (flutter_test_config)');
    final pinned = RidingFeature.debugDefaults;
    RidingFeature.debugDefaults = const {};
    addTearDown(() => RidingFeature.debugDefaults = pinned);
    expect(RidingFeature.autoBrightness.defaultOn, isTrue, reason: 'what ships');
    expect(RidingSettings().isOn(RidingFeature.autoBrightness), isTrue);
    expect(RidingFeature.autoBrightness.label, 'Auto brightness');
    expect(RidingFeature.autoBrightness.caption, 'Follows the time of day, or a working light sensor');
  });

  group('auto brightness', () {
    late ProviderContainer c;
    setUp(() => c = ProviderContainer());
    tearDown(() => c.dispose());

    test('follows the ambient sensor only while enabled', () {
      final v = c.read(vehicleProvider.notifier);
      c.read(brightnessProvider);
      c.read(autoBrightnessProvider);
      v.setAmbient(80);
      expect(c.read(brightnessProvider), 80, reason: 'feature off: untouched');
      c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoBrightness, true);
      expect(c.read(brightnessProvider), 86, reason: 'enabling applies the current ambient at once');
      v.setAmbient(0);
      expect(c.read(brightnessProvider), 30);
      c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoBrightness, false);
      v.setAmbient(100);
      expect(c.read(brightnessProvider), 30);
    });

    test('cycling the preset is a boost: auto stays on and takes over again at lock', () {
      c.read(autoBrightnessProvider);
      c.read(vehicleProvider.notifier).setLocked(false);
      c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoBrightness, true);
      expect(c.read(brightnessProvider), 65, reason: 'the mock sensor at 50');
      c.read(brightnessProvider.notifier).cyclePreset();
      expect(c.read(ridingSettingsProvider).isOn(RidingFeature.autoBrightness), isTrue);
      expect(c.read(brightnessProvider), 100, reason: 'next preset after 65');
      expect(c.read(autoBrightnessProvider).boost, 100);
      c.read(vehicleProvider.notifier).setAmbient(10);
      expect(c.read(brightnessProvider), 100, reason: 'held for this outing');
      c.read(vehicleProvider.notifier).setLocked(true);
      expect(c.read(autoBrightnessProvider).boost, isNull);
      expect(c.read(brightnessProvider), 37, reason: 'auto again');
    });
  });

  test('persisted feature state drives the vehicle without a toggle', () async {
    SharedPreferences.setMockInitialValues({'riding_autoBrightness': true, 'riding_smartHeadlight': false, 'riding_autoHeadlight': false});
    await PrefsService.init();
    final c = ProviderContainer();
    final v = c.read(vehicleProvider.notifier);
    c.read(ridingSettingsProvider);
    c.read(brightnessProvider);
    c.read(autoBrightnessProvider);
    v.setAmbient(0);
    expect(c.read(brightnessProvider), 30);
    v.setAmbient(20);
    v.setVehicleState(VehicleState.riding);
    expect(c.read(vehicleProvider).lowBeam, isFalse, reason: 'smart headlight persisted off');
    c.dispose();
    PrefsService.resetForTest();
  });

  group('smart headlight', () {
    late ProviderContainer c;
    late VehicleNotifier v;
    setUp(() {
      c = ProviderContainer();
      v = c.read(vehicleProvider.notifier);
      c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoHeadlight, false);
      c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.smartHeadlight, true);
    });
    tearDown(() => c.dispose());

    test('low beam follows ambient while riding', () {
      v.setAmbient(50);
      v.setVehicleState(VehicleState.riding);
      expect(c.read(vehicleProvider).lowBeam, isFalse, reason: 'daylight: DRL only');
      v.setAmbient(20);
      expect(c.read(vehicleProvider).lowBeam, isTrue);
      v.setAmbient(60);
      expect(c.read(vehicleProvider).lowBeam, isFalse);
      expect(c.read(vehicleProvider).highBeam, isFalse, reason: 'never touches high beam');
    });

    test('setting off while riding leaves the lamp alone, and parked ignores ambient', () {
      v.setAmbient(20);
      v.setVehicleState(VehicleState.riding);
      expect(c.read(vehicleProvider).lowBeam, isTrue);
      c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.smartHeadlight, false);
      v.setAmbient(70);
      expect(c.read(vehicleProvider).lowBeam, isTrue, reason: 'manual control once the feature is off');
      v.setVehicleState(VehicleState.parked);
      v.setAmbient(10);
      expect(c.read(vehicleProvider).lowBeam, isFalse);
    });

    test('auto headlight still forces the lamp on regardless of ambient', () {
      c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoHeadlight, true);
      v.setAmbient(90);
      v.setVehicleState(VehicleState.riding);
      expect(c.read(vehicleProvider).lowBeam, isTrue);
    });
  });
}
