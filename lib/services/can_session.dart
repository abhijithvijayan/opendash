import 'dart:async';

import 'package:grpc/grpc.dart';

import 'bms_decoder.dart';
import 'wifican_codec.dart';

/// An open connection delivering raw 16-byte CAN frames.
abstract interface class FrameSession {
  /// `ReadCanStream`: the frames `Init` asked for.
  Stream<List<int>> get stream;

  /// `CanDumpStream`: every frame on the bus, for when [stream] is silent.
  Stream<List<int>> openDump();

  Future<void> close();
}

/// Opens a [FrameSession]; the real one is `diagnostics_server`.
typedef FrameSource = Future<FrameSession> Function();

/// Server-stream packets to raw 16-byte frames.
Stream<List<int>> canFrames(Stream<List<int>> packets) =>
    packets.map(decodeCanPacket).where((f) => f != null).cast<List<int>>();

/// The request stream must be typed `Stream<List<int>>`: an untyped
/// `Stream.value(const [])` infers `List<dynamic>` as the request type and
/// grpc-dart throws a serializer contravariance TypeError before the
/// request reaches the wire.
Stream<List<int>> emptyCanRequest() => Stream<List<int>>.value(const <int>[]);

/// The real `diagnostics_server` session: `Init`, then the two streams.
/// Host and port are parameters so a test can point it at an in-process
/// server; the dashboard always uses `CanLink.host`:`CanLink.port`.
Future<FrameSession> openCanSession(String host, int port) async {
  final channel = ClientChannel(
    host,
    port: port,
    options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
  );
  try {
    final client = _WifiCanClient(channel);
    final init = await client.init(BmsState.canIds);
    if (!init.ok) throw StateError('Init refused: ${init.message}');
    return _GrpcSession(channel, client);
  } catch (_) {
    await channel.shutdown();
    rethrow;
  }
}

class _GrpcSession implements FrameSession {
  _GrpcSession(this._channel, this._client);
  final ClientChannel _channel;
  final _WifiCanClient _client;

  @override
  late final Stream<List<int>> stream = canFrames(_client.readCanStream());

  @override
  Stream<List<int>> openDump() => canFrames(_client.canDumpStream());

  @override
  Future<void> close() => _channel.shutdown();
}

/// Only the three read-only RPCs the dashboard is allowed to call.
class _WifiCanClient extends Client {
  _WifiCanClient(super.channel);

  static final _init = ClientMethod<List<int>, WifiCanResponse>(
    '/wifican.WifiCanRpc/Init',
    (ids) => encodeRegister(ids),
    (bytes) => decodeResponse(bytes),
  );

  static final _readCanStream = ClientMethod<List<int>, List<int>>(
    '/wifican.WifiCanRpc/ReadCanStream',
    (_) => encodeEmpty(),
    (List<int> bytes) => bytes,
  );

  ResponseFuture<WifiCanResponse> init(List<int> canIds) =>
      $createUnaryCall(_init, canIds, options: CallOptions(timeout: const Duration(seconds: 5)));

  static final _canDumpStream = ClientMethod<List<int>, List<int>>(
    '/wifican.WifiCanRpc/CanDumpStream',
    (_) => encodeEmpty(),
    (List<int> bytes) => bytes,
  );

  ResponseStream<List<int>> readCanStream() => $createStreamingCall(_readCanStream, emptyCanRequest());

  ResponseStream<List<int>> canDumpStream() => $createStreamingCall(_canDumpStream, emptyCanRequest());
}
