import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/settings/widgets.dart';
import 'package:opendash/services/fault_catalog.dart';
import 'package:opendash/state/active_faults.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/theme/tokens.dart';

void main() {
  late ProviderContainer container;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);
  Finder k(String id) => find.byKey(ValueKey(id));

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [platformServiceProvider.overrideWithValue(MockPlatformService())],
      child: const OpenDashApp(),
    ));
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

  Future<void> openSection(WidgetTester tester, String id) async {
    container.read(settingsScreenOpenProvider.notifier).open();
    await settle(tester);
    await tester.tap(k('section-$id'));
    await settle(tester);
  }

  testWidgets('diagnostics: live cards follow the vehicle, fault tab shows the active code', (tester) async {
    await pumpApp(tester);
    await openSection(tester, 'diagnostics');
    expect(container.read(diagnosticsOpenProvider), isTrue);
    expect(container.read(settingsScreenOpenProvider), isTrue, reason: 'settings stays underneath so back returns to it');
    await tester.tap(k('diag-tab-liveData'));
    await settle(tester);
    v().setHighBeam(true);
    // The readout tween starts on the next frame and runs for the value
    // duration, so give it a frame to start before advancing past it.
    await tester.pump();
    await tester.pump(DashMotion.value);
    await settle(tester);
    expect(find.descendant(of: k('diag-Speed'), matching: find.text('0')), findsOneWidget);
    expect(find.descendant(of: k('diag-High Beam'), matching: find.text('ON')), findsOneWidget);
    expect(find.descendant(of: k('diag-Side Stand'), matching: find.text('OFF')), findsOneWidget);
    // Live rider inputs (0x113/0x15B/0x6AC): the mock rests with throttle
    // released and nothing pressed.
    expect(find.descendant(of: k('diag-Throttle'), matching: find.text('0.82')), findsOneWidget);
    expect(find.descendant(of: k('diag-Front Brake'), matching: find.text('OFF')), findsOneWidget);
    expect(find.descendant(of: k('diag-Horn'), matching: find.text('OFF')), findsOneWidget);
    await tester.tap(k('diag-tab-faultCodes'));
    await settle(tester);
    expect(find.text('No active faults'), findsOneWidget);
    expect(find.text('Motor controller fault'), findsOneWidget);
    v().setFaultCode('E042');
    v().setFault(true);
    await settle(tester);
    expect(k('diag-active-fault'), findsOneWidget);
    expect(find.descendant(of: k('diag-active-fault'), matching: find.text('E042'), matchRoot: true), findsOneWidget);
    expect(k('diag-clear'), findsNothing, reason: 'DTC clearing is a workshop operation, not a dashboard button');
    expect(find.text('Clear All'), findsNothing);
    expect(find.textContaining('Read only.'), findsOneWidget);
    // The CAN fault catalog: inject a demo set and they list with severity.
    container.read(activeFaultsProvider.notifier).set(demoActiveFaults());
    await settle(tester);
    expect(find.textContaining('LIVE STATUS BITS · CAN'), findsOneWidget);
    expect(find.text('Over-voltage charge Permanent Fault'), findsOneWidget);
    expect(find.text('Motor over-temperature'), findsOneWidget);
    expect(find.text('Motor controller fault'), findsOneWidget, reason: 'history still renders');
    expect(find.text('Fault codes'), findsOneWidget);
    await tester.tap(k('toolbar-back'));
    await settle(tester);
    expect(container.read(diagnosticsOpenProvider), isFalse);
    expect(container.read(settingsScreenOpenProvider), isTrue);
    container.read(diagnosticsOpenProvider.notifier).open();
    await settle(tester);
    v().setSpeed(22);
    await settle(tester);
    expect(container.read(diagnosticsOpenProvider), isTrue, reason: 'it rides: stays open on the move');
    expect(k('diag-body'), findsOneWidget, reason: 'the tab stays up; the island shows the speedo over it');
  });

  testWidgets('diagnostics: Live Data keeps its scroll position when the ride starts', (tester) async {
    await pumpApp(tester);
    await openSection(tester, 'diagnostics');
    await tester.tap(k('diag-tab-liveData'));
    await settle(tester);
    final scrollable = find.descendant(of: k('diag-body'), matching: find.byType(Scrollable));
    await tester.drag(scrollable, const Offset(0, -300));
    await settle(tester);
    final before = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(before, greaterThan(0));
    v().setSpeed(22);
    await settle(tester);
    expect(k('diag-back'), findsOneWidget, reason: 'riding: the page carries its own back arrow');
    expect(tester.state<ScrollableState>(find.descendant(of: k('diag-body'), matching: find.byType(Scrollable))).position.pixels, before,
        reason: 'scrolled to the bottom, it jumped back to the top as the scooter moved off');
  });

  testWidgets('profile shows mock data and defers editing', (tester) async {
    await pumpApp(tester);
    await openSection(tester, 'profile');
    expect(find.text('KL 01 AB 1234'), findsOneWidget);
    expect(find.text('Owner (you)'), findsOneWidget);
    await tester.tap(k('profile-edit-registration'));
    await settle(tester);
    expect(find.text('Editing requires a keyboard (Phase 2)'), findsOneWidget);
    await tester.ensureVisible(k('profile-add-rider'));
    await settle(tester);
    await tester.tap(k('profile-add-rider'));
    await settle(tester);
    expect(find.text('Multi-rider coming in a future update'), findsOneWidget);
  });

  testWidgets('safe mode replaces the UI; retry returns', (tester) async {
    await pumpApp(tester);
    container.read(crashRecoveryProvider.notifier).enterSafeMode();
    await settle(tester);
    expect(k('safe-mode'), findsOneWidget);
    await tester.tap(k('safe-stock'));
    await settle(tester);
    expect(find.text('Stock dashboard not installed'), findsOneWidget);
    await tester.tap(k('safe-retry'));
    await settle(tester);
    expect(k('safe-mode'), findsNothing);
  });

  testWidgets('triple-tapping the About title opens service mode; exit closes it', (tester) async {
    await pumpApp(tester);
    await openSection(tester, 'about');
    for (var i = 0; i < 3; i++) {
      await tester.tap(k('about-title'));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await settle(tester);
    expect(k('passcode-gate'), findsOneWidget, reason: 'service mode is behind the passcode');
    expect(k('service-mode'), findsNothing);
    for (final d in '123456'.split('')) {
      await tester.tap(find.descendant(of: k('passcode-gate'), matching: find.text(d)));
      await tester.pump();
    }
    await settle(tester);
    expect(k('service-mode'), findsOneWidget);
    await tester.tap(k('service-com.ola.mfgapp'));
    await settle(tester);
    expect(find.text('Could not launch com.ola.mfgapp'), findsOneWidget);
    await tester.tap(k('service-exit'));
    await settle(tester);
    expect(k('service-mode'), findsNothing);
  });

  testWidgets('sleep hint appears after two seconds and a double tap wakes', (tester) async {
    await pumpApp(tester);
    container.read(sessionProvider.notifier).sleep();
    await settle(tester);
    AnimatedOpacity hint() => tester.widget<AnimatedOpacity>(
          find.ancestor(of: k('sleep-hint'), matching: find.byType(AnimatedOpacity)),
        );
    expect(hint().opacity, 0);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(hint().opacity, 0.3);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(hint().opacity, 0);
    await tester.tapAt(const Offset(300, 300));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(const Offset(300, 300));
    await settle(tester);
    expect(container.read(screenStateProvider), ScreenState.parked);
  });

  testWidgets('speed limit: riding toggle, tell-tale and alert', (tester) async {
    await pumpApp(tester);
    await openSection(tester, 'riding');
    // On at 80 by default; the switch turns it off and back on.
    expect(find.text('80 km/h'), findsOneWidget);
    await tester.tap(find.descendant(of: k('riding-speedLimit'), matching: find.byType(DashSwitch)));
    await settle(tester);
    expect(find.text('80 km/h'), findsNothing);
    await tester.tap(find.descendant(of: k('riding-speedLimit'), matching: find.byType(DashSwitch)));
    await settle(tester);
    expect(find.text('80 km/h'), findsOneWidget);
    container.read(ridingSettingsProvider.notifier).setSpeedLimit(40);
    container.read(settingsScreenOpenProvider.notifier).close();
    await settle(tester);
    expect(k('tt-speedLimit'), findsOneWidget);
    v().setSpeed(55);
    await settle(tester);
    expect(find.text('Speed 55 km/h'), findsOneWidget);
    v().setSpeed(20);
    await settle(tester);
    expect(find.text('Speed 55 km/h'), findsNothing);
  });
}
