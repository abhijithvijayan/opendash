import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/battery_health.dart';
import '../models/battery_diagnostics.dart';
import '../models/vehicle_data.dart';
import '../providers/battery_diagnostics_provider.dart';
import '../providers/mock_provider.dart';
import '../services/analytics_logger.dart';
import '../services/prefs_service.dart';
import '../services/ride_tracker.dart';
import '../services/trusted_clock.dart';

final batteryHealthProvider =
    NotifierProvider<BatteryHealthNotifier, BatteryHealthState>(BatteryHealthNotifier.new);

class BatteryHealthState {
  const BatteryHealthState({
    this.segments = const [],
    this.snapshots = const [],
    this.latestRawSoc = 0,
    this.cellWarning,
  });

  final List<RideSegment> segments;
  final List<BatteryHealthSnapshot> snapshots;
  final double latestRawSoc;
  final CellWarning? cellWarning;

  BatteryHealthState copyWith({
    List<RideSegment>? segments,
    List<BatteryHealthSnapshot>? snapshots,
    double? latestRawSoc,
    CellWarning? Function()? cellWarning,
  }) {
    return BatteryHealthState(
      segments: segments ?? this.segments,
      snapshots: snapshots ?? this.snapshots,
      latestRawSoc: latestRawSoc ?? this.latestRawSoc,
      cellWarning: cellWarning != null ? cellWarning() : this.cellWarning,
    );
  }
}

class BatteryHealthNotifier extends Notifier<BatteryHealthState> {
  Timer? _sampleTimer;
  bool _wasRiding = false;
  double _rideStartSoc = 0;
  int _rideStartOdometer = 0;
  int _rideStartOdometerM = 0;
  int _rideModeIndex = 2;
  final Map<int, int> _rideModeTicks = {};
  double _rideTempSum = 0;
  int _rideTempCount = 0;

  static const maxSegments = 20;
  static const sampleInterval = Duration(seconds: 5);

  /// Stored segments whose ends are closer than this, with odometer and SOC
  /// carrying on from one to the next, are pieces of one ride.
  static const mergeWithin = Duration(minutes: 10);

  /// The shortest ride kept when its distance is measured in metres.
  static const minMeasuredKm = 0.5;

  @override
  BatteryHealthState build() {
    ref.onDispose(() => _sampleTimer?.cancel());
    _sampleTimer = Timer.periodic(sampleInterval, (_) => _tick());
    // A segment is a ride as the RideTracker brackets it. Closing one each
    // time speed fell to 0 cut one ride (11.2 km, one
    // junction after another) into 7 + 1 + 3 km and dropped the rest, and
    // three rides counted as five towards the confidence figure.
    ref.listen(rideActiveProvider, (_, riding) => riding ? _onRideStart() : _onRideEnd(), fireImmediately: true);
    // Do not seed 8 invented rides on Android. Real
    // segments build up as the rider rides and are kept across restarts.
    // Until segments >= 3, estimateRange falls back to the vehicle's stock
    // range.
    final saved = _loadSegments();
    if (saved.isNotEmpty) logEvent('range', 'segments_loaded', {'count': saved.length});
    return BatteryHealthState(
      segments: saved.isNotEmpty || useAidlVehicle ? saved : _mockSeedSegments(),
    );
  }

  static List<RideSegment> _loadSegments() {
    final raw = PrefsService.getString(PrefsKeys.rideSegments, '');
    if (raw.isEmpty) return const [];
    try {
      final json = jsonDecode(raw);
      if (json is! List) return const [];
      final stored = [for (final j in json) RideSegment.fromJson(j as Map<String, dynamic>)];
      final out = mergeSplitSegments(stored);
      if (out.length != stored.length) logEvent('range', 'segments_merged', {'from': stored.length, 'to': out.length});
      return out.length > maxSegments ? out.sublist(out.length - maxSegments) : out;
    } catch (_) {
      // Malformed JSON or a wrong-typed field (fromJson casts): start empty
      // rather than estimate from half a history.
      return const [];
    }
  }

  /// Joins the pieces a ride was stored in by builds that closed a segment
  /// at every stop. The join spans any piece that was too short to store:
  /// its distance and its SOC both fall inside the gap.
  static List<RideSegment> mergeSplitSegments(List<RideSegment> segments) {
    final out = <RideSegment>[];
    for (final s in segments) {
      final p = out.isEmpty ? null : out.last;
      final odoGap = p == null ? -1 : s.startOdometer - p.endOdometer;
      final socGap = p == null ? 0.0 : p.endSoc - s.startSoc;
      if (p == null ||
          odoGap < 0 ||
          odoGap > 1 ||
          socGap < -0.5 ||
          socGap > 2 ||
          s.timestamp < p.timestamp ||
          s.timestamp - p.timestamp > mergeWithin.inSeconds) {
        out.add(s);
        continue;
      }
      final km = p.distanceKm + s.distanceKm;
      out.last = RideSegment(
        startSoc: p.startSoc,
        endSoc: s.endSoc,
        startOdometer: p.startOdometer,
        endOdometer: s.endOdometer,
        driveMode: s.distanceKm > p.distanceKm ? s.driveMode : p.driveMode,
        avgTempC: km > 0 ? (p.avgTempC * p.distanceKm + s.avgTempC * s.distanceKm) / km : p.avgTempC,
        timestamp: s.timestamp,
        distanceM: p.distanceM != null && s.distanceM != null ? p.distanceM! + s.distanceM! : null,
      );
    }
    return out;
  }

  static List<RideSegment> _mockSeedSegments() {
    // Distances are kilometres, not metres.
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    const day = 86400;
    return [
      RideSegment(startSoc: 95.0, endSoc: 81.5, startOdometer: 10200, endOdometer: 10200 + 20, driveMode: 6, avgTempC: 29, timestamp: now - day * 8),
      RideSegment(startSoc: 88.0, endSoc: 76.2, startOdometer: 10700, endOdometer: 10700 + 17, driveMode: 6, avgTempC: 31, timestamp: now - day * 7),
      RideSegment(startSoc: 90.0, endSoc: 78.5, startOdometer: 11000, endOdometer: 11000 + 10, driveMode: 2, avgTempC: 32, timestamp: now - day * 6),
      RideSegment(startSoc: 82.0, endSoc: 71.8, startOdometer: 11200, endOdometer: 11200 + 9, driveMode: 2, avgTempC: 33, timestamp: now - day * 5),
      RideSegment(startSoc: 78.0, endSoc: 67.2, startOdometer: 11500, endOdometer: 11500 + 8, driveMode: 3, avgTempC: 34, timestamp: now - day * 4),
      RideSegment(startSoc: 85.0, endSoc: 73.5, startOdometer: 11800, endOdometer: 11800 + 8, driveMode: 3, avgTempC: 32, timestamp: now - day * 3),
      RideSegment(startSoc: 72.0, endSoc: 63.8, startOdometer: 12000, endOdometer: 12000 + 5, driveMode: 7, avgTempC: 35, timestamp: now - day * 2),
      RideSegment(startSoc: 90.0, endSoc: 82.1, startOdometer: 12100, endOdometer: 12100 + 4, driveMode: 7, avgTempC: 33, timestamp: now - day * 1),
    ];
  }

  void seedSegments(List<RideSegment> segments) {
    state = state.copyWith(segments: segments);
  }

  void _tick() {
    final v = ref.read(vehicleProvider);
    final d = ref.read(batteryDiagnosticsProvider);
    final rawSoc = v.rawBatterySoc > 0 ? v.rawBatterySoc : v.batterySoc.toDouble();

    state = state.copyWith(latestRawSoc: rawSoc);

    // Cell frames arrive every ~15 s, so early in a ride min/max/spread would
    // be computed from a few cells; such a snapshot would read as a pack
    // that looks healthier (or worse) than it is.
    final cellsComplete = d.cells.isNotEmpty && d.cells.every((c) => c.state != CellState.missing);
    if (v.speed > 0) {
      _rideTempSum += v.batteryTemp;
      _rideTempCount++;
      _rideModeIndex = driveModeIndex(v.driveMode);
      _rideModeTicks[_rideModeIndex] = (_rideModeTicks[_rideModeIndex] ?? 0) + 1;
    }
    if (v.speed > 0 && cellsComplete) {
      final snap = BatteryHealthSnapshot(
        timestamp: TrustedClock.now().millisecondsSinceEpoch ~/ 1000,
        soc: v.batterySoc,
        rawSoc: rawSoc,
        odometer: v.odometer,
        cellMin: d.cellMinV ?? 0,
        cellMax: d.cellMaxV ?? 0,
        cellSpreadMv: d.cellSpreadMv ?? 0,
        packVoltage: d.packVoltage ?? 0,
        currentA: d.batteryCurrent ?? 0,
        tempC: v.batteryTemp.toDouble(),
        driveMode: _rideModeIndex,
      );
      final snaps = [...state.snapshots, snap];
      if (snaps.length > 100) snaps.removeRange(0, snaps.length - 100);
      state = state.copyWith(snapshots: snaps);
    }

    _updateCellWarning(v, d);
  }

  /// The resting gap between the strongest and the weakest cell worth a
  /// line on the battery page. A healthy pack rests within a few tens of
  /// millivolts; the test scooter's, with its known weak cell 3, rests 240 to
  /// 320 mV apart. A resting gap is a fact about the pack, there all day:
  /// it is not what the status bar warns about.
  // TODO(weak-cell): this and the constants below were tuned on one pack (cell 3 of the test scooter's). A per-amp rule
  // would carry to other packs; it needs data from more than one.
  static const driftSpreadMv = 60.0;

  /// What the status bar warns about is the weak cell giving way under
  /// load, while it is happening: the gap opening this much wider than it
  /// is at rest. The test scooter's pack once went from 300 mV at rest to
  /// 442 mV at 113 A, and stayed within 25 mV of rest at half that draw. No
  /// cell voltage is compared with a fixed number anywhere: where a pack
  /// cuts out differs (packs are seen at 2.8 V a cell in normal use), and
  /// that is the battery's to say (`VehicleData.batteryAtLimit`).
  static const strainExtraMv = 100.0;

  /// "At rest": under this much current either way.
  static const restCurrentA = 10.0;

  /// The resting gap is not learned below this charge: near empty the
  /// cells of any pack pull apart.
  static const cellJudgeMinSoc = 20;

  /// A resting gap has to hold for this many samples in a row before it
  /// is believed (one sample every [sampleInterval]).
  static const cellSettleReadings = 2;

  /// The warning stays for this many samples after the last strained one,
  /// so it does not blink with each burst of throttle, and then goes.
  static const strainHoldReadings = 4;

  bool? _restDrift;
  int _restReadings = 0;
  double? _restSpreadMv;
  CellWarning? _rest;
  CellWarning? _strain;
  int _strainLeft = 0;

  void _updateCellWarning(VehicleData v, BatteryDiagnostics d) {
    final cellMin = d.cellMinV;
    final spread = d.cellSpreadMv;
    final current = d.batteryCurrent;
    if (cellMin == null || spread == null || current == null) {
      if (state.cellWarning != null) state = state.copyWith(cellWarning: () => null);
      _strain = null;
      _strainLeft = 0;
      return;
    }
    final before = state.cellWarning?.severity;
    if (current.abs() <= restCurrentA) {
      // At rest: learn the resting gap; a strain that has passed runs out.
      if (v.batterySoc >= cellJudgeMinSoc) {
        final drift = spread >= driftSpreadMv;
        if (drift != _restDrift) {
          _restDrift = drift;
          _restReadings = 0;
        }
        if (++_restReadings >= cellSettleReadings) {
          _restSpreadMv = spread;
          _rest = drift
              ? CellWarning(weakCellIndex: _findWeakCell(d), cellMinV: cellMin, spreadMv: spread, severity: CellWarningSeverity.advisory)
              : null;
        }
      }
      if (_strainLeft > 0) _strainLeft--;
    } else if (v.power > 0) {
      // The motor is drawing: is the weak cell falling away from the rest?
      // (Not while charging or regenerating, when the gap moves for other
      // reasons. By the motor's power, not the current's sign.)
      final rest = _restSpreadMv;
      if (rest != null && spread - rest >= strainExtraMv) {
        _strain = CellWarning(weakCellIndex: _findWeakCell(d), cellMinV: cellMin, spreadMv: spread, severity: CellWarningSeverity.warning);
        _strainLeft = strainHoldReadings;
      } else if (_strainLeft > 0) {
        _strainLeft--;
      }
    }
    final shown = _strainLeft > 0 ? _strain : _rest;
    if (shown?.severity != before || shown?.weakCellIndex != state.cellWarning?.weakCellIndex) {
      if (shown?.severity != before) {
        logEvent('battery', 'cell_warning', {
          'level': shown?.severity.name,
          'cell': shown?.weakCellIndex,
          'spread_mv': spread.round(),
          'rest_mv': _restSpreadMv?.round(),
          'current_a': current.round(),
          'soc': v.batterySoc,
        });
      }
      state = state.copyWith(cellWarning: () => shown);
    }
  }

  int _findWeakCell(BatteryDiagnostics d) {
    if (d.cells.isEmpty) return 0;
    var minV = double.infinity;
    var idx = 1;
    for (final c in d.cells) {
      if (c.voltage > 0 && c.voltage < minV) {
        minV = c.voltage;
        idx = c.index;
      }
    }
    return idx;
  }

  void _onRideStart() {
    final v = ref.read(vehicleProvider);
    _wasRiding = true;
    _rideStartSoc = v.rawBatterySoc > 0 ? v.rawBatterySoc : v.batterySoc.toDouble();
    _rideStartOdometer = v.odometer;
    _rideStartOdometerM = v.odometerM;
    _rideModeIndex = driveModeIndex(v.driveMode);
    _rideModeTicks.clear();
    _rideTempSum = 0;
    _rideTempCount = 0;
  }

  /// The mode most of the ride's moving time was spent in; a whole ride
  /// often crosses modes and the estimate weights by this.
  int _rideMode() {
    var best = _rideModeIndex;
    var most = 0;
    _rideModeTicks.forEach((mode, ticks) {
      if (ticks > most) {
        best = mode;
        most = ticks;
      }
    });
    return best;
  }

  void _onRideEnd() {
    if (!_wasRiding) return;
    _wasRiding = false;
    final v = ref.read(vehicleProvider);
    final endSoc = v.rawBatterySoc > 0 ? v.rawBatterySoc : v.batterySoc.toDouble();
    final socUsed = _rideStartSoc - endSoc;
    // The CAN odometer in metres when both ends had it; otherwise HHMIS's
    // whole km, where a ride under 1 km cannot be
    // told from none.
    final measured = _rideStartOdometerM > 0 && v.odometerM >= _rideStartOdometerM;
    final distanceM = measured ? v.odometerM - _rideStartOdometerM : null;
    final distanceKm = distanceM != null ? distanceM / 1000 : (v.odometer - _rideStartOdometer).toDouble();
    if (socUsed < 0.5 || distanceKm < (measured ? minMeasuredKm : 1)) return;

    final segment = RideSegment(
      startSoc: _rideStartSoc,
      endSoc: endSoc,
      startOdometer: _rideStartOdometer,
      endOdometer: v.odometer,
      driveMode: _rideMode(),
      avgTempC: _rideTempCount > 0 ? _rideTempSum / _rideTempCount : v.batteryTemp.toDouble(),
      timestamp: TrustedClock.now().millisecondsSinceEpoch ~/ 1000,
      distanceM: distanceM,
    );

    final segments = [...state.segments, segment];
    if (segments.length > maxSegments) segments.removeRange(0, segments.length - maxSegments);
    state = state.copyWith(segments: segments);
    PrefsService.setString(PrefsKeys.rideSegments, jsonEncode([for (final s in segments) s.toJson()]));
    logEvent('range', 'segment_saved', {
      'km': double.parse(segment.distanceKm.toStringAsFixed(2)),
      'measured': measured,
      'soc_used': double.parse(segment.socUsed.toStringAsFixed(1)),
      'mode': segment.driveMode,
      'count': segments.length,
    });
  }

  TrueRange estimateRange({
    required int currentSoc,
    required double rawSoc,
    required DriveMode driveMode,
    required int stockRange,
  }) {
    final segments = state.segments;
    if (segments.length < 3) {
      return TrueRange(
        stockRangeKm: stockRange,
        trueRangeKm: stockRange,
        confidencePercent: segments.length * 10,
        kmPerPercent: 0,
        ridesUsed: segments.length,
      );
    }

    final modeIdx = driveModeIndex(driveMode);
    double weightedSum = 0;
    double weightTotal = 0;
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      if (seg.kmPerPercent <= 0) continue;
      // By distance as well as recency: the odometer is whole km, so a
      // 1 km segment is really 0.1 to 1.9 km and should not count like
      // a 20 km one.
      double weight = (i + 1) / segments.length * seg.distanceKm;
      if (seg.driveMode == modeIdx) weight *= 2;
      weightedSum += seg.kmPerPercent * weight;
      weightTotal += weight;
    }

    if (weightTotal == 0) {
      return TrueRange(
        stockRangeKm: stockRange,
        trueRangeKm: stockRange,
        confidencePercent: 0,
        kmPerPercent: 0,
        ridesUsed: segments.length,
      );
    }

    final kmPP = weightedSum / weightTotal;
    final effectiveSoc = rawSoc > 0 ? rawSoc : currentSoc.toDouble();
    final trueRange = (effectiveSoc * kmPP).round();
    final confidence = (segments.length * 10).clamp(0, 100);

    return TrueRange(
      stockRangeKm: stockRange,
      trueRangeKm: trueRange,
      confidencePercent: confidence,
      kmPerPercent: kmPP,
      ridesUsed: segments.length,
    );
  }
}

final trueRangeProvider = Provider<TrueRange>((ref) {
  final health = ref.watch(batteryHealthProvider);
  final healthNotifier = ref.read(batteryHealthProvider.notifier);
  final vehicle = ref.watch(vehicleProvider);
  return healthNotifier.estimateRange(
    currentSoc: vehicle.batterySoc,
    rawSoc: health.latestRawSoc,
    driveMode: vehicle.driveMode,
    stockRange: vehicle.range,
  );
});

final cellWarningProvider = Provider<CellWarning?>((ref) {
  return ref.watch(batteryHealthProvider.select((s) => s.cellWarning));
});
