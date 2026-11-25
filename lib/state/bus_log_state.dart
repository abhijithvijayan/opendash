import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import '../providers/battery_diagnostics_provider.dart';
import '../providers/mock_provider.dart';
import '../providers/vehicle_provider.dart';
import '../services/analytics_logger.dart';
import '../services/build_info.dart';
import '../services/can_link.dart';
import '../services/prefs_service.dart';
import '../services/trusted_clock.dart';

class BusLogStatus {
  const BusLogStatus({this.enabled = false, this.active = false, this.frames = 0, this.changed = 0, this.bursts = 0, this.path});
  final bool enabled;
  final bool active;
  final int frames;
  final int changed;
  final int bursts;
  final String? path;
}

/// The trusted wall clock minus the log's `mono`, for file names written
/// where `TrustedClock` is not (the bus worker); null while the clock
/// cannot be right.
int? wallClockOffsetMicros() =>
    TrustedClock.trusted ? TrustedClock.now().toUtc().microsecondsSinceEpoch - AnalyticsLogger.instance.monoMicros : null;

final busLogProvider = NotifierProvider<BusLogNotifier, BusLogStatus>(BusLogNotifier.new);

/// Settings → Developer → "Bus log" (`BusLog`): the whole bus while the
/// app is in front, for testing on a scooter OpenDash has not been checked
/// on. On by default ([enabledByDefault]) so every test build is logging
/// from the first boot; it stays on across restarts, and the switch turns
/// it off for good once set. While it is on the battery stream reads the
/// whole bus (the dump) instead of the fifteen frames it normally asks for.
///
/// What makes a burst: a command sent (not the ones the app sends on its
/// own, [quietTypes] and [quietNames]), a command refused, a fault, a ride
/// or a charge starting or ending, a recovery action, and an app start
/// after a crash.
// Run on the scooter for a real ride: the head unit stayed smooth (app.frames p95 ~3 ms
// build), but the whole-bus dump goes silent server-side about every 30 s. The fast dump-stall reopen in
// services/can_link.dart (dumpStallWindow) cuts the gap from ~20 s to ~3 s; bus.stats showed ~600
// frames/s captured on this bus. Identifier frames (VIN 0x689, MAC 0x696, serials 0x110, …) are masked at
// capture now (services/pii_frames.dart), so a plaintext VIN no longer reaches disk.
// TODO(bus-log): still open — whether the dump carries the frames the head unit itself sends (0x6BC): a
// command's burst shows it if it does.
class BusLogNotifier extends Notifier<BusLogStatus> {
  /// Logging is on from the first boot of a build nobody has ridden yet;
  /// the rider turns it off in Settings once the scooter is understood.
  static const enabledByDefault = true;

  static const statsEvery = Duration(seconds: 60);
  static const refreshEvery = Duration(seconds: 2);

  Timer? _stats;
  Timer? _refresh;

  /// Kept from [_start]: a provider cannot be read while this one is
  /// being disposed.
  BatteryDiagnosticsNotifier? _diag;
  bool _started = false;
  int _statsFrames = 0;
  int _statsChanged = 0;
  int _statsMicros = 0;

  @override
  BusLogStatus build() {
    ref.onDispose(() => _stop(log: false));
    ref.listen(vehicleProvider.select((v) => v.faultActive), (prev, next) {
      if (next && prev == false) _trigger('fault');
    });
    ref.listen(vehicleProvider.select((v) => v.isCharging), (prev, next) {
      if (prev != null && prev != next) _trigger(next ? 'charge_start' : 'charge_end');
    });
    final enabled = PrefsService.getBool(PrefsKeys.busLog, enabledByDefault);
    if (enabled) _start();
    return _status(enabled);
  }

  void setEnabled(bool on) {
    PrefsService.setBool(PrefsKeys.busLog, on);
    logEvent('bus', on ? 'enabled' : 'disabled', {});
    if (on) {
      _start();
    } else {
      _stop();
    }
    state = _status(on);
  }

  BusLogStatus _status(bool enabled) {
    final b = _diag?.busLogStatus.value ?? const CanBusLogStatus();
    return BusLogStatus(enabled: enabled, active: b.active, frames: b.frames, changed: b.changed, bursts: b.bursts, path: b.path);
  }

  void _onStatus() => state = _status(state.enabled);

  void _trigger(String reason) {
    if (_started) _diag?.send(CanBusLogTrigger(reason, AnalyticsLogger.instance.monoMicros));
  }

  void _start() {
    if (_started) return;
    // Only a real scooter has a bus to read; the mock dashboard (Chrome,
    // tests without an HHMIS override) has none, so there is nothing to log.
    if (ref.read(vehicleProvider.notifier) is! AidlVehicleNotifier) return;
    final logPath = AnalyticsLogger.instance.currentFilePath;
    final v = ref.read(vehicleProvider);
    final diag = ref.read(batteryDiagnosticsProvider.notifier);
    _diag?.busLogStatus.removeListener(_onStatus);
    _diag = diag;
    _started = true;
    // The log itself runs where the bus is read (`CanLink`).
    diag.send(CanBusLogStart(
      directoryPath: logPath == null ? null : File(logPath).parent.path,
      wallOffsetMicros: wallClockOffsetMicros(),
      header: {
        'version': appVersion,
        'build': BuildInfo.number,
        'git_sha': BuildInfo.gitSha,
        'vehicle_type': v.vehicleType,
        'moveos': v.moveOsVersion,
        'vehicle_software': v.vswVersion,
      },
    ));
    // After the start: its answer may come at once, while this is still being built.
    diag.busLogStatus.addListener(_onStatus);
    AnalyticsLogger.instance.listeners.add(_onEvent);
    _statsFrames = 0;
    _statsChanged = 0;
    _statsMicros = AnalyticsLogger.instance.monoMicros;
    _stats = Timer.periodic(statsEvery, (_) => _emitStats());
    _refresh = Timer.periodic(refreshEvery, (_) => diag.send(CanUpdateWallClock(wallClockOffsetMicros())));
    if (AnalyticsLogger.instance.recent('recovery', 'crash_count_restored').isNotEmpty) _trigger('crash_restart');
  }

  void _stop({bool log = true}) {
    _stats?.cancel();
    _stats = null;
    _refresh?.cancel();
    _refresh = null;
    if (!_started) return;
    _started = false;
    AnalyticsLogger.instance.listeners.remove(_onEvent);
    if (!log) _diag?.busLogStatus.removeListener(_onStatus);
    _diag?.send(CanBusLogStop(log: log));
  }

  /// What the head unit pays for the log: frames a second read off the
  /// bus, and how many of them changed and were written. Over the time
  /// between the two counts it has, which the link stamps.
  void _emitStats() {
    final diag = _diag;
    if (diag == null) return;
    diag.send(CanUpdateWallClock(wallClockOffsetMicros()));
    final b = diag.busLogStatus.value;
    final seconds = (b.atMicros - _statsMicros) / 1e6;
    if (seconds <= 0) return;
    logEvent('bus', 'stats', {
      'frames_s': ((b.frames - _statsFrames) / seconds).round(),
      'changed_s': ((b.changed - _statsChanged) / seconds).round(),
      'bursts': b.bursts,
    });
    _statsFrames = b.frames;
    _statsChanged = b.changed;
    _statsMicros = b.atMicros;
  }

  /// Sent on their own, many times a session (ten days of ride logs:
  /// 321 brightness, 114 media playing, 123 smart-light triggers): a burst
  /// for each would bury the commands a rider gave.
  static const quietTypes = {'setBrightness', 'mediaKey'};
  static const quietNames = {'btMediaPlaying', 'btCallActiveStatus', 'callStatus', 'projectLoaded', 'triggerSmartLight'};

  void _onEvent(String cat, String evt, Map<String, Object?> data) {
    final reason = switch ((cat, evt)) {
      ('hhmis', 'cmd_send') when !quietTypes.contains(data['type']) && !quietNames.contains(data['name']) => 'command',
      ('hhmis', 'cmd_result') when data['success'] == false => 'command_failed',
      ('ride', 'start') => 'ride_start',
      ('ride', 'end') => 'ride_end',
      ('state', 'fault_recorded') => 'fault',
      ('recovery', _) => 'recovery',
      _ => null,
    };
    if (reason != null) _trigger(reason);
  }
}
