import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/providers/battery_diagnostics_provider.dart';
import 'package:opendash/providers/grpc_diagnostics_provider.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/bus_log.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:opendash/services/raw_recorder.dart';
import 'package:opendash/state/bus_log_state.dart';
import 'package:opendash/state/raw_recording_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/stock.dart';

class _Session implements FrameSession {
  _Session(this.stream, this.dump);
  @override
  final Stream<List<int>> stream;
  final Stream<List<int>> dump;
  int dumpOpened = 0;
  @override
  Stream<List<int>> openDump() {
    dumpOpened++;
    return dump;
  }

  @override
  Future<void> close() async {}
}

Uint8List frame(int id, List<int> data) =>
    Uint8List.fromList([(id >> 24) & 255, (id >> 16) & 255, (id >> 8) & 255, id & 255, data.length, 0, 0, 0, ...data]);

/// Settings → Developer → "Bus log".
void main() {
  setUp(() async {
    AnalyticsLogger.instance.resetForTest();
    BusLog.instance.resetForTest();
    RawRecorder.instance.resetForTest();
    SharedPreferences.setMockInitialValues({});
    await PrefsService.init();
  });
  tearDown(() {
    BusLog.instance.resetForTest();
    PrefsService.resetForTest();
  });

  /// A scooter with a live bus; [body] gets the dump and the sessions opened.
  void onScooter(void Function(FakeAsync async, ProviderContainer c, StreamController<List<int>> dump, List<_Session> sessions) body) {
    fakeAsync((async) {
      AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
      final dump = StreamController<List<int>>.broadcast();
      final sessions = <_Session>[];
      final c = ProviderContainer(overrides: [
        batteryDiagnosticsProvider.overrideWith(() => GrpcDiagnosticsNotifier(source: () async {
              sessions.add(_Session(StreamController<List<int>>().stream, dump.stream));
              return sessions.last;
            })),
        vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: const Stream.empty(), invoke: (_, _) async => true)),
      ]);
      c.read(batteryDiagnosticsProvider);
      c.read(vehicleProvider);
      async.flushMicrotasks();
      body(async, c, dump, sessions);
      c.dispose();
      dump.close();
    });
  }

  test('on by default: it reads the whole bus from boot; turning it off sticks across a restart', () {
    onScooter((async, c, dump, sessions) {
      expect(c.read(busLogProvider).enabled, isTrue, reason: 'on from the first boot');
      expect(BusLog.instance.active, isTrue);
      expect(sessions.single.dumpOpened, 1, reason: 'the whole bus, not the fifteen-frame filter');
      dump.add(frame(0x4B0, [1, 2, 3, 4, 5, 6, 7, 8]));
      async.flushMicrotasks();
      expect(BusLog.instance.memory.map((l) => jsonDecode(l) as Map).where((r) => r['f'] == '4b0'), hasLength(1));
      c.read(busLogProvider.notifier).setEnabled(false);
      expect(BusLog.instance.active, isFalse);
      expect(PrefsService.getBool(PrefsKeys.busLog, true), isFalse);
    });
    onScooter((async, c, dump, sessions) {
      c.read(busLogProvider);
      expect(BusLog.instance.active, isFalse, reason: 'turned off, and the off is kept');
      expect(sessions.single.dumpOpened, 0, reason: 'it never takes the dump');
    });
  });

  test('a rider\'s command, a refusal, a ride and a fault make bursts; the app\'s own commands do not', () {
    onScooter((async, c, dump, sessions) {
      c.read(busLogProvider.notifier).setEnabled(true);
      final bus = Timer.periodic(const Duration(milliseconds: 100), (_) => dump.add(frame(0x120, List.filled(8, 1))));
      async.elapse(const Duration(seconds: 5));

      logEvent('hhmis', 'cmd_send', {'type': 'setBrightness', 'value': 90});
      logEvent('hhmis', 'cmd_send', {'type': 'int', 'name': 'btMediaPlaying'});
      logEvent('hhmis', 'cmd_result', {'success': true});
      async.elapse(BusLog.after + const Duration(seconds: 1));
      expect(BusLog.instance.burstMemory, isEmpty);

      logEvent('hhmis', 'cmd_send', {'type': 'void', 'name': 'unlockSeat'});
      async.elapse(const Duration(seconds: 1));
      logEvent('hhmis', 'cmd_result', {'success': false});
      async.elapse(BusLog.after);
      async.flushMicrotasks();
      final first = jsonDecode(BusLog.instance.burstMemory.values.single.first) as Map;
      expect(first['reasons'], ['command', 'command_failed']);

      logEvent('ride', 'end', {});
      async.elapse(BusLog.after);
      async.flushMicrotasks();
      c.read(vehicleProvider.notifier).state = c.read(vehicleProvider).copyWith(faultActive: true);
      async.elapse(BusLog.after);
      async.flushMicrotasks();
      final reasons = [for (final lines in BusLog.instance.burstMemory.values) (jsonDecode(lines.first) as Map)['reasons']];
      expect(reasons, [
        ['command', 'command_failed'],
        ['ride_end'],
        ['fault'],
      ]);
      bus.cancel();
    });
  });

  test('a raw recording and the bus log share the dump; the stream goes back only when both are done', () {
    onScooter((async, c, dump, sessions) {
      c.read(busLogProvider.notifier).setEnabled(true);
      c.read(rawRecordingProvider.notifier).start();
      async.flushMicrotasks();
      dump.add(frame(0x4B0, List.filled(8, 3)));
      async.flushMicrotasks();
      expect(RawRecorder.instance.frames, 1);
      expect(BusLog.instance.frames, 1);
      c.read(rawRecordingProvider.notifier).stop();
      async.flushMicrotasks();
      expect(sessions, hasLength(1), reason: 'the bus log still needs the dump');
      dump.add(frame(0x4B0, List.filled(8, 4)));
      async.flushMicrotasks();
      expect(BusLog.instance.frames, 2);
      c.read(busLogProvider.notifier).setEnabled(false);
      async.flushMicrotasks();
      expect(sessions.length, greaterThan(1), reason: 'back on the filtered stream');
    });
  });

  test('every minute the cost is logged: frames read and frames written per second', () {
    onScooter((async, c, dump, sessions) {
      c.read(busLogProvider.notifier).setEnabled(true);
      // A battery frame: a dump with none of those is judged silent and reopened.
      final bus = Timer.periodic(const Duration(milliseconds: 10), (_) => dump.add(frame(0x140, List.filled(8, 1))));
      async.elapse(BusLogNotifier.statsEvery);
      final stats = AnalyticsLogger.instance.recent('bus', 'stats').single['data'] as Map;
      expect(stats['frames_s'], closeTo(100, 2));
      expect(stats['changed_s'], 0);
      bus.cancel();
    });
  });
}
