import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/battery_diagnostics_provider.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/analytics_heartbeat.dart';
import 'package:opendash/services/analytics_logger.dart';

void main() {
  setUp(() => AnalyticsLogger.instance.resetForTest());

  List<Map<String, Object?>> beats() => AnalyticsLogger.instance.recent('state', 'heartbeat');

  test('battery.cells: every 5 s while charging, and at once on a charging state change', () {
    fakeAsync((async) {
      AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
      final c = ProviderContainer();
      c.listen(batteryDiagnosticsProvider, (_, _) {});
      final hb = AnalyticsHeartbeat(c)..start();
      async.elapse(const Duration(seconds: 3));
      c.read(vehicleProvider.notifier).setCharging(true);
      async.elapse(const Duration(seconds: 1));
      final cells = AnalyticsLogger.instance.recent('battery', 'cells');
      expect(cells, isNotEmpty);
      final first = cells.first['data']! as Map;
      expect(first['trigger'], 'charge_state');
      expect(first['max_cell'], 11, reason: 'the mock pack runs cell 11 high');
      expect(first['min_cell'], 7);
      expect(first['spread_mv'], isNotNull);
      final before = cells.length;
      async.elapse(AnalyticsHeartbeat.cellsWhileCharging);
      expect(AnalyticsLogger.instance.recent('battery', 'cells').length, before + 1);
      hb.stop();
      c.dispose();
    });
  });

  test('on the charger: every second for a minute after it changes, then one in ten', () {
    fakeAsync((async) {
      AnalyticsLogger.instance.resetForTest();
      AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
      final c = ProviderContainer();
      final hb = AnalyticsHeartbeat(c)..start();
      final n = c.read(vehicleProvider.notifier);
      var amps = 9.0;
      // The charge current wanders, so no sample equals the one before.
      final wander = Timer.periodic(const Duration(milliseconds: 500), (_) => n.state = n.state.copyWith(packCurrent: amps += 0.01));
      async.elapse(const Duration(seconds: 2));
      n.setCharging(true);
      int count() => AnalyticsLogger.instance.recent('state', 'heartbeat').length;
      final atPlug = count();
      async.elapse(AnalyticsHeartbeat.chargeSettle);
      final settled = count() - atPlug;
      expect(settled, greaterThan(50), reason: 'the plug-in itself is kept at full rate');
      final before = count();
      async.elapse(const Duration(minutes: 10));
      expect(count() - before, inInclusiveRange(55, 65), reason: 'one every ten seconds after that');
      wander.cancel();
      hb.stop();
      c.dispose();
    });
  });

  test('battery.cells stays silent where the battery provider never started', () {
    fakeAsync((async) {
      final c = ProviderContainer();
      final hb = AnalyticsHeartbeat(c)..start();
      c.read(vehicleProvider.notifier).setCharging(true);
      async.elapse(const Duration(seconds: 70));
      expect(AnalyticsLogger.instance.recent('battery', 'cells'), isEmpty);
      hb.stop();
      c.dispose();
    });
  });

  test('identical samples coalesce and the next change carries skipped_count', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final v = c.read(vehicleProvider.notifier);
    v.setConnected(true);
    final hb = AnalyticsHeartbeat(c);
    hb.sample();
    hb.sample();
    hb.sample();
    expect(beats().length, 1);
    v.setSpeed(12);
    hb.sample();
    expect(beats().length, 2);
    final last = beats().last['data'] as Map;
    expect(last['skipped_count'], 2);
    expect(last['speed'], 12);
    expect(last['state'], 'riding');
    expect(last['hhmis_up'], isTrue);
    expect(last.keys, containsAll(['soc', 'mode', 'lock', 'stand', 'cruise', 'power_kw', 'free_ram_mb', 'grpc_dump']));
  });

  test('the heartbeat records the custom ride mode, not the stale drive mode', () {
    // MoveOS 5 keeps driveMode at the last standard mode while the custom
    // mode is active, so the name has to come from customRideActive.
    expect(AnalyticsHeartbeat.snapshot(const VehicleData(driveMode: DriveMode.sport))['mode'], 'sport');
    expect(
      AnalyticsHeartbeat.snapshot(const VehicleData(driveMode: DriveMode.sport, customRideActive: true))['mode'],
      'custom',
    );
  });

  test('the heartbeat carries the BMS discharge limit the power bar is drawn against', () {
    final snap = AnalyticsHeartbeat.snapshot(const VehicleData(dischargePowerLimitW: 11800));
    expect(snap['discharge_limit_w'], 11800);
  });

  test('parked and unchanged: at most three heartbeats in thirty seconds', () {
    fakeAsync((async) {
      AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
      final c = ProviderContainer();
      final v = c.read(vehicleProvider.notifier);
      v.setConnected(true);
      final hb = AnalyticsHeartbeat(c)..start();
      async.elapse(const Duration(seconds: 30));
      expect(beats().length, lessThanOrEqualTo(3));
      expect(beats().length, greaterThanOrEqualTo(2), reason: 'a forced beat every ~10 s shows the app alive');
      hb.stop();
      c.dispose();
    });
  });

  test('riding samples at 1 Hz while the state keeps changing', () {
    fakeAsync((async) {
      AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
      final c = ProviderContainer();
      final v = c.read(vehicleProvider.notifier);
      v.setConnected(true);
      v.setVehicleState(VehicleState.ready);
      v.setSpeed(20);
      final hb = AnalyticsHeartbeat(c)..start();
      for (var i = 0; i < 10; i++) {
        async.elapse(const Duration(seconds: 1));
        v.setSpeed(21 + i);
      }
      expect(beats().length, 10);
      hb.stop();
      c.dispose();
    });
  });

  test('a disabled logger stops the heartbeat', () {
    fakeAsync((async) {
      final c = ProviderContainer();
      c.read(vehicleProvider.notifier).setConnected(true);
      AnalyticsLogger.instance.setEnabled(false);
      final hb = AnalyticsHeartbeat(c)..start();
      async.elapse(const Duration(seconds: 30));
      expect(beats(), isEmpty);
      hb.stop();
      c.dispose();
    });
  });
}
