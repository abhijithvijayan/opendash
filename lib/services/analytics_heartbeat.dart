import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vehicle_data.dart';
import '../providers/battery_diagnostics_provider.dart';
import '../providers/mock_provider.dart';
import 'analytics_logger.dart';

/// Transition events say what changed; the heartbeat says what the state
/// was, so a reader can reconstruct any moment. Every [idle] while parked,
/// every [active] while riding or charging. Consecutive identical
/// snapshots are coalesced: the next one that differs carries
/// `skipped_count`, and one is forced through every [maxSilence] so a long
/// idle still shows the app alive.
class AnalyticsHeartbeat {
  AnalyticsHeartbeat(this._container);

  static const active = Duration(seconds: 1);
  static const idle = Duration(seconds: 2);
  static const maxSilence = Duration(seconds: 10);

  /// On the charger the current wanders every second, so no two samples
  /// are alike and none was skipped: 3,500 lines an hour, 34 MB for one
  /// night, a quarter of all the log kept. A charge is slow;
  /// one sample every [charging] shows it, with every second kept for
  /// [chargeSettle] after the charging state changes (plug in, cut-off,
  /// top-up).
  // TODO(charging-log-rate): not yet seen on the charger. Check a night's log for size and for a cut-off that the
  // ten-second samples missed (battery.cells still lands on every charging state change).
  static const charging = Duration(seconds: 10);
  static const chargeSettle = Duration(seconds: 60);

  /// `battery.cells` cadence. On one charge the charger stopped at 98.75 %
  /// and the BMS snapped SOC to 100 % three seconds later; a high cell ending
  /// the charge (cell 4 was +181 mV) is the suspect, and the cells
  /// were nowhere in the log. One more line also lands on every charging
  /// state change, so the cut-off itself is captured.
  static const cellsWhileCharging = Duration(seconds: 5);
  static const cellsIdle = Duration(seconds: 60);

  final ProviderContainer _container;
  Timer? _timer;
  int _tick = 0;
  int? _lastHash;
  int _skipped = 0;
  int _lastEmitMicros = -1;
  int _cellsTick = 0;
  int _chargeChangedTick = -1000;
  ChargingState? _lastChargeState;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(active, (_) => _onTick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _onTick() {
    if (!AnalyticsLogger.instance.enabled) return;
    _tick++;
    final v = _container.read(vehicleProvider);
    _cellsTick++;
    final chargeChanged = _lastChargeState != null && v.chargingState != _lastChargeState;
    _lastChargeState = v.chargingState;
    final every = (v.isCharging ? cellsWhileCharging : cellsIdle).inSeconds ~/ active.inSeconds;
    if (chargeChanged || _cellsTick >= every) {
      _cellsTick = 0;
      logCells(chargeChanged ? 'charge_state' : 'periodic');
    }
    if (chargeChanged) _chargeChangedTick = _tick;
    final riding = v.vehicleState == VehicleState.riding;
    final settling = _tick - _chargeChangedTick < chargeSettle.inSeconds;
    if (!riding && v.isCharging && !settling) {
      if (_tick % charging.inSeconds != 0) return;
    } else if (!riding && !v.isCharging && _tick.isOdd) {
      return;
    }
    sample();
  }

  /// Highest / lowest cell and the spread, with the pack figures beside them.
  /// Nothing until all 14 cells have reported (R-12), and nothing on builds
  /// where the battery provider was never started.
  void logCells(String trigger) {
    if (!_container.read(batteryDiagnosticsProvider.exists)) return;
    final b = _container.read(batteryDiagnosticsProvider);
    if (b.cells.isEmpty || b.cellMaxV == null || b.cellMinV == null) return;
    final high = b.cells.reduce((a, c) => c.voltage > a.voltage ? c : a);
    final low = b.cells.reduce((a, c) => c.voltage < a.voltage ? c : a);
    final v = _container.read(vehicleProvider);
    logEvent('battery', 'cells', {
      'trigger': trigger,
      'soc': v.batterySoc,
      'raw_soc': v.rawBatterySoc,
      'charge_state': v.chargingState.name,
      'max_v': b.cellMaxV,
      'max_cell': high.index,
      'min_v': b.cellMinV,
      'min_cell': low.index,
      'spread_mv': b.cellSpreadMv,
      'avg_v': b.cellAvgV,
      'pack_v': b.packVoltage,
      'current_a': b.batteryCurrent,
      'balancing': b.balancingCells,
    });
  }

  /// One evaluation; the timer calls it on cadence, tests call it directly.
  void sample() {
    final snap = snapshot(_container.read(vehicleProvider));
    final hash = Object.hashAll(snap.values);
    final now = AnalyticsLogger.instance.monoMicros;
    final stale = _lastEmitMicros < 0 || now - _lastEmitMicros >= maxSilence.inMicroseconds;
    if (hash == _lastHash && !stale) {
      _skipped++;
      return;
    }
    logEvent('state', 'heartbeat', {...snap, 'skipped_count': _skipped});
    _skipped = 0;
    _lastHash = hash;
    _lastEmitMicros = now;
  }

  static Map<String, Object?> snapshot(VehicleData v) {
    final ctx = AnalyticsLogger.instance.context;
    return {
      'speed': v.speed,
      // Raw HHMIS units (`VehicleData.rpmUnit` rpm each), as logged since
      // the first build so rides stay comparable.
      'rpm': v.rpm,
      'soc': v.batterySoc,
      'raw_soc': v.rawBatterySoc,
      // Custom ride mode (MoveOS 5) keeps driveMode at the previous value,
      // so record it by name here instead of logging the stale one.
      'mode': v.customRideActive ? 'custom' : v.driveMode.name,
      'state': v.vehicleState.name,
      'lock': v.lockState,
      'stand': v.sideStand,
      'reverse': v.reverse,
      'hazard': v.hazard,
      'turn_left': v.turnLeft,
      'turn_right': v.turnRight,
      'low_beam': v.lowBeam,
      'high_beam': v.highBeam,
      'pos_light': v.positionLight,
      'cruise': v.cruiseMode.name,
      'power_kw': v.power,
      'bus_v': v.busVoltage,
      'pack_a': v.packCurrent,
      'battery_temp': v.batteryTemp,
      'motor_temp': v.motorTemp,
      'range_km': v.range,
      'trip_km': v.tripMeter,
      // The slider percent; `hhmis.volume` has the raw
      // STREAM_MUSIC index it was converted from.
      'volume': v.volume,
      'ambient': v.ambientBrightness,
      'ambient_known': v.ambientKnown,
      'ambient_usable': v.ambientUsable,
      'trunk_open': v.trunkOpen,
      'trunk_known': v.trunkStateKnown,
      'tamper': v.tamperDetected,
      'regen_avail': v.regenAvailabilityKnown ? v.regenAvailability : null,
      'regen_known': v.regenAvailabilityKnown,
      // Track the regen ceiling so the next ride shows
      // how often it drops to zero (dead telltale windows).
      'regen_limit_w': v.regenPowerLimitW,
      // The power bar's ceiling; never logged, so its real range (and
      // whether 12 kW is the healthy-pack value) is still unknown.
      'discharge_limit_w': v.dischargePowerLimitW,
      'fault': v.faultActive,
      'limp': v.limpMode,
      'charging': v.isCharging,
      'charge_state': v.chargingState.name,
      'charge_substate': v.chargeSubstate.name,
      'safe_to_unplug': v.safeToUnplug,
      'hhmis_up': v.hhmisConnected,
      'wifi': v.wifiConnected,
      'signal': v.signalBars,
      'grpc_dump': ctx['grpc_dump'] == true,
      'free_ram_mb': ctx['free_ram_mb'],
    };
  }
}
