import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'analytics_logger.dart';

/// `app.memory` every [period]: our RSS from `dart:io` and the system's
/// headroom from `/proc/meminfo` (world-readable, no permission). A HOME
/// app that runs for hours on a 3 GB head unit needs both: RSS that never
/// plateaus is a leak, `MemAvailable` near zero means the low-memory
/// killer is close. The latest `MemAvailable` is also cached for the
/// heartbeat's `free_ram_mb`, so the 1 Hz snapshots carry coarse memory
/// context without reading `/proc` at 1 Hz.
class AnalyticsHealthSampler {
  AnalyticsHealthSampler({
    this.period = const Duration(seconds: 15),
    this.meminfoPath = '/proc/meminfo',
    int Function()? rss,
    int Function()? maxRss,
  })  : _rss = rss ?? (() => ProcessInfo.currentRss),
        _maxRss = maxRss ?? (() => ProcessInfo.maxRss);

  static const _wanted = {'MemTotal', 'MemAvailable', 'SwapFree', 'Cached'};

  final Duration period;
  final String meminfoPath;
  final int Function() _rss;
  final int Function() _maxRss;
  Timer? _timer;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(period, (_) => sample());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One sample; emits nothing while logging is off. The read is
  /// synchronous: `/proc/meminfo` is a few hundred bytes of kernel memory,
  /// cheaper than a trip through the IO thread, and the cadence is 15 s.
  void sample() {
    if (!AnalyticsLogger.instance.enabled) return;
    try {
      final mem = _readMeminfo();
      final available = mem['MemAvailable'];
      if (available != null) AnalyticsLogger.instance.context['free_ram_mb'] = available;
      logEvent('app', 'memory', {
        'rss_mb': _mb(_safe(_rss)),
        'max_rss_mb': _mb(_safe(_maxRss)),
        'system_mem_total_mb': mem['MemTotal'],
        'system_mem_available_mb': available,
        'swap_free_mb': mem['SwapFree'],
        'cached_mb': mem['Cached'],
      });
    } catch (e) {
      debugPrint('[analytics] memory sample failed: $e');
    }
  }

  static int? _safe(int Function() read) {
    try {
      return read();
    } catch (_) {
      return null;
    }
  }

  static int? _mb(int? bytes) => bytes == null ? null : bytes ~/ (1024 * 1024);

  /// The four lines we want from `/proc/meminfo`, in MiB; empty when the
  /// file is unreadable (tests, desktop).
  Map<String, int> _readMeminfo() {
    final file = File(meminfoPath);
    if (!file.existsSync()) return const {};
    return parseMeminfo(file.readAsLinesSync());
  }

  /// `MemAvailable:    1234567 kB` -> `{'MemAvailable': 1205}`.
  @visibleForTesting
  static Map<String, int> parseMeminfo(List<String> lines) {
    final out = <String, int>{};
    for (final line in lines) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final key = line.substring(0, colon);
      if (!_wanted.contains(key)) continue;
      final parts = line.substring(colon + 1).trim().split(RegExp(r'\s+'));
      final kb = int.tryParse(parts.first);
      if (kb != null) out[key] = kb ~/ 1024;
    }
    return out;
  }
}
