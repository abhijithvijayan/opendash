import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/providers/battery_diagnostics_provider.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/charge_energy_state.dart';
import 'package:opendash/state/theme_state.dart';
import 'package:opendash/theme/colors.dart';
import 'package:opendash/theme/dash_theme.dart';

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

  testWidgets('energy stats accumulate while charging', (tester) async {
    await pumpApp(tester);
    v().setBattery(40);
    v().setCharging(true);
    await settle(tester);
    expect(find.text('energy used'), findsOneWidget);
    expect(find.text('charging power'), findsOneWidget);
    expect(find.descendant(of: k('charge-energy'), matching: find.text('0.00 kWh'), matchRoot: true), findsOneWidget);
    await tester.pump(const Duration(seconds: 60));
    await settle(tester);
    final kwh = container.read(chargeEnergyProvider).currentKwh;
    expect(kwh, greaterThan(0));
    expect(find.descendant(of: k('charge-energy'), matching: find.text('${kwh.toStringAsFixed(2)} kWh'), matchRoot: true), findsOneWidget);
    final power = container.read(chargeEnergyProvider).chargingPowerKw;
    expect(find.descendant(of: k('charge-power'), matching: find.text('${power.toStringAsFixed(2)} kW'), matchRoot: true), findsOneWidget);
  });

  testWidgets('balancing caption shows only while the BMS balances', (tester) async {
    await pumpApp(tester);
    v().setCharging(true);
    await settle(tester);
    expect(find.text('Cell balancing in progress'), findsNothing);
    container.read(batteryDiagnosticsProvider.notifier).setBalancing(true);
    await settle(tester);
    expect(find.text('Cell balancing in progress'), findsOneWidget);
    container.read(batteryDiagnosticsProvider.notifier).setBalancing(false);
    await settle(tester);
    expect(find.text('Cell balancing in progress'), findsNothing);
  });

  testWidgets('charge history expands to the last five sessions', (tester) async {
    await pumpApp(tester);
    v().setCharging(true);
    await settle(tester);
    expect(k('charge-history-toggle'), findsOneWidget);
    expect(k('charge-history-row-0'), findsNothing);
    await tester.tap(k('charge-history-toggle'));
    await settle(tester);
    expect(k('charge-history-row-0'), findsOneWidget);
    expect(k('charge-history-row-2'), findsOneWidget);
    expect(k('charge-history-row-3'), findsNothing, reason: 'only three seeded sessions');
    expect(find.textContaining('32→98%'), findsOneWidget);
    expect(find.textContaining('1.84 kWh'), findsOneWidget);
    expect(find.textContaining('48 min'), findsOneWidget);
    await tester.tap(k('charge-history-toggle'));
    await settle(tester);
    expect(k('charge-history-row-0'), findsNothing);
  });

  // On the Light theme the charging screen was once a white panel.
  testWidgets('the charging screen is dark even on the Light theme, and the choice comes back after', (tester) async {
    await pumpApp(tester);
    container.read(themeProvider.notifier).setTheme(DashTheme.light);
    await settle(tester);
    expect(container.read(shownThemeProvider).isLight, isTrue);
    v().setCharging(true);
    await settle(tester);
    expect(container.read(themeProvider).name, 'Light', reason: "the rider's choice is untouched");
    expect(container.read(shownThemeProvider).isLight, isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(DashColors.current.isLight, isFalse);
    v().setCharging(false);
    await settle(tester);
    expect(container.read(shownThemeProvider).isLight, isTrue);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the boot opens from the charging screen', (tester) async {
    await pumpApp(tester);
    v().setCharging(true);
    await settle(tester);
    expect(container.read(vehicleProvider).trunkOpen, isFalse);
    await tester.tap(k('dash-trunk'));
    await settle(tester);
    expect(container.read(vehicleProvider).trunkOpen, isTrue);
  });
}
