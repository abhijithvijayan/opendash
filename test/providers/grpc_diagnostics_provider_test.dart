import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/battery_diagnostics.dart';
import 'package:opendash/providers/battery_diagnostics_provider.dart';
import 'package:opendash/providers/grpc_diagnostics_provider.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/bms_decoder.dart';
import 'package:opendash/services/can_link.dart';
import '../helpers/stock.dart';

Uint8List frame(int id, List<int> data) {
  final out = Uint8List(16);
  out[0] = (id >> 24) & 0xff;
  out[1] = (id >> 16) & 0xff;
  out[2] = (id >> 8) & 0xff;
  out[3] = id & 0xff;
  out[4] = data.length;
  out.setRange(8, 8 + data.length, data);
  return out;
}

List<int> le16(int v) => [v & 0xff, (v >> 8) & 0xff];

ProviderContainer harness(FrameSource source) => ProviderContainer(overrides: [
      batteryDiagnosticsProvider.overrideWith(() => GrpcDiagnosticsNotifier(source: source)),
    ]);

class _Session implements FrameSession {
  _Session(this.stream, {this.dump, this.dumpThrows = false});
  @override
  final Stream<List<int>> stream;
  final Stream<List<int>>? dump;
  final bool dumpThrows;
  int closed = 0;
  int dumpOpened = 0;
  @override
  Stream<List<int>> openDump() {
    dumpOpened++;
    if (dumpThrows) throw StateError('CanDumpStream refused');
    return dump ?? const Stream.empty();
  }

  @override
  Future<void> close() async => closed++;
}

void main() {
  test('starts empty and publishes decoded frames on a throttle', () {
    fakeAsync((async) {
      final frames = StreamController<List<int>>();
      final c = harness(() async => _Session(frames.stream));
      expect(c.read(batteryDiagnosticsProvider), const BatteryDiagnostics());
      async.flushMicrotasks();
      frames.add(frame(0x1A5, [...le16(3890), ...le16(3892), ...le16(3889), ...le16(3893)]));
      frames.add(frame(0x150, [...le16(51200), ...le16(12), 90, 96, 0, 0]));
      async.flushMicrotasks();
      expect(c.read(batteryDiagnosticsProvider).cells, isEmpty, reason: 'not before the publish tick');
      async.elapse(GrpcDiagnosticsNotifier.publishEvery);
      final d = c.read(batteryDiagnosticsProvider);
      expect(d.cells[0].voltage, closeTo(3.890, 1e-9));
      expect(d.soh, 96);
      expect(d.busVoltage, closeTo(51.2, 1e-6));
      c.dispose();
      frames.close();
    });
  });

  test('a dead server leaves the page empty and retries with backoff', () {
    fakeAsync((async) {
      var attempts = 0;
      final c = harness(() async {
        attempts++;
        throw StateError('connection refused');
      });
      c.read(batteryDiagnosticsProvider);
      async.flushMicrotasks();
      expect(attempts, 1);
      async.elapse(GrpcDiagnosticsNotifier.retryMin);
      expect(attempts, 2);
      async.elapse(GrpcDiagnosticsNotifier.retryMin);
      expect(attempts, 2, reason: 'second wait is doubled');
      async.elapse(GrpcDiagnosticsNotifier.retryMin);
      expect(attempts, 3);
      expect(c.read(batteryDiagnosticsProvider).cells, isEmpty);
      c.dispose();
      async.elapse(GrpcDiagnosticsNotifier.retryMax * 2);
      expect(attempts, 3, reason: 'no retries after dispose');
    });
  });

  test('a closed stream reconnects and keeps the last reading', () {
    fakeAsync((async) {
      var opened = 0;
      StreamController<List<int>>? frames;
      final c = harness(() async {
        opened++;
        frames = StreamController<List<int>>();
        return _Session(frames!.stream);
      });
      c.read(batteryDiagnosticsProvider);
      async.flushMicrotasks();
      frames!.add(frame(0x150, [...le16(51200), ...le16(12), 90, 96, 0, 0]));
      async.elapse(GrpcDiagnosticsNotifier.publishEvery);
      expect(c.read(batteryDiagnosticsProvider).soh, 96);
      frames!.close();
      async.flushMicrotasks();
      async.elapse(GrpcDiagnosticsNotifier.retryMin);
      expect(opened, 2);
      expect(c.read(batteryDiagnosticsProvider).soh, 96);
      c.dispose();
    });
  });

  test('CAN sensor frames reach the AIDL vehicle notifier', () {
    fakeAsync((async) {
      final frames = StreamController<List<int>>();
      final c = ProviderContainer(overrides: [
        batteryDiagnosticsProvider.overrideWith(() => GrpcDiagnosticsNotifier(source: () async => _Session(frames.stream))),
        vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: const Stream.empty(), invoke: (_, _) async => true)),
      ]);
      c.read(batteryDiagnosticsProvider);
      expect(c.read(vehicleProvider).ambientKnown, isFalse);
      async.flushMicrotasks();
      frames.add(frame(0x353, [0, 0, 0, 0, 0, 0x08, 0, 72]));
      frames.add(frame(0x140, [...le16(1200), ...le16(43000), 0, 0, 0, 0]));
      frames.add(frame(0x6F4, [...le16(46), 0, 0, 0, 0, 0, 0]));
      frames.add(frame(0x683, [0x10, 0x01, 0, 0, 0, 0, 0, 0]));
      frames.add(frame(0x150, [...le16(51200), ...le16(12), 90, 96, 0, 0]));
      async.elapse(GrpcDiagnosticsNotifier.publishEvery);
      final v = c.read(vehicleProvider);
      expect(v.ambientBrightness, 72);
      expect(v.ambientKnown, isTrue);
      expect(v.serviceIndicator, isTrue);
      expect(v.regenPowerLimitW, 1200);
      expect(v.dischargePowerLimitW, 7000);
      expect(v.rangeEcoCan, 46);
      expect(v.towTheftState, 1);
      expect(v.tamperDetected, isTrue);
      expect(v.regenAvailability, 1);
      expect(v.busVoltage, closeTo(51.2, 1e-6));
      c.dispose();
      frames.close();
    });
  });

  test('the mock vehicle is left alone by the CAN bridge', () {
    fakeAsync((async) {
      final frames = StreamController<List<int>>();
      final c = harness(() async => _Session(frames.stream));
      c.read(batteryDiagnosticsProvider);
      async.flushMicrotasks();
      frames.add(frame(0x353, [0, 0, 0, 0, 0, 0x08, 0, 72]));
      async.elapse(GrpcDiagnosticsNotifier.publishEvery);
      expect(c.read(vehicleProvider).ambientBrightness, 50);
      expect(c.read(vehicleProvider).serviceIndicator, isFalse);
      c.dispose();
      frames.close();
    });
  });

  group('CanDumpStream fallback', () {
    test('a silent ReadCanStream falls back to the filtered dump after the silence window', () {
      fakeAsync((async) {
        final silent = StreamController<List<int>>();
        final dump = StreamController<List<int>>();
        final session = _Session(silent.stream, dump: dump.stream);
        final c = harness(() async => session);
        final n = c.read(batteryDiagnosticsProvider.notifier) as GrpcDiagnosticsNotifier;
        async.flushMicrotasks();
        expect(n.usingDumpFallback, isFalse);
        async.elapse(GrpcDiagnosticsNotifier.silenceWindow - const Duration(milliseconds: 1));
        expect(n.usingDumpFallback, isFalse);
        expect(session.dumpOpened, 0);
        async.elapse(const Duration(milliseconds: 1));
        expect(n.usingDumpFallback, isTrue);
        expect(session.dumpOpened, 1);
        dump.add(frame(0x123, [...le16(1), ...le16(2), 0, 0, 0, 0]));
        dump.add(frame(0x150, [...le16(51200), ...le16(12), 90, 96, 0, 0]));
        async.elapse(GrpcDiagnosticsNotifier.publishEvery);
        expect(c.read(batteryDiagnosticsProvider).soh, 96);
        expect(session.closed, 0, reason: 'the session stays open; only the RPC changed');
        c.dispose();
        silent.close();
        dump.close();
      });
    });

    test('a stream that goes quiet after frames is torn down and reconnected (R-14)', () {
      fakeAsync((async) {
        AnalyticsLogger.instance.resetForTest();
        final frames = StreamController<List<int>>();
        final session = _Session(frames.stream, dump: const Stream.empty());
        var opened = 0;
        final c = harness(() async {
          opened++;
          return session;
        });
        c.read(batteryDiagnosticsProvider.notifier);
        async.flushMicrotasks();
        frames.add(frame(0x150, [...le16(51200), ...le16(12), 90, 96, 0, 0]));
        async.elapse(GrpcDiagnosticsNotifier.frameCountsEvery);
        expect(AnalyticsLogger.instance.recent('grpc', 'stale'), isEmpty);
        async.elapse(GrpcDiagnosticsNotifier.frameCountsEvery);
        expect(AnalyticsLogger.instance.recent('grpc', 'stale'), hasLength(1));
        expect(session.closed, 1);
        async.elapse(GrpcDiagnosticsNotifier.retryMin);
        expect(opened, 2);
        c.dispose();
        frames.close();
      });
    });

    test('a frame inside the window keeps ReadCanStream', () {
      fakeAsync((async) {
        final frames = StreamController<List<int>>();
        final session = _Session(frames.stream, dump: const Stream.empty());
        final c = harness(() async => session);
        final n = c.read(batteryDiagnosticsProvider.notifier) as GrpcDiagnosticsNotifier;
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        frames.add(frame(0x150, [...le16(51200), ...le16(12), 90, 96, 0, 0]));
        async.elapse(GrpcDiagnosticsNotifier.silenceWindow * 3);
        expect(n.usingDumpFallback, isFalse);
        expect(session.dumpOpened, 0);
        c.dispose();
        frames.close();
      });
    });

    test('the dump filter keeps only the ids the decoder reads', () {
      expect(BmsState.wants(frame(0x150, [0, 0, 0, 0, 0, 0, 0, 0])), isTrue);
      expect(BmsState.wants(frame(0x683, [0, 0, 0, 0, 0, 0, 0, 0])), isTrue);
      expect(BmsState.wants(frame(0x123, [0, 0, 0, 0, 0, 0, 0, 0])), isFalse);
      expect(BmsState.wants(frame(0x6BC, [0, 0, 0, 0, 0, 0, 0, 0])), isFalse);
      expect(BmsState.wants(const [0x00, 0x00]), isFalse, reason: 'a truncated frame is dropped');
    });

    test('a refused dump tears the session down and rejoins the retry loop', () {
      fakeAsync((async) {
        final sessions = <_Session>[];
        final c = harness(() async {
          final s = _Session(StreamController<List<int>>().stream, dumpThrows: sessions.isEmpty);
          sessions.add(s);
          return s;
        });
        final n = c.read(batteryDiagnosticsProvider.notifier) as GrpcDiagnosticsNotifier;
        async.flushMicrotasks();
        async.elapse(GrpcDiagnosticsNotifier.silenceWindow);
        expect(sessions.single.dumpOpened, 1);
        expect(n.usingDumpFallback, isFalse);
        expect(sessions.single.closed, 1, reason: 'the half-switched session is closed, not left dangling');
        async.elapse(GrpcDiagnosticsNotifier.retryMin);
        expect(sessions.length, 2, reason: 'the normal backoff reconnect runs');
        async.elapse(GrpcDiagnosticsNotifier.silenceWindow);
        expect(n.usingDumpFallback, isTrue, reason: 'the next session can still fall back');
        c.dispose();
      });
    });

    test('ReadCanStream closing before any frame falls back to the dump', () {
      fakeAsync((async) {
        final silent = StreamController<List<int>>();
        final dump = StreamController<List<int>>();
        final session = _Session(silent.stream, dump: dump.stream);
        final c = harness(() async => session);
        final n = c.read(batteryDiagnosticsProvider.notifier) as GrpcDiagnosticsNotifier;
        async.flushMicrotasks();
        silent.close();
        async.flushMicrotasks();
        expect(session.dumpOpened, 1);
        expect(n.usingDumpFallback, isTrue);
        expect(session.closed, 0, reason: 'the session stays open; only the RPC changed');
        dump.add(frame(0x150, [...le16(51200), ...le16(12), 90, 96, 0, 0]));
        async.elapse(GrpcDiagnosticsNotifier.publishEvery);
        expect(c.read(batteryDiagnosticsProvider).soh, 96);
        c.dispose();
        dump.close();
      });
    });

    test('a frame on ReadCanStream before a close keeps us on the primary stream', () {
      fakeAsync((async) {
        final frames = StreamController<List<int>>();
        final session = _Session(frames.stream, dump: const Stream.empty());
        final c = harness(() async => session);
        final n = c.read(batteryDiagnosticsProvider.notifier) as GrpcDiagnosticsNotifier;
        async.flushMicrotasks();
        frames.add(frame(0x150, [...le16(51200), ...le16(12), 90, 96, 0, 0]));
        async.elapse(const Duration(milliseconds: 100));
        frames.close();
        async.flushMicrotasks();
        expect(n.usingDumpFallback, isFalse);
        expect(session.dumpOpened, 0, reason: 'a close after real frames is a reconnect, not a fallback');
        c.dispose();
      });
    });

    test('a reconnect starts again on ReadCanStream', () {
      fakeAsync((async) {
        final sessions = <_Session>[];
        StreamController<List<int>>? dump;
        final c = harness(() async {
          dump = StreamController<List<int>>();
          final s = _Session(StreamController<List<int>>().stream, dump: dump!.stream);
          sessions.add(s);
          return s;
        });
        final n = c.read(batteryDiagnosticsProvider.notifier) as GrpcDiagnosticsNotifier;
        async.flushMicrotasks();
        async.elapse(GrpcDiagnosticsNotifier.silenceWindow);
        expect(n.usingDumpFallback, isTrue);
        dump!.close();
        async.flushMicrotasks();
        expect(sessions.single.closed, 1, reason: 'a dead dump stream tears the session down');
        async.elapse(GrpcDiagnosticsNotifier.retryMin);
        expect(sessions.length, 2);
        expect(n.usingDumpFallback, isFalse);
        c.dispose();
      });
    });
  });

  group('dump is a stopgap (G-7)', () {
    setUp(AnalyticsLogger.instance.resetForTest);

    test('a dump with no frames is given up and the retry starts on ReadCanStream', () {
      fakeAsync((async) {
        final sessions = <_Session>[];
        final c = harness(() async {
          final s = _Session(StreamController<List<int>>().stream, dump: StreamController<List<int>>().stream);
          sessions.add(s);
          return s;
        });
        final n = c.read(batteryDiagnosticsProvider.notifier) as GrpcDiagnosticsNotifier;
        async.flushMicrotasks();
        async.elapse(GrpcDiagnosticsNotifier.silenceWindow);
        expect(n.usingDumpFallback, isTrue);
        async.elapse(GrpcDiagnosticsNotifier.dumpSilenceWindow - const Duration(milliseconds: 1));
        expect(sessions.single.closed, 0);
        async.elapse(const Duration(milliseconds: 1));
        expect(AnalyticsLogger.instance.recent('grpc', 'dump_silent'), hasLength(1));
        expect(sessions.single.closed, 1);
        async.elapse(GrpcDiagnosticsNotifier.retryMin);
        expect(sessions, hasLength(2));
        expect(n.usingDumpFallback, isFalse);
        c.dispose();
      });
    });

    test('a working dump is left for ReadCanStream after the recheck interval, which doubles', () {
      fakeAsync((async) {
        final sessions = <_Session>[];
        final dumps = <StreamController<List<int>>>[];
        final c = harness(() async {
          dumps.add(StreamController<List<int>>());
          final s = _Session(StreamController<List<int>>().stream, dump: dumps.last.stream);
          sessions.add(s);
          return s;
        });
        final n = c.read(batteryDiagnosticsProvider.notifier) as GrpcDiagnosticsNotifier;
        void feedFor(Duration d) {
          for (var t = Duration.zero; t < d; t += const Duration(seconds: 1)) {
            dumps.last.add(frame(0x150, [...le16(51200), ...le16(12), 90, 96, 0, 0]));
            async.elapse(const Duration(seconds: 1));
          }
        }

        async.flushMicrotasks();
        async.elapse(GrpcDiagnosticsNotifier.silenceWindow);
        expect(n.usingDumpFallback, isTrue);
        feedFor(GrpcDiagnosticsNotifier.dumpRecheckMin);
        expect(sessions, hasLength(2), reason: 'a new session, straight away, on ReadCanStream');
        expect(sessions.first.closed, 1);
        expect(n.usingDumpFallback, isFalse);
        expect(AnalyticsLogger.instance.recent('grpc', 'lost'), isEmpty, reason: 'a recheck is not a loss');
        expect((AnalyticsLogger.instance.recent('grpc', 'dump_recheck').single['data'] as Map)['after_s'], 60);

        // ReadCanStream is silent again: back on the dump, next recheck twice as far out.
        async.elapse(GrpcDiagnosticsNotifier.silenceWindow);
        expect(n.usingDumpFallback, isTrue);
        feedFor(GrpcDiagnosticsNotifier.dumpRecheckMin);
        expect(sessions, hasLength(2));
        feedFor(GrpcDiagnosticsNotifier.dumpRecheckMin);
        expect(sessions, hasLength(3));
        expect((AnalyticsLogger.instance.recent('grpc', 'dump_recheck').last['data'] as Map)['after_s'], 120);
        c.dispose();
      });
    });

    test('a frame on ReadCanStream resets the recheck interval', () {
      fakeAsync((async) {
        final primaries = <StreamController<List<int>>>[];
        final dumps = <StreamController<List<int>>>[];
        final c = harness(() async {
          primaries.add(StreamController<List<int>>());
          dumps.add(StreamController<List<int>>());
          return _Session(primaries.last.stream, dump: dumps.last.stream);
        });
        final n = c.read(batteryDiagnosticsProvider.notifier) as GrpcDiagnosticsNotifier;
        async.flushMicrotasks();
        async.elapse(GrpcDiagnosticsNotifier.silenceWindow);
        for (var i = 0; i < 60; i++) {
          dumps.last.add(frame(0x150, [...le16(51200), ...le16(12), 90, 96, 0, 0]));
          async.elapse(const Duration(seconds: 1));
        }
        expect(primaries, hasLength(2));
        primaries.last.add(frame(0x150, [...le16(51200), ...le16(12), 90, 96, 0, 0]));
        async.flushMicrotasks();
        expect(n.usingDumpFallback, isFalse);
        primaries.last.close();
        async.flushMicrotasks();
        async.elapse(GrpcDiagnosticsNotifier.retryMin + GrpcDiagnosticsNotifier.silenceWindow);
        expect(n.usingDumpFallback, isTrue);
        for (var i = 0; i < 60; i++) {
          dumps.last.add(frame(0x150, [...le16(51200), ...le16(12), 90, 96, 0, 0]));
          async.elapse(const Duration(seconds: 1));
        }
        expect((AnalyticsLogger.instance.recent('grpc', 'dump_recheck').last['data'] as Map)['after_s'], 60);
        c.dispose();
      });
    });
  });

  group('app lifecycle (G-8)', () {
    setUp(AnalyticsLogger.instance.resetForTest);

    test('pause closes the session without a retry; resume reconnects', () {
      fakeAsync((async) {
        final sessions = <_Session>[];
        final streams = <StreamController<List<int>>>[];
        final c = harness(() async {
          streams.add(StreamController<List<int>>());
          final s = _Session(streams.last.stream);
          sessions.add(s);
          return s;
        });
        final n = c.read(batteryDiagnosticsProvider.notifier) as GrpcDiagnosticsNotifier;
        async.flushMicrotasks();
        streams.last.add(frame(0x150, [...le16(51200), ...le16(12), 90, 96, 0, 0]));
        async.elapse(GrpcDiagnosticsNotifier.publishEvery);
        n.onLifecyclePause();
        n.onLifecyclePause();
        expect(sessions.single.closed, 1);
        expect(streams.single.hasListener, isFalse);
        async.elapse(const Duration(minutes: 5));
        expect(sessions, hasLength(1), reason: 'no stale watchdog, no retry while paused');
        expect(AnalyticsLogger.instance.recent('grpc', 'lost'), isEmpty);
        expect(AnalyticsLogger.instance.recent('grpc', 'stale'), isEmpty);
        expect(AnalyticsLogger.instance.recent('grpc', 'paused'), hasLength(1));
        expect(c.read(batteryDiagnosticsProvider).soh, 96, reason: 'the page keeps its last reading');
        n.onLifecycleResume();
        async.flushMicrotasks();
        expect(sessions, hasLength(2));
        expect(streams.last.hasListener, isTrue);
        c.dispose();
      });
    });

    test('a connect that lands after the pause is closed again', () {
      fakeAsync((async) {
        final opening = Completer<FrameSession>();
        final session = _Session(const Stream.empty());
        final c = harness(() => opening.future);
        final n = c.read(batteryDiagnosticsProvider.notifier) as GrpcDiagnosticsNotifier;
        async.flushMicrotasks();
        n.onLifecyclePause();
        opening.complete(session);
        async.flushMicrotasks();
        expect(session.closed, 1);
        expect(n.health.connected, isFalse);
        c.dispose();
      });
    });
  });

  group('stream loss (G-3)', () {
    setUp(AnalyticsLogger.instance.resetForTest);

    test('CAN-only vehicle values are cleared and HHMIS owns regen again', () {
      fakeAsync((async) {
        final streams = <StreamController<List<int>>>[];
        final c = ProviderContainer(overrides: [
          batteryDiagnosticsProvider.overrideWith(() => GrpcDiagnosticsNotifier(source: () async {
                streams.add(StreamController<List<int>>());
                return _Session(streams.last.stream);
              })),
          vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: const Stream.empty(), invoke: (_, _) async => true)),
        ]);
        final vehicle = c.read(vehicleProvider.notifier) as AidlVehicleNotifier;
        c.read(batteryDiagnosticsProvider);
        async.flushMicrotasks();
        vehicle.onEvent({'BOOL_VEHICLE_REGEN_AVAIL_STATUS': true});
        streams.last.add(frame(0x353, [0, 0, 0, 0, 0, 0, 0, 72]));
        streams.last.add(frame(0x140, [...le16(1200), ...le16(43000), ...le16(30000), 0, 0]));
        streams.last.add(frame(0x683, [0, 0x00, 0, 0, 0, 0, 0, 0]));
        streams.last.add(frame(0x1A8, [0, 0, 0, 0, ...le16(55280), 0, 0]));
        async.elapse(GrpcDiagnosticsNotifier.publishEvery);
        vehicle.onEvent({'BOOL_VEHICLE_REGEN_AVAIL_STATUS': true});
        var v = c.read(vehicleProvider);
        expect(v.regenAvailability, 0, reason: 'the CAN nibble owns it while the stream is up');
        expect(v.packVoltage, closeTo(55.28, 1e-6));
        expect(v.dischargePowerLimitW, 7000);

        streams.last.close();
        async.flushMicrotasks();
        v = c.read(vehicleProvider);
        expect(v.ambientKnown, isFalse);
        expect(v.regenPowerLimitW, 0);
        expect(v.dischargePowerLimitW, 0);
        expect(v.packVoltage, 0);
        expect(v.regenAvailabilityKnown, isTrue);
        expect(v.regenAvailability, 1, reason: "HHMIS's last flag is re-applied");
        expect(AnalyticsLogger.instance.recent('grpc', 'can_values_cleared'), hasLength(1));
        vehicle.onEvent({'BOOL_VEHICLE_REGEN_AVAIL_STATUS': false});
        expect(c.read(vehicleProvider).regenAvailability, 0, reason: 'HHMIS writes it again');

        // The next session must not republish what the old one last saw.
        async.elapse(GrpcDiagnosticsNotifier.retryMin);
        expect(streams, hasLength(2));
        streams.last.add(frame(0x353, [0, 0, 0, 0, 0, 0, 0, 40]));
        async.elapse(GrpcDiagnosticsNotifier.publishEvery);
        v = c.read(vehicleProvider);
        expect(v.ambientBrightness, 40);
        expect(v.ambientKnown, isTrue);
        expect(v.packVoltage, 0, reason: 'no 0x1A8 yet on this session');
        expect(v.regenAvailability, 0, reason: 'no 0x683 yet, so HHMIS still owns it');
        c.dispose();
      });
    });

    test('failed retries after the loss clear nothing more', () {
      fakeAsync((async) {
        var fail = false;
        final frames = StreamController<List<int>>();
        final c = ProviderContainer(overrides: [
          batteryDiagnosticsProvider.overrideWith(() => GrpcDiagnosticsNotifier(source: () async {
                if (fail) throw StateError('down');
                return _Session(frames.stream);
              })),
          vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: const Stream.empty(), invoke: (_, _) async => true)),
        ]);
        c.read(batteryDiagnosticsProvider);
        async.flushMicrotasks();
        frames.add(frame(0x353, [0, 0, 0, 0, 0, 0, 0, 72]));
        async.elapse(GrpcDiagnosticsNotifier.publishEvery);
        fail = true;
        frames.close();
        async.elapse(const Duration(minutes: 3));
        expect(AnalyticsLogger.instance.recent('grpc', 'lost').length, greaterThan(2));
        expect(AnalyticsLogger.instance.recent('grpc', 'can_values_cleared'), hasLength(1));
        c.dispose();
      });
    });
  });

  test('the session is closed on stream error and on dispose', () {
    fakeAsync((async) {
      final sessions = <_Session>[];
      StreamController<List<int>>? frames;
      final c = harness(() async {
        frames = StreamController<List<int>>();
        final s = _Session(frames!.stream);
        sessions.add(s);
        return s;
      });
      c.read(batteryDiagnosticsProvider);
      async.flushMicrotasks();
      frames!.addError(StateError('reset by peer'));
      async.flushMicrotasks();
      expect(sessions.single.closed, 1);
      async.elapse(GrpcDiagnosticsNotifier.retryMin);
      expect(sessions.length, 2);
      c.dispose();
      async.flushMicrotasks();
      expect(sessions[1].closed, 1);
    });
  });

  group('request typing', () {
    test('the request stream is typed List<int>, which an untyped Stream.value(const []) is not', () {
      expect(GrpcDiagnosticsNotifier.emptyRequest(), isA<Stream<List<int>>>());
      expect(Stream.value(const []), isNot(isA<Stream<List<int>>>()),
          reason: 'what HEAD sent; grpc-dart then throws on the request serializer');
    });

    test('the frame mapper takes and yields typed frames', () async {
      expect(GrpcDiagnosticsNotifier.frames, isA<Stream<List<int>> Function(Stream<List<int>>)>());
    });
  });

  group('backoff', () {
    setUp(AnalyticsLogger.instance.resetForTest);
    tearDown(AnalyticsLogger.instance.resetForTest);

    List<int> lostBackoffs() =>
        [for (final e in AnalyticsLogger.instance.recent('grpc', 'lost')) (e['data']! as Map)['backoff_s'] as int];

    test('a successful Init does not reset the backoff; the first frame does', () {
      fakeAsync((async) {
        StreamController<List<int>>? frames;
        var deliver = false;
        final c = harness(() async {
          frames = StreamController<List<int>>();
          if (deliver) scheduleMicrotask(() => frames!.add(frame(0x150, [...le16(51200), ...le16(12), 90, 96, 0, 0])));
          return _Session(frames!.stream);
        });
        c.read(batteryDiagnosticsProvider);
        var wait = GrpcDiagnosticsNotifier.retryMin;
        for (var i = 0; i < 3; i++) {
          if (i > 0) async.elapse(wait);
          if (i > 0) wait *= 2;
          async.flushMicrotasks();
          frames!.close();
          async.flushMicrotasks();
        }
        expect(lostBackoffs(), [10, 20, 40], reason: 'Init succeeded every time, the streams never delivered');
        expect(AnalyticsLogger.instance.recent('grpc', 'backoff_reset'), isEmpty);
        deliver = true;
        async.elapse(const Duration(seconds: 40));
        expect(AnalyticsLogger.instance.recent('grpc', 'backoff_reset'), hasLength(1));
        frames!.close();
        async.flushMicrotasks();
        expect(lostBackoffs().last, 10);
        c.dispose();
      });
    });
  });

  group('a dump that goes silent is reconnected fast (the ~30s server cut)', () {
    setUp(AnalyticsLogger.instance.resetForTest);
    tearDown(AnalyticsLogger.instance.resetForTest);
    // A fresh primary per connect: a reconnect opens a new Init session, and a
    // single-subscription stream cannot be listened to twice.
    ProviderContainer dumpHarness(List<_Session> sessions, List<StreamController<List<int>>> primaries, StreamController<List<int>> dump) {
      final c = harness(() async {
        final p = StreamController<List<int>>();
        primaries.add(p);
        final s = _Session(p.stream, dump: dump.stream);
        sessions.add(s);
        return s;
      });
      c.read(batteryDiagnosticsProvider);
      return c;
    }

    test('a stalled dump reconnects on a fresh session at once, no clear/backoff', () {
      fakeAsync((async) {
        AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
        final primaries = <StreamController<List<int>>>[];
        final dump = StreamController<List<int>>.broadcast();
        final sessions = <_Session>[];
        final c = dumpHarness(sessions, primaries, dump);
        async.flushMicrotasks();
        // A bus tap moves the session to the filter-less CanDumpStream.
        c.read(batteryDiagnosticsProvider.notifier).send(const CanBusLogStart(header: {}));
        async.flushMicrotasks();
        expect(sessions, hasLength(1));
        // A frame lands, then the dump goes silent (server stops, no close).
        dump.add(frame(0x1A5, List.filled(8, 1)));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        expect(sessions, hasLength(1), reason: 'a 1s quiet is not a stall');
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(sessions.length, greaterThanOrEqualTo(2), reason: 'a fresh session, not a dead-stream reopen');
        expect(AnalyticsLogger.instance.recent('grpc', 'dump_restart'), isNotEmpty);
        expect(AnalyticsLogger.instance.recent('grpc', 'lost'), isEmpty, reason: 'values kept, no backoff');
        // Frames on the reconnected dump recover it; no further restarts.
        dump.add(frame(0x1A5, List.filled(8, 1)));
        async.flushMicrotasks();
        final n = sessions.length;
        async.elapse(const Duration(seconds: 2));
        expect(sessions.length, n, reason: 'a recovered dump is not restarted');
        c.dispose();
        for (final p in primaries) {
          p.close();
        }
        dump.close();
      });
    });

    test('a reconnect that stays silent falls back to the ordinary backoff', () {
      fakeAsync((async) {
        AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
        final primaries = <StreamController<List<int>>>[];
        final dump = StreamController<List<int>>.broadcast();
        final sessions = <_Session>[];
        final c = dumpHarness(sessions, primaries, dump);
        async.flushMicrotasks();
        c.read(batteryDiagnosticsProvider.notifier).send(const CanBusLogStart(header: {}));
        async.flushMicrotasks();
        dump.add(frame(0x1A5, List.filled(8, 1)));
        async.flushMicrotasks();
        // The dump stalls, we reconnect fast, and the new session is silent too
        // (a genuine outage): the dump-silence window then hands it to backoff.
        async.elapse(GrpcDiagnosticsNotifier.dumpSilenceWindow + const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(AnalyticsLogger.instance.recent('grpc', 'dump_restart'), isNotEmpty);
        final lost = AnalyticsLogger.instance.recent('grpc', 'lost');
        expect(lost, isNotEmpty, reason: 'a persistently silent dump still backs off');
        c.dispose();
        for (final p in primaries) {
          p.close();
        }
        dump.close();
      });
    });
  });
}
