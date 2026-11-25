import 'vehicle_data.dart';

class BatteryHealthSnapshot {
  const BatteryHealthSnapshot({
    required this.timestamp,
    required this.soc,
    required this.rawSoc,
    required this.odometer,
    required this.cellMin,
    required this.cellMax,
    required this.cellSpreadMv,
    required this.packVoltage,
    required this.currentA,
    required this.tempC,
    required this.driveMode,
  });

  final int timestamp;
  final int soc;
  final double rawSoc;
  final int odometer;
  final double cellMin;
  final double cellMax;
  final double cellSpreadMv;
  final double packVoltage;
  final double currentA;
  final double tempC;
  final int driveMode;
}

class RideSegment {
  const RideSegment({
    required this.startSoc,
    required this.endSoc,
    required this.startOdometer,
    required this.endOdometer,
    required this.driveMode,
    required this.avgTempC,
    required this.timestamp,
    this.distanceM,
  });

  final double startSoc;
  final double endSoc;
  final int startOdometer;
  final int endOdometer;
  final int driveMode;
  final double avgTempC;
  final int timestamp;

  /// Metres covered by the CAN odometer (0x356), when both ends of the
  /// ride had it. Null for segments stored before it was read, or a ride
  /// without the CAN stream: [distanceKm] then falls back to the whole-km
  /// odometer, which is 0.1 to 1.9 km for a "1 km" ride.
  final int? distanceM;

  double get socUsed => startSoc - endSoc;

  /// [startOdometer] and [endOdometer] are whole km.
  double get distanceKm => distanceM != null ? distanceM! / 1000 : (endOdometer - startOdometer).toDouble();
  double get kmPerPercent => socUsed > 0 ? distanceKm / socUsed : 0;

  Map<String, dynamic> toJson() => {
        'startSoc': startSoc,
        'endSoc': endSoc,
        'startOdometer': startOdometer,
        'endOdometer': endOdometer,
        'driveMode': driveMode,
        'avgTempC': avgTempC,
        'timestamp': timestamp,
        if (distanceM != null) 'distanceM': distanceM,
      };

  factory RideSegment.fromJson(Map<String, dynamic> j) => RideSegment(
        startSoc: (j['startSoc'] as num).toDouble(),
        endSoc: (j['endSoc'] as num).toDouble(),
        startOdometer: j['startOdometer'] as int,
        endOdometer: j['endOdometer'] as int,
        driveMode: j['driveMode'] as int,
        avgTempC: (j['avgTempC'] as num).toDouble(),
        timestamp: j['timestamp'] as int,
        distanceM: j['distanceM'] as int?,
      );
}

class TrueRange {
  const TrueRange({
    required this.stockRangeKm,
    required this.trueRangeKm,
    required this.confidencePercent,
    required this.kmPerPercent,
    required this.ridesUsed,
  });

  final int stockRangeKm;
  final int trueRangeKm;
  final int confidencePercent;
  final double kmPerPercent;
  final int ridesUsed;

  static const fallback = TrueRange(
    stockRangeKm: 0,
    trueRangeKm: 0,
    confidencePercent: 0,
    kmPerPercent: 0,
    ridesUsed: 0,
  );
}

/// How far one cell is from the rest. There is no "critical": whether the
/// battery is about to cut power is the battery's to say
/// (`VehicleData.batteryAtLimit`), not a voltage picked here.
enum CellWarningSeverity { advisory, warning }

/// One cell sits below the others. `advisory`: the gap with the pack at
/// rest, a standing fact shown on the battery page. `warning`: under load
/// that cell is falling away from the rest right now, which is what the
/// status bar says while it happens. Never a voltage against a fixed
/// number (see `BatteryHealthNotifier.strainExtraMv`).
class CellWarning {
  const CellWarning({
    required this.weakCellIndex,
    required this.cellMinV,
    required this.spreadMv,
    required this.severity,
  });

  final int weakCellIndex;
  final double cellMinV;

  /// Strongest cell minus weakest, when this was judged.
  final double spreadMv;
  final CellWarningSeverity severity;

  String get _gap => '${(spreadMv / 1000).toStringAsFixed(2)} V';

  String get message => switch (severity) {
        CellWarningSeverity.warning =>
          'Cell $weakCellIndex is sagging under load ($_gap below the strongest). Ease off: hard acceleration drains it first',
        CellWarningSeverity.advisory => 'Cell $weakCellIndex rests $_gap below the strongest',
      };
}

int driveModeIndex(DriveMode mode) => switch (mode) {
      DriveMode.eco => 6,
      DriveMode.normal => 2,
      DriveMode.sport => 3,
      DriveMode.hyper => 7,
    };

DriveMode driveModeFromIndex(int i) => switch (i) {
      6 => DriveMode.eco,
      3 => DriveMode.sport,
      7 => DriveMode.hyper,
      _ => DriveMode.normal,
    };
