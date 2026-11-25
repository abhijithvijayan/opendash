import 'analytics_logger.dart';
import 'prefs_service.dart';

/// The head unit has no battery-backed clock. After a cold boot with no
/// network Android starts it at the firmware's build date
/// (`ro.build.date.utc`) and it counts up from there until something sets
/// it: on one cold boot the session began 5 s after that date and got the real
/// time 47 s later. Everything that asks "what time is it" goes through
/// here, so a clock that cannot be right is treated as unknown instead of
/// believed.
///
/// No date is written into the rule. A clock is at its default when it has
/// run no further past the firmware build date than the device has been up
/// ([configure]); it is a reset when it is behind the last good reading.
abstract final class TrustedClock {
  /// Margin on "no further past the build date than the uptime". The real
  /// time is years past any firmware build; a day is nothing against that.
  static const defaultSlack = Duration(days: 1);

  /// A clock this far behind the last good reading is a reset, not a
  /// correction.
  static const backstep = Duration(days: 1);
  static const saveEvery = Duration(minutes: 1);

  /// A step between two ticks larger than this is logged as a jump.
  static const jumpThreshold = Duration(seconds: 5);

  static DateTime Function() wall = DateTime.now;

  static final Stopwatch _mono = Stopwatch();
  static int? _lastGoodMs;
  static int _lastGoodAtMicros = 0;
  static int _savedAtMicros = 0;
  static int? _prevWallMs;
  static int _prevMonoMicros = 0;
  static bool? _wasTrusted;

  static int? _firmwareBuildMs;
  static int _uptimeAtConfigMs = 0;
  static int _configAtMicros = 0;

  /// The firmware build time and the device uptime at this moment, from the
  /// platform (`Build.TIME`, `SystemClock.elapsedRealtime`). Without them
  /// (web, tests, a failed lookup) only the last good reading is checked.
  static void configure({required int firmwareBuildMs, required int elapsedRealtimeMs}) {
    _firmwareBuildMs = firmwareBuildMs;
    _uptimeAtConfigMs = elapsedRealtimeMs;
    _configAtMicros = _mono.elapsedMicroseconds;
  }

  static int get _uptimeMs => _uptimeAtConfigMs + (_mono.elapsedMicroseconds - _configAtMicros) ~/ 1000;

  static DateTime? get _lastGood =>
      _lastGoodMs == null ? null : DateTime.fromMillisecondsSinceEpoch(_lastGoodMs!);

  /// Call once after [PrefsService.init]. Safe to skip: an uninitialised
  /// clock only has the build floor to go by.
  static void init() {
    _mono
      ..reset()
      ..start();
    final saved = PrefsService.getInt(PrefsKeys.clockLastGood, 0);
    _lastGoodMs = saved > 0 ? saved : null;
    _lastGoodAtMicros = 0;
    _savedAtMicros = 0;
    _prevWallMs = null;
    _wasTrusted = null;
  }

  static bool _plausible(DateTime t) {
    final firmware = _firmwareBuildMs;
    if (firmware != null && t.millisecondsSinceEpoch < firmware + _uptimeMs + defaultSlack.inMilliseconds) return false;
    final good = _lastGood;
    return good == null || !t.isBefore(good.subtract(backstep));
  }

  static bool get trusted => _plausible(wall());

  /// Whether [t], a time another app took from this head unit's clock, can
  /// be told to the rider: not from before the network set the clock.
  static bool plausible(DateTime t) => _plausible(t);

  /// Whether [now] has a last good reading to stand in with.
  static bool get hasEstimate => _lastGoodMs != null;

  /// The wall clock when it can be right. Otherwise the last good reading
  /// plus the time this process has been up: behind by however long the
  /// scooter was off, but on the right day far more often than 2024 is.
  /// For records and log lines, never for the clock on screen.
  static DateTime now() {
    final t = wall();
    if (_plausible(t)) return t;
    final good = _lastGoodMs;
    if (good == null) return t;
    return DateTime.fromMillisecondsSinceEpoch(good + (_mono.elapsedMicroseconds - _lastGoodAtMicros) ~/ 1000);
  }

  /// Once a second from the vehicle notifier. Logs the state at the first
  /// tick, every jump and every change of trust, and keeps the last good
  /// reading saved. [context] adds what was connected at that moment, to
  /// show what set the clock.
  static bool tick([Map<String, Object?> Function()? context]) {
    final t = wall();
    final mono = _mono.elapsedMicroseconds;
    final ok = _plausible(t);
    final prevWall = _prevWallMs;
    if (_wasTrusted == null) {
      logEvent('time', 'boot', {..._describe(t, ok), ...?context?.call()});
    } else if (prevWall != null) {
      final stepMs = (t.millisecondsSinceEpoch - prevWall) - (mono - _prevMonoMicros) ~/ 1000;
      if (stepMs.abs() > jumpThreshold.inMilliseconds) {
        logEvent('time', 'jump', {
          'from': DateTime.fromMillisecondsSinceEpoch(prevWall, isUtc: true).toIso8601String(),
          'step_s': stepMs ~/ 1000,
          'up_s': mono ~/ 1000000,
          ..._describe(t, ok),
          ...?context?.call(),
        });
      }
    }
    if (_wasTrusted != null && _wasTrusted != ok) {
      logEvent('time', 'trusted', {
        'on': ok,
        'up_s': mono ~/ 1000000,
        // How far off the stand-in was, now that the real time is known.
        if (ok && _lastGoodMs != null)
          'estimate_error_s': (t.millisecondsSinceEpoch -
                  (_lastGoodMs! + (mono - _lastGoodAtMicros) ~/ 1000)) ~/
              1000,
        ...?context?.call(),
      });
    }
    _wasTrusted = ok;
    _prevWallMs = t.millisecondsSinceEpoch;
    _prevMonoMicros = mono;
    if (ok) {
      _lastGoodMs = t.millisecondsSinceEpoch;
      _lastGoodAtMicros = mono;
      if (_savedAtMicros == 0 || mono - _savedAtMicros >= saveEvery.inMicroseconds) {
        _savedAtMicros = mono;
        PrefsService.setInt(PrefsKeys.clockLastGood, t.millisecondsSinceEpoch);
      }
    }
    return ok;
  }

  static Map<String, Object?> _describe(DateTime t, bool ok) => {
        'wall': t.toUtc().toIso8601String(),
        'trusted': ok,
        'tz_offset_min': t.timeZoneOffset.inMinutes,
        'tz': t.timeZoneName,
        'last_good': _lastGood?.toUtc().toIso8601String(),
        // What this firmware's default looks like: a clock at its default
        // has `since_firmware_s` close to `uptime_s`.
        if (_firmwareBuildMs != null) ...{
          'firmware_build': DateTime.fromMillisecondsSinceEpoch(_firmwareBuildMs!, isUtc: true).toIso8601String(),
          'since_firmware_s': (t.millisecondsSinceEpoch - _firmwareBuildMs!) ~/ 1000,
          'uptime_s': _uptimeMs ~/ 1000,
        },
        if (!ok) 'estimate': now().toUtc().toIso8601String(),
      };

  static void resetForTest() {
    wall = DateTime.now;
    _mono
      ..stop()
      ..reset()
      ..start();
    _lastGoodMs = null;
    _lastGoodAtMicros = 0;
    _savedAtMicros = 0;
    _prevWallMs = null;
    _prevMonoMicros = 0;
    _wasTrusted = null;
    _firmwareBuildMs = null;
    _uptimeAtConfigMs = 0;
    _configAtMicros = 0;
  }

  /// Tests: a last good reading without going through prefs.
  static void debugSetLastGood(DateTime t) {
    _lastGoodMs = t.millisecondsSinceEpoch;
    _lastGoodAtMicros = _mono.elapsedMicroseconds;
  }
}
