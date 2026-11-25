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
    // IOtaShieldService in declaration order: 0 isActivated,
    // 1 isFailsafeEngaged, 2 isBootFailsafeEnabled, 3 getActivationStep,
    // 4 getStatsReportJson, 5 getFotaLogsJson, 6 activateBlocker,
    // 7 deactivateBlocker, 8 disableFailsafe, 9 setBootFailsafeEnabled.
    final codes = RegExp(r'FIRST_CALL_TRANSACTION \+ (\d+)\n').allMatches(source).map((m) => int.parse(m[1]!)).toSet();
    expect(codes, {0, 1, 3, 6, 8});
    final sent = RegExp(r'call\([a-z]+, (TX_[A-Z_]+)').allMatches(source).map((m) => m[1]).toSet();
    expect(sent, {'TX_IS_ACTIVATED', 'TX_IS_FAILSAFE_ENGAGED', 'TX_GET_ACTIVATION_STEP', 'TX_ACTIVATE_BLOCKER', 'TX_DISABLE_FAILSAFE'});
    expect(RegExp(r'\.transact\(').allMatches(source).length, 1);
  });

  test('an offer\'s address and notes are not passed on', () {
    for (final field in ['"url"', '"releaseNotes"', '"topic"', '"assetId"']) {
      expect(source, isNot(contains('opt${field == '"assetId"' ? 'Long' : 'String'}($field')), reason: field);
    }
  });
}
