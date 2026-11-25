import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/battery_health.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/safe_mode/safe_mode_screen.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/range_readout.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/widget_panel_state.dart';
import 'package:opendash/widgets/gauges/battery_ring.dart';
import 'package:opendash/widgets/overlays/nav_overlay.dart';
import 'package:opendash/widgets/panel/widget_panel.dart';
import 'package:opendash/widgets/status_bar/overlay_toolbar.dart';

class _Vehicle extends VehicleNotifier {
  void put(VehicleData Function(VehicleData v) f) => state = f(state);
}

TrueRange _tr({int stock = 100, int learned = 80, int conf = 80}) => TrueRange(
      stockRangeKm: stock,
      trueRangeKm: learned,
      confidencePercent: conf,
      kmPerPercent: 1,
      ridesUsed: conf ~/ 10,
    );

void main() {
  group('rangeReadout', () {
    RangeReadout r({bool known = true, bool limp = false, bool on = true, TrueRange? tr}) =>
        rangeReadout(known: known, limp: limp, trueRangeOn: on, trueRange: tr ?? _tr());

    test('setting off: the stock figure', () {
      expect(r(on: false), const RangeReadout(km: 100, kind: RangeKind.stock));
    });

    test('confidence gates the learned figure at 30 and the ~ at 70', () {
      expect(r(tr: _tr(conf: 29)), const RangeReadout(km: 100, kind: RangeKind.stock));
      expect(r(tr: _tr(conf: 30)), const RangeReadout(km: 80, kind: RangeKind.trueRange, approx: true, stockKm: 100));
      expect(r(tr: _tr(conf: 69)).approx, isTrue);
      expect(r(tr: _tr(conf: 70)), const RangeReadout(km: 80, kind: RangeKind.trueRange, stockKm: 100));
    });

    test('stock figure rides along only past a 10 % disagreement', () {
      expect(r(tr: _tr(learned: 90)).stockKm, isNull);
      expect(r(tr: _tr(learned: 89)).stockKm, 100);
      expect(r(tr: _tr(learned: 111)).stockKm, 100);
      expect(r(tr: _tr(stock: 0, learned: 40)).stockKm, isNull);
    });

    test('limp: the VCU figure, whatever the learned one says', () {
      expect(r(limp: true), const RangeReadout(km: 100, kind: RangeKind.limp));
      expect(r(limp: true, on: false), const RangeReadout(km: 100, kind: RangeKind.limp));
    });

    test('unknown: no figure, no ~, no stock line, caption kept', () {
      expect(r(known: false), const RangeReadout(km: null, kind: RangeKind.trueRange));
      expect(r(known: false, on: false), const RangeReadout(km: null, kind: RangeKind.stock));
      expect(r(known: false, limp: true), const RangeReadout(km: null, kind: RangeKind.limp));
    });
  });

  group('VehicleData known getters', () {
    test('defaults (the mock) are known once connected', () {
      const v = VehicleData(hhmisConnected: true);
      expect([v.hhmisKnown, v.socKnown, v.rangeKnown, v.motorTempKnown, v.batteryTempKnown], everyElement(isTrue));
    });

    test('not connected or stale: nothing is known', () {
      for (final v in const [VehicleData(), VehicleData(hhmisConnected: true, hhmisStale: true)]) {
        expect([v.hhmisKnown, v.socKnown, v.rangeKnown, v.motorTempKnown, v.batteryTempKnown], everyElement(isFalse));
      }
    });

    test('each value waits for its own first arrival', () {
      const v = VehicleData(hhmisConnected: true, socSeen: false, rangeSeen: false, motorTempSeen: false, batteryTempSeen: false);
      expect(v.hhmisKnown, isTrue);
      expect(v.copyWith(socSeen: true).socKnown, isTrue);
      expect(v.copyWith(socSeen: true).rangeKnown, isFalse);
      expect(v.copyWith(rangeSeen: true).rangeKnown, isTrue);
      expect(v.copyWith(motorTempSeen: true).motorTempKnown, isTrue);
      expect(v.copyWith(motorTempSeen: true).batteryTempKnown, isFalse);
      expect(v.copyWith(batteryTempSeen: true).batteryTempKnown, isTrue);
      expect(v.copyWith(socSeen: true), isNot(v), reason: 'the flags are part of equality');
    });
  });

  // The seeds (100 %, 180 km, 30°, 28°) were on screen
  // until HHMIS sent the value.
  group('"—" before the value arrives', () {
    late ProviderContainer container;
    _Vehicle v() => container.read(vehicleProvider.notifier) as _Vehicle;
    Finder k(String id) => find.byKey(ValueKey(id));
    Finder dashIn(Finder f) => find.descendant(of: f, matching: find.text('—'));

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
    }

    Future<void> pumpApp(WidgetTester tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [vehicleProvider.overrideWith(_Vehicle.new)],
        child: const OpenDashApp(),
      ));
      await tester.pump();
      container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 500));
      v().setLocked(false);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 500));
    }

    void unseen() =>
        v().put((s) => s.copyWith(socSeen: false, rangeSeen: false, motorTempSeen: false, batteryTempSeen: false));
    void seen() =>
        v().put((s) => s.copyWith(socSeen: true, rangeSeen: true, motorTempSeen: true, batteryTempSeen: true));

    testWidgets('battery page: ring and range', (tester) async {
      await pumpApp(tester);
      expect(k('range-unknown'), findsNothing, reason: 'the mock shows values');
      expect(dashIn(find.byType(BatteryRing)), findsNothing);
      unseen();
      await settle(tester);
      expect(dashIn(find.byType(BatteryRing)), findsOneWidget);
      expect(k('range-unknown'), findsOneWidget);
      expect(k('battery-hot'), findsNothing);
      seen();
      await settle(tester);
      expect(k('range-unknown'), findsNothing);
      expect(dashIn(find.byType(BatteryRing)), findsNothing);
    });

    testWidgets('battery page blanks while stale too', (tester) async {
      await pumpApp(tester);
      v().put((s) => s.copyWith(hhmisStale: true));
      await settle(tester);
      expect(dashIn(find.byType(BatteryRing)), findsOneWidget);
      expect(k('range-unknown'), findsOneWidget);
    });

    testWidgets('a hot seed never tints an unknown battery temperature', (tester) async {
      await pumpApp(tester);
      v().put((s) => s.copyWith(batteryTemp: 58, batteryTempSeen: false));
      await settle(tester);
      expect(k('battery-hot'), findsNothing);
    });

    testWidgets('performance page: motor temperature', (tester) async {
      await pumpApp(tester);
      container.read(widgetPageProvider.notifier).set(1);
      await settle(tester);
      expect(dashIn(k('motor-temp')), findsNothing);
      v().put((s) => s.copyWith(motorTempSeen: false));
      await settle(tester);
      expect(dashIn(k('motor-temp')), findsOneWidget);
      expect(find.descendant(of: k('motor-temp'), matching: find.text('HOT')), findsNothing);
    });

    testWidgets('overlay toolbar battery', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      expect(find.byType(OverlayToolbar), findsOneWidget);
      expect(tester.widget<Text>(k('toolbar-battery')).data, '${container.read(vehicleProvider).batterySoc}%');
      unseen();
      await settle(tester);
      expect(tester.widget<Text>(k('toolbar-battery')).data, '—');
    });

    testWidgets('diagnostics live data: SoC, range and both temperatures', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      container.read(diagnosticsOpenProvider.notifier).open();
      await settle(tester);
      await tester.tap(k('diag-tab-liveData'));
      await settle(tester);
      for (final label in ['Battery SoC', 'Battery Temp', 'Range', 'Motor Temp']) {
        expect(dashIn(k('diag-$label')), findsNothing, reason: label);
      }
      unseen();
      await settle(tester);
      for (final label in ['Battery SoC', 'Battery Temp', 'Range', 'Motor Temp']) {
        expect(dashIn(k('diag-$label')), findsOneWidget, reason: label);
      }
      expect(dashIn(k('diag-Speed')), findsNothing);
    });

    Future<void> pumpAlone(WidgetTester tester, Widget child) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [vehicleProvider.overrideWith(_Vehicle.new)],
        child: Directionality(textDirection: TextDirection.ltr, child: Center(key: const ValueKey('alone'), child: child)),
      ));
      container = ProviderScope.containerOf(tester.element(k('alone')));
      v().setConnected(true);
      await settle(tester);
    }

    testWidgets('nav overlay battery', (tester) async {
      await pumpAlone(tester, const NavOverlay());
      expect(tester.widget<Text>(k('nav-battery')).data, '${container.read(vehicleProvider).batterySoc}%');
      unseen();
      await settle(tester);
      expect(tester.widget<Text>(k('nav-battery')).data, '—');
    });

    testWidgets('safe-mode screen battery', (tester) async {
      await pumpAlone(tester, const SizedBox(width: 1280, height: 768, child: SafeModeScreen()));
      expect(find.text('${container.read(vehicleProvider).batterySoc}%'), findsOneWidget);
      unseen();
      await settle(tester);
      expect(find.text('${container.read(vehicleProvider).batterySoc}%'), findsNothing);
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('BatteryRing with no SOC is an empty ring', (tester) async {
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: BatteryRing(soc: null, accent: Color(0xFF00FF00))),
      ));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('—'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('DataCard with known: false shows a dash, not the value', (tester) async {
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: DataCard(label: 'Motor temp', value: 30, unit: '°C', known: false)),
      ));
      expect(find.text('—'), findsOneWidget);
      expect(find.text('30'), findsNothing);
    });
  });
}
