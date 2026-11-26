import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vehicle_data.dart';
import '../providers/mock_provider.dart';
import '../state/crash_recovery.dart';
import '../state/error_state.dart';
import '../state/media_state.dart';
import '../state/overlay_state.dart';
import '../state/riding_settings.dart';
import '../state/screen_state.dart';
import '../state/settings_state.dart';
import '../state/wifi_state.dart';
import 'analytics_logger.dart';

/// Logs every state-machine, screen and modal transition from one place,
/// by listening on the providers rather than patching each notifier, so a
/// widget rebuild can never double-fire. Installed once per container.
void installAnalyticsTransitions(ProviderContainer c) {
  bool standSensor() => c.read(ridingSettingsProvider).isOn(RidingFeature.sideStandCutOff);
  c.listen(vehicleProvider.select((v) => v.vehicleState), (prev, next) {
    final v = c.read(vehicleProvider);
    logEvent('state', 'vehicle_state', {
      'from': prev?.name,
      'to': next.name,
      'speed': v.speed,
      'locked': v.locked,
      'stand': v.sideStand,
      'stand_sensor': standSensor(),
    });
  });
  c.listen(vehicleProvider.select((v) => v.lockState), (prev, next) {
    logEvent('state', 'lock_change', {'from': prev, 'to': next});
  });
  c.listen(vehicleProvider.select((v) => v.driveMode), (prev, next) {
    logEvent('state', 'drive_mode', {'from': prev?.name, 'to': next.name});
  });
  c.listen(vehicleProvider.select((v) => v.reverse), (_, on) => logEvent('state', 'reverse', {'on': on}));
  c.listen(vehicleProvider.select((v) => v.limpMode), (_, on) => logEvent('state', 'limp_mode', {'on': on}));
  c.listen(vehicleProvider.select((v) => (v.isCharging, v.chargingState)), (_, next) {
    logEvent('state', 'charging', {'on': next.$1, 'state': next.$2.name});
  });
  c.listen(vehicleProvider.select((v) => v.sideStand), (_, down) {
    final v = c.read(vehicleProvider);
    logEvent('state', 'side_stand', {'down': down, 'state': v.vehicleState.name, 'speed': v.speed, 'stand_sensor': standSensor()});
  });
  c.listen(vehicleProvider.select((v) => v.hhmisConnected), (_, up) => logEvent('state', 'hhmis_connected', {'up': up}));

  var booted = false;
  c.listen(screenStateProvider, (prev, next) {
    final v = c.read(vehicleProvider);
    logEvent('ui', 'screen', {
      'from': prev?.name,
      'to': next.name,
      'trigger': _screenTrigger(prev, next, v),
      'state': v.vehicleState.name,
      'locked': v.locked,
      'charging': v.isCharging,
    });
    if (!booted && prev == ScreenState.booting && next != ScreenState.booting) {
      booted = true;
      bootMark('boot_complete');
    }
  });
  c.listen(overlayTitleProvider, (prev, next) => logEvent('ui', 'overlay', {'from': prev, 'to': next}));

  void modal(String name, bool Function(VehicleData v) pick) =>
      c.listen(vehicleProvider.select(pick), (_, on) => _logModal(name, on));
  modal('call_bar', (v) => v.callActive);
  modal('incoming_call', (v) => v.callIncoming);
  modal('bt_pairing', (v) => v.btPairingCode.isNotEmpty);
  c.listen(appErrorProvider.select((e) => e != null), (_, on) => _logModal('error_overlay', on));
  c.listen(crashRecoveryProvider.select((s) => s.safeMode), (_, on) => _logModal('safe_mode', on));
  c.listen(serviceModeOpenProvider, (_, on) => _logModal('service_mode', on));
  c.listen(sohPopupOpenProvider, (_, on) => _logModal('soh_popup', on));
  c.listen(chargeLimitPopupProvider, (_, on) => _logModal('charge_limit_popup', on));
  c.listen(tripResetProvider, (_, on) => _logModal('trip_reset_dialog', on));
  c.listen(changePasscodeOpenProvider, (_, on) => _logModal('change_passcode', on));
  c.listen(volumeOverlayProvider, (_, on) => _logModal('volume_overlay', on));
  c.listen(wifiDetailsOpenProvider, (_, on) => _logModal('wifi_details', on));
  c.listen(ridingSettingsProvider.select((r) => r.hillHoldPrompt), (_, on) => _logModal('hill_hold_prompt', on));
  c.listen(ridingSettingsProvider.select((r) => r.standBypassPrompt), (_, on) => _logModal('stand_bypass_prompt', on));
  c.listen(ridingSettingsProvider.select((r) => r.vacationPrompt), (_, on) => _logModal('vacation_prompt', on));
}

String _screenTrigger(ScreenState? prev, ScreenState next, VehicleData v) {
  if (prev == ScreenState.booting || next == ScreenState.booting) return 'session';
  if (prev == ScreenState.sleep || next == ScreenState.sleep) return 'sleep';
  if (prev == ScreenState.locked || next == ScreenState.locked) return 'lock';
  if (prev == ScreenState.charging || next == ScreenState.charging) return 'charging';
  return 'vehicle_state';
}

void _logModal(String name, bool on) {
  if (on) {
    logModalShow(name, reason: 'state_change');
  } else {
    logModalDismiss(name, reason: 'state_change');
  }
}
