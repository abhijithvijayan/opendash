import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/battery_diagnostics.dart';
import '../models/connection_health.dart';
import '../models/vehicle_data.dart' show VehicleState;
import '../services/can_host.dart';
import '../services/can_link.dart';
import 'grpc_diagnostics_provider.dart';
import 'mock_provider.dart';

final batteryDiagnosticsProvider = NotifierProvider<BatteryDiagnosticsNotifier, BatteryDiagnostics>(
  useAidlVehicle ? GrpcDiagnosticsNotifier.new : BatteryDiagnosticsNotifier.new,
);

/// Mock BMS telemetry, shaped on CAN bus captures from this scooter. Ticks
/// every few seconds with tiny jitter so the screen feels live without
/// being distracting. On the head unit `GrpcDiagnosticsNotifier` reads the
/// real pack over gRPC instead.
class BatteryDiagnosticsNotifier extends Notifier<BatteryDiagnostics> {
  static const tick = Duration(milliseconds: 2500);
  static const packLabels = ['Pack 1', 'Pack 2', 'Pack 3', 'Pack 4', 'Pack 5', 'Pack 6'];

  /// Resting figures; cell 7 runs a little low and cell 11 a little high,
  /// inside a healthy ~12mV spread.
  static const baseCells = [3.890, 3.892, 3.889, 3.893, 3.891, 3.889, 3.883, 3.892, 3.890, 3.888, 3.896, 3.891, 3.889, 3.891];
  static const basePackTemps = [32.0, 31.0, 33.0, 30.0, 32.0, 31.0];
  static const hotPackTemps = [52.0, 50.0, 54.0, 49.0, 53.0, 51.0];
  static const mcuTemp = 44.0;

  /// Diagnostics → Connections; only the gRPC notifier has one.
  GrpcHealth? get health => null;

  /// The bus log's and a raw recording's counts, as the link last gave them.
  final busLogStatus = ValueNotifier(const CanBusLogStatus());
  final rawStatus = ValueNotifier(const CanRawStatus());

  CanHost? _host;
  bool _hostDisposed = false;

  /// The mock has no bus: its link only keeps a raw recording's file.
  @protected
  CanHost createHost() => InProcessCanHost(onEvent: onCanEvent);

  @protected
  CanHost get canHost => _host ??= createHost();

  @protected
  bool get hostDisposed => _hostDisposed;

  /// The bus log (`BusLogNotifier`) and a raw recording
  /// (`RawRecordingNotifier`) run where the link does, and are driven
  /// through here.
  void send(CanCommand command) {
    if (!_hostDisposed) canHost.send(command);
  }

  @protected
  void disposeHost() {
    _hostDisposed = true;
    _host?.dispose();
  }

  @protected
  void onCanEvent(CanEvent event) {
    if (event is CanBusLogStatus) busLogStatus.value = event;
    if (event is CanRawStatus) rawStatus.value = event;
  }

  void reconnectNow() {}
  void onLifecyclePause() {}
  void onLifecycleResume() {}

  final _rng = math.Random(7);
  Timer? _timer;
  bool _degraded = false;
  bool _hot = false;
  bool _balancing = false;
  bool _overvoltage = false;
  bool _charging = false;
  double _balancingTemp = 29.0;
  int _motorTemp = 41;
  double _powerKw = 0;
  bool _healthGood = true;

  bool get degradedCells => _degraded;
  bool get hotPack => _hot;
  bool get balancing => _balancing;
  bool get overvoltage => _overvoltage;

  /// Resting draw with the motor off: lights, head unit, BMS.
  static const idleDrainA = 0.5;
  static const sohGood = 96.0;
  static const sohDegraded = 78.0;
  final List<double> _cellJitter = List.filled(14, 0);
  final List<double> _tempJitter = List.filled(6, 0);
  double _mcuJitter = 0;

  int _soc = 82;

  @override
  BatteryDiagnostics build() {
    ref.onDispose(() {
      _timer?.cancel();
      disposeHost();
    });
    final v = ref.read(vehicleProvider);
    _motorTemp = v.motorTemp;
    _powerKw = v.power;
    _healthGood = v.batteryHealthGood;
    _soc = v.batterySoc;
    _charging = v.vehicleState == VehicleState.charging;
    ref.listen(vehicleProvider.select((v) => (v.motorTemp, v.power, v.batteryHealthGood, v.batterySoc, v.vehicleState)),
        (_, next) {
      _motorTemp = next.$1;
      _powerKw = next.$2;
      _healthGood = next.$3;
      _soc = next.$4;
      _charging = next.$5 == VehicleState.charging;
      _publish();
    });
    _timer = Timer.periodic(tick, (_) => _jitter());
    return _compute();
  }

  void setDegradedCells(bool on) {
    _degraded = on;
    _publish();
  }

  void setHotPack(bool on) {
    _hot = on;
    _publish();
  }

  void setBalancing(bool on) {
    _balancing = on;
    _publish();
  }

  void setOvervoltage(bool on) {
    _overvoltage = on;
    _publish();
  }

  /// One step of ±1mV on the cells and ±0.1°C on the sensors, bounded so
  /// a healthy pack never drifts into uneven on its own.
  void _jitter() {
    for (var i = 0; i < 14; i++) {
      _cellJitter[i] = (_cellJitter[i] + (_rng.nextDouble() * 2 - 1) * 0.001).clamp(-0.003, 0.003);
    }
    for (var i = 0; i < 6; i++) {
      _tempJitter[i] = (_tempJitter[i] + (_rng.nextDouble() * 2 - 1) * 0.1).clamp(-0.5, 0.5);
    }
    _mcuJitter = (_mcuJitter + (_rng.nextDouble() * 2 - 1) * 0.1).clamp(-1.0, 1.0);
    // The balancing resistors heat while bleeding and cool when idle.
    final target = _balancing ? 46.0 : 29.0;
    _balancingTemp += (target - _balancingTemp) * 0.3;
    _publish();
  }

  double _cellVoltage(int i) {
    // Demo: one cell driven over the LG M50 max (red overvoltage).
    if (_overvoltage && i == 4) return 4.305;
    // A weak cell has more resistance than the rest: it sags further under
    // load (about 1.5 mV an amp here), which is what the warning watches.
    if (_degraded && i == 2) return 3.780 - 0.0015 * (_powerKw > 0 ? _powerKw * 1000 / 51.2 : 0);
    if (_degraded && i == 10) return 3.950;
    if (i == 6) {
      if (_soc < 8) return 2.90;
      if (_soc < 15) return 3.05;
      if (_soc < 25) return 3.15;
    }
    return baseCells[i];
  }

  void _publish() => state = _compute();

  BatteryDiagnostics _compute() {
    final cells = [
      for (var i = 0; i < 14; i++)
        _cellVoltage(i) + _cellJitter[i],
    ];
    final packTemps = _hot ? hotPackTemps : basePackTemps;
    final busVoltage = 51.2 + _cellJitter.reduce((a, b) => a + b);
    // Positive leaves the pack; regen and charging flow in.
    final current = _powerKw == 0 ? idleDrainA : _powerKw * 1000 / busVoltage;
    return BatteryDiagnostics.compute(
      cellVoltages: cells,
      temps: [
        for (var i = 0; i < 6; i++) PackTemperature(label: packLabels[i], tempC: packTemps[i] + _tempJitter[i]),
        PackTemperature(label: 'Controller', tempC: mcuTemp + _mcuJitter),
        PackTemperature(label: 'Motor', tempC: _motorTemp.toDouble()),
      ],
      soh: _healthGood ? sohGood : sohDegraded,
      busVoltage: busVoltage,
      packVoltage: busVoltage,
      batteryCurrent: double.parse(current.toStringAsFixed(1)),
      dischargeLimitW: 18000,
      regenLimitW: 3200,
      balancingActive: _balancing,
      balancingTemp: double.parse(_balancingTemp.toStringAsFixed(1)),
      cycleCount: 312,
      // Charge rate and ETAs only exist while charging (as on the scooter).
      chargingRatePercent: _charging ? 45 : null,
      etaSlowToFullMin: _charging ? 210 : null,
      etaFastToFullMin: _charging ? 95 : null,
      // The BMS bleeds the cells sitting above the pack average.
      balancingCells: _balancing
          ? [
              for (var i = 0; i < 14; i++)
                if (cells[i] > cells.reduce((a, b) => a + b) / 14) i + 1,
            ]
          : const [],
    );
  }
}
