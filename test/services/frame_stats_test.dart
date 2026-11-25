import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/frame_stats.dart';

FrameTiming _frame({required int buildMs, required int rasterMs}) => FrameTiming(
      vsyncStart: 0,
      buildStart: 0,
      buildFinish: buildMs * 1000,
      rasterStart: buildMs * 1000,
      rasterFinish: (buildMs + rasterMs) * 1000,
      rasterFinishWallTime: (buildMs + rasterMs) * 1000,
    );

void main() {
  setUp(AnalyticsLogger.instance.resetForTest);

  List<Map<Object?, Object?>> frames() =>
      [for (final e in AnalyticsLogger.instance.recent('app', 'frames')) e['data']! as Map];

  test('a window is summed up when it is flushed: count, slow frames, worst and p95 times', () {
    final stats = FrameStats(riding: () => false);
    stats.onTimings([
      for (var i = 0; i < 18; i++) _frame(buildMs: 4, rasterMs: 5),
      _frame(buildMs: 12, rasterMs: 9),
      _frame(buildMs: 30, rasterMs: 6),
    ]);
    expect(frames(), isEmpty, reason: 'the window has not run out');
    stats.flush();
    final f = frames().single;
    expect(f['n'], 20);
    expect(f['slow'], 2, reason: 'two frames took more than 16.7 ms in all');
    expect(f['build_max_ms'], 30.0);
    expect(f['build_p95_ms'], 12.0);
    expect(f['raster_max_ms'], 9.0);
    expect(f['riding'], isFalse);
  });

  test('a window that saw the riding lockout at any point is marked riding, and the next one starts clean', () {
    var riding = true;
    final stats = FrameStats(riding: () => riding);
    stats.onTimings([_frame(buildMs: 5, rasterMs: 5)]);
    riding = false;
    stats.onTimings([_frame(buildMs: 5, rasterMs: 5)]);
    stats.flush();
    expect(frames().single['riding'], isTrue);
    stats.onTimings([_frame(buildMs: 5, rasterMs: 5)]);
    stats.flush();
    expect(frames().last['riding'], isFalse);
    expect(frames().last['n'], 1);
  });

  test('nothing is logged for a screen that drew nothing', () {
    FrameStats(riding: () => false).flush();
    expect(frames(), isEmpty);
  });
}
