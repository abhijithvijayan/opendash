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
import 'package:opendash/state/passcode_gate.dart';
import 'package:opendash/state/settings_state.dart';

/// The status bar's Wi-Fi icon: Android's Wi-Fi panel on a tap, Settings →
/// Connectivity on a long-press, as stock's quick Wi-Fi button.
void main() {
  late ProviderContainer container;
  late MockPlatformService platform;
  Finder k(String id) => find.byKey(ValueKey(id));

  setUp(() => AnalyticsLogger.instance.resetForTest());

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpApp(WidgetTester tester) async {
    platform = MockPlatformService();
    await tester.pumpWidget(ProviderScope(
      overrides: [platformServiceProvider.overrideWithValue(platform)],
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

  testWidgets('a tap opens the Wi-Fi panel, with no passcode and the way back', (tester) async {
    await pumpApp(tester);
    await tester.tap(k('status-wifi'));
    await settle(tester);
    expect(platform.systemPages, ['wifi']);
    expect(container.read(passcodeGateProvider).open, isFalse, reason: 'only the network list: no passcode');
    expect(container.read(outsideAppProvider)?.name, 'Wi-Fi');
    expect(AnalyticsLogger.instance.recent('apps', 'system_page').last['data'],
        allOf(containsPair('page', 'wifi_panel'), containsPair('from', 'status_bar'), containsPair('opened', true)));
  });

  testWidgets('a long-press opens Settings at Connectivity', (tester) async {
    await pumpApp(tester);
    await tester.longPress(k('status-wifi'));
    await settle(tester);
    expect(platform.systemPages, isEmpty);
    expect(container.read(settingsScreenOpenProvider), isTrue);
    expect(container.read(settingsSectionProvider), SettingsSection.connectivity);
  });

  testWidgets('refused while riding', (tester) async {
    await pumpApp(tester);
    container.read(vehicleProvider.notifier).setVehicleState(VehicleState.ready);
    container.read(vehicleProvider.notifier).setSpeed(30);
    await settle(tester);
    await container.read(appManagerProvider.notifier).openWifiPanel('test');
    await settle(tester);
    expect(platform.systemPages, isEmpty);
  });
}
