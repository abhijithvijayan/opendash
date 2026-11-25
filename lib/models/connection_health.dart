/// Snapshots for Diagnostics → Connections. Null on the mock providers.
class HhmisHealth {
  const HhmisHealth({
    required this.connectedForMicros,
    required this.lastDataAgoMicros,
    required this.stale,
    required this.inFront,
    required this.batches,
    required this.reattaches,
    required this.projectLoadedSent,
    required this.touchOn,
    required this.lastCommand,
    required this.lastCommandOk,
    required this.lastCommandMs,
    required this.lastVehicleCommand,
    required this.lastPopupId,
  });

  final int? connectedForMicros;
  final int? lastDataAgoMicros;
  final bool stale;
  final bool inFront;
  final int batches;
  final int reattaches;
  final bool projectLoadedSent;
  final bool? touchOn;
  final String? lastCommand;
  final bool? lastCommandOk;
  final int? lastCommandMs;
  final int? lastVehicleCommand;
  final int? lastPopupId;
}

class GrpcHealth {
  const GrpcHealth({
    required this.connected,
    required this.dump,
    required this.receivingFrames,
    required this.attempt,
    required this.backoffSeconds,
    required this.lastFrameAgoMicros,
    required this.frames,
    required this.lastWindowByCanId,
  });

  final bool connected;
  final bool dump;
  final bool receivingFrames;
  final int attempt;
  final int backoffSeconds;
  final int? lastFrameAgoMicros;
  final int frames;
  final Map<String, int> lastWindowByCanId;
}
