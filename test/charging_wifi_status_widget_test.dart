import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/charging/charging_screen.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/wifi_state.dart';
import 'package:opendash/theme/colors.dart';
import 'package:opendash/widgets/status_bar/status_icons.dart';

void main() {
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
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('charging: status strip, start time, limit popup, charger states', (tester) async {
    await pumpApp(tester);
    v().setCharging(true);
    await settle(tester);
    expect(tester.widget<ChargeStatusBar>(find.byType(ChargeStatusBar)).fraction, closeTo(0.82, 1e-9));
    expect(find.text('charge started'), findsOneWidget);
    expect(find.descendant(of: k('charge-label'), matching: find.text('Charging'), matchRoot: true), findsOneWidget);
    // The limit is a hypercharge limit; a home charger has none.
    expect(k('charge-limit-edit'), findsNothing);
    v().setHyperCharger(true);
    await settle(tester);
    await tester.tap(k('charge-limit-edit'));
    await settle(tester);
    expect(k('charge-limit-popup'), findsOneWidget);
    v().setChargeLimit(80);
    await settle(tester);
    expect(find.descendant(of: k('charge-limit'), matching: find.text('80%'), matchRoot: true), findsOneWidget);
    await tester.tap(k('charge-limit-done'));
    await settle(tester);
    expect(k('charge-limit-popup'), findsNothing);

    v().setChargerState(ChargingState.initializing);
    await settle(tester);
    expect(find.text('Initializing charger…'), findsOneWidget);
    expect(find.text('—'), findsWidgets);
    v().setChargerState(ChargingState.notCharging);
    await settle(tester);
    expect(find.text('Not charging'), findsOneWidget);
    expect(find.text('Check charger connection'), findsOneWidget);
    v().setChargerState(ChargingState.complete);
    await settle(tester);
    expect(find.text('Charged. Safe to unplug'), findsOneWidget);
    expect(tester.widget<ChargeStatusBar>(find.byType(ChargeStatusBar)).complete, isTrue);
  });

  // Stock blanks the charge times while a fast charger idles.
  testWidgets('charging: an idle fast charger shows no charge times', (tester) async {
    await pumpApp(tester);
    v().setCharging(true);
    v().setBoostCharger(true);
    await settle(tester);
    Text eta() => tester.widget<Text>(find.descendant(of: k('charge-to-full'), matching: find.byType(Text)).first);
    expect(eta().data, isNot('—'));
    v().setFcChargeIdle(true);
    await settle(tester);
    expect(eta().data, '—');
    expect(find.text('Initializing charger…'), findsOneWidget);
  });

  testWidgets('SOH popup opens from vehicle info', (tester) async {
    await pumpApp(tester);
    // Default is unknown; the BMS reports Good once the
    // BOOL_PACK_SOH_STAT key arrives.
    container.read(vehicleProvider.notifier).setBatteryHealth(true);
    container.read(settingsScreenOpenProvider.notifier).open();
    await settle(tester);
    await tester.tap(k('section-vehicleInfo'));
    await settle(tester);
    await tester.ensureVisible(k('soh-row'));
    await settle(tester);
    await tester.tap(k('soh-row'));
    await settle(tester);
    expect(k('soh-popup'), findsOneWidget);
    expect(find.descendant(of: k('soh-value'), matching: find.text('Good'), matchRoot: true), findsOneWidget);
    expect(find.descendant(of: k('soh-popup'), matching: find.textContaining(RegExp(r'^\d+%$'))), findsNothing);
    expect(find.text('Keep battery between 20-80% for daily use'), findsOneWidget);
    await tester.tap(k('soh-done'));
    await settle(tester);
    expect(k('soh-popup'), findsNothing);
  });

  testWidgets('wifi rows: details popup, disconnect, scan spinner, toggle', (tester) async {
    await pumpApp(tester);
    container.read(settingsScreenOpenProvider.notifier).open();
    await settle(tester);
    await tester.tap(k('section-connectivity'));
    await settle(tester);
    expect(k('wifi-ServiceCenter'), findsOneWidget);
    await tester.tap(k('wifi-HomeWifi_5G'));
    await settle(tester);
    expect(k('wifi-details'), findsOneWidget);
    expect(find.text('Strong'), findsOneWidget);
    await tester.tap(k('wifi-disconnect'));
    await tester.pump(const Duration(milliseconds: 1100));
    await settle(tester);
    expect(container.read(wifiProvider).connectedSsid, isNull);
    expect(find.text('Disconnected from HomeWifi_5G'), findsOneWidget);
    await tester.tap(k('wifi-scan'));
    await tester.pump();
    expect(k('wifi-scanning'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2100));
    await settle(tester);
    expect(k('wifi-scan'), findsOneWidget);
  });

  testWidgets('status bar: temperature icon thresholds', (tester) async {
    await pumpApp(tester);
    expect(k('status-temp'), findsNothing);
    v().setBatteryTemp(45);
    await settle(tester);
    expect(tester.widget<ThermometerIcon>(find.byType(ThermometerIcon)).color, DashColors.warning);
    v().setBatteryTemp(55);
    await settle(tester);
    expect(tester.widget<ThermometerIcon>(find.byType(ThermometerIcon)).color, DashColors.critical);
  });

  testWidgets('reverse wordmark, kept while it moves and left at a stop, and brightness button', (tester) async {
    await pumpApp(tester);
    expect(find.text('REVERSE'), findsNothing);
    v().activateReverse();
    await settle(tester);
    expect(find.text('REVERSE'), findsOneWidget);
    v().setSpeed(8);
    await settle(tester);
    expect(find.text('REVERSE'), findsOneWidget, reason: 'backing up is still reverse');
    v().activateReverse();
    await settle(tester);
    expect(find.text('REVERSE'), findsOneWidget, reason: 'not while moving');
    v().setSpeed(0);
    await settle(tester);
    v().activateReverse();
    await settle(tester);
    expect(find.text('REVERSE'), findsNothing);
    await tester.tap(k('ctl-handle'));
    await settle(tester);
    await tester.tap(k('ctl-brightness'));
    await settle(tester);
    expect(container.read(brightnessProvider), 100);
    expect(find.text('Brightness: High'), findsOneWidget);
  });

  testWidgets('licenses screen opens from About and shows the list', (tester) async {
    // The list is Flutter's LicenseRegistry, not six
    // hard-coded names.
    LicenseRegistry.reset();
    addTearDown(LicenseRegistry.reset);
    LicenseRegistry.addLicense(() => Stream.fromIterable(const [
          LicenseEntryWithLineBreaks(['riverpod'], 'MIT License\n\nPermission is hereby granted'),
          LicenseEntryWithLineBreaks(['grpc', 'protobuf'], 'Apache License 2.0'),
        ]));
    await pumpApp(tester);
    container.read(settingsScreenOpenProvider.notifier).open();
    await settle(tester);
    await tester.tap(k('section-about'));
    await settle(tester);
    await tester.tap(k('about-licenses'));
    await settle(tester);
    expect(container.read(licensesScreenOpenProvider), isTrue);
    // The apps Apps can install come first, so the packages can start below the fold.
    await tester.scrollUntilVisible(k('license-riverpod'), 200,
        scrollable: find.descendant(of: k('licenses-body'), matching: find.byType(Scrollable)).first);
    await settle(tester);
    expect(k('license-riverpod'), findsOneWidget);
    expect(k('license-grpc'), findsOneWidget);
    expect(k('license-protobuf'), findsOneWidget);
    expect(k('license-flutter_test'), findsNothing);
    await tester.ensureVisible(k('license-riverpod'));
    await settle(tester);
    await tester.tap(k('license-riverpod'));
    await settle(tester);
    expect(k('license-text'), findsOneWidget);
    expect(find.textContaining('Permission is hereby granted'), findsOneWidget);
    await tester.tap(k('license-close'));
    await settle(tester);
    expect(k('license-text'), findsNothing);
    // Back on the list, which opens at its top again.
    expect(k('license-Headunit Revived (from Apps)'), findsOneWidget);
  });

  testWidgets('light theme is offered and the dial keeps its instruments', (tester) async {
    await pumpApp(tester);
    container.read(settingsScreenOpenProvider.notifier).open();
    await settle(tester);
    expect(k('theme-light'), findsOneWidget);
  });
}
