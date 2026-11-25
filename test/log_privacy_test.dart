import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/services/log_privacy.dart';

/// A pulled log is passed on, so it must not single out a person, a
/// household or a place.
void main() {
  test('a DNS server keeps what names the provider, not the line', () {
    expect(LogPrivacy.dnsServer('192.168.1.1'), '192.168.1.1');
    expect(LogPrivacy.dnsServer('203.0.113.6'), '203.0.113.6');
    expect(LogPrivacy.dnsServer('2001:db8:800::6'), '2001:db8::');
    expect(LogPrivacy.dnsServer('2001:db8:1234:5678:9abc:def0:1234:5678'), '2001:db8::');
  });

  test('a private DNS name loses a label that can be an account\'s own', () {
    expect(LogPrivacy.privateDns('abc123.dns.example.io'), '*.dns.example.io');
    expect(LogPrivacy.privateDns('one.one.one.one'), '*.one.one.one');
    expect(LogPrivacy.privateDns('dns.google'), 'dns.google');
    expect(LogPrivacy.privateDns('off'), 'off');
    expect(LogPrivacy.privateDns('auto'), 'auto');
    expect(LogPrivacy.privateDns(null), isNull);
  });

  test('a network keeps every other fact', () {
    final out = LogPrivacy.networks([
      {'transport': 'mobile', 'validated': true, 'mtu': 1500, 'dns': ['2001:db8:800::6', '203.0.113.6'], 'private_dns': 'abc123.dns.example.io'},
    ]).single as Map;
    expect(out, {'transport': 'mobile', 'validated': true, 'mtu': 1500, 'dns': ['2001:db8::', '203.0.113.6'], 'private_dns': '*.dns.example.io'});
  });

  test('sunrise and sunset are written to the quarter hour', () {
    expect(LogPrivacy.sunTime('2026-11-16 17:52:10'), '2026-11-16 17:45');
    expect(LogPrivacy.sunTime('2026-11-16 06:22:31'), '2026-11-16 06:15');
    expect(LogPrivacy.sunTime('garbage'), 'unreadable');
    expect(LogPrivacy.sunTime(null), isNull);
  });

  test('every place that logs a network list or a sun time goes through the rule', () {
    final dart = [
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')))
        (f.path, f.readAsStringSync()),
    ];
    for (final (path, source) in dart) {
      for (final m in RegExp(r"logEvent\('net', '\w+', \{[^}]*'networks': ([^}\n]+)\}").allMatches(source)) {
        expect(m.group(1), startsWith('LogPrivacy.networks('), reason: path);
      }
      for (final m in RegExp(r"'(sunrise|sunset)': ([^,\n]+),").allMatches(source)) {
        if (path.endsWith('vehicle_provider.dart')) expect(m.group(2), startsWith('LogPrivacy.sunTime('), reason: path);
      }
    }
    final net = File('android/app/src/main/kotlin/in/abhijithvijayan/opendash/Net.kt').readAsStringSync();
    expect(RegExp(r'Analytics\.log\("net", "state", mapOf\("networks" to state\.map\(::forLog\)\)\)').hasMatch(net), isTrue);
    expect(RegExp(r'"networks" to state\)').hasMatch(net), isFalse);
  });
}
