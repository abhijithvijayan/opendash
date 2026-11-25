import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'trusted_clock.dart';

/// Structured JSONL event log for diagnosing what happened on the scooter
/// after the fact. One object per line:
///
///     {"ts":"2026-11-09T10:15:30.123Z","mono":123456,"cat":"hhmis","evt":"bind_success","data":{...}}
///
/// `ts` is wall-clock UTC, `mono` microseconds since [init] on a stopwatch,
/// so durations survive an NTP jump. Events buffer in memory and flush on a
/// timer, so [log] never blocks a frame and never throws; logger failures
/// go to `debugPrint` only. The last [ringSize] events are always kept in
/// memory ([recentDump]) whether or not a file is open, which is also what
/// tests read.
///
/// Disk budget: the current file rotates past [maxFileBytes] and
/// [generations] rotated files are kept, so at most ~130 MB on the head
/// unit (13 x 10 MB) in `<externalFilesDir>/analytics/`. Sized for ~6+ h
/// of continuous riding at 1 Hz heartbeat (empirical: ~300 KB/min active)
/// so a 2 h ride never rotates the start out before `adb pull`.
class AnalyticsLogger {
  AnalyticsLogger({
    this.maxFileBytes = defaultMaxFileBytes,
    this.generations = defaultGenerations,
    this.flushAt = 32,
    this.flushInterval = const Duration(seconds: 1),
  });

  static AnalyticsLogger instance = AnalyticsLogger();

  static const defaultMaxFileBytes = 10 * 1024 * 1024;
  static const defaultGenerations = 12;
  static const fileName = 'opendash.jsonl';
  static const subdir = 'analytics';
  static const ringSize = 500;
  static const maxStringLength = 200;
  static const maxListLength = 20;

  final int maxFileBytes;
  final int generations;
  final int flushAt;
  final Duration flushInterval;

  /// Small shared scratch for values other samplers want in the heartbeat
  /// without a provider dependency (`free_ram_mb`, `grpc_dump`).
  final Map<String, Object?> context = {};

  /// Called synchronously for every accepted event. The ride tracker counts
  /// modals this way; tests use it to assert on seams.
  final List<void Function(String cat, String evt, Map<String, Object?> data)> listeners = [];

  final Stopwatch _mono = Stopwatch()..start();
  final List<String> _pending = [];
  final ListQueue<Map<String, Object?>> _recent = ListQueue();
  bool _enabled = true;
  Directory? _dir;
  File? _file;
  int _bytes = 0;
  Timer? _timer;
  Future<void> _io = Future.value();
  int _rotations = 0;

  bool get enabled => _enabled;

  /// On-disk path for `adb pull`; null until [init] opened a file.
  String? get currentFilePath => _file?.path;

  /// Tests under `fakeAsync` swap the stopwatch for the fake clock.
  int Function()? monoOverride;

  int get monoMicros => monoOverride?.call() ?? _mono.elapsedMicroseconds;

  /// Opens `<directory>/analytics/opendash.jsonl`. Without [directory] the
  /// logger stays memory-only (Chrome, tests), which is not an error.
  Future<void> init({bool enabled = true, Directory? directory}) async {
    _enabled = enabled;
    _timer?.cancel();
    if (directory == null) return;
    try {
      final dir = Directory('${directory.path}${Platform.pathSeparator}$subdir');
      await dir.create(recursive: true);
      final file = File('${dir.path}${Platform.pathSeparator}$fileName');
      _bytes = await file.exists() ? await file.length() : 0;
      _dir = dir;
      _file = file;
      // Whatever was logged before the file opened (boot marks, early
      // bridge events) is still in the ring buffer; carry it over.
      _pending.addAll(_recent.map(jsonEncode));
      _timer = Timer.periodic(flushInterval, (_) => flush());
    } catch (e) {
      debugPrint('[analytics] cannot open log file: $e');
      _dir = null;
      _file = null;
    }
  }

  /// The settings switch. Straddles the flip with a `log.disabled` /
  /// `log.enabled` event so the gap is visible in the file.
  void setEnabled(bool on) {
    if (on == _enabled) return;
    if (!on) {
      log('log', 'disabled');
      _enabled = false;
      flush();
    } else {
      _enabled = true;
      log('log', 'enabled');
    }
  }

  /// The hot path: no await, no throw. Top-level list fields named in
  /// [uncappedLists] skip the [maxListLength] cut (key-name lists whose
  /// tail is the point, e.g. `hhmis.batch`); their strings are still capped.
  void log(String cat, String evt, [Map<String, Object?>? data, Set<String> uncappedLists = const {}]) {
    if (!_enabled) return;
    try {
      final clean = _sanitizeMap(data ?? const {}, uncappedLists);
      final event = <String, Object?>{
        'ts': _timestamp(TrustedClock.now()),
        // The head unit's clock cannot be right (see TrustedClock): `ts` is
        // then the last good reading plus uptime, not the wall clock.
        if (!TrustedClock.trusted) 'clk': 'est',
        'mono': monoMicros,
        'cat': cat,
        'evt': evt,
        'data': clean,
      };
      _recent.addLast(event);
      if (_recent.length > ringSize) _recent.removeFirst();
      for (final l in listeners) {
        try {
          l(cat, evt, clean);
        } catch (e) {
          debugPrint('[analytics] listener failed: $e');
        }
      }
      if (_file == null) return;
      _pending.add(jsonEncode(event));
      if (_pending.length >= flushAt) flush();
    } catch (e) {
      debugPrint('[analytics] log failed: $e');
    }
  }

  /// Writes everything buffered. Returns how many events were handed to
  /// the file, whether or not the write then succeeded.
  Future<int> flush() {
    if (_pending.isEmpty || _file == null) return Future.value(0);
    final chunk = _pending.toList();
    _pending.clear();
    _io = _io.then((_) => _write(chunk));
    return _io.then((_) => chunk.length);
  }

  Future<void> _write(List<String> lines) async {
    final file = _file;
    if (file == null) return;
    try {
      final text = '${lines.join('\n')}\n';
      await file.writeAsString(text, mode: FileMode.append, flush: true);
      _bytes += utf8.encode(text).length;
      if (_bytes > maxFileBytes) {
        await _rotate();
        log('log', 'rotated', {'generation': _rotations, 'reason': 'size'});
      }
    } catch (e) {
      debugPrint('[analytics] write failed: $e');
    }
  }

  /// "Start new capture": the file rotates now, regardless of size, and
  /// the new one opens with `log.capture_started`.
  Future<void> startCapture({String? label}) async {
    if (_file == null) return;
    await flush();
    _io = _io.then((_) => _rotate());
    await _io;
    log('log', 'capture_started', {'label': label ?? _timestamp(DateTime.now())});
    await flush();
  }

  Future<void> _rotate() async {
    final dir = _dir;
    final file = _file;
    if (dir == null || file == null) return;
    try {
      final sep = Platform.pathSeparator;
      String gen(int n) => '${dir.path}${sep}opendash.$n.jsonl';
      final last = File(gen(generations));
      if (await last.exists()) await last.delete();
      for (var n = generations - 1; n >= 1; n--) {
        final f = File(gen(n));
        if (await f.exists()) await f.rename(gen(n + 1));
      }
      if (await file.exists()) await file.rename(gen(1));
      _bytes = 0;
      _rotations++;
    } catch (e) {
      debugPrint('[analytics] rotate failed: $e');
    }
  }

  /// Flushes and stops the timer. The logger can keep logging to memory
  /// afterwards; call [init] again to reopen a file.
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await flush();
    await _io;
  }

  /// The last [ringSize] events, oldest first.
  Iterable<Map<String, Object?>> recentDump() => _recent.toList();

  /// Events in [recentDump] matching [cat] and, when given, [evt].
  List<Map<String, Object?>> recent(String cat, [String? evt]) =>
      [for (final e in _recent) if (e['cat'] == cat && (evt == null || e['evt'] == evt)) e];

  /// Drops the ring buffer, the buffer and any listeners; tests call this
  /// between cases.
  void resetForTest() {
    _recent.clear();
    _pending.clear();
    listeners.clear();
    context.clear();
    monoOverride = null;
    _enabled = true;
    _timer?.cancel();
    _timer = null;
    _file = null;
    _dir = null;
    _bytes = 0;
    _rotations = 0;
  }

  static String _timestamp(DateTime t) =>
      DateTime.fromMillisecondsSinceEpoch(t.millisecondsSinceEpoch, isUtc: true).toIso8601String();

  static Map<String, Object?> _sanitizeMap(Map<Object?, Object?> data, [Set<String> uncappedLists = const {}]) {
    final out = <String, Object?>{};
    var truncated = false;
    data.forEach((k, v) {
      final key = k.toString();
      final (value, cut) = _sanitize(v, uncapped: uncappedLists.contains(key));
      out[key] = value;
      if (cut) truncated = true;
    });
    if (truncated) out['truncated'] = true;
    return out;
  }

  static (Object?, bool) _sanitize(Object? v, {bool uncapped = false}) {
    switch (v) {
      case null || bool() || num():
        return (v, false);
      case String():
        return v.length > maxStringLength ? ('${v.substring(0, maxStringLength)}…', true) : (v, false);
      case Map():
        return (_sanitizeMap(v), false);
      case Iterable():
        final list = v.toList();
        final cut = !uncapped && list.length > maxListLength;
        final kept = cut ? list.sublist(0, maxListLength) : list;
        return ([for (final e in kept) _sanitize(e).$1], cut);
      case Enum():
        return (v.name, false);
      default:
        return _sanitize(v.toString());
    }
  }
}

// Short helpers for the call sites, so a tap is one line.

void logEvent(String cat, String evt, [Map<String, Object?>? data, Set<String> uncappedLists = const {}]) =>
    AnalyticsLogger.instance.log(cat, evt, data, uncappedLists);

void uiTap(String target, [Map<String, Object?>? extra]) => logEvent('ui', 'tap', {'target': target, ...?extra});

void uiSwipe(String target, [Map<String, Object?>? extra]) => logEvent('ui', 'swipe', {'target': target, ...?extra});

void uiLongPress(String target) => logEvent('ui', 'long_press', {'target': target});

void uiToggle(String target, bool on) => logEvent('ui', 'toggle', {'target': target, 'on': on});

void uiModalButton(String modal, String button) => logEvent('ui', 'modal_button', {'modal': modal, 'button': button});

void logModalShow(String name, {String reason = 'opened', Map<String, Object?>? extra}) =>
    logEvent('modal', 'show', {'name': name, 'reason': reason, ...?extra});

void logModalDismiss(String name, {required String reason, Map<String, Object?>? extra}) =>
    logEvent('modal', 'dismiss', {'name': name, 'reason': reason, ...?extra});

/// One event per user-initiated settings change; a no-op change is skipped.
void logSettingsChange(String key, Object? from, Object? to) {
  if (from == to) return;
  logEvent('settings', 'change', {'key': key, 'from': from, 'to': to});
}

void bootMark(String stage) => logEvent('boot', 'mark', {'stage': stage, 'mono': AnalyticsLogger.instance.monoMicros});

/// Kotlin -> Dart analytics: `HhmisService` and friends call
/// `Analytics.log` which arrives here as an `analytics` method call on the
/// platform channel. `analyticsReady` tells the Kotlin side to drain what
/// it queued before Dart was listening.
void installAnalyticsBridge() {
  const channel = MethodChannel('in.abhijithvijayan.opendash.platform');
  channel.setMethodCallHandler((call) async {
    if (call.method != 'analytics') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    final data = args['data'];
    AnalyticsLogger.instance.log(
      '${args['cat']}',
      '${args['evt']}',
      data is Map ? Map<String, Object?>.from(data.map((k, v) => MapEntry('$k', v))) : null,
    );
    return null;
  });
  channel.invokeMethod<void>('analyticsReady').catchError((Object _) {});
}
