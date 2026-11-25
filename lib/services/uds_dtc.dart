/// Reads diagnostic trouble codes (DTCs) over UDS, the way Ola's own
/// diagnostics app does — ReadDTCInformation (service 0x19, sub 0x02,
/// statusMask 0x09) over ISO-TP, parsed into active/stored faults. Pure logic
/// here (frame building, ISO-TP reassembly, response parsing); the live
/// transport lives elsewhere.
library;

/// The three ECUs the app queries, each with a request/response CAN id pair
/// (EcuCanId in Ola's UDS engine).
enum DtcEcu { bms, mcu, vcu }

/// (request id, response id) for [ecu].
(int, int) ecuCanIds(DtcEcu ecu) => switch (ecu) {
      DtcEcu.bms => (0x78E, 0x7B1),
      DtcEcu.vcu => (0x786, 0x7B0),
      DtcEcu.mcu => (0x7A6, 0x7B4),
    };

/// The ReadDTCInformation request as an 8-byte ISO-TP single frame:
/// PCI 0x03 (3 data bytes) + `19 02 09`, zero-padded.
List<int> readDtcFrame() => [0x03, 0x19, 0x02, 0x09, 0, 0, 0, 0];

/// The flow-control frame the tester sends after a First Frame:
/// FS=ContinueToSend, BlockSize=0, STmin=0x14.
List<int> flowControlFrame() => [0x30, 0x00, 0x14, 0, 0, 0, 0, 0];

/// Reassembles an ISO-TP message from its CAN frames (each 8 data bytes on the
/// ECU's response id). Returns the complete UDS payload when done, else null.
class IsoTpReassembler {
  final _buf = <int>[];
  int _expected = 0;

  /// True once a First Frame has arrived and a flow-control frame is owed.
  bool needsFlowControl = false;

  List<int>? feed(List<int> f) {
    if (f.length < 8) return null;
    final type = (f[0] & 0xf0) >> 4;
    switch (type) {
      case 0: // single frame: low nibble is the length
        final len = f[0] & 0x0f;
        return f.sublist(1, 1 + len);
      case 1: // first frame: 12-bit length, 6 payload bytes
        _expected = ((f[0] & 0x0f) << 8) | f[1];
        _buf
          ..clear()
          ..addAll(f.sublist(2, 8));
        needsFlowControl = true;
        return _buf.length >= _expected ? _buf.sublist(0, _expected) : null;
      case 2: // consecutive frame: 7 payload bytes
        _buf.addAll(f.sublist(1, 8));
        return _buf.length >= _expected ? _buf.sublist(0, _expected) : null;
      default:
        return null;
    }
  }
}

/// Fault-code descriptions (code → description, per ECU), from the bundled
/// fault_codes.json.
class DtcCatalog {
  const DtcCatalog(this._byEcu);
  final Map<DtcEcu, Map<String, String>> _byEcu;

  /// The human description for [code] on [ecu], or null if unknown.
  String? lookup(DtcEcu ecu, String code) => _byEcu[ecu]?[code.toUpperCase()];
}

/// Parses fault_codes.json (`{"bms": {"<code>": "<description>", ...}, ...}`)
/// into a [DtcCatalog].
DtcCatalog parseDtcCatalog(Map<String, dynamic> json) {
  final byEcu = <DtcEcu, Map<String, String>>{};
  for (final ecu in DtcEcu.values) {
    final group = json[ecu.name];
    if (group is! Map) continue;
    byEcu[ecu] = {for (final e in group.entries) (e.key as String).toUpperCase(): e.value.toString()};
  }
  return DtcCatalog(byEcu);
}

/// One decoded DTC: a 6-hex-digit code and its ISO-14229 status byte.
class DtcRecord {
  const DtcRecord(this.code, this.status);
  final String code;
  final int status;

  /// testFailed (bit 0) — the app's active/inactive split keys on this bit.
  bool get active => status & 0x01 != 0;
}

/// Parses a ReadDTCInformation positive response payload (`59 02 <mask>` then
/// 4-byte DTC records) into records, skipping zero-status and all-equal padding
/// chunks, exactly as the app's createFault does.
List<DtcRecord> parseDtcResponse(List<int> payload) {
  if (payload.length < 3 || payload[0] != 0x59) return const [];
  final body = payload.sublist(3); // drop 59 02 mask
  final out = <DtcRecord>[];
  for (var i = 0; i + 4 <= body.length; i += 4) {
    final c = body.sublist(i, i + 4);
    final status = c[3];
    if (status == 0) continue;
    if (c[0] == c[1] && c[1] == c[2] && c[2] == c[3]) continue;
    final code = c.take(3).map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0')).join();
    out.add(DtcRecord(code, status));
  }
  return out;
}

/// A named, resolved fault for display: ECU, 6-hex code, description, active.
class Dtc {
  const Dtc(this.ecu, this.code, this.description, this.active);
  final DtcEcu ecu;
  final String code;
  final String description;
  final bool active;
}

/// The hex bytes isotprecv prints for a reassembled message, e.g.
/// "59 02 09 13 0E F0 08 \n" → [0x59, 0x02, ...]. Ignores trailing noise.
List<int> parseIsotpHex(String out) => out
    .trim()
    .split(RegExp(r'\s+'))
    .where((t) => t.length == 2 && int.tryParse(t, radix: 16) != null)
    .map((t) => int.parse(t, radix: 16))
    .toList();

/// Resolves a ReadDTCInformation payload into named [Dtc]s via [catalog].
List<Dtc> dtcsFromResponse(DtcEcu ecu, List<int> payload, DtcCatalog catalog) => [
      for (final r in parseDtcResponse(payload))
        Dtc(ecu, r.code, catalog.lookup(ecu, r.code) ?? 'Unknown (${r.code})', r.active),
    ];

/// One ECU's fault read: whether it answered at all (an asleep MCU sends
/// nothing), and the DTCs if it did.
class EcuFaultResult {
  const EcuFaultResult(this.responded, this.dtcs);
  final bool responded;
  final List<Dtc> dtcs;
}

/// Builds an [EcuFaultResult] from a decoded response payload. Empty payload ⇒
/// the ECU did not respond (e.g. MCU asleep while parked).
EcuFaultResult ecuFaultResult(DtcEcu ecu, List<int> payload, DtcCatalog catalog) =>
    EcuFaultResult(payload.isNotEmpty, dtcsFromResponse(ecu, payload, catalog));
