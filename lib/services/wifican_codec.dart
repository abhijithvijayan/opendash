import 'dart:convert';
import 'dart:typed_data';

/// Protobuf wire codec for the five `wifican` messages the dashboard uses
/// (see `proto/wifican.proto`). Hand-written because they are tiny and it
/// keeps protoc out of the build: `Register{repeated uint32 can_ids=1}`,
/// `CANPacket{bytes can_frame=1}`, `Response{RespStatus status=1;
/// string status_msg=2}`, `Command{string cmd_msg=1}` (RecoveryService's
/// `ExecuteADBCommand`) and `google.protobuf.Empty`.

List<int> encodeEmpty() => const [];

/// `Command{string cmd_msg = 1}`. UTF-8 bytes of [cmd] under field 1.
List<int> encodeCommand(String cmd) {
  if (cmd.isEmpty) return const [];
  final bytes = utf8.encode(cmd);
  return [0x0a, ..._varint(bytes.length), ...bytes];
}

/// proto3 packs repeated scalars: tag 1 length-delimited, then varints.
List<int> encodeRegister(List<int> canIds) {
  if (canIds.isEmpty) return const [];
  final payload = <int>[];
  for (final id in canIds) {
    _writeVarint(payload, id);
  }
  return [0x0a, ..._varint(payload.length), ...payload];
}

/// The `can_frame` bytes, or null when the message carries none. grpc hands
/// over a `Uint8List`, so the frame is a view into the message, not a copy;
/// the decoder reads it before the next message arrives and keeps nothing.
Uint8List? decodeCanPacket(List<int> bytes) {
  Uint8List? frame;
  _scan(bytes, (field, wire, value, start, end) {
    if (field != 1 || wire != 2) return;
    frame = bytes is Uint8List ? Uint8List.sublistView(bytes, start, end) : Uint8List.fromList(bytes.sublist(start, end));
  });
  return frame;
}

class WifiCanResponse {
  const WifiCanResponse(this.status, this.message);
  final int status;
  final String message;

  /// `RESP_SUCCESS`.
  bool get ok => status == 1;
}

WifiCanResponse decodeResponse(List<int> bytes) {
  var status = 0;
  var message = '';
  _scan(bytes, (field, wire, value, start, end) {
    if (field == 1 && wire == 0) status = value;
    if (field == 2 && wire == 2) message = utf8.decode(bytes.sublist(start, end), allowMalformed: true);
  });
  return WifiCanResponse(status, message);
}

/// Walks the fields; [value] is the varint for wire type 0, and
/// [start]..[end] bound the payload for wire type 2. Other wire types are
/// skipped. Stops quietly on a truncated message.
void _scan(List<int> bytes, void Function(int field, int wire, int value, int start, int end) visit) {
  var i = 0;
  while (i < bytes.length) {
    final (tag, next) = _readVarint(bytes, i);
    if (next < 0) return;
    i = next;
    final field = tag >> 3;
    final wire = tag & 7;
    switch (wire) {
      case 0:
        final (v, n) = _readVarint(bytes, i);
        if (n < 0) return;
        visit(field, wire, v, i, n);
        i = n;
      case 2:
        final (len, n) = _readVarint(bytes, i);
        if (n < 0 || n + len > bytes.length) return;
        visit(field, wire, len, n, n + len);
        i = n + len;
      case 1:
        i += 8;
      case 5:
        i += 4;
      default:
        return;
    }
  }
}

Uint8List _varint(int v) {
  final out = <int>[];
  _writeVarint(out, v);
  return Uint8List.fromList(out);
}

void _writeVarint(List<int> out, int value) {
  var v = value;
  while (v >= 0x80) {
    out.add((v & 0x7f) | 0x80);
    v >>= 7;
  }
  out.add(v);
}

/// Returns (value, nextIndex), or nextIndex -1 when truncated.
(int, int) _readVarint(List<int> bytes, int at) {
  var result = 0;
  var shift = 0;
  var i = at;
  while (i < bytes.length) {
    final b = bytes[i++];
    result |= (b & 0x7f) << shift;
    if (b & 0x80 == 0) return (result, i);
    shift += 7;
    if (shift > 63) return (0, -1);
  }
  return (0, -1);
}
