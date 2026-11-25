import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import '../providers/battery_diagnostics_provider.dart';
import '../providers/mock_provider.dart';
import '../services/analytics_logger.dart';
import '../services/build_info.dart';
import '../services/can_link.dart';
import '../services/raw_recorder.dart';
import 'bus_log_state.dart' show wallClockOffsetMicros;

class RawRecording {
  const RawRecording({this.active = false, this.secondsLeft = 0, this.frames = 0, this.batches = 0, this.path});
  final bool active;
  final int secondsLeft;
  final int frames;
  final int batches;

  /// The file of the running or the last recording; null when there is no
  /// folder to write to (Chrome, tests).
  final String? path;
}

final rawRecordingProvider = NotifierProvider<RawRecordingNotifier, RawRecording>(RawRecordingNotifier.new);

/// Settings → Developer → "Record raw data": [length] of everything the
/// scooter sends, into a file of its own (`RawRecorder`). Started on
/// purpose, never by itself; it ends by the clock, when the file is full,
/// or on "Stop". While it runs the battery data stream reads the whole
/// bus instead of the fifteen frames it normally asks for.
// TODO(raw-recording): never run on the scooter. Unknown: whether the head unit stays smooth on sixteen times
// the frames, and whether the unfiltered stream delivers every id. Try it parked first (app.frames, raw.stop).
class RawRecordingNotifier extends Notifier<RawRecording> {
  static const length = Duration(minutes: 5);

  Timer? _timer;
  int _left = 0;
  BatteryDiagnosticsNotifier? _diag;
  VehicleNotifier? _vehicle;

  @override
  RawRecording build() {
    ref.onDispose(() {
      _timer?.cancel();
      _diag?.rawStatus.removeListener(_onStatus);
    });
    return const RawRecording();
  }

  void start() {
    if (state.active) return;
    final logPath = AnalyticsLogger.instance.currentFilePath;
    final vehicle = ref.read(vehicleProvider.notifier);
    _vehicle = vehicle;
    final diag = ref.read(batteryDiagnosticsProvider.notifier);
    _diag?.rawStatus.removeListener(_onStatus);
    _diag = diag;
    // The recorder runs where the bus is read (`CanLink`), which names the
    // file and stamps the header's `log_mono_ms`.
    diag.send(CanRawStart(
      directoryPath: logPath == null ? null : File(logPath).parent.path,
      wallOffsetMicros: wallClockOffsetMicros(),
      header: {
        'version': appVersion,
        'build': BuildInfo.number,
        'git_sha': BuildInfo.gitSha,
        'length_s': length.inSeconds,
      },
    ));
    // The stock service's batches arrive here, so their rows are made here.
    vehicle.rawBatch = (delta) => diag.send(
        CanRawRow(RawRecorder.batchRow(delta, isText: vehicle.survey.isText), AnalyticsLogger.instance.monoMicros));
    _left = length.inSeconds;
    final rec = diag.rawStatus.value;
    state = RawRecording(active: true, secondsLeft: length.inSeconds, path: rec.active ? rec.path : null);
    diag.rawStatus.addListener(_onStatus);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  /// Counts that come after this asked for them: the file's name once it
  /// is known, and the last counts of a recording that has ended.
  void _onStatus() {
    final rec = _diag!.rawStatus.value;
    if (state.active && rec.active && rec.path != state.path) {
      state = RawRecording(active: true, secondsLeft: _left, frames: rec.frames, batches: rec.batches, path: rec.path);
    } else if (!state.active && !rec.active) {
      state = RawRecording(frames: rec.frames, batches: rec.batches, path: rec.path);
    }
  }

  void _tick() {
    final diag = _diag!;
    // Counted in ticks: the timer is the clock here.
    _left--;
    diag.send(const CanRawPoll());
    final rec = diag.rawStatus.value;
    if (_left <= 0 || rec.full) return stop(rec.full ? 'full' : 'time');
    state = RawRecording(active: true, secondsLeft: _left, frames: rec.frames, batches: rec.batches, path: rec.path);
  }

  void stop([String reason = 'rider']) {
    if (!state.active) return;
    _timer?.cancel();
    _timer = null;
    _vehicle?.rawBatch = null;
    _vehicle = null;
    final diag = _diag!;
    diag.send(CanRawStop(reason));
    final rec = diag.rawStatus.value;
    state = RawRecording(frames: rec.frames, batches: rec.batches, path: rec.path);
  }
}
