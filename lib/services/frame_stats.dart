import 'package:flutter/scheduler.dart';

import 'analytics_logger.dart';

/// How smoothly the dashboard is drawing, summed up every [window] as
/// `app.frames`. Added because swiping the right-hand panel felt
/// heavier on the move than parked, the gesture code is the same in both,
/// and nothing in the log could say whether the app was dropping frames.
///
/// No timer of its own: a window closes on the first frame after it has run
/// out, so a screen that is not drawing logs nothing.
class FrameStats {
  FrameStats({required this.riding, this.window = const Duration(seconds: 10)});

  /// A frame that takes longer than this missed its 60 Hz slot.
  static const budgetMicros = 16667;

  final bool Function() riding;
  final Duration window;
  final _build = <int>[];
  final _raster = <int>[];
  final _vsync = <int>[];
  int _slow = 0;
  int _startedMicros = 0;
  bool _ridingSeen = false;

  void start() => SchedulerBinding.instance.addTimingsCallback(onTimings);

  void onTimings(List<FrameTiming> timings) {
    final now = AnalyticsLogger.instance.monoMicros;
    if (_build.isEmpty) _startedMicros = now;
    for (final t in timings) {
      final build = t.buildDuration.inMicroseconds;
      final raster = t.rasterDuration.inMicroseconds;
      _build.add(build);
      _raster.add(raster);
      _vsync.add(t.vsyncOverhead.inMicroseconds);
      if (build + raster > budgetMicros) _slow++;
    }
    _ridingSeen = _ridingSeen || riding();
    if (now - _startedMicros >= window.inMicroseconds) flush();
  }

  void flush() {
    if (_build.isEmpty) return;
    logEvent('app', 'frames', {
      'n': _build.length,
      'slow': _slow,
      'build_p95_ms': _ms(_p95(_build)),
      'build_max_ms': _ms(_build.reduce((a, b) => a > b ? a : b)),
      'raster_p95_ms': _ms(_p95(_raster)),
      'raster_max_ms': _ms(_raster.reduce((a, b) => a > b ? a : b)),
      // How long after its vsync a frame began to build: the main thread
      // was busy with something else for that long (it also carries the
      // bus stream and every channel call).
      'vsync_p95_ms': _ms(_p95(_vsync)),
      'vsync_max_ms': _ms(_vsync.reduce((a, b) => a > b ? a : b)),
      'riding': _ridingSeen,
    });
    _build.clear();
    _raster.clear();
    _vsync.clear();
    _slow = 0;
    _ridingSeen = false;
  }

  static int _p95(List<int> values) {
    final sorted = [...values]..sort();
    return sorted[((sorted.length - 1) * 0.95).round()];
  }

  static double _ms(int micros) => (micros / 100).round() / 10;
}
