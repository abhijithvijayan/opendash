import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vehicle_data.dart';
import '../providers/mock_provider.dart';
import '../services/analytics_logger.dart';
import 'prompt_surface.dart';
import 'screen_state.dart';
import 'toast_state.dart';

const untrustedDataMessage = 'Vehicle data not reliable';

/// The rider tapped "Continue without vehicle data" at boot and HHMIS has
/// still not answered. Nothing can be proven then, and Settings / Recovery
/// are what fixes it, so their word stands in for the data. Once HHMIS has
/// connected the flag is gone for good: a link that drops later is unknown.
bool noDataVouched(Ref ref) =>
    ref.read(sessionProvider).noData && !ref.read(vehicleProvider).hhmisConnected;

/// True while the scooter is moving or can't be shown to be stopped.
/// Anything that needs eyes off the road (settings, pairing, text entry,
/// lock, trunk, reverse) hides behind this.
///
/// A speed above zero engages it at once. Data that stops being trustworthy
/// (stale, disconnected, speed and rpm disagreeing) engages it after
/// [grace], so an HHMIS hiccup does not throw the rider out of a screen.
final ridingLockoutProvider = NotifierProvider<RidingLockout, bool>(RidingLockout.new);

class RidingLockout extends Notifier<bool> {
  static const grace = Duration(seconds: 2);
  Timer? _grace;

  @override
  bool build() {
    ref.onDispose(() => _grace?.cancel());
    ref.listen(vehicleProvider.select((v) => (v.speed > 0, v.speedTrusted, v.hhmisConnected)), (_, _) => _update());
    ref.listen(sessionProvider.select((s) => s.noData), (_, _) => _update());
    return ref.read(vehicleProvider).speed > 0 || _unknown;
  }

  bool get _unknown => !ref.read(vehicleProvider).speedTrusted && !noDataVouched(ref);

  void _update() {
    final moving = ref.read(vehicleProvider).speed > 0;
    if (moving || !_unknown) {
      _grace?.cancel();
      _grace = null;
      if (state != moving) state = moving;
      return;
    }
    if (state) return;
    _grace ??= Timer(grace, () {
      _grace = null;
      state = true;
    });
  }
}

/// For an action that is only safe at a standstill: true (with a toast) when
/// [v] does not prove one. [vouched] is [noDataVouched], for the recovery
/// actions that must work with no data at all. Nothing is vouched for, or
/// done, with no surface showing ([promptSurfaceVisibleProvider]): a
/// callback that lands behind another app is not the rider's tap.
bool refuseUnlessStopped(Ref ref, VehicleData v, String flow, String movingMessage, {bool vouched = false}) {
  final seen = ref.read(promptSurfaceVisibleProvider) || islandTapInHand;
  if (seen && (v.provenStopped || (vouched && v.speed == 0))) return false;
  final reason = v.speed > 0
      ? null
      : seen
          ? v.speedUntrustedReason
          : noPromptSurfaceReason;
  if (reason != null) logEvent('safety', 'untrusted_refused', {'flow': flow, 'reason': reason});
  if (seen) {
    ref.read(toastProvider.notifier).show(reason == null ? movingMessage : untrustedDataMessage, type: ToastType.warning);
  }
  return true;
}

/// A pending or counting-down action was dropped because the data behind it
/// stopped being trustworthy, or because no surface is left to show it on
/// (reason `background`; no toast, there is nowhere to read it). [ownScreen]
/// is for the prompts the island cannot host.
void untrustedCancel(Ref ref, VehicleData v, String flow, {bool ownScreen = false}) {
  final seen = ref.read(ownScreen ? ownScreenVisibleProvider : promptSurfaceVisibleProvider);
  logEvent('safety', 'untrusted_cancel', {
    'flow': flow,
    'reason': seen ? v.speedUntrustedReason ?? 'unknown' : noPromptSurfaceReason,
  });
  if (seen) ref.read(toastProvider.notifier).show(untrustedDataMessage, type: ToastType.warning);
}

/// Runs [fn] each time the lockout engages: what closes an eyes-off-road
/// screen. A notifier that sets its own state notifies at once, so unlike a
/// derived provider this cannot land after a later open().
void onRidingLockout(Ref ref, void Function() fn) {
  ref.listen(ridingLockoutProvider, (_, on) {
    if (on) fn();
  });
}
