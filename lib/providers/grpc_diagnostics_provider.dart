import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/battery_diagnostics.dart';
import '../models/connection_health.dart';
import '../services/analytics_logger.dart';
import '../services/can_host.dart';
import '../services/can_link.dart';
import '../services/can_session.dart';
import '../state/active_faults.dart';
import 'battery_diagnostics_provider.dart';
import 'mock_provider.dart';
import 'vehicle_provider.dart';

export '../services/can_session.dart' show FrameSession, FrameSource;

/// BMS cell data from `diagnostics_server`, as the dashboard sees it: the
/// connection, the decoding, the bus log and a raw recording all live in a
/// [CanLink], which on the scooter runs in a background isolate
/// ([IsolateCanHost]). This is only its face on the main isolate: it sends
/// the link its commands and puts what comes back (the decoded pack about
/// twice a second, losses, health, log events) where the app reads it.
/// With a [FrameSource] given (tests) the link runs here instead.
class GrpcDiagnosticsNotifier extends BatteryDiagnosticsNotifier {
  GrpcDiagnosticsNotifier({this.source});

  static const host = CanLink.host;
  static const port = CanLink.port;
  static const publishEvery = CanLink.publishEvery;
  static const retryMin = CanLink.retryMin;
  static const retryMax = CanLink.retryMax;
  static const silenceWindow = CanLink.silenceWindow;
  static const frameCountsEvery = CanLink.frameCountsEvery;
  static const dumpSilenceWindow = CanLink.dumpSilenceWindow;
  static const dumpRecheckMin = CanLink.dumpRecheckMin;
  static const dumpRecheckMax = CanLink.dumpRecheckMax;
  static const dumpStallWindow = CanLink.dumpStallWindow;
  static const dumpStallCheck = CanLink.dumpStallCheck;
  static const dumpRotateAfter = CanLink.dumpRotateAfter;

  /// Given, the link runs in this isolate on it; otherwise in the bus worker.
  final FrameSource? source;
  CanHealth? _health;

  bool get usingDumpFallback => _health?.dump ?? false;

  @override
  CanHost createHost() => source != null || kIsWeb
      ? InProcessCanHost(source: source ?? () => openCanSession(host, port), onEvent: onCanEvent)
      : IsolateCanHost(onEvent: onCanEvent);

  @override
  BatteryDiagnostics build() {
    ref.onDispose(() {
      disposeHost();
      AnalyticsLogger.instance.context.remove('grpc_dump');
    });
    ref.listen(vehicleProvider.select((v) => v.motorTemp), (_, t) => send(CanSetMotorTemp(t.toDouble())));
    send(CanSetMotorTemp(ref.read(vehicleProvider).motorTemp.toDouble()));
    return const BatteryDiagnostics();
  }

  // The dev panel's mock knobs have no meaning on a real pack.
  @override
  void setDegradedCells(bool on) {}

  @override
  void setHotPack(bool on) {}

  @override
  void setBalancing(bool on) {}

  @override
  void onLifecyclePause() => send(const CanPause());

  @override
  void onLifecycleResume() => send(const CanResume());

  @override
  void reconnectNow() => send(const CanReconnectNow());

  @override
  GrpcHealth get health {
    final h = _health;
    final last = h?.lastFrameMicros;
    return GrpcHealth(
      connected: h?.connected ?? false,
      dump: h?.dump ?? false,
      receivingFrames: h?.receivingFrames ?? false,
      attempt: h?.attempt ?? 0,
      backoffSeconds: h?.backoffSeconds ?? retryMin.inSeconds,
      lastFrameAgoMicros: last == null ? null : AnalyticsLogger.instance.monoMicros - last,
      frames: h?.frames ?? 0,
      lastWindowByCanId: h?.lastWindowByCanId ?? const {},
    );
  }

  @override
  void onCanEvent(CanEvent event) {
    if (hostDisposed) return;
    switch (event) {
      case CanPublish():
        state = event.diagnostics;
        ref.read(activeFaultsProvider.notifier).set(event.faults);
        // The mock dashboard keeps its own values.
        final vehicle = ref.read(vehicleProvider.notifier);
        if (vehicle is! AidlVehicleNotifier) return;
        vehicle.applySensorUpdate(
          ambientBrightness: event.ambientBrightness,
          serviceIndicator: event.serviceIndicator,
          regenPowerLimitW: event.regenPowerLimitW,
          dischargePowerLimitW: event.dischargePowerLimitW,
          rangeEcoCan: event.rangeEcoCan,
          regenAvailability: event.regenAvailability,
          towTheftState: event.towTheftState,
          busVoltage: event.busVoltage,
          packVoltage: event.packVoltage,
          packCurrent: event.packCurrent,
          trunkClosed: event.trunkClosed,
          vehicleLockStateBcm: event.vehicleLockStateBcm,
          odometerM: event.odometerM,
          pduTemp: event.pduTemp,
          mcuTemp: event.mcuTemp,
          thermalLimits: event.thermalLimits,
          liveInputs: event.liveInputs,
        );
      case CanLost():
        ref.read(vehicleProvider.notifier).releaseCanOwnership();
      case CanHealth():
        _health = event;
      case CanFrameShapes(:final rows):
        ref.read(vehicleProvider.notifier).survey.setFrameShapes(rows);
      case CanLog(:final cat, :final evt, :final data):
        logEvent(cat, evt, data);
      case CanContext(:final key, :final value):
        if (value == null) {
          AnalyticsLogger.instance.context.remove(key);
        } else {
          AnalyticsLogger.instance.context[key] = value;
        }
      case CanBootMark(:final stage):
        bootMark(stage);
      case CanBusLogStatus() || CanRawStatus():
        super.onCanEvent(event);
    }
  }

  /// One raw frame, as if from the stream; only where the link runs here.
  @visibleForTesting
  void feedFrame(List<int> frame) {
    final host = canHost;
    if (host is InProcessCanHost) host.link.feedFrame(frame);
  }

  @visibleForTesting
  static Stream<List<int>> frames(Stream<List<int>> packets) => canFrames(packets);

  @visibleForTesting
  static Stream<List<int>> emptyRequest() => emptyCanRequest();

  @visibleForTesting
  static Future<FrameSession> openGrpc(String host, int port) => openCanSession(host, port);
}
