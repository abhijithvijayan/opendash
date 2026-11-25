import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/state/apps_state.dart';

/// The swipe up from the dashboard's bottom edge that opens Apps.
void main() {
  late ProviderContainer container;
  Finder k(String id) => find.byKey(ValueKey(id));

  setUp(() => AnalyticsLogger.instance.resetForTest());

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [platformServiceProvider.overrideWithValue(MockPlatformService())],
      child: const OpenDashApp(),
    ));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    container.read(vehicleProvider.notifier).setLocked(false);
    container.read(vehicleProvider.notifier).setVehicleState(VehicleState.parked);
    await settle(tester);
  }

  Future<void> swipeUp(WidgetTester tester) async {
    await tester.fling(k('apps-swipe-zone'), const Offset(0, -200), 1000);
    await settle(tester);
  }

  double grabber(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.ancestor(of: k('apps-swipe-grabber'), matching: find.byType(AnimatedOpacity))).opacity;

  testWidgets('a flick up from the bottom edge opens Apps, and a flick down puts it away', (tester) async {
    await pumpApp(tester);
    expect(grabber(tester), 1);
    await swipeUp(tester);
    expect(container.read(appLauncherOpenProvider), isTrue);
    expect(AnalyticsLogger.instance.recent('ui', 'swipe').last['data'], containsPair('target', 'apps-swipe-up'));

    await tester.fling(k('app-terminal'), const Offset(0, 300), 1000);
    await settle(tester);
    expect(container.read(appLauncherOpenProvider), isFalse);
    expect(AnalyticsLogger.instance.recent('ui', 'swipe').last['data'], containsPair('target', 'apps-swipe-down'));
  });

  testWidgets('a tap on the edge opens nothing, and a downward drag there does nothing', (tester) async {
    await pumpApp(tester);
    await tester.tap(k('apps-swipe-zone'));
    await settle(tester);
    expect(container.read(appLauncherOpenProvider), isFalse);
    await tester.fling(k('apps-swipe-zone'), const Offset(0, 40), 1000);
    await settle(tester);
    expect(container.read(appLauncherOpenProvider), isFalse);
  });

  testWidgets('refused while riding, and the grab bar is not shown then', (tester) async {
    await pumpApp(tester);
    container.read(vehicleProvider.notifier).setVehicleState(VehicleState.ready);
    container.read(vehicleProvider.notifier).setSpeed(30);
    await settle(tester);
    expect(grabber(tester), 0);
    await swipeUp(tester);
    expect(container.read(appLauncherOpenProvider), isFalse);
    expect(AnalyticsLogger.instance.recent('ui', 'swipe').last['data'], containsPair('opened', false));
  });

  testWidgets('the grab bar stays however often the swipe is used, and is not there while locked', (tester) async {
    await pumpApp(tester);
    for (var i = 0; i < 4; i++) {
      await swipeUp(tester);
      container.read(appLauncherOpenProvider.notifier).close();
      await settle(tester);
    }
    expect(grabber(tester), 1);
    container.read(vehicleProvider.notifier).setLocked(true);
    await settle(tester);
    expect(k('apps-swipe-grabber'), findsNothing, reason: 'the lock screen takes the dashboard away');
  });
}
