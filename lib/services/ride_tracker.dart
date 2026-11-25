import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vehicle_data.dart';
import '../providers/mock_provider.dart';
import 'analytics_logger.dart';
import 'prefs_service.dart';

/// True between `ride.start` and `ride.end`. The learned-range history
/// closes a segment on this, so a ride with ten junction stops is one
/// segment, not ten.
final rideActiveProvider = NotifierProvider<RideActive, bool>(RideActive.new);

class RideActive extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool active) => state = active;
}

/// Brackets each trip with `ride.start` / `ride.end` so one app session
/// that covers five stops reads as five rides. A ride starts once the
/// scooter has covered [minDistanceM] since the motor came on: early
/// logs were full of 47-49 s, 0.0 km "rides" from unparking and
/// parking in place, and a throttle blip to 18 km/h moved it 10 m. The
/// distance is the speed integrated every [pollEvery], so it does not hang
/// on which HHMIS trip counter is mapped. The ride's clock, odometer and
/// SOC are taken from the motor-on that led to it.
///
/// It ends once the motor has been off for [endAfter], long enough that a
/// red light does not split a ride but folding the stand or plugging in
/// does, and at once on a lock or a scooter restart: neither is a pause,
/// and the head unit may lose power before [endAfter] runs out (one
/// ride never logged its end: restart 8 s after parking).
class RideTracker {
  RideTracker(
    this._container, {
    this.minDistanceM = 100,
    this.pollEvery = const Duration(seconds: 1),
    this.endAfter = const Duration(seconds: 30),
  });

  final ProviderContainer _container;
  final double minDistanceM;
  final Duration pollEvery;
  final Duration endAfter;

  ProviderSubscription<(VehicleState, int, bool, bool)>? _sub;
  Timer? _moveTimer;
  Timer? _endTimer;
  bool _inRide = false;
  int _rideSeq = 0;
  int _startedMicros = 0;
  double _movedM = 0;
  int _odoStart = 0;
  double _tripStart = 0;
  int _socStart = 0;
  int _topSpeed = 0;
  int _faultCount = 0;
  bool _faultActive = false;
  final Map<String, int> _modals = {};

  bool get inRide => _inRide;

  void start() {
    _rideSeq = PrefsService.getInt(PrefsKeys.rideSeq, 0);
    _sub = _container.listen(
      vehicleProvider.select((v) => (v.vehicleState, v.speed, v.faultActive, v.locked)),
      (_, next) => _onChange(next.$1.motorOn, next.$2, next.$3, next.$4),
    );
    AnalyticsLogger.instance.listeners.add(_onEvent);
    final v = _container.read(vehicleProvider);
    _onChange(v.vehicleState.motorOn, v.speed, v.faultActive, v.locked);
  }

  void stop() {
    _sub?.close();
    _sub = null;
    _moveTimer?.cancel();
    _endTimer?.cancel();
    AnalyticsLogger.instance.listeners.remove(_onEvent);
  }

  void _onEvent(String cat, String evt, Map<String, Object?> data) {
    if (!_inRide) return;
    if (cat == 'recovery' && evt == 'reboot_scooter') {
      _end(why: 'restart');
    } else if (cat == 'modal' && evt == 'show') {
      final name = '${data['name']}';
      _modals[name] = (_modals[name] ?? 0) + 1;
    }
  }

  void _onChange(bool motorOn, int speed, bool fault, bool locked) {
    if (speed > _topSpeed) _topSpeed = speed;
    if (!_inRide) {
      if (!motorOn) {
        _moveTimer?.cancel();
        _moveTimer = null;
      } else if (_moveTimer == null) {
        final v = _container.read(vehicleProvider);
        _startedMicros = AnalyticsLogger.instance.monoMicros;
        _movedM = 0;
        _odoStart = v.odometer;
        _tripStart = v.tripMeter;
        _socStart = v.batterySoc;
        _topSpeed = speed;
        _moveTimer = Timer.periodic(pollEvery, (_) => _poll());
      }
      return;
    }
    if (fault && !_faultActive) _faultCount++;
    _faultActive = fault;
    if (locked) {
      _end(why: 'lock');
    } else if (motorOn) {
      _endTimer?.cancel();
      _endTimer = null;
    } else {
      _endTimer ??= Timer(endAfter, () => _end(why: 'motor_off'));
    }
  }

  void _poll() {
    final v = _container.read(vehicleProvider);
    _movedM += v.speed * pollEvery.inMilliseconds / 3600;
    if (_movedM < minDistanceM) return;
    _moveTimer?.cancel();
    _moveTimer = null;
    _inRide = true;
    _rideSeq++;
    PrefsService.setInt(PrefsKeys.rideSeq, _rideSeq);
    _faultCount = 0;
    _faultActive = v.faultActive;
    _modals.clear();
    logEvent('ride', 'start', {'ride_seq': _rideSeq, 'started_at_odo_km': _odoStart, 'soc_start': _socStart});
    _container.read(rideActiveProvider.notifier).set(true);
  }

  void _end({required String why}) {
    _endTimer?.cancel();
    _endTimer = null;
    if (!_inRide) return;
    final v = _container.read(vehicleProvider);
    if (why == 'motor_off' && v.vehicleState.motorOn) return;
    _inRide = false;
    final durationS = (AnalyticsLogger.instance.monoMicros - _startedMicros) ~/ 1000000;
    final tripDelta = v.tripMeter - _tripStart;
    final distance = tripDelta >= 0 && tripDelta < 1000 ? tripDelta : (v.odometer - _odoStart).toDouble();
    final avg = durationS > 0 && distance > 0 ? (distance / (durationS / 3600)).round() : null;
    logEvent('ride', 'end', {
      'ride_seq': _rideSeq,
      'why': why,
      'duration_s': durationS,
      'distance_km': double.parse(distance.toStringAsFixed(2)),
      'soc_end': v.batterySoc,
      'top_speed': _topSpeed,
      'avg_speed': avg,
      'fault_count': _faultCount,
      'modal_count_by_name': Map<String, Object?>.from(_modals),
    });
    _container.read(rideActiveProvider.notifier).set(false);
  }
}
