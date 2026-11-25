import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/battery_diagnostics.dart';
import 'package:opendash/models/battery_health.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/battery_diagnostics_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:opendash/services/ride_tracker.dart';
import 'package:opendash/state/battery_health_state.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Vehicle extends VehicleNotifier {
  void put(VehicleData Function(VehicleData v) f) => state = f(state);
}

void main() {
  void withHealth(void Function(FakeAsync async, ProviderContainer c, VehicleNotifier v) body) {
    fakeAsync((async) {
      final c = ProviderContainer();
      c.listen(batteryHealthProvider, (_, _) {});
      c.listen(vehicleProvider, (_, _) {});
      c.listen(batteryDiagnosticsProvider, (_, _) {});
      c.listen(ridingSettingsProvider, (_, _) {});
      final v = c.read(vehicleProvider.notifier);
      async.elapse(const Duration(milliseconds: 100));
      body(async, c, v);
      c.dispose();
    });
  }

  group('seed segments', () {
    test('notifier starts with 8 mock segments', () {
      withHealth((async, c, v) {
        final s = c.read(batteryHealthProvider);
        expect(s.segments.length, 8);
      });
    });

    test('seed segments have valid km/percent ratios', () {
      withHealth((async, c, v) {
        for (final seg in c.read(batteryHealthProvider).segments) {
          expect(seg.kmPerPercent, greaterThan(0), reason: 'mode ${seg.driveMode}');
          expect(seg.socUsed, greaterThan(0));
          expect(seg.distanceKm, greaterThan(0));
        }
      });
    });
  });

  group('range estimation', () {
    test('with enough segments produces a true range and confidence', () {
      withHealth((async, c, v) {
        final notifier = c.read(batteryHealthProvider.notifier);
        final result = notifier.estimateRange(
          currentSoc: 80,
          rawSoc: 79.3,
          driveMode: DriveMode.normal,
          stockRange: 100,
        );
        expect(result.trueRangeKm, greaterThan(0));
        expect(result.confidencePercent, greaterThan(0));
        expect(result.kmPerPercent, greaterThan(0));
        expect(result.ridesUsed, 8);
        expect(result.stockRangeKm, 100);
      });
    });

    test('falls back to stock range with fewer than 3 segments', () {
      withHealth((async, c, v) {
        final notifier = c.read(batteryHealthProvider.notifier);
        notifier.seedSegments([
          const RideSegment(startSoc: 90, endSoc: 85, startOdometer: 1000, endOdometer: 5000, driveMode: 2, avgTempC: 30, timestamp: 100),
        ]);
        final result = notifier.estimateRange(
          currentSoc: 80,
          rawSoc: 79.3,
          driveMode: DriveMode.normal,
          stockRange: 95,
        );
        expect(result.trueRangeKm, 95);
        expect(result.confidencePercent, 10);
        expect(result.ridesUsed, 1);
      });
    });

    test('mode-matching segments get higher weight', () {
      withHealth((async, c, v) {
        final notifier = c.read(batteryHealthProvider.notifier);
        notifier.seedSegments([
          const RideSegment(startSoc: 90, endSoc: 80, startOdometer: 0, endOdometer: 10000, driveMode: 6, avgTempC: 30, timestamp: 100),
          const RideSegment(startSoc: 90, endSoc: 80, startOdometer: 0, endOdometer: 10000, driveMode: 6, avgTempC: 30, timestamp: 200),
          const RideSegment(startSoc: 90, endSoc: 80, startOdometer: 0, endOdometer: 10000, driveMode: 6, avgTempC: 30, timestamp: 300),
          const RideSegment(startSoc: 90, endSoc: 80, startOdometer: 0, endOdometer: 5000, driveMode: 2, avgTempC: 30, timestamp: 400),
        ]);
        final ecoResult = notifier.estimateRange(
          currentSoc: 80, rawSoc: 80, driveMode: DriveMode.eco, stockRange: 100,
        );
        final normalResult = notifier.estimateRange(
          currentSoc: 80, rawSoc: 80, driveMode: DriveMode.normal, stockRange: 100,
        );
        expect(ecoResult.trueRangeKm, greaterThan(normalResult.trueRangeKm),
            reason: 'eco segments dominate so eco estimate should be higher');
      });
    });
  });

  // The learned range once forgot every ride at each app restart.
  group('segment persistence', () {
    setUp(AnalyticsLogger.instance.resetForTest);
    tearDown(PrefsService.resetForTest);

    RideSegment seg(int i) => RideSegment(
          startSoc: 90,
          endSoc: 80,
          startOdometer: i * 10,
          endOdometer: i * 10 + 8,
          driveMode: 2,
          avgTempC: 30,
          timestamp: i,
        );
    String stored(int n) => jsonEncode([for (var i = 0; i < n; i++) seg(i).toJson()]);

    void withStored(void Function(FakeAsync async, ProviderContainer c, _Vehicle v) body) {
      fakeAsync((async) {
        final c = ProviderContainer(overrides: [vehicleProvider.overrideWith(_Vehicle.new)]);
        c.listen(batteryHealthProvider, (_, _) {});
        c.listen(vehicleProvider, (_, _) {});
        final v = c.read(vehicleProvider.notifier) as _Vehicle;
        v.setConnected(true);
        v.setLocked(false);
        final tracker = RideTracker(c)..start();
        async.elapse(const Duration(milliseconds: 100));
        body(async, c, v);
        tracker.stop();
        c.dispose();
      });
    }

    // 36 km/h is 10 m/s: the ride starts after 10 s and ends 30 s after
    // the motor goes off.
    void ride(FakeAsync async, _Vehicle v, {required int km, required int socUsed}) {
      v.setBattery(80);
      v.setVehicleState(VehicleState.ready);
      v.setSpeed(36);
      async.elapse(const Duration(seconds: 12));
      v.put((s) => s.copyWith(odometer: s.odometer + km));
      v.setBattery(80 - socUsed);
      v.setSpeed(0);
      v.setVehicleState(VehicleState.parked);
      async.elapse(const Duration(seconds: 31));
    }

    test('a finished ride is written to prefs and read back by a new notifier', () async {
      SharedPreferences.setMockInitialValues({'rideSegments': stored(2)});
      await PrefsService.init();
      withStored((async, c, v) {
        expect(c.read(batteryHealthProvider).segments.length, 2, reason: 'stored rides replace the mock seeds');
        expect(AnalyticsLogger.instance.recent('range', 'segments_loaded').single['data'], {'count': 2});
        ride(async, v, km: 6, socUsed: 5);
        final segments = c.read(batteryHealthProvider).segments;
        expect(segments.length, 3);
        expect(segments.last.distanceKm, 6);
        expect(segments.last.socUsed, closeTo(5, 1e-9));
        final saved = AnalyticsLogger.instance.recent('range', 'segment_saved').single['data'] as Map;
        expect(saved['km'], 6);
        expect(saved['count'], 3);
      });
      final raw = (await SharedPreferences.getInstance()).getString('rideSegments');
      expect((jsonDecode(raw!) as List).length, 3);
      final c2 = ProviderContainer();
      final again = c2.read(batteryHealthProvider).segments;
      expect(again.length, 3);
      expect(again.last.distanceKm, 6);
      expect(again.last.kmPerPercent, closeTo(1.2, 1e-9));
      c2.dispose();
    });

    test('a ride too short to count is not stored', () async {
      SharedPreferences.setMockInitialValues({'rideSegments': stored(2)});
      await PrefsService.init();
      withStored((async, c, v) {
        ride(async, v, km: 0, socUsed: 5);
        expect(c.read(batteryHealthProvider).segments.length, 2);
      });
      final raw = (await SharedPreferences.getInstance()).getString('rideSegments');
      expect((jsonDecode(raw!) as List).length, 2);
    });

    test('with the CAN odometer, a ride under a kilometre counts, to the metre', () async {
      SharedPreferences.setMockInitialValues({'rideSegments': stored(2)});
      await PrefsService.init();
      withStored((async, c, v) {
        v.put((s) => s.copyWith(odometerM: 33101528));
        v.setBattery(80);
        v.setVehicleState(VehicleState.ready);
        v.setSpeed(36);
        async.elapse(const Duration(seconds: 12));
        v.put((s) => s.copyWith(odometerM: 33101528 + 740));
        v.setBattery(79);
        v.setSpeed(0);
        v.setVehicleState(VehicleState.parked);
        async.elapse(const Duration(seconds: 31));
        final segments = c.read(batteryHealthProvider).segments;
        expect(segments.length, 3, reason: 'the whole-km odometer did not move; the metres did');
        expect(segments.last.distanceM, 740);
        expect(segments.last.distanceKm, closeTo(0.74, 1e-9));
        expect(segments.last.kmPerPercent, closeTo(0.74, 1e-9));
        final saved = AnalyticsLogger.instance.recent('range', 'segment_saved').single['data'] as Map;
        expect(saved['measured'], isTrue);
      });
      final raw = (await SharedPreferences.getInstance()).getString('rideSegments');
      final last = (jsonDecode(raw!) as List).last as Map;
      expect(last['distanceM'], 740);
    });

    test('a measured ride under the minimum is not stored', () async {
      SharedPreferences.setMockInitialValues({'rideSegments': stored(2)});
      await PrefsService.init();
      withStored((async, c, v) {
        v.put((s) => s.copyWith(odometerM: 1000000));
        v.setBattery(80);
        v.setVehicleState(VehicleState.ready);
        v.setSpeed(36);
        async.elapse(const Duration(seconds: 12));
        v.put((s) => s.copyWith(odometerM: 1000000 + 300));
        v.setBattery(79);
        v.setSpeed(0);
        v.setVehicleState(VehicleState.parked);
        async.elapse(const Duration(seconds: 31));
        expect(c.read(batteryHealthProvider).segments.length, 2);
      });
    });

    test('the stored list is capped at maxSegments, newest kept', () async {
      SharedPreferences.setMockInitialValues({'rideSegments': stored(BatteryHealthNotifier.maxSegments + 5)});
      await PrefsService.init();
      withStored((async, c, v) {
        final loaded = c.read(batteryHealthProvider).segments;
        expect(loaded.length, BatteryHealthNotifier.maxSegments);
        expect(loaded.first.timestamp, 5);
        ride(async, v, km: 6, socUsed: 5);
        expect(c.read(batteryHealthProvider).segments.length, BatteryHealthNotifier.maxSegments);
      });
      final raw = (await SharedPreferences.getInstance()).getString('rideSegments');
      final list = jsonDecode(raw!) as List;
      expect(list.length, BatteryHealthNotifier.maxSegments);
      expect((list.first as Map)['timestamp'], 6);
    });

    // A logged ride (23 min, 11.24 km, 56.9 -> 41.5 %):
    // seconds from its start, speed, state, raw SOC, odometer at each change
    // of moving / state. The build on the scooter stored 7 + 1 + 3 km.
    const ride3 = <(int, int, VehicleState, double, int)>[
      (9, 0, VehicleState.ready, 56.89, 33179),
      (12, 3, VehicleState.riding, 56.87, 33179),
      (15, 0, VehicleState.ready, 56.86, 33179),
      (24, 3, VehicleState.riding, 56.83, 33179),
      (47, 0, VehicleState.ready, 56.75, 33179),
      (70, 30, VehicleState.riding, 56.74, 33179),
      (792, 0, VehicleState.ready, 48.90, 33186),
      (794, 30, VehicleState.riding, 48.90, 33186),
      (885, 0, VehicleState.ready, 47.50, 33187),
      (893, 1, VehicleState.riding, 47.50, 33187),
      (895, 0, VehicleState.ready, 47.50, 33187),
      (898, 1, VehicleState.riding, 47.49, 33187),
      (899, 0, VehicleState.ready, 47.49, 33187),
      (900, 1, VehicleState.riding, 47.49, 33187),
      (909, 0, VehicleState.ready, 47.46, 33187),
      (913, 1, VehicleState.riding, 47.45, 33187),
      (917, 0, VehicleState.ready, 47.44, 33187),
      (922, 2, VehicleState.riding, 47.43, 33187),
      (925, 0, VehicleState.ready, 47.39, 33187),
      (936, 3, VehicleState.riding, 47.33, 33187),
      (951, 0, VehicleState.ready, 47.10, 33187),
      (962, 7, VehicleState.riding, 47.02, 33187),
      (969, 0, VehicleState.ready, 46.88, 33187),
      (979, 30, VehicleState.riding, 46.82, 33187),
      (1333, 0, VehicleState.ready, 41.73, 33190),
      (1335, 0, VehicleState.parked, 41.72, 33190),
      (1363, 1, VehicleState.riding, 41.71, 33190),
      (1373, 0, VehicleState.ready, 41.56, 33190),
      (1375, 0, VehicleState.parked, 41.56, 33190),
      (1387, 3, VehicleState.riding, 41.55, 33190),
      (1389, 0, VehicleState.parked, 41.54, 33190),
    ];

    test('a stop-and-go ride is one segment, not one per junction', () async {
      SharedPreferences.setMockInitialValues({'rideSegments': stored(2)});
      await PrefsService.init();
      withStored((async, c, v) {
        v.put((s) => s.copyWith(odometer: 33179, rawBatterySoc: 56.9, batterySoc: 56, driveMode: DriveMode.sport));
        var at = 0;
        for (final (t, speed, vs, soc, odo) in ride3) {
          async.elapse(Duration(seconds: t - at));
          at = t;
          v.put((s) => s.copyWith(speed: speed, vehicleState: vs, rawBatterySoc: soc, batterySoc: soc.floor(), odometer: odo));
          expect(c.read(batteryHealthProvider).segments.length, 2, reason: 'no segment mid-ride (t=$t)');
        }
        async.elapse(const Duration(seconds: 12));
        v.setLocked(true);
        async.flushMicrotasks();
        final segments = c.read(batteryHealthProvider).segments;
        expect(segments.length, 3);
        expect(segments.last.startOdometer, 33179);
        expect(segments.last.distanceKm, 11);
        expect(segments.last.socUsed, closeTo(56.74 - 41.54, 0.2));
        expect(segments.last.driveMode, driveModeIndex(DriveMode.sport));
        expect(AnalyticsLogger.instance.recent('range', 'segment_saved').length, 1);
        expect(AnalyticsLogger.instance.recent('ride', 'end').length, 1);
      });
    });

    test('a segment takes the mode most of the ride was ridden in', () async {
      SharedPreferences.setMockInitialValues({'rideSegments': stored(2)});
      await PrefsService.init();
      withStored((async, c, v) {
        v.put((s) => s.copyWith(rawBatterySoc: 80, vehicleState: VehicleState.riding, speed: 36, driveMode: DriveMode.hyper));
        async.elapse(const Duration(seconds: 60));
        v.put((s) => s.copyWith(driveMode: DriveMode.normal));
        async.elapse(const Duration(seconds: 15));
        v.put((s) => s.copyWith(rawBatterySoc: 75, odometer: s.odometer + 4, speed: 0, vehicleState: VehicleState.parked));
        async.elapse(const Duration(seconds: 31));
        expect(c.read(batteryHealthProvider).segments.last.driveMode, driveModeIndex(DriveMode.hyper));
      });
    });

    // What an earlier build left in prefs after a day of rides.
    test('pieces of one ride already in prefs are joined on load; separate rides are kept', () async {
      const t = 1794500000;
      RideSegment piece(double s0, double s1, int o0, int o1, int at) => RideSegment(
          startSoc: s0, endSoc: s1, startOdometer: o0, endOdometer: o1, driveMode: 3, avgTempC: 37, timestamp: t + at);
      final split = [
        piece(84.98, 64.7, 33165, 33174, 0),
        piece(64.0, 57.0, 33174, 33179, 2546),
        piece(56.7, 48.9, 33179, 33186, 3467),
        piece(48.9, 47.5, 33186, 33187, 3559),
        piece(46.8, 41.7, 33187, 33190, 4008),
      ];
      SharedPreferences.setMockInitialValues({'rideSegments': jsonEncode([for (final s in split) s.toJson()])});
      await PrefsService.init();
      final c = ProviderContainer();
      final loaded = c.read(batteryHealthProvider).segments;
      expect([for (final s in loaded) s.distanceKm], [9, 5, 11]);
      expect(loaded.last.startSoc, 56.7);
      expect(loaded.last.endSoc, 41.7);
      expect(loaded.last.timestamp, t + 4008);
      expect(AnalyticsLogger.instance.recent('range', 'segments_merged').single['data'], {'from': 5, 'to': 3});
      expect(BatteryHealthNotifier.mergeSplitSegments(loaded).length, 3, reason: 'idempotent');
      c.dispose();
    });

    test('a charge or a gap in the odometer between segments is never joined over', () {
      RideSegment piece(double s0, double s1, int o0, int o1, int at) => RideSegment(
          startSoc: s0, endSoc: s1, startOdometer: o0, endOdometer: o1, driveMode: 3, avgTempC: 37, timestamp: at);
      expect(BatteryHealthNotifier.mergeSplitSegments([piece(60, 50, 100, 108, 0), piece(55, 45, 108, 116, 300)]).length, 2);
      expect(BatteryHealthNotifier.mergeSplitSegments([piece(60, 50, 100, 108, 0), piece(50, 45, 111, 116, 300)]).length, 2);
      expect(BatteryHealthNotifier.mergeSplitSegments([piece(60, 50, 100, 108, 0), piece(50, 45, 108, 116, 601)]).length, 2);
      expect(BatteryHealthNotifier.mergeSplitSegments([piece(60, 50, 100, 108, 0), piece(50, 45, 108, 116, 600)]).length, 1);
    });

    test('the estimate weights a segment by its distance', () {
      withStored((async, c, v) {
        final n = c.read(batteryHealthProvider.notifier);
        n.seedSegments([
          const RideSegment(startSoc: 90, endSoc: 70, startOdometer: 0, endOdometer: 20, driveMode: 2, avgTempC: 30, timestamp: 1),
          const RideSegment(startSoc: 70, endSoc: 50, startOdometer: 20, endOdometer: 40, driveMode: 2, avgTempC: 30, timestamp: 2),
          const RideSegment(startSoc: 50, endSoc: 49.5, startOdometer: 40, endOdometer: 41, driveMode: 2, avgTempC: 30, timestamp: 3),
        ]);
        final r = n.estimateRange(currentSoc: 50, rawSoc: 50, driveMode: DriveMode.normal, stockRange: 70);
        expect(r.kmPerPercent, closeTo(1.0, 0.05), reason: 'the 1 km / 0.5 % segment (2 km/%) barely moves it');
        expect(r.confidencePercent, 30);
      });
    });

    test('corrupt or wrong-shaped stored data starts from the seeds, without throwing', () async {
      for (final bad in ['{"not": "a list"}', 'not json', '[{"startSoc": "ninety"}]', '[1, 2]']) {
        SharedPreferences.setMockInitialValues({'rideSegments': bad});
        await PrefsService.init();
        final c = ProviderContainer();
        expect(c.read(batteryHealthProvider).segments.length, 8, reason: bad);
        c.dispose();
      }
    });
  });

  group('trueRangeProvider', () {
    test('computes from vehicle + health state', () {
      withHealth((async, c, v) {
        c.listen(trueRangeProvider, (_, _) {});
        async.elapse(const Duration(seconds: 1));
        final tr = c.read(trueRangeProvider);
        expect(tr.stockRangeKm, c.read(vehicleProvider).range);
        expect(tr.ridesUsed, 8);
        expect(tr.confidencePercent, 80);
      });
    });
  });

  group('cell warning detection', () {
    test('no warning with the cells together, at any charge', () {
      withHealth((async, c, v) {
        async.elapse(BatteryHealthNotifier.sampleInterval * 4);
        expect(c.read(cellWarningProvider), isNull);
        // Low charge alone is not a weak cell: there is no voltage rule,
        // and near empty, where any pack's cells pull apart, none is judged.
        v.setBattery(8);
        async.elapse(BatteryHealthNotifier.sampleInterval * 4);
        expect(c.read(cellWarningProvider), isNull);
      });
    });

    // A Gen 1 test pack rests 240 to 320 mV apart all day. A
    // warning for that would never go away; one on a voltage came and went
    // with the throttle. What is warned about is the weak cell giving way
    // under load, while it does.
    test('a pack that rests uneven is not a status-bar warning; the weak cell giving way under load is, and it goes again', () {
      withHealth((async, c, v) {
        const sample = BatteryHealthNotifier.sampleInterval;
        final diag = c.read(batteryDiagnosticsProvider.notifier);
        diag.setDegradedCells(true);
        async.elapse(sample * (BatteryHealthNotifier.cellSettleReadings + 2));
        final rest = c.read(cellWarningProvider)!;
        expect(rest.severity, CellWarningSeverity.advisory, reason: 'a standing fact, for the battery page');
        expect(rest.weakCellIndex, 3);

        // Gentle riding: the gap barely moves.
        v.setVehicleState(VehicleState.riding);
        v.setSpeed(30);
        v.setPower(2);
        async.elapse(sample * 3);
        expect(c.read(cellWarningProvider)!.severity, CellWarningSeverity.advisory);

        // Hard acceleration: the weak cell falls away.
        v.setPower(8);
        async.elapse(sample * 2);
        final strained = c.read(cellWarningProvider)!;
        expect(strained.severity, CellWarningSeverity.warning);
        expect(strained.spreadMv - rest.spreadMv, greaterThanOrEqualTo(BatteryHealthNotifier.strainExtraMv));
        expect(strained.message, contains('sagging under load'));

        // Easing off: it holds for a few samples, so it does not blink
        // with the throttle, and then goes.
        v.setPower(2);
        async.elapse(sample * (BatteryHealthNotifier.strainHoldReadings - 1));
        expect(c.read(cellWarningProvider)!.severity, CellWarningSeverity.warning);
        async.elapse(sample * 3);
        expect(c.read(cellWarningProvider)!.severity, CellWarningSeverity.advisory);

        final levels = [for (final e in AnalyticsLogger.instance.recent('battery', 'cell_warning')) (e['data'] as Map)['level']];
        expect(levels, ['advisory', 'warning', 'advisory']);
        v.setPower(0);
        v.setSpeed(0);
      });
    });

    test('a healthy pack under the same load: nothing', () {
      withHealth((async, c, v) {
        async.elapse(BatteryHealthNotifier.sampleInterval * 4);
        v.setVehicleState(VehicleState.riding);
        v.setSpeed(60);
        v.setPower(8);
        async.elapse(BatteryHealthNotifier.sampleInterval * 4);
        expect(c.read(cellWarningProvider), isNull);
        v.setPower(0);
        v.setSpeed(0);
      });
    });
  });

  group('the battery at its own limit', () {
    // The most this battery has offered: 12.3 kW (full).
    VehicleData at({required double kw, required int limitW, int peakW = 12300}) => const VehicleData()
        .copyWith(power: kw, dischargePowerLimitW: limitW, batterySoc: 55, peaks: ScooterPeaks(dischargeLimitW: peakW));
    bool alert(VehicleData v) => v.alerts.any((a) => a.kind == AlertKind.batteryAtLimit);

    test('a banner when the battery has cut its limit and the draw reaches it, whatever the cell voltages', () {
      // `power` is on the display scale (pack kW x 0.708); the limit is pack watts.
      expect(alert(at(kw: 5.0, limitW: 7600)), isTrue, reason: '7.06 kW at the pack, 93 % of a limit at 62 % of its best');
      expect(alert(at(kw: 5.0, limitW: 5400)), isTrue, reason: 'past the limit');
      expect(alert(at(kw: 5.0, limitW: 8000)), isFalse, reason: '88 % of it');
    });

    test('nothing for a hard pull against a limit that is still near its best', () {
      expect(alert(at(kw: 6.35, limitW: 9867)), isFalse, reason: 'at 56 %: 91 % of a limit at 80 % of its best');
      expect(alert(at(kw: 7.7, limitW: 11979)), isFalse, reason: 'full battery, full throttle');
      expect(alert(at(kw: 5.0, limitW: 7600, peakW: 0)), isFalse, reason: 'no best yet to compare with');
    });

    test('not without a limit from the battery, and not on a trickle', () {
      expect(alert(at(kw: 6.0, limitW: 0)), isFalse, reason: 'no reading (locked, or no CAN stream)');
      expect(alert(at(kw: 0.5, limitW: 500)), isFalse, reason: 'under 1 kW shown');
      expect(alert(at(kw: -2.0, limitW: 1000)), isFalse, reason: 'regenerating');
    });
  });

  group('seedSegments', () {
    test('replaces segments with the given list', () {
      withHealth((async, c, v) {
        final notifier = c.read(batteryHealthProvider.notifier);
        notifier.seedSegments([
          const RideSegment(startSoc: 95, endSoc: 85, startOdometer: 0, endOdometer: 8000, driveMode: 2, avgTempC: 30, timestamp: 100),
        ]);
        expect(c.read(batteryHealthProvider).segments.length, 1);
      });
    });

    test('empty seed gives zero segments', () {
      withHealth((async, c, v) {
        final notifier = c.read(batteryHealthProvider.notifier);
        notifier.seedSegments([]);
        expect(c.read(batteryHealthProvider).segments, isEmpty);
      });
    });
  });

  group('predictedRange toggle', () {
    test('trueRangeProvider still computes when toggle is off', () {
      withHealth((async, c, v) {
        c.listen(trueRangeProvider, (_, _) {});
        c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.predictedRange, false);
        async.elapse(const Duration(seconds: 1));
        final tr = c.read(trueRangeProvider);
        expect(tr.ridesUsed, 8, reason: 'data collection continues regardless of toggle');
        expect(tr.confidencePercent, 80);
        expect(c.read(ridingSettingsProvider).isOn(RidingFeature.predictedRange), isFalse);
      });
    });

    test('predictedRange defaults to true', () {
      withHealth((async, c, v) {
        expect(c.read(ridingSettingsProvider).isOn(RidingFeature.predictedRange), isTrue);
      });
    });
  });

  test('health snapshots store the pack voltage, not the bus voltage', () {
    fakeAsync((async) {
      final c = ProviderContainer(overrides: [batteryDiagnosticsProvider.overrideWith(_FixedDiagnostics.new)]);
      c.listen(batteryHealthProvider, (_, _) {});
      c.read(vehicleProvider.notifier).setSpeed(30);
      async.elapse(BatteryHealthNotifier.sampleInterval);
      expect(c.read(batteryHealthProvider).snapshots.last.packVoltage, 54.5);
      c.dispose();
    });
  });

  // Cell frames arrive every ~15 s; min/max/spread from a few
  // cells is not a reading of the pack.
  test('no health snapshot until every cell has reported', () {
    fakeAsync((async) {
      final c = ProviderContainer(overrides: [
        batteryDiagnosticsProvider.overrideWith(() => _FixedDiagnostics(cellsSeen: 4)),
      ]);
      c.listen(batteryHealthProvider, (_, _) {});
      c.read(vehicleProvider.notifier).setSpeed(30);
      async.elapse(BatteryHealthNotifier.sampleInterval * 3);
      expect(c.read(batteryHealthProvider).snapshots, isEmpty);
      c.dispose();
    });
  });
}

class _FixedDiagnostics extends BatteryDiagnosticsNotifier {
  _FixedDiagnostics({this.cellsSeen = 14});
  final int cellsSeen;

  @override
  BatteryDiagnostics build() => BatteryDiagnostics.compute(
        cellVoltages: [for (var i = 0; i < 14; i++) i < cellsSeen ? 3.9 : 0],
        temps: const [],
        busVoltage: 25.2,
        packVoltage: 54.5,
        batteryCurrent: 3,
      );
}
