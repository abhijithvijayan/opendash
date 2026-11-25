import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:opendash/state/passcode_state.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  void withPasscode(void Function(FakeAsync async, ProviderContainer c, PasscodeNotifier p) body) {
    fakeAsync((async) {
      final c = ProviderContainer();
      c.listen(passcodeProvider, (_, _) {});
      c.listen(sessionProvider, (_, _) {});
      c.read(vehicleProvider.notifier).setConnected(true);
      body(async, c, c.read(passcodeProvider.notifier));
      c.dispose();
    });
  }

  void enter(PasscodeNotifier p, String pin) {
    for (final ch in pin.split('')) {
      p.enterDigit(int.parse(ch));
    }
  }

  test('scooter starts locked and the lock screen shows', () {
    withPasscode((async, c, p) {
      expect(c.read(vehicleProvider).locked, isTrue);
      expect(c.read(screenStateProvider), ScreenState.locked);
    });
  });

  test('correct PIN unlocks', () {
    withPasscode((async, c, p) {
      enter(p, '123456');
      expect(c.read(passcodeProvider).lastResult, PasscodeResult.success);
      expect(c.read(vehicleProvider).locked, isFalse);
      expect(c.read(screenStateProvider), ScreenState.parked);
    });
  });

  test('wrong PIN decrements attempts and clears after the shake', () {
    withPasscode((async, c, p) {
      enter(p, '000000');
      final s = c.read(passcodeProvider);
      expect(s.lastResult, PasscodeResult.failure);
      expect(s.attemptsRemaining, 4);
      expect(s.enteredDigits, hasLength(6));
      expect(c.read(vehicleProvider).locked, isTrue);
      async.elapse(const Duration(milliseconds: 600));
      expect(c.read(passcodeProvider).enteredDigits, isEmpty);
      expect(c.read(passcodeProvider).lastResult, isNull);
    });
  });

  test('an unanswered verify clears the entry without spending an attempt', () {
    fakeAsync((async) {
      final c = ProviderContainer(overrides: [vehicleProvider.overrideWith(_SilentVehicle.new)]);
      c.listen(passcodeProvider, (_, _) {});
      final p = c.read(passcodeProvider.notifier);
      enter(p, '123456');
      final s = c.read(passcodeProvider);
      expect(s.lastResult, isNull);
      expect(s.failures, 0);
      expect(s.attemptsRemaining, VehicleNotifier.maxPasscodeAttempts);
      expect(s.enteredDigits, isEmpty);
      c.dispose();
    });
  });

  test('typing straight after a failure starts a fresh entry', () {
    withPasscode((async, c, p) {
      enter(p, '000000');
      p.enterDigit(1);
      expect(c.read(passcodeProvider).enteredDigits, [1]);
      expect(c.read(passcodeProvider).lastResult, isNull);
    });
  });

  test('delete removes the last digit', () {
    withPasscode((async, c, p) {
      enter(p, '12');
      p.deleteDigit();
      expect(c.read(passcodeProvider).enteredDigits, [1]);
      p.deleteDigit();
      p.deleteDigit();
      expect(c.read(passcodeProvider).enteredDigits, isEmpty);
    });
  });

  test('five failures lock out for HPMS\'s 5 minutes, then entry resumes', () {
    withPasscode((async, c, p) {
      for (var i = 0; i < 5; i++) {
        enter(p, '999999');
        async.elapse(const Duration(milliseconds: 600));
      }
      var s = c.read(passcodeProvider);
      expect(s.lockedOut, isTrue);
      expect(s.lastResult, PasscodeResult.lockedOut);
      expect(s.attemptsRemaining, 0);
      expect(s.lockoutRemaining(DateTime.now()).inSeconds, inInclusiveRange(298, 300));

      enter(p, '123456');
      expect(c.read(vehicleProvider).locked, isTrue, reason: 'keypad ignored during lockout');

      async.elapse(const Duration(minutes: 2));
      expect(c.read(passcodeProvider).lockedOut, isTrue, reason: 'HPMS still refuses a correct code at minute 2');
      async.elapse(const Duration(minutes: 3, seconds: 1));
      s = c.read(passcodeProvider);
      expect(s.lockedOut, isFalse);
      expect(s.attemptsRemaining, 5);
      enter(p, '123456');
      expect(c.read(vehicleProvider).locked, isFalse);
    });
  });

  test('reset lockout clears the timer and restores attempts', () {
    withPasscode((async, c, p) {
      for (var i = 0; i < 5; i++) {
        enter(p, '999999');
        async.elapse(const Duration(milliseconds: 600));
      }
      p.resetLockout();
      expect(c.read(passcodeProvider).lockedOut, isFalse);
      expect(c.read(passcodeProvider).attemptsRemaining, 5);
      async.elapse(const Duration(seconds: 31));
      expect(c.read(passcodeProvider).attemptsRemaining, 5);
    });
  });

  test('re-locking resets the entry but keeps the attempt count', () {
    withPasscode((async, c, p) {
      enter(p, '000000');
      async.elapse(const Duration(milliseconds: 600));
      enter(p, '123456');
      expect(c.read(vehicleProvider).locked, isFalse);
      expect(c.read(passcodeProvider).attemptsRemaining, 5);

      enter(p, '12');
      c.read(vehicleProvider.notifier).setLocked(false);
      c.read(vehicleProvider.notifier).setLocked(true);
      expect(c.read(passcodeProvider).enteredDigits, isEmpty);
      expect(c.read(passcodeProvider).lastResult, isNull);
    });
  });

  group('HPMS lockout window', () {
    void lockOut(FakeAsync async, PasscodeNotifier p) {
      for (var i = 0; i < 5; i++) {
        enter(p, '999999');
        async.elapse(const Duration(milliseconds: 600));
      }
    }

    // HHMIS re-sends the count every ~100 ms on the passcode screen
    // (log 1224, 06:53:4x); a restart per zero froze the hint at 5:00.
    test('repeated zeros from HPMS keep the lockout without restarting the countdown', () {
      withPasscode((async, c, p) {
        lockOut(async, p);
        final end = c.read(passcodeProvider).lockoutEndTime;
        for (var i = 0; i < 1200; i++) {
          c.read(passcodeReportProvider.notifier).report(0);
          async.elapse(const Duration(milliseconds: 100));
        }
        expect(c.read(passcodeProvider).lockedOut, isTrue);
        expect(c.read(passcodeProvider).lockoutEndTime, end, reason: 'the countdown keeps running');
        async.elapse(PasscodeNotifier.lockoutDuration - const Duration(minutes: 2));
        expect(c.read(passcodeProvider).lockedOut, isFalse, reason: 'ends 5 minutes after it started');
        expect(c.read(passcodeProvider).attemptsRemaining, 5);
      });
    });

    test('a positive count from HPMS ends the lockout early', () {
      withPasscode((async, c, p) {
        lockOut(async, p);
        c.read(passcodeReportProvider.notifier).report(5);
        final s = c.read(passcodeProvider);
        expect(s.lockedOut, isFalse);
        expect(s.lastResult, isNull);
        expect(s.attemptsRemaining, 5);
      });
    });

    // Dart process restarts (a Doze kill) throw away the lockout timer,
    // so when HPMS still reports `remaining=0` on the fresh bind, the
    // listener has to arm a new lockout — otherwise the user sees no timer
    // until they type and get rejected (seen in a ride log).
    test('a zero report arms the lockout when we are not already locked', () {
      withPasscode((async, c, p) {
        expect(c.read(passcodeProvider).lockedOut, isFalse);
        c.read(passcodeReportProvider.notifier).report(0);
        expect(c.read(passcodeProvider).lockedOut, isTrue);
        expect(c.read(passcodeProvider).lastResult, PasscodeResult.lockedOut);
        async.elapse(PasscodeNotifier.lockoutDuration);
        expect(c.read(passcodeProvider).lockedOut, isFalse);
        expect(c.read(passcodeProvider).attemptsRemaining, 5);
      });
    });

    test('a positive report during the arm-from-zero lockout clears it early', () {
      withPasscode((async, c, p) {
        c.read(passcodeReportProvider.notifier).report(0);
        expect(c.read(passcodeProvider).lockedOut, isTrue);
        async.elapse(const Duration(minutes: 2));
        c.read(passcodeReportProvider.notifier).report(5);
        expect(c.read(passcodeProvider).lockedOut, isFalse,
            reason: 'HPMS is the authority; its window ended before our conservative 5-min timer');
      });
    });

    // A Doze/LMK restart during the lockout throws away the in-memory timer.
    // Prefs remember the end time so the restored lockout shows the real
    // remaining duration, not a fresh 5-min countdown. (Seen on a ride:
    // user saw ~3 min left before sleep, restart, then UI reset to 5 min.)
    test('a lockout armed in a dead process is restored from prefs with remaining time', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      await PrefsService.init();
      final end = DateTime.now().add(const Duration(minutes: 3, seconds: 10));
      await PrefsService.setInt(PrefsKeys.passcodeLockoutEnd, end.millisecondsSinceEpoch);

      final c = ProviderContainer();
      c.listen(passcodeProvider, (_, _) {});
      c.read(vehicleProvider.notifier).setConnected(true);
      final s = c.read(passcodeProvider);
      expect(s.lockedOut, isTrue, reason: 'build() restored the lockout from prefs');
      expect(s.lastResult, PasscodeResult.lockedOut);
      expect(s.lockoutEndTime, isNotNull);
      final left = s.lockoutRemaining(DateTime.now());
      expect(left.inSeconds, greaterThan(170), reason: 'restored remaining should be close to 3 min 10 s');
      expect(left.inSeconds, lessThan(200));
      c.dispose();
      PrefsService.resetForTest();
    });

    test('an expired pref is cleared and does not keep the UI locked', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      await PrefsService.init();
      final past = DateTime.now().subtract(const Duration(seconds: 1));
      await PrefsService.setInt(PrefsKeys.passcodeLockoutEnd, past.millisecondsSinceEpoch);

      final c = ProviderContainer();
      c.listen(passcodeProvider, (_, _) {});
      c.read(vehicleProvider.notifier).setConnected(true);
      expect(c.read(passcodeProvider).lockedOut, isFalse);
      // The build() path calls PrefsService.remove (async, fire-and-forget).
      // Pumping one event loop is enough for it to settle.
      await Future<void>.value();
      expect(PrefsService.getInt(PrefsKeys.passcodeLockoutEnd, 0), 0,
          reason: 'expired pref was removed in build()');
      c.dispose();
      PrefsService.resetForTest();
    });
  });
}

class _SilentVehicle extends VehicleNotifier {
  @override
  (bool, int) verifyPasscode(String pin) => (false, VehicleNotifier.passcodeNoAnswer);
}
