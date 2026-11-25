import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/providers/battery_diagnostics_provider.dart';
import 'package:opendash/providers/grpc_diagnostics_provider.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/raw_recorder.dart';
import 'package:opendash/state/raw_recording_state.dart';
import 'helpers/stock.dart';

class _Session implements FrameSession {
  _Session(this.stream, this.dump);
  @override
  final Stream<List<int>> stream;
  final Stream<List<int>> dump;
  int dumpOpened = 0;
  int closed = 0;
  @override
  Stream<List<int>> openDump() {
    dumpOpened++;
    return dump;
  }

  @override
  Future<void> close() async => closed++;
}

Uint8List frame(int id, List<int> data) =>
    Uint8List.fromList([(id >> 24) & 255, (id >> 16) & 255, (id >> 8) & 255, id & 255, data.length, 0, 0, 0, ...data]);

/// "Record raw data": a few minutes of everything, in a
/// file of its own, started on purpose.
void main() {
  setUp(() {
    AnalyticsLogger.instance.resetForTest();
    RawRecorder.instance.resetForTest();
  });

  List<Map<String, dynamic>> lines() => [for (final l in RawRecorder.instance.memory) jsonDecode(l) as Map<String, dynamic>];

  test('nothing is written until a recording is started', () {
    RawRecorder.instance.batch({'INT_VEHICLE_SPEED': 40});
    RawRecorder.instance.frame(frame(0x1A5, List.filled(8, 1)));
    expect(RawRecorder.instance.memory, isEmpty);
  });

  test('frames and updates are written with their time, under a warning', () {
    final rec = RawRecorder.instance;
    rec.start(header: {'version': '1.0.0'});
    rec.frame(frame(0x7E8, [0x4D, 0x42, 0x38, 0x58, 0x59, 0x5A, 0x31, 0x32]));
    rec.batch({'INT_VEHICLE_SPEED': 40, 'STR_VEHICLE_DRIVE_MODE': 'SPORT'});
    final l = lines();
    expect(l[0]['raw_recording'], 1);
    expect(l[0]['warning'], contains('share only with someone you trust'));
    expect(l[1], containsPair('f', '7e8'));
    expect(l[1], containsPair('d', '4d423858595a3132'));
    expect(l[1]['t'], isA<int>());
    expect(l[2]['b'], {'INT_VEHICLE_SPEED': 40, 'STR_VEHICLE_DRIVE_MODE': 'SPORT'});
    expect((rec.frames, rec.batches), (1, 1));
  });

  test('values from the stock service keep the survey\'s privacy rule', () {
    RawRecorder.instance.start(header: const {});
    RawRecorder.instance.batch({'STR_PROFILE_USER_NAME': 'Asha', '_hwInfo_9': 'MB8XYZ1234567890A', 'FLOAT_NAVI_LATITUDE': 12.9716, 'INT_BATTERY_SOC': 71});
    final text = RawRecorder.instance.memory.join();
    for (final secret in ['Asha', 'MB8XYZ', '12.97']) {
      expect(text.contains(secret), isFalse, reason: secret);
    }
    expect(lines().last['b'], {'STR_PROFILE_USER_NAME': null, '_hwInfo_9': 'len17', 'FLOAT_NAVI_LATITUDE': null, 'INT_BATTERY_SOC': 71});
  });

  test('identifier frames (VIN, MAC) are masked at capture; ordinary frames are not', () {
    RawRecorder.instance.start(header: const {});
    RawRecorder.instance.frame(frame(0x689, [0x01, 0x50, 0x35, 0x33, 0x41, 0x46, 0x44, 0x43])); // VIN "·P53AFDC"
    RawRecorder.instance.frame(frame(0x696, [0x29, 0x88, 0x0f, 0x6d, 0x49, 0xe3, 0, 0])); // BLE MAC
    RawRecorder.instance.frame(frame(0x1A5, List.filled(8, 0xAB))); // ordinary BMS frame
    final text = RawRecorder.instance.memory.join();
    expect(text.contains('50353341'), isFalse, reason: 'P53A VIN bytes must not appear');
    expect(text.contains('29880f6d49e3'), isFalse, reason: 'BLE MAC bytes must not appear');
    expect(lines().first['pii_masked'], contains('689'));
    expect(lines().firstWhere((l) => l['f'] == '689')['d'], '0000000000000000');
    expect(lines().firstWhere((l) => l['f'] == '696')['d'], '0000000000000000');
    expect(lines().firstWhere((l) => l['f'] == '1a5')['d'], 'abababababababab', reason: 'ordinary payload untouched');
  });

  test('a recording reads the whole bus, ends by the clock and hands the stream back', () {
    fakeAsync((async) {
      final primary = <StreamController<List<int>>>[];
      final dump = StreamController<List<int>>.broadcast();
      final sessions = <_Session>[];
      final events = StreamController<dynamic>();
      final c = ProviderContainer(overrides: [
        batteryDiagnosticsProvider.overrideWith(() => GrpcDiagnosticsNotifier(source: () async {
              primary.add(StreamController<List<int>>());
              sessions.add(_Session(primary.last.stream, dump.stream));
              return sessions.last;
            })),
        vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: events.stream, invoke: (_, _) async => true)),
      ]);
      c.read(batteryDiagnosticsProvider);
      c.read(vehicleProvider);
      async.flushMicrotasks();
      primary.last.add(frame(0x1A5, List.filled(8, 1)));
      async.flushMicrotasks();
      expect(sessions.single.dumpOpened, 0, reason: 'the filtered stream is working');

      c.read(rawRecordingProvider.notifier).start();
      async.flushMicrotasks();
      expect(sessions.single.dumpOpened, 1);
      expect(c.read(rawRecordingProvider).active, isTrue);

      // A live bus: a frame OpenDash reads, every second.
      final bus = Timer.periodic(const Duration(seconds: 1), (_) => dump.add(frame(0x1A6, List.filled(8, 2))));
      // A frame OpenDash never asks for, and a stock update.
      dump.add(frame(0x4B0, [1, 2, 3, 4, 5, 6, 7, 8]));
      events.add({'_connected': true, 'INT_VEHICLE_SPEED': 30});
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 2));
      final mid = c.read(rawRecordingProvider);
      expect(mid.frames, greaterThanOrEqualTo(2));
      expect(mid.batches, 1);
      expect(mid.secondsLeft, lessThan(RawRecordingNotifier.length.inSeconds));
      expect(lines().where((l) => l['f'] == '4b0'), hasLength(1));

      // The dump is not dropped for a recheck while a recording runs.
      async.elapse(GrpcDiagnosticsNotifier.dumpRecheckMin + const Duration(seconds: 5));
      expect(sessions, hasLength(1));

      async.elapse(RawRecordingNotifier.length);
      expect(c.read(rawRecordingProvider).active, isFalse);
      expect((AnalyticsLogger.instance.recent('raw', 'stop').single['data'] as Map)['reason'], 'time');
      expect(lines().last['end'], 1);
      async.flushMicrotasks();
      expect(sessions.length, greaterThan(1), reason: 'a fresh session, back on the filtered stream first');
      final written = RawRecorder.instance.frames;
      dump.add(frame(0x4B0, List.filled(8, 9)));
      async.flushMicrotasks();
      expect(RawRecorder.instance.frames, written, reason: 'nothing after the end');
      bus.cancel();
      c.dispose();
      events.close();
      dump.close();
    });
  });

  test('"Stop" ends it early; in Chrome there is no bus and no file', () {
    fakeAsync((async) {
      final c = ProviderContainer();
      final n = c.read(rawRecordingProvider.notifier);
      n.start();
      async.elapse(const Duration(seconds: 3));
      n.stop();
      expect(c.read(rawRecordingProvider).active, isFalse);
      expect(c.read(rawRecordingProvider).path, isNull);
      expect((AnalyticsLogger.instance.recent('raw', 'stop').single['data'] as Map)['reason'], 'rider');
      async.elapse(const Duration(minutes: 10));
      c.dispose();
    });
  });

  group('scripts/raw-recording.py', () {
    const script = 'scripts/raw-recording.py';
    final python = Process.runSync('which', ['python3']).exitCode == 0;

    String recording() {
      final rec = RawRecorder.instance;
      rec.start(header: {'version': '1.0.0', 'build': 500});
      for (var i = 0; i < 30; i++) {
        // Cells under an id OpenDash does not know, as another pack might send them.
        rec.frame(frame(0x2C1, [for (final mv in [3901 + i, 3890, 3640 - i, 3905]) ...[mv & 255, mv >> 8]]));
        rec.frame(frame(0x7E8, ascii.encode('MB8XYZ12')));
        rec.frame(frame(0x7E9, [0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0]));
        rec.frame(frame(0x1A5, [for (final mv in [3900, 3910 + i, 3640, 3905]) ...[mv & 255, mv >> 8]]));
        rec.batch({'INT_VEHICLE_SPEED': 30 + i});
      }
      final dir = Directory.systemTemp.createTempSync('raw');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/raw-test.jsonl')..writeAsStringSync('${rec.memory.join('\n')}\n');
      return file.path;
    }

    test('lists every id and points at cells under an unknown one', () {
      final r = Process.runSync('python3', [script, recording()]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      final out = r.stdout as String;
      expect(out, contains('120 frames on 4 ids, 30 updates'));
      expect(out.split('\n').firstWhere((l) => l.startsWith('0x2c1')), contains('cell voltages?'));
      expect(out.split('\n').firstWhere((l) => l.startsWith('0x7e8')), contains('TEXT'));
      expect(out.split('\n').firstWhere((l) => l.startsWith('0x7e9')), contains('never changed'));
      expect(out, contains('frames OpenDash reads that never came'));
    }, skip: !python);

    test('--scrub drops text and unknown constant frames, and keeps the rest', () {
      final path = recording();
      final out = '${File(path).parent.path}/clean.jsonl';
      final r = Process.runSync('python3', [script, path, '--scrub', out]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      final clean = File(out).readAsStringSync();
      expect(clean.contains('4d423858595a3132'), isFalse, reason: 'the frame that spelt an identifier');
      expect(clean.contains('"f":"7e9"'), isFalse);
      expect(clean.contains('"f":"2c1"'), isTrue);
      expect(clean.contains('"f":"1a5"'), isTrue);
      expect(clean.contains('INT_VEHICLE_SPEED'), isTrue);
      expect(clean.contains('Scrubbed'), isTrue);
    }, skip: !python);

    test('--id prints one frame over time', () {
      final r = Process.runSync('python3', [script, recording(), '--id', '0x2C1']);
      expect(r.exitCode, 0);
      expect((r.stdout as String).trim().split('\n'), hasLength(30));
      expect(r.stdout, contains('3901 3890 3640 3905'));
    }, skip: !python);
  });
}
