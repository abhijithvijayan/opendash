import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/services/analytics_health.dart';
import 'package:opendash/services/analytics_logger.dart';

void main() {
  setUp(() => AnalyticsLogger.instance.resetForTest());

  List<Map<String, Object?>> samples() => AnalyticsLogger.instance.recent('app', 'memory');

  test('parses the four meminfo lines into MiB', () {
    final parsed = AnalyticsHealthSampler.parseMeminfo([
      'MemTotal:        2957660 kB',
      'MemFree:          123456 kB',
      'MemAvailable:    1048576 kB',
      'Cached:           524288 kB',
      'SwapFree:         262144 kB',
      'garbage line',
    ]);
    expect(parsed, {'MemTotal': 2888, 'MemAvailable': 1024, 'Cached': 512, 'SwapFree': 256});
  });

  test('emits one app.memory per period with populated fields and feeds the heartbeat cache', () async {
    final tmp = await Directory.systemTemp.createTemp('opendash-meminfo-');
    addTearDown(() => tmp.delete(recursive: true));
    final meminfo = File('${tmp.path}/meminfo');
    await meminfo.writeAsString('MemTotal: 3000000 kB\nMemAvailable: 400000 kB\nSwapFree: 100000 kB\nCached: 900000 kB\n');
    final s = AnalyticsHealthSampler(
      meminfoPath: meminfo.path,
      rss: () => 150 * 1024 * 1024,
      maxRss: () => 210 * 1024 * 1024,
    );
    s.sample();
    final data = samples().single['data'] as Map;
    expect(data['rss_mb'], 150);
    expect(data['max_rss_mb'], 210);
    expect(data['system_mem_total_mb'], 2929);
    expect(data['system_mem_available_mb'], 390);
    expect(data['swap_free_mb'], 97);
    expect(data['cached_mb'], 878);
    expect(AnalyticsLogger.instance.context['free_ram_mb'], 390);
  });

  test('a missing /proc/meminfo degrades to nulls and still emits', () async {
    final s = AnalyticsHealthSampler(meminfoPath: '/nonexistent/meminfo', rss: () => 1 << 20, maxRss: () => 2 << 20);
    s.sample();
    final data = samples().single['data'] as Map;
    expect(data['rss_mb'], 1);
    expect(data['system_mem_available_mb'], isNull);
    expect(data['swap_free_mb'], isNull);
  });

  test('samples on its period and not while logging is off', () {
    fakeAsync((async) {
      final s = AnalyticsHealthSampler(period: const Duration(seconds: 15), meminfoPath: '/nonexistent', rss: () => 0, maxRss: () => 0)..start();
      async.elapse(const Duration(seconds: 46));
      expect(samples().length, 3);
      AnalyticsLogger.instance.setEnabled(false);
      async.elapse(const Duration(seconds: 30));
      expect(samples().length, 3);
      s.stop();
    });
  });
}
