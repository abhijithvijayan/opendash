import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/state/control_panel.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/theme/colors.dart';
import 'package:opendash/widgets/controls/control_panel.dart';

void main() {
  // The lock button is hidden on the scooter for now; these keep it working for when it returns.
  setUp(() => ControlPanel.showLock = true);
  tearDown(() => ControlPanel.showLock = false);

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

  Future<void> openPanel(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('ctl-handle')));
    await settle(tester);
    expect(container.read(controlPanelOpenProvider), isTrue);
  }

  Finder btn(String id) => find.byKey(ValueKey('ctl-$id'));

  testWidgets('handle shows on dashboard, hidden on lock, boot and sleep', (tester) async {
    await pumpApp(tester);
    expect(btn('handle'), findsOneWidget);

    v().setLocked(true);
    await settle(tester);
    expect(btn('handle'), findsNothing);
    v().setLocked(false);
    await settle(tester);

    container.read(sessionProvider.notifier).sleep();
    await settle(tester);
    expect(btn('handle'), findsNothing);
    container.read(sessionProvider.notifier).wake();
    await settle(tester);

    container.read(sessionProvider.notifier).reboot();
    await settle(tester);
    expect(btn('handle'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
  });

  testWidgets('handle opens the panel; tap outside closes it', (tester) async {
    await pumpApp(tester);
    await openPanel(tester);
    await tester.tapAt(const Offset(200, 300));
    await settle(tester);
    expect(container.read(controlPanelOpenProvider), isFalse);
    await openPanel(tester);
    await tester.tap(btn('handle'));
    await settle(tester);
    expect(container.read(controlPanelOpenProvider), isFalse);
  });

  testWidgets('panel closes when the screen changes', (tester) async {
    await pumpApp(tester);
    await openPanel(tester);
    v().setCharging(true);
    await settle(tester);
    expect(container.read(controlPanelOpenProvider), isFalse);
  });

  testWidgets('no indicator, reverse or DRL buttons; hazard and high beam work', (tester) async {
    await pumpApp(tester);
    await openPanel(tester);
    // The indicators and reverse are the handlebar's, and the DRL switch
    // never moved the lamp: none of them is offered.
    expect(btn('left'), findsNothing);
    expect(btn('right'), findsNothing);
    expect(btn('reverse'), findsNothing);
    expect(btn('beam'), findsNothing);
    await tester.tap(btn('hazard'));
    await tester.pump();
    expect(v().hazardOn, isTrue);
    v().setLowBeam(true);
    await tester.pump();
    await tester.tap(btn('beam'));
    await tester.pump();
    expect(container.read(vehicleProvider).highBeam, isTrue);
    await tester.pump(VehicleNotifier.indicatorThrottle);
  });

  testWidgets('charging shows only settings and lock', (tester) async {
    await pumpApp(tester);
    v().setCharging(true);
    await settle(tester);
    expect(btn('handle'), findsOneWidget);
    expect(btn('settings'), findsOneWidget);
    expect(btn('trunk'), findsNothing);
    expect(btn('lock'), findsOneWidget);
    expect(btn('left'), findsNothing);
    expect(btn('beam'), findsNothing);
    expect(btn('reverse'), findsNothing);
  });

  testWidgets('riding hides lock and settings in real time', (tester) async {
    await pumpApp(tester);
    expect(btn('lock'), findsOneWidget);
    expect(btn('settings'), findsOneWidget);
    v().setSpeed(15);
    await tester.pump();
    expect(btn('lock'), findsNothing);
    expect(btn('settings'), findsNothing);
    expect(btn('hazard'), findsOneWidget);
    v().setSpeed(0);
    await tester.pump();
    expect(btn('lock'), findsOneWidget);
  });

  testWidgets('settings button closes the panel and opens settings', (tester) async {
    await pumpApp(tester);
    await openPanel(tester);
    expect(btn('trunk'), findsNothing, reason: 'the dashboard pill is the trunk control');
    await tester.tap(btn('settings'));
    await settle(tester);
    expect(container.read(settingsScreenOpenProvider), isTrue);
    expect(container.read(controlPanelOpenProvider), isFalse);
  });

  testWidgets('lock asks for confirmation, then locks', (tester) async {
    await pumpApp(tester);
    await openPanel(tester);
    await tester.tap(btn('lock'));
    await tester.pump();
    expect(find.text('LOCK?'), findsOneWidget);
    expect(container.read(vehicleProvider).locked, isFalse);
    await tester.tap(btn('lock'));
    await settle(tester);
    expect(container.read(lockingProvider), isTrue);
    expect(tester.widget<ControlButton>(btn('lock')).enabled, isFalse);
    expect(container.read(vehicleProvider).locked, isFalse, reason: 'locking animation runs first');
    await tester.pump(const Duration(milliseconds: 1600));
    await settle(tester);
    expect(container.read(vehicleProvider).locked, isTrue);
  });

  testWidgets('lock confirmation times out', (tester) async {
    await pumpApp(tester);
    await openPanel(tester);
    await tester.tap(btn('lock'));
    await tester.pump();
    expect(find.text('LOCK?'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2100));
    expect(find.text('LOCK?'), findsNothing);
    expect(container.read(vehicleProvider).locked, isFalse);
  });

  group('smart headlight on the beam button and the status bar', () {
    final marker = find.byKey(const ValueKey('status-beam-auto'));
    Finder caption(String text) => find.descendant(of: btn('beam'), matching: find.text(text));

    testWidgets('AUTO marks a beam the smart headlight holds, and only then', (tester) async {
      await pumpApp(tester);
      v().setSmartHeadlightMode(SmartHeadlight.auto);
      await openPanel(tester);
      expect(container.read(vehicleProvider).highBeam || container.read(vehicleProvider).lowBeam, isFalse);
      expect(marker, findsNothing, reason: 'no beam lit: nothing is being held');
      expect(caption('AUTO'), findsNothing);

      v().setSpeed(30);
      await settle(tester);
      await openPanel(tester);
      expect(container.read(vehicleProvider).lowBeam, isTrue);
      expect(marker, findsOneWidget);
      expect(caption('AUTO'), findsOneWidget);
      expect(caption('LOW'), findsNothing);

      v().setHighBeam(true);
      await settle(tester);
      expect(marker, findsOneWidget);
      expect(caption('AUTO'), findsOneWidget);
      expect(tester.widget<ControlButton>(btn('beam')).activeColor, DashColors.normal,
          reason: 'the button still shows which beam the vehicle reports');

      v().setSmartHeadlightMode(SmartHeadlight.off);
      await settle(tester);
      expect(marker, findsNothing);
      expect(caption('HIGH'), findsOneWidget);
    });

    testWidgets('paused: the normal caption, and a long-press asks to resume', (tester) async {
      AnalyticsLogger.instance.resetForTest();
      await pumpApp(tester);
      v().setSpeed(30);
      v().setHighBeam(true);
      v().setSmartHeadlightMode(SmartHeadlight.auto);
      await settle(tester);
      await openPanel(tester);
      expect(tester.widget<ControlButton>(btn('beam')).onLongPress, isNull);

      v().setSmartHeadlightMode(SmartHeadlight.paused);
      await settle(tester);
      expect(marker, findsNothing);
      expect(caption('HIGH'), findsOneWidget);
      await tester.longPress(btn('beam'));
      await settle(tester);
      final presses = AnalyticsLogger.instance.recent('ui', 'long_press').map((e) => (e['data']! as Map)['target']);
      expect(presses, ['ctl-beam']);
      expect(container.read(vehicleProvider).highBeam, isTrue, reason: 'a long-press is not a tap');
    });
  });
}
