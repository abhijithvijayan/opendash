import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/services/analytics_logger.dart';

enum ListEnum { first, second }

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('opendash-analytics-');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  List<Map<String, Object?>> lines(File f) =>
      f.readAsLinesSync().where((l) => l.isNotEmpty).map((l) => jsonDecode(l) as Map<String, Object?>).toList();

  File current(AnalyticsLogger l) => File(l.currentFilePath!);

  test('log writes JSONL to the file and flush returns the event count', () async {
    final l = AnalyticsLogger();
    await l.init(directory: tmp);
    expect(l.currentFilePath, endsWith('analytics${Platform.pathSeparator}opendash.jsonl'));
    l.log('app', 'start', {'version': '0.1.0'});
    l.log('ui', 'tap', {'target': 'ctl-left'});
    expect(await l.flush(), 2);
    final rows = lines(current(l));
    expect(rows.map((r) => r['cat']), ['app', 'ui']);
    expect(rows.first['evt'], 'start');
    expect((rows.first['data'] as Map)['version'], '0.1.0');
    expect(rows.first['ts'], matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$')));
    expect(rows[1]['mono'] as int, greaterThanOrEqualTo(rows.first['mono'] as int));
    expect(await l.flush(), 0, reason: 'nothing left');
    await l.dispose();
  });

  test('events logged before init reach the file once it opens', () async {
    final l = AnalyticsLogger();
    l.log('boot', 'mark', {'stage': 'main_entered'});
    await l.init(directory: tmp);
    await l.flush();
    expect(lines(current(l)).single['evt'], 'mark');
    await l.dispose();
  });

  test('rotation keeps the current file plus the configured generations', () async {
    final l = AnalyticsLogger(maxFileBytes: 2000, generations: 4, flushAt: 1000);
    await l.init(directory: tmp);
    for (var i = 0; i < 200; i++) {
      l.log('state', 'heartbeat', {'i': i, 'pad': 'x' * 40});
      if (i % 10 == 9) await l.flush();
    }
    await l.dispose();
    final names = tmp.listSync(recursive: true).whereType<File>().map((f) => f.uri.pathSegments.last).toList()..sort();
    expect(names, ['opendash.1.jsonl', 'opendash.2.jsonl', 'opendash.3.jsonl', 'opendash.4.jsonl', 'opendash.jsonl']);
    final dir = Directory('${tmp.path}${Platform.pathSeparator}analytics');
    final gen1 = lines(File('${dir.path}${Platform.pathSeparator}opendash.1.jsonl'));
    final gen2 = lines(File('${dir.path}${Platform.pathSeparator}opendash.2.jsonl'));
    expect(gen1.first['evt'], 'rotated', reason: 'each new file opens with the rotation marker');
    expect((gen2.last['data'] as Map)['i'], lessThan((gen1.last['data'] as Map)['i']), reason: 'older generations hold earlier events');
    final newest = lines(current(l));
    expect(newest.first['evt'], 'rotated');
    expect(current(l).lengthSync(), lessThan(2000 + 600));
  });

  test('a disabled logger discards silently and re-enabling straddles the gap', () async {
    final l = AnalyticsLogger();
    await l.init(directory: tmp, enabled: false);
    l.log('ui', 'tap', {'target': 'nothing'});
    expect(await l.flush(), 0);
    expect(l.recentDump(), isEmpty);
    l.setEnabled(true);
    l.log('ui', 'tap', {'target': 'ctl-left'});
    l.setEnabled(false);
    l.log('ui', 'tap', {'target': 'dropped'});
    await l.dispose();
    expect(lines(current(l)).map((r) => '${r['cat']}.${r['evt']}'), ['log.enabled', 'ui.tap', 'log.disabled']);
  });

  test('logging never throws: unopenable directory, odd values', () async {
    final l = AnalyticsLogger();
    final blocker = File('${tmp.path}${Platform.pathSeparator}notadir');
    await blocker.writeAsString('x');
    await l.init(directory: Directory(blocker.path));
    expect(l.currentFilePath, isNull);
    expect(() => l.log('x', 'y', {'obj': Object(), 'nested': {'deep': [1, 2, 3]}}), returnsNormally);
    expect(await l.flush(), 0);
    expect(l.recentDump().single['evt'], 'y');
  });

  test('recentDump keeps the last 500 in order, with monotonic mono', () {
    final l = AnalyticsLogger();
    for (var i = 0; i < 620; i++) {
      l.log('t', 'e', {'i': i});
    }
    final dump = l.recentDump().toList();
    expect(dump.length, AnalyticsLogger.ringSize);
    expect((dump.first['data'] as Map)['i'], 120);
    expect((dump.last['data'] as Map)['i'], 619);
    var last = -1;
    for (final e in dump) {
      expect(e['mono'] as int, greaterThanOrEqualTo(last));
      last = e['mono'] as int;
    }
  });

  test('values are capped: long strings, long lists, enums by name', () {
    final l = AnalyticsLogger();
    l.log('t', 'e', {
      'long': 'a' * 300,
      'list': List.generate(30, (i) => i),
      'enum': ListEnum.second,
      'ok': 'short',
    });
    final data = l.recentDump().single['data'] as Map;
    expect((data['long'] as String).length, AnalyticsLogger.maxStringLength + 1);
    expect((data['list'] as List).length, AnalyticsLogger.maxListLength);
    expect(data['truncated'], isTrue);
    expect(data['enum'], 'second');
    expect(data['ok'], 'short');
  });

  test('start new capture rotates now and the new file opens with log.capture_started', () async {
    final l = AnalyticsLogger();
    await l.init(directory: tmp);
    l.log('ui', 'tap', {'target': 'before'});
    await l.startCapture(label: 'repro-1');
    l.log('ui', 'tap', {'target': 'after'});
    await l.dispose();
    final fresh = lines(current(l));
    expect(fresh.first['evt'], 'capture_started');
    expect((fresh.first['data'] as Map)['label'], 'repro-1');
    expect(fresh.map((r) => r['evt']), ['capture_started', 'tap']);
    final older = lines(File(l.currentFilePath!.replaceFirst('opendash.jsonl', 'opendash.1.jsonl')));
    expect((older.single['data'] as Map)['target'], 'before');
  });

  test('listeners hear every accepted event and cannot break logging', () {
    final l = AnalyticsLogger();
    final heard = <String>[];
    l.listeners.add((cat, evt, data) => heard.add('$cat.$evt'));
    l.listeners.add((_, _, _) => throw StateError('boom'));
    l.log('modal', 'show', {'name': 'auto_park'});
    expect(heard, ['modal.show']);
    expect(l.recentDump().length, 1);
  });
}
