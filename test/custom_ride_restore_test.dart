import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/stock.dart';

/// The custom ride mode is remembered across starts, so its ladder row and
/// By-mode bar are there from boot and not only after the rider selects it
/// (HHMIS re-sends CUSTOM_RIDE_* only on a change).
void main() {
  tearDown(PrefsService.resetForTest);

  ProviderContainer scooter() => ProviderContainer(overrides: [
        vehicleProvider.overrideWith(() => AidlVehicleNotifier(
            identity: stockIdentity(), events: const Stream.empty(), invoke: (_, _) async => true)),
      ]);

  test('a saved custom config is restored into the initial state', () async {
    SharedPreferences.setMockInitialValues({'customRide': '{"name":"Rain","enabled":true,"topSpeedKmh":70}'});
    await PrefsService.init();
    final c = scooter();
    final custom = c.read(vehicleProvider).customRide;
    expect(custom.known, isTrue);
    expect(custom.name, 'Rain');
    expect(custom.enabled, isTrue);
    expect(custom.topSpeedKmh, 70);
    c.dispose();
  });

  test('nothing saved means no custom mode is shown', () async {
    SharedPreferences.setMockInitialValues({});
    await PrefsService.init();
    final c = scooter();
    expect(c.read(vehicleProvider).customRide.known, isFalse);
    c.dispose();
  });

  test('the config is persisted when the scooter reports it', () async {
    SharedPreferences.setMockInitialValues({});
    await PrefsService.init();
    final c = scooter();
    final v = c.read(vehicleProvider.notifier) as AidlVehicleNotifier;
    v.onEvent({'STR_CUSTOM_RIDE_MODE_NAME': 'Rain', 'CUSTOM_RIDE_MODE': 1});
    expect(PrefsService.getString(PrefsKeys.customRide, ''), contains('Rain'));
    // A fresh notifier (restart) now shows it from boot.
    final c2 = scooter();
    expect(c2.read(vehicleProvider).customRide.name, 'Rain');
    c.dispose();
    c2.dispose();
  });
}
