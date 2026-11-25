import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/services/wifican_codec.dart';

void main() {
  test('Register encodes can_ids as a packed varint list', () {
    expect(encodeRegister([0x120]), [0x0a, 0x02, 0xa0, 0x02]);
    expect(encodeRegister([0x120, 0x1a5]), [0x0a, 0x04, 0xa0, 0x02, 0xa5, 0x03]);
    expect(encodeRegister([]), isEmpty);
  });

  test('Empty encodes to nothing', () {
    expect(encodeEmpty(), isEmpty);
  });

  test('Command encodes cmd_msg as length-delimited UTF-8 under field 1', () {
    // "am ..." = ASCII bytes, field=1, wire=2 → tag 0x0a.
    expect(encodeCommand('ok'), [0x0a, 0x02, 0x6f, 0x6b]);
    expect(encodeCommand(''), isEmpty);
    final out = encodeCommand('am force-stop com.olaelectric.hmiclient');
    expect(out.first, 0x0a);
    expect(out[1], 39, reason: 'the length byte is the UTF-8 length');
    expect(String.fromCharCodes(out.skip(2)), 'am force-stop com.olaelectric.hmiclient');
  });

  test('CANPacket decodes the can_frame bytes', () {
    final frame = List<int>.generate(16, (i) => i);
    final packet = [0x0a, 0x10, ...frame];
    expect(decodeCanPacket(packet), frame);
  });

  test('CANPacket decode of a typed message is a view, not a copy (R-14)', () {
    final packet = Uint8List.fromList([0x0a, 0x10, ...List<int>.generate(16, (i) => i)]);
    final frame = decodeCanPacket(packet)!;
    expect(frame, List<int>.generate(16, (i) => i));
    expect(frame.offsetInBytes, 2);
    packet[2] = 0xEE;
    expect(frame[0], 0xEE, reason: 'same bytes as the message');
  });

  test('CANPacket decode skips unknown fields and tolerates an empty message', () {
    expect(decodeCanPacket([]), isNull);
    final frame = [1, 2, 3];
    expect(decodeCanPacket([0x10, 0x07, 0x0a, 0x03, ...frame, 0x1a, 0x01, 0x00]), frame);
  });

  test('Response decodes status and message', () {
    final r = decodeResponse([0x08, 0x01, 0x12, 0x02, 0x6f, 0x6b]);
    expect(r.status, 1);
    expect(r.message, 'ok');
    expect(r.ok, isTrue);
    expect(decodeResponse([0x08, 0x02]).ok, isFalse);
  });

  test('varints over one byte round-trip', () {
    expect(encodeRegister([300]), [0x0a, 0x02, 0xac, 0x02]);
    final big = Uint8List(200);
    final packet = [0x0a, 0xc8, 0x01, ...big];
    expect(decodeCanPacket(packet)!.length, 200);
  });
}
