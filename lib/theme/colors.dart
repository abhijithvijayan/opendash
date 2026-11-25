import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vehicle_data.dart';
import '../providers/mock_provider.dart';
import '../state/theme_state.dart';
import 'dash_theme.dart';

abstract final class DashColors {
  /// The palette every static token resolves against. Updated by the eased
  /// theme notifier; defaults to Dark so tests and painters work without a
  /// provider. Widgets that cache colours only pick up a change on their
  /// next build, which the root forces by remounting on a theme switch.
  static DashTheme current = DashTheme.dark;

  static Color get ink => current.ink;
  static Color get inkLift => current.inkLift;
  static Color get bone => current.bone;
  static Color get ash => current.ash;
  static Color get slate => current.slate;

  static Color get eco => current.eco;
  static Color get normal => current.normal;
  static Color get sport => current.sport;
  static Color get hyper => current.hyper;
  static Color get charging => current.charging;
  static Color get parked => current.parked;

  static Color get critical => current.critical;
  static Color get warning => current.warning;
  static Color get regen => bone;

  static Color forMode(DriveMode mode) => current.accentFor(mode);

  static Color accentFor(VehicleData v) => accentFrom(v, current);

  static Color accentFrom(VehicleData v, DashTheme t) =>
      accentOf(
        isCharging: v.isCharging,
        locked: v.locked,
        vehicleState: v.vehicleState,
        driveMode: v.driveMode,
        customRide: v.customRideActive,
        reverse: v.reverse,
        cruise: v.cruiseMode == CruiseMode.active,
        theme: t,
      );

  static Color accentOf({
    required bool isCharging,
    required bool locked,
    required VehicleState vehicleState,
    required DriveMode driveMode,
    bool customRide = false,
    bool reverse = false,
    bool cruise = false,
    required DashTheme theme,
  }) {
    if (isCharging) return theme.charging;
    if (locked) return theme.parked;
    // Reverse is none of the drive modes: the scooter reports "REVERSE" in
    // their place, and the mode remembered from before says nothing here.
    if (reverse) return theme.warning;
    if (vehicleState == VehicleState.parked) return theme.parked;
    if (cruise) return theme.eco;
    if (customRide) return theme.custom;
    return theme.accentFor(driveMode);
  }

  static Color batteryFill(int soc, Color accent) {
    if (soc < 10) return critical;
    // Stock's BATTERY_LOW is SOC <= 20 (BatteryInfoManager :4285).
    if (soc <= 20) return warning;
    return accent;
  }
}

/// The live mode accent, from the eased theme so theme switches blend.
final accentProvider = Provider<Color>((ref) {
  // Only these fields move the accent; the whole VehicleData changes at
  // 30Hz on a ride.
  final (charging, locked, state, mode, custom, reverse, cruise) = ref.watch(vehicleProvider.select((v) =>
      (v.isCharging, v.locked, v.vehicleState, v.driveMode, v.customRideActive, v.reverse, v.cruiseMode == CruiseMode.active)));
  return DashColors.accentOf(
    isCharging: charging,
    locked: locked,
    vehicleState: state,
    driveMode: mode,
    customRide: custom,
    reverse: reverse,
    cruise: cruise,
    theme: ref.watch(uiThemeProvider),
  );
});
