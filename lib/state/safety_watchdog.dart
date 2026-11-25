import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vehicle_data.dart';
import '../providers/mock_provider.dart';
import '../providers/vehicle_provider.dart';
import '../services/analytics_logger.dart';
import 'apps_state.dart';
import 'prompt_surface.dart';
import 'riding_lockout.dart';
import 'riding_settings.dart';

/// Since MoveOS 4.0.4 the scooter stays in ride mode, throttle live, when
/// the side stand goes down *during* a ride and the rider then rolls to a
/// stop. The stock VCU still parks correctly when the rider stops first and
/// puts the stand down after, so this watchdog arms only for the former
/// case: the stand must have come down while the scooter was moving.
/// A blocking modal counts down [delay] and then sends Lock_Now. The rider
/// can cancel; the countdown then stays off until the condition clears
/// (stand up, or a new ride) and recurs.
///
/// "Stopped" has to be proven (`VehicleData.provenStopped`): a speed frozen
/// at 0 by a silent HHMIS would otherwise lock a moving scooter. Losing the
/// proof mid-countdown cancels it; it starts over when the data is back.
///
/// The countdown is a prompt, so it runs only where the rider can see it and
/// tap "Keep riding" (`promptSurfaceVisibleProvider`). With another app in
/// front, phone projection included, the dashboard is brought forward first
/// and the full countdown starts once it is there; if it does not get there
/// within [frontBound] nothing is locked. Losing the surface mid-countdown
/// cancels it, and it starts over in full on the way back.
///
/// A rider with a broken stand sensor can bypass it (the side stand sensor
/// toggle in riding settings); the watchdog then stays disarmed, since a
/// stuck sensor would otherwise park the scooter at every red light.
///
/// Auto-lock behaviour is gated by `RidingSettings.autoLockEnabled`, defaulting
/// off. A device test on the scooter proved the VCU
/// on this firmware ignores an unsolicited `Lock_Now 0x54`: the modal cleared
/// on timeout, the scooter never engaged ESCL, and the throttle stayed live.
/// The settings toggle lets a rider opt in once they've verified it works on
/// their own firmware; once the echo-waiting modal pattern lands (wait up to
/// 2 s for `BOOL_VEHICLE_ESCL_STATUS = 3`, show "Lock failed" on timeout),
/// the default should flip to on.
final safetyWatchdogProvider =
    NotifierProvider<SafetyWatchdog, SafetyWatchdogState>(SafetyWatchdog.new);

class SafetyWatchdogState {
  const SafetyWatchdogState({
    this.armed = false,
    this.remainingSeconds = 0,
    this.awaitingLock = false,
    this.retryAttempt = 0,
  });
  final bool armed;
  final int remainingSeconds;

  /// True from the moment the watchdog fires Lock_Now until the vehicle
  /// confirms (pendingLock cleared and no latched failure) or the rider
  /// chooses "Keep riding" on the failed state.
  final bool awaitingLock;

  /// 0 for the first autoPark, 1 after the first retry, and so on.
  final int retryAttempt;

  SafetyWatchdogState copyWith({
    bool? armed,
    int? remainingSeconds,
    bool? awaitingLock,
    int? retryAttempt,
  }) =>
      SafetyWatchdogState(
        armed: armed ?? this.armed,
        remainingSeconds: remainingSeconds ?? this.remainingSeconds,
        awaitingLock: awaitingLock ?? this.awaitingLock,
        retryAttempt: retryAttempt ?? this.retryAttempt,
      );

  @override
  bool operator ==(Object other) =>
      other is SafetyWatchdogState &&
      other.armed == armed &&
      other.remainingSeconds == remainingSeconds &&
      other.awaitingLock == awaitingLock &&
      other.retryAttempt == retryAttempt;

  @override
  int get hashCode => Object.hash(armed, remainingSeconds, awaitingLock, retryAttempt);
}

class SafetyWatchdog extends Notifier<SafetyWatchdogState> {
  static const delay = Duration(seconds: 5);

  /// `bringToFront` to resumed took 50-200 ms in a ride log (the
  /// return pill uses the same call); past this it has failed.
  static const frontBound = Duration(seconds: 3);
  Timer? _timer;
  Timer? _frontWait;

  /// One request per stand episode: an app that keeps the foreground is not
  /// fought for it.
  bool _frontRequested = false;
  int _remaining = 0;
  bool _sensorOn = true;
  bool _standCondition = false;
  bool _cancelled = false;
  bool _droppedWhileMoving = false;
  bool _autoLockEnabled = false;

  static bool standCondition(VehicleData v) => v.provenStopped && v.sideStand && v.vehicleState.motorOn;

  @override
  SafetyWatchdogState build() {
    ref.onDispose(() {
      _timer?.cancel();
      _frontWait?.cancel();
    });
    final settings = ref.read(ridingSettingsProvider);
    _sensorOn = settings.isOn(RidingFeature.sideStandCutOff);
    _autoLockEnabled = settings.autoLockEnabled;
    final initial = ref.read(vehicleProvider);
    _standCondition = standCondition(initial);
    _droppedWhileMoving = initial.sideStand && initial.speed > 0;
    ref.listen(
      vehicleProvider.select((v) => (v.sideStand, v.speed > 0, v.vehicleState.motorOn)),
      (_, next) {
        final (stand, moving, motorOn) = next;
        if (stand && moving) _droppedWhileMoving = true;
        if (!stand || !motorOn) _droppedWhileMoving = false;
      },
    );
    ref.listen(vehicleProvider.select(standCondition), (_, on) {
      _standCondition = on;
      // "Keep riding" lasts until the stand or the speed really changes; a
      // data hiccup must not bring the countdown back.
      final v = ref.read(vehicleProvider);
      final onlyTrustLost = v.speed == 0 && !v.speedTrusted && v.sideStand && v.vehicleState.motorOn;
      if (!on && !onlyTrustLost) {
        _cancelled = false;
        _frontRequested = false;
      }
      _recheck();
    });
    ref.listen(promptSurfaceVisibleProvider, (_, visible) {
      if (!visible && _timer != null) {
        untrustedCancel(ref, ref.read(vehicleProvider), 'auto_park');
        _disarm(noPromptSurfaceReason);
      }
      _recheck();
    });
    ref.listen(ridingSettingsProvider.select((r) => r.isOn(RidingFeature.sideStandCutOff)), (_, on) {
      _sensorOn = on;
      _recheck();
    });
    ref.listen(ridingSettingsProvider.select((r) => r.autoLockEnabled), (_, on) {
      _autoLockEnabled = on;
      _recheck();
    });
    // While awaitingLock, mirror pendingLock / lockFailedAtMicros from the
    // vehicle into the modal so its state (Locking… vs Failed) tracks
    // reality. The confirm path clears pendingLock without a failure.
    ref.listen(
      vehicleProvider.select((v) => (v.pendingLock != null, v.lockFailedAtMicros != null)),
      (_, next) {
        if (!state.awaitingLock) return;
        final (pending, failed) = next;
        if (!pending && !failed) {
          // Lock confirmed; the modal goes away.
          logEvent('safety', 'auto_park_confirmed', {'retry': state.retryAttempt});
          state = state.copyWith(awaitingLock: false, retryAttempt: 0);
        }
      },
    );
    if (_sensorOn && _standCondition && _droppedWhileMoving && _autoLockEnabled) {
      if (!ref.read(promptSurfaceVisibleProvider)) {
        _awaitSurface();
        return const SafetyWatchdogState();
      }
      _start();
      return SafetyWatchdogState(armed: true, remainingSeconds: _remaining);
    }
    return const SafetyWatchdogState();
  }

  void _awaitSurface() {
    if (_frontRequested) return;
    _frontRequested = true;
    ref.read(appManagerProvider.notifier).returnForPrompt('auto_park');
    _frontWait = Timer(frontBound, () {
      _frontWait = null;
      if (ref.read(promptSurfaceVisibleProvider)) return;
      logEvent('safety', 'watchdog_cancel', {'reason': noPromptSurfaceReason});
    });
  }

  /// "Keep riding" from the countdown: off until the stand or the speed
  /// changes and the condition comes back.
  void cancel() {
    if (!state.armed) return;
    _cancelled = true;
    _disarm('user');
  }

  /// "Keep riding" from the Lock failed modal: clear the
  /// awaitingLock latch; the modal goes away. Does not resend anything.
  void keepRiding() {
    if (!state.awaitingLock) return;
    logEvent('safety', 'auto_park_keep_riding', {'retry': state.retryAttempt});
    logModalDismiss('auto_park', reason: 'user_keep_riding');
    _cancelled = true;
    state = state.copyWith(awaitingLock: false, retryAttempt: 0);
  }

  /// "Retry" from the Lock failed modal: fire autoPark again and go back
  /// to Locking…. The vehicle layer clears any latched failure when it
  /// sees the new pendingLock.
  void retryLock() {
    if (!state.awaitingLock) return;
    if (refuseUnlessStopped(ref, ref.read(vehicleProvider), 'auto_park_retry', 'Stop to lock the scooter')) return;
    final attempt = state.retryAttempt + 1;
    logEvent('safety', 'lock_now_retry', {'attempt': attempt});
    uiModalButton('auto_park', 'retry');
    state = state.copyWith(retryAttempt: attempt);
    ref.read(vehicleProvider.notifier).autoPark();
  }

  void _recheck() {
    if (_sensorOn && _standCondition && _droppedWhileMoving && !_cancelled) {
      if (!_autoLockEnabled) {
        // Feature disabled in settings (VCU on this firmware doesn't honour
        // unsolicited Lock_Now). Log that we would have armed so the ride
        // data can be reviewed.
        logEvent('safety', 'watchdog_suppressed', {
          'reason': 'auto_lock_disabled',
          'dropped_while_moving': _droppedWhileMoving,
        });
      } else if (ref.read(promptSurfaceVisibleProvider)) {
        _arm();
      } else {
        _awaitSurface();
      }
      return;
    }
    _frontWait?.cancel();
    _frontWait = null;
    final v = ref.read(vehicleProvider);
    final untrusted = _timer != null && _sensorOn && v.speed == 0 && !v.speedTrusted;
    if (untrusted) untrustedCancel(ref, v, 'auto_park');
    final reason = !_sensorOn
        ? 'sensor_off'
        : untrusted
            ? 'untrusted'
        : !_standCondition && v.speed > 0
            ? 'speed'
            : !_standCondition || !_droppedWhileMoving
                ? 'stand_up'
                : 'bypass';
    _disarm(reason);
  }

  void _arm() {
    if (_timer != null) return;
    _frontWait?.cancel();
    _frontWait = null;
    _start();
    state = SafetyWatchdogState(armed: true, remainingSeconds: _remaining);
  }

  void _start() {
    _remaining = delay.inSeconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    logEvent('safety', 'watchdog_arm', {'remaining_s': _remaining, 'dropped_while_moving': _droppedWhileMoving});
    logModalShow('auto_park', reason: 'stand_down_while_moving');
  }

  void _tick() {
    _remaining -= 1;
    logEvent('safety', 'watchdog_tick', {'remaining_s': _remaining});
    if (_remaining > 0) {
      state = SafetyWatchdogState(armed: true, remainingSeconds: _remaining);
      return;
    }
    _fire();
  }

  void _disarm(String reason) {
    final wasArmed = _timer != null;
    _timer?.cancel();
    _timer = null;
    if (wasArmed) {
      logEvent('safety', 'watchdog_cancel', {'reason': reason});
      logModalDismiss('auto_park', reason: reason == 'user' ? 'user' : 'condition_cleared', extra: {'cause': reason});
    }
    if (state.armed) state = const SafetyWatchdogState();
  }

  void _fire() {
    _timer?.cancel();
    _timer = null;
    // The listener disarms on untrusted data; this is the last look before
    // the command, in case the two land in the same tick.
    final v = ref.read(vehicleProvider);
    final seen = ref.read(promptSurfaceVisibleProvider);
    if (!standCondition(v) || !seen) {
      if (!seen || (v.speed == 0 && !v.speedTrusted)) untrustedCancel(ref, v, 'auto_park');
      final cause = seen ? 'not_stopped_at_fire' : noPromptSurfaceReason;
      logEvent('safety', 'watchdog_cancel', {'reason': cause});
      logModalDismiss('auto_park', reason: 'condition_cleared', extra: {'cause': cause});
      state = const SafetyWatchdogState();
      return;
    }
    // armed → awaitingLock; the modal switches from countdown to Locking….
    state = const SafetyWatchdogState(awaitingLock: true);
    debugPrint('[SAFETY] Auto-lock: side stand down at zero speed for ${delay.inSeconds}s');
    logEvent('safety', 'watchdog_fire', {});
    ref.read(vehicleProvider.notifier).autoPark();
    logEvent('safety', 'lock_now_sent', {'cmd': HhmisCmd.sideStandStatus, 'value': HhmisCmd.sideStandLockNow});
  }
}
