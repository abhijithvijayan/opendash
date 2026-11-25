import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `scripts/raw-recording.py` on a bus-log file: what --scrub leaves.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('raw_recording_script'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('--scrub takes a text frame out of the frame lines and out of every keyframe', () {
    // "MB8XYZ12" in ASCII: a frame that spells text, as a VIN frame would.
    const vin = '4d423858595a3132';
    final input = File('${dir.path}/bus-1.jsonl')
      ..writeAsStringSync([
        jsonEncode({'raw_recording': 1, 'kind': 'bus_log', 'log_mono_ms': 1000, 'warning': 'w'}),
        jsonEncode({'t': 0, 'f': '7e8', 'n': 8, 'd': vin}),
        jsonEncode({'t': 0, 'f': '140', 'n': 8, 'd': '0100000000000000'}),
        jsonEncode({'t': 100, 'f': '140', 'n': 8, 'd': '0200000000000000'}),
        jsonEncode({'t': 30000, 'key': {'7e8': vin, '140': '0200000000000000'}}),
      ].join('\n'));
    final out = '${dir.path}/scrubbed.jsonl';
    final r = Process.runSync('python3', ['-I', 'scripts/raw-recording.py', input.path, '--scrub', out]);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    final text = File(out).readAsStringSync();
    expect(text.contains(vin), isFalse);
    final rows = [for (final l in const LineSplitter().convert(text)) jsonDecode(l) as Map];
    expect(rows.last['key'], {'140': '0200000000000000'});
    expect(rows.where((r) => r['f'] == '140'), hasLength(2));
  });

  test('the summary says a bus log counts changes', () {
    final input = File('${dir.path}/bus-2.jsonl')
      ..writeAsStringSync([
        jsonEncode({'raw_recording': 1, 'kind': 'bus_log', 'log_mono_ms': 0}),
        jsonEncode({'t': 0, 'f': '140', 'n': 8, 'd': '0100000000000000'}),
        jsonEncode({'t': 1000, 'f': '140', 'n': 8, 'd': '0200000000000000'}),
      ].join('\n'));
    final r = Process.runSync('python3', ['-I', 'scripts/raw-recording.py', input.path]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(r.stdout, contains('changes'));
  });
}
