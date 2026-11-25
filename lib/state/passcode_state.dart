import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mock_provider.dart';
import '../services/analytics_logger.dart';
import '../services/prefs_service.dart';
import '../services/trusted_clock.dart';
import 'toast_state.dart';

enum PasscodeResult { success, failure, lockedOut }

class PasscodeState {
  const PasscodeState({
    this.enteredDigits = const [],
    this.attemptsRemaining = VehicleNotifier.maxPasscodeAttempts,
    this.lockoutEndTime,
    this.lastResult,
    this.failures = 0,
  });

  final List<int> enteredDigits;
  final int attemptsRemaining;
  final DateTime? lockoutEndTime;
  final PasscodeResult? lastResult;

  /// Counts failed attempts so the UI can replay the shake on every one.
  final int failures;

  bool get lockedOut => lockoutEndTime != null;

  Duration lockoutRemaining(DateTime now) {
    final end = lockoutEndTime;
    if (end == null) return Duration.zero;
    final left = end.difference(now);
    if (left.isNegative) return Duration.zero;
    // The end is a wall-clock time and the head unit's clock can step by
    // years; the timer that actually ends the lockout is not affected.
    return left > PasscodeNotifier.lockoutDuration ? PasscodeNotifier.lockoutDuration : left;
  }

  PasscodeState copyWith({
    List<int>? enteredDigits,
    int? attemptsRemaining,
    DateTime? Function()? lockoutEndTime,
    PasscodeResult? Function()? lastResult,
    int? failures,
  }) {
    return PasscodeState(
      enteredDigits: enteredDigits ?? this.enteredDigits,
      attemptsRemaining: attemptsRemaining ?? this.attemptsRemaining,
      lockoutEndTime: lockoutEndTime != null ? lockoutEndTime() : this.lockoutEndTime,
      lastResult: lastResult != null ? lastResult() : this.lastResult,
      failures: failures ?? this.failures,
    );
  }
}

/// HPMS's remaining-attempts count, each time the vehicle reports one
/// (`_passcode` results and INT_PROFILE_REMAINING_ATTEMPTS). [seq] makes a
/// repeated value a new report.
typedef PasscodeReport = ({int remaining, int seq});

final passcodeReportProvider =
    NotifierProvider<PasscodeReportNotifier, PasscodeReport?>(PasscodeReportNotifier.new);

class PasscodeReportNotifier extends Notifier<PasscodeReport?> {
  @override
  PasscodeReport? build() => null;

  void report(int remaining) => state = (remaining: remaining, seq: (state?.seq ?? 0) + 1);
}

/// Counts the head unit's screen going off (`BOOL_HEAD_UNIT_POWER_FLAG`
/// true -> false). Its own provider because the vehicle notifier cannot
/// read [passcodeProvider], which listens to it.
final screenOffProvider = NotifierProvider<ScreenOffNotifier, int>(ScreenOffNotifier.new);

class ScreenOffNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void mark() => state++;
}

final passcodeProvider =
    NotifierProvider<PasscodeNotifier, PasscodeState>(PasscodeNotifier.new);

class PasscodeNotifier extends Notifier<PasscodeState> {
  static const length = 6;
  /// HPMS refuses every code, right or wrong, until 5 minutes after the
  /// first failed try (`UserRepository.getRemainingAttemptsSharedPref`).
  static const lockoutDuration = Duration(minutes: 5);
  static const clearDelay = Duration(milliseconds: 500);
  /// A right PIN unlocks within half a second. HHMIS also answers success
  /// when the VCU is asleep and never unlocks (about 3 s later, 2026-11-21
  /// and 2026-11-25): without this the pad stayed green and dead until a
  /// restart, even after the scooter woke.
  static const unlockWait = Duration(seconds: 5);

  Timer? _clearTimer;
  Timer? _unlockTimer;
  Timer? _lockoutTimer;

  @override
  PasscodeState build() {
    ref.onDispose(() {
      _clearTimer?.cancel();
      _lockoutTimer?.cancel();
      _unlockTimer?.cancel();
    });
    ref.listen(vehicleProvider.select((v) => v.locked), (_, locked) {
      _unlockTimer?.cancel();
      if (locked) {
        // Not the six that just unlocked it, which sit here until the next lock.
        if (state.enteredDigits.isNotEmpty && state.lastResult != PasscodeResult.success) {
          logEvent('safety', 'passcode_cleared', {'reason': 'locked_again', 'digits': state.enteredDigits.length});
        }
        _clearTimer?.cancel();
        state = state.copyWith(enteredDigits: const [], lastResult: () => null);
      }
    });
    // A true -> false transition of
    // the head-unit-power flag blanks any in-progress passcode entry so
    // a dead screen does not re-submit stale digits when touch returns.
    ref.listen(vehicleProvider.select((v) => v.touchDisabled), (prev, next) {
      if (prev == false && next == true) clear('touch_disabled');
    });
    // The same on the raw screen-off edge: `touchDisabled` is cancelled at
    // once whenever the scooter is parked, which is always at the lock
    // screen, so the listener above never fired there.
    ref.listen(vehicleProvider.select((v) => v.scooterAsleep), (_, asleep) {
      if (asleep) clear('asleep');
    });
    ref.listen(screenOffProvider, (_, _) {
      if (state.enteredDigits.isEmpty) return;
      clear('screen_off');
    });
    // HPMS is the authority. Three cases, keyed on the report and our state:
    // - `remaining == 0` and we're NOT yet locked out: a prior lockout was
    //   armed in a dead process (Doze/LMK restart, stolen slot, etc.) and
    //   HPMS still has its 5-minute window running. Arm a conservative
    //   lockout from now; HPMS will clear it below once its true window ends.
    // - `remaining > 0` during our lockout: HPMS's real window ended earlier
    //   than ours; clear the timer.
    // - `remaining == 0` during our lockout: HPMS resends this every ~100 ms
    //   on the passcode screen; it must not restart the countdown.
    ref.listen(passcodeReportProvider, (_, report) {
      if (report == null) return;
      if (!state.lockedOut && report.remaining <= 0) {
        _startLockout();
        return;
      }
      if (state.lockedOut && report.remaining > 0) {
        _lockoutTimer?.cancel();
        _endLockout(remaining: report.remaining);
      }
    });
    // Restore a lockout armed in a prior process lifetime. HPMS runs its
    // own 5-min window, but we track our own end time in prefs so a
    // Doze/LMK restart shows the real remaining time instead of resetting
    // the countdown. The arm-from-zero branch above handles the case where
    // this pref is missing (older install, cleared data).
    final savedEnd = PrefsService.getInt(PrefsKeys.passcodeLockoutEnd, 0);
    if (savedEnd > 0) {
      var end = DateTime.fromMillisecondsSinceEpoch(savedEnd);
      var left = end.difference(DateTime.now());
      // Never more than one full lockout: a saved end read against a clock
      // that has since stepped back (a cold boot at a 2024 date) would
      // otherwise be years away. HPMS still ends it early with its report.
      if (left > lockoutDuration) {
        logEvent('safety', 'lockout_clamped', {'saved_left_s': left.inSeconds, 'clock_trusted': TrustedClock.trusted});
        left = lockoutDuration;
        end = DateTime.now().add(left);
      }
      if (left > Duration.zero) {
        _lockoutTimer = Timer(left, _endLockout);
        return PasscodeState(
          attemptsRemaining: 0,
          lockoutEndTime: end,
          lastResult: PasscodeResult.lockedOut,
        );
      }
      PrefsService.remove(PrefsKeys.passcodeLockoutEnd);
    }
    return PasscodeState(
      attemptsRemaining: ref.read(vehicleProvider.notifier).passcodeAttemptsRemaining,
    );
  }

  void enterDigit(int digit) {
    if (state.lockedOut || state.lastResult == PasscodeResult.success) {
      logEvent('ui', 'keypad_ignored', {'screen': 'lock', 'reason': state.lockedOut ? 'locked_out' : 'already_unlocking'});
      return;
    }
    if (state.lastResult == PasscodeResult.failure) {
      _clearTimer?.cancel();
      state = state.copyWith(enteredDigits: const [], lastResult: () => null);
    }
    if (state.enteredDigits.length >= length) {
      // Six are in and the scooter has not answered yet.
      logEvent('ui', 'keypad_ignored', {'screen': 'lock', 'reason': 'waiting_for_answer'});
      return;
    }
    final digits = [...state.enteredDigits, digit];
    uiTap('passcode-digit', {'screen': 'lock', 'count': digits.length});
    state = state.copyWith(enteredDigits: digits);
    if (digits.length == length) _verify();
  }

  void deleteDigit() {
    if (state.enteredDigits.isEmpty || state.lastResult != null) return;
    final digits = state.enteredDigits.sublist(0, state.enteredDigits.length - 1);
    uiTap('passcode-delete', {'screen': 'lock', 'count': digits.length});
    state = state.copyWith(enteredDigits: digits);
  }

  /// Digits the rider had entered and did not take back himself are
  /// logged as they go: a wipe between two presses looks, from the saddle,
  /// like a key that did not take.
  void clear([String reason = 'clear']) {
    if (state.enteredDigits.isNotEmpty && state.lastResult != PasscodeResult.success) {
      logEvent('safety', 'passcode_cleared', {'reason': reason, 'digits': state.enteredDigits.length});
    }
    _clearTimer?.cancel();
    state = state.copyWith(enteredDigits: const [], lastResult: () => null);
  }

  void _verify() {
    final pin = state.enteredDigits.join();
    final result = ref.read(vehicleProvider.notifier).verifyPasscode(pin);
    if (result is Future<(bool, int)>) {
      result.then(_applyResult);
    } else {
      _applyResult(result);
    }
  }

  void _applyResult((bool, int) result) {
    final (ok, remaining) = result;
    // The lock screen may have been dismissed while the vehicle was asked.
    if (state.enteredDigits.length < length) return;
    if (remaining == VehicleNotifier.passcodeNoAnswer) {
      state = state.copyWith(enteredDigits: const [], lastResult: () => null);
      return;
    }
    if (ok) {
      state = state.copyWith(
        attemptsRemaining: remaining,
        lastResult: () => PasscodeResult.success,
      );
      _unlockTimer?.cancel();
      if (ref.read(vehicleProvider).locked) _unlockTimer = Timer(unlockWait, _unlockNotFollowed);
      return;
    }
    state = state.copyWith(
      attemptsRemaining: remaining,
      lastResult: () => PasscodeResult.failure,
      failures: state.failures + 1,
    );
    if (remaining <= 0) {
      _startLockout();
      return;
    }
    _clearTimer?.cancel();
    _clearTimer = Timer(clearDelay, () {
      if (state.lastResult == PasscodeResult.failure) {
        state = state.copyWith(enteredDigits: const [], lastResult: () => null);
      }
    });
  }

  void _unlockNotFollowed() {
    _unlockTimer = null;
    if (!ref.read(vehicleProvider).locked || state.lastResult != PasscodeResult.success) return;
    logEvent('safety', 'unlock_not_followed', {'wait_s': unlockWait.inSeconds});
    state = state.copyWith(enteredDigits: const [], lastResult: () => null);
    ref.read(toastProvider.notifier).show("The scooter didn't unlock. Wake it and try again", type: ToastType.warning);
  }

  void _startLockout() {
    _clearTimer?.cancel();
    _lockoutTimer?.cancel();
    final end = DateTime.now().add(lockoutDuration);
    state = state.copyWith(
      enteredDigits: const [],
      lockoutEndTime: () => end,
      lastResult: () => PasscodeResult.lockedOut,
    );
    PrefsService.setInt(PrefsKeys.passcodeLockoutEnd, end.millisecondsSinceEpoch);
    _lockoutTimer = Timer(lockoutDuration, _endLockout);
  }

  void _endLockout({int? remaining}) {
    _lockoutTimer = null;
    PrefsService.remove(PrefsKeys.passcodeLockoutEnd);
    if (remaining == null) ref.read(vehicleProvider.notifier).resetPasscodeAttempts();
    state = state.copyWith(
      attemptsRemaining: remaining ?? VehicleNotifier.maxPasscodeAttempts,
      lockoutEndTime: () => null,
      lastResult: () => null,
    );
  }

  void resetLockout() {
    _lockoutTimer?.cancel();
    _endLockout();
  }
}
