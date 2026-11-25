import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/widgets/indicators/mode_ladder.dart';

void main() {
  late ProviderContainer container;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);
  Finder row(String label) => find.descendant(of: find.byType(ModeLadder), matching: find.text(label));

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

  double rowOpacity(WidgetTester tester, String label) =>
      tester.widget<AnimatedOpacity>(find.ancestor(of: row(label), matching: find.byType(AnimatedOpacity)).first).opacity;
  double ladderOpacity(WidgetTester tester) => rowOpacity(tester, 'SPORT');
  double paintedOpacity(WidgetTester tester, String label) =>
      tester.widget<FadeTransition>(find.ancestor(of: row(label), matching: find.byType(FadeTransition)).first).opacity.value;

  testWidgets('a tap at speed 0 selects the mode', (tester) async {
    await pumpReady(tester);
    await tester.tap(row('SPORT'));
    await settle(tester);
    expect(container.read(vehicleProvider).driveMode, DriveMode.sport);
    expect(ladderOpacity(tester), 1.0);
  });

  testWidgets('while riding the rows are dimmed and a tap changes nothing', (tester) async {
    await pumpReady(tester);
    v().setSpeed(25);
    await settle(tester);
    expect(ladderOpacity(tester), 0.4);
    final before = container.read(vehicleProvider).driveMode;
    await tester.tap(row('HYPER'));
    await settle(tester);
    expect(container.read(vehicleProvider).driveMode, before);
    expect(find.byType(GestureDetector).evaluate().where((e) => (e.widget as GestureDetector).onTap == null &&
        find.descendant(of: find.byWidget(e.widget), matching: row('HYPER')).evaluate().isNotEmpty), isNotEmpty,
        reason: 'the gesture is dropped, not just ignored');
    v().setSpeed(0);
    await settle(tester);
    expect(ladderOpacity(tester), 1.0);
  });

  testWidgets('the read-only dim fades in and out instead of snapping', (tester) async {
    await pumpReady(tester);
    expect(paintedOpacity(tester, 'SPORT'), 1.0);
    v().setSpeed(25);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(paintedOpacity(tester, 'SPORT'), allOf(lessThan(1.0), greaterThan(ModeLadder.readOnlyOpacity)));
    await settle(tester);
    expect(paintedOpacity(tester, 'SPORT'), ModeLadder.readOnlyOpacity);
    v().setSpeed(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(paintedOpacity(tester, 'SPORT'), allOf(lessThan(1.0), greaterThan(ModeLadder.readOnlyOpacity)));
    await settle(tester);
    expect(paintedOpacity(tester, 'SPORT'), 1.0);
  });

  testWidgets('modes the VCU reports unavailable are dimmed and refuse the tap', (tester) async {
    await pumpReady(tester);
    AnalyticsLogger.instance.resetForTest();
    v().setModesAvailable(1);
    await settle(tester);
    expect(rowOpacity(tester, 'HYPER'), ModeLadder.unavailableOpacity);
    expect(rowOpacity(tester, 'SPORT'), ModeLadder.unavailableOpacity);
    expect(rowOpacity(tester, 'NORMAL'), 1.0);
    expect(rowOpacity(tester, 'ECO'), 1.0);
    await tester.tap(row('SPORT'));
    await settle(tester);
    expect(container.read(vehicleProvider).driveMode, DriveMode.normal);
    expect(find.text('SPORT is not available right now'), findsOneWidget);
    final tap = AnalyticsLogger.instance.recent('ui', 'tap').last['data'] as Map;
    expect(tap, containsPair('allowed', false));
    expect(tap, containsPair('reason', 'unavailable'));
    await tester.tap(row('ECO'));
    await settle(tester);
    expect(container.read(vehicleProvider).driveMode, DriveMode.eco);

    v().setModesAvailable(2);
    await settle(tester);
    expect(rowOpacity(tester, 'NORMAL'), ModeLadder.unavailableOpacity);
    expect(rowOpacity(tester, 'ECO'), 1.0);

    v().setModesAvailable(3);
    await settle(tester);
    expect(rowOpacity(tester, 'ECO'), 1.0, reason: 'the mode the VCU is in is never drawn as unavailable');
    expect(rowOpacity(tester, 'HYPER'), ModeLadder.unavailableOpacity);

    v().setModesAvailable(0);
    await settle(tester);
    for (final m in DriveMode.values) {
      expect(rowOpacity(tester, m.label), 1.0);
    }
  });

  testWidgets('an unavailable mode stays dimmer than the riding dim', (tester) async {
    await pumpReady(tester);
    v().setModesAvailable(1);
    v().setSpeed(25);
    await settle(tester);
    expect(rowOpacity(tester, 'HYPER'), ModeLadder.unavailableOpacity);
    expect(rowOpacity(tester, 'ECO'), ModeLadder.readOnlyOpacity);
  });
}
