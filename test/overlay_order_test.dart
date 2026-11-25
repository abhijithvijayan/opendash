import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/dev/dev_panel.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/screens/safe_mode/safe_mode_screen.dart';
import 'package:opendash/screens/safety/safety_overlay.dart';
import 'package:opendash/screens/service/service_mode_screen.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/state/bt_settings.dart';
import 'package:opendash/state/error_state.dart';
import 'package:opendash/state/media_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/widgets/overlays/phone_pairing_overlay.dart';
import 'package:opendash/widgets/overlays/alert_overlay.dart';
import 'package:opendash/widgets/overlays/auto_park_modal.dart';
import 'package:opendash/widgets/overlays/call_overlay.dart';
import 'package:opendash/widgets/overlays/error_overlay.dart';
import 'package:opendash/widgets/overlays/firmware_overlays.dart';
import 'package:opendash/state/firmware_state.dart';
import 'package:opendash/widgets/overlays/passcode_gate_overlay.dart';
import 'package:opendash/widgets/overlays/restart_confirm_overlay.dart';
import 'package:opendash/widgets/overlays/toast_overlay.dart';
import 'helpers/stock.dart';

void main() {
  late ProviderContainer container;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);
  Finder k(String key) => find.byKey(ValueKey(key));

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpReady(WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenDashApp()));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    v().setLocked(false);
    await settle(tester);
    v().setVehicleState(VehicleState.ready);
    await settle(tester);
  }

  /// The root stack's children that take part in the documented order, by
  /// type, lowest first.
  List<Type> rootOrder(WidgetTester tester, Set<Type> of) {
    final stack = tester.widget<Stack>(find.ancestor(of: find.byType(ErrorOverlay), matching: find.byType(Stack)).first);
    return [for (final w in stack.children) if (of.contains(w.runtimeType)) w.runtimeType];
  }

  testWidgets('the root stack mounts the modals in the documented order', (tester) async {
    await pumpReady(tester);
    const order = [
      ServiceModeScreen,
      PasscodeGateOverlay,
      RestartConfirmOverlay,
      PhonePairingOverlay,
      ErrorOverlay,
      FirmwareInstallOverlay,
      AutoParkModal,
      AlertOverlay,
      IncomingCallOverlay,
      SafetyOverlay,
      ToastOverlay,
      DevPanel,
    ];
    expect(rootOrder(tester, order.toSet()), order);
  });

  testWidgets('the firmware-install notice sits under every safety overlay and over the rest', (tester) async {
    await pumpReady(tester);
    container.read(firmwareProvider.notifier).onNotice(const {'kind': 'install_progress', 'state': 3, 'progress': 10});
    await settle(tester);
    expect(k('fw-installing'), findsOneWidget);
    const below = [ServiceModeScreen, PasscodeGateOverlay, RestartConfirmOverlay, PhonePairingOverlay, ErrorOverlay];
    const above = [AutoParkModal, AlertOverlay, IncomingCallOverlay, SafetyOverlay, ToastOverlay];
    final order = rootOrder(tester, {...below, ...above, FirmwareInstallOverlay});
    final at = order.indexOf(FirmwareInstallOverlay);
    expect(order.sublist(0, at), below);
    expect(order.sublist(at + 1), above);

    // And in safe mode, where the stack is a different one.
    container.read(crashRecoveryProvider.notifier).enterSafeMode();
    await settle(tester);
    final safe = rootOrder(tester, {ErrorOverlay, FirmwareInstallOverlay, AutoParkModal, SafetyOverlay});
    expect(safe, [ErrorOverlay, FirmwareInstallOverlay, AutoParkModal, SafetyOverlay]);
    expect(k('fw-installing'), findsOneWidget);
  });

  testWidgets('the idle-lock warning shows over an open screen, takes no touches, and goes on its own', (tester) async {
    await pumpReady(tester);
    container.read(settingsScreenOpenProvider.notifier).open();
    await settle(tester);
    expect(k('idle-lock-warning'), findsNothing);
    v().idleLockIn.value = 8;
    await tester.pump();
    expect(k('idle-lock-warning'), findsOneWidget);
    expect(find.text('Locking in 8 s'), findsOneWidget);
    expect(find.text('Touch the screen to stay unlocked'), findsOneWidget);
    expect(find.ancestor(of: k('idle-lock-warning'), matching: find.byType(IgnorePointer)), findsWidgets);
    expect(k('settings-body'), findsOneWidget, reason: 'the screen stays up underneath');
    v().idleLockIn.value = 0;
    await tester.pump();
    expect(find.text('Locking'), findsOneWidget);
    v().idleLockIn.value = null;
    await tester.pump();
    expect(k('idle-lock-warning'), findsNothing);
  });

  group('phone pairing prompt', () {
    testWidgets('shows over the dashboard, over Settings and over the Bluetooth screen', (tester) async {
      await pumpReady(tester);
      final bt = container.read(btSettingsProvider.notifier);
      bt.simulatePairingRequest();
      await settle(tester);
      expect(k('phone-pairing-pair').hitTestable(), findsOneWidget, reason: 'no screen open');
      expect(find.text(BtSettingsNotifier.mockPairingCode.split('').join(' ')), findsOneWidget);
      expect(find.text('Pair with ${BtSettingsNotifier.mockPairingName}'), findsOneWidget);
      bt.rejectPairing();
      await settle(tester);
      expect(k('phone-pairing'), findsNothing);

      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      bt.simulatePairingRequest();
      await settle(tester);
      expect(k('phone-pairing-pair').hitTestable(), findsOneWidget, reason: 'over Settings');
      bt.rejectPairing();

      container.read(btScreenOpenProvider.notifier).open();
      await settle(tester);
      bt.simulatePairingRequest();
      await settle(tester);
      expect(k('phone-pairing-pair').hitTestable(), findsOneWidget, reason: 'over the Bluetooth screen');
      await tester.tap(k('phone-pairing-pair'));
      await settle(tester);
      expect(k('phone-pairing'), findsNothing);
      expect(find.text(BtSettingsNotifier.mockPairingName), findsOneWidget, reason: 'now in the paired list');
      expect(AnalyticsLogger.instance.recent('ui', 'tap').last['data'], containsPair('target', 'phone-pairing-pair'));
    });

    testWidgets('is never drawn while moving: the request is rejected', (tester) async {
      await pumpReady(tester);
      final bt = container.read(btSettingsProvider.notifier);
      bt.simulatePairingRequest();
      await settle(tester);
      expect(k('phone-pairing'), findsOneWidget);
      v().setSpeed(8);
      await settle(tester);
      expect(k('phone-pairing'), findsNothing);
      expect(container.read(btSettingsProvider).pairingOpen, isFalse);
      bt.simulatePairingRequest();
      await settle(tester);
      expect(k('phone-pairing'), findsNothing, reason: 'refused at once while moving');
    });

    testWidgets('the error screen covers it; "Device pairing failed" is dismissed with OK', (tester) async {
      await pumpReady(tester);
      final bt = container.read(btSettingsProvider.notifier);
      bt.simulatePairFailed();
      await settle(tester);
      expect(find.text('Device pairing failed'), findsOneWidget);
      await tester.tap(k('phone-pairing-failed-ok'));
      await settle(tester);
      expect(k('phone-pairing'), findsNothing);

      bt.simulatePairingRequest();
      await settle(tester);
      container.read(appErrorProvider.notifier).capture(() => throw StateError('boom'));
      await settle(tester);
      expect(k('phone-pairing-pair').hitTestable(), findsNothing, reason: 'under the opaque error screen');
    });
  });

  testWidgets('safe mode keeps the same order', (tester) async {
    await pumpReady(tester);
    container.read(crashRecoveryProvider.notifier).enterSafeMode();
    await settle(tester);
    const order = [SafeModeScreen, ErrorOverlay, AutoParkModal, SafetyOverlay, ToastOverlay, DevPanel];
    expect(rootOrder(tester, order.toSet()), order);
  });

  testWidgets('a safety alert stays on top of service mode and of the error screen', (tester) async {
    await pumpReady(tester);
    v().setFault(true);
    await settle(tester);
    expect(k('alert-banner').hitTestable(), findsOneWidget);

    container.read(serviceModeOpenProvider.notifier).open();
    await settle(tester);
    expect(k('service-mode'), findsOneWidget);
    expect(k('alert-banner').hitTestable(), findsOneWidget, reason: 'the opaque technician screen does not cover it');
    final banner = tester.getRect(k('alert-banner'));
    final title = tester.getRect(find.text('Service Mode'));
    expect(title.top, greaterThanOrEqualTo(banner.bottom), reason: 'the screen moves down instead of hiding its title');
    container.read(serviceModeOpenProvider.notifier).close();

    container.read(appErrorProvider.notifier).capture(() => throw StateError('boom'));
    await settle(tester);
    expect(k('error-overlay'), findsOneWidget);
    expect(k('alert-banner').hitTestable(), findsOneWidget, reason: 'the opaque error screen does not cover it');
    expect(k('error-retry').hitTestable(), findsOneWidget, reason: 'and the banner does not cover the way out');
  });

  group('dev panel', () {
    testWidgets('mounts over the mock provider', (tester) async {
      await pumpReady(tester);
      expect(find.byType(DevPanel), findsOneWidget);
      container.read(crashRecoveryProvider.notifier).enterSafeMode();
      await settle(tester);
      expect(find.byType(DevPanel), findsOneWidget);
    });

    test('is refused over the HHMIS bridge', () {
      fakeAsync((async) {
        final events = StreamController<dynamic>();
        final c = ProviderContainer(overrides: [
          vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: events.stream, invoke: (m, a) async => true)),
        ]);
        expect(devPanelAllowed(c.read(vehicleProvider.notifier)), isFalse);
        c.dispose();
        events.close();
      });
      final mock = ProviderContainer();
      expect(devPanelAllowed(mock.read(vehicleProvider.notifier)), isTrue);
      mock.dispose();
    });
  });
}
