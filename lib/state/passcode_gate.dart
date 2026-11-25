import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mock_provider.dart';
import 'passcode_state.dart';
import 'prompt_surface.dart';
import 'riding_lockout.dart';
import '../services/analytics_logger.dart';

class PasscodeGateState {
  const PasscodeGateState({
    this.open = false,
    this.purpose = '',
    this.enteredDigits = const [],
    this.failures = 0,
    this.failed = false,
    this.lockoutEndTime,
  });

  final bool open;

  /// What the rider is confirming, shown as the overlay title.
  final String purpose;
  final List<int> enteredDigits;

  /// Counts failed attempts so the UI can replay the shake on every one.
  final int failures;
  final bool failed;
  final DateTime? lockoutEndTime;

  bool get lockedOut => lockoutEndTime != null;

  Duration lockoutRemaining(DateTime now) {
    final end = lockoutEndTime;
    if (end == null) return Duration.zero;
    final left = end.difference(now);
    if (left.isNegative) return Duration.zero;
    return left > PasscodeGate.lockoutDuration ? PasscodeGate.lockoutDuration : left;
  }

  PasscodeGateState copyWith({
    bool? open,
    String? purpose,
    List<int>? enteredDigits,
    int? failures,
    bool? failed,
    DateTime? Function()? lockoutEndTime,
  }) =>
      PasscodeGateState(
        open: open ?? this.open,
        purpose: purpose ?? this.purpose,
        enteredDigits: enteredDigits ?? this.enteredDigits,
        failures: failures ?? this.failures,
        failed: failed ?? this.failed,
        lockoutEndTime: lockoutEndTime != null ? lockoutEndTime() : this.lockoutEndTime,
      );
}

final passcodeGateProvider = NotifierProvider<PasscodeGate, PasscodeGateState>(PasscodeGate.new);

/// Passcode confirmation for sensitive actions (OTA install, side stand
/// bypass, service mode). The caller hands over a callback that runs once
/// the right code is entered; cancel, riding and a speed that can no longer
/// be trusted all drop it.
class PasscodeGate extends Notifier<PasscodeGateState> {
  static const length = PasscodeNotifier.length;
  static const maxAttempts = VehicleNotifier.maxPasscodeAttempts;
  /// Local only: the gate's verify-only challenge never spends an HPMS
  /// attempt, so HPMS's 5-minute window does not apply here.
  static const lockoutDuration = Duration(seconds: 30);
  static const clearDelay = PasscodeNotifier.clearDelay;

  VoidCallback? _onSuccess;
  bool _allowUnknown = false;
  int _attempts = maxAttempts;
  Timer? _clearTimer;
  Timer? _lockoutTimer;

  int get attemptsRemaining => _attempts;

  @override
  PasscodeGateState build() {
    ref.onDispose(() {
      _clearTimer?.cancel();
      _lockoutTimer?.cancel();
    });
    ref.listen(vehicleProvider.select((v) => v.speed > 0), (_, riding) {
      if (riding) _cancel('state_change');
    });
    onRidingLockout(ref, () {
      if (!_allowUnknown) _cancel('state_change');
    });
    // A success hands over before the action runs, so an action that opens
    // another app does not cancel its own gate.
    onOwnScreenLost(ref, () {
      if (!state.open) return;
      untrustedCancel(ref, ref.read(vehicleProvider), 'passcode_gate', ownScreen: true);
      _cancel(noPromptSurfaceReason);
    });
    return const PasscodeGateState();
  }

  /// [allowUnknown] keeps the gate up without trustworthy vehicle data: the
  /// restart that fixes a dead HHMIS link starts here.
  void request({required String purpose, required VoidCallback onSuccess, bool allowUnknown = false}) {
    if (ref.read(vehicleProvider).speed > 0 || (!allowUnknown && ref.read(ridingLockoutProvider))) return;
    _clearTimer?.cancel();
    _onSuccess = onSuccess;
    _allowUnknown = allowUnknown;
    if (!state.open) logModalShow('lock_passcode_gate', reason: purpose);
    state = PasscodeGateState(open: true, purpose: purpose, lockoutEndTime: state.lockoutEndTime);
  }

  void enterDigit(int digit) {
    if (!state.open || state.lockedOut) {
      logEvent('ui', 'keypad_ignored', {'screen': 'gate', 'reason': state.lockedOut ? 'locked_out' : 'closed'});
      return;
    }
    if (state.failed) {
      _clearTimer?.cancel();
      state = state.copyWith(enteredDigits: const [], failed: false);
    }
    if (state.enteredDigits.length >= length) {
      logEvent('ui', 'keypad_ignored', {'screen': 'gate', 'reason': 'waiting_for_answer'});
      return;
    }
    final digits = [...state.enteredDigits, digit];
    uiTap('passcode-digit', {'screen': 'gate', 'count': digits.length});
    state = state.copyWith(enteredDigits: digits);
    if (digits.length == length) _verify();
  }

  void deleteDigit() {
    if (state.enteredDigits.isEmpty || state.failed) return;
    state = state.copyWith(enteredDigits: state.enteredDigits.sublist(0, state.enteredDigits.length - 1));
  }

  void cancel() => _cancel('user');

  void _cancel(String reason) {
    _clearTimer?.cancel();
    _onSuccess = null;
    if (!state.open) return;
    logModalDismiss('lock_passcode_gate', reason: reason);
    state = state.copyWith(open: false, purpose: '', enteredDigits: const [], failed: false);
  }

  void _verify() {
    final pin = state.enteredDigits.join();
    final result = ref.read(vehicleProvider.notifier).checkPasscode(pin);
    if (result is Future<bool?>) {
      result.then(_applyResult);
    } else {
      _applyResult(result);
    }
  }

  void _applyResult(bool? ok) {
    if (!state.open || state.enteredDigits.length < length) return;
    // Null is 'no answer'. Don't spend an attempt,
    // just wipe the digits so the rider can try again.
    if (ok == null) {
      state = state.copyWith(enteredDigits: const [], failed: false);
      return;
    }
    if (ok) {
      _attempts = maxAttempts;
      final done = _onSuccess;
      _onSuccess = null;
      logModalDismiss('lock_passcode_gate', reason: 'success');
      state = const PasscodeGateState();
      done?.call();
      return;
    }
    _attempts -= 1;
    logEvent('modal', 'passcode_failed', {'name': 'lock_passcode_gate', 'attempts_left': _attempts});
    state = state.copyWith(failed: true, failures: state.failures + 1);
    if (_attempts <= 0) {
      _startLockout();
      return;
    }
    _clearTimer?.cancel();
    _clearTimer = Timer(clearDelay, () {
      if (state.failed) state = state.copyWith(enteredDigits: const [], failed: false);
    });
  }

  void _startLockout() {
    _lockoutTimer?.cancel();
    state = state.copyWith(
      enteredDigits: const [],
      failed: false,
      lockoutEndTime: () => DateTime.now().add(lockoutDuration),
    );
    _lockoutTimer = Timer(lockoutDuration, () {
      _lockoutTimer = null;
      _attempts = maxAttempts;
      state = state.copyWith(lockoutEndTime: () => null);
    });
  }
}
