import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/state/alert_state.dart';
import 'package:opendash/state/passcode_gate.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:opendash/theme/colors.dart';
import 'package:opendash/theme/dash_theme.dart';
import 'package:opendash/widgets/indicators/telltale_strip.dart';
import 'package:opendash/widgets/overlays/toast_overlay.dart';

void main() {
  late ProviderContainer container;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenDashApp()));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    v().setLocked(false);
    // The unlock raises the handlebar hint; let it expire before tapping.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  group('alert banner', () {
    testWidgets('warning has a dismiss button, critical does not', (tester) async {
      await pumpApp(tester);
      v().setBattery(8);
      await settle(tester);
      expect(find.text('Battery low'), findsOneWidget);
      expect(find.byKey(const ValueKey('alert-dismiss')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('alert-dismiss')));
      await settle(tester);
      expect(find.text('Battery low'), findsNothing);

      v().setBattery(4);
      await settle(tester);
      expect(find.text('Battery critical'), findsOneWidget);
      expect(find.byKey(const ValueKey('alert-dismiss')), findsNothing);
    });

    testWidgets('counter shows with several alerts and swipe cycles', (tester) async {
      await pumpApp(tester);
      v().setBrakeWorn(true);
      v().setDerating(true);
      v().setLimpMode(true);
      await settle(tester);
      expect(find.text('1 of 3'), findsOneWidget);
      expect(find.text('Limp mode'), findsOneWidget);
      await tester.fling(find.text('Limp mode'), const Offset(-300, 0), 1500);
      await settle(tester);
      expect(find.text('2 of 3'), findsOneWidget);
      expect(find.text('Power reduced'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      expect(find.text('3 of 3'), findsOneWidget);
    });

    testWidgets('info alert disappears on its own after four seconds', (tester) async {
      await pumpApp(tester);
      v().setCharging(true);
      v().setBattery(100);
      await settle(tester);
      expect(find.text('Charging complete'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await settle(tester);
      expect(find.text('Charging complete'), findsNothing);
      expect(container.read(dismissedAlertsProvider), contains(const AlertKey(AlertKind.chargingComplete)));
    });
  });

  group('alert banner actions', () {
    // Stock's restart popup for faults 72 / 75 has a
    // button; ours opens the same passcode-and-confirm flow as Settings.
    testWidgets('a restart fault carries a Restart button into the restart flow', (tester) async {
      await pumpApp(tester);
      AnalyticsLogger.instance.resetForTest();
      v().setNotice(const VehicleNotice(72, 'Scooter issue', 'Restart the scooter', AlertPriority.critical,
          action: AlertAction.restartScooter));
      await settle(tester);
      expect(find.text('Restart'), findsOneWidget);
      expect(container.read(passcodeGateProvider).open, isFalse);
      await tester.tap(find.byKey(const ValueKey('alert-action')));
      await settle(tester);
      expect(container.read(passcodeGateProvider).open, isTrue, reason: 'passcode first, as from Settings');
      final tap = AnalyticsLogger.instance.recent('ui', 'tap').last['data']! as Map;
      expect(tap['target'], 'alert-action');
      expect(tap['action'], 'restartScooter');
      final requested = AnalyticsLogger.instance.recent('recovery', 'restart_requested').single['data']! as Map;
      expect(requested['from'], 'alert_banner');
    });

    testWidgets('a failed unlock carries Retry unlock next to the dismiss button', (tester) async {
      await pumpApp(tester);
      v().failUnlock();
      await settle(tester);
      expect(find.text('Unlock failed'), findsOneWidget);
      expect(find.text('Retry unlock'), findsOneWidget);
      expect(find.byKey(const ValueKey('alert-dismiss')), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('alert-action'))).height, greaterThanOrEqualTo(56));
      await tester.tap(find.byKey(const ValueKey('alert-action')));
      await settle(tester);
      expect(container.read(vehicleProvider).unlockFailedWarning, isFalse, reason: 'the mock retry succeeds');
      expect(find.text('Unlock failed'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('an alert without an action has no button', (tester) async {
      await pumpApp(tester);
      v().failLock();
      await settle(tester);
      expect(find.text('Handlebars not locked'), findsOneWidget);
      expect(find.byKey(const ValueKey('alert-action')), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('toasts', () {
    testWidgets('actions raise a toast that times out and gets replaced', (tester) async {
      await pumpApp(tester);
      v().toggleTrunk();
      await settle(tester);
      expect(find.text('Boot opened'), findsOneWidget);
      v().setDriveMode(DriveMode.eco);
      await settle(tester);
      expect(find.text('Boot opened'), findsNothing);
      expect(find.text('Drive mode: ECO'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);
      expect(find.text('Drive mode: ECO'), findsNothing);
    });

    testWidgets('toast pill carries the type colour', (tester) async {
      await pumpApp(tester);
      container.read(toastProvider.notifier).show('Something went wrong', type: ToastType.error);
      await settle(tester);
      final pill = tester.widget<ToastPill>(find.byType(ToastPill));
      expect(pill.toast.type.color, DashColors.critical);
      final icon = tester.widget<Icon>(
        find.descendant(of: find.byType(ToastPill), matching: find.byType(Icon)),
      );
      expect(icon.color, DashColors.critical);
    });
  });

  group('tell-tales', () {
    testWidgets('icons appear for active states and leave when cleared', (tester) async {
      await pumpApp(tester);
      expect(find.byType(TelltaleStrip), findsOneWidget);
      expect(find.byKey(const ValueKey('tt-cruise')), findsNothing);
      v().setCruise(CruiseMode.standby);
      v().setHillHold(true);
      v().setRegenActive(true);
      v().setRegenMode(RegenMode.city);
      v().setTamper(true);
      await settle(tester);
      for (final id in ['cruise', 'hillHold', 'regen', 'tamper']) {
        expect(find.byKey(ValueKey('tt-$id')), findsOneWidget, reason: id);
      }
      expect(find.byKey(const ValueKey('tt-apb')), findsNothing);
      v().setTamper(false);
      await settle(tester);
      expect(find.byKey(const ValueKey('tt-tamper')), findsNothing);
    });

    testWidgets('strip is absent on charging and lock screens', (tester) async {
      await pumpApp(tester);
      v().setCharging(true);
      await settle(tester);
      expect(find.byType(TelltaleStrip), findsNothing);
      v().setCharging(false);
      v().setLocked(true);
      await settle(tester);
      expect(find.byType(TelltaleStrip), findsNothing);
    });

    test('tell-tale table maps states to colours', () {
      DashColors.current = DashTheme.dark;
      final standby = telltalesFor(const VehicleData(cruiseMode: CruiseMode.standby)).single;
      expect(standby.color, DashColors.ash);
      final active = telltalesFor(const VehicleData(cruiseMode: CruiseMode.active)).single;
      expect(active.color, DashColors.eco);
      expect(telltalesFor(const VehicleData(brakeWorn: true)).single.color, DashColors.warning);
      expect(telltalesFor(const VehicleData(fallDetected: true)).single.color, DashColors.critical);
      for (final m in RegenMode.values) {
        expect(
          telltalesFor(VehicleData(regenActive: true, regenNotification: true, regenMode: m, regenAvailability: 1, regenAvailabilityKnown: true))
              .single
              .pulse,
          isFalse,
          reason: 'regen mode is a choice, not an intensity to pulse at',
        );
      }
      expect(telltalesFor(const VehicleData()), isEmpty);
    });
  });
}
