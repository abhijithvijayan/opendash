import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'apps_state.dart';
import 'crash_recovery.dart';
import 'media_state.dart';
import 'ota_state.dart';
import 'riding_lockout.dart';
import 'settings_state.dart';

/// Title of the topmost full-screen overlay, or null on the dashboard.
/// Children of settings win over settings itself, which stays mounted
/// underneath them.
final overlayTitleProvider = Provider<String?>((ref) {
  if (ref.watch(licensesScreenOpenProvider)) return 'Licenses';
  if (ref.watch(otaScreenOpenProvider)) return 'Updates';
  if (ref.watch(btScreenOpenProvider)) return 'Bluetooth Devices';
  if (ref.watch(diagnosticsOpenProvider)) return 'Diagnostics';
  if (ref.watch(appLauncherOpenProvider)) return 'Apps';
  if (ref.watch(settingsScreenOpenProvider)) return 'Settings';
  return null;
});

/// A moving scooter keeps the full status bar (turn signals, beams) and its
/// warnings, so the toolbar only stands in while stopped. Every overlay
/// closes on the lockout; an OTA install is the one that outlives it.
final overlayToolbarVisibleProvider = Provider<bool>((ref) =>
    ref.watch(overlayTitleProvider) != null &&
    !ref.watch(ridingLockoutProvider) &&
    // During a Diagnostics ride the island is the readout; the back-arrow bar
    // stays hidden so it does not flash in on every stop.
    !ref.watch(diagnosticsRidingProvider));

/// Closes whatever the toolbar is titled for. An OTA install refuses to
/// close, which is why the result says whether anything happened.
bool closeTopOverlay(WidgetRef ref) {
  if (ref.read(licensesScreenOpenProvider)) {
    ref.read(licensesScreenOpenProvider.notifier).close();
  } else if (ref.read(otaScreenOpenProvider)) {
    if (ref.read(otaProvider).status == OtaStatus.installing) return false;
    ref.read(otaScreenOpenProvider.notifier).close();
  } else if (ref.read(btScreenOpenProvider)) {
    ref.read(btScreenOpenProvider.notifier).close();
  } else if (ref.read(diagnosticsOpenProvider)) {
    ref.read(diagnosticsOpenProvider.notifier).close();
  } else if (ref.read(appLauncherOpenProvider)) {
    ref.read(appLauncherOpenProvider.notifier).close();
  } else if (ref.read(settingsScreenOpenProvider)) {
    ref.read(settingsScreenOpenProvider.notifier).close();
  } else {
    return false;
  }
  return true;
}

final statusBarPeekProvider = NotifierProvider<StatusBarPeek, bool>(StatusBarPeek.new);

/// A pull-down on the toolbar shows the full status bar over it for
/// [duration]; a tap anywhere else, or the overlay closing, ends it early.
class StatusBarPeek extends Notifier<bool> {
  static const duration = Duration(seconds: 3);
  Timer? _timer;

  @override
  bool build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen(overlayToolbarVisibleProvider, (_, open) {
      if (!open) hide();
    });
    return false;
  }

  void peek() {
    _timer?.cancel();
    state = true;
    _timer = Timer(duration, hide);
  }

  void hide() {
    _timer?.cancel();
    _timer = null;
    if (state) state = false;
  }
}
