import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'analytics_logger.dart';
import 'can_link.dart';
import 'can_session.dart';
import 'raw_recorder.dart';

/// Where a [CanLink] runs. Its events come back through the `onEvent` the
/// host was made with.
abstract interface class CanHost {
  void send(CanCommand command);
  void dispose();
}

/// The link in the calling isolate, called directly: tests (a [FrameSource]
/// is given), the web, and the mock dashboard (no source, so no bus).
class InProcessCanHost implements CanHost {
  InProcessCanHost({FrameSource? source, required void Function(CanEvent event) onEvent})
      : link = CanLink(source: source, emit: onEvent) {
    link.start();
  }

  final CanLink link;

  @override
  void send(CanCommand command) => link.handle(command);

  @override
  void dispose() => link.dispose();
}

/// The link in one long-lived background isolate, connected to
/// `diagnostics_server` at [host]:[port]. Only plain values cross.
///
/// A worker that dies is reported as `grpc.worker_exit` and a [CanLost],
/// and a new one is started after the link's own retry backoff, with the
/// bus log, a running recording, the pause and the motor temperature put
/// back as they were.
class IsolateCanHost implements CanHost {
  IsolateCanHost({
    required this.onEvent,
    this.host = CanLink.host,
    this.port = CanLink.port,
    this.retryMin = CanLink.retryMin,
    this.retryMax = CanLink.retryMax,
  }) : _backoff = retryMin {
    _spawn();
  }

  final void Function(CanEvent event) onEvent;
  final String host;
  final int port;
  final Duration retryMin;
  final Duration retryMax;

  /// How many workers have been started.
  int spawns = 0;

  Isolate? _isolate;
  ReceivePort? _events;
  ReceivePort? _exit;
  SendPort? _commands;
  final _queued = <CanCommand>[];
  Timer? _respawn;
  Duration _backoff;
  bool _disposed = false;
  String? _error;
  CanHealth? _lastHealth;

  bool _paused = false;
  double? _motorTemp;
  int? _wallOffsetMicros;
  CanBusLogStart? _busLog;
  CanRawStart? _raw;

  @override
  void send(CanCommand command) {
    if (_disposed) return;
    switch (command) {
      case CanPause():
        _paused = true;
      case CanResume():
        _paused = false;
      case CanSetMotorTemp(:final value):
        _motorTemp = value;
      case CanBusLogStart(:final wallOffsetMicros):
        _busLog = command;
        _wallOffsetMicros = wallOffsetMicros;
      case CanBusLogStop():
        _busLog = null;
      case CanRawStart(:final wallOffsetMicros):
        _raw = command;
        _wallOffsetMicros = wallOffsetMicros;
      case CanRawStop():
        _raw = null;
      case CanUpdateWallClock(:final wallOffsetMicros):
        _wallOffsetMicros = wallOffsetMicros;
      default:
    }
    final commands = _commands;
    if (commands != null) {
      commands.send(command);
    } else if (command is! CanRawRow && command is! CanRawPoll && command is! CanUpdateWallClock) {
      // No worker yet (starting, or between two): kept for when it is ready.
      _queued.add(command);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _respawn?.cancel();
    final commands = _commands;
    if (commands != null) {
      // The worker closes its files and ends itself.
      commands.send(const CanDispose());
    } else {
      _isolate?.kill(priority: Isolate.immediate);
    }
    _closePorts();
  }

  @visibleForTesting
  void killWorkerForTest() => _isolate?.kill(priority: Isolate.immediate);

  Future<void> _spawn() async {
    _respawn = null;
    if (_disposed) return;
    spawns++;
    _error = null;
    final events = _events = ReceivePort();
    final exit = _exit = ReceivePort();
    events.listen(_onMessage);
    // One port for both, so the error is here before the exit it causes.
    exit.listen((message) {
      if (message is List) {
        _error = message.isEmpty ? 'error' : '${message.first}';
      } else {
        _onExit();
      }
    });
    try {
      final isolate = await Isolate.spawn(
        canWorkerMain,
        [events.sendPort, host, port],
        onError: exit.sendPort,
        onExit: exit.sendPort,
        debugName: 'can-worker',
      );
      if (_disposed) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _isolate = isolate;
    } catch (e) {
      _error = 'spawn failed: $e';
      _onExit();
    }
  }

  void _onMessage(Object? message) {
    if (_disposed) return;
    if (message is SendPort) {
      message.send([AnalyticsLogger.instance.monoMicros, _queued.toList()]);
      _queued.clear();
      _commands = message;
    } else if (message is CanEvent) {
      if (message is CanHealth) {
        _lastHealth = message;
        if (message.receivingFrames) _backoff = retryMin;
      }
      onEvent(message);
    }
  }

  void _onExit() {
    if (_disposed) return;
    _closePorts();
    _isolate = null;
    _commands = null;
    onEvent(CanLog('grpc', 'worker_exit', {'why': _error ?? 'exit', 'backoff_s': _backoff.inSeconds}));
    onEvent(const CanLost());
    final last = _lastHealth;
    onEvent(CanHealth(
      connected: false,
      dump: false,
      receivingFrames: false,
      attempt: last?.attempt ?? 0,
      backoffSeconds: _backoff.inSeconds,
      lastFrameMicros: last?.lastFrameMicros,
      frames: last?.frames ?? 0,
      lastWindowByCanId: last?.lastWindowByCanId ?? const {},
    ));
    final motorTemp = _motorTemp;
    final busLog = _busLog;
    final raw = _raw;
    _queued
      ..clear()
      ..addAll([
        if (motorTemp != null) CanSetMotorTemp(motorTemp),
        if (_paused) const CanPause(),
        if (busLog != null) CanBusLogStart(header: busLog.header, directoryPath: busLog.directoryPath, wallOffsetMicros: _wallOffsetMicros),
        if (raw != null) CanRawStart(header: raw.header, directoryPath: raw.directoryPath, wallOffsetMicros: _wallOffsetMicros),
      ]);
    _respawn = Timer(_backoff, _spawn);
    _backoff = _backoff * 2 > retryMax ? retryMax : _backoff * 2;
  }

  // Closing drops whatever a dead worker still had on its way here.
  void _closePorts() {
    _events?.close();
    _events = null;
    _exit?.close();
    _exit = null;
  }
}

/// The bus worker isolate. It says it is ready with the port its commands
/// go to; the first message back is `[mono, commands]`: the main isolate's
/// `mono` at that moment, so that this isolate's log clock, and with it the
/// time in every file written here, is the main log's `mono`, and what the
/// link must be told before it connects.
void canWorkerMain(List<Object?> args) {
  final out = args[0]! as SendPort;
  final host = args[1]! as String;
  final port = args[2]! as int;
  final commands = ReceivePort();
  CanLink? link;
  commands.listen((message) async {
    if (message is List) {
      final clock = Stopwatch()..start();
      final base = message[0] as int;
      AnalyticsLogger.instance.monoOverride = () => base + clock.elapsedMicroseconds;
      AnalyticsLogger.instance.listeners.add((cat, evt, data) => out.send(CanLog(cat, evt, data)));
      final l = link = CanLink(source: () => openCanSession(host, port), emit: out.send);
      for (final command in message[1] as List) {
        l.handle(command as CanCommand);
      }
      l.start();
    } else if (message is CanDispose) {
      commands.close();
      await link?.dispose();
      await RawRecorder.instance.stop();
      Isolate.exit();
    } else if (message is CanCommand) {
      link?.handle(message);
    }
  });
  out.send(commands.sendPort);
}
