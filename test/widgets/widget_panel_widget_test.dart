import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/main.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/widget_panel_state.dart';
import 'package:opendash/widgets/gauges/battery_ring.dart';
import 'package:opendash/widgets/panel/rpm_gauge.dart';
import 'package:opendash/widgets/panel/widget_panel.dart';

void main() {
  setUp(AnalyticsLogger.instance.resetForTest);
  late ProviderContainer container;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);
  Finder k(String id) => find.byKey(ValueKey(id));

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
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  Future<void> swipeLeft(WidgetTester tester) async {
    await tester.fling(find.byType(PageView), const Offset(-90, 0), 700);
    await settle(tester);
  }

  // HHMIS sends rpm / 100; the page shows real rpm.
  testWidgets('the motor page shows real rpm from the live value', (tester) async {
    await pumpApp(tester);
    await swipeLeft(tester);
    expect(tester.widget<Text>(k('rpm-value')).data, '0');
    // Setting off snaps the panel back to the battery ring.
    v().setSpeed(100);
    await settle(tester);
    await swipeLeft(tester);
    expect(container.read(vehicleProvider).rpm, 31);
    expect(tester.widget<Text>(k('rpm-value')).data, '3,100');
    expect(tester.widget<RpmGauge>(find.byType(RpmGauge)).rpm, 3100);
  });

  testWidgets('page 0 is the battery ring, swipes reveal the three widget pages and stop', (tester) async {
    await pumpApp(tester);
    expect(find.byType(WidgetPanel), findsOneWidget);
    expect(find.descendant(of: find.byType(WidgetPanel), matching: find.byType(BatteryRing)), findsOneWidget);
    expect(k('range-caption'), findsOneWidget);
    expect(container.read(widgetPageProvider), 0);

    await swipeLeft(tester);
    expect(container.read(widgetPageProvider), 1);
    expect(find.byType(RpmGauge), findsOneWidget);
    expect(find.descendant(of: find.byType(WidgetPanel), matching: find.text('Torque')), findsOneWidget);

    expect(k('motor-temp'), findsOneWidget);

    await swipeLeft(tester);
    expect(container.read(widgetPageProvider), 2);
    expect(find.text('By mode'), findsOneWidget);
    expect(find.text('kWh regen'), findsOneWidget);
    expect(k('mode-bar-hyper'), findsOneWidget);

    await swipeLeft(tester);
    expect(container.read(widgetPageProvider), 2, reason: 'no page beyond trip stats');

    await tester.fling(find.byType(PageView), const Offset(90, 0), 700);
    await settle(tester);
    expect(container.read(widgetPageProvider), 1);
  });

  testWidgets('page resets to the battery ring when the charger is plugged in', (tester) async {
    await pumpApp(tester);
    await swipeLeft(tester);
    expect(container.read(widgetPageProvider), 1);
    v().setCharging(true);
    await settle(tester);
    expect(container.read(widgetPageProvider), 0);
    v().setCharging(false);
    await settle(tester);
    expect(find.descendant(of: find.byType(WidgetPanel), matching: find.byType(BatteryRing)), findsOneWidget);
  });

  testWidgets('dots follow the page', (tester) async {
    await pumpApp(tester);
    // The dot visual is an AnimatedContainer inside the tappable
    // GestureDetector, so the dots are tappable.
    AnimatedContainer dot(int i) => tester.widget<AnimatedContainer>(
        find.descendant(of: k('dot-$i'), matching: find.byType(AnimatedContainer)));
    expect(dot(0).constraints?.maxWidth ?? 10, 10);
    await swipeLeft(tester);
    final active = tester.widget<PageDots>(find.byType(PageDots)).active;
    expect(active, 1);
  });

  testWidgets('tapping a dot jumps the page', (tester) async {
    await pumpApp(tester);
    expect(container.read(widgetPageProvider), 0);
    await tester.tap(k('dot-2'));
    await settle(tester);
    expect(container.read(widgetPageProvider), 2);
    await tester.tap(k('dot-0'));
    await settle(tester);
    expect(container.read(widgetPageProvider), 0);
  });

  testWidgets('stopping and setting off again leaves the page where the rider put it; parking resets it', (tester) async {
    await pumpApp(tester);
    v().setVehicleState(VehicleState.ready);
    await settle(tester);
    await swipeLeft(tester);
    expect(container.read(widgetPageProvider), 1);
    for (var i = 0; i < 3; i++) {
      v().setVehicleState(VehicleState.riding);
      v().setSpeed(30);
      await settle(tester);
      v().setSpeed(0);
      v().setVehicleState(VehicleState.ready);
      await settle(tester);
    }
    expect(container.read(widgetPageProvider), 1, reason: 'a traffic light is not a screen change');
    expect(AnalyticsLogger.instance.recent('ui', 'panel_reset'), isEmpty);
    v().setVehicleState(VehicleState.parked);
    await settle(tester);
    expect(container.read(widgetPageProvider), 0);
    expect((AnalyticsLogger.instance.recent('ui', 'panel_reset').single['data']! as Map)['from'], 1);
  });

  testWidgets('every sideways drag on the panel is logged, whether or not it turned the page', (tester) async {
    await pumpApp(tester);
    List<Map<Object?, Object?>> attempts() =>
        [for (final e in AnalyticsLogger.instance.recent('ui', 'swipe_attempt')) e['data']! as Map];
    // Too short to turn the page.
    await tester.drag(find.byType(PageView), const Offset(-30, 0));
    await settle(tester);
    expect(container.read(widgetPageProvider), 0);
    expect(attempts().single['target'], 'widget-panel');
    expect(attempts().single['from'], 0);
    expect(attempts().single['dx_fraction'], lessThan(0));
    expect(AnalyticsLogger.instance.recent('ui', 'swipe'), isEmpty);
    await swipeLeft(tester);
    expect(container.read(widgetPageProvider), 1);
    expect(attempts(), hasLength(2));
    expect(AnalyticsLogger.instance.recent('ui', 'swipe'), hasLength(1));
    // A tap is not an attempt.
    await tester.tap(find.byType(PageView));
    await settle(tester);
    expect(attempts(), hasLength(2));
  });

  testWidgets('performance page motor temp reflects the dev sliders', (tester) async {
    await pumpApp(tester);
    await swipeLeft(tester);
    v().setMotorTemp(90);
    await settle(tester);
    expect(find.descendant(of: k('motor-temp'), matching: find.text('90')), findsOneWidget);
  });
}
