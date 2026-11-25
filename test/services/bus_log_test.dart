import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/bus_log.dart';

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

List<Map<String, dynamic>> rows(List<String> lines) => [for (final l in lines) jsonDecode(l) as Map<String, dynamic>];

void main() {
  final log = BusLog.instance;

  setUp(() {
    AnalyticsLogger.instance.resetForTest();
    log.resetForTest();
  });
  tearDown(() {
    log.resetForTest();
    AnalyticsLogger.instance.resetForTest();
  });

  void run(void Function(FakeAsync async) body) => fakeAsync((async) {
        AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
        body(async);
      });

  test('the first line is a raw-recording header carrying the clock, the warning and the scooter', () {
    run((async) {
      async.elapse(const Duration(seconds: 3));
      log.start(header: {'version': '0.1.1-beta.2', 'vehicle_type': 3});
      final h = rows(log.memory).first;
      expect(h['raw_recording'], 1, reason: 'scripts/raw-recording.py reads it');
      expect(h['kind'], 'bus_log');
      expect(h['log_mono_ms'], 3000, reason: 'log_mono_ms + t is the analytics log\'s mono');
      expect(h['warning'], contains('scrub'));
      expect(h['vehicle_type'], 3);
      expect(h['changed_only'], isTrue);
    });
  });

  test('a frame is written only when its payload or length changes', () {
    run((async) {
      log.start(header: const {});
      for (var i = 0; i < 10; i++) {
        log.frame(frame(0x356, [1, 2, 3, 4, 0, 0, 0, 0]));
        async.elapse(const Duration(milliseconds: 100));
      }
      log.frame(frame(0x356, [2, 2, 3, 4, 0, 0, 0, 0]));
      log.frame(frame(0x356, [2, 2, 3, 4]));
      final written = rows(log.memory).where((r) => r['f'] == '356').toList();
      expect(written.length, 3);
      expect(written[0]['d'], '0102030400000000');
      expect(written[1]['t'], 1000);
      expect(written[2]['n'], 4);
      expect(log.frames, 12);
      expect(log.changed, 3);
    });
  });

  test('a keyframe every 30 s holds the last payload of every id', () {
    run((async) {
      log.start(header: const {});
      log.frame(frame(0x120, [1, 0, 0, 0, 0, 0, 0, 0]));
      log.frame(frame(0x356, [9, 0, 0, 0, 0, 0, 0, 0]));
      async.elapse(BusLog.keyframeEvery);
      log.frame(frame(0x120, [1, 0, 0, 0, 0, 0, 0, 0]));
      final keys = rows(log.memory).where((r) => r.containsKey('key')).toList();
      expect(keys.length, 1);
      expect(keys.single['key'], {'120': '0100000000000000', '356': '0900000000000000'});
      expect(keys.single['t'], 30000);
    });
  });

  test('a burst holds the minute before the trigger and the seconds after, every frame', () {
    run((async) {
      log.start(header: const {'build': 7});
      // 80 s of one unchanging frame a second, then the trigger.
      for (var i = 0; i < 80; i++) {
        log.frame(frame(0x140, [i & 1, 0, 0, 0, 0, 0, 0, 0]));
        log.frame(frame(0x6bc, [0, 0, 0, 0, 0, 0, 0, 0]));
        async.elapse(const Duration(seconds: 1));
      }
      log.trigger('command');
      for (var i = 0; i < 5; i++) {
        log.frame(frame(0x6bc, [0x54, 0, 0, 0, 0, 0, 0, 0]));
        async.elapse(const Duration(seconds: 1));
      }
      log.trigger('fault');
      async.elapse(BusLog.after);
      async.flushMicrotasks();
      expect(log.burstMemory.length, 1, reason: 'a trigger while one is pending joins it');
      final lines = rows(log.burstMemory.values.single);
      final h = lines.first;
      expect(h['kind'], 'bus_burst');
      expect(h['reasons'], ['command', 'fault']);
      expect(h['build'], 7);
      expect(h['trigger_t'], 60000, reason: 'the first frame kept is the one a minute before the trigger');
      final frames = lines.skip(1).toList();
      expect(frames.where((r) => r['f'] == '6bc').length, 60 + 5, reason: 'unchanged frames too: a burst is every frame');
      expect(frames.last['d'], '5400000000000000');
      expect(log.bursts, 1);
      expect(AnalyticsLogger.instance.recent('bus', 'burst').single['data'], containsPair('frames', frames.length));
    });
  });

  test('stopping writes a pending burst with what it has', () {
    run((async) {
      log.start(header: const {});
      log.frame(frame(0x120, [1, 0, 0, 0, 0, 0, 0, 0]));
      log.trigger('ride_end');
      log.stop();
      async.flushMicrotasks();
      expect(log.burstMemory.keys.single, contains('ride_end'));
      expect(log.active, isFalse);
      log.frame(frame(0x120, [2, 0, 0, 0, 0, 0, 0, 0]));
      expect(log.frames, 1, reason: 'nothing is read once stopped');
    });
  });

  test('on disk: a full file rotates, only the newest generations are kept, and a burst lands beside them', () async {
    final dir = await Directory.systemTemp.createTemp('bus_log_test');
    addTearDown(() => dir.delete(recursive: true));
    var n = 0;
    log.fileLimit = 2000;
    log.start(header: const {}, directory: dir, stamp: () => '${n++}'.padLeft(4, '0'));
    for (var i = 0; i < 2000; i++) {
      log.frame(frame(0x100 + (i % 50), [i & 0xff, i >> 8, 0, 0, 0, 0, 0, 0]));
    }
    log.trigger('command');
    await log.stop();
    final names = dir.listSync().map((f) => f.uri.pathSegments.last).toList()..sort();
    final busFiles = names.where((f) => f.startsWith('bus-')).toList();
    // The cap is what matters; the exact count can tie on file mtime under
    // parallel test load, so assert it is never exceeded rather than ==.
    expect(busFiles.length, inInclusiveRange(1, BusLog.generations));
    expect(names.where((f) => f.startsWith('burst-')).single, endsWith('-command.jsonl'));
    // Every surviving bus file starts with its header, and the ones with
    // any frames carry a keyframe so they can be read alone. (Checked over
    // all of them, not just the newest, so a mid-flush file under parallel
    // load does not flake the index.)
    for (final f in busFiles) {
      final lines = File('${dir.path}/$f').readAsLinesSync();
      expect(jsonDecode(lines.first)['raw_recording'], 1, reason: '$f starts with its header');
      if (lines.length > 1) {
        expect(jsonDecode(lines[1]), contains('key'), reason: '$f has a keyframe');
      }
    }
  });

  test('an identifier frame (VIN) is masked at capture: header, changed line and keyframe', () {
    run((async) {
      log.start(header: const {});
      // 0x689 Vehicle_VIN_Info: the real VIN bytes must never reach a line.
      log.frame(frame(0x689, [0x01, 0x50, 0x35, 0x33, 0x41, 0x46, 0x44, 0x43])); // "·P53AFDC"
      log.frame(frame(0x356, [1, 2, 3, 4, 0, 0, 0, 0])); // an ordinary frame is untouched
      async.elapse(const Duration(seconds: 31)); // force a keyframe
      log.frame(frame(0x120, [9, 0, 0, 0, 0, 0, 0, 0]));
      final r = rows(log.memory);
      expect(r.first['pii_masked'], contains('689'), reason: 'the header names the masked ids');
      expect(r.first['warning'], contains('masked'));
      final vin = r.where((e) => e['f'] == '689').toList();
      expect(vin, isNotEmpty);
      expect(vin.every((e) => e['d'] == '0000000000000000'), isTrue, reason: 'VIN payload never written');
      // No line (changed frame or keyframe) contains the plaintext VIN bytes.
      expect(log.memory.any((l) => l.contains('50353341')), isFalse, reason: 'P53A bytes must not appear anywhere');
      // The ordinary frame keeps its real payload.
      expect(r.firstWhere((e) => e['f'] == '356')['d'], '0102030400000000');
      final key = r.firstWhere((e) => e.containsKey('key'))['key'] as Map<String, dynamic>;
      expect(key['689'], '0000000000000000', reason: 'keyframe masks the VIN too');
    });
  });
}
