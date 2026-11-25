import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/charge_session.dart';
import 'package:opendash/providers/battery_diagnostics_provider.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:opendash/state/charge_energy_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/stock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(PrefsService.resetForTest);

  test('seeds three mock sessions when nothing is stored', () {
    final c = ProviderContainer();
    final h = c.read(chargeEnergyProvider).history;
    expect(h.length, 3);
    expect(h.first.timestamp, greaterThan(h.last.timestamp), reason: 'newest first');
    c.dispose();
  });

  test('mock pack electricals look like a charger while plugged in', () {
    final c = ProviderContainer();
    final v = c.read(vehicleProvider.notifier);
    v.setBattery(20);
    v.setCharging(true);
    final s = c.read(vehicleProvider);
    expect(s.busVoltage, closeTo(50.1, 0.2));
    expect(s.packCurrent, closeTo(9, 0.01), reason: 'positive into the pack, as on the scooter');
    v.setHyperCharger(true);
    expect(c.read(vehicleProvider).packCurrent, closeTo(25, 0.01));
    v.setBattery(100);
    expect(c.read(vehicleProvider).busVoltage, closeTo(58.5, 0.01));
    v.setCharging(false);
    expect(c.read(vehicleProvider).packCurrent, 0);
    c.dispose();
  });

  test('accumulates energy once a second while charging and files a session on unplug', () {
    fakeAsync((async) {
      AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
      addTearDown(() => AnalyticsLogger.instance.monoOverride = null);
      final c = ProviderContainer();
      final v = c.read(vehicleProvider.notifier);
      c.read(chargeEnergyProvider);
      v.setBattery(40);
      v.setCharging(true);
      final volts = c.read(vehicleProvider).packVoltage;
      async.elapse(const Duration(seconds: 60));
      final e = c.read(chargeEnergyProvider);
      expect(e.chargingPowerKw, closeTo(volts * 9 / 1000, 1e-6));
      expect(e.currentKwh, closeTo(volts * 9 * 60 / 3600 / 1000, 1e-6));
      expect(e.peakPowerKw, closeTo(volts * 9 / 1000, 1e-6));
      v.setBattery(55);
      v.setCharging(false);
      final after = c.read(chargeEnergyProvider);
      expect(after.currentKwh, 0);
      expect(after.chargingPowerKw, 0);
      expect(after.history.length, 4);
      expect(after.history.first.startSoc, 40);
      expect(after.history.first.endSoc, 55);
      expect(after.history.first.durationMinutes, 1);
      expect(after.history.first.energyKwh, closeTo(volts * 9 * 60 / 3600 / 1000, 1e-6));
      c.dispose();
    });
  });

  test('an unplug with no samples records nothing', () {
    final c = ProviderContainer();
    final v = c.read(vehicleProvider.notifier);
    c.read(chargeEnergyProvider);
    v.setCharging(true);
    v.setCharging(false);
    expect(c.read(chargeEnergyProvider).history.length, 3);
    c.dispose();
  });

  test('a charger handshake with no pack readings files nothing', () {
    fakeAsync((async) {
      final c = ProviderContainer(overrides: [
        vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: const Stream.empty(), invoke: (_, _) async => true)),
      ]);
      c.read(chargeEnergyProvider);
      final v = c.read(vehicleProvider.notifier) as AidlVehicleNotifier;
      v.onEvent({'INT_CHARGE_STATUS': 3});
      async.elapse(const Duration(seconds: 5));
      v.onEvent({'INT_CHARGE_STATUS': 0});
      expect(c.read(chargeEnergyProvider).history, isEmpty, reason: 'no seeds on the bridge, no zero-energy rows');
      c.dispose();
    });
  });

  test('history persists as JSON, newest first, capped at ten', () async {
    SharedPreferences.setMockInitialValues({});
    await PrefsService.init();
    fakeAsync((async) {
      AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
      addTearDown(() => AnalyticsLogger.instance.monoOverride = null);
      final c = ProviderContainer();
      final v = c.read(vehicleProvider.notifier);
      c.read(chargeEnergyProvider);
      for (var i = 0; i < 9; i++) {
        v.setCharging(true);
        async.elapse(const Duration(seconds: 2));
        v.setCharging(false);
      }
      expect(c.read(chargeEnergyProvider).history.length, 10);
      c.dispose();
    });
    final raw = (await SharedPreferences.getInstance()).getString('chargeHistory');
    final list = jsonDecode(raw!) as List;
    expect(list.length, 10);
    expect(ChargeSessionSummary.fromJson(list.first), isNotNull);
    final c2 = ProviderContainer();
    expect(c2.read(chargeEnergyProvider).history.length, 10);
    c2.dispose();
  });

  test('corrupt stored history falls back to the seeds', () async {
    SharedPreferences.setMockInitialValues({'chargeHistory': '{"not": "a list"}'});
    await PrefsService.init();
    final c = ProviderContainer();
    expect(c.read(chargeEnergyProvider).history.length, 3);
    c.dispose();
  });

  test('balancing flags come from the BMS diagnostics', () {
    final c = ProviderContainer();
    c.read(chargeEnergyProvider);
    c.read(batteryDiagnosticsProvider.notifier).setBalancing(true);
    final e = c.read(chargeEnergyProvider);
    expect(e.balancingActive, isTrue);
    expect(e.balancingCells, isNotEmpty);
    expect(e.balancingCells.every((i) => i >= 1 && i <= 14), isTrue);
    c.dispose();
  });
  test('on the scooter: the head unit drawing from a full pack is not charging, and a stalled HHMIS adds nothing', () {
    fakeAsync((async) {
      AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
      addTearDown(() => AnalyticsLogger.instance.monoOverride = null);
      final c = ProviderContainer(overrides: [
        vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: const Stream.empty(), invoke: (_, _) async => true)),
      ]);
      c.read(chargeEnergyProvider);
      final v = c.read(vehicleProvider.notifier) as AidlVehicleNotifier;
      v.onEvent({'INT_CHARGE_STATUS': 1, 'FLOAT_VEHICLE_VOLTAGE': 57.0, 'FLOAT_VEHICLE_CURRENT': 12.0});
      async.elapse(const Duration(seconds: 100));
      final charged = c.read(chargeEnergyProvider).currentKwh;
      expect(charged * 1000, closeTo(57 * 12 * 100 / 3600, 0.5));
      v.onEvent({'FLOAT_VEHICLE_CURRENT': -0.5});
      async.elapse(const Duration(minutes: 10));
      expect(c.read(chargeEnergyProvider).currentKwh, charged, reason: 'current out of the pack is not charging');
      expect(c.read(chargeEnergyProvider).chargingPowerKw, 0);
      c.dispose();
    });
  });
}
