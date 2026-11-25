import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/can_host.dart';
import 'package:opendash/services/can_link.dart';

/// A stand-in `diagnostics_server` in this isolate; the bus worker (a real
/// isolate, real time) connects to it over the loopback. Both streams send
/// the frames again and again until the call ends, like a live bus.
class _WifiCan extends Service {
  _WifiCan(this.frames) {
    $addMethod(ServiceMethod<List<int>, List<int>>('Init', _init, false, false, _bytes, _bytes));
    $addMethod(ServiceMethod<List<int>, List<int>>('ReadCanStream', _stream, false, true, _bytes, _bytes));
    $addMethod(ServiceMethod<List<int>, List<int>>('CanDumpStream', _stream, false, true, _bytes, _bytes));
  }

  final List<List<int>> frames;
  bool stopped = false;

  static List<int> _bytes(List<int> b) => b;

  @override
  String get $name => 'wifican.WifiCanRpc';

  Future<List<int>> _init(ServiceCall call, Future<List<int>> request) async {
    await request;
    return const [0x08, 0x01];
  }

  Stream<List<int>> _stream(ServiceCall call, Future<List<int>> request) async* {
    await request;
    while (!call.isCanceled && !stopped) {
      for (final f in frames) {
        yield [0x0a, f.length, ...f];
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

Uint8List _frame(int id, List<int> data) {
  final out = Uint8List(16);
  out[0] = (id >> 24) & 0xff;
  out[1] = (id >> 16) & 0xff;
  out[2] = (id >> 8) & 0xff;
  out[3] = id & 0xff;
  out[4] = 8;
  out.setRange(8, 8 + data.length, data);
  return out;
}

void main() {
  late Server server;
  late _WifiCan service;
  final received = <(CanEvent, int)>[];

  setUp(() async {
    AnalyticsLogger.instance.resetForTest();
    received.clear();
    service = _WifiCan([
      _frame(0x1A8, [0xf1, 0x02, 0xf5, 0x02, 0xfc, 0xd4, 0x6d, 0x1e]),
      _frame(0x150, [0x0e, 0x62, 0x60, 0x6c, 0x64, 0x64, 0, 0]),
      _frame(0x4B0, [1, 2, 3, 4, 5, 6, 7, 8]),
    ]);
    server = Server.create(services: [service]);
    await server.serve(address: '127.0.0.1', port: 0);
  });

  tearDown(() async {
    service.stopped = true;
    // A killed worker's connection is only closed when its socket is
    // collected, and a graceful shutdown would wait for that.
    await server.shutdown().timeout(const Duration(seconds: 2), onTimeout: () {});
  });

  void onEvent(CanEvent e) => received.add((e, AnalyticsLogger.instance.monoMicros));

  /// The first event of a kind that passes [test], and the main isolate's
  /// `mono` when it arrived.
  Future<(T, int)> wait<T extends CanEvent>([bool Function(T e)? test]) async {
    final give = DateTime.now().add(const Duration(seconds: 20));
    while (true) {
      for (final (e, at) in received) {
        if (e is T && (test?.call(e) ?? true)) return (e, at);
      }
      if (DateTime.now().isAfter(give)) fail('no $T in ${received.map((r) => r.$1.runtimeType).toList()}');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  bool isLog(CanLog e, String cat, String evt) => e.cat == cat && e.evt == evt;

  test('the worker reads, decodes and logs the bus, on the main log\'s clock', () async {
    final dir = await Directory.systemTemp.createTemp('can_worker');
    addTearDown(() => dir.delete(recursive: true));
    final startedAt = AnalyticsLogger.instance.monoMicros;
    final host = IsolateCanHost(host: '127.0.0.1', port: server.port!, onEvent: onEvent);
    addTearDown(host.dispose);
    host.send(const CanSetMotorTemp(41));
    host.send(CanBusLogStart(
      header: const {'version': 'test'},
      directoryPath: dir.path,
      wallOffsetMicros: DateTime.now().toUtc().microsecondsSinceEpoch - AnalyticsLogger.instance.monoMicros,
    ));

    final (publish, _) = await wait<CanPublish>((e) => e.packVoltage != null && e.diagnostics.soh != null);
    expect(publish.packVoltage, closeTo(54.524, 1e-9));
    expect(publish.busVoltage, closeTo(25.102, 1e-9));
    expect(publish.diagnostics.soh, 100);
    expect(publish.diagnostics.packVoltage, closeTo(54.524, 1e-9));
    expect(publish.diagnostics.temps.last.tempC, 41, reason: 'the motor temperature it was sent');
    expect(publish.faults, isEmpty);

    final (health, healthAt) = await wait<CanHealth>((e) => e.connected && e.receivingFrames && e.frames > 0);
    expect(health.dump, isTrue, reason: 'the bus log keeps it on the whole bus');
    expect(healthAt - health.lastFrameMicros!, inInclusiveRange(-2000, 3000000));

    final (first, _) = await wait<CanLog>((e) => isLog(e, 'grpc', 'first_frame'));
    expect(first.data['dump'], isTrue);
    expect(received.map((r) => r.$1).whereType<CanLog>().where((e) => e.cat == 'grpc').map((e) => e.evt),
        containsAllInOrder(['connect', 'init_ok', 'first_frame']));
    expect((await wait<CanBootMark>()).$1.stage, 'grpc_first_frame');
    expect((await wait<CanContext>((e) => e.value == true)).$1.key, 'grpc_dump');

    // The worker's clock is the main log's: a count it stamps now arrives now.
    received.removeWhere((r) => r.$1 is CanBusLogStatus);
    host.send(const CanUpdateWallClock(null));
    final (status, statusAt) = await wait<CanBusLogStatus>();
    expect(status.active, isTrue);
    expect(status.frames, greaterThan(0));
    // Never ahead of the main clock; behind by at most what a loaded machine
    // takes to deliver the clock to the worker and the count back.
    expect(statusAt - status.atMicros, inInclusiveRange(-2000, 2000000));
    expect(status.path!.split('/').last, matches(RegExp(r'^bus-\d{8}T\d{6}-\d+\.jsonl$')));

    host.send(CanBusLogTrigger('test', AnalyticsLogger.instance.monoMicros));
    host.send(const CanBusLogStop());
    final (burst, _) = await wait<CanLog>((e) => isLog(e, 'bus', 'burst'));
    expect(burst.data['reasons'], ['test']);
    await wait<CanLog>((e) => isLog(e, 'bus', 'stop'));
    final burstFile = File('${dir.path}/${burst.data['file']}');
    // After the clock was sent as unknown.
    expect(burst.data['file'], matches(RegExp(r'^burst-noclock-\d+-test\.jsonl$')));
    final lines = [for (final l in burstFile.readAsLinesSync()) jsonDecode(l) as Map<String, dynamic>];
    expect(lines.first['kind'], 'bus_burst');
    expect(lines.first['version'], 'test');
    expect(lines.length - 1, burst.data['frames']);
    expect(lines.skip(1).map((l) => l['f']).toSet(), {'1a8', '150', '4b0'}, reason: 'every frame, not only the ones decoded');
    final now = AnalyticsLogger.instance.monoMicros;
    expect(lines.first['log_mono_ms'], inInclusiveRange(startedAt ~/ 1000, now ~/ 1000));

    final (stopped, _) = await wait<CanBusLogStatus>((e) => !e.active);
    final busFile = File(stopped.path!);
    for (var i = 0; i < 100 && busFile.readAsLinesSync().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final header = jsonDecode(busFile.readAsLinesSync().first) as Map<String, dynamic>;
    expect(header['kind'], 'bus_log');
    expect(header['log_mono_ms'], inInclusiveRange(startedAt ~/ 1000, now ~/ 1000));
  });

  test('a worker that dies is reported, the bus values are given up, and a new one takes over', () async {
    final host = IsolateCanHost(
      host: '127.0.0.1',
      port: server.port!,
      onEvent: onEvent,
      retryMin: const Duration(milliseconds: 200),
    );
    addTearDown(host.dispose);
    host.send(const CanBusLogStart(header: {}));
    await wait<CanLog>((e) => isLog(e, 'grpc', 'first_frame'));
    expect(host.spawns, 1);

    final before = received.length;
    host.killWorkerForTest();
    final (exit, _) = await wait<CanLog>((e) => isLog(e, 'grpc', 'worker_exit'));
    expect(exit.data['backoff_s'], 0);
    final after = [for (final r in received.skip(before)) r.$1];
    final at = after.indexOf(exit);
    expect(after[at + 1], isA<CanLost>());
    expect((after[at + 2] as CanHealth).connected, isFalse);

    received.clear();
    final (again, _) = await wait<CanLog>((e) => isLog(e, 'grpc', 'first_frame'));
    expect(host.spawns, 2);
    expect(again.data['dump'], isTrue, reason: 'the bus log was put back');
    expect(received.map((r) => r.$1).whereType<CanLog>().where((e) => isLog(e, 'bus', 'start')), hasLength(1));
    await wait<CanPublish>((e) => e.packVoltage != null);
  });
}
