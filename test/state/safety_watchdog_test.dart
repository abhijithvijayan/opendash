import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/safety_watchdog.dart';

void main() {
  // The watchdog is gated by RidingSettings.autoLockEnabled (default off
  // on-device until the echo-waiting modal lands). These tests exercise the
  // full arming path and must enable it.
  void withWatchdog(void Function(FakeAsync async, ProviderContainer c, VehicleNotifier v) body) {
    fakeAsync((async) {
      final c = ProviderContainer();
      c.listen(safetyWatchdogProvider, (_, _) {});
      c.read(ridingSettingsProvider.notifier).setAutoLockEnabled(true);
      final v = c.read(vehicleProvider.notifier);
      v.setConnected(true);
      v.setLocked(false);
      body(async, c, v);
      c.dispose();
    });
  }

  SafetyWatchdogState state(ProviderContainer c) => c.read(safetyWatchdogProvider);

  // Scenario B: the real bug. Stand goes down while rolling, rider rolls to
  // a stop, VCU no longer auto-parks, our watchdog must.
  void dropWhileMoving(VehicleNotifier v) {
    v.setVehicleState(VehicleState.ready);
    v.setSpeed(20);
    v.setSideStand(true);
    v.setSpeed(0);
  }

  test('arms when the stand came down during a ride and the scooter rolls to a stop', () {
    withWatchdog((async, c, v) {
      expect(state(c).armed, isFalse);
      dropWhileMoving(v);
      expect(state(c).armed, isTrue);
      expect(state(c).remainingSeconds, 5);
    });
  });

  test('does not arm when the rider stops first and then puts the stand down', () {
    // Scenario A: stock VCU auto-parks correctly for this one, so our modal
    // must stay out of the way.
    withWatchdog((async, c, v) {
      v.setVehicleState(VehicleState.ready);
      v.setSideStand(true);
      expect(state(c).armed, isFalse);
      async.elapse(const Duration(seconds: 10));
      expect(state(c).armed, isFalse);
      expect(c.read(vehicleProvider).vehicleState, VehicleState.ready);
    });
  });

  test('does not arm when RidingSettings.autoLockEnabled is false (default)', () {
    fakeAsync((async) {
      final c = ProviderContainer();
      c.listen(safetyWatchdogProvider, (_, _) {});
      // Default: setting is off. Scenario B should NOT arm.
      expect(c.read(ridingSettingsProvider).autoLockEnabled, isFalse);
      final v = c.read(vehicleProvider.notifier);
      v.setConnected(true);
      v.setLocked(false);
      v.setVehicleState(VehicleState.ready);
      v.setSpeed(20);
      v.setSideStand(true);
      v.setSpeed(0);
      expect(c.read(safetyWatchdogProvider).armed, isFalse);
      async.elapse(const Duration(seconds: 10));
      expect(c.read(vehicleProvider).vehicleState, VehicleState.ready,
          reason: 'no auto-park while the setting is disabled');
      c.dispose();
    });
  });

  test('toggling autoLockEnabled on arms immediately if the condition holds', () {
    withWatchdog((async, c, v) {
      v.setVehicleState(VehicleState.ready);
      v.setSpeed(20);
      v.setSideStand(true);
      v.setSpeed(0);
      expect(state(c).armed, isTrue, reason: 'setting pre-enabled in withWatchdog helper');
    });
  });

  test('does not arm when the stand drops and lifts again while still riding', () {
    // Scenario C: a bump that drops the stand mid-ride, rider folds it back
    // before stopping. Only a toast (handled elsewhere), never a lock.
    withWatchdog((async, c, v) {
      v.setVehicleState(VehicleState.ready);
      v.setSpeed(20);
      v.setSideStand(true);
      v.setSideStand(false);
      v.setSpeed(0);
      expect(state(c).armed, isFalse);
    });
  });

  test('counts down once a second and parks after 5s', () {
    withWatchdog((async, c, v) {
      dropWhileMoving(v);
      final seen = <int>[];
      c.listen(safetyWatchdogProvider, (_, s) => seen.add(s.remainingSeconds));
      for (var expected = 4; expected >= 1; expected--) {
        async.elapse(const Duration(seconds: 1));
        expect(state(c).remainingSeconds, expected);
        expect(state(c).armed, isTrue);
        expect(c.read(vehicleProvider).vehicleState, VehicleState.ready);
      }
      async.elapse(const Duration(seconds: 1));
      expect(c.read(vehicleProvider).vehicleState, VehicleState.parked);
      expect(state(c).armed, isFalse);
      expect(seen, [4, 3, 2, 1, 0]);
    });
  });

  test('moving off before 5s cancels the countdown', () {
    withWatchdog((async, c, v) {
      dropWhileMoving(v);
      async.elapse(const Duration(seconds: 3));
      v.setSpeed(8);
      expect(state(c).armed, isFalse);
      async.elapse(const Duration(seconds: 3));
      expect(c.read(vehicleProvider).vehicleState, VehicleState.riding);
    });
  });

  test('retracting the stand cancels the countdown', () {
    withWatchdog((async, c, v) {
      dropWhileMoving(v);
      async.elapse(const Duration(seconds: 3));
      v.setSideStand(false);
      expect(state(c).armed, isFalse);
      async.elapse(const Duration(seconds: 3));
      expect(c.read(vehicleProvider).vehicleState, VehicleState.ready);
    });
  });

  test('does nothing when already parked', () {
    withWatchdog((async, c, v) {
      v.setSideStand(true);
      expect(state(c).armed, isFalse);
      async.elapse(const Duration(seconds: 6));
      expect(c.read(vehicleProvider).vehicleState, VehicleState.parked);
    });
  });

  test('re-arms after a new ride and parks again', () {
    withWatchdog((async, c, v) {
      dropWhileMoving(v);
      async.elapse(const Duration(seconds: 5));
      expect(c.read(vehicleProvider).vehicleState, VehicleState.parked);
      v.setSideStand(false);
      v.setVehicleState(VehicleState.ready);
      v.setSpeed(20);
      v.setSideStand(true);
      v.setSpeed(0);
      expect(c.read(vehicleProvider).vehicleState, VehicleState.ready);
      expect(state(c).armed, isTrue);
      async.elapse(const Duration(seconds: 5));
      expect(c.read(vehicleProvider).vehicleState, VehicleState.parked);
    });
  });

  test('Keep riding disarms and blocks re-arming until the condition clears and recurs', () {
    withWatchdog((async, c, v) {
      dropWhileMoving(v);
      async.elapse(const Duration(seconds: 2));
      c.read(safetyWatchdogProvider.notifier).cancel();
      expect(state(c).armed, isFalse);
      async.elapse(const Duration(seconds: 10));
      expect(c.read(vehicleProvider).vehicleState, VehicleState.ready, reason: 'no auto-park after cancel');
      expect(state(c).armed, isFalse, reason: 'the condition is unchanged, so it must not re-arm');
      // A new ride with the stand up, then stand down again mid-ride, counts
      // as a fresh event.
      v.setSideStand(false);
      v.setSpeed(20);
      v.setSideStand(true);
      v.setSpeed(0);
      expect(state(c).armed, isTrue, reason: 'stand up + new ride + stand down is a new event');
      expect(state(c).remainingSeconds, 5);
      async.elapse(const Duration(seconds: 5));
      expect(c.read(vehicleProvider).vehicleState, VehicleState.parked);
    });
  });

  test('a cancel that lands after the countdown already cleared does not suppress the next one', () {
    withWatchdog((async, c, v) {
      dropWhileMoving(v);
      v.setSideStand(false);
      expect(state(c).armed, isFalse);
      c.read(safetyWatchdogProvider.notifier).cancel();
      v.setSpeed(20);
      v.setSideStand(true);
      v.setSpeed(0);
      expect(state(c).armed, isTrue, reason: 'Keep riding on a stale frame must not skip a real countdown');
    });
  });

  test('speed clears a cancel as well', () {
    withWatchdog((async, c, v) {
      dropWhileMoving(v);
      c.read(safetyWatchdogProvider.notifier).cancel();
      v.setSpeed(12);
      v.setSpeed(0);
      expect(state(c).armed, isTrue);
    });
  });
}
