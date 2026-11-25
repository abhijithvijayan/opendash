import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// OpenDash reads OTA Shield and may only start its block or lift its boot
/// fail-safe: two questions on its control port, five calls to its service
/// (never deactivateBlocker or setBootFailsafeEnabled), and an offer's
/// download address and release notes never leave Kotlin.
void main() {
  final source = File('android/app/src/main/kotlin/in/abhijithvijayan/opendash/OtaShield.kt').readAsStringSync();

  test('only the two read commands are sent to its daemon', () {
    final sent = RegExp(r'ask\("([A-Z_]+)"\)').allMatches(source).map((m) => m[1]).toSet();
    expect(sent, {'GET_STATS', 'GET_FOTA_UPDATES'});
  });

  test('its service is sent only the reads, activate and turn off fail-safe', () {
    // IOtaShieldService, API version 2 (OTA Shield 1.1.0 on): 0 getApiVersion,
    // 1 isActivated, 2 isFailsafeEngaged, 3 isBootFailsafeEnabled,
    // 4 getActivationStep, 5 getStatsReportJson, 6 getFotaLogsJson,
    // 7 activateBlocker, 8 deactivateBlocker, 9 disableFailsafe,
    // 10 setBootFailsafeEnabled, 11 isDaemonRunning.
    final codes = RegExp(r'FIRST_CALL_TRANSACTION \+ (\d+)\n').allMatches(source).map((m) => int.parse(m[1]!)).toSet();
    expect(codes, {0, 1, 2, 4, 7, 9});
    expect(codes.intersection({8, 10}), isEmpty);
    final sent = RegExp(r'call\([a-z]+, (TX_[A-Z_]+)').allMatches(source).map((m) => m[1]).toSet();
    expect(sent, {'TX_GET_API_VERSION', 'TX_IS_ACTIVATED', 'TX_IS_FAILSAFE_ENGAGED', 'TX_GET_ACTIVATION_STEP', 'TX_ACTIVATE_BLOCKER', 'TX_DISABLE_FAILSAFE'});
    expect(RegExp(r'\.transact\(').allMatches(source).length, 1);
  });

  // 1.0.0 numbered from isActivated, so its 8 was disableFailsafe and
  // 1.1.0's 8 is deactivateBlocker: nothing but the version question may go
  // to a service before it has said 2 or later.
  test('nothing but the version question reaches a service that has not said API 2', () {
    expect(source, contains('private const val API = 2'));
    expect(source, contains('if (api >= API) binder else null'));
    final unchecked = RegExp(r'\bbound\(context\)').allMatches(source).length;
    expect(unchecked, 1, reason: 'bound() is called only inside compatible()');
    expect(RegExp(r'compatible\(context\)').allMatches(source).length, 3);
  });

  test('an offer\'s address and notes are not passed on', () {
    for (final field in ['"url"', '"releaseNotes"', '"topic"', '"assetId"']) {
      expect(source, isNot(contains('opt${field == '"assetId"' ? 'Long' : 'String'}($field')), reason: field);
    }
  });
}
