import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'analytics_logger.dart';
import 'pii_frames.dart';

/// The whole bus, for testing on a scooter nobody has checked: every frame
/// id, written when its payload changes, into `bus-<stamp>.jsonl` beside
/// the log; and the last [before] of every frame held in memory, written
/// to `burst-<stamp>-<reason>.jsonl` with the [after] that follows when
/// something happens ([trigger]: a command, a fault, a ride or a charge
/// starting or ending, a recovery).
///
/// Lines are those of a raw recording (`RawRecorder`, `scripts/raw-recording.py`):
/// a header with `raw_recording` and `log_mono_ms`, then frames as
/// `{"t": ms since the header, "f": id, "n": length, "d": 8 bytes}`. So
/// `log_mono_ms + t` is the `mono` of the analytics log (in ms), and a
/// `hhmis.cmd_send` lines up with the frames around it. Every
/// [keyframeEvery] a `{"t", "key": {id: bytes}}` line holds the last
/// payload of every id, so a file can be read from any keyframe on.
///
/// Frames nobody has classified may spell the VIN: both files say so in
/// their header, and the script's `--scrub` removes them, from keyframes too.
class BusLog {
  BusLog._();
  static final instance = BusLog._();

  /// A changed-frames file rotates past this, and [generations] are kept.
  static const maxFileBytes = 16 * 1024 * 1024;
  static const generations = 8;
  static const keyframeEvery = Duration(seconds: 30);
  static const before = Duration(seconds: 60);
  static const after = Duration(seconds: 10);
  static const maxBursts = 30;

  /// Frames held for a burst: [before] at up to ~2,000 frames a second
  /// (a Gen 1 bus runs ~1,000).
  static const ringCapacity = 120000;

  /// Without a folder a burst is kept in memory, this many lines at a
  /// time, yielding between. With one, the text is made and written on a
  /// background isolate: 70 s of bus is some 60,000 lines, and making them
  /// on the main thread held up frames sixteen times a burst.
  static const burstChunk = 4000;

  /// Without a folder (Chrome, tests) lines are kept here, up to a cap.
  static const memoryCap = 20000;

  final memory = <String>[];
  final burstMemory = <String, List<String>>{};

  /// [maxFileBytes]; tests lower it to see a rotation.
  int fileLimit = maxFileBytes;

  Directory? _dir;
  IOSink? _sink;
  final List<Future<void>> _pendingCloses = [];
  String? _path;
  int _bytes = 0;
  int _fileStartMicros = 0;
  int _lastKeyMicros = 0;
  bool _active = false;
  Map<String, Object?> _header = const {};
  String Function() _stamp = () => '${AnalyticsLogger.instance.monoMicros ~/ 1000}';

  /// Last payload by id: 8 data bytes then the length.
  final _last = <int, Uint8List>{};

  Float64List? _ringT;
  Uint32List? _ringId;
  Uint8List? _ringN;
  Uint8List? _ringD;
  int _ringHead = 0;
  int _ringCount = 0;

  _Burst? _burst;
  Timer? _burstTimer;

  int frames = 0;
  int changed = 0;
  int bursts = 0;

  bool get active => _active;
  String? get path => _path;

  /// [header] goes into every file's first line, with the warning.
  /// [stamp] names each file; it must sort by time and not collide.
  void start({required Map<String, Object?> header, Directory? directory, String Function()? stamp}) {
    if (_active) return;
    _active = true;
    _header = header;
    _dir = directory;
    if (stamp != null) _stamp = stamp;
    frames = changed = bursts = 0;
    _last.clear();
    memory.clear();
    burstMemory.clear();
    _ringT = Float64List(ringCapacity);
    _ringId = Uint32List(ringCapacity);
    _ringN = Uint8List(ringCapacity);
    _ringD = Uint8List(ringCapacity * 8);
    _ringHead = _ringCount = 0;
    _openFile();
  }

  /// One frame off the bus: 4 id bytes (big-endian), length, 3 padding, 8 data.
  void frame(List<int> bytes) {
    if (!_active || bytes.length < 16) return;
    final now = AnalyticsLogger.instance.monoMicros;
    frames++;
    final id = (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
    final n = bytes[4] > 8 ? 8 : bytes[4];
    // An identifier or passcode frame (VIN, MAC, serial): the payload is
    // zeroed everywhere it is stored or written — ring (bursts), change
    // detection, keyframes and this line — so it never reaches disk. The id,
    // length and timing stay, and the header lists the masked ids.
    final masked = piiFrameIds.contains(id);

    final i = _ringHead;
    _ringT![i] = now.toDouble();
    _ringId![i] = id;
    _ringN![i] = n;
    final d = _ringD!;
    for (var k = 0; k < 8; k++) {
      d[i * 8 + k] = masked ? 0 : bytes[8 + k];
    }
    _ringHead = (i + 1) % ringCapacity;
    if (_ringCount < ringCapacity) _ringCount++;

    final prev = _last[id];
    var same = prev != null && prev[8] == n;
    for (var k = 0; same && k < 8; k++) {
      if (prev![k] != (masked ? 0 : bytes[8 + k])) same = false;
    }
    if (!same) {
      final copy = prev ?? Uint8List(9);
      for (var k = 0; k < 8; k++) {
        copy[k] = masked ? 0 : bytes[8 + k];
      }
      copy[8] = n;
      _last[id] = copy;
      changed++;
      _line('{"t":${(now - _fileStartMicros) ~/ 1000},"f":"${id.toRadixString(16)}","n":$n,"d":"${masked ? '0000000000000000' : _hex(bytes, 8, 8)}"}');
    }
    if (now - _lastKeyMicros >= keyframeEvery.inMicroseconds) _keyframe(now);
  }

  /// Something worth the bus around it. The frames from [before] it to
  /// [after] it go to a burst file; a trigger while one is pending joins it.
  /// [at]: when it happened on the log's clock, if that was not just now.
  void trigger(String reason, {int? at}) {
    if (!_active) return;
    final b = _burst;
    if (b != null) {
      if (!b.reasons.contains(reason)) b.reasons.add(reason);
      return;
    }
    _burst = _Burst(at ?? AnalyticsLogger.instance.monoMicros, [reason]);
    _burstTimer = Timer(after, () => _writeBurst());
  }

  /// Ends the log. A pending burst is written first, with what it has.
  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    _burstTimer?.cancel();
    _burstTimer = null;
    await _writeBurst();
    await _closeFile();
    // Rotations during the run closed their files fire-and-forget; wait for
    // those flushes so every file on disk is complete before we return (a
    // pulled mid-rotation file, and the on-disk test, both rely on it).
    if (_pendingCloses.isNotEmpty) {
      await Future.wait(_pendingCloses);
      _pendingCloses.clear();
    }
    // A prune during a rotation can fail to delete a file that is still
    // closing (deleteSync throws, caught), leaving one over the cap; now
    // that every file is closed, enforce the caps once more.
    _prune('bus-', generations);
    _prune('burst-', maxBursts);
    _ringT = null;
    _ringId = null;
    _ringN = null;
    _ringD = null;
    _ringCount = 0;
    _last.clear();
  }

  void _openFile() {
    final now = AnalyticsLogger.instance.monoMicros;
    _fileStartMicros = now;
    _bytes = 0;
    _path = null;
    final dir = _dir;
    if (dir != null) {
      try {
        // Before the new file: openWrite creates it only later.
        _prune('bus-', generations - 1);
        final file = File('${dir.path}/bus-${_stamp()}.jsonl');
        _sink = file.openWrite();
        _path = file.path;
      } catch (_) {
        _sink = null;
      }
    }
    _line(jsonEncode(_headerLine('bus_log', now, {'changed_only': true, 'keyframe_s': keyframeEvery.inSeconds})));
    _keyframe(now);
  }

  Future<void> _closeFile() async {
    final sink = _sink;
    _sink = null;
    try {
      await sink?.flush();
      await sink?.close();
    } catch (_) {}
  }

  Map<String, Object?> _headerLine(String kind, int startMicros, Map<String, Object?> extra) => {
        'raw_recording': 1,
        'kind': kind,
        'warning': 'Raw bus data. Known identifier frames (VIN, MAC, serials, passcode) are masked '
            'at capture; other unclassified frames may still carry identifiers, so share only with '
            'someone you trust, or scrub it first (scripts/raw-recording.py --scrub).',
        'pii_masked': [for (final id in piiFrameIds) id.toRadixString(16)],
        'log_mono_ms': startMicros ~/ 1000,
        ...extra,
        ..._header,
      };

  void _keyframe(int now) {
    _lastKeyMicros = now;
    if (_last.isEmpty) return;
    final key = StringBuffer('{"t":${(now - _fileStartMicros) ~/ 1000},"key":{');
    var first = true;
    for (final e in _last.entries) {
      if (!first) key.write(',');
      first = false;
      key.write('"${e.key.toRadixString(16)}":"${_hex(e.value, 0, 8)}"');
    }
    key.write('}}');
    _line(key.toString());
  }

  void _line(String line) {
    _bytes += line.length + 1;
    final sink = _sink;
    if (sink == null) {
      if (memory.length < memoryCap) memory.add(line);
    } else {
      sink.writeln(line);
    }
    if (_bytes >= fileLimit && sink != null) {
      _pendingCloses.add(_closeFile());
      _openFile();
    }
  }

  Future<void> _writeBurst() async {
    final b = _burst;
    _burst = null;
    _burstTimer?.cancel();
    _burstTimer = null;
    final ringT = _ringT;
    if (b == null || ringT == null) return;
    final from = (b.at - before.inMicroseconds).toDouble();
    // Copied out first: frames keep arriving while the file is written.
    final order = <int>[];
    final start = (_ringHead - _ringCount + ringCapacity) % ringCapacity;
    for (var k = 0; k < _ringCount; k++) {
      final i = (start + k) % ringCapacity;
      if (ringT[i] >= from) order.add(i);
    }
    final t0 = order.isEmpty ? b.at : ringT[order.first].toInt();
    final ids = Uint32List(order.length), ns = Uint8List(order.length), ts = Float64List(order.length);
    final data = Uint8List(order.length * 8);
    for (var k = 0; k < order.length; k++) {
      final i = order[k];
      ids[k] = _ringId![i];
      ns[k] = _ringN![i];
      ts[k] = ringT[i];
      data.setRange(k * 8, k * 8 + 8, _ringD!, i * 8);
    }
    final name = 'burst-${_stamp()}-${b.reasons.first}.jsonl';
    final header = jsonEncode(_headerLine('bus_burst', t0, {
      'reasons': b.reasons,
      'trigger_t': (b.at - t0) ~/ 1000,
      'before_s': before.inSeconds,
      'after_s': after.inSeconds,
    }));
    final dir = _dir;
    var written = false;
    if (dir != null) {
      _prune('burst-', maxBursts - 1);
      final path = '${dir.path}/$name';
      try {
        // Only plain values and typed lists go across: nothing of this
        // object, which holds an open file.
        await Isolate.run(() => _burstToFile(path, header, t0, ids, ns, ts, data));
        written = true;
      } catch (_) {}
    }
    if (!written) {
      final mem = burstMemory[name] = [header];
      for (var k = 0; k < ids.length; k++) {
        mem.add(_burstLine(t0, ids, ns, ts, data, k));
        if (k % burstChunk == burstChunk - 1) await Future<void>.delayed(Duration.zero);
      }
    }
    bursts++;
    logEvent('bus', 'burst', {'reasons': b.reasons, 'frames': order.length, 'file': name});
  }

  /// Keeps the newest [keep] files of a kind; the oldest go first.
  void _prune(String prefix, int keep) {
    final dir = _dir;
    if (dir == null) return;
    try {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.uri.pathSegments.last.startsWith(prefix) && f.path.endsWith('.jsonl'))
          .toList()
        ..sort((a, b) {
          final byTime = a.statSync().modified.compareTo(b.statSync().modified);
          return byTime != 0 ? byTime : a.path.compareTo(b.path);
        });
      for (var i = 0; i < files.length - keep; i++) {
        files[i].deleteSync();
      }
    } catch (_) {}
  }

  static String _burstLine(int t0, Uint32List ids, Uint8List ns, Float64List ts, Uint8List data, int k) =>
      '{"t":${(ts[k].toInt() - t0) ~/ 1000},"f":"${ids[k].toRadixString(16)}","n":${ns[k]},"d":"${_hex(data, k * 8, 8)}"}';

  /// Runs on a background isolate.
  static void _burstToFile(String path, String header, int t0, Uint32List ids, Uint8List ns, Float64List ts, Uint8List data) {
    final text = StringBuffer()..writeln(header);
    for (var k = 0; k < ids.length; k++) {
      text.writeln(_burstLine(t0, ids, ns, ts, data, k));
    }
    File(path).writeAsStringSync(text.toString(), flush: true);
  }

  static const _digits = '0123456789abcdef';

  static String _hex(List<int> bytes, int from, int count) {
    final codes = List<int>.filled(count * 2, 0);
    for (var k = 0; k < count; k++) {
      final b = bytes[from + k];
      codes[k * 2] = _digits.codeUnitAt(b >> 4);
      codes[k * 2 + 1] = _digits.codeUnitAt(b & 15);
    }
    return String.fromCharCodes(codes);
  }

  void resetForTest() {
    _burstTimer?.cancel();
    _burstTimer = null;
    _burst = null;
    _sink = null;
    _active = false;
    _dir = null;
    _path = null;
    _last.clear();
    memory.clear();
    burstMemory.clear();
    frames = changed = bursts = 0;
    fileLimit = maxFileBytes;
    _stamp = () => '${AnalyticsLogger.instance.monoMicros ~/ 1000}';
  }
}

class _Burst {
  _Burst(this.at, this.reasons);
  final int at;
  final List<String> reasons;
}
