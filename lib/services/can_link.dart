import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/battery_diagnostics.dart';
import '../models/vehicle_data.dart' show LiveInputs, ThermalLimits;
import 'analytics_logger.dart';
import 'bms_decoder.dart';
import 'bus_log.dart';
import 'can_session.dart';
import 'fault_catalog.dart';
import 'raw_recorder.dart';
import 'scooter_survey.dart';

/// What the owner of a [CanLink] may ask of it. Plain values only: a
/// command crosses to the bus worker isolate (`IsolateCanHost`).
sealed class CanCommand {
  const CanCommand();
}

class CanPause extends CanCommand {
  const CanPause();
}

class CanResume extends CanCommand {
  const CanResume();
}

class CanReconnectNow extends CanCommand {
  const CanReconnectNow();
}

class CanSetMotorTemp extends CanCommand {
  const CanSetMotorTemp(this.value);
  final double value;
}

/// [wallOffsetMicros]: the trusted wall clock minus the log's `mono`, null
/// while the clock cannot be right; file names are stamped from it.
class CanBusLogStart extends CanCommand {
  const CanBusLogStart({required this.header, this.directoryPath, this.wallOffsetMicros});
  final Map<String, Object?> header;
  final String? directoryPath;
  final int? wallOffsetMicros;
}

class CanBusLogStop extends CanCommand {
  const CanBusLogStop({this.log = true});
  final bool log;
}

class CanBusLogTrigger extends CanCommand {
  const CanBusLogTrigger(this.reason, this.atMicros);
  final String reason;
  final int atMicros;
}

class CanRawStart extends CanCommand {
  const CanRawStart({required this.header, this.directoryPath, this.wallOffsetMicros});
  final Map<String, Object?> header;
  final String? directoryPath;
  final int? wallOffsetMicros;
}

/// One batch from the stock service, already through the survey's privacy
/// rule (`RawRecorder.batchRow`), and the `mono` it arrived at.
class CanRawRow extends CanCommand {
  const CanRawRow(this.row, this.atMicros);
  final String row;
  final int atMicros;
}

class CanRawStop extends CanCommand {
  const CanRawStop(this.reason);
  final String reason;
}

/// Asks for a [CanRawStatus].
class CanRawPoll extends CanCommand {
  const CanRawPoll();
}

/// The wall-clock offset as it is now; answered with a [CanBusLogStatus].
class CanUpdateWallClock extends CanCommand {
  const CanUpdateWallClock(this.wallOffsetMicros);
  final int? wallOffsetMicros;
}

class CanDispose extends CanCommand {
  const CanDispose();
}

/// What a [CanLink] tells its owner. Plain values only, as for [CanCommand].
sealed class CanEvent {
  const CanEvent();
}

/// The decoded pack, twice a second while frames arrive, with what the
/// vehicle state takes from the bus (`AidlVehicleNotifier.applySensorUpdate`).
class CanPublish extends CanEvent {
  const CanPublish({
    required this.diagnostics,
    required this.faults,
    required this.ambientBrightness,
    required this.serviceIndicator,
    required this.regenPowerLimitW,
    required this.dischargePowerLimitW,
    required this.rangeEcoCan,
    required this.regenAvailability,
    required this.towTheftState,
    required this.busVoltage,
    required this.packVoltage,
    required this.packCurrent,
    required this.trunkClosed,
    required this.vehicleLockStateBcm,
    required this.odometerM,
    required this.pduTemp,
    required this.mcuTemp,
    required this.thermalLimits,
    required this.liveInputs,
  });

  final BatteryDiagnostics diagnostics;
  final List<ActiveFault> faults;
  final int? ambientBrightness;
  final bool? serviceIndicator;
  final int? regenPowerLimitW;
  final int? dischargePowerLimitW;
  final int? rangeEcoCan;
  final int? regenAvailability;
  final int? towTheftState;
  final double? busVoltage;
  final double? packVoltage;
  final double? packCurrent;
  final bool? trunkClosed;
  final int? vehicleLockStateBcm;
  final int? odometerM;
  final double? pduTemp;
  final double? mcuTemp;
  final ThermalLimits? thermalLimits;
  final LiveInputs? liveInputs;
}

/// The stream is gone: the bridged values are no longer readings.
class CanLost extends CanEvent {
  const CanLost();
}

/// [lastFrameMicros] is on the log's `mono`, so its age is worked out where
/// it is shown.
class CanHealth extends CanEvent {
  const CanHealth({
    required this.connected,
    required this.dump,
    required this.receivingFrames,
    required this.attempt,
    required this.backoffSeconds,
    required this.lastFrameMicros,
    required this.frames,
    required this.lastWindowByCanId,
  });

  final bool connected;
  final bool dump;
  final bool receivingFrames;
  final int attempt;
  final int backoffSeconds;
  final int? lastFrameMicros;
  final int frames;
  final Map<String, int> lastWindowByCanId;
}

/// [atMicros]: the `mono` the counts were read at.
class CanBusLogStatus extends CanEvent {
  const CanBusLogStatus({this.active = false, this.frames = 0, this.changed = 0, this.bursts = 0, this.path, this.atMicros = 0});
  final bool active;
  final int frames;
  final int changed;
  final int bursts;
  final String? path;
  final int atMicros;
}

class CanRawStatus extends CanEvent {
  const CanRawStatus({this.active = false, this.frames = 0, this.batches = 0, this.full = false, this.path});
  final bool active;
  final int frames;
  final int batches;
  final bool full;
  final String? path;
}

/// The survey's frame shapes by id (`ScooterSurvey.setFrameShapes`).
class CanFrameShapes extends CanEvent {
  const CanFrameShapes(this.rows);
  final Map<int, String> rows;
}

/// An event the bus worker logged, to be logged again where the file is.
class CanLog extends CanEvent {
  const CanLog(this.cat, this.evt, this.data);
  final String cat;
  final String evt;
  final Map<String, Object?> data;
}

/// A value for `AnalyticsLogger.context`; null removes it.
class CanContext extends CanEvent {
  const CanContext(this.key, this.value);
  final String key;
  final Object? value;
}

class CanBootMark extends CanEvent {
  const CanBootMark(this.stage);
  final String stage;
}

/// BMS cell data from `diagnostics_server` (gRPC on localhost:50005),
/// read-only: `Init` with the BMS id filter, then `ReadCanStream`. On the
/// test unit `ReadCanStream` stayed silent after a successful `Init`, so
/// if nothing arrives within [silenceWindow] the session switches to the
/// filter-less `CanDumpStream` (what community tools and the Ola diagnostics app
/// use) with the id filter applied here. The dump is a stopgap: a dump with
/// no frames for [dumpSilenceWindow] is treated as lost, and one that does
/// deliver is dropped for a fresh `ReadCanStream` attempt after
/// [dumpRecheckMin] (doubling to [dumpRecheckMax] while the filtered stream
/// stays silent). While the server is unreachable the page keeps its last
/// reading and the values bridged to the vehicle state are cleared;
/// reconnects back off from [retryMin] to [retryMax] and start again on
/// `ReadCanStream`. The session is closed while the app is paused.
///
/// The whole of it runs wherever this object lives: on the scooter a
/// background isolate (`IsolateCanHost`), so that some 900 frames a second
/// are read, decoded and logged off the thread that draws. It also hosts
/// what reads the whole bus, the bus log ([BusLog]) and a raw recording
/// ([RawRecorder]): while either runs the session stays on the dump and
/// every frame is handed to them before the id filter. Its owner sees
/// [CanEvent]s and sends [CanCommand]s, nothing else. Without a [FrameSource]
/// (the mock dashboard) there is no bus and it only keeps the recorders.
// TODO(can-stream): the dump fallback is a stopgap. Why ReadCanStream stays silent after a good Init on this unit
// has never been found; grpc.silence_fallback and grpc.dump_recheck in a log say how often it still happens.
class CanLink {
  CanLink({FrameSource? source, required this.emit}) : _open = source;

  static const host = '127.0.0.1';
  static const port = 50005;
  static const publishEvery = Duration(milliseconds: 500);
  static const retryMin = Duration(seconds: 10);
  static const retryMax = Duration(seconds: 60);
  static const silenceWindow = Duration(seconds: 5);
  static const frameCountsEvery = Duration(seconds: 10);
  static const dumpSilenceWindow = Duration(seconds: 30);
  static const dumpRecheckMin = Duration(seconds: 60);
  static const dumpRecheckMax = Duration(minutes: 10);

  /// The server stops a working dump without closing it, per session: once
  /// ~30 s in, and 17.8-18.0 s after each connect on a Gen 1 / 5.0.2 unit
  /// (2026-11-26), where waiting 2.5 s to notice lost ~3 s of every 21 s,
  /// a side-stand command among them. A whole-bus dump silent for
  /// [dumpStallWindow] is that cut, not a quiet bus (no gap between frames
  /// passed 300 ms there), so we reconnect at once on a FRESH session
  /// (reopening the dump on the same session delivers nothing), keeping the
  /// bridged values and skipping the backoff. A reconnect that stays silent
  /// is caught by the ordinary [dumpSilenceWindow] -> backoff.
  static const dumpStallWindow = Duration(seconds: 1);
  static const dumpStallCheck = Duration(milliseconds: 250);

  /// A flowing dump is moved to a fresh session this long after it opened,
  /// ahead of the cut: a reconnect costs ~50 ms of frames, the cut ~1 s more.
  static const dumpRotateAfter = Duration(seconds: 15);

  final FrameSource? _open;
  final void Function(CanEvent event) emit;
  final _bms = BmsState();
  final _shapes = ScooterSurvey();

  bool _started = false;
  bool _busLog = false;
  bool _raw = false;
  int? _wallOffsetMicros;

  FrameSession? _session;
  StreamSubscription<List<int>>? _sub;
  Timer? _retry;
  Timer? _publishTimer;
  Timer? _silence;
  Timer? _dumpRecheckTimer;
  Timer? _dumpStallTimer;
  int? _dumpOpenedMicros;
  Duration _dumpRecheck = dumpRecheckMin;
  bool _paused = false;
  Duration _backoff = retryMin;
  bool _dirty = false;
  bool _disposed = false;
  bool _usingDumpFallback = false;
  bool _receivedAnyFrame = false;
  int? _lastFrameMicros;
  int _frames = 0;
  Map<String, int> _lastWindow = const {};
  bool _firstFrameEver = true;
  bool _resetBackoffOnFirstFrame = false;
  int _attempt = 0;
  int _connectStartedMicros = 0;
  final Map<int, int> _frameCounts = {};
  final _handling = Stopwatch();
  Timer? _countsTimer;
  double? _motorTemp;

  int get _taps => (_busLog ? 1 : 0) + (_raw ? 1 : 0);

  /// Commands handled before this (a pause, the bus log) are in place when
  /// the first connection is made.
  void start() {
    if (_open == null || _disposed || _started) return;
    _started = true;
    _countsTimer = Timer.periodic(frameCountsEvery, (_) => _emitFrameCounts());
    _connect();
  }

  void handle(CanCommand command) {
    if (_disposed) return;
    switch (command) {
      case CanPause():
        _pause();
      case CanResume():
        _resume();
      case CanReconnectNow():
        _reconnectNow();
      case CanSetMotorTemp(:final value):
        // The first is what the motor reads now, not a change to publish.
        final first = _motorTemp == null;
        _motorTemp = value;
        if (!first) _markDirty();
      case CanBusLogStart():
        _busLogStart(command);
      case CanBusLogStop(:final log):
        _busLogStop(log);
      case CanBusLogTrigger(:final reason, :final atMicros):
        BusLog.instance.trigger(reason, at: atMicros);
      case CanRawStart():
        _rawStart(command);
      case CanRawRow(:final row, :final atMicros):
        RawRecorder.instance.row(row, atMicros);
      case CanRawStop(:final reason):
        _rawStop(reason);
      case CanRawPoll():
        _emitRawStatus();
      case CanUpdateWallClock(:final wallOffsetMicros):
        _wallOffsetMicros = wallOffsetMicros;
        _emitBusLogStatus();
      case CanDispose():
        dispose();
    }
  }

  /// Completes when the bus log's files are closed.
  Future<void> dispose() {
    if (_disposed) return Future.value();
    _disposed = true;
    _sub?.cancel();
    _retry?.cancel();
    _publishTimer?.cancel();
    _silence?.cancel();
    _dumpRecheckTimer?.cancel();
    _dumpStallTimer?.cancel();
    _countsTimer?.cancel();
    _closeSession();
    final busLog = _busLog;
    _busLog = false;
    return busLog ? BusLog.instance.stop() : Future.value();
  }

  /// A name that sorts by time when the clock is right, and cannot collide
  /// when it is not.
  String _stamp() {
    final mono = AnalyticsLogger.instance.monoMicros;
    final offset = _wallOffsetMicros;
    final wall = offset == null
        ? 'noclock'
        : DateTime.fromMicrosecondsSinceEpoch(mono + offset, isUtc: true).toIso8601String().substring(0, 19).replaceAll(RegExp('[-:]'), '');
    return '$wall-${mono ~/ 1000}';
  }

  void _busLogStart(CanBusLogStart c) {
    if (_busLog) return;
    _wallOffsetMicros = c.wallOffsetMicros;
    final b = BusLog.instance;
    final dir = c.directoryPath;
    b.start(header: c.header, directory: dir == null ? null : Directory(dir), stamp: _stamp);
    _busLog = true;
    _tapOn();
    logEvent('bus', 'start', {'file': b.path?.split('/').last});
    _emitBusLogStatus();
  }

  void _busLogStop(bool log) {
    if (!_busLog) return;
    _busLog = false;
    _tapOff();
    final b = BusLog.instance;
    if (log) logEvent('bus', 'stop', {'frames': b.frames, 'changed': b.changed, 'bursts': b.bursts});
    b.stop();
    _emitBusLogStatus();
  }

  void _emitBusLogStatus() {
    final b = BusLog.instance;
    emit(CanBusLogStatus(
      active: b.active,
      frames: b.frames,
      changed: b.changed,
      bursts: b.bursts,
      path: b.path,
      atMicros: AnalyticsLogger.instance.monoMicros,
    ));
  }

  void _rawStart(CanRawStart c) {
    if (_raw) return;
    _wallOffsetMicros = c.wallOffsetMicros;
    final rec = RawRecorder.instance;
    final dir = c.directoryPath;
    rec.start(
      directory: dir == null ? null : Directory(dir),
      stamp: _stamp(),
      header: {...c.header, 'log_mono_ms': AnalyticsLogger.instance.monoMicros ~/ 1000},
    );
    _raw = true;
    _tapOn();
    logEvent('raw', 'start', {'file': rec.path?.split('/').last, 'length_s': c.header['length_s']});
    _emitRawStatus();
  }

  void _rawStop(String reason) {
    if (!_raw) return;
    _raw = false;
    _tapOff();
    final rec = RawRecorder.instance;
    logEvent('raw', 'stop', {'reason': reason, 'frames': rec.frames, 'batches': rec.batches, 'file': rec.path?.split('/').last});
    rec.stop();
    _emitRawStatus();
  }

  void _emitRawStatus() {
    final rec = RawRecorder.instance;
    emit(CanRawStatus(active: rec.active, frames: rec.frames, batches: rec.batches, full: rec.full, path: rec.path));
  }

  /// A raw recording or the bus log has started: the session moves to the
  /// filter-less dump, about sixteen times the frames, and every one is
  /// handed to them before the id filter. It stays there until the last of
  /// them has stopped ([_tapOff]); the decoding goes on as on any dump.
  void _tapOn() {
    if (_open == null) return;
    logEvent('grpc', 'bus_tap', {'on': true, 'taps': _taps, 'connected': _session != null, 'dump': _usingDumpFallback});
    if (_session != null && !_usingDumpFallback) _fallBackToDump();
    _dumpRecheckTimer?.cancel();
    _dumpRecheckTimer = null;
  }

  void _tapOff() {
    if (_open == null) return;
    logEvent('grpc', 'bus_tap', {'on': false, 'taps': _taps, 'connected': _session != null, 'dump': _usingDumpFallback});
    if (_taps > 0 || _disposed || _paused || !_usingDumpFallback || _session == null) return;
    _teardown();
    _connect();
  }

  bool _tapped(List<int> frame) {
    _handling.start();
    if (_busLog) BusLog.instance.frame(frame);
    if (_raw) RawRecorder.instance.frame(frame);
    _handling.stop();
    return BmsState.wants(frame);
  }

  Future<void> _connect() async {
    final open = _open;
    if (open == null || !_started || _disposed || _paused) return;
    _attempt++;
    _connectStartedMicros = AnalyticsLogger.instance.monoMicros;
    logEvent('grpc', 'connect', {'attempt': _attempt});
    _emitHealth();
    try {
      final session = await open();
      if (_disposed || _paused) {
        session.close();
        return;
      }
      logEvent('grpc', 'init_ok', {'can_ids_count': BmsState.canIds.length});
      _session = session;
      // Init succeeding says nothing about the streams; the backoff resets
      // on the first frame instead.
      _resetBackoffOnFirstFrame = true;
      _setDumpFallback(false);
      _receivedAnyFrame = false;
      _listen(session.stream);
      if (_taps > 0) {
        _fallBackToDump();
      } else {
        _silence = Timer(silenceWindow, () => _fallBackToDump(silence: true));
      }
      _emitHealth();
    } catch (e) {
      logEvent('grpc', 'init_fail', {'error': e.toString()});
      _lost('connect failed: $e');
    }
  }

  void _setDumpFallback(bool on) {
    _usingDumpFallback = on;
    emit(CanContext('grpc_dump', on));
    _emitHealth();
  }

  void _listen(Stream<List<int>> frames) {
    _sub = frames.listen(
      (frame) {
        _silence?.cancel();
        _silence = null;
        var changed = false;
        if (_resetBackoffOnFirstFrame) {
          _resetBackoffOnFirstFrame = false;
          _backoff = retryMin;
          logEvent('grpc', 'backoff_reset', {});
          changed = true;
        }
        if (!_receivedAnyFrame) {
          _receivedAnyFrame = true;
          if (!_usingDumpFallback) _dumpRecheck = dumpRecheckMin;
          logEvent('grpc', 'first_frame', {
            'after_ms': (AnalyticsLogger.instance.monoMicros - _connectStartedMicros) ~/ 1000,
            'dump': _usingDumpFallback,
          });
          if (_firstFrameEver) {
            _firstFrameEver = false;
            emit(const CanBootMark('grpc_first_frame'));
          }
          changed = true;
        }
        _lastFrameMicros = AnalyticsLogger.instance.monoMicros;
        _frames++;
        if (changed) _emitHealth();
        _handling.start();
        _count(frame);
        feedFrame(frame);
        _handling.stop();
      },
      onError: (Object e) => _streamEnded('stream error: $e'),
      onDone: () => _streamEnded('stream closed'),
      cancelOnError: true,
    );
  }

  /// `ReadCanStream` closing before any frame arrives looks the same to the
  /// retry loop as the server being down, so we would spin without ever
  /// trying the dump. If the primary stream ended without delivering a
  /// frame, fall back to `CanDumpStream` first.
  void _streamEnded(String why) {
    if (_disposed) return;
    if (!_usingDumpFallback && !_receivedAnyFrame && _session != null) {
      debugPrint('[gRPC] ReadCanStream $why without frames; falling back to CanDumpStream');
      logEvent('grpc', 'close_fallback', {'why': why});
      _fallBackToDump();
      return;
    }
    _lost(why);
  }

  void _fallBackToDump({bool silence = false}) {
    _silence?.cancel();
    _silence = null;
    final session = _session;
    if (_disposed || session == null) return;
    if (silence) logEvent('grpc', 'silence_fallback', {'silence_s': silenceWindow.inSeconds});
    _sub?.cancel();
    _sub = null;
    try {
      _listen(session.openDump().where(_tapped));
      _setDumpFallback(true);
      debugPrint('[gRPC] falling back to CanDumpStream');
      // G-7: nothing used to watch the dump. A silent one (bus asleep) goes
      // back to the retry loop; a working one is still ~16x the frames, so
      // the filtered stream gets another chance after a while.
      _silence = Timer(dumpSilenceWindow, () {
        logEvent('grpc', 'dump_silent', {'silence_s': dumpSilenceWindow.inSeconds});
        _lost('dump silent');
      });
      _dumpRecheckTimer?.cancel();
      _dumpRecheckTimer = _taps > 0 ? null : Timer(_dumpRecheck, _retryPrimary);
      _dumpOpenedMicros = AnalyticsLogger.instance.monoMicros;
      _dumpStallTimer?.cancel();
      _dumpStallTimer = Timer.periodic(dumpStallCheck, (_) => _checkDumpStall());
    } catch (e) {
      logEvent('grpc', 'dump_fallback_refused', {'error': e.toString()});
      _lost('dump fallback refused: $e');
    }
  }

  /// A working dump gone silent for [dumpStallWindow] is the server's ~30 s
  /// cut, not a quiet bus (the whole bus is never silent that long). Reconnect
  /// fast on a fresh session, keeping the bridged values and skipping the
  /// backoff. A reconnect that stays silent is handled by [dumpSilenceWindow].
  void _checkDumpStall() {
    if (_disposed || _paused || !_usingDumpFallback || !_receivedAnyFrame) return;
    final last = _lastFrameMicros;
    if (last == null) return;
    final now = AnalyticsLogger.instance.monoMicros;
    if (now - last >= dumpStallWindow.inMicroseconds) return _restartDump();
    final opened = _dumpOpenedMicros;
    if (opened != null && now - opened >= dumpRotateAfter.inMicroseconds) _restartDump(rotate: true);
  }

  /// A full, fast reconnect: a fresh `Init` session, which the bus-tap path
  /// takes straight back to the dump. No cleared values, no backoff — unlike
  /// [_lost] — because the server is up and only capped the previous stream.
  void _restartDump({bool rotate = false}) {
    if (_disposed || _paused || _session == null || !_usingDumpFallback) return;
    final last = _lastFrameMicros;
    if (!rotate) {
      logEvent('grpc', 'dump_restart',
          {'gap_ms': last == null ? null : (AnalyticsLogger.instance.monoMicros - last) ~/ 1000});
    }
    _teardown();
    _connect();
  }

  /// Leaves a working dump for a new session, which starts on
  /// `ReadCanStream`. Not a loss: no backoff, and the bridged values stand
  /// for the moment it takes.
  void _retryPrimary() {
    _dumpRecheckTimer = null;
    if (_disposed || !_usingDumpFallback || _session == null) return;
    logEvent('grpc', 'dump_recheck', {'after_s': _dumpRecheck.inSeconds});
    _dumpRecheck = _dumpRecheck * 2 > dumpRecheckMax ? dumpRecheckMax : _dumpRecheck * 2;
    _teardown();
    _connect();
  }

  void _teardown() {
    _sub?.cancel();
    _sub = null;
    _silence?.cancel();
    _silence = null;
    _dumpRecheckTimer?.cancel();
    _dumpRecheckTimer = null;
    _dumpStallTimer?.cancel();
    _dumpStallTimer = null;
    _dumpOpenedMicros = null;
    _retry?.cancel();
    _retry = null;
    _closeSession();
    _emitHealth();
  }

  /// G-8: behind another app nothing reads these values, so the ~110
  /// frames/s of decode stop with the UI. Not reported as a loss: the last
  /// values stand (charge-energy accounting keeps its pack voltage) and the
  /// first frame after resume lands within ~0.1 s.
  void _pause() {
    if (_disposed || _paused) return;
    _paused = true;
    logEvent('grpc', 'paused', {'was_connected': _session != null});
    _teardown();
  }

  void _resume() {
    if (_disposed || !_paused) return;
    _paused = false;
    _backoff = retryMin;
    _connect();
  }

  void _count(List<int> frame) {
    if (frame.length < 4) return;
    final id = (frame[0] << 24) | (frame[1] << 16) | (frame[2] << 8) | frame[3];
    _frameCounts[id] = (_frameCounts[id] ?? 0) + 1;
  }

  void _emitFrameCounts() {
    // R-14: after the first frame nothing noticed a stream that went quiet,
    // so CAN-only values froze on screen. A whole counts window with no frame
    // on a live session means the stream is dead; reconnect.
    if (_frameCounts.isEmpty) {
      if (_receivedAnyFrame && _session != null) {
        logEvent('grpc', 'stale', {'silence_s': frameCountsEvery.inSeconds, 'dump': _usingDumpFallback});
        _lost('stale');
      }
      return;
    }
    _lastWindow = {for (final e in _frameCounts.entries) '0x${e.key.toRadixString(16).toUpperCase()}': e.value};
    // handler_ms: time this window spent in our own frame code (the bus
    // log, a recording, decode), not in the gRPC library before it.
    logEvent('grpc', 'frame_counts', {
      'by_can_id': _lastWindow,
      'dump': _usingDumpFallback,
      'handler_ms': (_handling.elapsedMicroseconds / 100).round() / 10,
    });
    _handling.reset();
    _frameCounts.clear();
    emit(CanFrameShapes(_shapes.frameShapes));
    _emitHealth();
  }

  void _emitHealth() => emit(CanHealth(
        connected: _session != null,
        dump: _usingDumpFallback,
        receivingFrames: _receivedAnyFrame,
        attempt: _attempt,
        backoffSeconds: _backoff.inSeconds,
        lastFrameMicros: _lastFrameMicros,
        frames: _frames,
        lastWindowByCanId: _lastWindow,
      ));

  /// Diagnostics → Connections: drop the session and connect now, without
  /// waiting out the backoff.
  void _reconnectNow() {
    if (_disposed) return;
    logEvent('grpc', 'reconnect_manual', {});
    _teardown();
    _backoff = retryMin;
    _connect();
  }

  void _lost(String why) {
    if (_disposed || _paused) return;
    debugPrint('[gRPC] $why; retry in ${_backoff.inSeconds}s');
    logEvent('grpc', 'lost', {'why': why, 'backoff_s': _backoff.inSeconds, 'usingDumpFallback': _usingDumpFallback});
    // G-3: without a stream the bridged values are no longer readings.
    // Forget the fast frames (the cells and pack temperatures stay for the
    // diagnostics page) and hand the vehicle state back to HHMIS.
    _bms.clearLive();
    emit(const CanLost());
    _teardown();
    _retry = Timer(_backoff, _connect);
    _backoff = _backoff * 2 > retryMax ? retryMax : _backoff * 2;
    _emitHealth();
  }

  void _closeSession() {
    final s = _session;
    _session = null;
    s?.close().catchError((Object e) => debugPrint('[gRPC] close failed: $e'));
  }

  /// One raw frame from the stream. Public so tests can drive it.
  void feedFrame(List<int> frame) {
    final bytes = frame is Uint8List ? frame : Uint8List.fromList(frame);
    _shapes.noteFrame(bytes);
    _bms.feed(bytes);
    if (_bms.hasData) _markDirty();
  }

  void _markDirty() {
    _dirty = true;
    _publishTimer ??= Timer(publishEvery, _publish);
  }

  void _publish() {
    _publishTimer = null;
    if (_disposed || !_dirty) return;
    _dirty = false;
    if (!_bms.hasData) return;
    // The CAN stream is the only source for ambient light, the service
    // flag and the Eco range word.
    emit(CanPublish(
      diagnostics: _bms.toDiagnostics(motorTemp: _motorTemp),
      faults: _bms.activeFaults,
      ambientBrightness: _bms.ambientBrightness,
      serviceIndicator: _bms.serviceIndicator,
      regenPowerLimitW: _bms.regenLimitW?.round(),
      dischargePowerLimitW: _bms.dischargeLimitW?.round(),
      rangeEcoCan: _bms.rangeEcoCan,
      regenAvailability: _bms.regenAvailability,
      towTheftState: _bms.towTheftState,
      busVoltage: _bms.busVoltage,
      packVoltage: _bms.packVoltage,
      packCurrent: _bms.batteryCurrent,
      trunkClosed: _bms.trunkClosed,
      vehicleLockStateBcm: _bms.vehicleLockStateBcm,
      odometerM: _bms.odometerM,
      pduTemp: _bms.pduTemp,
      mcuTemp: _bms.mcuTemp,
      thermalLimits: _bms.thermalConfigSeen ? _bms.thermalLimits : null,
      liveInputs: _bms.liveInputs,
    ));
    _emitHealth();
  }
}
