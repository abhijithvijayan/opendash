import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/models/scooter_model.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/build_info.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:opendash/services/trusted_clock.dart';
import 'package:opendash/state/usage_ping.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('isoWeek', () {
    test('mid-year and year edges', () {
      expect(isoWeek(DateTime(2026, 11, 25)), '2026-W48');
      expect(isoWeek(DateTime(2027, 1, 1)), '2026-W53');
      expect(isoWeek(DateTime(2024, 12, 30)), '2025-W01');
      expect(isoWeek(DateTime(2026, 1, 1)), '2026-W01');
    });
  });

  group('payload', () {
    test('says only what is published, and nothing that tells scooters apart', () {
      BuildInfo.number = 1612;
      addTearDown(() => BuildInfo.number = null);
      final p = usagePayload(
        week: '2026-W48',
        isNew: true,
        v: const VehicleData(hhmisBacked: true, vehicleType: 3, moveOsVersion: '4.6.14'),
        software: const StockIdentity(version: '4.6.14', source: StockIdentity.sourceRead, name: 'gen1-moveos4-hhmis-4.6.14'),
        android: '10',
      );
      expect(p.keys.toSet(), {'v', 'week', 'new', 'app', 'build', 'gen', 'model', 'moveos', 'stock', 'android'});
      expect(p, containsPair('android', '10'));
      expect(p, containsPair('gen', '1'));
      expect(p, containsPair('model', 'S1 Pro'));
      expect(p, containsPair('build', 1612));
      expect(p, containsPair('stock', '4.6.14'));
    });

    test('nothing about the scooter before the stock service has spoken', () {
      final p = usagePayload(week: '2026-W48', isNew: false, v: const VehicleData(vehicleType: 3), android: '10');
      expect([p['gen'], p['model'], p['moveos'], p['stock']], ['', '', '', '']);
    });
  });

  group('sending', () {
    late ProviderContainer container;
    late MockPlatformService platform;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await PrefsService.init();
      AnalyticsLogger.instance.resetForTest();
      TrustedClock.resetForTest();
      TrustedClock.wall = () => DateTime(2026, 11, 25, 9);
      UsagePing.sendsHere = () => true;
      platform = MockPlatformService();
      backed = true;
      container = ProviderContainer(overrides: [
        platformServiceProvider.overrideWithValue(platform),
        vehicleProvider.overrideWith(_Scooter.new),
      ]);
    });

    tearDown(() {
      container.dispose();
      PrefsService.resetForTest();
      TrustedClock.resetForTest();
      UsagePing.sendsHere = () => false;
    });

    UsagePing ping() {
      container.read(usagePingProvider);
      return container.read(usagePingProvider.notifier);
    }

    List<Map<String, Object?>> sent() => [for (final b in platform.usagePings) jsonDecode(b) as Map<String, Object?>];

    test('carries the head unit\'s Android version', () async {
      await ping().sendIfDue();
      expect(sent().single['android'], platform.deviceInfo()['release']);
      expect(sent().single['android'], isNotEmpty);
    });

    test('once a week; the first one marks the install', () async {
      await ping().sendIfDue();
      await ping().sendIfDue();
      TrustedClock.wall = () => DateTime(2026, 12, 2, 9);
      await ping().sendIfDue();
      expect(sent().map((p) => (p['week'], p['new'])), [('2026-W48', true), ('2026-W49', false)]);
    });

    test('a failed send is tried again and still counts the install', () async {
      platform.usagePingStatus = 0;
      await ping().sendIfDue();
      platform.usagePingStatus = 204;
      await ping().sendIfDue();
      expect(sent().map((p) => p['new']), [true, true]);
      expect(AnalyticsLogger.instance.recent('usage', 'ping').map((e) => (e['data'] as Map)['ok']), [false, true]);
    });

    test('nothing while the clock cannot be trusted', () async {
      TrustedClock.debugSetLastGood(DateTime(2026, 11, 25, 10));
      TrustedClock.wall = () => DateTime(2024, 3, 1);
      await ping().sendIfDue();
      expect(platform.usagePings, isEmpty);
    });

    test('nothing once turned off, and it stays off', () async {
      ping().set(false);
      await ping().sendIfDue();
      expect(platform.usagePings, isEmpty);
      expect(PrefsService.getBool(PrefsKeys.usagePing, true), isFalse);
    });

    test('nothing before the stock service has answered: an emulator or a broken install is not counted', () async {
      backed = false;
      await ping().sendIfDue();
      expect(platform.usagePings, isEmpty);
      backed = true;
      container.invalidate(vehicleProvider);
      await ping().sendIfDue();
      expect(platform.usagePings, hasLength(1));
    });

    test('nothing off a real scooter', () async {
      UsagePing.sendsHere = () => false;
      await ping().sendIfDue();
      expect(platform.usagePings, isEmpty);
    });
  });

  test('the request carries no header but the app name', () {
    final source = File('android/app/src/main/kotlin/in/abhijithvijayan/opendash/UsagePing.kt').readAsStringSync();
    expect(RegExp(r'\.header\("([^"]+)"').allMatches(source).map((m) => m[1]).toList(), ['User-Agent']);
  });
}

/// Whether the mock's data reads as having come from the scooter's service.
bool backed = true;

class _Scooter extends VehicleNotifier {
  @override
  VehicleData build() => super.build().copyWith(hhmisBacked: backed);
}
