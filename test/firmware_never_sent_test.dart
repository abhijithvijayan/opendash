import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'helpers/stock.dart';

/// OpenDash never consents to a firmware download or install, and never
/// acts on one in HOTA. These fail if a send path for any of it appears.
/// Commands go by stock name; their numbers and the transaction codes are
/// in the recorded builds (`contracts/*.json`).
void main() {
  const kotlin = 'android/app/src/main/kotlin/in/abhijithvijayan/opendash';
  final proxy = File('$kotlin/hhmis/HhmisProxy.kt').readAsStringSync();
  final contract = File('$kotlin/hhmis/StockContract.kt').readAsStringSync();
  final service = File('$kotlin/hhmis/HhmisService.kt').readAsStringSync();
  final channel = File('$kotlin/VehicleChannel.kt').readAsStringSync();

  /// Code only: comments may, and do, name what is never sent.
  String code(String source) => source.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

  const neverSentNames = {
    'BOOL_INSTALL_ERROR_STAT': 1,
    'VOID_CANCEL_DOWNLOAD': 20,
    'VOID_CHECK_INSTALL_ERROR_STAT': 22,
    'VOID_RETRY_DOWNLOAD': 24,
  };

  group('HHMIS transactions 8, 9 and 10 (download, install, notice shown)', () {
    test('the proxy has no transaction constant for them', () {
      final codes = RegExp(r'const val TX_\w+ = (\d+)').allMatches(code(proxy)).map((m) => int.parse(m.group(1)!)).toSet();
      expect(codes, isNotEmpty);
      for (final tx in [8, 9, 10]) {
        expect(codes, isNot(contains(tx)), reason: 'transaction $tx must never be sent');
      }
      expect(codes, contains(5), reason: 'the passive subscription');
    });

    test('every transact call uses a named constant, so none can hide as a literal', () {
      final calls = RegExp(r'transact\(([^,]+),').allMatches(code(proxy)).map((m) => m.group(1)!.trim()).toSet();
      expect(calls.where((c) => !c.startsWith('TX_') && c != 'code' && c != 'code: Int'), isEmpty);
      expect(calls.where((c) => c.startsWith('TX_')), isNotEmpty);
    });

    test('no method by those names exists in any Kotlin source', () {
      for (final file in Directory(kotlin).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.kt'))) {
        // The recorded lists name every stock call and its code; nothing in
        // that file sends anything.
        if (file.path.endsWith('StockFixtures.kt')) continue;
        final source = code(file.readAsStringSync());
        if (file.path.contains('/hhmis/')) {
          expect(RegExp(r'fun (download|install)\s*\(').hasMatch(source), isFalse, reason: file.path);
        }
        expect(source.contains('triggerReceviedOnHMI'), isFalse, reason: file.path);
      }
    });
  });

  group('ClientCmds 1, 20, 22 and 24', () {
    test('they have those numbers on every recorded build, and "check" is 21', () {
      final fixtures = Directory('contracts').listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
      expect(fixtures, isNotEmpty);
      for (final file in fixtures) {
        final commands = ((jsonDecode(file.readAsStringSync()) as Map)['commands'] as List).cast<String>();
        for (final MapEntry(key: name, value: ordinal) in neverSentNames.entries) {
          expect(commands.indexOf(name), ordinal, reason: '$name in ${file.path}');
        }
        expect(commands.indexOf('VOID_CHECK_FOR_UPDATE'), 21, reason: file.path);
        expect(commands, contains('AUTODOWNLOAD_UPDATE'), reason: file.path);
      }
    });

    test('the Kotlin never-sent set is exactly those four, and Dart agrees', () {
      final block = RegExp(r'val NEVER_SENT = setOf\(([^)]*)\)').firstMatch(contract)!.group(1)!;
      final names = RegExp(r'[A-Z_]{4,}').allMatches(block).map((m) => m.group(0)!).toSet();
      expect(names, neverSentNames.keys.toSet());
      expect(HhmisCmd.neverSent, neverSentNames.keys.toSet());
    });

    test('the channel refuses them before any command is sent, and so does the one send path', () {
      final refusal = channel.substring(channel.indexOf('private fun refused('), channel.indexOf('private fun sent('));
      expect(refusal, contains('cmd !in StockContract.NEVER_SENT'));
      expect(refusal, contains('return true'));
      final sends = RegExp(r'override fun send(Void|Bool|Int|String)\([^)]*\) =\s*\n\s*(.*)').allMatches(channel).toList();
      expect(sends, hasLength(4));
      for (final m in sends) {
        final body = m.group(2)!;
        expect(body, startsWith('!refused(cmd, '), reason: m.group(1));
        expect(body.indexOf('!refused('), lessThan(body.indexOf('service.send(')), reason: m.group(1));
      }
      final send = service.substring(service.indexOf('fun send(name: String'));
      expect(send.indexOf('name in StockContract.NEVER_SENT'), greaterThan(0));
      expect(send.indexOf('name in StockContract.NEVER_SENT'), lessThan(send.indexOf('command { block(number) }')));
    });

    test('every numbered command leaves Kotlin through that one send path', () {
      for (final file in Directory(kotlin).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.kt'))) {
        final source = code(file.readAsStringSync());
        for (final call in ['voidCmd(', 'intCmd(', 'boolCmd(', 'stringCmd(']) {
          for (final line in source.split('\n').where((l) => l.contains(call) && !l.contains('fun '))) {
            expect(line, contains('service.send('), reason: '${file.path}: $line');
          }
        }
      }
    });

    test('no Kotlin source names them outside the never-sent set and the recorded lists', () {
      for (final file in Directory(kotlin).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.kt'))) {
        if (file.path.endsWith('StockFixtures.kt')) continue;
        var source = code(file.readAsStringSync());
        if (file.path.endsWith('StockContract.kt')) {
          source = source.replaceAll(RegExp(r'val NEVER_SENT = setOf\([^)]*\)'), '');
        }
        for (final name in neverSentNames.keys) {
          expect(source.contains(name), isFalse, reason: '$name in ${file.path}');
        }
      }
    });

    test('"check for update" has one way out in Kotlin: the "Check now" method', () {
      final uses = <String>[];
      for (final file in Directory(kotlin).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.kt'))) {
        if (file.path.endsWith('StockFixtures.kt')) continue;
        final lines = code(file.readAsStringSync()).split('\n');
        uses.addAll(lines.where((l) => l.contains('CHECK_FOR_UPDATE') && !l.contains('const val')));
      }
      expect(uses, hasLength(2), reason: 'the generic-path refusal and the one send');
      expect(uses.where((l) => l.contains('override fun checkFirmwareUpdate()')), hasLength(1));
      expect(uses.where((l) => l.contains('cmd != StockContract.CHECK_FOR_UPDATE) return false')), hasLength(1));
    });

    test('Dart: none is sendable through any method, and "check" not through the generic one', () {
      for (final method in ['sendVoidCmd', 'sendIntCmd', 'sendBoolCmd', 'sendStringCmd', 'checkFirmwareUpdate']) {
        for (final cmd in [...neverSentNames.keys, 'VOID_CHECK_FOR_UPDATE']) {
          expect(HhmisCmd.sendable(method, cmd), isFalse, reason: '$method $cmd');
        }
      }
      expect(HhmisCmd.sendable('sendIntCmd', HhmisCmd.autoDownloadUpdate), isTrue);
      expect(HhmisCmd.sendable('checkFirmwareUpdate', null), isTrue);
    });

    test('Dart: no lib source sends a number for a command, or names a never-sent one outside the refusal', () {
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        var source = file.readAsStringSync();
        expect(RegExp(r"'cmd':\s*\d").hasMatch(source), isFalse, reason: file.path);
        source = source.replaceAll(RegExp(r'static const neverSent = \{[^}]*\};'), '');
        for (final name in neverSentNames.keys) {
          expect(source.contains("'$name'"), isFalse, reason: '$name in ${file.path}');
        }
      }
    });

    test('Dart: the names of the never-sent commands are not constants of HhmisCmd', () {
      final provider = File('lib/providers/vehicle_provider.dart').readAsStringSync();
      final body = provider.substring(provider.indexOf('abstract final class HhmisCmd'), provider.indexOf('static const names'));
      for (final word in ['cancelDownload', 'retryDownload', 'installError', 'InstallError']) {
        expect(body.contains(word), isFalse, reason: word);
      }
      expect(RegExp(r'HhmisCmd\.checkForUpdate').allMatches(provider), hasLength(2),
          reason: 'the hold in _invoke, which sends nothing, and the "Check now" send');
    });

    test('the bridge drops a never-sent command without invoking the channel', () {
      fakeAsync((async) {
        AnalyticsLogger.instance.resetForTest();
        final events = StreamController<dynamic>();
        final calls = <(String, Object?)>[];
        final c = ProviderContainer(overrides: [
          vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), 
                events: events.stream,
                invoke: (m, a) async {
                  calls.add((m, a));
                  return true;
                },
              )),
        ]);
        final n = c.read(vehicleProvider.notifier) as AidlVehicleNotifier;
        for (final cmd in [...neverSentNames.keys, 'VOID_CHECK_FOR_UPDATE']) {
          n.debugSend('sendVoidCmd', {'cmd': cmd});
          n.debugSend('sendIntCmd', {'cmd': cmd, 'value': 1});
          n.debugSend('sendBoolCmd', {'cmd': cmd, 'value': true});
        }
        async.flushMicrotasks();
        expect(calls.where((c) => c.$1.startsWith('send')), isEmpty);
        expect(AnalyticsLogger.instance.recent('hhmis', 'cmd_refused'), hasLength(15));
        expect(AnalyticsLogger.instance.recent('hhmis', 'cmd_send'), isEmpty);

        n.checkFirmwareUpdate();
        async.flushMicrotasks();
        expect(calls.single.$1, 'checkFirmwareUpdate');
        expect(AnalyticsLogger.instance.recent('hhmis', 'cmd_send').single['data'], containsPair('cmd', 'VOID_CHECK_FOR_UPDATE'));
        c.dispose();
        events.close();
      });
    });
  });
}
