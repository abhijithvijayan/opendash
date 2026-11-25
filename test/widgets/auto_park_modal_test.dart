import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/safety_watchdog.dart';
import 'package:opendash/widgets/overlays/auto_park_modal.dart';

void main() {
  // Modal only renders when the watchdog arms, which is gated by the
  // RidingSettings.autoLockEnabled toggle (default off on-device).
  late ProviderContainer container;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);
  Finder k(String id) => find.byKey(ValueKey(id));

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpReady(WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenDashApp()));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    container.read(ridingSettingsProvider.notifier).setAutoLockEnabled(true);
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    v().setLocked(false);
    await settle(tester);
    v().setVehicleState(VehicleState.ready);
    await settle(tester);
  }

  /// Simulate scenario B: stand dropped while moving, then rolled to a stop.
  Future<void> armFromRide(WidgetTester tester) async {
    v().setSpeed(20);
    await settle(tester);
    v().setSideStand(true);
    await settle(tester);
    v().setSpeed(0);
    await settle(tester);
  }

  testWidgets('the countdown modal appears when the watchdog arms and ticks down', (tester) async {
    await pumpReady(tester);
    expect(k('auto-park-modal'), findsNothing);
    await armFromRide(tester);
    expect(k('auto-park-modal'), findsOneWidget);
    expect(find.text('Side stand is down'), findsOneWidget);
    expect(find.text('Auto-locking in 5…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('Auto-locking in 4…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
    expect(container.read(vehicleProvider).vehicleState, VehicleState.parked);
    // The modal stays as Locking… until the vehicle confirms
    // (or the rider acknowledges a Lock failed).
    expect(k('auto-park-modal'), findsOneWidget);
    expect(find.text('Locking…'), findsOneWidget);
    // Simulate the real-path pendingLock set then cleared (the vehicle
    // acknowledged the lock). The watchdog listener clears awaitingLock
    // on the transition back to (no pending, no failed).
    v().debugSetPendingLock(LockSource.autoPark);
    await settle(tester);
    v().debugClearPendingLock();
    await settle(tester);
    expect(k('auto-park-modal'), findsNothing);
  });

  testWidgets('Keep riding dismisses the modal and no auto-park follows', (tester) async {
    await pumpReady(tester);
    await armFromRide(tester);
    await tester.tap(find.text('Keep riding'));
    await settle(tester);
    expect(k('auto-park-modal'), findsNothing);
    expect(container.read(safetyWatchdogProvider).armed, isFalse);
    await tester.pump(const Duration(seconds: 10));
    await settle(tester);
    expect(container.read(vehicleProvider).vehicleState, VehicleState.ready);
  });

  testWidgets('the modal leaves when the stand comes up', (tester) async {
    await pumpReady(tester);
    await armFromRide(tester);
    expect(k('auto-park-modal'), findsOneWidget);
    v().setSideStand(false);
    await settle(tester);
    expect(k('auto-park-modal'), findsNothing);
  });

  testWidgets('the modal does not appear when the rider stops first and then puts the stand down', (tester) async {
    // Scenario A: stock VCU parks correctly, so we must stay out of the way.
    await pumpReady(tester);
    v().setSideStand(true);
    await settle(tester);
    expect(k('auto-park-modal'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    await settle(tester);
    expect(k('auto-park-modal'), findsNothing);
    expect(container.read(vehicleProvider).vehicleState, VehicleState.ready);
  });

  testWidgets('the modal renders over safe mode too', (tester) async {
    await pumpReady(tester);
    container.read(crashRecoveryProvider.notifier).enterSafeMode();
    await settle(tester);
    expect(k('safe-mode'), findsOneWidget);
    await armFromRide(tester);
    expect(k('auto-park-modal'), findsOneWidget);
    await tester.tap(find.text('Keep riding'));
    await settle(tester);
    expect(k('auto-park-modal'), findsNothing);
    expect(k('safe-mode'), findsOneWidget);
  });

  // After the countdown fires, the modal stays as
  // "Locking…" while pendingLock is set, and latches at
  // "Lock failed - Retry / Keep riding" if the vehicle never confirms.
  // Retry calls autoPark again; "Keep riding" from the failed state
  // dismisses the modal.
  group('three-state modal (countdown → Locking… → Failed)', () {
    testWidgets('countdown → Locking… once pendingLock is set', (tester) async {
      await pumpReady(tester);
      await armFromRide(tester);
      expect(find.text('Auto-locking in 5…'), findsOneWidget);
      // Fire the countdown. AidlVehicleNotifier is not wired in the mock
      // path, so push the modal into Locking… via the watchdog's own fire.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      // The mock autoPark does not set pendingLock; drive it directly.
      v().debugSetPendingLock(LockSource.autoPark);
      await settle(tester);
      expect(k('auto-park-modal'), findsOneWidget);
      expect(find.text('Locking…'), findsOneWidget);
      expect(find.text('Keep riding'), findsNothing,
          reason: 'no interaction while locking');
    });

    testWidgets('Locking… → Failed with Retry and Keep riding', (tester) async {
      await pumpReady(tester);
      await armFromRide(tester);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      v().debugSetPendingLock(LockSource.autoPark);
      await settle(tester);
      v().debugMarkLockFailed();
      await settle(tester);
      expect(k('auto-park-failed'), findsOneWidget);
      expect(find.text('Lock failed'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Keep riding'), findsOneWidget);
      // Failed state never auto-dismisses.
      await tester.pump(const Duration(seconds: 30));
      await settle(tester);
      expect(k('auto-park-failed'), findsOneWidget);
    });

    testWidgets('Retry sends another autoPark and returns to Locking…', (tester) async {
      await pumpReady(tester);
      await armFromRide(tester);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      v().debugSetPendingLock(LockSource.autoPark);
      v().debugMarkLockFailed();
      await settle(tester);
      await tester.tap(find.text('Retry'));
      await settle(tester);
      expect(find.text('Locking…'), findsOneWidget);
    });
  });

  testWidgets('mounting while already armed fires the haptic once', (tester) async {
    final vibrations = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') vibrations.add(call.arguments as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final c = ProviderContainer();
    c.listen(safetyWatchdogProvider, (_, _) {});
    c.read(ridingSettingsProvider.notifier).setAutoLockEnabled(true);
    final vehicle = c.read(vehicleProvider.notifier);
    vehicle.setConnected(true);
    vehicle.setLocked(false);
    vehicle.setVehicleState(VehicleState.ready);
    vehicle.setSpeed(20);
    vehicle.setSideStand(true);
    vehicle.setSpeed(0);
    expect(c.read(safetyWatchdogProvider).armed, isTrue);
    expect(vibrations, isEmpty, reason: 'nothing mounted yet');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const Directionality(textDirection: TextDirection.ltr, child: Stack(children: [AutoParkModal()])),
    ));
    await tester.pump();
    expect(k('auto-park-modal'), findsOneWidget);
    expect(vibrations, ['HapticFeedbackType.heavyImpact']);
    await tester.pump(const Duration(seconds: 1));
    expect(vibrations.length, 1, reason: 'ticks do not re-fire the arm haptic');
    vehicle.setSideStand(false);
    await tester.pump();
    vehicle.setSpeed(20);
    vehicle.setSideStand(true);
    vehicle.setSpeed(0);
    await tester.pump();
    expect(vibrations.length, 2, reason: 'a fresh arm after mount fires through the listener');
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}
