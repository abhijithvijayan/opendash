import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mock_provider.dart';
import '../providers/vehicle_provider.dart';
import '../services/analytics_logger.dart';
import '../services/prefs_service.dart';
import '../services/trusted_clock.dart';

/// kWh drawn from the pack today, for the trip page's "kWh used".
final energyUsedProvider = NotifierProvider<EnergyUsedNotifier, double>(EnergyUsedNotifier.new);

/// No HHMIS key carries energy used (stock shows only Wh/km), so on the
/// scooter this integrates pack volts x amps once a second while the motor
/// is on, counting only what leaves the pack: regen has its own row. Each
/// sample covers the time measured since the last one, and none is taken
/// while neither HHMIS nor the CAN stream is delivering (`packReadingsLive`). Over
/// one logged ride the same sum on the heartbeats gives 393 Wh
/// out and 32 Wh back for 7.75 km and 10.9 % of SOC. The total is kept in
/// prefs with its date, so a restart mid-day keeps it and the first sample
/// of a new day starts from zero. The mock dashboard shows its own figure.
class EnergyUsedNotifier extends Notifier<double> {
  static const sampleEvery = Duration(seconds: 1);

  /// A longer wait between samples (the app was held up, or the readings
  /// stalled) is not integrated: nothing is known about it.
  static const maxGap = Duration(seconds: 5);

  Timer? _timer;
  double _wh = 0;
  String _day = '';
  int _lastTickMicros = 0;

  @override
  double build() {
    if (ref.read(vehicleProvider.notifier) is! AidlVehicleNotifier) {
      return ref.watch(vehicleProvider.select((v) => v.energyUsed));
    }
    ref.onDispose(() => _timer?.cancel());
    final saved = PrefsService.getString(PrefsKeys.energyUsedToday, '').split('|');
    _day = today();
    _wh = saved.length == 2 && saved[0] == _day ? double.tryParse(saved[1]) ?? 0 : 0;
    ref.listen(vehicleProvider.select((v) => v.vehicleState.motorOn), (_, on) => _run(on));
    _run(ref.read(vehicleProvider).vehicleState.motorOn);
    return _kwh;
  }

  /// Local calendar day; tests replace it to cross midnight.
  String Function() today = () {
    final now = TrustedClock.now();
    return '${now.year}-${now.month}-${now.day}';
  };

  double get _kwh => (_wh / 10).round() / 100;

  void _run(bool motorOn) {
    _timer?.cancel();
    _lastTickMicros = AnalyticsLogger.instance.monoMicros;
    _timer = motorOn ? Timer.periodic(sampleEvery, (_) => tick()) : null;
  }

  /// One sample, over the time since the last one. Public so tests can
  /// drive it without the timer.
  void tick() {
    final day = today();
    if (day != _day) {
      _day = day;
      _wh = 0;
    }
    final now = AnalyticsLogger.instance.monoMicros;
    final dtS = (now - _lastTickMicros) / 1e6;
    _lastTickMicros = now;
    final v = ref.read(vehicleProvider);
    if (dtS <= 0 || dtS > maxGap.inSeconds || !packReadingsLive(ref.read(vehicleProvider.notifier), v)) return;
    // Measured pack volts need the CAN stream; the bus voltage HHMIS sends
    // sits within 0.2 V of it while the motor is on.
    final volts = v.packVoltage > 0 ? v.packVoltage : v.busVoltage;
    if (v.packCurrent < 0) _wh += volts * -v.packCurrent * dtS / 3600;
    final kwh = _kwh;
    if (kwh == state) return;
    state = kwh;
    PrefsService.setString(PrefsKeys.energyUsedToday, '$_day|${_wh.toStringAsFixed(1)}');
  }
}
