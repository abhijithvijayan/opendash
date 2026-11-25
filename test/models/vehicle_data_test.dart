import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';

void main() {
  group('VehicleData', () {
    test('defaults describe a parked, unlocked scooter with a full battery', () {
      const v = VehicleData();
      expect(v.speed, 0);
      expect(v.batterySoc, 100);
      expect(v.driveMode, DriveMode.normal);
      expect(v.vehicleState, VehicleState.parked);
      expect(v.isCharging, isFalse);
      expect(v.lockState, 0);
      expect(v.hhmisConnected, isFalse);
      expect(v.trunkStateKnown, isFalse);
      expect(v.signalBars, 3);
    });

    test('copyWith replaces only the given fields', () {
      const v = VehicleData(speed: 40, batterySoc: 50);
      final next = v.copyWith(speed: 64);
      expect(next.speed, 64);
      expect(next.batterySoc, 50);
      expect(v.speed, 40);
    });

    test('value equality', () {
      expect(const VehicleData(speed: 10), const VehicleData(speed: 10));
      expect(const VehicleData(speed: 10), isNot(const VehicleData(speed: 11)));
    });

    // Nine constructor fields were missing from ==
    // and hashCode, so a copyWith that only changed one of them compared
    // equal to the original. The widget tree then skipped the rebuild.
    test('equality covers every constructor field', () {
      const v = VehicleData();
      expect(v.copyWith(batteryMaxTemp: () => 99.0), isNot(equals(v)), reason: 'batteryMaxTemp');
      expect(v.copyWith(batteryMinTemp: () => 5.0), isNot(equals(v)), reason: 'batteryMinTemp');
      expect(v.copyWith(chargeSubstate: ChargeSubstate.chargeComplete), isNot(equals(v)), reason: 'chargeSubstate');
      expect(v.copyWith(fcChargeIdle: true), isNot(equals(v)), reason: 'fcChargeIdle');
      expect(v.copyWith(featureMirror: const {'tamper': true}), isNot(equals(v)), reason: 'featureMirror');
      expect(v.copyWith(featureAvailable: const {'tamper': false}), isNot(equals(v)), reason: 'featureAvailable');
      expect(v.copyWith(hillHoldConsent: () => true), isNot(equals(v)), reason: 'hillHoldConsent');
      expect(v.copyWith(alarmSoundIndex: () => 1), isNot(equals(v)), reason: 'alarmSoundIndex');
      expect(v.copyWith(safetySensitivity: () => 1), isNot(equals(v)), reason: 'safetySensitivity');
      expect(v.copyWith(inclinationDegrees: () => -1), isNot(equals(v)), reason: 'inclinationDegrees');
      expect(v.copyWith(hyperMinutesTo80: 7), isNot(equals(v)), reason: 'hyperMinutesTo80');
      expect(v.copyWith(regenNotification: true), isNot(equals(v)), reason: 'regenNotification');
      expect(v.copyWith(touchDisabled: true), isNot(equals(v)), reason: 'touchDisabled');
      expect(v.copyWith(vehicleBrightness: () => 80), isNot(equals(v)), reason: 'vehicleBrightness');
    });

    test('new tell-tale fields round-trip through copyWith and equality', () {
      const v = VehicleData();
      final next = v.copyWith(
        hillHoldActive: true,
        regenActive: true,
        regenMode: RegenMode.city,
        brakeWorn: true,
        tamperDetected: true,
        fallDetected: true,
        takeMeHomeLights: true,
        takeMeHomeLightsRemaining: 45,
        autoTurnOff: true,
        positionLight: true,
        accidentDetected: true,
        thermalRunaway: true,
        deratingActive: true,
        faultCode: 'E042',
      );
      expect(next.regenMode, RegenMode.city);
      expect(next.takeMeHomeLightsRemaining, 45);
      expect(next.faultCode, 'E042');
      expect(next, isNot(v));
      expect(next, next.copyWith());
      expect(v.copyWith(regenMode: RegenMode.highway), isNot(v.copyWith(regenMode: RegenMode.standard)));
    });
  });

  group('CustomRideMode', () {
    test('config round-trips and leaves out the live figures', () {
      const m = CustomRideMode(
        name: 'Rain', enabled: true, isDefault: false, topSpeedKmh: 70,
        powerPercent: 60, throttle: 2, regen: 3, rangeKm: 80, todayKm: 12.5,
      );
      final back = CustomRideMode.decodeConfig(m.encodeConfig());
      expect(back.name, 'Rain');
      expect(back.enabled, isTrue);
      expect(back.topSpeedKmh, 70);
      expect(back.known, isTrue, reason: 'so the ladder row and By-mode bar show from boot');
      expect(back.rangeKm, isNull, reason: 'live range is not identity');
      expect(back.todayKm, isNull, reason: 'live distance is not identity');
    });

    test('an empty or damaged blob decodes to an unknown mode', () {
      expect(CustomRideMode.decodeConfig('').known, isFalse);
      expect(CustomRideMode.decodeConfig('not json').known, isFalse);
      expect(CustomRideMode.decodeConfig('[1,2]').known, isFalse);
      // A mode with nothing set does not write anything that reads as known.
      expect(CustomRideMode.decodeConfig(const CustomRideMode().encodeConfig()).known, isFalse);
    });
  });

  group('DriveMode', () {
    test('parses contract strings case-insensitively', () {
      expect(DriveMode.parse('ECO'), DriveMode.eco);
      expect(DriveMode.parse('hyper'), DriveMode.hyper);
      expect(DriveMode.parse('nonsense'), DriveMode.normal);
    });

    test('labels match the contract', () {
      expect(DriveMode.sport.label, 'SPORT');
    });
  });

  group('VehicleState', () {
    test('maps contract ints', () {
      expect(VehicleState.fromInt(0), VehicleState.parked);
      expect(VehicleState.fromInt(2), VehicleState.riding);
      expect(VehicleState.fromInt(3), VehicleState.charging);
      expect(VehicleState.fromInt(99), VehicleState.unknown);
    });
  });

  group('alerts', () {
    test('side stand while motor is on is critical', () {
      const v = VehicleData(sideStand: true, vehicleState: VehicleState.ready);
      expect(v.alerts.map((a) => a.kind), contains(AlertKind.sideStand));
      expect(v.alerts.first.priority, AlertPriority.critical);
    });

    test('side stand while parked is not an alert', () {
      const v = VehicleData(sideStand: true, vehicleState: VehicleState.parked);
      expect(v.alerts, isEmpty);
    });

    test('low battery is critical unless charging', () {
      expect(const VehicleData(batterySoc: 9).alerts.map((a) => a.kind),
          contains(AlertKind.lowBattery));
      expect(const VehicleData(batterySoc: 9, isCharging: true).alerts,
          isEmpty);
      expect(const VehicleData(batterySoc: 10).alerts, isEmpty);
    });

    test('limp mode and trunk open while riding', () {
      expect(const VehicleData(limpMode: true).alerts.map((a) => a.kind),
          contains(AlertKind.limpMode));
      final trunk = const VehicleData(
              trunkOpen: true,
              trunkStateKnown: true,
              vehicleState: VehicleState.riding,
              speed: 12)
          .alerts;
      expect(trunk.single.kind, AlertKind.trunkOpen);
      expect(trunk.single.priority, AlertPriority.warning);
      expect(const VehicleData(trunkOpen: true).alerts, isEmpty);
    });

    test('banner actions: retry on a failed unlock, the notice passes its own through', () {
      final unlock = const VehicleData(unlockFailedWarning: true).alerts.single;
      expect(unlock.action, AlertAction.retryUnlock);
      const restart = VehicleNotice(72, 'Scooter issue', 'Restart the scooter', AlertPriority.critical,
          action: AlertAction.restartScooter);
      expect(const VehicleData(notice: restart).alerts.single.action, AlertAction.restartScooter);
      expect(const VehicleData(lockFailedWarning: true).alerts.single.action, isNull);
    });

    test('a countdown notice is a new value each second but the same alert identity', () {
      const a = VehicleNotice(9, 'Overheating', 'Switching to Park in 10 s', AlertPriority.warning);
      const b = VehicleNotice(9, 'Overheating', 'Switching to Park in 9 s', AlertPriority.warning);
      expect(a == b, isFalse);
      expect(const VehicleData(notice: a).alerts.single.key, const VehicleData(notice: b).alerts.single.key);
    });

    test('trunk open is ignored until the trunk state is known', () {
      const v = VehicleData(
          trunkOpen: true, vehicleState: VehicleState.riding, speed: 12);
      expect(v.alerts, isEmpty);
    });

    test('battery tiers: critical below 5, low from 5 to 9; no guess at "too low to ride"', () {
      Iterable<AlertKind> kinds(int soc) =>
          VehicleData(batterySoc: soc).alerts.map((a) => a.kind);
      expect(kinds(10), isNot(contains(AlertKind.lowBattery)));
      expect(kinds(9), contains(AlertKind.lowBattery));
      expect(kinds(5), contains(AlertKind.lowBattery));
      expect(kinds(5), isNot(contains(AlertKind.criticalBattery)));
      expect(kinds(4), contains(AlertKind.criticalBattery));
      expect(kinds(4), isNot(contains(AlertKind.lowBattery)));
      // Whether there is enough charge to ride is the
      // VCU's message (commands 4, 11), not a 3 % rule of ours.
      expect(kinds(2), [AlertKind.criticalBattery]);
      expect(const VehicleData(batterySoc: 2, isCharging: true).alerts, isEmpty);
      final critical = const VehicleData(batterySoc: 4).alerts.first;
      expect(critical.priority, AlertPriority.critical);
      final low = const VehicleData(batterySoc: 7).alerts.first;
      expect(low.priority, AlertPriority.warning);
    });

    test('two-tier thermal banner: an advance warning (SET-9), then critical at the Park limit', () {
      // Motor derates at 147; our advance fires 9 below (138), so 138 is clear.
      expect(const VehicleData(motorTemp: 138).alerts, isEmpty);
      // Advance band: a warning-priority "Heating up" banner, ahead of the derate.
      final warm = const VehicleData(motorTemp: 139).alerts.single;
      expect(warm.kind, AlertKind.thermalWarning);
      expect(warm.priority, AlertPriority.warning);
      expect(warm.title, 'Heating up');
      expect(warm.body, contains('Motor 139°'));
      expect(warm.body, contains('Ease off'));
      // Park error (>165): critical "Overheating".
      final hot = const VehicleData(motorTemp: 166).alerts.single;
      expect(hot.priority, AlertPriority.critical);
      expect(hot.title, 'Overheating');
      expect(hot.body, contains('Motor 166°'));
      // Cell advance at 55-9=46, Park at 62.
      expect(const VehicleData(batteryTemp: 46).alerts, isEmpty);
      expect(const VehicleData(batteryTemp: 47).alerts.single.priority, AlertPriority.warning);
      expect(const VehicleData(batteryTemp: 63).alerts.single.priority, AlertPriority.critical);
      // PDU and MCU are CAN-only: nothing until a reading has arrived.
      expect(const VehicleData(pduTemp: 101).alerts, isEmpty, reason: 'pduTempSeen false');
      expect(const VehicleData(pduTemp: 101, pduTempSeen: true).alerts.single.body, contains('BMS 101°'));
      expect(const VehicleData(mcuTemp: 103).alerts, isEmpty, reason: 'mcuTempSeen false');
      // MCU advance at 84-9=75: 75 clear, 76 warns, 103 critical.
      expect(const VehicleData(mcuTemp: 75, mcuTempSeen: true).alerts, isEmpty);
      final mcu = const VehicleData(mcuTemp: 76, mcuTempSeen: true).alerts.single;
      expect(mcu.priority, AlertPriority.warning);
      expect(mcu.body, contains('MCU 76°'));
      expect(const VehicleData(mcuTemp: 103, mcuTempSeen: true).alerts.single.priority, AlertPriority.critical);
    });

    test('live thermal limits from the config frames override the defaults', () {
      // Default MCU advance is 84-9=75, so 65 is clear.
      expect(const VehicleData(mcuTemp: 65, mcuTempSeen: true).alerts, isEmpty);
      // A scooter whose config says it derates at 70 warns 9 below (61), so 65 warns.
      final v = const VehicleData(mcuTemp: 65, mcuTempSeen: true, thermalLimits: ThermalLimits(mcuWarn: 70, mcuError: 90));
      expect(v.alerts.single.priority, AlertPriority.warning);
      expect(v.alerts.single.body, contains('MCU 65°'));
    });

    // Thermal runaway is its own critical alert, stock
    // text, separate from the temperature-based "Overheating" alert.
    test('thermal runaway has its own critical alert with stock text', () {
      final a = const VehicleData(thermalRunaway: true).alerts.single;
      expect(a.kind, AlertKind.thermalRunaway);
      expect(a.priority, AlertPriority.critical);
      expect(a.title, 'Scooter Issue');
      expect(a.body, 'please maintain a safe distance');
    });

    test('fault body carries the fault code', () {
      expect(const VehicleData(faultActive: true).alerts.single.body,
          'Stop safely and contact service');
      expect(const VehicleData(faultActive: true, faultCode: 'E042').alerts.single.body,
          contains('E042'));
    });

    test('accident, derating, brake worn and charging complete', () {
      final accident = const VehicleData(accidentDetected: true).alerts.single;
      expect(accident.priority, AlertPriority.critical);
      expect(accident.body, contains(emergencyNumber));
      final derate = const VehicleData(deratingActive: true).alerts.single;
      expect(derate.kind, AlertKind.deratingActive);
      expect(derate.priority, AlertPriority.warning);
      expect(const VehicleData(brakeWorn: true).alerts.single.kind, AlertKind.brakeWorn);
      final full = const VehicleData(chargingState: ChargingState.complete, isCharging: true).alerts.single;
      expect(full.kind, AlertKind.chargingComplete);
      expect(full.priority, AlertPriority.info);
    });

    test('tell-tale flags are not alerts', () {
      expect(const VehicleData(fallDetected: true, hillHoldActive: true).alerts, isEmpty);
    });

    test('alerts compare by value', () {
      expect(const VehicleData(faultActive: true, faultCode: 'E1').alerts,
          const VehicleData(faultActive: true, faultCode: 'E1').alerts);
    });

    test('alerts are ordered critical first', () {
      const v = VehicleData(
        trunkOpen: true,
        trunkStateKnown: true,
        vehicleState: VehicleState.riding,
        speed: 5,
        limpMode: true,
      );
      expect(v.alerts.first.priority, AlertPriority.critical);
      expect(v.alerts.last.priority, AlertPriority.warning);
    });
  });
  sensorFieldTests();
}

void sensorFieldTests() {
  group('bus, pack, power-limit and tow-theft sensor fields', () {
    test('defaults and copyWith for the new sensor fields', () {
      const v = VehicleData();
      expect(v.ambientBrightness, 50);
      expect(v.serviceIndicator, isFalse);
      expect(v.busVoltage, 0);
      expect(v.packCurrent, 0);
      expect(v.regenPowerLimitW, 0);
      expect(v.dischargePowerLimitW, 0);
      expect(v.rangeEcoCan, 0);
      expect(v.regenAvailability, 0);
      expect(v.towTheftState, 0);
      final w = v.copyWith(ambientBrightness: 80, serviceIndicator: true, busVoltage: 52.1, packCurrent: -9.5,
          regenPowerLimitW: 1500, dischargePowerLimitW: 8000, rangeEcoCan: 40, regenAvailability: 2, towTheftState: 3);
      expect(w.ambientBrightness, 80);
      expect(w.serviceIndicator, isTrue);
      expect(w.busVoltage, 52.1);
      expect(w.packCurrent, -9.5);
      expect(w.regenPowerLimitW, 1500);
      expect(w.dischargePowerLimitW, 8000);
      expect(w.rangeEcoCan, 40);
      expect(w.regenAvailability, 2);
      expect(w.towTheftState, 3);
      expect(w == v, isFalse);
      expect(w.copyWith(), w);
    });

    test('tamper alert has one wording; the CAN nibble cannot tell tow from tilt', () {
      DashAlert tamper(int state) =>
          VehicleData(tamperDetected: true, towTheftState: state).alerts.firstWhere((a) => a.kind == AlertKind.tamper);
      for (final state in [0, 1, 2, 3]) {
        expect(tamper(state).title, 'Tamper alert', reason: 'state $state');
        expect(tamper(state).body, 'Movement detected while locked');
        expect(tamper(state).priority, AlertPriority.critical);
      }
      expect(const VehicleData().alerts.where((a) => a.kind == AlertKind.tamper), isEmpty);
    });

    test('a fresh VehicleData has no regen availability reading yet', () {
      expect(const VehicleData().regenAvailability, 0);
      expect(const VehicleData().regenAvailabilityKnown, isFalse);
      final known = const VehicleData().copyWith(regenAvailability: 1, regenAvailabilityKnown: true);
      expect(known.regenAvailability, 1);
      expect(known.regenAvailabilityKnown, isTrue);
      expect(known.copyWith(), known);
      expect(known == const VehicleData().copyWith(regenAvailability: 1), isFalse);
    });
  });
}
