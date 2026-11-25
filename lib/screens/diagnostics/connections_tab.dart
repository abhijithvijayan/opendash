import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/build_info.dart';
import '../../models/connection_health.dart';
import '../../providers/battery_diagnostics_provider.dart';
import '../../providers/mock_provider.dart';
import '../../services/analytics_logger.dart';
import '../../state/riding_lockout.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../settings/widgets.dart';

/// Is the dashboard actually hearing the scooter? HHMIS (vehicle data), the
/// CAN stream over gRPC, and the app itself, refreshed once a second while
/// the tab is open. Saves a log pull for "is it connected" questions.
class ConnectionsTab extends ConsumerStatefulWidget {
  const ConnectionsTab({super.key});

  static const refresh = Duration(seconds: 1);

  @override
  ConsumerState<ConnectionsTab> createState() => _ConnectionsTabState();
}

class _ConnectionsTabState extends ConsumerState<ConnectionsTab> {
  Timer? _timer;
  HhmisHealth? _prevHhmis;
  GrpcHealth? _prevGrpc;
  int? _batchRate;
  int? _frameRate;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(ConnectionsTab.refresh, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hhmis = ref.read(vehicleProvider.notifier).health;
    final grpc = ref.read(batteryDiagnosticsProvider.notifier).health;
    if (hhmis != null && _prevHhmis != null && hhmis.batches >= _prevHhmis!.batches) {
      _batchRate = hhmis.batches - _prevHhmis!.batches;
    }
    if (grpc != null && _prevGrpc != null && grpc.frames >= _prevGrpc!.frames) {
      _frameRate = grpc.frames - _prevGrpc!.frames;
    }
    _prevHhmis = hhmis;
    _prevGrpc = grpc;
    final riding = ref.watch(ridingLockoutProvider);

    return SingleChildScrollView(
      key: const ValueKey('diag-connections'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader('Vehicle data (HHMIS)'),
          if (hhmis == null)
            const _Line('Source', 'Mock data', ok: null)
          else ...[
            _Line(
              'Status',
              hhmis.connectedForMicros == null
                  ? 'Not connected'
                  : hhmis.stale
                      ? 'Connected, data frozen'
                      : 'Connected ${_duration(hhmis.connectedForMicros!)}',
              ok: hhmis.connectedForMicros != null && !hhmis.stale,
            ),
            _Line('Last data', hhmis.lastDataAgoMicros == null ? '—' : '${_ago(hhmis.lastDataAgoMicros!)} ago',
                ok: hhmis.lastDataAgoMicros != null && hhmis.lastDataAgoMicros! < 3000000),
            _Line('Updates', _batchRate == null ? '—' : '$_batchRate / s', ok: null),
            _Line('Callback slot', hhmis.inFront ? (hhmis.stale ? 'Probably taken' : 'Held') : 'Not checked (in background)',
                ok: hhmis.inFront ? !hhmis.stale : null),
            _Line('Re-attaches', '${hhmis.reattaches}', ok: null),
            _Line('Start-up handshake', hhmis.projectLoadedSent ? 'Sent' : 'Waiting for park / charging', ok: null),
            _Line('Touch heartbeat', switch (hhmis.touchOn) { true => 'Touch', false => 'Idle', null => '—' }, ok: null),
            _Line(
              'Last command',
              hhmis.lastCommand == null ? '—' : '${hhmis.lastCommand} · ${hhmis.lastCommandOk == true ? 'ok' : 'failed'} · ${hhmis.lastCommandMs} ms',
              ok: hhmis.lastCommandOk,
            ),
            _Line('Last vehicle message', hhmis.lastVehicleCommand == null ? '—' : '#${hhmis.lastVehicleCommand}', ok: null),
            _Line('Last popup', hhmis.lastPopupId == null ? '—' : 'id ${hhmis.lastPopupId}', ok: null),
          ],
          const SizedBox(height: 12),
          const SectionHeader('CAN bus (gRPC)'),
          if (grpc == null)
            const _Line('Source', 'Mock data', ok: null)
          else ...[
            _Line(
              'Status',
              grpc.connected ? (grpc.receivingFrames ? 'Streaming' : 'Connected, no frames yet') : 'Retrying in ≤ ${grpc.backoffSeconds} s',
              ok: grpc.connected && grpc.receivingFrames,
            ),
            _Line('Stream', grpc.dump ? 'Dump fallback' : 'ReadCanStream', ok: null),
            _Line('Last frame', grpc.lastFrameAgoMicros == null ? '—' : '${_ago(grpc.lastFrameAgoMicros!)} ago',
                ok: grpc.lastFrameAgoMicros != null && grpc.lastFrameAgoMicros! < 3000000),
            _Line('Frames', _frameRate == null ? '—' : '$_frameRate / s', ok: null),
            _Line('Connect attempts', '${grpc.attempt}', ok: null),
            if (grpc.lastWindowByCanId.isNotEmpty)
              _Line(
                'Per CAN ID (10 s)',
                (grpc.lastWindowByCanId.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
                    .map((e) => '${e.key} ${e.value}')
                    .join('  '),
                ok: null,
              ),
          ],
          const SizedBox(height: 12),
          const SectionHeader('App'),
          _Line('Build', BuildInfo.label, ok: null),
          _Line('Up for', _duration(AnalyticsLogger.instance.monoMicros), ok: null),
          _Line('Memory', _memory(), ok: null),
          _Line('Log file', _logSize(), ok: null),
          const SizedBox(height: 20),
          Row(
            children: [
              Opacity(
                opacity: riding ? 0.4 : 1,
                child: PrimaryButton(
                  'Re-attach HHMIS',
                  key: const ValueKey('conn-reattach'),
                  onTap: () {
                    if (riding) return;
                    uiTap('conn-reattach');
                    ref.read(vehicleProvider.notifier).reattachNow();
                  },
                ),
              ),
              const SizedBox(width: 16),
              Opacity(
                opacity: riding ? 0.4 : 1,
                child: PrimaryButton(
                  'Reconnect CAN',
                  key: const ValueKey('conn-reconnect'),
                  onTap: () {
                    if (riding) return;
                    uiTap('conn-reconnect');
                    ref.read(batteryDiagnosticsProvider.notifier).reconnectNow();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  static String _ago(int micros) {
    final ms = micros ~/ 1000;
    return ms < 1000 ? '$ms ms' : '${(ms / 1000).toStringAsFixed(1)} s';
  }

  static String _duration(int micros) {
    final s = micros ~/ 1000000;
    if (s < 60) return '${s}s';
    if (s < 3600) return '${s ~/ 60}m ${s % 60}s';
    return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
  }

  static String _memory() {
    final free = AnalyticsLogger.instance.context['free_ram_mb'];
    int? rss;
    if (!kIsWeb) {
      try {
        rss = ProcessInfo.currentRss ~/ (1024 * 1024);
      } catch (_) {}
    }
    return [if (rss != null) 'app $rss MB', if (free != null) 'system free $free MB'].join(' · ').ifEmpty('—');
  }

  static String _logSize() {
    final path = AnalyticsLogger.instance.currentFilePath;
    if (path == null || kIsWeb) return 'Memory only';
    try {
      return '${(File(path).lengthSync() / (1024 * 1024)).toStringAsFixed(1)} MB';
    } catch (_) {
      return '—';
    }
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// A label, a value and, when it means something, a green / red dot.
class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {required this.ok});
  final String label;
  final String value;
  final bool? ok;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 40,
        child: Row(
          children: [
            SizedBox(
              width: 18,
              child: ok == null
                  ? null
                  : Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: ok! ? DashColors.eco : DashColors.critical),
                    ),
            ),
            SizedBox(width: 240, child: Text(label, style: DashText.caption(18), maxLines: 1, overflow: TextOverflow.ellipsis)),
            Expanded(child: Text(value, style: DashText.value(18), maxLines: 1, overflow: TextOverflow.ellipsis)),
          ],
        ),
      );
}
