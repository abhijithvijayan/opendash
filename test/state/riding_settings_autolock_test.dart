import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(PrefsService.resetForTest);

  test('auto-lock switched on before it was hidden is not restored at start', () async {
    SharedPreferences.setMockInitialValues({
      'flutter.${PrefsKeys.riding}': jsonEncode({'autoLockEnabled': true, 'speedLimit': 60}),
    });
    await PrefsService.init();
    final s = RidingSettings.fromPrefs();
    expect(s.autoLockEnabled, isFalse);
    expect(s.speedLimit, 60, reason: 'the rest of the blob still loads');
  });
}
