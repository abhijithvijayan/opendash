import 'dart:typed_data';

import 'analytics_logger.dart';

/// What a log has to say about a scooter nobody has seen, so that one
/// pulled file answers "is this the same as the scooter OpenDash was built
/// on?" without a second visit.
///
/// It records the shape of the data, not the ride: for every value the
/// stock service sends, its type, how often it came and the range or the
/// distinct values it took; for every battery frame, its length, its
/// first and last raw bytes and which bytes ever changed; and the ratio of
/// motor rpm to speed.
///
/// Nothing that names the rider or the scooter is kept. A string's text
/// is recorded only for the keys in [_textKeys]; every other string is its
/// length. Keys matching [_private] give no value at all.
class ScooterSurvey {
  ScooterSurvey({this.isText});

  /// Further keys whose text may be kept (the ECU software versions).
  final bool Function(String key)? isText;

  static const _maxDistinct = 16;

  /// `INT_VEHICLE_STATE` locked: a ride is over, so its shape is written.
  static const _locked = 0;

  /// Model, mode and version strings: needed, and the same on every
  /// scooter of a model.
  static const _textKeys = {'STR_VEHICLE_DRIVE_MODE', '_moveOs', '_vsw', '_vdp', '_hhmis'};

  static final _private = RegExp(
    r'VIN|ICCID|IMEI|IMSI|MAC|NAME|NUMBER|ADDRESS|PASSCODE|PIN|LAT|LON|LOCATION|GEO|NAVI|CALL|CONTACT|MESSAGE|MEDIA|SONG|ARTIST|ALBUM|TITLE|SSID|_ip$|_bt[A-Z]',
    caseSensitive: false,
  );

  /// Time between snapshots while the scooter stays unlocked.
  static const every = Duration(minutes: 15);

  /// The first snapshot waits for the profile replay after a connection.
  static const settle = Duration(seconds: 60);

  final _keys = <String, _KeyShape>{};
  final _frames = <int, _FrameShape>{};
  Map<int, String> _reportedFrames = const {};
  final _ratio = <int, int>{};
  int? _speed;
  int? _rpm;
  int? _startedMicros;
  int? _lastMicros;
  bool _dirty = false;
  int _snapshots = 0;
  Object? _state;

  static bool _keepsText(String key, bool Function(String key)? isText) =>
      _textKeys.contains(key) || (isText?.call(key) ?? false);

  /// The one privacy rule for a value from the stock service, wherever it
  /// is written: a private key gives nothing, a string gives its text only
  /// where that is allowed and its length otherwise.
  static Object? shown(String key, Object? value, {bool Function(String key)? isText}) {
    final text = _keepsText(key, isText);
    if (!text && _private.hasMatch(key)) return null;
    return _KeyShape.shownValue(value, text: text);
  }

  /// One batch from the stock service, raw.
  void note(Map<Object?, Object?> delta) {
    final now = AnalyticsLogger.instance.monoMicros;
    _startedMicros ??= now;
    for (final MapEntry(:key, :value) in delta.entries) {
      if (key is! String) continue;
      final text = _keepsText(key, isText);
      (_keys[key] ??= _KeyShape()).add(value, text: text, private: !text && _private.hasMatch(key));
      _dirty = true;
    }
    final speed = delta['INT_VEHICLE_SPEED'];
    if (speed is num) _speed = speed.round();
    final rpm = delta['INT_VEHICLE_MOTOR_RPM'];
    if (rpm is num) _rpm = rpm.round();
    // Hundredths of raw rpm per km/h, at a speed where one unit of either
    // is a small error.
    if ((speed is num || rpm is num) && _speed != null && _rpm != null && _speed! >= 20) {
      final bucket = (_rpm!.abs() * 100 / _speed!).round();
      _ratio[bucket] = (_ratio[bucket] ?? 0) + 1;
    }
    final state = delta['INT_VEHICLE_STATE'];
    if (state != null) {
      final locking = state == _locked && _state != null && _state != _locked;
      _state = state;
      if (locking && _dirty) return emit('lock');
    }
    final since = now - (_lastMicros ?? _startedMicros!);
    if (_dirty && since >= (_lastMicros == null ? settle : every).inMicroseconds) emit('timer');
  }

  /// One raw frame from the battery data stream.
  void noteFrame(Uint8List frame) {
    if (frame.length < 8) return;
    final id = (frame[0] << 24) | (frame[1] << 16) | (frame[2] << 8) | frame[3];
    (_frames[id] ??= _FrameShape(frame)).add(frame);
  }

  /// The shape of every frame noted here, by id, as [emit] writes it.
  Map<int, String> get frameShapes => {for (final e in _frames.entries) e.key: e.value.describe()};

  /// Frame shapes noted somewhere else (the bus worker, `CanLink`): the
  /// whole set each time, replacing the last.
  void setFrameShapes(Map<int, String> rows) => _reportedFrames = rows;

  /// Median of raw rpm per km/h, and how many samples it rests on.
  (double?, int) get rpmPerKmh {
    final total = _ratio.values.fold(0, (a, b) => a + b);
    if (total == 0) return (null, 0);
    var seen = 0;
    for (final bucket in _ratio.keys.toList()..sort()) {
      seen += _ratio[bucket]!;
      if (seen * 2 >= total) return (bucket / 100, total);
    }
    return (null, total);
  }

  /// Writes the snapshot: `survey.values` (in parts), `survey.frames` and
  /// `survey.ratio`. Called by [note] on its own clock and by the vehicle
  /// notifier when the scooter locks.
  void emit(String reason) {
    final frames = {..._reportedFrames, ...frameShapes};
    if (_keys.isEmpty && frames.isEmpty) return;
    _lastMicros = AnalyticsLogger.instance.monoMicros;
    _dirty = false;
    final n = ++_snapshots;
    final rows = [for (final key in _keys.keys.toList()..sort()) '$key|${_keys[key]!.describe()}'];
    const part = 60;
    for (var i = 0; i < rows.length; i += part) {
      logEvent(
        'survey',
        'values',
        {
          'snapshot': n,
          'reason': reason,
          'part': i ~/ part + 1,
          'parts': (rows.length / part).ceil(),
          'keys': rows.length,
          'rows': rows.sublist(i, i + part > rows.length ? rows.length : i + part),
        },
        const {'rows'},
      );
    }
    if (frames.isNotEmpty) {
      logEvent(
        'survey',
        'frames',
        {
          'snapshot': n,
          'rows': [for (final id in frames.keys.toList()..sort()) '${id.toRadixString(16)}|${frames[id]}'],
        },
        const {'rows'},
      );
    }
    final (ratio, samples) = rpmPerKmh;
    if (ratio != null) logEvent('survey', 'ratio', {'snapshot': n, 'raw_rpm_per_kmh': ratio, 'samples': samples});
  }
}

class _KeyShape {
  String type = '';
  int count = 0;
  num? min;
  num? max;
  final distinct = <Object>{};
  bool overflow = false;

  void add(Object? value, {required bool text, required bool private}) {
    count++;
    final t = switch (value) {
      null => 'null',
      bool _ => 'bool',
      int _ => 'int',
      double _ => 'double',
      String _ => 'string',
      List _ => 'list',
      Map _ => 'map',
      _ => 'other',
    };
    if (type.isEmpty) {
      type = t;
    } else if (!type.split('/').contains(t)) {
      type = '$type/$t';
    }
    if (private) return;
    final shown = shownValue(value, text: text);
    if (shown is num) {
      if (min == null || shown < min!) min = shown;
      if (max == null || shown > max!) max = shown;
    }
    if (shown == null || distinct.contains(shown)) return;
    if (distinct.length >= ScooterSurvey._maxDistinct) {
      overflow = true;
    } else {
      distinct.add(shown);
    }
  }

  static Object? shownValue(Object? value, {required bool text}) {
    return switch (value) {
      final bool b => b,
      final int i => i,
      // Two decimals: enough to see a scale, not a stream of noise.
      final double d => d.isFinite ? (d * 100).round() / 100 : null,
      final String s => text ? (s.length > 40 ? s.substring(0, 40) : s) : 'len${s.length}',
      final List l => 'n${l.length}',
      final Map m => 'n${m.length}',
      _ => null,
    };
  }

  /// `type|count|min|max|v1,v2,...` with `+` after the values when there
  /// were more than are listed.
  String describe() => '$type|$count|${min ?? ''}|${max ?? ''}|${distinct.join(',')}${overflow ? ',+' : ''}';
}

class _FrameShape {
  _FrameShape(Uint8List frame)
      : first = Uint8List.fromList(frame),
        last = Uint8List.fromList(frame),
        changed = Uint8List(frame.length);

  final Uint8List first;
  Uint8List last;
  final Uint8List changed;
  int count = 0;
  final lengths = <int>{};

  void add(Uint8List frame) {
    count++;
    lengths.add(frame.length);
    final n = frame.length < first.length ? frame.length : first.length;
    for (var i = 0; i < n; i++) {
      changed[i] |= frame[i] ^ first[i];
    }
    if (frame.length == last.length) {
      last.setAll(0, frame);
    } else {
      last = Uint8List.fromList(frame);
    }
  }

  static String _hex(Uint8List b, [int from = 0]) =>
      [for (var i = from; i < b.length; i++) b[i].toRadixString(16).padLeft(2, '0')].join();

  /// `count|lengths|dlc|first data|last data|changed-bits mask`: the eight
  /// data bytes start at offset 8, after the id, the length and padding.
  String describe() {
    final dlc = first.length > 4 ? first[4] : 0;
    final at = first.length >= 16 ? 8 : 0;
    return '$count|${(lengths.toList()..sort()).join(',')}|$dlc|${_hex(first, at)}|${_hex(last, at)}|${_hex(changed, at)}';
  }
}
