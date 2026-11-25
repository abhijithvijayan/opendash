import 'dart:async';

import 'package:opendash/state/access_state.dart';
import 'package:opendash/state/auto_brightness.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/theme_state.dart';

/// Time-based theme switching and auto brightness are on by default, so
/// every test would otherwise look different after dark. Noon unless a
/// test pins its own.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  AutoThemeScheduler.clock = () => DateTime(2026, 1, 1, 12);
  AutoBrightness.clock = () => DateTime(2026, 1, 1, 12);
  RidingFeature.debugDefaults = const {RidingFeature.autoBrightness: false};
  AccessNotifier.debugAskAfterUnlock = false;
  await testMain();
}
