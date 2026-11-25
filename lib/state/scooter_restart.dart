import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vehicle_data.dart';
import '../providers/mock_provider.dart';
import '../services/analytics_logger.dart';
import '../services/recovery_service.dart';
import 'passcode_gate.dart';
import 'prompt_surface.dart';
import 'riding_lockout.dart';
import 'toast_state.dart';

bool hasLiveVehicleData(VehicleData v) => v.hhmisKnown;

/// Stock: "Ensure scooter is in park to reboot", and no restart while
/// charging. A charger can be plugged in while HHMIS still says PARK (switched
/// off, or before charging starts), so the charge mode and charging flags
/// count too. Needs live data: these are the checks we can actually make.
bool canRestartScooter(VehicleData v) =>
    hasLiveVehicleData(v) &&
    v.provenStopped &&
    !v.locked &&
    v.vehicleState == VehicleState.parked &&
    !v.isCharging &&
    !v.chargerCharging &&
    v.chargingState != ChargingState.charging &&
    v.chargingState != ChargingState.initializing;

/// Without live data the dashboard is likely the thing that's stuck, which is
/// when a restart is most wanted; the rider vouches for park instead.
bool restartAvailable(VehicleData v) => !hasLiveVehicleData(v) || canRestartScooter(v);

/// Why the button is off, for the toast.
String restartBlockedReason(VehicleData v) {
  if (v.isCharging || v.chargerCharging || v.chargingState == ChargingState.charging || v.chargingState == ChargingState.initializing) {
    return 'Unplug the charger to restart';
  }
  if (v.speed == 0 && v.speedUntrustedReason != null) return untrustedDataMessage;
  return 'Park the scooter to restart';
}

/// The confirmation shown after the passcode; null while closed.
class RestartConfirm {
  const RestartConfirm({required this.liveData, required this.secondsLeft, required this.from});

  /// False: the dashboard can't see the scooter, so it can't check park and
  /// the charger; the dialog asks the rider to.
  final bool liveData;
  final int secondsLeft;
  final String from;

  RestartConfirm tick() => RestartConfirm(liveData: liveData, secondsLeft: secondsLeft - 1, from: from);
}

final scooterRestartProvider = NotifierProvider<ScooterRestart, RestartConfirm?>(ScooterRestart.new);

/// Stock's Settings → Reboot Scooter, reachable from the control panel and
/// Settings → Vehicle. Passcode first (stops a mis-tap), then an explicit
/// Restart tap on a dialog that cancels itself; nothing restarts on a timer.
///
/// With live data the scooter must be parked and unplugged, and the restart
/// is stock's ClientCmd 23 only (whole scooter). Without live data the rider
/// confirms park; HHMIS gets ClientCmd 23 if it is bound, and if it refuses or
/// is gone the head unit reboots, which is the fix for a stuck dashboard.
/// Unlike stock, no clearing of the data aggregator's / cloud connector's
/// cached data.
class ScooterRestart extends Notifier<RestartConfirm?> {
  static const confirmFor = 10;
  Timer? _countdown;

  @override
  RestartConfirm? build() {
    ref.onDispose(() => _countdown?.cancel());
    // A dialog that said "parked and unplugged, checked" must not outlive the
    // data it checked. Asking again offers the rider-vouches restart.
    ref.listen(vehicleProvider.select((v) => v.provenStopped), (_, stopped) {
      final pending = state;
      if (stopped || pending == null || !pending.liveData) return;
      final v = ref.read(vehicleProvider);
      if (v.speed == 0) untrustedCancel(ref, v, 'restart_confirm');
      cancel(v.speed > 0 ? 'moving' : 'untrusted');
    });
    // Both dialogs: the rider-vouches one too has nobody vouching behind
    // another app.
    onOwnScreenLost(ref, () {
      if (state == null) return;
      untrustedCancel(ref, ref.read(vehicleProvider), 'restart_confirm', ownScreen: true);
      cancel(noPromptSurfaceReason);
    });
    return null;
  }

  void request(String from) {
    final v = ref.read(vehicleProvider);
    if (!restartAvailable(v)) return _blocked(from, v);
    logEvent('recovery', 'restart_requested', {'from': from, 'live_data': hasLiveVehicleData(v)});
    ref.read(passcodeGateProvider.notifier).request(
      purpose: 'Enter passcode to restart the scooter',
      onSuccess: () => _openConfirm(from),
      allowUnknown: true,
    );
  }

  void _openConfirm(String from) {
    final v = ref.read(vehicleProvider);
    if (!restartAvailable(v)) return _blocked(from, v);
    logModalShow('restart_confirm', reason: from);
    state = RestartConfirm(liveData: hasLiveVehicleData(v), secondsLeft: confirmFor, from: from);
    _countdown?.cancel();
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
      final s = state;
      if (s == null) return;
      if (s.secondsLeft <= 1) return cancel('timeout');
      state = s.tick();
    });
  }

  void cancel([String reason = 'user']) {
    _countdown?.cancel();
    _countdown = null;
    if (state == null) return;
    logModalDismiss('restart_confirm', reason: reason);
    state = null;
  }

  Future<void> confirm() async {
    final pending = state;
    if (pending == null) return;
    _countdown?.cancel();
    _countdown = null;
    state = null;
    logModalDismiss('restart_confirm', reason: 'restart');
    // Re-checked at the tap: the rider may have plugged in, or data may have
    // come back, while the dialog was up.
    final v = ref.read(vehicleProvider);
    final live = hasLiveVehicleData(v);
    if (live && !canRestartScooter(v)) return _blocked(pending.from, v);
    if (!ref.read(ownScreenVisibleProvider)) return untrustedCancel(ref, v, 'restart_confirm', ownScreen: true);
    final toast = ref.read(toastProvider.notifier);
    toast.show('Restarting the scooter. This takes about a minute');
    if (v.hhmisConnected && await ref.read(vehicleProvider.notifier).rebootScooter()) return;
    if (live) {
      toast.show("Couldn't restart the scooter", type: ToastType.warning);
      return;
    }
    if (!await recoveryService.rebootHeadUnit(from: pending.from)) {
      toast.show("Couldn't restart the scooter", type: ToastType.warning);
    }
  }

  void _blocked(String from, VehicleData v) {
    logEvent('recovery', 'restart_blocked', {'from': from, 'reason': restartBlockedReason(v)});
    ref.read(toastProvider.notifier).show(restartBlockedReason(v), type: ToastType.warning);
  }
}
