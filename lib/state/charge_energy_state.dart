import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/charge_session.dart';
import '../providers/battery_diagnostics_provider.dart';
import '../providers/mock_provider.dart';
import '../providers/vehicle_provider.dart';
import '../services/analytics_logger.dart';
import '../services/prefs_service.dart';
import '../services/trusted_clock.dart';

class ChargeEnergyState {
  const ChargeEnergyState({
    this.currentKwh = 0,
    this.chargingPowerKw = 0,
    this.peakPowerKw = 0,
    this.history = const [],
    this.balancingActive = false,
    this.balancingCells = const [],
  });

  /// Running total for the session on the charger now.
  final double currentKwh;
  final double chargingPowerKw;
  final double peakPowerKw;

  /// Newest first, at most [ChargeEnergyNotifier.historyLength].
  final List<ChargeSessionSummary> history;
  final bool balancingActive;

  /// 1-indexed cells the BMS is bleeding down.
  final List<int> balancingCells;

  ChargeEnergyState copyWith({
    double? currentKwh,
    double? chargingPowerKw,
    double? peakPowerKw,
    List<ChargeSessionSummary>? history,
    bool? balancingActive,
    List<int>? balancingCells,
  }) =>
      ChargeEnergyState(
        currentKwh: currentKwh ?? this.currentKwh,
        chargingPowerKw: chargingPowerKw ?? this.chargingPowerKw,
        peakPowerKw: peakPowerKw ?? this.peakPowerKw,
        history: history ?? this.history,
        balancingActive: balancingActive ?? this.balancingActive,
        balancingCells: balancingCells ?? this.balancingCells,
      );
}

final chargeEnergyProvider = NotifierProvider<ChargeEnergyNotifier, ChargeEnergyState>(ChargeEnergyNotifier.new);

/// Integrates charger power once a second from the pack volts and amps the
/// vehicle reports, files a summary when the charger comes off, and keeps
/// the last ten sessions in prefs. Sampling is on its own timer rather than
/// on vehicle updates, because CAN pushes volts and amps many times a
/// second on hardware.
class ChargeEnergyNotifier extends Notifier<ChargeEnergyState> {
  static const historyLength = 10;
  static const sampleEvery = Duration(seconds: 1);

  ChargeEnergyTracker? _tracker;
  int _startSoc = 0;
  Timer? _timer;
  int _lastTickMicros = 0;

  @override
  ChargeEnergyState build() {
    ref.onDispose(_stopTimer);
    ref.listen(vehicleProvider.select((v) => v.isCharging), (_, charging) => charging ? _start() : _finish());
    ref.listen(
      batteryDiagnosticsProvider.select((d) => (d.balancingActive, d.balancingCells)),
      (_, b) => state = state.copyWith(balancingActive: b.$1, balancingCells: b.$2),
    );
    final diag = ref.read(batteryDiagnosticsProvider);
    // Seeded sessions are for the mock dashboard only; the scooter starts
    // with the sessions it has actually had.
    final seed = ref.read(vehicleProvider.notifier) is! AidlVehicleNotifier;
    final initial = ChargeEnergyState(
      history: _loadHistory(seed: seed),
      balancingActive: diag.balancingActive,
      balancingCells: diag.balancingCells,
    );
    if (ref.read(vehicleProvider).isCharging) {
      _startTracker();
    }
    return initial;
  }

  void _start() {
    _startTracker();
    state = state.copyWith(currentKwh: 0, chargingPowerKw: 0, peakPowerKw: 0);
  }

  void _startTracker() {
    _tracker = ChargeEnergyTracker();
    _startSoc = ref.read(vehicleProvider).batterySoc;
    _lastTickMicros = AnalyticsLogger.instance.monoMicros;
    _stopTimer();
    _timer = Timer.periodic(sampleEvery, (_) => tick());
  }

  /// One sample, over the time since the last one. Public so tests can
  /// drive it without the timer.
  void tick() {
    final t = _tracker;
    if (t == null) return;
    final now = AnalyticsLogger.instance.monoMicros;
    final dtS = (now - _lastTickMicros) / 1e6;
    _lastTickMicros = now;
    final v = ref.read(vehicleProvider);
    if (!packReadingsLive(ref.read(vehicleProvider.notifier), v)) {
      t.elapse(dtS);
      return;
    }
    // As in `EnergyUsed`: the pack voltage needs the CAN stream, the bus
    // voltage does not.
    final volts = v.packVoltage > 0 ? v.packVoltage : v.busVoltage;
    t.sample(volts, v.packCurrent, dtS);
    state = state.copyWith(
      currentKwh: t.energyKwh,
      chargingPowerKw: v.packCurrent > 0 ? volts * v.packCurrent / 1000 : 0,
      peakPowerKw: t.peakPowerKw,
    );
  }

  void _finish() {
    _stopTimer();
    final t = _tracker;
    _tracker = null;
    if (t != null && t.samples > 0) {
      final summary = t.summary(
        startSoc: _startSoc,
        endSoc: ref.read(vehicleProvider).batterySoc,
        timestamp: TrustedClock.now().millisecondsSinceEpoch,
      );
      final history = [summary, ...state.history].take(historyLength).toList();
      _saveHistory(history);
      state = state.copyWith(history: history, currentKwh: 0, chargingPowerKw: 0, peakPowerKw: 0);
    } else {
      state = state.copyWith(currentKwh: 0, chargingPowerKw: 0, peakPowerKw: 0);
    }
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  static List<ChargeSessionSummary> _loadHistory({required bool seed}) {
    final raw = PrefsService.getString(PrefsKeys.chargeHistory, '');
    if (raw.isNotEmpty) {
      try {
        final json = jsonDecode(raw);
        if (json is List) {
          final parsed = json.map(ChargeSessionSummary.fromJson).whereType<ChargeSessionSummary>().toList();
          if (parsed.isNotEmpty) return parsed.take(historyLength).toList();
        }
      } on FormatException {
        // fall through to the seeds
      }
    }
    return seed ? seedHistory() : const [];
  }

  static void _saveHistory(List<ChargeSessionSummary> history) =>
      PrefsService.setString(PrefsKeys.chargeHistory, jsonEncode([for (final s in history) s.toJson()]));

  /// Three plausible home-charger sessions so the list has something to
  /// show before the first real charge.
  static List<ChargeSessionSummary> seedHistory() {
    final now = DateTime.now();
    ChargeSessionSummary at(int daysAgo, int start, int end, double kwh, int minutes, double peak) =>
        ChargeSessionSummary(
          energyKwh: kwh,
          startSoc: start,
          endSoc: end,
          durationMinutes: minutes,
          peakPowerKw: peak,
          avgPowerKw: minutes == 0 ? 0 : kwh / (minutes / 60),
          timestamp: now.subtract(Duration(days: daysAgo, hours: 2)).millisecondsSinceEpoch,
        );
    return [
      at(0, 32, 98, 1.84, 48, 2.6),
      at(1, 15, 100, 2.31, 62, 2.6),
      at(3, 45, 80, 0.94, 28, 2.4),
    ];
  }
}

/// The pack's measured full capacity: the median of the implied full-pack
/// kWh of recent wide charges (`ChargeSessionSummary.impliedPackKwh`). A
/// real number for a worn pack, where the BMS SoH reads 100. Null until a
/// couple of wide charges have been seen.
final measuredCapacityProvider = Provider<double?>((ref) {
  final history = ref.watch(chargeEnergyProvider.select((s) => s.history));
  final kwh = [for (final s in history) s.impliedPackKwh].whereType<double>().toList()..sort();
  if (kwh.length < 2) return null;
  return kwh[kwh.length ~/ 2];
});
