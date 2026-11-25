import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/hhmis_mapping.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/theme/dash_theme.dart';
import 'package:opendash/widgets/gauges/power_bar.dart';
import 'package:opendash/widgets/indicators/telltale_icons.dart';
import 'package:opendash/widgets/indicators/telltale_strip.dart';

void main() {
  group('regen telltale', () {
    Telltale? regen(VehicleData v) => telltalesFor(v).cast<Telltale?>().firstWhere((t) => t!.id == 'regen', orElse: () => null);
    Telltale? regenOff(VehicleData v) => telltalesFor(v).cast<Telltale?>().firstWhere((t) => t!.id == 'regenOff', orElse: () => null);

    test('colour follows regen availability once it is known', () {
      const t = DashTheme.dark;
      // HVDP RegenAvailability: 0 NOT_AVAILABLE, 1 AVAILABLE, 2 NOT_AVAILABLE_THROTTLE.
      const known = VehicleData(regenActive: true, regenNotification: true, regenPowerLimitW: 900, regenAvailabilityKnown: true);
      expect(regen(known.copyWith(regenAvailability: 1))!.color, t.eco);
      expect(regen(known.copyWith(regenAvailability: 0))!.color, t.ash);
      expect(regen(known.copyWith(regenAvailability: 2))!.color, t.ash);
    });

    test('before the first 0x683 the telltale is neutral ash whatever the value holds', () {
      const t = DashTheme.dark;
      for (final value in [0, 1, 2]) {
        final v = VehicleData(regenActive: true, regenNotification: true, regenMode: RegenMode.off, regenPowerLimitW: 1500, regenAvailability: value);
        expect(v.regenAvailabilityKnown, isFalse);
        expect(regen(v)!.color, t.ash, reason: 'value $value');
        expect(regen(v)!.pulse, isFalse);
        expect(regenOff(v.copyWith(regenActive: false, regenPowerLimitW: 0)), isNull, reason: 'no data yet is not off');
      }
    });

    test('description carries the available capacity', () {
      final d = regen(const VehicleData(regenActive: true, regenNotification: true, regenPowerLimitW: 750, regenMode: RegenMode.city))!.description;
      expect(d, contains('50%'));
      expect(regen(const VehicleData(regenActive: true, regenNotification: true, regenMode: RegenMode.city))!.description, contains('City (strong)'));
    });

    test('a zero ceiling shows Regen off instead, only with the motor on', () {
      const known = VehicleData(regenAvailabilityKnown: true, vehicleState: VehicleState.riding);
      expect(regenOff(known.copyWith(regenPowerLimitW: 0, regenAvailability: 0)), isNotNull);
      expect(regenOff(known.copyWith(regenPowerLimitW: 0, regenAvailability: 0))!.color, DashTheme.dark.ash);
      expect(regenOff(known.copyWith(regenPowerLimitW: 0, regenAvailability: 2)), isNull,
          reason: 'NOT_AVAILABLE_THROTTLE is transient, not off');
      expect(regenOff(known.copyWith(regenPowerLimitW: 1500, regenAvailability: 0)), isNull);
      expect(regenOff(known.copyWith(regenPowerLimitW: 0, regenAvailability: 1)), isNull, reason: 'available is not off');
      expect(regenOff(const VehicleData()), isNull, reason: 'no data yet is not off');
    });

    // A parked capture: at 91 % SOC and 33 °C the BMS reports a
    // zero ceiling and nibble 2, which is not "battery full or too cold".
    test('parked, locked or charging never shows Regen off', () {
      for (final state in [VehicleState.parked, VehicleState.charging, VehicleState.unknown]) {
        for (final nibble in [0, 2]) {
          final v = VehicleData(regenAvailabilityKnown: true, vehicleState: state, regenAvailability: nibble);
          expect(regenOff(v), isNull, reason: '$state nibble $nibble');
        }
      }
      expect(regenOff(const VehicleData(regenAvailabilityKnown: true, vehicleState: VehicleState.riding, regenAvailability: 1)),
          isNull, reason: 'riding with regen available');
    });

    test('regen off has its own glyph and never hides active regen', () {
      const known = VehicleData(regenAvailabilityKnown: true, vehicleState: VehicleState.riding);
      final off = regenOff(known.copyWith(regenPowerLimitW: 0, regenAvailability: 0))!;
      expect(off.glyph, TelltaleGlyph.regenOff);
      expect(off.glyph, isNot(TelltaleGlyph.regen));
      final active = known.copyWith(regenActive: true, regenNotification: true, regenPowerLimitW: 0, regenAvailability: 0);
      expect(regen(active), isNotNull, reason: 'recovering energy is shown even when the BMS says unavailable');
      expect(regenOff(active), isNull);
    });

    test('regen capacity is the limit over the full ceiling', () {
      expect(regenCapacity(const VehicleData(regenPowerLimitW: 1500)), 1);
      expect(regenCapacity(const VehicleData(regenPowerLimitW: 750)), closeTo(0.5, 1e-9));
      expect(regenCapacity(const VehicleData(regenPowerLimitW: 0)), 0);
    });
  });

  group('power bar ceiling', () {
    test('fraction uses the BMS discharge ceiling when it is known', () {
      expect(powerBarFraction(4.0, maxPower: 8.0), closeTo(0.5, 1e-9));
      expect(powerBarFraction(4.0, maxPower: 3.0), 1);
      expect(powerBarFraction(-2.0, maxPower: 8.0), closeTo(0.5, 1e-9), reason: 'regen side uses its own ceiling');
      expect(powerBarMaxFor(const VehicleData(dischargePowerLimitW: 0)), PowerBar.defaultMaxPower);
    });

    test('the BMS limit is in pack watts and takes the same display scale as power', () {
      expect(powerBarMaxFor(const VehicleData(dischargePowerLimitW: 3000)), closeTo(2.125, 1e-6));
      // 11807 W at 85 % SOC, 10016 W at the day's lowest.
      expect(powerBarMaxFor(const VehicleData(dischargePowerLimitW: 11807)), closeTo(8.363, 1e-3));
      expect(powerBarMaxFor(const VehicleData(dischargePowerLimitW: 12000)), closeTo(PowerBar.defaultMaxPower, 1e-5));
      // 6 kW out of the pack against a 12 kW limit is half the bar.
      final shown = 6 * HhmisPower.displayScale;
      expect(
        powerBarFraction(shown, maxPower: powerBarMaxFor(const VehicleData(dischargePowerLimitW: 12000))),
        closeTo(0.5, 1e-6),
      );
    });
  });

  group('service indicator', () {
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

    // HVDP never reads bit 43 of 0x353, so the wrench stays hidden until a
    // real capture has shown the bit set (serviceIndicatorVerified).
    testWidgets('wrench stays hidden in the status bar and vehicle info until verified on device', (tester) async {
      expect(VehicleData.serviceIndicatorVerified, isFalse);
      await pumpApp(tester);
      expect(k('status-service'), findsNothing);
      v().setServiceIndicator(true);
      await settle(tester);
      expect(container.read(vehicleProvider).serviceIndicator, isTrue, reason: 'the field and decoder stay intact');
      expect(k('status-service'), findsNothing);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      await tester.tap(k('section-vehicleInfo'));
      await settle(tester);
      expect(find.text('Service due'), findsNothing);
    });

    testWidgets('limp mode paints the range in warning', (tester) async {
      await pumpApp(tester);
      v().setLimpMode(true);
      await settle(tester);
      expect(k('range-limp'), findsOneWidget);
      v().setLimpMode(false);
      await settle(tester);
      expect(k('range-limp'), findsNothing);
    });
  });
}
