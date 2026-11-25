/// Integrates pack power while the charger is connected. Current is
/// positive into the pack (the scooter's 0x140 and HHMIS
/// `FLOAT_VEHICLE_CURRENT`; negative is discharge), and only that counts:
/// with the charger left on after full, the head unit's own draw comes out
/// of the pack and is not charging. Each sample covers the seconds that
/// really passed since the last one; a gap longer than [maxGap] (the app
/// was held up, or the readings stalled) adds to the session's time but
/// not its energy, since nothing is known about it.
class ChargeEnergyTracker {
  static const maxGap = Duration(seconds: 5);

  double _energyWh = 0;
  double _peakPowerW = 0;
  double _elapsedS = 0;
  int _samples = 0;

  void sample(double voltageV, double currentA, double dtS) {
    if (dtS <= 0) return;
    _elapsedS += dtS;
    if (dtS > maxGap.inSeconds) return;
    final powerW = voltageV * currentA;
    if (currentA <= 0 || powerW <= 0) return;
    _energyWh += powerW * dtS / 3600;
    if (powerW > _peakPowerW) _peakPowerW = powerW;
    _samples++;
  }

  /// Time on the charger, without adding energy: a tick whose readings
  /// could not be trusted.
  void elapse(double dtS) {
    if (dtS > 0) _elapsedS += dtS;
  }

  /// Samples that carried charging power.
  int get samples => _samples;
  double get energyKwh => _energyWh / 1000;
  double get peakPowerKw => _peakPowerW / 1000;
  int get durationMinutes => _elapsedS ~/ 60;
  double get avgPowerKw => _elapsedS <= 0 ? 0 : _energyWh / (_elapsedS / 3600) / 1000;

  ChargeSessionSummary summary({required int startSoc, required int endSoc, required int timestamp}) =>
      ChargeSessionSummary(
        energyKwh: energyKwh,
        startSoc: startSoc,
        endSoc: endSoc,
        durationMinutes: durationMinutes,
        peakPowerKw: peakPowerKw,
        avgPowerKw: avgPowerKw,
        timestamp: timestamp,
      );
}

class ChargeSessionSummary {
  const ChargeSessionSummary({
    required this.energyKwh,
    required this.startSoc,
    required this.endSoc,
    required this.durationMinutes,
    required this.peakPowerKw,
    required this.avgPowerKw,
    required this.timestamp,
  });

  final double energyKwh;
  final int startSoc;
  final int endSoc;
  final int durationMinutes;
  final double peakPowerKw;
  final double avgPowerKw;

  /// Milliseconds since epoch, session end.
  final int timestamp;

  /// Full-pack kWh this charge implies: the energy put in over the SoC it
  /// covered. A real measurement of capacity, unlike the BMS SoH (which
  /// reads 100 on a worn pack). Null under a 20-point span, where the
  /// top-of-charge taper and SoC rounding make it unreliable.
  double? get impliedPackKwh {
    final span = endSoc - startSoc;
    return span >= 20 && energyKwh > 0 ? energyKwh / (span / 100) : null;
  }

  Map<String, Object> toJson() => {
        'energyKwh': energyKwh,
        'startSoc': startSoc,
        'endSoc': endSoc,
        'durationMinutes': durationMinutes,
        'peakPowerKw': peakPowerKw,
        'avgPowerKw': avgPowerKw,
        'timestamp': timestamp,
      };

  /// Null for anything that is not a well-typed summary.
  static ChargeSessionSummary? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final energy = raw['energyKwh'];
    final start = raw['startSoc'];
    final end = raw['endSoc'];
    final minutes = raw['durationMinutes'];
    final peak = raw['peakPowerKw'];
    final avg = raw['avgPowerKw'];
    final ts = raw['timestamp'];
    if (energy is! num || start is! int || end is! int || minutes is! int || peak is! num || avg is! num || ts is! int) {
      return null;
    }
    return ChargeSessionSummary(
      energyKwh: energy.toDouble(),
      startSoc: start,
      endSoc: end,
      durationMinutes: minutes,
      peakPowerKw: peak.toDouble(),
      avgPowerKw: avg.toDouble(),
      timestamp: ts,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChargeSessionSummary &&
      other.energyKwh == energyKwh &&
      other.startSoc == startSoc &&
      other.endSoc == endSoc &&
      other.durationMinutes == durationMinutes &&
      other.peakPowerKw == peakPowerKw &&
      other.avgPowerKw == avgPowerKw &&
      other.timestamp == timestamp;

  @override
  int get hashCode => Object.hash(energyKwh, startSoc, endSoc, durationMinutes, peakPowerKw, avgPowerKw, timestamp);
}
