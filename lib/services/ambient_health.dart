import 'dart:convert';

/// Whether the "ambient light" value this scooter sends behaves like a
/// light sensor. On a Gen 1 scooter on service 4.6.14 it is the screen
/// brightness coming back: it read 60 for days while the brightness was 60,
/// and it followed every brightness step (30, 60, 100, 30) a second
/// or two behind. Another scooter may have a real sensor. So nothing is
/// assumed: the readings are watched, readings that merely repeat the
/// brightness are set aside, and the value is relied on only once it has
/// been seen to move on its own.
enum AmbientVerdict {
  /// Not enough seen yet to say either way. Not relied on.
  unknown,

  /// It has sat at two clearly different levels that were not the screen
  /// brightness: a light sensor.
  usable,

  /// Hours of readings and it never moved.
  stuck,

  /// It repeats the screen brightness.
  echo,
}

class AmbientHealth {
  AmbientHealth();

  /// Readings are grouped in steps of this many points (0-100).
  static const bucketWidth = 5;
  static const _buckets = 100 ~/ bucketWidth + 1;

  /// Two levels count as different when they are at least this many steps
  /// apart: 10 points, so a reading on a step boundary is not "movement".
  static const bucketGap = 2;

  /// How long the value must have sat at a level for the level to count.
  static const dwell = Duration(minutes: 5);

  /// The first readings after each connection are left out: the boot-time
  /// 10 on a scooter whose value is otherwise fixed.
  static const settle = Duration(seconds: 60);

  /// With this much watched and no second level, it is stuck.
  static const stuckAfter = Duration(hours: 6);

  /// Older time fades (halved) past this, so a sensor that dies later is
  /// noticed and one that starts working is not outvoted for ever.
  static const window = Duration(hours: 48);

  /// A gap between two readings longer than this is not counted: the app
  /// was paused or the frames stopped.
  static const maxStep = Duration(seconds: 2);

  /// A reading within this many points of the screen brightness is the
  /// brightness coming back, not light.
  static const echoTolerance = 2;

  /// A reading is credited to a level (counted as independent movement) only
  /// once the brightness has held steady this long. The echo trails brightness
  /// changes, and in the ambient-theme + auto-brightness feedback loop
  /// it lagged several seconds behind rapid changes; a short guard
  /// let those lagging reads look like a second level. Requiring the brightness
  /// to be settled this long means a value that only moves when the brightness
  /// moves can never pass for a sensor, while a real sensor at a steady
  /// brightness still counts.
  static const echoLag = Duration(seconds: 30);

  /// This much time repeating the brightness, and most of what was seen,
  /// names it an echo.
  static const echoAfter = Duration(minutes: 10);

  final List<int> _ms = List.filled(_buckets, 0);
  int _echoMs = 0;
  int? _sessionStartMicros;
  int? _lastMicros;
  int? _lastBucket;
  bool _lastEcho = false;
  int? _brightness;
  int _brightnessChangedMicros = 0;

  /// Time credited to a level, i.e. not spent repeating the brightness.
  int get observedMs => _ms.fold(0, (a, b) => a + b);
  int get echoMs => _echoMs;

  /// Silence this long means a new connection or a wake from sleep: the
  /// settle period starts over.
  static const sessionGap = Duration(seconds: 30);

  /// One reading at [nowMicros] on a monotonic clock, with the screen
  /// [brightness] at that moment. The time since the previous reading is
  /// credited to the level the value was at, or to the echo count when the
  /// value was just the brightness.
  void add(int ambient, int nowMicros, {int? brightness}) {
    final bucket = ambient.clamp(0, 100) ~/ bucketWidth;
    final last = _lastMicros, lastBucket = _lastBucket, lastEcho = _lastEcho;
    if (last != null && nowMicros - last > sessionGap.inMicroseconds) _sessionStartMicros = nowMicros;
    final start = _sessionStartMicros ??= nowMicros;
    if (brightness != _brightness) {
      _brightness = brightness;
      _brightnessChangedMicros = nowMicros;
    }
    final settling = brightness != null && nowMicros - _brightnessChangedMicros < echoLag.inMicroseconds;
    _lastMicros = nowMicros;
    _lastBucket = settling ? null : bucket;
    _lastEcho = brightness != null && (ambient - brightness).abs() <= echoTolerance;
    if (nowMicros - start < settle.inMicroseconds || last == null || lastBucket == null) return;
    final step = nowMicros - last;
    if (step <= 0 || step > maxStep.inMicroseconds) return;
    if (lastEcho) {
      _echoMs += step ~/ 1000;
      if (_echoMs > window.inMilliseconds) _echoMs ~/= 2;
      return;
    }
    _ms[lastBucket] += step ~/ 1000;
    if (observedMs > window.inMilliseconds) {
      for (var i = 0; i < _buckets; i++) {
        _ms[i] ~/= 2;
      }
    }
  }

  /// The levels (lower bound of each step) the value has dwelt at.
  List<int> get levels => [
        for (var i = 0; i < _buckets; i++)
          if (_ms[i] >= dwell.inMilliseconds) i * bucketWidth,
      ];

  AmbientVerdict get verdict {
    final seen = levels;
    if (seen.isNotEmpty && seen.last - seen.first >= bucketGap * bucketWidth) return AmbientVerdict.usable;
    if (_echoMs >= echoAfter.inMilliseconds && _echoMs >= observedMs * 9) return AmbientVerdict.echo;
    return observedMs >= stuckAfter.inMilliseconds ? AmbientVerdict.stuck : AmbientVerdict.unknown;
  }

  /// A history in which the value sat at [levels] long enough to count;
  /// for tests and the dev panel.
  factory AmbientHealth.proven([List<int> levels = const [0, 80]]) {
    final health = AmbientHealth();
    for (final level in levels) {
      health._ms[level.clamp(0, 100) ~/ bucketWidth] = dwell.inMilliseconds;
    }
    return health;
  }

  String toJson() => jsonEncode({'ms': _ms, 'echo': _echoMs});

  /// Anything malformed starts from nothing.
  factory AmbientHealth.fromJson(String raw) {
    final health = AmbientHealth();
    if (raw.isEmpty) return health;
    try {
      // A bare list is the first format, kept before echoes were told
      // apart; what it holds may be the brightness, so it is dropped.
      final json = jsonDecode(raw);
      final ms = json is Map ? json['ms'] : null;
      final echo = json is Map ? json['echo'] : null;
      if (ms is List && ms.length == _buckets && ms.every((e) => e is int && e >= 0)) {
        for (var i = 0; i < _buckets; i++) {
          health._ms[i] = ms[i] as int;
        }
        if (echo is int && echo >= 0) health._echoMs = echo;
      }
    } on FormatException {
      // Start over.
    }
    return health;
  }

  Map<String, Object?> describe() => {
        'verdict': verdict.name,
        'observed_s': observedMs ~/ 1000,
        'echo_s': _echoMs ~/ 1000,
        'levels': levels,
        // Seconds at each level that has any, as "level:seconds".
        'seconds': [
          for (var i = 0; i < _buckets; i++)
            if (_ms[i] >= 1000) '${i * bucketWidth}:${_ms[i] ~/ 1000}',
        ],
      };
}
