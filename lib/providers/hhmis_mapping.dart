import '../models/vehicle_data.dart';

/// Folds one batch of HHMIS updates into [current]. Keys are `ServerCmd`
/// names (or `_`-prefixed bridge keys, see `HhmisService.kt`), values are
/// whatever the callback carried. Anything unknown or mistyped is skipped:
/// a newer MoveOS must never crash the cluster.
///
/// [power] carries pack volts and amps between batches; without it the
/// product is only formed when both arrive together. [onUnknown] hears
/// every ServerCmd name this mapping has no case for, so a newer firmware's
/// additions show up in the analytics log.
VehicleData applyHhmisUpdate(
  VehicleData current,
  Map<Object?, Object?> delta, {
  HhmisPower? power,
  void Function(String key)? onUnknown,
}) {
  var v = current;
  // The bridge batches into a hash map, so arrival order is lost. The
  // coarse vehicle state goes first and the specific lock and charge keys
  // after it, so the same batch always lands the same way.
  for (final key in _orderedKeys(delta)) {
    v = _applyOne(v, key, delta[key], onUnknown);
  }
  v = _settleState(v);
  final kw = (power ?? HhmisPower()).update(delta, motorOn: v.vehicleState.motorOn);
  return kw == null ? v : v.copyWith(power: kw);
}

const _lateKeys = ['INT_VEHICLE_ESCL_STATUS', 'INT_CHARGE_STATUS'];

List<String> _orderedKeys(Map<Object?, Object?> delta) {
  final keys = delta.keys.whereType<String>().toList();
  if (keys.length < 2) return keys;
  final early = <String>[];
  final late = <String>[];
  for (final k in keys) {
    if (k == 'INT_VEHICLE_STATE') {
      early.insert(0, k);
    } else if (_lateKeys.contains(k)) {
      late.add(k);
    } else {
      early.add(k);
    }
  }
  return [...early, ...late];
}

/// The vehicle states as the app numbers them (`StockContract.APP_STATES`
/// in Kotlin, which turns the scooter's own numbers into these by name):
/// stock 4.6.14's seven, then what later software added. A state the app
/// has no name for arrives as -1.
const _stateLock = 0, _stateAlarm = 1, _statePasscode = 2, _statePark = 3;
const _stateMotorOn = 4, _stateReverse = 5, _stateCharging = 6, _stateParkAssist = 7;

/// `VehicleLockStateBCM` ordinals.
const _esclUnlocked = 1, _esclLocked = 3;

/// What HHMIS `VehicleManager.setChargingStatus` emits after its own switch
/// map, not the HVDP `ChargingStatus` ordinals (HHMIC agrees). 3 never
/// arrives.
const _chargeOff = 0, _chargeInProgress = 1, _chargeComplete = 2, _chargeError = -1;

/// `ChargingModes.Boost_Charge`.
const _chargeModeBoost = 6;

/// `INT_BOOST_HYPER_CHARGE_STATUS`: 0 slow, 1 boost, 2 hyper (MoveOS 5's
/// 3, the slow charger on, arrives here as 0: `StockProfile`).
const _hyperCharger = 2;

/// `HillHoldStatus`: 0 SNA, 1 UNAVAILABLE, 2 ACTIVE, 3 NOT_ACTIVE,
/// 4 ABT_TO_DEACTIVATE. HHMIS never sends 5 or 6.
const _hillHoldActive = 2;

/// `TowTheftDetection`: 0 SNA, 1 ACTIVE, 2 INACTIVE. Shared with the CAN
/// nibble on 0x683, which carries the same enum.
const towTheftActive = 1;

int? _int(Object? o) => o is int ? o : (o is double ? o.round() : null);
double? _double(Object? o) => o is num ? o.toDouble() : null;
bool? _bool(Object? o) => o is bool ? o : null;

VehicleData _mirror(VehicleData v, Object? raw, String feature) {
  final b = _bool(raw);
  if (b == null || v.featureMirror[feature] == b) return v;
  return v.copyWith(featureMirror: {...v.featureMirror, feature: b});
}
String? _string(Object? o) => o is String ? o : null;

VehicleData _available(VehicleData v, bool? available, String feature) {
  if (available == null || v.featureAvailable[feature] == available) return v;
  return v.copyWith(featureAvailable: {...v.featureAvailable, feature: available});
}

/// The INT flavour: stock's `onVehicleFeatureAvailable(II)` treats anything
/// but 1 as "not available" (tow/tamper arrives as 2 on a scooter without it).
VehicleData _availableInt(VehicleData v, Object? raw, String feature) {
  final i = _int(raw);
  return _available(v, i == null ? null : i == 1, feature);
}

final _leadingNumber = RegExp(r'-?\d+(\.\d+)?');

/// "72 km/h" -> 72.0; anything without a number -> null.
double? _num(Object? o) {
  if (o is num) return o.toDouble();
  if (o is! String) return null;
  final m = _leadingNumber.firstMatch(o);
  return m == null ? null : double.tryParse(m.group(0)!);
}

VehicleData _applyOne(VehicleData v, String key, Object? raw, void Function(String key)? onUnknown) {
  switch (key) {
    case 'INT_VEHICLE_SPEED':
      final s = _int(raw);
      return s == null ? v : v.copyWith(speed: s.clamp(0, 199));
    case 'INT_BATTERY_SOC':
      final s = _int(raw);
      return s == null ? v : v.copyWith(batterySoc: s.clamp(0, 100));
    case 'FLOAT_BATTERY_OVERALL_SOC':
      final s = _double(raw);
      return s == null ? v : v.copyWith(rawBatterySoc: s.clamp(0, 100));
    case 'INT_VEHICLE_RANGE':
      final r = _int(raw);
      return r == null ? v : v.copyWith(range: r);
    case 'INT_VEHICLE_ODO':
      final o = _int(raw);
      return o == null ? v : v.copyWith(odometer: o);
    case 'INT_VEHICLE_MOTOR_RPM':
      // Hundreds of rpm (HHMIS divides by 100 before
      // sending; HHMIC hands the same number to Kanzi). Kept raw here and
      // multiplied by `VehicleData.rpmUnit` where it is shown.
      final r = _int(raw);
      return r == null ? v : v.copyWith(rpm: r);
    case 'STR_VEHICLE_DRIVE_MODE':
      return _driveMode(v, _string(raw));
    // Sent on change only (VPServerConnection$13.onAvailableDrivingModesChanged),
    // RESERVE folded into 0.
    case 'INT_VEHICLE_MODE_AVAILABLE_STATUS':
      final i = _int(raw);
      return i == null || i < 0 || i > 3 ? v : v.copyWith(modesAvailable: i);
    // The generic `STR_VEHICLE_DISTANCE_COVERED` does arrive (seen as "3")
    // but is not a trip meter we use. The two trip counters are
    // confusingly named: a ride's raw-value capture proved
    // that `_BY_ALL_USERS` is the one `VOID_RESET_TRIPO_METER_B` (cmd 28)
    // zeroes, i.e. stock's second meter (`TripometerSecond`), and it is the
    // only one shown. `_BY_INDIVIDUAL_USER` (stock's first meter,
    // `Tripometer`) keeps accumulating across that reset and is not mapped.
    // Value is meters as a decimal string, divided by 1000.0 for km (stock
    // `WidgetInfoManager.smali:8710-8719` `long-to-float / 1000.0f`).
    case 'STR_VEHICLE_DISTANCE_COVERED_BY_ALL_USERS':
      final m = _num(raw);
      return m == null ? v : v.copyWith(tripMeter: m / 1000.0);
    case 'BOOL_LEFT_INDICATOR_STATUS':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(turnLeft: b);
    case 'BOOL_RIGHT_INDICATOR_STATUS':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(turnRight: b);
    case 'BOOL_HAZARD_LIGHT_PERSIST_TOGGLE_STAT':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(hazard: b);
    case 'BOOL_HIGH_BEAM_STATUS':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(highBeam: b);
    case 'BOOL_LOW_BEAM_STATUS':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(lowBeam: b);
    case 'BOOL_POSITION_LAMP_STATUS':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(positionLight: b);
    case 'BOOL_SIDE_STAND_ICON_STATUS':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(sideStand: b);
    // ESCL warning state is set by the 3-second debounce in AidlVehicleNotifier
    // (OpenDash's own; stock shows no popup from this status). Here we only
    // reflect the clean transitions and clear transient warnings when the
    // vehicle lands on a stable Locked/Unlocked.
    case 'INT_VEHICLE_ESCL_STATUS':
      return switch (_int(raw)) {
        _esclUnlocked => v.copyWith(lockState: 0, lockFailedWarning: false, unlockFailedWarning: false),
        _esclLocked => v.copyWith(lockState: 4, lockFailedWarning: false, unlockFailedWarning: false),
        _ => v,
      };
    case 'INT_VEHICLE_TRUNK_STATUS':
      return switch (_int(raw)) {
        2 => v.copyWith(trunkOpen: true, trunkStateKnown: true),
        3 => v.copyWith(trunkOpen: false, trunkStateKnown: true),
        _ => v,
      };
    case 'INT_VEHICLE_STATE':
      return _vehicleState(v, _int(raw));
    case 'INT_VEHICLE_CRUISE_MODE_STATUS':
      return switch (_int(raw)) {
        1 => v.copyWith(cruiseMode: CruiseMode.active, cruiseSetSpeed: v.cruiseMode == CruiseMode.active ? null : v.speed),
        0 => v.copyWith(cruiseMode: CruiseMode.standby, cruiseSetSpeed: 0),
        null => v,
        _ => v.copyWith(cruiseMode: CruiseMode.off, cruiseSetSpeed: 0),
      };
    case 'BOOL_CRUISE_CONTROL_STATUS':
      final b = _bool(raw);
      if (b == null) return v;
      return b
          ? v.copyWith(cruiseMode: CruiseMode.active, cruiseSetSpeed: v.cruiseMode == CruiseMode.active ? null : v.speed)
          : v.copyWith(cruiseMode: v.cruiseMode == CruiseMode.active ? CruiseMode.standby : null, cruiseSetSpeed: 0);
    case 'BOOL_VEHICLE_ADAPTIVE_POWER_BOOST_STATUS':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(apbActive: b);
    // VCU is cutting the head-unit 12 V supply. Stock HHMIC's
    // `setHeadUnitPowerFlag` calls `IKanziView.setTouchDisabled(!flag)` —
    // we gate touch the same way so a tap during the grace window before
    // power drops doesn't fire a stale action.
    case 'BOOL_HEAD_UNIT_POWER_FLAG':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(touchDisabled: !b);
    // HHMIS `BOOL_*_PERSIST_TOGGLE_STAT` broadcasts the vehicle's persisted
    // setting for each feature. R-9: the non-PERSIST variants (`*_TOGGLE_STAT`
    // alone) mean "sent", not "on" — do NOT map them here. These keys
    // populate `featureMirror` by RidingFeature.name; RidingSettings listens
    // and mirrors into state without sending back.
    case 'BOOL_APB_PERSIST_TOGGLE_STAT':
      return _mirror(v, raw, 'adaptivePowerBoost');
    case 'BOOL_HILL_HOLD_PERSIST_TOGGLE_STAT':
      return _mirror(v, raw, 'hillHold');
    case 'BOOL_ACCIDENT_DETECTION_PERSIST_TOGGLE_STAT':
      return _mirror(v, raw, 'fallDetection');
    case 'BOOL_TOW_THEFT_PERSIST_TOGGLE_STAT':
      return _mirror(v, raw, 'tamper');
    case 'BOOL_PROXIMITY_PERSIST_TOGGLE_STAT':
      return _mirror(v, raw, 'proximityUnlock');
    case 'BOOL_SMART_DRL_PERSIST_TOGGLE_STAT':
      return _mirror(v, raw, 'smartDrl');
    case 'BOOL_AUTO_HEADLIGHT_PERSIST_TOGGLE_STAT':
      return _mirror(v, raw, 'autoHeadlight');
    case 'BOOL_MOTOR_CUTOFF_PERSIST_TOGGLE_STAT':
      return _mirror(v, raw, 'motorCutOff');
    case 'BOOL_VACATION_PERSIST_TOGGLE_STAT':
      return _mirror(v, raw, 'vacationMode');
    case 'BOOL_PREDICT_RANGE_PERSIST_TOGGLE_STAT':
      return _mirror(v, raw, 'predictedRange');
    case 'BOOL_TAKE_ME_HOME_PERSIST_TOGGLE_STAT':
      return _mirror(v, raw, 'takeMeHome');
    // ClientCmd 51 (auto indicator turn-off) is RidingFeature.autoTurnOff.
    case 'BOOL_AUTO_INDICATOR_PERSIST_TURNOFF_TOGGLE_STAT':
      return _mirror(v, raw, 'autoTurnOff');
    // No `_STAT` suffix on this one in the HHMIS enum. True is the
    // bypass (SIDE_STAND_ENABLE, 0x6BC 5B), so the sensor is its inverse.
    // 2026-11-26 Gen 1 5.0.2: false all day, HHMIS sent 5A at each unlock,
    // and the stand still cut drive. Stock without the override flag
    // always sends 0 (Session 38).
    case 'BOOL_SIDE_STAND_PERSIST_TOGGLE':
      final bypass = _bool(raw);
      return bypass == null ? v : _mirror(v, !bypass, 'sideStandCutOff');
    // Smart-headlight persisted state arrives as
    // INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT. 1 = on.
    case 'INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT':
      final i = _int(raw);
      if (i == null) return v;
      final on = i == 1;
      if (v.featureMirror['smartHeadlight'] == on) return v;
      return v.copyWith(featureMirror: {...v.featureMirror, 'smartHeadlight': on});
    // What this scooter has. Stock HHMIC
    // (`SettingsInfoManager.onVehicleFeatureAvailable`) hides the setting on
    // false / != 1; RidingSection and every "on" sender read
    // `VehicleData.isFeatureAvailable`. The BOOL_ variants of tow/tamper,
    // hill hold and take-me-home are dead enum entries; HHMIS sends the INT_
    // ones.
    case 'BOOL_BOOST_MODE_FEATURE_AVAILABLE':
      return _available(v, _bool(raw), 'adaptivePowerBoost');
    case 'BOOL_ACCIDENT_DETECTION_FEATURE_AVAILABLE':
      return _available(v, _bool(raw), 'fallDetection');
    case 'BOOL_PROXIMITY_LOCK_FEATURE_AVAILABLE':
      return _available(v, _bool(raw), 'proximityUnlock');
    case 'BOOL_SMART_HEAD_LIGHT_FEATURE_AVAILABLE':
      return _available(v, _bool(raw), 'smartHeadlight');
    case 'BOOL_SMART_DRL_LIGHT_FEATURE_AVAILABLE':
      return _available(v, _bool(raw), 'smartDrl');
    case 'BOOL_AUTO_HEAD_LIGHT_FEATURE_AVAILABLE':
      return _available(v, _bool(raw), 'autoHeadlight');
    case 'BOOL_HAZARD_LIGHT_FEATURE_AVAILABLE':
      return _available(v, _bool(raw), 'hazard');
    case 'BOOL_AUTO_INDICATOR_TURN_OFF_FEATURE_AVAILABLE':
      return _available(v, _bool(raw), 'autoTurnOff');
    case 'BOOL_MOTOR_CUTOFF_DELAY_FEATURE_AVAILABLE':
      return _available(v, _bool(raw), 'motorCutOff');
    case 'INT_TOW_TAMPER_DETECTION_FEATURE_AVAILABLE':
      return _availableInt(v, raw, 'tamper');
    case 'INT_HILL_HOLD_FEATURE_AVAILABLE':
      return _availableInt(v, raw, 'hillHold');
    case 'INT_TAKE_ME_HOME_FEATURE_AVAILABLE':
      return _availableInt(v, raw, 'takeMeHome');
    // Stock `TechPackInfoManager.setTechPackRegenFeature`: anything but 1
    // holds regen at Default.
    case 'INT_TECH_PACH_REGEN':
      return _availableInt(v, raw, 'regen');
    // Settings HPMS persists and HHMIS replays at profile load; RidingSettings
    // mirrors them without sending back.
    case 'INT_PERSISTED_USER_HILLHOLD_CONDITIONACCEPTED':
      final i = _int(raw);
      return i == null ? v : v.copyWith(hillHoldConsent: () => i == 1);
    case 'INT_PERSISTED_ALARM_ALERT_SOUND':
      final i = _int(raw);
      return i == 0 || i == 1 ? v.copyWith(alarmSoundIndex: () => i) : v;
    case 'INT_PERSISTED_SAFETY_SENSITIVITY':
      final i = _int(raw);
      return i == 0 || i == 1 ? v.copyWith(safetySensitivity: () => i) : v;
    // The stock dashboard's auto-download setting, replayed from the profile
    // at unlock. Shown on the Updates screen and switched off once
    // (`FirmwareNotifier`); HOTA itself never reads it.
    case 'AUTODOWNLOAD_UPDATE':
      final i = _int(raw);
      return i == null ? v : v.copyWith(stockAutoDownload: () => i);
    // Whole degrees. It arrives as often as the speed, but the value sits
    // at -1..1 for whole rides, so equal values drop
    // out at VehicleData equality and nothing rebuilds.
    case 'INT_VEHICLE_INCLINATION_DEGREE':
      final i = _int(raw);
      return i == null ? v : v.copyWith(inclinationDegrees: () => i);
    case 'FLOAT_VEHICLE_TORQUE':
      final t = _double(raw);
      return t == null ? v : v.copyWith(torque: t);
    case 'FLOAT_VEHICLE_VOLTAGE':
      final d = _double(raw);
      return d == null ? v : v.copyWith(busVoltage: d);
    case 'FLOAT_VEHICLE_CURRENT':
      final d = _double(raw);
      return d == null ? v : v.copyWith(packCurrent: d);
    // The decompiled ServerCmd enum has no ambient light, service indicator
    // or limp range key; those come from the CAN stream via
    // GrpcDiagnosticsNotifier. Regen availability is the boolean below (HVDP
    // forwards the BMS 0x640 flag) until the VCU's 0x683 nibble has
    // reported; AidlVehicleNotifier then drops this key so the two
    // different signals do not alternate.
    case 'BOOL_VEHICLE_REGEN_AVAIL_STATUS':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(regenAvailability: b ? 1 : 0, regenAvailabilityKnown: true);
    case 'FLOAT_MOTOR_TEMPERATURE':
      final t = _double(raw);
      return t == null ? v : v.copyWith(motorTemp: t.round());
    case 'FLOAT_BATTERY_EFF_TEMP':
      final t = _double(raw);
      // Stock `onEffectiveBatteryTemp` moves the shown
      // integer only once the reading is 1.0 degree away from it.
      return t == null || (t - v.batteryTemp).abs() < 1 ? v : v.copyWith(batteryTemp: t.round());
    case 'INT_CHARGE_STATUS':
      return switch (_int(raw)) {
        _chargeInProgress => v.copyWith(isCharging: true, chargingState: ChargingState.charging, safeToUnplug: false),
        _chargeComplete => v.copyWith(isCharging: true, chargingState: ChargingState.complete, safeToUnplug: true),
        _chargeError => v.copyWith(isCharging: true, chargingState: ChargingState.notCharging, safeToUnplug: false),
        _chargeOff => v.copyWith(isCharging: false, chargingState: ChargingState.normal, safeToUnplug: false),
        _ => v,
      };
    case 'INT_CHARGE_MODE':
      final m = _int(raw);
      if (m == null) return v;
      var next = v.copyWith(isBoostCharger: m == _chargeModeBoost, chargeMode: m);
      // INT_CHARGE_STATUS = 0 (the only path that
      // currently clears isCharging) is a transition-only event and a
      // ride log showed it missing during an unplug. Treat a
      // charge-mode that is not one of {3 charging, 4 hyper, 6 fast} as
      // a secondary 'not charging' signal when the vehicle state is not
      // CHARGING either.
      const activeModes = {3, 4, 6};
      if (next.isCharging && !activeModes.contains(m) && next.vehicleState != VehicleState.charging) {
        next = next.copyWith(isCharging: false, chargingState: ChargingState.normal, safeToUnplug: false);
      }
      return next;
    case 'INT_BOOST_HYPER_CHARGE_STATUS':
      final m = _int(raw);
      return m == null ? v : v.copyWith(isHyperCharger: m == _hyperCharger);
    case 'INT_BATTERY_TIME_TO_FULL_CHARGE_UPDATE':
      final m = _int(raw);
      return m == null ? v : v.copyWith(minutesToFull: m < 0 ? 0 : m);
    case 'INT_BATTERY_OPTIMUM_CHARGE_TIME':
      final m = _int(raw);
      return m == null ? v : v.copyWith(minutesTo80: m < 0 ? 0 : m);
    // Fast-charger companion to the two above. Both values are minutes.
    case 'INT_FC_BATTERY_TIME_TO_FULL_CHARGE_UPDATE':
      final m = _int(raw);
      return m == null ? v : v.copyWith(hyperMinutesToFull: m < 0 ? 0 : m);
    case 'INT_FC_BATTERY_OPTIMUM_CHARGE_UPDATE':
      final m = _int(raw);
      return m == null ? v : v.copyWith(hyperMinutesTo80: m < 0 ? 0 : m);
    // HHMIS `Constants.HmiStatusBarStatus`, 0-3 (HVDP's INITIALIZING_HYPERCHARGER
    // is not forwarded; it arrives as INT_VEHICLE_COMMAND 132).
    //
    // INT_CHARGE_STATUS arrives only on transitions (0 at unplug, 1 at
    // plug-in; absent from a 657-event ride log), so the
    // status-bar substate, sent continuously, is also the authoritative
    // source for `chargingState` and `safeToUnplug`. Stock's "Charging
    // complete — unplug now" and "Not charging" strings both come from this
    // field, not INT_CHARGE_STATUS. `isCharging` keeps meaning "plugged in"
    // and is left to INT_VEHICLE_STATE = 6.
    case 'INT_HMI_STATUSBAR_STATUS':
      final i = _int(raw);
      if (i == null) return v;
      final sub = switch (i) {
        1 => ChargeSubstate.chargeComplete,
        2 => ChargeSubstate.chargingSlowly,
        3 => ChargeSubstate.notCharging,
        _ => ChargeSubstate.sna,
      };
      return switch (sub) {
        ChargeSubstate.chargeComplete => v.copyWith(
            chargeSubstate: sub,
            chargingState: ChargingState.complete,
            safeToUnplug: true,
          ),
        ChargeSubstate.chargingSlowly => v.copyWith(
            chargeSubstate: sub,
            chargingState: ChargingState.charging,
            safeToUnplug: false,
          ),
        ChargeSubstate.notCharging => v.copyWith(
            chargeSubstate: sub,
            chargingState: ChargingState.notCharging,
            safeToUnplug: false,
          ),
        // Leaving a substate drops what it set, as
        // stock's status text falls back to the charge mode. 0 is also the
        // steady value, so only the transition counts.
        ChargeSubstate.sna => v.chargeSubstate == ChargeSubstate.sna
            ? v
            : v.copyWith(
                chargeSubstate: sub,
                chargingState: v.isCharging ? ChargingState.charging : ChargingState.normal,
                safeToUnplug: false,
              ),
      };
    // HHMIS is the only writer of these two. CAN 0x160 bits 24-39 / 40-55
    // carry the same values, but the CAN path does not decode them.
    case 'FLOAT_BATTERY_MIN_TEMP':
      final t = _double(raw);
      return t == null ? v : v.copyWith(batteryMinTemp: () => t);
    case 'FLOAT_BATTERY_MAX_TEMP':
      final t = _double(raw);
      return t == null ? v : v.copyWith(batteryMaxTemp: () => t);
    // Fast charger plugged but idling (no current flow).
    case 'BOOL_FC_CHARGE_IDLE_STATUS':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(fcChargeIdle: b);
    // VCU-fired regen notification; stock HHMIC
    // shows a brief indicator chime per `BOOL_VEHICLE_REGEN_NOTIFICATION_STATUS`.
    case 'BOOL_VEHICLE_REGEN_NOTIFICATION_STATUS':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(regenNotification: b);
    // Vehicle's view of the current brightness (0-100);
    // mirrored into BrightnessNotifier so an external change (auto
    // brightness, settings-app, charger-override) is reflected on our
    // slider without us echoing it back to HHMIS.
    case 'INT_VEHICLE_BRIGHTNESS':
      final i = _int(raw);
      return i == null ? v : v.copyWith(vehicleBrightness: () => i.clamp(0, 100));
    case 'BOOL_VEHICLE_CONNECTOR_LATCHED':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(safeToUnplug: !b && v.isCharging);
    case 'BOOL_BRAKE_WORN_OUT_STATUS':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(brakeWorn: b);
    // The popups for 2 and 4 are raised by AidlVehicleNotifier._hillHold.
    case 'INT_HILL_HOLD_STATUS':
      final i = _int(raw);
      return i == null ? v : v.copyWith(hillHoldActive: i == _hillHoldActive);
    // HVSM replays the vehicle's persisted regen mode on bind
    // (`onRegenStatusReceived`), so RidingSettings follows the VCU rather
    // than the dashboard's own prefs value.
    case 'REGEN_SETTINGS_UPDATE':
      final i = _int(raw);
      final mode = i == null ? null : RegenMode.fromWire(i);
      return mode == null ? v : v.copyWith(regenMode: mode);
    // Stock `VehicleInfoManager.fallDetectionAlert`: 1 (ACTIVE) raises the
    // fall screen and nothing in the Java side takes it down except the end
    // of ALARM. Ours also closes on any other value (0 SNA, 2 INACTIVE,
    // 3 RECOVERED): the screen has no button, so it must not outlive the
    // fall.
    // BOOL_FALL_DETECTED_L1/L2_PHASE are never sent and stock's handlers
    // are empty; both are in ignoredHhmisKeys.
    case 'INT_FALL_DETECTION_ALERT':
      return switch (_int(raw)) {
        null => v,
        1 => v.copyWith(fallDetected: true),
        _ => v.copyWith(fallDetected: false),
      };
    // Stock `setAccidentSeverityStatus` acts on true only; the accident
    // screen stays until the rider answers it or ALARM ends.
    case 'BOOL_ACCIDENT_SEVERITY_STAT':
      return _bool(raw) == true ? v.copyWith(accidentDetected: true) : v;
    // Two enums share this key: TowTheftDetection (0 SNA, 1 ACTIVE,
    // 2 INACTIVE) and CommandFromVehicle.TAMPER_PASS_EXIT (153). Stock
    // `towTheftDetectionAlert` acts on 1 only, and the alert is taken down
    // by leaving ALARM (_vehicleState), never by a value.
    case 'INT_TOW_THEFT_DETECTION_ALERT':
      return switch (_int(raw)) {
        towTheftActive => v.copyWith(tamperDetected: true, towTheftState: towTheftActive),
        final int i when i == 0 || i == 2 => v.copyWith(towTheftState: i),
        _ => v,
      };
    // A one-shot notification; stock never sends a zero. Drives its own
    // critical alert ("Scooter Issue, please maintain a safe distance");
    // plugging in does not clear it, and the Kotlin
    // ONE_SHOT_KEYS set stops a reattach from replaying it.
    case 'INT_THERMAL_RUNAWAY':
      final i = _int(raw);
      return i == null || i == 0 ? v : v.copyWith(thermalRunaway: true);
    // HHMIS forwards the scooter's advertised BT name;
    // mapping it keeps the Profile card's name truthful instead of the
    // mock default.
    case 'STR_PROFILE_SCOOTER_NAME':
      final s = raw is String ? raw : null;
      return s == null || s.isEmpty ? v : v.copyWith(scooterBtName: s);
    // Stock: `IUserInfo.onProfileNameChanged` (UserProfileManager.smali).
    case 'STR_PROFILE_USER_NAME':
      final s = _string(raw);
      return s == null || s.isEmpty ? v : v.copyWith(profileUserName: s);
    // STAT = true means degraded; read as healthy, a dying pack would
    // show "Good". The default is unknown; the first value sets
    // batteryHealthKnown.
    case 'BOOL_PACK_SOH_STAT':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(batteryHealthGood: !b, batteryHealthKnown: true);
    case 'STR_VEHICLE_TOP_SPEED':
      final n = _num(raw);
      return n == null ? v : v.copyWith(dailyTopSpeed: n.round());
    case 'STR_VEHICLE_AVG_SPEED':
      final n = _num(raw);
      return n == null ? v : v.copyWith(dailyAvgSpeed: n.round());
    // Stock HHMIC reads the *_WITH_METER
    // variant which carries one decimal; the plain key truncated to
    // whole km, so a 12.8 km day read 12.
    case 'STR_VEHICLE_TOTAL_DISTANCE_DAY_WITH_METER':
      final n = _num(raw);
      return n == null ? v : v.copyWith(dailyDistance: n.round());
    case 'STR_VEHICLE_DISTANCE_COVERED_IN_ECO_MODE_FOR_THE_DAY':
      final n = _num(raw);
      return n == null ? v : v.copyWith(ecoDistance: n);
    case 'STR_VEHICLE_DISTANCE_COVERED_IN_NORMAL_MODE_FOR_THE_DAY':
      final n = _num(raw);
      return n == null ? v : v.copyWith(normalDistance: n);
    case 'STR_VEHICLE_DISTANCE_COVERED_IN_SPORT_MODE_FOR_THE_DAY':
      final n = _num(raw);
      return n == null ? v : v.copyWith(sportDistance: n);
    case 'STR_VEHICLE_DISTANCE_COVERED_IN_HYPER_MODE_FOR_THE_DAY':
      final n = _num(raw);
      return n == null ? v : v.copyWith(hyperDistance: n);
    case 'STR_RIDE_EFFICIENCY_UPDATED_FOR_THE_DAY':
      final n = _num(raw);
      return n == null ? v : v.copyWith(rideEfficiency: n);
    case 'STR_REGEN_GENERATED_DURING_THE_DAY':
      final n = _num(raw);
      return n == null ? v : v.copyWith(regenEnergy: n);
    case 'INT_VEHICLE_VOLUME':
    case '_volume':
      final i = _int(raw);
      return i == null ? v : v.copyWith(volume: i.clamp(0, 100));
    case 'STR_VERSION_WIFI_MAC_ADDR':
      final s = _string(raw);
      return s == null ? v : v.copyWith(wifiMac: s);
    case 'STR_PROXIMITY_BLE_PASSCODE':
      final s = _string(raw);
      return s == null ? v : v.copyWith(btPairingCode: s);
    case 'BOOL_BT_CALL_MUTE_STAT':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(callMuted: b);
    case '_wifi':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(wifiConnected: b);
    case '_bt':
      final b = _bool(raw);
      return b == null ? v : v.copyWith(btConnected: b);
    // Identity and status rows read by SystemStatus.kt from
    // the Android services (stock reads the same through HSSS).
    case '_signal':
      final i = _int(raw);
      return i == null ? v : v.copyWith(signalBars: i.clamp(0, 4));
    case '_ip':
      final s = _string(raw);
      return s == null ? v : v.copyWith(ipAddress: s);
    case '_btName':
      final s = _string(raw);
      return s == null || s.isEmpty ? v : v.copyWith(scooterBtName: s);
    case '_btDevice':
      final s = _string(raw);
      return s == null ? v : v.copyWith(btDeviceName: s);
    case '_btBonded':
      if (raw is! List) return v;
      return v.copyWith(btBondedDevices: [for (final e in raw) if (e is String) e]);
    // Vehicle variant (3 on an S1 Pro Gen 1). Stock uses it for S1 Air
    // and fleet differences; here it names the model and flags one that
    // OpenDash has not been checked on (`ScooterModel`).
    case 'INT_PROFILE_VEHICLE_TYPE':
      final t = _int(raw);
      return t == null ? v : v.copyWith(vehicleType: t);
    case '_moveOs':
      final s = _string(raw);
      return s == null ? v : v.copyWith(moveOsVersion: s);
    case '_vsw':
      final s = _string(raw);
      return s == null ? v : v.copyWith(vswVersion: s);
    case '_vdp':
      final s = _string(raw);
      return s == null ? v : v.copyWith(vdpVersion: s);
    // The rider's own ride mode (MoveOS 5). Shown only; nothing is sent.
    case 'STR_CUSTOM_RIDE_MODE_NAME':
      final s = _string(raw);
      return s == null ? v : v.copyWith(customRide: v.customRide.copyWith(name: s));
    case 'CUSTOM_RIDE_MODE':
      final i = _int(raw);
      return i == null ? v : v.copyWith(customRide: v.customRide.copyWith(enabled: i == 1));
    case 'DEFAULT_RIDE_MODE':
      final i = _int(raw);
      return i == null ? v : v.copyWith(customRide: v.customRide.copyWith(isDefault: i == 1));
    case 'CUSTOM_RIDE_SPEED':
      final i = _int(raw);
      return i == null ? v : v.copyWith(customRide: v.customRide.copyWith(topSpeedKmh: i));
    case 'CUSTOM_RIDE_POWER_TORQUE':
      final i = _int(raw);
      return i == null ? v : v.copyWith(customRide: v.customRide.copyWith(powerPercent: i));
    case 'CUSTOM_RIDE_THROTTLE_SENSITIVITY':
      final i = _int(raw);
      return i == null ? v : v.copyWith(customRide: v.customRide.copyWith(throttle: i));
    case 'CUSTOM_RIDE_REGEN_INTENSITY':
      final i = _int(raw);
      return i == null ? v : v.copyWith(customRide: v.customRide.copyWith(regen: i));
    case 'INT_DIY_RANGE_CHANGED':
      final i = _int(raw);
      return i == null || i < 0 ? v : v.copyWith(customRide: v.customRide.copyWith(rangeKm: i));
    case 'STR_VEHICLE_DISTANCE_COVERED_IN_CUSTOM_MODE_FOR_THE_DAY':
      final d = double.tryParse(_string(raw)?.trim() ?? '');
      return d == null ? v : v.copyWith(customRide: v.customRide.copyWith(todayKm: d));
    case '_rangeByMode':
      if (raw is! List || raw.length < 4) return v;
      final r = raw.map(_int).toList();
      if (r.any((x) => x == null)) return v;
      return v.copyWith(rangeEco: r[0], rangeNormal: r[1], rangeSport: r[2], rangeHyper: r[3]);
    // Acted on in AidlVehicleNotifier.onEvent, not folded into state.
    case 'INT_BT_MUSIC_COMMAND':
    case 'BOOL_BT_CALL_HANDLE_REQUEST':
    case 'INT_VEHICLE_COMMAND':
    case 'INT_PROFILE_REMAINING_ATTEMPTS':
    case 'BOOL_PROFILE_PASSCODE_CHANGED_ACK':
    case 'INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST':
    case 'BOOL_PROXIMITY_PAIRING_ACK':
      return v;
    default:
      if (!key.startsWith('_') && !ignoredHhmisKeys.contains(key)) onUnknown?.call(key);
      return v;
  }
}

/// ServerCmds the dash deliberately drops, so `hhmis.unknown_keys` only
/// surfaces keys nobody has looked at yet. A day of rides sent ~60
/// unmapped keys; these are the ones with no place on this dashboard.
const ignoredHhmisKeys = {
  // Never sent by HHMIS (`VPServerConnection$9.isFallDetectedL1Phase` /
  // `L2Phase` are empty) and ignored by stock; the fall and accident
  // screens come from INT_FALL_DETECTION_ALERT and
  // BOOL_ACCIDENT_SEVERITY_STAT.
  'BOOL_FALL_DETECTED_L1_PHASE',
  'BOOL_FALL_DETECTED_L2_PHASE',
  // STR_VEHICLE_TOTAL_DISTANCE_DAY still
  // arrives but the _WITH_METER variant is authoritative.
  'STR_VEHICLE_TOTAL_DISTANCE_DAY',
  // Raw IMU and motor streams; continuous, nothing on the cluster uses them.
  'FLOAT_VEHICLE_ACCELERATION',
  'FLOAT_VEHICLE_ACCEL_X',
  'FLOAT_VEHICLE_ACCEL_Y',
  'FLOAT_VEHICLE_ACCEL_Z',
  'FLOAT_VEHICLE_GYRO_X',
  'FLOAT_VEHICLE_GYRO_Y',
  'FLOAT_VEHICLE_GYRO_Z',
  'FLOAT_VEHICLE_MOTOR_TORQUE',
  // Ola's tech-pack fences and vacation mode: cloud-side features.
  'BOOL_TECH_PACH_VACATION_MODE',
  'BOOL_VACATION_MODE_FLAG',
  'INT_TECH_PACH_GEO_FENCE',
  'INT_TECH_PACH_MODE_FENCE',
  'INT_TECH_PACH_TIME_FENCE',
  // Stock-app preferences for features OpenDash does not have.
  'BOOL_VEHICLE_NAVIGATION_SUPPORT',
  // Read by `AidlVehicleNotifier._applyCallbacks` (calls on the dashboard),
  // not mapped to a VehicleData field.
  'INT_PERSISTED_SYNC_CONTACT',
  'INT_PERSISTED_SYNC_CONTACT_CONSENT',
  'INT_PERSISTED_VOICE_ASSISTANT',
  'INT_PROFILE_NAVI_SETTINGS_UPDATE',
  'INT_PROFILE_THEME_UPDATE',
  'INT_PROFILE_MODE_UPDATE',
  // HHMIS's reply to our own toggle command. true means
  // "handed to HVDP", for an OFF as much as an ON, so it is not feature
  // state; the PERSIST variants are.
  'BOOL_APB_TOGGLE_STAT',
  'BOOL_ACCIDENT_DETECTION_TOGGLE_STAT',
  'BOOL_TOW_THEFT_TOGGLE_STAT',
  'BOOL_PROXIMITY_TOGGLE_STAT',
  'BOOL_HILL_HOLD_TOGGLE_STAT',
  'BOOL_SMART_HEADLIGHT_TOGGLE_STAT',
  'BOOL_SMART_DRL_TOGGLE_STAT',
  'BOOL_AUTO_HEADLIGHT_TOGGLE_STAT',
  'BOOL_HAZARD_LIGHT_TOGGLE_STAT',
  'BOOL_AUTO_INDICATOR_TURNOFF_TOGGLE_STAT',
  'BOOL_MOTOR_CUTOFF_TOGGLE_STAT',
  'BOOL_VACATION_MODE_TOGGLE_STAT',
  'BOOL_TAKE_ME_HOME_TOGGLE_STAT',
  'BOOL_SIDE_STAND_TOGGLE_STAT',
  // Persisted REGEN_TOGGLE (0 here). Stock `SettingsInfoManager.
  // updateRegenToggle` writes RegenEnable = true on both branches, so the
  // value changes nothing; the regen mode is REGEN_SETTINGS_UPDATE.
  'REGEN_SETTINGS_TOGGLE',
  // Stock drops Bluetooth connections on lock and restores them on unlock.
  // Not replicated yet; it belongs with the stock-disable work.
  'BOOL_BT_LOCK',
  // Stock only logs these (`WidgetInfoManager.onTripoMeter`,
  // `SettingsInfoManager.setHillHoldCallibration`) or has no handler. The
  // per-user trip counter is still logged raw as `safety.trip_value`.
  'STR_VEHICLE_DISTANCE_COVERED',
  'STR_VEHICLE_DISTANCE_COVERED_BY_INDIVIDUAL_USER',
  'BOOL_USER_CALIBRATION_STATUS',
  'BOOL_VOICE_ASSISTANT_ACTIVATE',
};

VehicleData _driveMode(VehicleData v, String? name) {
  if (name == null) return v;
  switch (name.toUpperCase()) {
    case 'REVERSE':
      return v.copyWith(reverse: true);
    case 'PARKED':
      return v.copyWith(reverse: false);
    // HHMIS collapses LIMPHOME, ECO and BOOST into "ECO", so limp mode
    // cannot be read from this string.
    case 'ECO':
    case 'NORMAL':
    case 'SPORT':
    case 'HYPER':
      return v.copyWith(driveMode: DriveMode.parse(name), reverse: false, customRideActive: false);
    // MoveOS 5 sends the custom mode under the rider's own name;
    // `MoveOs5Profile` turns that into this word before it gets here.
    case customRideModeName:
      return v.copyWith(customRideActive: true, reverse: false);
    default:
      return v;
  }
}

/// What a custom ride mode's own name arrives here as (`StockProfile`).
const customRideModeName = 'CUSTOM';

VehicleData _vehicleState(VehicleData v, int? raw) {
  var next = _vehicleStateOf(v, raw);
  // A known state sets the park-assist flag for the wordmark; a null raw
  // (no change in this batch) leaves it as it was.
  if (raw != null) next = next.copyWith(parkAssist: raw == _stateParkAssist);
  // Stock `onVehicleStateChange`: leaving ALARM sets TamperFallStatus to 0,
  // which takes down the tamper, fall and accident screens together.
  if (v.alarmActive && !next.alarmActive) {
    return next.copyWith(tamperDetected: false, fallDetected: false, accidentDetected: false);
  }
  return next;
}

VehicleData _vehicleStateOf(VehicleData v, int? raw) {
  if (raw == null) return v;
  switch (raw) {
    // INT_CHARGE_STATUS owns isCharging: a locked scooter is usually the
    // one on charge, so LOCK/PARK must not clear it.
    case _stateLock:
    case _statePasscode:
      return v.copyWith(vehicleState: VehicleState.parked, lockState: 4, reverse: false, alarmActive: false);
    // ALARM is not the lock screen. alarmActive puts
    // the alarm screen over whatever lockState says (locked, in practice:
    // the VCU enters ALARM from LOCK, and the bridge starts locked).
    case _stateAlarm:
      return v.copyWith(vehicleState: VehicleState.parked, reverse: false, alarmActive: true);
    case _statePark:
      return v.copyWith(vehicleState: VehicleState.parked, lockState: 0, reverse: false, alarmActive: false);
    case _stateMotorOn:
      return v.copyWith(vehicleState: VehicleState.ready, lockState: 0, reverse: false, alarmActive: false);
    case _stateReverse:
      return v.copyWith(vehicleState: VehicleState.ready, lockState: 0, reverse: true, alarmActive: false);
    // MoveOS 5: the scooter creeping forward or back under smart park. Stock
    // treats it as motor-on everywhere it used to test "motor on or reverse".
    // Which way it is moving is another event, not read yet, so no reverse.
    case _stateParkAssist:
      return v.copyWith(vehicleState: VehicleState.ready, lockState: 0, reverse: false, alarmActive: false);
    case _stateCharging:
      return v.copyWith(
        vehicleState: VehicleState.charging,
        isCharging: true,
        chargingState: v.chargingState == ChargingState.normal ? ChargingState.charging : null,
        alarmActive: false,
        // thermalRunaway is not cleared on CHARGING.
      );
    default:
      return v.copyWith(vehicleState: VehicleState.unknown);
  }
}

/// Motor-on splits into ready/riding by speed once the whole batch is in.
VehicleData _settleState(VehicleData v) {
  var out = v;
  if (v.vehicleState == VehicleState.ready && v.speed > 0) {
    out = out.copyWith(vehicleState: VehicleState.riding);
  } else if (v.vehicleState == VehicleState.riding && v.speed == 0) {
    out = out.copyWith(vehicleState: VehicleState.ready);
  }
  return out;
}

/// Pack electrical arrives as two floats; the bridge keeps the latest of
/// each so the product can be formed whenever either changes.
///
/// Sign convention: matches stock HHMIC's
/// `-volts * amps / 1000`. CAN carries current as positive flowing INTO
/// the battery, so discharge = positive power out, regen = negative.
/// Without this, `battery_diagnostics_provider` ("positive leaves the
/// pack") inverted discharge and regen on screen.
///
/// Scale and gate follow stock HHMIC
/// `WidgetInfoManager.updateWidgetPower`: `/ 1000 * 0.70833` (`0x3f355555`),
/// and "0.0" outside MOTOR_ON / REVERSE. The ride logs settle what the
/// factor is. `bus_v * pack_a` is the true electrical pack power (bus and
/// measured pack volts agree to a median 0.15 V with the motor on), and
/// over 9,105 motor-on heartbeats it peaks at 10.99 kW, above 8.5 kW in 99
/// of them and never above 12. 0.70833 is 8.5 / 12: stock maps the pack's
/// 0-12 kW onto the 0-8.5 kW the cluster is drawn for (the motor's rated
/// peak), so the raw magnitude does not fit our 8.5 kW scales and the
/// scaled one does (logged peak 7.79). Without the gate the charger showed
/// as up to 0.73 kW of "regen" in 3,146 of 4,412 charging heartbeats.
class HhmisPower {
  /// Stock's `0x3f355555`: electrical pack kW to displayed kW (8.5 / 12).
  /// Anything compared against `VehicleData.power` in pack watts (the BMS
  /// discharge limit) has to be scaled by the same factor.
  static const displayScale = 0.7083333;

  double? _volts;
  double? _amps;
  bool? _motorOn;

  /// Returns the new power in kW when the batch touched either input or
  /// the motor went on or off; zero whenever the motor is off.
  double? update(Map<Object?, Object?> delta, {required bool motorOn}) {
    var touched = motorOn != _motorOn;
    _motorOn = motorOn;
    final volts = _double(delta['FLOAT_VEHICLE_VOLTAGE']);
    if (volts != null) {
      _volts = volts;
      touched = true;
    }
    final amps = _double(delta['FLOAT_VEHICLE_CURRENT']);
    if (amps != null) {
      _amps = amps;
      touched = true;
    }
    if (!touched) return null;
    if (!motorOn) return 0;
    if (_volts == null || _amps == null) return null;
    return double.parse((-_volts! * _amps! / 1000 * displayScale).toStringAsFixed(2));
  }
}
