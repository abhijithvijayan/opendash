import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:opendash/providers/grpc_diagnostics_provider.dart';
import 'package:opendash/services/bms_decoder.dart';

/// A stand-in `diagnostics_server` speaking the same wire format, so the
/// real client (channel, ClientMethod serializers, request stream typing)
/// is exercised end to end. An untyped request stream shipped twice
/// because only a fake FrameSession was ever tested.
class _WifiCan extends Service {
  _WifiCan(this.frames) {
    $addMethod(ServiceMethod<List<int>, List<int>>('Init', _init, false, false, _bytes, _bytes));
    $addMethod(ServiceMethod<List<int>, List<int>>('ReadCanStream', _stream, false, true, _bytes, _bytes));
    $addMethod(ServiceMethod<List<int>, List<int>>('CanDumpStream', _stream, false, true, _bytes, _bytes));
  }

  final List<List<int>> frames;
  final initRequests = <List<int>>[];
  final streamRequests = <List<int>>[];

  static List<int> _bytes(List<int> b) => b;

  @override
  String get $name => 'wifican.WifiCanRpc';

  /// `Response{status: RESP_SUCCESS}`.
  Future<List<int>> _init(ServiceCall call, Future<List<int>> request) async {
    initRequests.add(await request);
    return const [0x08, 0x01];
  }

  Stream<List<int>> _stream(ServiceCall call, Future<List<int>> request) async* {
    streamRequests.add(await request);
    for (final f in frames) {
      yield [0x0a, f.length, ...f];
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

  setUp(() async {
    service = _WifiCan([
      _frame(0x1A8, [0xf1, 0x02, 0xf5, 0x02, 0xfc, 0xd4, 0x6d, 0x1e]),
      _frame(0x150, [0x0e, 0x62, 0x60, 0x6c, 0x64, 0x64, 0, 0]),
    ]);
    server = Server.create(services: [service]);
    await server.serve(address: '127.0.0.1', port: 0);
  });

  tearDown(() => server.shutdown());

  test('Init sends the BMS id filter and ReadCanStream delivers raw frames', () async {
    final session = await GrpcDiagnosticsNotifier.openGrpc('127.0.0.1', server.port!);
    addTearDown(session.close);
    final frames = await session.stream.toList().timeout(const Duration(seconds: 5));
    expect(frames, hasLength(2));
    expect(frames.first, _frame(0x1A8, [0xf1, 0x02, 0xf5, 0x02, 0xfc, 0xd4, 0x6d, 0x1e]));
    expect(service.initRequests.single, isNotEmpty, reason: 'the packed can_ids');
    expect(service.streamRequests.single, isEmpty, reason: 'google.protobuf.Empty');
    final bms = BmsState();
    for (final f in frames) {
      bms.feed(Uint8List.fromList(f));
    }
    expect(bms.packVoltage, closeTo(54.524, 1e-9));
  });

  test('CanDumpStream goes through the same typed request path', () async {
    final session = await GrpcDiagnosticsNotifier.openGrpc('127.0.0.1', server.port!);
    addTearDown(session.close);
    final frames = await session.openDump().toList().timeout(const Duration(seconds: 5));
    expect(frames, hasLength(2));
  });

  test('an unreachable server fails Init rather than hanging', () async {
    final port = server.port!;
    await server.shutdown();
    await expectLater(GrpcDiagnosticsNotifier.openGrpc('127.0.0.1', port), throwsA(isA<GrpcError>()));
  });
}
