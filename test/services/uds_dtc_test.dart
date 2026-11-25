import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/services/uds_dtc.dart';

void main() {
  group('request frames', () {
    test('ReadDTCInformation 19 02 09 as an ISO-TP single frame', () {
      // Spec: 03 19 02 09 00 00 00 00 on the ECU request id.
      expect(readDtcFrame(), [0x03, 0x19, 0x02, 0x09, 0, 0, 0, 0]);
    });
    test('flow control is 30 00 14 padded', () {
      expect(flowControlFrame(), [0x30, 0x00, 0x14, 0, 0, 0, 0, 0]);
    });
    test('ECU request/response ids match EcuCanId', () {
      expect(ecuCanIds(DtcEcu.bms), (0x78E, 0x7B1));
      expect(ecuCanIds(DtcEcu.vcu), (0x786, 0x7B0));
      expect(ecuCanIds(DtcEcu.mcu), (0x7A6, 0x7B4));
    });
  });

  group('ISO-TP reassembly', () {
    test('single frame returns the UDS payload', () {
      final r = IsoTpReassembler();
      // SF len 7: 59 02 FF + one DTC record (11 01 09 status 09).
      final out = r.feed([0x07, 0x59, 0x02, 0xFF, 0x11, 0x01, 0x09, 0x09]);
      expect(out, [0x59, 0x02, 0xFF, 0x11, 0x01, 0x09, 0x09]);
      expect(r.needsFlowControl, isFalse);
    });

    test('first frame asks for flow control, consecutive frames complete it', () {
      final r = IsoTpReassembler();
      // total len 15 = 59 02 FF + three 4-byte DTC records.
      expect(r.feed([0x10, 0x0F, 0x59, 0x02, 0xFF, 0x11, 0x01, 0x09]), isNull);
      expect(r.needsFlowControl, isTrue);
      expect(r.feed([0x21, 0x09, 0x15, 0x02, 0x1C, 0x08, 0x11, 0x02]), isNull);
      final out = r.feed([0x22, 0x1C, 0x09, 0, 0, 0, 0, 0]);
      expect(out, [0x59, 0x02, 0xFF, 0x11, 0x01, 0x09, 0x09, 0x15, 0x02, 0x1C, 0x08, 0x11, 0x02, 0x1C, 0x09]);
    });
  });

  group('response parsing', () {
    test('splits 4-byte records, reads code and active bit', () {
      final dtcs = parseDtcResponse([0x59, 0x02, 0xFF, 0x11, 0x01, 0x09, 0x09, 0x15, 0x02, 0x1C, 0x08]);
      expect(dtcs.map((d) => d.code), ['110109', '15021C']);
      expect(dtcs[0].active, isTrue, reason: 'status 0x09 has testFailed bit0 set');
      expect(dtcs[1].active, isFalse, reason: 'status 0x08 has bit0 clear');
    });

    test('skips zero-status and all-equal padding records', () {
      final dtcs = parseDtcResponse([0x59, 0x02, 0xFF, 0x11, 0x01, 0x09, 0x00, 0x00, 0x00, 0x00, 0x00]);
      expect(dtcs, isEmpty, reason: 'status 0 and the 00 00 00 00 chunk are not real faults');
    });

    test('rejects a non-ReadDTC response', () {
      expect(parseDtcResponse([0x7F, 0x19, 0x31]), isEmpty);
    });
  });

  group('isotprecv output', () {
    test('parses the hex bytes isotprecv prints (with trailing noise)', () {
      expect(parseIsotpHex('59 02 09 13 0E F0 08 \n'), [0x59, 0x02, 0x09, 0x13, 0x0E, 0xF0, 0x08]);
      expect(parseIsotpHex(''), isEmpty);
    });

    test('end to end: stdout + catalog -> named DTCs', () {
      final cat = parseDtcCatalog({
        'mcu': {'130EF0': 'Motor position sensor disconnected'},
      });
      final dtcs = dtcsFromResponse(DtcEcu.mcu, parseIsotpHex('59 02 09 13 0E F0 08'), cat);
      expect(dtcs.single.code, '130EF0');
      expect(dtcs.single.description, 'Motor position sensor disconnected');
      expect(dtcs.single.active, isFalse, reason: 'status 0x08 is stored, not active');
    });
  });

  group('ECU fault result', () {
    test('a response with the 59 header counts as responded', () {
      final r = ecuFaultResult(DtcEcu.bms, parseIsotpHex('59 02 FF'), parseDtcCatalog(const <String, dynamic>{}));
      expect(r.responded, isTrue);
      expect(r.dtcs, isEmpty);
    });
    test('empty output means the ECU did not respond (asleep/unreachable)', () {
      final r = ecuFaultResult(DtcEcu.mcu, parseIsotpHex('  \n'), parseDtcCatalog(const <String, dynamic>{}));
      expect(r.responded, isFalse);
    });
  });

  group('DTC catalog', () {
    test('maps each ECU group to code -> description', () {
      final cat = parseDtcCatalog({
        'bms': {'110109': 'Cell 1 voltage sensor failed'},
        'mcu': {'d10108': 'No messages from the VCU'},
      });
      expect(cat.lookup(DtcEcu.bms, '110109'), 'Cell 1 voltage sensor failed');
      expect(cat.lookup(DtcEcu.mcu, 'D10108'), 'No messages from the VCU');
      expect(cat.lookup(DtcEcu.bms, 'FFFFFF'), isNull, reason: 'unknown code');
    });

    test('the bundled file names codes for all three ECUs', () {
      final cat = parseDtcCatalog(json.decode(File('assets/diagnostics/fault_codes.json').readAsStringSync()) as Map<String, dynamic>);
      expect(cat.lookup(DtcEcu.bms, '110E09'), 'Cell 14 voltage sensor failed');
      expect(cat.lookup(DtcEcu.mcu, '1316F0'), 'Motor stalled');
      expect(cat.lookup(DtcEcu.vcu, '920B13'), 'Brake light open circuit');
    });
  });
}
