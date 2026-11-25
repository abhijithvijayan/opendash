import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/hhmis_mapping.dart';

void main() {
  const base = VehicleData();

  VehicleData apply(Map<Object?, Object?> delta, [VehicleData from = base]) =>
      applyHhmisUpdate(from, delta);

  group('applyHhmisUpdate', () {
    test('maps the main dashboard ints and bools', () {
      final v = apply({
        'INT_VEHICLE_SPEED': 42,
        'INT_BATTERY_SOC': 67,
        'INT_VEHICLE_RANGE': 91,
        'INT_VEHICLE_ODO': 12408,
        'INT_VEHICLE_MOTOR_RPM': 29,
        'BOOL_LEFT_INDICATOR_STATUS': true,
        'BOOL_HIGH_BEAM_STATUS': true,
        'BOOL_SIDE_STAND_ICON_STATUS': true,
        'FLOAT_BATTERY_OVERALL_SOC': 66.73,
      });
      expect(v.speed, 42);
      expect(v.batterySoc, 67);
      expect(v.range, 91);
      expect(v.odometer, 12408);
      expect(v.rpm, 29); // raw: HHMIS sends rpm / 100 (VehicleManager.setMotorRpm); shown as 2,900.
      expect(v.turnLeft, isTrue);
      expect(v.highBeam, isTrue);
      expect(v.sideStand, isTrue);
      expect(v.rawBatterySoc, closeTo(66.73, 0.001));
    });

    test('mode availability: 0 all, 1 no Sport/Hyper, 2 Eco only, 3 none', () {
      final unknown = <String>[];
      VehicleData at(Object? raw) =>
          applyHhmisUpdate(base, {'INT_VEHICLE_MODE_AVAILABLE_STATUS': raw}, onUnknown: unknown.add);
      Set<DriveMode> modes(VehicleData v) => {for (final m in DriveMode.values) if (m.availableIn(v.modesAvailable)) m};
      expect(modes(base), DriveMode.values.toSet());
      expect(modes(at(0)), DriveMode.values.toSet());
      expect(modes(at(1)), {DriveMode.eco, DriveMode.normal});
      expect(modes(at(2)), {DriveMode.eco});
      expect(modes(at(3)), isEmpty);
      expect(at(4).modesAvailable, 0, reason: 'HHMIS sends 0-3 only');
      expect(at('x').modesAvailable, 0);
      expect(unknown, isEmpty, reason: 'no longer reported in hhmis.unknown_keys');
    });

    test('ignores unknown keys and leaves untouched fields alone', () {
      final from = base.copyWith(speed: 30);
      final v = apply({'SOMETHING_NEW': 1, 'INT_BATTERY_SOC': 50}, from);
      expect(v.speed, 30);
      expect(v.batterySoc, 50);
    });

    test('drive mode strings', () {
      expect(apply({'STR_VEHICLE_DRIVE_MODE': 'SPORT'}).driveMode, DriveMode.sport);
      expect(apply({'STR_VEHICLE_DRIVE_MODE': 'HYPER'}).driveMode, DriveMode.hyper);
      final reverse = apply({'STR_VEHICLE_DRIVE_MODE': 'REVERSE'}, base.copyWith(driveMode: DriveMode.eco));
      expect(reverse.reverse, isTrue);
      expect(reverse.driveMode, DriveMode.eco);
      // HHMIS collapses LIMPHOME into the literal "ECO"; the string never
      // arrives, so it must not drive limp mode.
      final limp = apply({'STR_VEHICLE_DRIVE_MODE': 'LIMPHOME'});
      expect(apply({'STR_VEHICLE_DRIVE_MODE': 'PARK'}, reverse).reverse, isTrue, reason: 'HHMIS sends PARKED, never PARK');
      expect(limp.limpMode, isFalse);
      expect(limp, base);
      final parked = apply({'STR_VEHICLE_DRIVE_MODE': 'PARKED'}, reverse);
      expect(parked.reverse, isFalse);
      expect(parked.driveMode, DriveMode.eco);
      final back = apply({'STR_VEHICLE_DRIVE_MODE': 'NORMAL'}, base.copyWith(reverse: true));
      expect(back.reverse, isFalse);
      expect(back.driveMode, DriveMode.normal);
      // A newer MoveOS mode name must not throw or change the mode.
      final unknown = apply({'STR_VEHICLE_DRIVE_MODE': 'GH1'}, base.copyWith(driveMode: DriveMode.sport));
      expect(unknown.driveMode, DriveMode.sport);
    });

    test('vehicle state enum', () {
      final locked = apply({'INT_VEHICLE_STATE': 0});
      expect(locked.locked, isTrue);
      expect(locked.vehicleState, VehicleState.parked);
      final park = apply({'INT_VEHICLE_STATE': 3}, locked);
      expect(park.locked, isFalse);
      expect(park.vehicleState, VehicleState.parked);
      expect(apply({'INT_VEHICLE_STATE': 4}).vehicleState, VehicleState.ready);
      expect(apply({'INT_VEHICLE_STATE': 4, 'INT_VEHICLE_SPEED': 12}).vehicleState, VehicleState.riding);
      final rev = apply({'INT_VEHICLE_STATE': 5});
      expect(rev.vehicleState, VehicleState.ready);
      expect(rev.reverse, isTrue);
      final charging = apply({'INT_VEHICLE_STATE': 6});
      expect(charging.vehicleState, VehicleState.charging);
      expect(charging.isCharging, isTrue);
      expect(apply({'INT_VEHICLE_STATE': 99}).vehicleState, VehicleState.unknown);
    });

    test('MoveOS 5 smart park (state 7) sets parkAssist and clears on another state', () {
      final park = apply({'INT_VEHICLE_STATE': 7});
      expect(park.vehicleState, VehicleState.ready, reason: 'treated as motor-on, as stock does');
      expect(park.parkAssist, isTrue);
      expect(park.reverse, isFalse);
      // Leaving it clears the flag.
      expect(apply({'INT_VEHICLE_STATE': 4}, park).parkAssist, isFalse);
      // A batch with no state change leaves the flag as it was.
      expect(apply({'INT_VEHICLE_SPEED': 3}, park).parkAssist, isTrue);
    });

    test('speed alone promotes ready to riding and back', () {
      final ready = apply({'INT_VEHICLE_STATE': 4});
      final moving = apply({'INT_VEHICLE_SPEED': 20}, ready);
      expect(moving.vehicleState, VehicleState.riding);
      final stopped = apply({'INT_VEHICLE_SPEED': 0}, moving);
      expect(stopped.vehicleState, VehicleState.ready);
      // Parked stays parked even if a stray speed arrives.
      expect(apply({'INT_VEHICLE_SPEED': 5}).vehicleState, VehicleState.parked);
    });

    test('ESCL lock status: clean transitions change lockState and clear warnings; fail codes defer to the debounce', () {
      expect(apply({'INT_VEHICLE_ESCL_STATUS': 3}).lockState, 4);
      final unlocked = apply({'INT_VEHICLE_ESCL_STATUS': 1}, base.copyWith(lockState: 4));
      expect(unlocked.lockState, 0);
      // Fail codes (2 and 4) are only turned into warnings after the 3 s
      // debounce in AidlVehicleNotifier (mirrors stock HHMIC's
      // checkESCL{Lock,Unlock}FailedStatus postDelayed 0xBB8). The pure
      // mapping stays a no-op so transient blips never set the flag.
      expect(apply({'INT_VEHICLE_ESCL_STATUS': 2}).unlockFailedWarning, isFalse);
      expect(apply({'INT_VEHICLE_ESCL_STATUS': 4}).lockFailedWarning, isFalse);
      // A clean status still clears a previously-set warning.
      final cleared = apply({'INT_VEHICLE_ESCL_STATUS': 3}, base.copyWith(lockFailedWarning: true));
      expect(cleared.lockFailedWarning, isFalse);
      final clearedUnlock = apply({'INT_VEHICLE_ESCL_STATUS': 1}, base.copyWith(unlockFailedWarning: true));
      expect(clearedUnlock.unlockFailedWarning, isFalse);
    });

    test('BOOL_HEAD_UNIT_POWER_FLAG drives touchDisabled (inverse of the flag)', () {
      expect(apply({'BOOL_HEAD_UNIT_POWER_FLAG': true}).touchDisabled, isFalse);
      expect(apply({'BOOL_HEAD_UNIT_POWER_FLAG': false}).touchDisabled, isTrue);
      // A non-bool is ignored (never clobbers a prior value).
      final hot = base.copyWith(touchDisabled: true);
      expect(apply({'BOOL_HEAD_UNIT_POWER_FLAG': 'junk'}, hot).touchDisabled, isTrue);
    });

    test('trunk status: 2 is open, 3 is closed', () {
      final open = apply({'INT_VEHICLE_TRUNK_STATUS': 2});
      expect(open.trunkOpen, isTrue);
      expect(open.trunkStateKnown, isTrue);
      expect(apply({'INT_VEHICLE_TRUNK_STATUS': 3}, open).trunkOpen, isFalse);
      expect(apply({'INT_VEHICLE_TRUNK_STATUS': 1}).trunkStateKnown, isFalse);
    });

    // HHMIS's own table (VehicleManager.setChargingStatus), not HVDP's
    // ChargingStatus ordinals: 0 off, 1 in progress, 2 complete, -1 error.
    test('charge status and charger type', () {
      final charging = apply({'INT_CHARGE_STATUS': 1});
      expect(charging.isCharging, isTrue);
      expect(charging.chargingState, ChargingState.charging);
      final done = apply({'INT_CHARGE_STATUS': 2}, charging);
      expect(done.chargingState, ChargingState.complete);
      expect(done.safeToUnplug, isTrue);
      final off = apply({'INT_CHARGE_STATUS': 0}, done);
      expect(off.isCharging, isFalse);
      expect(off.chargingState, ChargingState.normal);
      expect(apply({'INT_CHARGE_STATUS': -1}).chargingState, ChargingState.notCharging);
      expect(apply({'INT_CHARGE_STATUS': 3}, charging), charging, reason: 'HHMIS never sends 3');
      expect(apply({'INT_CHARGE_STATUS': 7}, charging), charging);
      expect(apply({'INT_CHARGE_MODE': 6}).isBoostCharger, isTrue);
      expect(apply({'INT_CHARGE_MODE': 4}).isBoostCharger, isFalse);
      expect(apply({'INT_BOOST_HYPER_CHARGE_STATUS': 2}).isHyperCharger, isTrue);
      expect(apply({'INT_BOOST_HYPER_CHARGE_STATUS': 1}, base.copyWith(isHyperCharger: true)).isHyperCharger, isFalse,
          reason: '1 is a boost charger');
      expect(apply({'INT_BOOST_HYPER_CHARGE_STATUS': 0}, base.copyWith(isHyperCharger: true)).isHyperCharger, isFalse);
      expect(apply({'BOOL_VEHICLE_CONNECTOR_LATCHED': true}, done).safeToUnplug, isFalse);
    });

    test('charge times stay minutes; negatives clamp to idle 0', () {
      final v = apply({'INT_BATTERY_TIME_TO_FULL_CHARGE_UPDATE': 100, 'INT_BATTERY_OPTIMUM_CHARGE_TIME': 55});
      expect(v.minutesToFull, 100);
      expect(v.minutesTo80, 55);
      expect(apply({'INT_BATTERY_TIME_TO_FULL_CHARGE_UPDATE': -1}).minutesToFull, 0);
    });

    // Stock is -V*A/1000 * 0.70833, shown only in
    // MOTOR_ON / REVERSE. Current is positive into the battery, so a
    // positive A here is regen → negative power.
    test('power is -V*A / 1000 on stock\'s 8.5/12 scale; temps round to int', () {
      final on = base.copyWith(vehicleState: VehicleState.ready);
      final regen = apply({'FLOAT_VEHICLE_VOLTAGE': 50.0, 'FLOAT_VEHICLE_CURRENT': 40.0}, on);
      expect(regen.power, closeTo(-1.42, 0.001));
      final discharge = apply({'FLOAT_VEHICLE_VOLTAGE': 50.0, 'FLOAT_VEHICLE_CURRENT': -40.0}, on);
      expect(discharge.power, closeTo(1.42, 0.001));
      // A ride at 78 km/h: -227.8 A, raw 10.99 kW. Stock shows 7.8.
      final peak = apply({'FLOAT_VEHICLE_VOLTAGE': 48.244, 'FLOAT_VEHICLE_CURRENT': -227.8}, on);
      expect(peak.power, closeTo(7.78, 0.001));
      // The pack's 12 kW is the cluster's 8.5 kW.
      expect(12 * HhmisPower.displayScale, closeTo(8.5, 1e-5));
      final t = apply({'FLOAT_MOTOR_TEMPERATURE': 61.6, 'FLOAT_BATTERY_EFF_TEMP': 33.2});
      expect(t.motorTemp, 62);
      expect(t.batteryTemp, 33);
    });

    group('power motor-on gate (stock updateWidgetPower)', () {
      const draw = {'FLOAT_VEHICLE_VOLTAGE': 55.0, 'FLOAT_VEHICLE_CURRENT': -20.0};

      test('parked, locked or charging reads zero whatever the pack is doing', () {
        expect(apply(draw, base.copyWith(vehicleState: VehicleState.parked, power: 3)).power, 0);
        // The charger: +13 A into the pack used to read as 0.7 kW of regen.
        final charging = apply(
          {'FLOAT_VEHICLE_VOLTAGE': 56.0, 'FLOAT_VEHICLE_CURRENT': 13.0},
          base.copyWith(vehicleState: VehicleState.charging, isCharging: true, power: -0.7),
        );
        expect(charging.power, 0);
      });

      test('MOTOR_ON, riding and REVERSE all show power', () {
        expect(apply(draw, base.copyWith(vehicleState: VehicleState.ready)).power, closeTo(0.78, 0.001));
        expect(apply(draw, base.copyWith(vehicleState: VehicleState.riding, speed: 30)).power, closeTo(0.78, 0.001));
        expect(apply({...draw, 'INT_VEHICLE_STATE': 5}).power, closeTo(0.78, 0.001));
      });

      test('the state change alone zeroes and restores it, from the kept volts and amps', () {
        final power = HhmisPower();
        var v = applyHhmisUpdate(base, {'INT_VEHICLE_STATE': 4, ...draw}, power: power);
        expect(v.power, closeTo(0.78, 0.001));
        v = applyHhmisUpdate(v, {'INT_VEHICLE_SPEED': 0}, power: power);
        expect(v.power, closeTo(0.78, 0.001), reason: 'an unrelated batch leaves it alone');
        v = applyHhmisUpdate(v, {'INT_VEHICLE_STATE': 3}, power: power);
        expect(v.power, 0, reason: 'MOTOR_ON → PARK with no volts or amps in the batch');
        v = applyHhmisUpdate(v, {'FLOAT_VEHICLE_CURRENT': -30.0}, power: power);
        expect(v.power, 0);
        v = applyHhmisUpdate(v, {'INT_VEHICLE_STATE': 4}, power: power);
        expect(v.power, closeTo(1.17, 0.001), reason: 'back on: the latest sample, not the one from before');
      });
    });

    test('daily strings parse leniently', () {
      final v = apply({
        'STR_VEHICLE_TOP_SPEED': '72 km/h',
        'STR_VEHICLE_AVG_SPEED': '34',
        'STR_VEHICLE_TOTAL_DISTANCE_DAY_WITH_METER': '18.4',
        'STR_RIDE_EFFICIENCY_UPDATED_FOR_THE_DAY': '42.5',
        'STR_VEHICLE_DISTANCE_COVERED_IN_ECO_MODE_FOR_THE_DAY': 'garbage',
      });
      expect(v.dailyTopSpeed, 72);
      expect(v.dailyAvgSpeed, 34);
      expect(v.dailyDistance, 18);
      expect(v.rideEfficiency, closeTo(42.5, 0.001));
      expect(v.ecoDistance, 0);
    });

    test('tripMeter is Trip B (`_BY_ALL_USERS`, confusingly named), meters / 1000', () {
      // Proven by raw-value capture on a ride: cmd 28
      // (VOID_RESET_TRIPO_METER_B) zeroed `_BY_ALL_USERS` while
      // `_BY_INDIVIDUAL_USER` kept incrementing. The naming is misleading
      // but the behaviour is empirically clear.
      expect(apply({'STR_VEHICLE_DISTANCE_COVERED_BY_ALL_USERS': '12345'}).tripMeter,
          closeTo(12.345, 1e-6));
      // The generic key arrives as "0" and stock only logs it: ignored,
      // and not reported as unknown.
      final unknown = <String>[];
      final out = applyHhmisUpdate(base, {'STR_VEHICLE_DISTANCE_COVERED': '128400'},
          onUnknown: unknown.add);
      expect(out.tripMeter, base.tripMeter, reason: 'generic key is ignored');
      // Trip A (`_BY_INDIVIDUAL_USER`) is intentionally NOT mapped — it is
      // the counter that does NOT reset on cmd 28, i.e. the one riders
      // complained about.
      final outA = applyHhmisUpdate(base, {'STR_VEHICLE_DISTANCE_COVERED_BY_INDIVIDUAL_USER': '50000'},
          onUnknown: unknown.add);
      expect(outA.tripMeter, base.tripMeter);
      expect(unknown, isEmpty);
    });

    test('hyper charge times from INT_FC_BATTERY_* keys', () {
      expect(apply({'INT_FC_BATTERY_TIME_TO_FULL_CHARGE_UPDATE': 85}).hyperMinutesToFull, 85);
      expect(apply({'INT_FC_BATTERY_OPTIMUM_CHARGE_UPDATE': 25}).hyperMinutesTo80, 25);
      // Wrong type ignored, prior value kept.
      final warm = base.copyWith(hyperMinutesToFull: 120);
      expect(apply({'INT_FC_BATTERY_TIME_TO_FULL_CHARGE_UPDATE': 'junk'}, warm).hyperMinutesToFull, 120);
    });

    test('INT_HMI_STATUSBAR_STATUS maps to HmiStatusBarStt', () {
      expect(apply({'INT_HMI_STATUSBAR_STATUS': 0}).chargeSubstate, ChargeSubstate.sna);
      expect(apply({'INT_HMI_STATUSBAR_STATUS': 1}).chargeSubstate, ChargeSubstate.chargeComplete);
      expect(apply({'INT_HMI_STATUSBAR_STATUS': 2}).chargeSubstate, ChargeSubstate.chargingSlowly);
      expect(apply({'INT_HMI_STATUSBAR_STATUS': 3}).chargeSubstate, ChargeSubstate.notCharging);
      // HHMIS never forwards HVDP's INITIALIZING_HYPERCHARGER.
      expect(apply({'INT_HMI_STATUSBAR_STATUS': 4}).chargeSubstate, ChargeSubstate.sna);
      // Unknown ordinal falls back to SNA (safer than silently keeping old value).
      expect(apply({'INT_HMI_STATUSBAR_STATUS': 99}).chargeSubstate, ChargeSubstate.sna);
    });

    test('INT_HMI_STATUSBAR_STATUS also drives chargingState + safeToUnplug', () {
      // INT_CHARGE_STATUS is never broadcast on this firmware, so the
      // status-bar substate is what tells us charge-complete vs still-charging.
      final complete = apply({'INT_HMI_STATUSBAR_STATUS': 1});
      expect(complete.chargingState, ChargingState.complete);
      expect(complete.safeToUnplug, isTrue);

      final charging = apply({'INT_HMI_STATUSBAR_STATUS': 2});
      expect(charging.chargingState, ChargingState.charging);
      expect(charging.safeToUnplug, isFalse);

      final notCharging = apply({'INT_HMI_STATUSBAR_STATUS': 3});
      expect(notCharging.chargingState, ChargingState.notCharging);
      expect(notCharging.safeToUnplug, isFalse);

      // SNA leaves chargingState alone (no clobbering during the brief gap
      // between plug-in and the first substate broadcast).
      final warm = base.copyWith(chargingState: ChargingState.charging, safeToUnplug: false);
      final sna = apply({'INT_HMI_STATUSBAR_STATUS': 0}, warm);
      expect(sna.chargingState, ChargingState.charging);
    });

    test('leaving a status-bar substate for SNA drops what the substate set', () {
      final unplugged = apply({'INT_HMI_STATUSBAR_STATUS': 3});
      expect(unplugged.chargingState, ChargingState.notCharging);
      final after = apply({'INT_HMI_STATUSBAR_STATUS': 0}, unplugged);
      expect(after.chargeSubstate, ChargeSubstate.sna);
      expect(after.chargingState, ChargingState.normal, reason: 'the charger is gone');
      final done = apply({'INT_HMI_STATUSBAR_STATUS': 1}, base.copyWith(isCharging: true));
      final topUp = apply({'INT_HMI_STATUSBAR_STATUS': 0}, done);
      expect(topUp.chargingState, ChargingState.charging, reason: 'still plugged in');
      expect(topUp.safeToUnplug, isFalse);
      // A steady 0 does not undo what INT_CHARGE_STATUS said.
      final complete = base.copyWith(isCharging: true, chargingState: ChargingState.complete, safeToUnplug: true);
      expect(apply({'INT_HMI_STATUSBAR_STATUS': 0}, complete).chargingState, ChargingState.complete);
    });

    test('battery temperature moves only once the reading is a whole degree away', () {
      var v = apply({'FLOAT_BATTERY_EFF_TEMP': 30.4});
      expect(v.batteryTemp, 30);
      v = apply({'FLOAT_BATTERY_EFF_TEMP': 30.6}, v);
      expect(v.batteryTemp, 30, reason: 'x.5 jitter does not flip the digit');
      v = apply({'FLOAT_BATTERY_EFF_TEMP': 29.4}, v);
      expect(v.batteryTemp, 30);
      v = apply({'FLOAT_BATTERY_EFF_TEMP': 31.0}, v);
      expect(v.batteryTemp, 31);
      v = apply({'FLOAT_BATTERY_EFF_TEMP': 29.9}, v);
      expect(v.batteryTemp, 30);
    });

    test('FLOAT_BATTERY_MIN_TEMP / MAX_TEMP populate the new fields', () {
      final v = apply({'FLOAT_BATTERY_MIN_TEMP': 30.5, 'FLOAT_BATTERY_MAX_TEMP': 33.2});
      expect(v.batteryMinTemp, closeTo(30.5, 1e-9));
      expect(v.batteryMaxTemp, closeTo(33.2, 1e-9));
      // Null preserves the last reading.
      final warm = base.copyWith(batteryMinTemp: () => 30.5, batteryMaxTemp: () => 33.2);
      expect(apply({}, warm).batteryMinTemp, 30.5);
    });

    test('BOOL_FC_CHARGE_IDLE_STATUS + BOOL_VEHICLE_REGEN_NOTIFICATION_STATUS', () {
      expect(apply({'BOOL_FC_CHARGE_IDLE_STATUS': true}).fcChargeIdle, isTrue);
      expect(apply({'BOOL_FC_CHARGE_IDLE_STATUS': false}).fcChargeIdle, isFalse);
      expect(apply({'BOOL_VEHICLE_REGEN_NOTIFICATION_STATUS': true}).regenNotification, isTrue);
    });

    test('INT_VEHICLE_BRIGHTNESS populates vehicleBrightness, clamped 0-100', () {
      expect(apply({'INT_VEHICLE_BRIGHTNESS': 72}).vehicleBrightness, 72);
      expect(apply({'INT_VEHICLE_BRIGHTNESS': 150}).vehicleBrightness, 100);
      expect(apply({'INT_VEHICLE_BRIGHTNESS': -5}).vehicleBrightness, 0);
      // A non-int is ignored (vehicleBrightness kept).
      final warm = base.copyWith(vehicleBrightness: () => 50);
      expect(apply({'INT_VEHICLE_BRIGHTNESS': 'junk'}, warm).vehicleBrightness, 50);
    });

    test('cruise, alerts and system flags', () {
      expect(apply({'INT_VEHICLE_CRUISE_MODE_STATUS': 1}).cruiseMode, CruiseMode.active);
      expect(apply({'INT_VEHICLE_CRUISE_MODE_STATUS': 0}).cruiseMode, CruiseMode.standby);
      expect(apply({'INT_VEHICLE_CRUISE_MODE_STATUS': 4}).cruiseMode, CruiseMode.off);
      expect(apply({'BOOL_CRUISE_CONTROL_STATUS': true}).cruiseMode, CruiseMode.active);
      expect(apply({'INT_TOW_THEFT_DETECTION_ALERT': 1}).tamperDetected, isTrue);
      expect(apply({'BOOL_ACCIDENT_SEVERITY_STAT': true}).accidentDetected, isTrue);
      expect(apply({'BOOL_BRAKE_WORN_OUT_STATUS': true}).brakeWorn, isTrue);
      // BOOL_PACK_SOH_STAT=true means degraded in
      // stock (not healthy). Default is unknown until the key arrives.
      expect(apply({'BOOL_PACK_SOH_STAT': true}).batteryHealthGood, isFalse);
      expect(apply({'BOOL_PACK_SOH_STAT': true}).batteryHealthKnown, isTrue);
      expect(apply({'BOOL_PACK_SOH_STAT': false}).batteryHealthGood, isTrue);
      expect(apply({'BOOL_PACK_SOH_STAT': false}).batteryHealthKnown, isTrue);
      expect(const VehicleData().batteryHealthKnown, isFalse, reason: 'default is unknown');
      expect(apply({'_wifi': true}).wifiConnected, isTrue);
      expect(apply({'_bt': true}).btConnected, isTrue);
      expect(apply({'_volume': 30}).volume, 30);
      expect(apply({'STR_PROXIMITY_BLE_PASSCODE': '482917'}).btPairingCode, '482917');
    });

    test('hill hold lights only on ACTIVE (2); HHMIS never sends 5 or 6', () {
      final on = base.copyWith(hillHoldActive: true);
      expect(apply({'INT_HILL_HOLD_STATUS': 2}).hillHoldActive, isTrue);
      for (final off in [0, 1, 3, 4, 5, 6]) {
        expect(apply({'INT_HILL_HOLD_STATUS': off}, on).hillHoldActive, isFalse, reason: 'status $off');
      }
    });

    // INT_CHARGE_STATUS = 0 (the usual clear path)
    // is transition-only and has been missed in logs; CHARGE_MODE
    // leaving {3,4,6} together with a non-CHARGING vehicle state must
    // also clear isCharging.
    test('isCharging clears on CHARGE_MODE + VEHICLE_STATE even without STATUS 0', () {
      final charging = base.copyWith(
          isCharging: true,
          chargingState: ChargingState.charging,
          vehicleState: VehicleState.charging);
      // Unplug: the status 0 was dropped; only CHARGE_MODE = 5 and PARK arrive.
      final after = apply({'INT_CHARGE_MODE': 5, 'INT_VEHICLE_STATE': 3}, charging);
      expect(after.isCharging, isFalse);
      expect(after.chargingState, ChargingState.normal);
      // While CHARGE_MODE is in the active set, isCharging stays true.
      final stillCharging = apply({'INT_CHARGE_MODE': 3}, charging);
      expect(stillCharging.isCharging, isTrue);
      // A matching CHARGING state keeps isCharging on even if the mode is 5.
      final chargingState6 = apply({'INT_CHARGE_MODE': 5, 'INT_VEHICLE_STATE': 6}, charging);
      expect(chargingState6.isCharging, isTrue);
    });

    // Accident is raised by BOOL_ACCIDENT_SEVERITY_STAT,
    // not BOOL_FALL_DETECTED_L2_PHASE (which stock HHMIS never emits).
    test('accident is driven by BOOL_ACCIDENT_SEVERITY_STAT, not L2 phase', () {
      expect(apply({'BOOL_ACCIDENT_SEVERITY_STAT': true}).accidentDetected, isTrue);
      // Stock acts on true only; the screen waits for the
      // rider's answer or the end of ALARM.
      expect(apply({'BOOL_ACCIDENT_SEVERITY_STAT': false}, base.copyWith(accidentDetected: true)).accidentDetected, isTrue);
      // L2 phase no longer triggers anything.
      expect(apply({'BOOL_FALL_DETECTED_L2_PHASE': true}).accidentDetected, isFalse);
      expect(apply({'BOOL_FALL_DETECTED_L2_PHASE': true}).fallDetected, isFalse);
    });

    // INT_VEHICLE_STATE=1 is the tamper alarm. It is not folded into the
    // ordinary lock screen; a parallel alarmActive flag carries it so the
    // alarm screen can replace the UI.
    test('alarm state raises alarmActive and does not force lockState=4', () {
      final a = apply({'INT_VEHICLE_STATE': 1});
      expect(a.alarmActive, isTrue);
      expect(a.lockState, isNot(4), reason: 'lock screen must not be shown during an alarm');
      // Leaving alarm clears it.
      final after = apply({'INT_VEHICLE_STATE': 3}, a);
      expect(after.alarmActive, isFalse);
    });

    // Fall is driven by INT_FALL_DETECTION_ALERT (1 =
    // active). L1 and L2 are empty in stock VIM and never sent.
    test('fall is driven by INT_FALL_DETECTION_ALERT', () {
      expect(apply({'INT_FALL_DETECTION_ALERT': 1}).fallDetected, isTrue);
      for (final over in [0, 2, 3]) {
        expect(apply({'INT_FALL_DETECTION_ALERT': over}, base.copyWith(fallDetected: true)).fallDetected, isFalse,
            reason: 'value $over');
      }
      expect(apply({'BOOL_FALL_DETECTED_L1_PHASE': true}).fallDetected, isFalse);
      final unknown = <String>[];
      applyHhmisUpdate(base, {'BOOL_FALL_DETECTED_L1_PHASE': true, 'BOOL_FALL_DETECTED_L2_PHASE': true}, onUnknown: unknown.add);
      expect(unknown, isEmpty, reason: 'ignored on purpose, not unknown');
    });

    // Stock's TamperFallStatus goes to 0 only
    // when the vehicle leaves ALARM, and that takes all three screens down.
    test('leaving ALARM clears tamper, fall and accident; nothing else does', () {
      final alarm = apply({'INT_VEHICLE_STATE': 1}, base.copyWith(tamperDetected: true, fallDetected: true, accidentDetected: true));
      expect((alarm.tamperDetected, alarm.fallDetected, alarm.accidentDetected), (true, true, true));
      for (final state in [0, 2, 3, 4, 5, 6]) {
        final left = apply({'INT_VEHICLE_STATE': state}, alarm);
        expect((left.alarmActive, left.tamperDetected, left.fallDetected, left.accidentDetected), (false, false, false, false),
            reason: 'state $state');
      }
      final lockToPasscode = apply({'INT_VEHICLE_STATE': 2}, base.copyWith(tamperDetected: true, lockState: 4));
      expect(lockToPasscode.tamperDetected, isTrue, reason: 'no ALARM was left');
    });

    // Thermal runaway has its own field and
    // its own critical alert (stock's "Scooter Issue, please maintain a safe
    // distance"). Plugging in no longer clears it: the rider must see the
    // event even if the next thing they do is charge the scooter.
    test('thermal runaway is a one-shot that CHARGING does not clear', () {
      expect(apply({'INT_THERMAL_RUNAWAY': 2}).thermalRunaway, isTrue);
      expect(apply({'INT_THERMAL_RUNAWAY': 1}).thermalRunaway, isTrue);
      final hot = base.copyWith(thermalRunaway: true);
      expect(apply({'INT_THERMAL_RUNAWAY': 0}, hot).thermalRunaway, isTrue, reason: 'stock never sends a zero');
      expect(apply({'INT_VEHICLE_STATE': 4}, hot).thermalRunaway, isTrue);
      for (final s in [0, 1, 2, 3, 6]) {
        expect(apply({'INT_VEHICLE_STATE': s}, hot).thermalRunaway, isTrue,
            reason: 'state $s must not acknowledge the runaway alert');
      }
    });

    test('range by mode arrives eco, normal, sport, hyper', () {
      final v = apply({'_rangeByMode': [180, 140, 110, 90]});
      expect(v.rangeEco, 180);
      expect(v.rangeNormal, 140);
      expect(v.rangeSport, 110);
      expect(v.rangeHyper, 90);
    });

    test('lock and charge keys give the same result in either batch order', () {
      final a = apply({'INT_CHARGE_STATUS': 1, 'INT_VEHICLE_STATE': 0});
      final b = apply({'INT_VEHICLE_STATE': 0, 'INT_CHARGE_STATUS': 1});
      expect(a, b);
      expect(a.isCharging, isTrue, reason: 'charge status owns isCharging');
      expect(a.locked, isTrue);
      final c = apply({'INT_VEHICLE_ESCL_STATUS': 1, 'INT_VEHICLE_STATE': 0});
      final d = apply({'INT_VEHICLE_STATE': 0, 'INT_VEHICLE_ESCL_STATUS': 1});
      expect(c, d);
      expect(c.locked, isFalse, reason: 'the specific lock status wins over the coarse state');
    });

    test('locking while plugged in keeps the charging screen', () {
      final charging = apply({'INT_CHARGE_STATUS': 1});
      final locked = apply({'INT_VEHICLE_STATE': 0}, charging);
      expect(locked.isCharging, isTrue);
      expect(locked.locked, isTrue);
      final unplugged = apply({'INT_CHARGE_STATUS': 0}, locked);
      expect(unplugged.isCharging, isFalse);
    });

    test('take-me-home feature echo does not light the indicator', () {
      expect(apply({'BOOL_TAKE_ME_HOME_TOGGLE_STAT': true}).takeMeHomeLights, isFalse);
    });

    test('bus voltage, pack current and tow-theft sensor fields', () {
      final v = apply({'FLOAT_VEHICLE_VOLTAGE': 52.4, 'FLOAT_VEHICLE_CURRENT': -9.2});
      expect(v.busVoltage, closeTo(52.4, 1e-9));
      expect(v.packCurrent, closeTo(-9.2, 1e-9));
      // TowTheftDetection: 0 SNA, 1 ACTIVE, 2 INACTIVE. Only 1 is an alarm.
      final tow = apply({'INT_TOW_THEFT_DETECTION_ALERT': 1});
      expect(tow.tamperDetected, isTrue);
      expect(tow.towTheftState, 1);
      // Stock acts on 1 only: 0 and 2 neither raise nor clear, and 153
      // (TAMPER_PASS_EXIT on the same key) is not a tow state at all.
      for (final quiet in [0, 2]) {
        final still = apply({'INT_TOW_THEFT_DETECTION_ALERT': quiet}, tow);
        expect(still.tamperDetected, isTrue, reason: 'value $quiet');
        expect(still.towTheftState, quiet);
        expect(apply({'INT_TOW_THEFT_DETECTION_ALERT': quiet}).tamperDetected, isFalse, reason: 'value $quiet');
      }
      for (final from in [base, tow]) {
        final passExit = apply({'INT_TOW_THEFT_DETECTION_ALERT': 153}, from);
        expect(passExit.tamperDetected, from.tamperDetected);
        expect(passExit.towTheftState, from.towTheftState);
      }
      // HVDP RegenAvailability: 0 NOT_AVAILABLE, 1 AVAILABLE.
      final unavailable = apply({'BOOL_VEHICLE_REGEN_AVAIL_STATUS': false});
      expect(unavailable.regenAvailability, 0);
      expect(unavailable.regenAvailabilityKnown, isTrue);
      expect(apply({'BOOL_VEHICLE_REGEN_AVAIL_STATUS': true}, base.copyWith(regenAvailability: 0)).regenAvailability, 1);
      expect(base.regenAvailabilityKnown, isFalse);
    });

    test('wrong value types are ignored rather than thrown', () {
      final v = apply({'INT_VEHICLE_SPEED': 'fast', 'BOOL_HIGH_BEAM_STATUS': 1, 'INT_VEHICLE_STATE': null});
      expect(v.speed, 0);
      expect(v.highBeam, isFalse);
    });

    test('REGEN_SETTINGS_UPDATE carries the vehicle persisted RegenState', () {
      expect(apply({'REGEN_SETTINGS_UPDATE': 0}).regenMode, RegenMode.standard);
      expect(apply({'REGEN_SETTINGS_UPDATE': 1}).regenMode, RegenMode.highway);
      expect(apply({'REGEN_SETTINGS_UPDATE': 2}).regenMode, RegenMode.city);
      expect(apply({'REGEN_SETTINGS_UPDATE': 3}).regenMode, RegenMode.off);
      final city = base.copyWith(regenMode: RegenMode.city);
      expect(apply({'REGEN_SETTINGS_UPDATE': 9}, city).regenMode, RegenMode.city, reason: 'out of range is ignored');
      expect(apply({'REGEN_SETTINGS_UPDATE': -1}, city).regenMode, RegenMode.city);
      expect(apply({'REGEN_SETTINGS_UPDATE': 'junk'}, city).regenMode, RegenMode.city,
          reason: 'wrong type leaves the value alone');
    });

    test('keys acted on outside the mapping are not reported unknown', () {
      final unknown = <String>[];
      for (final key in [
        'INT_BT_MUSIC_COMMAND',
        'INT_PROFILE_REMAINING_ATTEMPTS',
        'BOOL_PROFILE_PASSCODE_CHANGED_ACK',
        'INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST',
      ]) {
        expect(applyHhmisUpdate(base, {key: 1}, onUnknown: unknown.add), base, reason: key);
      }
      expect(unknown, isEmpty);
    });

    test('BOOL_*_PERSIST_TOGGLE_STAT echoes populate featureMirror by RidingFeature.name', () {
      final out = apply({
        'BOOL_APB_PERSIST_TOGGLE_STAT': true,
        'BOOL_HILL_HOLD_PERSIST_TOGGLE_STAT': false,
        'BOOL_ACCIDENT_DETECTION_PERSIST_TOGGLE_STAT': true,
        'BOOL_TOW_THEFT_PERSIST_TOGGLE_STAT': false,
        'BOOL_PROXIMITY_PERSIST_TOGGLE_STAT': true,
        'BOOL_SMART_DRL_PERSIST_TOGGLE_STAT': false,
        'BOOL_AUTO_HEADLIGHT_PERSIST_TOGGLE_STAT': true,
        'BOOL_MOTOR_CUTOFF_PERSIST_TOGGLE_STAT': true,
        'BOOL_VACATION_PERSIST_TOGGLE_STAT': false,
        'BOOL_PREDICT_RANGE_PERSIST_TOGGLE_STAT': true,
        'BOOL_TAKE_ME_HOME_PERSIST_TOGGLE_STAT': false,
        'BOOL_AUTO_INDICATOR_PERSIST_TURNOFF_TOGGLE_STAT': true,
        'BOOL_SIDE_STAND_PERSIST_TOGGLE': false,
      });
      expect(out.featureMirror['adaptivePowerBoost'], isTrue);
      expect(out.featureMirror['hillHold'], isFalse);
      expect(out.featureMirror['fallDetection'], isTrue);
      expect(out.featureMirror['tamper'], isFalse);
      expect(out.featureMirror['proximityUnlock'], isTrue);
      expect(out.featureMirror['smartHeadlight'], isNull, reason: 'HHMIS sends smart headlight only as an int key');
      expect(out.featureMirror['smartDrl'], isFalse);
      expect(out.featureMirror['autoHeadlight'], isTrue);
      expect(out.featureMirror['motorCutOff'], isTrue);
      expect(out.featureMirror['vacationMode'], isFalse);
      expect(out.featureMirror['predictedRange'], isTrue);
      expect(out.featureMirror['takeMeHome'], isFalse);
      expect(out.featureMirror['autoTurnOff'], isTrue, reason: 'ClientCmd 51, auto indicator turn-off');
      expect(out.featureMirror['sideStandCutOff'], isNull,
          reason: 'not mirrored: its polarity is unknown, and false on a MoveOS 5 scooter whose sensor worked');
    });

    group('feature availability', () {
      test('BOOL_*_FEATURE_AVAILABLE keys fill featureAvailable by feature name', () {
        // The values a Gen 1 scooter on 4.6.14 reports.
        final out = apply({
          'BOOL_BOOST_MODE_FEATURE_AVAILABLE': false,
          'BOOL_ACCIDENT_DETECTION_FEATURE_AVAILABLE': true,
          'BOOL_PROXIMITY_LOCK_FEATURE_AVAILABLE': false,
          'BOOL_SMART_HEAD_LIGHT_FEATURE_AVAILABLE': false,
          'BOOL_SMART_DRL_LIGHT_FEATURE_AVAILABLE': true,
          'BOOL_HAZARD_LIGHT_FEATURE_AVAILABLE': true,
          'BOOL_AUTO_INDICATOR_TURN_OFF_FEATURE_AVAILABLE': true,
          'BOOL_MOTOR_CUTOFF_DELAY_FEATURE_AVAILABLE': false,
        });
        expect(out.featureAvailable, {
          'adaptivePowerBoost': false,
          'fallDetection': true,
          'proximityUnlock': false,
          'smartHeadlight': false,
          'smartDrl': true,
          'hazard': true,
          'autoTurnOff': true,
          'motorCutOff': false,
        });
        expect(out.featureAvailable['smartHeadlight'], isFalse);
        expect(out.isFeatureAvailable('smartHeadlight'), isTrue, reason: 'the one feature the flag does not gate');
        expect(out.isFeatureAvailable('proximityUnlock'), isFalse);
        expect(out.isFeatureAvailable('motorCutOff'), isFalse);
        expect(out.isFeatureAvailable('smartDrl'), isTrue);
        expect(out.isFeatureAvailable('autoHeadlight'), isTrue, reason: 'never reported on this scooter: unknown is available');
        expect(apply({'BOOL_AUTO_HEAD_LIGHT_FEATURE_AVAILABLE': false}).isFeatureAvailable('autoHeadlight'), isFalse);
      });

      test('INT_*_FEATURE_AVAILABLE: only 1 is available (tow/tamper arrives as 2)', () {
        final out = apply({
          'INT_TOW_TAMPER_DETECTION_FEATURE_AVAILABLE': 2,
          'INT_HILL_HOLD_FEATURE_AVAILABLE': 1,
          'INT_TAKE_ME_HOME_FEATURE_AVAILABLE': 0,
        });
        expect(out.featureAvailable, {'tamper': false, 'hillHold': true, 'takeMeHome': false});
        // Take-me-home flips 0 -> 1 a few batches into a boot.
        expect(apply({'INT_TAKE_ME_HOME_FEATURE_AVAILABLE': 1}, out).isFeatureAvailable('takeMeHome'), isTrue);
      });

      test('INT_TECH_PACH_REGEN gates regen, and is no longer ignored', () {
        expect(ignoredHhmisKeys, isNot(contains('INT_TECH_PACH_REGEN')));
        expect(apply({'INT_TECH_PACH_REGEN': 1}).isFeatureAvailable('regen'), isTrue);
        expect(apply({'INT_TECH_PACH_REGEN': 0}).isFeatureAvailable('regen'), isFalse);
        expect(apply({'INT_TECH_PACH_REGEN': 2}).isFeatureAvailable('regen'), isFalse);
      });

      test('a repeat of the same value keeps the same map; wrong types are skipped', () {
        final a = apply({'BOOL_BOOST_MODE_FEATURE_AVAILABLE': false});
        final b = apply({'BOOL_BOOST_MODE_FEATURE_AVAILABLE': false, 'INT_HILL_HOLD_FEATURE_AVAILABLE': 'x'}, a);
        expect(identical(a.featureAvailable, b.featureAvailable), isTrue);
        expect(apply({'BOOL_BOOST_MODE_FEATURE_AVAILABLE': 1}).featureAvailable, isEmpty);
      });
    });

    test('persisted settings: hill-hold consent, alarm sound, safety sensitivity', () {
      expect(base.hillHoldConsent, isNull);
      expect(apply({'INT_PERSISTED_USER_HILLHOLD_CONDITIONACCEPTED': 1}).hillHoldConsent, isTrue);
      expect(apply({'INT_PERSISTED_USER_HILLHOLD_CONDITIONACCEPTED': 0}).hillHoldConsent, isFalse);
      expect(apply({'INT_PERSISTED_ALARM_ALERT_SOUND': 1}).alarmSoundIndex, 1);
      expect(apply({'INT_PERSISTED_ALARM_ALERT_SOUND': 5}).alarmSoundIndex, isNull, reason: 'HHMIS has two sounds');
      expect(apply({'INT_PERSISTED_SAFETY_SENSITIVITY': 0}).safetySensitivity, 0);
      expect(apply({'INT_PERSISTED_SAFETY_SENSITIVITY': 1}).safetySensitivity, 1);
      expect(apply({'INT_PERSISTED_SAFETY_SENSITIVITY': -1}).safetySensitivity, isNull);
    });

    test('INT_VEHICLE_INCLINATION_DEGREE is whole degrees; a repeat changes nothing', () {
      final out = apply({'INT_VEHICLE_INCLINATION_DEGREE': -1});
      expect(out.inclinationDegrees, -1);
      expect(apply({'INT_VEHICLE_INCLINATION_DEGREE': -1}, out), out, reason: 'no rebuild for an unchanged value');
      expect(apply({'INT_VEHICLE_INCLINATION_DEGREE': 'x'}, out).inclinationDegrees, -1);
    });

    test('R-9: the *_TOGGLE_STAT acks are ignored, never feature state', () {
      final unknown = <String>[];
      final out = applyHhmisUpdate(base, {
        'BOOL_APB_TOGGLE_STAT': true,
        'BOOL_HILL_HOLD_TOGGLE_STAT': true,
        'BOOL_TOW_THEFT_TOGGLE_STAT': true,
        'BOOL_TAKE_ME_HOME_TOGGLE_STAT': true,
        'BOOL_VACATION_MODE_TOGGLE_STAT': true,
        'BOOL_SIDE_STAND_TOGGLE_STAT': true,
        'REGEN_SETTINGS_TOGGLE': 0,
      }, onUnknown: unknown.add);
      expect(out, base);
      expect(out.featureMirror, isEmpty);
      expect(unknown, isEmpty);
    });

    test('every key ride logs reported unknown is mapped or ignored', () {
      // INT_VEHICLE_MODE_AVAILABLE_STATUS is left out on purpose: the mode
      // ladder maps it.
      const seen = {
        'BOOL_ACCIDENT_DETECTION_FEATURE_AVAILABLE': true,
        'BOOL_ACCIDENT_SEVERITY_STAT': false,
        'BOOL_AUTO_INDICATOR_TURN_OFF_FEATURE_AVAILABLE': true,
        'BOOL_BOOST_MODE_FEATURE_AVAILABLE': false,
        'BOOL_BT_LOCK': true,
        'BOOL_HAZARD_LIGHT_FEATURE_AVAILABLE': true,
        'BOOL_MOTOR_CUTOFF_DELAY_FEATURE_AVAILABLE': false,
        'BOOL_PROXIMITY_LOCK_FEATURE_AVAILABLE': false,
        'BOOL_SMART_DRL_LIGHT_FEATURE_AVAILABLE': true,
        'BOOL_SMART_HEAD_LIGHT_FEATURE_AVAILABLE': false,
        'INT_HILL_HOLD_FEATURE_AVAILABLE': 1,
        'INT_PERSISTED_SAFETY_SENSITIVITY': 0,
        'INT_PERSISTED_USER_HILLHOLD_CONDITIONACCEPTED': 1,
        'INT_PROFILE_VEHICLE_TYPE': 3,
        'INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT': 0,
        'INT_TAKE_ME_HOME_FEATURE_AVAILABLE': 1,
        'INT_TOW_TAMPER_DETECTION_FEATURE_AVAILABLE': 2,
        'INT_VEHICLE_INCLINATION_DEGREE': -1,
        'REGEN_SETTINGS_TOGGLE': 0,
        'STR_PROFILE_SCOOTER_NAME': 'scooter',
        'STR_VEHICLE_DISTANCE_COVERED': '0',
        'STR_VEHICLE_DISTANCE_COVERED_BY_INDIVIDUAL_USER': '0',
        'STR_VEHICLE_TOTAL_DISTANCE_DAY_WITH_METER': '1.493',
      };
      final unknown = <String>[];
      applyHhmisUpdate(base, seen, onUnknown: unknown.add);
      expect(unknown, isEmpty);
    });
  });
}
