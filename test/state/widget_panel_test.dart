import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/widget_panel_state.dart';
import 'package:opendash/theme/colors.dart';
import 'package:opendash/widgets/panel/performance_page.dart';
import 'package:opendash/widgets/panel/rpm_gauge.dart';
import 'package:opendash/widgets/panel/widget_panel.dart';
import 'package:opendash/widgets/panel/trip_stats_page.dart';

void main() {
  late ProviderContainer c;
  late VehicleNotifier v;

  setUp(() {
    c = ProviderContainer();
    c.listen(sessionProvider, (_, _) {});
    c.listen(widgetPageProvider, (_, _) {});
    v = c.read(vehicleProvider.notifier);
    v.setConnected(true);
    v.setLocked(false);
  });
  tearDown(() => c.dispose());

  group('widget page', () {
    test('defaults to 0, clamps, and resets on screen and lock changes', () {
      expect(c.read(widgetPageProvider), 0);
      expect(WidgetPage.count, 3);
      final p = c.read(widgetPageProvider.notifier);
      p.set(9);
      expect(c.read(widgetPageProvider), 2);
      v.setCharging(true);
      expect(c.read(widgetPageProvider), 0);
      v.setCharging(false);
      p.set(2);
      v.setLocked(true);
      expect(c.read(widgetPageProvider), 0);
      v.setLocked(false);
      p.set(1);
      v.setSpeed(20);
      expect(c.read(widgetPageProvider), 0, reason: 'riding transition');
      v.setSpeed(0);
      p.set(1);
      c.read(sessionProvider.notifier).sleep();
      expect(c.read(widgetPageProvider), 0);
    });
  });

  group('gauge maths', () {
    // The gauge takes real rpm (HHMIS hundreds x VehicleData.rpmUnit); the
    // recorded rides peaked at 36 raw = 3,600 at 117 km/h.
    test('rpm text is the real figure with a thousands separator', () {
      expect(rpmText(0), '0');
      expect(rpmText(900), '900');
      expect(rpmText(36 * VehicleData.rpmUnit), '3,600');
    });

    // The log-derived ratio: 0.311 raw units per km/h, floored as HHMIS does.
    test('the mock reports rpm in the same raw units as HHMIS', () {
      v.setSpeed(100);
      expect(c.read(vehicleProvider).rpm, 31);
      v.setSpeed(0);
      expect(c.read(vehicleProvider).rpm, 0);
    });

    test('rpm sweep scales 0-4000 over 180 degrees and clamps', () {
      expect(rpmSweep(0), 0);
      expect(rpmSweep(2000), closeTo(3.14159 / 2, 1e-3));
      expect(rpmSweep(36.0 * VehicleData.rpmUnit), closeTo(3.14159 * 0.9, 1e-3));
      expect(rpmSweep(4000), closeTo(3.14159, 1e-3));
      expect(rpmSweep(8000), closeTo(3.14159, 1e-3));
    });

    test('power fraction is signed and clamps both ways', () {
      expect(powerFraction(8.5), 1);
      expect(powerFraction(4.25), closeTo(0.5, 1e-9));
      expect(powerFraction(-4), -1);
      expect(powerFraction(-2), closeTo(-0.5, 1e-9));
      expect(powerFraction(20), 1);
    });

    test('temperature colours step at the given thresholds', () {
      // ash at/below warn, warning above warn, critical above danger.
      expect(tempColor(147, warn: 147, danger: 165), DashColors.ash);
      expect(tempColor(148, warn: 147, danger: 165), DashColors.warning);
      expect(tempColor(165, warn: 147, danger: 165), DashColors.warning);
      expect(tempColor(166, warn: 147, danger: 165), DashColors.critical);
    });

    test('thermal limits default to the scooter-read values', () {
      const d = ThermalLimits();
      expect((d.mcuWarn, d.mcuError), (84, 102));
      expect((d.pduWarn, d.pduError), (85, 100));
      expect((d.cellWarn, d.cellError), (55, 62));
      expect((d.motorWarn, d.motorError), (147, 165));
    });

    test('mode breakdown is proportional to the longest ride', () {
      const d = VehicleData(ecoDistance: 50, normalDistance: 200, sportDistance: 100, hyperDistance: 0);
      final f = modeBarFractions(d);
      expect(f[DriveMode.normal], 1);
      expect(f[DriveMode.sport], 0.5);
      expect(f[DriveMode.eco], 0.25);
      expect(f[DriveMode.hyper], 0);
      expect(modeBarFractions(const VehicleData()).values, everyElement(0));
    });

    test('By-mode bars include the custom mode once the scooter has reported it', () {
      const none = VehicleData(ecoDistance: 10, normalDistance: 20);
      expect(modeBars(none).map((b) => b.key), ['eco', 'normal', 'sport', 'hyper'],
          reason: 'no custom row until the scooter says there is one');
      const withCustom = VehicleData(
        ecoDistance: 10,
        normalDistance: 20,
        customRide: CustomRideMode(name: 'Rain', enabled: true, todayKm: 40),
      );
      final bars = modeBars(withCustom);
      expect(bars.map((b) => b.key), ['eco', 'normal', 'sport', 'hyper', 'custom']);
      final custom = bars.last;
      expect(custom.label, 'RAIN');
      expect(custom.km, 40);
      expect(custom.fraction, 1.0, reason: 'longest ride, so full bar');
    });
  });

  group('mock', () {
    test('temperature setters clamp', () {
      // Ceilings reach the scooter's real hot zones (motor winding Parks at
      // 165, cell errors at 62), so the dev sliders can demo the red.
      v.setMotorTemp(250);
      expect(c.read(vehicleProvider).motorTemp, 200);
      v.setBatteryTemp(-3);
      expect(c.read(vehicleProvider).batteryTemp, 0);
      v.setBatteryTemp(63);
      expect(c.read(vehicleProvider).batteryTemp, 63);
      v.setPduTemp(110);
      expect(c.read(vehicleProvider).pduTemp, 110);
      expect(c.read(vehicleProvider).pduTempKnown, isTrue);
    });

    test('demo ride warms the motor while moving and cools it at rest', () {
      v.setDemo(true);
      final start = c.read(vehicleProvider).motorTemp;
      for (var i = 0; i < 30 * 16; i++) {
        v.demoTick(1 / 30);
      }
      final moving = c.read(vehicleProvider);
      expect(moving.speed, greaterThan(0));
      expect(moving.motorTemp, greaterThan(start));
      expect(moving.batteryTemp, inInclusiveRange(33, 37));
      for (var i = 0; i < 30 * 6; i++) {
        v.demoTick(1 / 30);
      }
      final stopped = c.read(vehicleProvider);
      expect(stopped.speed, 0);
      expect(stopped.motorTemp, lessThan(moving.motorTemp));
      v.setDemo(false);
    });
  });
}
