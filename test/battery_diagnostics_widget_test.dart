import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/dev/dev_panel.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/battery_diagnostics.dart';
import 'package:opendash/providers/battery_diagnostics_provider.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/diagnostics/cell_bar_chart.dart';
import 'package:opendash/screens/diagnostics/diagnostics_screen.dart';
import 'package:opendash/screens/diagnostics/temp_heatmap.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/theme_state.dart';
import 'package:opendash/theme/colors.dart';
import 'package:opendash/theme/dash_theme.dart';
import 'package:opendash/theme/tokens.dart';
import 'package:opendash/widgets/indicators/telltale_icons.dart';
import 'package:opendash/widgets/status_bar/status_bar.dart';
import 'package:opendash/widgets/status_bar/status_icons.dart';

void main() {
  late ProviderContainer container;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);
  BatteryDiagnosticsNotifier bat() => container.read(batteryDiagnosticsProvider.notifier);
  Finder k(String id) => find.byKey(ValueKey(id));

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenDashApp()));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    v().setLocked(false);
    await settle(tester);
  }

  Future<void> openDiagnostics(WidgetTester tester) async {
    await pumpApp(tester);
    container.read(settingsScreenOpenProvider.notifier).open();
    container.read(diagnosticsOpenProvider.notifier).open();
    await settle(tester);
  }

  group('diagnostics tabs', () {
    testWidgets('battery is the default tab and all three are reachable and tall enough', (tester) async {
      await openDiagnostics(tester);
      expect(container.read(diagTabProvider), DiagTab.battery);
      expect(k('diag-battery'), findsOneWidget);
      for (final t in DiagTab.values) {
        expect(tester.getSize(k('diag-tab-${t.name}')).height, greaterThanOrEqualTo(DashTouch.min), reason: t.name);
      }
      await tester.tap(k('diag-tab-liveData'));
      await settle(tester);
      expect(k('diag-Speed'), findsOneWidget);
      await tester.tap(k('diag-tab-faultCodes'));
      await settle(tester);
      expect(find.text('No active faults'), findsOneWidget);
      await tester.tap(k('diag-tab-battery'));
      await settle(tester);
      expect(k('diag-battery'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('connections tab shows the data sources and refreshes', (tester) async {
      await openDiagnostics(tester);
      await tester.tap(k('diag-tab-connections'));
      await settle(tester);
      expect(k('diag-connections'), findsOneWidget);
      for (final h in ['VEHICLE DATA (HHMIS)', 'CAN BUS (GRPC)', 'APP']) {
        expect(find.text(h, skipOffstage: false), findsOneWidget, reason: h);
      }
      expect(find.text('Mock data'), findsNWidgets(2), reason: 'tests run on the mock providers');
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
      await tester.tap(k('diag-tab-battery'));
      await settle(tester);
    });

    testWidgets('live data is grouped under four section headers', (tester) async {
      await openDiagnostics(tester);
      await tester.tap(k('diag-tab-liveData'));
      await settle(tester);
      for (final h in ['POWERTRAIN', 'BATTERY', 'VEHICLE', 'INDICATORS']) {
        expect(find.text(h, skipOffstage: false), findsOneWidget, reason: h);
      }
      final powertrain = tester.getRect(find.text('POWERTRAIN'));
      final speed = tester.getRect(k('diag-Speed'));
      final battery = tester.getRect(find.text('BATTERY'));
      expect(speed.top, greaterThan(powertrain.bottom));
      expect(battery.top, greaterThan(speed.bottom));
      for (final id in ['Speed', 'RPM', 'Power', 'Torque', 'Battery SoC', 'Battery Temp', 'Regen Energy', 'Range',
          'Drive Mode', 'Vehicle State', 'Lock State', 'Turn Left', 'Turn Right', 'High Beam', 'Side Stand', 'Trunk Open']) {
        expect(find.byKey(ValueKey('diag-$id'), skipOffstage: false), findsOneWidget, reason: id);
      }
    });
  });

  group('battery tab', () {
    testWidgets('stat tiles show health, spread, average and balance', (tester) async {
      await openDiagnostics(tester);
      final d = container.read(batteryDiagnosticsProvider);
      // The headline tile is measured capacity (from charge history), not
      // the SoH that reads 100 on a worn pack.
      expect(find.descendant(of: k('diag-capacity'), matching: find.textContaining('kWh')), findsOneWidget);
      expect(find.descendant(of: k('diag-capacity'), matching: find.textContaining('Capacity (measured)')), findsOneWidget);
      expect(find.descendant(of: k('diag-spread'), matching: find.text('${d.cellSpreadMv!.round()} mV')), findsOneWidget);
      expect(find.descendant(of: k('diag-avg'), matching: find.text('${d.cellAvgV!.toStringAsFixed(3)} V')), findsOneWidget);
      expect(find.descendant(of: k('diag-balance'), matching: find.text('Even')), findsOneWidget);
      for (final id in ['diag-capacity', 'diag-spread', 'diag-avg', 'diag-balance']) {
        expect(tester.getSize(k(id)).height, greaterThanOrEqualTo(72), reason: id);
      }
      bat().setDegradedCells(true);
      await settle(tester);
      expect(find.descendant(of: k('diag-balance'), matching: find.text('Uneven')), findsOneWidget);
      final spread = tester.widget<AnimatedDefaultTextStyle>(
          find.descendant(of: k('diag-spread'), matching: find.byType(AnimatedDefaultTextStyle)));
      expect(spread.style.color, DashColors.critical, reason: 'spread beyond 40mV');
      // Tapping a tile with an info id reveals its explanation and range.
      await tester.tap(k('diag-spread'));
      await settle(tester);
      expect(find.textContaining('weak or ageing cell'), findsOneWidget);
      expect(find.textContaining('Under 20 mV healthy'), findsOneWidget);
    });

    testWidgets('cell chart paints fourteen bars, green unless a cell strays', (tester) async {
      await openDiagnostics(tester);
      CellBarChartPainter painter() => tester.widget<CustomPaint>(k('cell-chart')).painter as CellBarChartPainter;
      expect(painter().cells.length, 14);
      final rects = painter().barRects(const Size(560, 200));
      expect(rects.length, 14);
      for (var i = 1; i < rects.length; i++) {
        expect(rects[i].left, greaterThan(rects[i - 1].right), reason: 'bars do not overlap');
      }
      expect(rects.every((r) => r.height > 0), isTrue);
      expect(painter().cells.map(painter().colorFor), everyElement(DashColors.eco));
      expect(painter().avgVoltage, closeTo(container.read(batteryDiagnosticsProvider).cellAvgV!, 1e-9));
      bat().setDegradedCells(true);
      await settle(tester);
      expect(painter().colorFor(painter().cells[2]), DashColors.warning);
      expect(painter().colorFor(painter().cells[10]), DashColors.warning);
      expect(painter().colorFor(painter().cells[0]), DashColors.eco);
      expect(painter().colorFor(const CellReading(index: 1, voltage: 0, deviationMv: 0, state: CellState.missing)), DashColors.inkLift);
    });

    testWidgets('heatmap shows the sensors plus the balancing resistor, a legend, and warms with the pack', (tester) async {
      await openDiagnostics(tester);
      // Six pack sensors, controller, motor, and the balancing resistor.
      expect(find.byType(TempTile), findsNWidgets(9));
      expect(k('temp-legend'), findsOneWidget);
      expect(tester.widgetList<TempTile>(find.byType(TempTile)).where((t) => t.reading.label == 'Balancing').length, 1,
          reason: 'resistor temp sits in the grid as a tile, not buried in a text row');
      for (final t in tester.widgetList<TempTile>(find.byType(TempTile))) {
        expect(tester.getRect(find.byWidget(t)).height, greaterThanOrEqualTo(56 * (tester.getRect(k('diag-body')).height / 768)));
      }
      expect(find.text('Controller'), findsOneWidget);
      expect(find.text('Motor'), findsOneWidget);
      Color tile(int i) => tester.widget<TempTile>(k('temp-tile-$i')).color;
      final cool = tile(0);
      bat().setHotPack(true);
      await settle(tester);
      expect(tile(0), isNot(cool));
      expect(tile(0).r, greaterThan(tile(0).b), reason: 'hot reads red, not blue');
      expect(cool.b, greaterThan(cool.r), reason: 'a 32° pack reads cool');
    });

    test('tile colour interpolates through the four stops', () {
      expect(tempTileColor(20), const Color(0xFF1a3a4a));
      expect(tempTileColor(35), const Color(0xFF2a3a2a));
      expect(tempTileColor(45), const Color(0xFF4a3a1a));
      expect(tempTileColor(55), const Color(0xFF5a2020));
      expect(tempTileColor(70), const Color(0xFF5a2020), reason: 'clamped above the top stop');
      expect(tempTileColor(10), const Color(0xFF1a3a4a), reason: 'clamped below the bottom stop');
      expect(tempTileColor(40), Color.lerp(const Color(0xFF2a3a2a), const Color(0xFF4a3a1a), 0.5));
      expect(tempTileColor(double.nan), const Color(0xFF1f2329), reason: 'a silent sensor reads neutral grey, not hot');
      expect(legendStops, [0, closeTo(15 / 35, 1e-9), closeTo(25 / 35, 1e-9), 1]);
    });

    test('the balancing resistor runs on its own warmer scale', () {
      // Sola calls 20-60C the healthy band, so a 46C resistor should read
      // calm, not the amber the 20-55 pack scale would paint it.
      expect(tempTileColor(46, resistorTempStops).r, lessThan(tempTileColor(46).r),
          reason: '46C is less red on the resistor scale than on the pack scale');
      expect(tempTileColor(68, resistorTempStops), resistorTempStops.last.$2, reason: 'hot clamps to red');
      expect(tempTileColor(20, resistorTempStops), resistorTempStops.first.$2);
    });

    testWidgets('pack electrical lists voltage, current, power, limits and balancing', (tester) async {
      await openDiagnostics(tester);
      final d = container.read(batteryDiagnosticsProvider);
      final body = tester.getRect(k('diag-body'));
      expect(tester.getRect(find.text('Inactive')).left, lessThan(body.center.dx), reason: 'pack electrical sits under the chart');
      final chart = tester.getRect(k('cell-chart'));
      final electrical = tester.getRect(find.text('PACK ELECTRICAL'));
      expect(electrical.top, greaterThan(chart.bottom));
      expect(find.text('${d.busVoltage!.toStringAsFixed(2)} V'), findsOneWidget);
      expect(find.text('+0.5 A'), findsOneWidget);
      expect(find.text('+${d.packPowerKw!.toStringAsFixed(2)} kW'), findsOneWidget);
      v().setPower(-2);
      await settle(tester);
      expect(find.textContaining(RegExp(r'^-\d+\.\d A$')), findsOneWidget);
      expect(find.text('-2.00 kW'), findsOneWidget);
      v().setPower(0);
      await settle(tester);
      expect(find.text('18000 W'), findsOneWidget);
      expect(find.text('3200 W'), findsOneWidget);
      expect(find.text('Inactive'), findsOneWidget);
      bat().setBalancing(true);
      await settle(tester);
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Inactive'), findsNothing);
    });
  });

  group('dev panel', () {
    testWidgets('battery toggles drive the mock', (tester) async {
      await openDiagnostics(tester);
      container.read(devPanelOpenProvider.notifier).toggle();
      await settle(tester);
      final list = find.descendant(of: find.byType(DevPanel), matching: find.byType(ListView));
      for (final id in ['dev-degraded-cells', 'dev-hot-pack', 'dev-balancing']) {
        await tester.scrollUntilVisible(k(id), 200, scrollable: find.descendant(of: list, matching: find.byType(Scrollable)).first);
        await settle(tester);
        await tester.tap(find.descendant(of: k(id), matching: find.byType(Switch)));
        await settle(tester);
      }
      final d = container.read(batteryDiagnosticsProvider);
      expect(d.balancingNeeded, isTrue);
      expect(d.temps.first.tempC, greaterThanOrEqualTo(48));
      expect(d.balancingActive, isTrue);
    });
  });

  group('toolbar and trunk polish', () {
    testWidgets('the toolbar carries a battery icon left of the percentage', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      final icon = find.descendant(of: k('overlay-toolbar'), matching: find.byType(BatteryIcon));
      expect(icon, findsOneWidget);
      final size = tester.getSize(icon);
      expect(size.height, inInclusiveRange(16, 18));
      expect(tester.getRect(icon).right, lessThanOrEqualTo(tester.getRect(k('toolbar-battery')).left));
      expect(tester.widget<BatteryIcon>(icon).soc, container.read(vehicleProvider).batterySoc);
    });

    testWidgets('the halo status icon follows the theme eco colour', (tester) async {
      await pumpApp(tester);
      v().setPositionLight(true);
      await settle(tester);
      TelltaleIcon halo() => tester.widget<TelltaleIcon>(k('status-position-light'));
      expect(halo().color, DashTheme.light.eco);
      container.read(themeProvider.notifier).setTheme(DashTheme.ember);
      await tester.pump(const Duration(milliseconds: 700));
      await settle(tester);
      expect(halo().color, DashTheme.ember.eco);
      expect(halo().color, isNot(DashTheme.light.eco));
      expect(find.byType(StatusBar), findsOneWidget);
    });

    testWidgets('the trunk label sits under its icon', (tester) async {
      await pumpApp(tester);
      final icon = tester.getRect(find.descendant(of: k('dash-trunk'), matching: find.byType(TrunkOpenIcon)));
      final label = tester.getRect(find.descendant(of: k('dash-trunk'), matching: find.text('TRUNK')));
      expect(label.top, greaterThanOrEqualTo(icon.bottom));
      expect((label.center.dx - icon.center.dx).abs(), lessThan(1));
      final size = tester.getSize(k('dash-trunk'));
      expect(size.width, greaterThanOrEqualTo(72));
      expect(size.height, greaterThanOrEqualTo(72));
    });
  });

  group('true range toggle gating', () {
    testWidgets('diagnostics hides true range tiles when predictedRange is off', (tester) async {
      await openDiagnostics(tester);
      expect(k('diag-true-range'), findsOneWidget);
      expect(k('diag-confidence'), findsOneWidget);
      container.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.predictedRange, false);
      await settle(tester);
      expect(k('diag-true-range'), findsNothing);
      expect(k('diag-stock-range'), findsNothing);
      expect(k('diag-km-pct'), findsNothing);
      expect(k('diag-confidence'), findsNothing);
      expect(k('diag-capacity'), findsOneWidget, reason: 'core tiles remain');
    });

    testWidgets('battery page says "range" whichever figure it shows; the peek is only for the learned one', (tester) async {
      await pumpApp(tester);
      expect(find.text('range'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('range')));
      await settle(tester);
      expect(find.byKey(const ValueKey('range-peek')), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      container.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.predictedRange, false);
      await settle(tester);
      expect(find.text('range'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('range')));
      await settle(tester);
      expect(find.byKey(const ValueKey('range-peek')), findsNothing);
    });
  });
}
