import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/battery_diagnostics.dart';
import 'package:opendash/screens/diagnostics/battery_tab.dart';
import 'package:opendash/screens/diagnostics/diag_info.dart';
import 'package:opendash/theme/colors.dart';

void main() {
  group('balance tile', () {
    test('reads even when the pack is balanced', () {
      final t = balanceTile(BatteryDiagnostics.compute(cellVoltages: List.filled(14, 3.9), temps: const []));
      expect((t.label, t.value, t.color), ('Balance', 'Even', DashColors.eco));
    });

    test('reads uneven amber once a cell strays past 20mV', () {
      final t = balanceTile(BatteryDiagnostics.compute(
          cellVoltages: [...List.filled(13, 3.880), 3.920], temps: const []));
      expect((t.label, t.value, t.color), ('Balance', 'Uneven', DashColors.warning));
    });

    test('flips to a red over-max callout naming the worst cell', () {
      final t = balanceTile(BatteryDiagnostics.compute(
          cellVoltages: [...List.filled(13, 4.300), 4.305], temps: const [], chargeEndCellMv: 4200));
      expect(t.color, DashColors.critical);
      expect(t.label, contains('14'), reason: 'names the worst over cell');
      expect(t.value, contains('4.305'));
    });
  });

  group('diag info', () {
    test('confidence has a plain-language explanation', () {
      expect(infoFor('confidence')!.description, contains('True range'));
    });
    test('the balancing resistor carries its healthy range', () {
      expect(infoFor('balancing-temp')!.range, contains('20'));
    });
    test('temp labels map to their info id, incl. the mock Controller alias', () {
      expect(tempInfoId('MCU'), 'mcu-temp');
      expect(tempInfoId('Controller'), 'mcu-temp');
      expect(tempInfoId('Balancing'), 'balancing-temp');
      expect(tempInfoId('Pack 1'), isNull);
    });
  });

  group('eta label', () {
    test('formats minutes as hours and minutes', () {
      expect(etaLabel(210), '3h 30m');
      expect(etaLabel(45), '45m');
      expect(etaLabel(60), '1h 0m');
    });

    test('is a dash when unknown or zero', () {
      expect(etaLabel(null), '—');
      expect(etaLabel(0), '—');
    });
  });
}
