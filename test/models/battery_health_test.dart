import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/battery_health.dart';
import 'package:opendash/models/vehicle_data.dart';

void main() {
  group('RideSegment', () {
    test('kmPerPercent computes distance per percent SOC', () {
      const seg = RideSegment(
        startSoc: 90,
        endSoc: 80,
        startOdometer: 10000,
        endOdometer: 19000,
        driveMode: 2,
        avgTempC: 30,
        timestamp: 1000000,
      );
      expect(seg.socUsed, 10);
      // Odometer values are km, not meters.
      expect(seg.distanceKm, 9000);
      expect(seg.kmPerPercent, 900);
    });

    test('kmPerPercent is zero when no SOC consumed', () {
      const seg = RideSegment(
        startSoc: 80,
        endSoc: 80,
        startOdometer: 10000,
        endOdometer: 10500,
        driveMode: 2,
        avgTempC: 30,
        timestamp: 1000000,
      );
      expect(seg.kmPerPercent, 0);
    });

    test('JSON round-trip preserves all fields', () {
      const seg = RideSegment(
        startSoc: 85.3,
        endSoc: 72.1,
        startOdometer: 11000,
        endOdometer: 22000,
        driveMode: 6,
        avgTempC: 29.5,
        timestamp: 1700000000,
      );
      final restored = RideSegment.fromJson(seg.toJson());
      expect(restored.startSoc, seg.startSoc);
      expect(restored.endSoc, seg.endSoc);
      expect(restored.startOdometer, seg.startOdometer);
      expect(restored.endOdometer, seg.endOdometer);
      expect(restored.driveMode, seg.driveMode);
      expect(restored.avgTempC, seg.avgTempC);
      expect(restored.timestamp, seg.timestamp);
    });
  });

  group('CellWarning', () {
    test('warning message matches severity', () {
      const w = CellWarning(weakCellIndex: 7, cellMinV: 3.6, spreadMv: 290, severity: CellWarningSeverity.warning);
      expect(w.message, contains('Cell 7'));
      expect(w.message, contains('0.29 V below'));
      expect(w.message, contains('under load'));
      expect(w.message, isNot(contains('critical')), reason: 'how close the battery is to cutting out is the battery\'s to say');

      const d = CellWarning(weakCellIndex: 3, cellMinV: 3.8, spreadMv: 70, severity: CellWarningSeverity.advisory);
      expect(d.message, contains('rests 0.07 V below'));
      expect(CellWarningSeverity.values, hasLength(2));
    });
  });

  group('driveModeIndex', () {
    test('round-trips through driveModeFromIndex', () {
      for (final mode in DriveMode.values) {
        final idx = driveModeIndex(mode);
        expect(driveModeFromIndex(idx), mode);
      }
    });
  });
  test('a measured distance round-trips; a stored segment without one uses the whole-km odometer', () {
    const measured = RideSegment(
      startSoc: 80, endSoc: 79, startOdometer: 33101, endOdometer: 33101,
      driveMode: 2, avgTempC: 30, timestamp: 1, distanceM: 740,
    );
    final back = RideSegment.fromJson(measured.toJson());
    expect(back.distanceM, 740);
    expect(back.distanceKm, closeTo(0.74, 1e-9));
    final legacy = RideSegment.fromJson({
      'startSoc': 80, 'endSoc': 75, 'startOdometer': 100, 'endOdometer': 106,
      'driveMode': 2, 'avgTempC': 30, 'timestamp': 1,
    });
    expect(legacy.distanceM, isNull);
    expect(legacy.distanceKm, 6);
  });
}
