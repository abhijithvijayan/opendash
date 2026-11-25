import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'analytics_logger.dart';
import 'pii_frames.dart';
import 'scooter_survey.dart';

/// A few minutes of everything, for learning a scooter nobody has seen:
/// every batch the stock service sends and every frame on the whole bus,
/// each with its time, in a file of its own beside the log
/// (`raw-<stamp>.jsonl`). The log keeps the shape of the data
/// ([ScooterSurvey]); this keeps the data, so a field can be found by
/// lining it up against speed or current afterwards
/// (`scripts/raw-recording.py`).
///
/// Values from the stock service pass the survey's privacy rule. Bus
/// frames do not: nobody knows yet what an unclassified frame carries, and
/// one may spell the VIN. The file says so in its first line, and the
/// script can scrub it before it is shared.
class RawRecorder {
  RawRecorder._();
  static final instance = RawRecorder._();

  /// A full bus is about 1,800 frames a second; this is over ten minutes.
  static const maxBytes = 96 * 1024 * 1024;

  IOSink? _sink;
  String? _path;
  int _startMicros = 0;
  int _bytes = 0;
  int frames = 0;
  int batches = 0;
  bool Function(String key)? _isText;

  /// Tests: what would have been written, when there is no folder.
  final memory = <String>[];

  bool get active => _startMicros != 0;
  String? get path => _path;
  bool get full => _bytes >= maxBytes;

  /// [header] is written as the first line with the warning.
  void start({required Map<String, Object?> header, Directory? directory, bool Function(String key)? isText, String? stamp}) {
    if (active) return;
    _isText = isText;
    _startMicros = AnalyticsLogger.instance.monoMicros;
    if (_startMicros == 0) _startMicros = 1;
    frames = batches = _bytes = 0;
    memory.clear();
    _path = null;
    if (directory != null) {
      try {
        final file = File('${directory.path}/raw-${stamp ?? _startMicros}.jsonl');
        _sink = file.openWrite();
        _path = file.path;
      } catch (_) {
        _sink = null;
      }
    }
    _write({
      'raw_recording': 1,
      'warning': 'Raw bus data. Known identifier frames (VIN, MAC, serials, passcode) are masked '
          'at capture; other unclassified frames may still carry identifiers, so share only with '
          'someone you trust, or scrub it first (scripts/raw-recording.py --scrub).',
      'pii_masked': [for (final id in piiFrameIds) id.toRadixString(16)],
      ...header,
    });
  }

  int get _ms => (AnalyticsLogger.instance.monoMicros - _startMicros) ~/ 1000;

  /// One batch from the stock service, values through the survey's rule.
  void batch(Map<Object?, Object?> delta) {
    if (!active || full) return;
    row(batchRow(delta, isText: _isText), AnalyticsLogger.instance.monoMicros);
  }

  /// The values of one batch as they are written, through the survey's
  /// rule: made where the batch arrives, written by [row] where the file is.
  static String batchRow(Map<Object?, Object?> delta, {bool Function(String key)? isText}) => jsonEncode({
        for (final MapEntry(:key, :value) in delta.entries)
          if (key is String) key: ScooterSurvey.shown(key, value, isText: isText),
      });

  /// One [batchRow] that arrived at [atMicros] on the log's clock.
  void row(String values, int atMicros) {
    if (!active || full) return;
    batches++;
    final at = atMicros < _startMicros ? _startMicros : atMicros;
    _line('{"t":${(at - _startMicros) ~/ 1000},"b":$values}');
  }

  /// One frame off the bus: 4 id bytes, length, 3 padding, 8 data.
  void frame(List<int> bytes) {
    if (!active || full || bytes.length < 8) return;
    frames++;
    final id = (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    // Identifier/passcode frames (VIN, MAC, serials): zero the payload at
    // capture so it never reaches disk; the id, length and timing stay.
    final masked = piiFrameIds.contains(id);
    final data = StringBuffer();
    for (var i = bytes.length >= 16 ? 8 : 5; i < bytes.length; i++) {
      data.write(masked ? '00' : bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    _line('{"t":$_ms,"f":"${id.toRadixString(16)}","n":${bytes[4]},"d":"$data"}');
  }

  /// Closes the file; the counts stay readable.
  Future<void> stop() async {
    if (!active) return;
    _write({'t': _ms, 'end': 1, 'frames': frames, 'batches': batches});
    _startMicros = 0;
    final sink = _sink;
    _sink = null;
    try {
      await sink?.flush();
      await sink?.close();
    } catch (_) {}
  }

  void _write(Map<String, Object?> row) => _line(jsonEncode(row));

  void _line(String line) {
    _bytes += line.length + 1;
    final sink = _sink;
    if (sink == null) {
      if (memory.length < 5000) memory.add(line);
    } else {
      sink.writeln(line);
    }
  }

  void resetForTest() {
    _sink = null;
    _startMicros = 0;
    _path = null;
    frames = batches = _bytes = 0;
    memory.clear();
  }
}

/// For callers that hold a list, not typed bytes.
Uint8List asBytes(List<int> frame) => frame is Uint8List ? frame : Uint8List.fromList(frame);
