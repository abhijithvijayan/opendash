import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/battery_health.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/locked/locked_screen.dart';
import 'package:opendash/state/battery_health_state.dart';
import 'package:opendash/state/format_settings.dart';
import 'package:opendash/state/range_readout.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/theme/colors.dart';
import 'package:opendash/widgets/panel/widget_panel.dart';

class _Vehicle extends VehicleNotifier {
  void put(VehicleData Function(VehicleData v) f) => state = f(state);
}

void main() {
  late ProviderContainer container;
  _Vehicle v() => container.read(vehicleProvider.notifier) as _Vehicle;
  Finder k(String id) => find.byKey(ValueKey(id));
  String text(WidgetTester tester, String id) => tester.widget<Text>(k(id)).data!;
  Color? color(WidgetTester tester, String id) => tester.widget<Text>(k(id)).style!.color;

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
  }

  Future<void> pumpLocked(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [vehicleProvider.overrideWith(_Vehicle.new)],
      child: const OpenDashApp(),
    ));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(LockedScreen), findsOneWidget);
  }

  void setTrueRange(bool on) =>
      container.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.predictedRange, on);

  // 0.5 km per percent: well under the mock's stock figure.
  void seed(int rides) => container.read(batteryHealthProvider.notifier).seedSegments([
        for (var i = 0; i < rides; i++)
          RideSegment(
            startSoc: 90,
            endSoc: 80,
            startOdometer: i * 5,
            endOdometer: i * 5 + 5,
            driveMode: 2,
            avgTempC: 30,
            timestamp: i,
          ),
      ]);

  // A display woken while the scooter sleeps: stock shows nothing to press.
  testWidgets('asleep: black, no keypad, a touch shows how to get out', (tester) async {
    await pumpLocked(tester);
    v().put((d) => d.copyWith(scooterAsleep: true));
    await settle(tester);
    expect(k('lock-asleep'), findsOneWidget);
    expect(k('lock-soc'), findsNothing);
    final hint = find.text('The scooter is asleep');
    double opacity() => tester.widget<AnimatedOpacity>(find.ancestor(of: hint, matching: find.byType(AnimatedOpacity))).opacity;
    expect(opacity(), 0);
    await tester.tap(k('lock-asleep'));
    await settle(tester);
    expect(opacity(), greaterThan(0));
    await tester.pump(AsleepLockView.hintFor);
    expect(opacity(), 0);
    v().put((d) => d.copyWith(scooterAsleep: false));
    await settle(tester);
    expect(k('lock-soc'), findsOneWidget);
  });

  group('lock-screen range', () {
    testWidgets('setting off: stock range, "km range"', (tester) async {
      await pumpLocked(tester);
      seed(8);
      setTrueRange(false);
      await settle(tester);
      expect(text(tester, 'lock-range'), '${container.read(vehicleProvider).range}');
      expect(text(tester, 'lock-range-caption'), 'km range');
    });

    testWidgets('setting on, confidence >= 70: the learned range, exact, captioned "range"', (tester) async {
      await pumpLocked(tester);
      seed(8);
      await settle(tester);
      final tr = container.read(trueRangeProvider);
      expect(tr.confidencePercent, 80);
      expect(tr.trueRangeKm, isNot(tr.stockRangeKm));
      expect(text(tester, 'lock-range'), '${tr.trueRangeKm}');
      expect(text(tester, 'lock-range-caption'), 'km range');
      expect(color(tester, 'lock-range'), DashColors.bone);
    });

    testWidgets('confidence 30-69: the learned range, rounded to 5 and dimmed, no symbol', (tester) async {
      await pumpLocked(tester);
      seed(4);
      await settle(tester);
      final tr = container.read(trueRangeProvider);
      expect(tr.confidencePercent, 40);
      expect(text(tester, 'lock-range'), '${(tr.trueRangeKm / 5).round() * 5}');
      expect(color(tester, 'lock-range'), DashColors.ash);
      expect(find.text('~'), findsNothing);
      expect(text(tester, 'lock-range-caption'), 'km range');
    });

    testWidgets('confidence < 30: stock range', (tester) async {
      await pumpLocked(tester);
      seed(2);
      await settle(tester);
      expect(container.read(trueRangeProvider).confidencePercent, 20);
      expect(text(tester, 'lock-range'), '${container.read(vehicleProvider).range}');
      expect(text(tester, 'lock-range-caption'), 'km range');
    });

    // 0x6F4 word 0 is the Eco range, so limp shows the VCU's
    // own figure, never the learned one and never the Eco word.
    testWidgets('limp: the VCU range in critical, "km limp"', (tester) async {
      await pumpLocked(tester);
      seed(8);
      v().setLimpMode(true);
      v().put((s) => s.copyWith(rangeEcoCan: 7));
      await settle(tester);
      expect(text(tester, 'lock-range'), '${container.read(vehicleProvider).range}');
      expect(text(tester, 'lock-range-caption'), 'km limp');
      expect(color(tester, 'lock-range'), DashColors.critical);
      expect(color(tester, 'lock-range-caption'), DashColors.critical);
    });

    testWidgets('no "Stock:" sub-line, even when true and stock disagree', (tester) async {
      await pumpLocked(tester);
      seed(8);
      await settle(tester);
      expect(container.read(rangeReadoutProvider).stockKm, isNotNull);
      expect(find.textContaining('Stock:'), findsNothing);
    });

    testWidgets('unlocking shows the same figure on the home battery page', (tester) async {
      await pumpLocked(tester);
      seed(4);
      await settle(tester);
      final onLock = text(tester, 'lock-range');
      v().setLocked(false);
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      expect(find.byType(LockedScreen), findsNothing);
      expect(find.descendant(of: find.byType(BatteryPage), matching: find.text(onLock)), findsOneWidget);
      expect(tester.widget<Text>(k('range-caption')).data, 'range');
    });

    testWidgets('miles: converted figure and "mi" caption', (tester) async {
      await pumpLocked(tester);
      setTrueRange(false);
      v().put((s) => s.copyWith(range: 161));
      container.read(useMilesProvider.notifier).set(true);
      await settle(tester);
      expect(text(tester, 'lock-range'), '100');
      expect(text(tester, 'lock-range-caption'), 'mi range');
    });
  });

  group('lock-screen "—"', () {
    testWidgets('stale data blanks SOC and range, and they return with data', (tester) async {
      await pumpLocked(tester);
      await settle(tester);
      expect(text(tester, 'lock-soc'), '${container.read(vehicleProvider).batterySoc}');
      v().put((s) => s.copyWith(hhmisStale: true));
      await settle(tester);
      expect(text(tester, 'lock-soc'), '—');
      expect(text(tester, 'lock-range'), '—');
      v().put((s) => s.copyWith(hhmisStale: false));
      await settle(tester);
      expect(text(tester, 'lock-soc'), '${container.read(vehicleProvider).batterySoc}');
      expect(text(tester, 'lock-range'), isNot('—'));
    });

    testWidgets('connected but SOC / range not received yet: each blank on its own', (tester) async {
      await pumpLocked(tester);
      v().put((s) => s.copyWith(socSeen: false, rangeSeen: false));
      await settle(tester);
      expect(text(tester, 'lock-soc'), '—');
      expect(text(tester, 'lock-range'), '—');
      v().put((s) => s.copyWith(socSeen: true));
      await settle(tester);
      expect(text(tester, 'lock-soc'), '${container.read(vehicleProvider).batterySoc}');
      expect(text(tester, 'lock-range'), '—', reason: 'range has still not arrived');
    });
  });
}
