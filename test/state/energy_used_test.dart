import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:opendash/state/energy_used_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/stock.dart';

ProviderContainer scooter() => ProviderContainer(overrides: [
      vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: const Stream.empty(), invoke: (_, _) async => true)),
    ]);

/// A clock the test moves by hand, one second per [step].
class _Clock {
  int micros = 0;
  void step([int seconds = 1]) => micros += seconds * 1000000;
}

void main() {
  tearDown(PrefsService.resetForTest);
  tearDown(() => AnalyticsLogger.instance.monoOverride = null);

  AidlVehicleNotifier vehicle(ProviderContainer c) => c.read(vehicleProvider.notifier) as AidlVehicleNotifier;

  test('on the scooter: pack volts x amps out of the pack, once a second, only with the motor on', () {
    fakeAsync((async) {
      AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
      final c = scooter();
      final v = vehicle(c);
      c.listen(energyUsedProvider, (_, _) {});
      expect(c.read(energyUsedProvider), 0);

      // Parked with the charger on: nothing counts.
      v.onEvent({'INT_VEHICLE_STATE': 6, 'FLOAT_VEHICLE_VOLTAGE': 56.0, 'FLOAT_VEHICLE_CURRENT': 13.0});
      async.elapse(const Duration(minutes: 10));
      v.onEvent({'INT_VEHICLE_STATE': 3, 'FLOAT_VEHICLE_CURRENT': -2.0});
      async.elapse(const Duration(minutes: 10));
      expect(c.read(energyUsedProvider), 0);

      // 50 V x 72 A = 3.6 kW for 100 s = 0.1 kWh.
      v.onEvent({'INT_VEHICLE_STATE': 4, 'FLOAT_VEHICLE_VOLTAGE': 50.0, 'FLOAT_VEHICLE_CURRENT': -72.0});
      async.elapse(const Duration(seconds: 100));
      expect(c.read(energyUsedProvider), closeTo(0.10, 1e-9));

      // Regen is not subtracted; it has its own row.
      v.onEvent({'FLOAT_VEHICLE_CURRENT': 40.0});
      async.elapse(const Duration(seconds: 100));
      expect(c.read(energyUsedProvider), closeTo(0.10, 1e-9));

      // Parked again: the total stands and the sampling stops.
      v.onEvent({'INT_VEHICLE_STATE': 3, 'FLOAT_VEHICLE_CURRENT': -72.0});
      async.elapse(const Duration(minutes: 5));
      expect(c.read(energyUsedProvider), closeTo(0.10, 1e-9));
      c.dispose();
    });
  });

  test('measured pack volts from CAN are preferred over the bus voltage', () {
    final clock = _Clock();
    AnalyticsLogger.instance.monoOverride = () => clock.micros;
    final c = scooter();
    final v = vehicle(c);
    final n = c.read(energyUsedProvider.notifier);
    v.onEvent({'INT_VEHICLE_STATE': 4, 'FLOAT_VEHICLE_VOLTAGE': 50.0, 'FLOAT_VEHICLE_CURRENT': -360.0});
    v.applySensorUpdate(
      ambientBrightness: null, serviceIndicator: null, regenPowerLimitW: null, dischargePowerLimitW: null,
      rangeEcoCan: null, regenAvailability: null, towTheftState: null, busVoltage: null, packVoltage: 100.0,
      packCurrent: null, trunkClosed: null, vehicleLockStateBcm: null,
    );
    n.tick();
    clock.step();
    n.tick();
    expect(c.read(energyUsedProvider), closeTo(0.01, 1e-9), reason: '100 V x 360 A for 1 s is 10 Wh');
    c.dispose();
  });

  test('the total survives a restart on the same day and starts over on the next', () async {
    SharedPreferences.setMockInitialValues({});
    await PrefsService.init();
    final clock = _Clock();
    AnalyticsLogger.instance.monoOverride = () => clock.micros;
    var c = scooter();
    var n = c.read(energyUsedProvider.notifier)..today = () => '2026-11-12';
    // build() ran with the real date; nothing saved yet, so it starts at 0.
    vehicle(c).onEvent({'INT_VEHICLE_STATE': 4, 'FLOAT_VEHICLE_VOLTAGE': 50.0, 'FLOAT_VEHICLE_CURRENT': -72.0});
    n.tick();
    for (var i = 0; i < 50; i++) {
      clock.step();
      n.tick();
    }
    expect(c.read(energyUsedProvider), closeTo(0.05, 1e-9));
    expect(PrefsService.getString(PrefsKeys.energyUsedToday, ''), '2026-11-12|45.0',
        reason: 'written when the shown figure moves (every 10 Wh), not every second');
    c.dispose();

    // Same day: PrefsService hands the stored total back.
    final now = DateTime.now();
    await PrefsService.setString(PrefsKeys.energyUsedToday, '${now.year}-${now.month}-${now.day}|50.0');
    c = scooter();
    expect(c.read(energyUsedProvider), closeTo(0.05, 1e-9));

    // Next day: the first sample starts from zero.
    n = c.read(energyUsedProvider.notifier)..today = () => 'tomorrow';
    vehicle(c).onEvent({'INT_VEHICLE_STATE': 4, 'FLOAT_VEHICLE_VOLTAGE': 50.0, 'FLOAT_VEHICLE_CURRENT': -720.0});
    n.tick();
    clock.step();
    n.tick();
    expect(c.read(energyUsedProvider), closeTo(0.01, 1e-9));
    c.dispose();

    // A stale date in prefs is ignored at start.
    await PrefsService.setString(PrefsKeys.energyUsedToday, '1999-1-1|900.0');
    c = scooter();
    expect(c.read(energyUsedProvider), 0);
    c.dispose();
  });

  test('the mock dashboard keeps showing its own figure', () {
    final c = ProviderContainer();
    expect(c.read(energyUsedProvider), 0);
    c.read(vehicleProvider.notifier).state = const VehicleData(energyUsed: 1.25);
    expect(c.read(energyUsedProvider), 1.25);
    c.dispose();
  });
  test('a late sample counts the seconds that passed; a long gap counts nothing', () {
    final clock = _Clock();
    AnalyticsLogger.instance.monoOverride = () => clock.micros;
    final c = scooter();
    final v = vehicle(c);
    final n = c.read(energyUsedProvider.notifier);
    v.onEvent({'INT_VEHICLE_STATE': 4, 'FLOAT_VEHICLE_VOLTAGE': 50.0, 'FLOAT_VEHICLE_CURRENT': -72.0});
    n.tick();
    clock.step(3);
    n.tick();
    expect(c.read(energyUsedProvider), closeTo(0.0, 0.006), reason: '3 s x 3.6 kW is 3 Wh, shown to 10 Wh');
    clock.step(60);
    n.tick();
    expect(c.read(energyUsedProvider), closeTo(0.0, 0.006), reason: 'a minute with no samples is not integrated');
    for (var i = 0; i < 7; i++) {
      clock.step();
      n.tick();
    }
    expect(c.read(energyUsedProvider), closeTo(0.01, 1e-9), reason: '3 s + 7 s at 3.6 kW is 10 Wh');
    c.dispose();
  });

  test('nothing is integrated while HHMIS is stale and CAN is not live', () {
    final clock = _Clock();
    AnalyticsLogger.instance.monoOverride = () => clock.micros;
    final c = scooter();
    final v = vehicle(c);
    final n = c.read(energyUsedProvider.notifier);
    v.onEvent({'INT_VEHICLE_STATE': 4, 'FLOAT_VEHICLE_VOLTAGE': 50.0, 'FLOAT_VEHICLE_CURRENT': -720.0});
    v.state = v.state.copyWith(hhmisStale: true);
    n.tick();
    for (var i = 0; i < 5; i++) {
      clock.step();
      n.tick();
    }
    expect(c.read(energyUsedProvider), 0);
    c.dispose();
  });
}
