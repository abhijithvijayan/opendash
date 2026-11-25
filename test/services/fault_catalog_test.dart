import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/services/fault_catalog.dart';

Uint8List bits8(List<int> setBits) {
  final d = Uint8List(8);
  for (final b in setBits) {
    d[b >> 3] |= 1 << (b & 7);
  }
  return d;
}

void main() {
  group('severity from signal name', () {
    test('permanent faults and runaway are critical', () {
      expect(severityForSignal('BMS00_Over_voltage_charge_Permanent_Fault'), FaultSeverity.critical);
      expect(severityForSignal('thermal_runaway_fault'), FaultSeverity.critical);
    });
    test('explicit warnings stay warnings', () {
      expect(severityForSignal('BMS00_Over_voltage_charge_Warning'), FaultSeverity.warning);
    });
    test('a plain error/fault is an error', () {
      expect(severityForSignal('BMS00_Over_voltage_charge_Error'), FaultSeverity.error);
      expect(severityForSignal('Horn_Overcurrent_fault'), FaultSeverity.error);
    });
  });

  group('title humanizing', () {
    test('drops the BMS prefix and tidies over-voltage', () {
      expect(faultTitle('BMS00_Over_voltage_charge_Error'), 'Over-voltage charge Error');
    });
    test('strips Ola\'s grade/info suffixes (incl. the "Gratde" typo)', () {
      expect(faultTitle('Motor_overtemperature_Gratde_3'), 'Motor over-temperature');
      expect(faultTitle('BMS00_PDU_temperature_warning_info'), 'PDU temperature warning');
    });
  });

  group('active faults', () {
    test('reports only the bits that are set, severity-first', () {
      // 0x410 b46 = over-voltage charge Error; b47 = ...Permanent_Fault (critical);
      // b43 = PDU temperature warning.
      final active = activeFaultsIn({0x410: bits8([43, 46, 47])});
      expect(active.map((f) => f.title), [
        'Over-voltage charge Permanent Fault',
        'Over-voltage charge Error',
        'PDU temperature warning',
      ], reason: 'critical, then error, then warning (Ola names: b43 = ...warning_info)');
      expect(active.first.severity, FaultSeverity.critical);
      expect(active.first.component, 'BMS');
    });

    test('a frame with no bits set yields nothing', () {
      expect(activeFaultsIn({0x410: Uint8List(8)}), isEmpty);
    });

    test('the catalog spans several components', () {
      expect(faultCatalog.map((f) => f.component).toSet(), containsAll({'BMS', 'MCU', 'Charger', 'VCU', 'Body'}));
      expect(faultCatalog.length, greaterThan(100));
    });
  });
}
