import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/services/bms_decoder.dart';

Uint8List _frame(int canId, List<int> data) {
  final f = Uint8List(16);
  f[0] = (canId >> 24) & 0xff;
  f[1] = (canId >> 16) & 0xff;
  f[2] = (canId >> 8) & 0xff;
  f[3] = canId & 0xff;
  f[4] = 8;
  for (var i = 0; i < data.length && i < 8; i++) {
    f[8 + i] = data[i];
  }
  return f;
}

void main() {
  test('0x113 Cruise_Control_Status bit (byte5 bit0) sets cruiseEngaged', () {
    final bms = BmsState();
    bms.feed(_frame(0x113, [0, 0, 0, 0, 0, 0x01, 0, 0]));
    expect(bms.liveInputs!.cruiseEngaged, isTrue);
  });

  test('0x143 Cruise_Control_Availability (byte7 bits 3-5) decodes to its ordinal', () {
    final bms = BmsState();
    bms.feed(_frame(0x143, [0, 0, 0, 0, 0, 0, 0, 3 << 3]));
    expect(bms.liveInputs!.cruiseAvailability, 3);
  });

  test('before either frame, cruiseEngaged is false and cruiseAvailability is null', () {
    final bms = BmsState();
    bms.feed(_frame(0x6AC, [0, 0, 0, 0, 0, 0, 0, 0]));
    expect(bms.liveInputs!.cruiseEngaged, isFalse);
    expect(bms.liveInputs!.cruiseAvailability, isNull);
  });
}
