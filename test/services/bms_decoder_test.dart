import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/services/bms_decoder.dart';

Uint8List frame(int id, List<int> data) {
  final out = Uint8List(16);
  out[0] = (id >> 24) & 0xff;
  out[1] = (id >> 16) & 0xff;
  out[2] = (id >> 8) & 0xff;
  out[3] = id & 0xff;
  out[4] = data.length;
  out.setRange(8, 8 + data.length, data);
  return out;
}

List<int> le16(int v) => [v & 0xff, (v >> 8) & 0xff];

void main() {
  test('extractSignal reads little-endian bit fields with scale and offset', () {
    final data = Uint8List.fromList([...le16(3890), ...le16(3892), 0, 0, 0, 0]);
    expect(extractSignal(data, 0, 16, scale: 0.001), closeTo(3.890, 1e-9));
    expect(extractSignal(data, 16, 16, scale: 0.001), closeTo(3.892, 1e-9));
    final bit = Uint8List.fromList([0x01, 0, 0, 0, 0, 0, 0, 0]);
    expect(extractSignal(bit, 0, 1), 1);
    expect(extractSignal(bit, 1, 1), 0);
    final short = Uint8List.fromList([1, 2]);
    expect(extractSignal(short, 16, 16), 0, reason: 'past the end reads as zero');
  });

  test('cells come from 0x1A5, 0x1A6, 0x1A9 and 0x1AA', () {
    final bms = BmsState();
    bms.feed(frame(0x1A5, [...le16(3890), ...le16(3892), ...le16(3889), ...le16(3893)]));
    bms.feed(frame(0x1A6, [...le16(3891), ...le16(3889), ...le16(3883), ...le16(3892)]));
    bms.feed(frame(0x1A9, [...le16(3890), ...le16(3888), ...le16(3896), ...le16(3891)]));
    bms.feed(frame(0x1AA, [...le16(3889), ...le16(3891), ...le16(3890), 0, 0]));
    expect(bms.cells[0], closeTo(3.890, 1e-9));
    expect(bms.cells[6], closeTo(3.883, 1e-9));
    expect(bms.cells[13], closeTo(3.891, 1e-9));
    expect(bms.cells.where((c) => c > 0).length, 14);
  });

  test('pack temperatures carry the -50 offset and 0.1 scale', () {
    final bms = BmsState();
    bms.feed(frame(0x1A4, [...le16(820), ...le16(810), ...le16(830), ...le16(800)]));
    bms.feed(frame(0x1A7, [...le16(820), ...le16(810), 0, 0, 0, 0]));
    expect(bms.packTemps[0], closeTo(32.0, 1e-9));
    expect(bms.packTemps[3], closeTo(30.0, 1e-9));
    expect(bms.packTemps[5], closeTo(31.0, 1e-9));
  });

  test('limits, current, SOH and balancing', () {
    final bms = BmsState();
    // 0x140 b4-5 is the current stock reads: raw 30250 -> 2.5 A.
    bms.feed(frame(0x140, [...le16(3200), ...le16(38000), ...le16(30250), 0, 0]));
    bms.feed(frame(0x150, [...le16(51200), ...le16(12), 90, 96, 0, 0]));
    bms.feed(frame(0x160, [0x01, ...le16(820), ...le16(810), ...le16(830)]));
    expect(bms.batteryCurrent, closeTo(2.5, 1e-6));
    expect(bms.regenLimitW, 3200);
    expect(bms.dischargeLimitW, 12000);
    // A ride log: the limit read -11807 W at 85 % (raw 38193).
    bms.feed(frame(0x140, [...le16(4372), ...le16(38193), ...le16(30000), 0, 0]));
    expect(bms.dischargeLimitW, 11807);
    // HV off or charging: raw 50000. Above it would be a "charge" limit,
    // which is not a discharge ceiling.
    bms.feed(frame(0x140, [...le16(1794), ...le16(50000), ...le16(30000), 0, 0]));
    expect(bms.dischargeLimitW, 0);
    bms.feed(frame(0x140, [...le16(1794), ...le16(50400), ...le16(30000), 0, 0]));
    expect(bms.dischargeLimitW, 0);
    expect(bms.busVoltage, closeTo(51.2, 1e-6));
    expect(bms.soh, 96);
    expect(bms.balancingActive, isTrue);
  });

  test('pack current is the 0x140 copy; 0x120 is neither subscribed nor decoded (G-6, G-10)', () {
    final bms = BmsState();
    expect(BmsState.canIds, isNot(contains(0x120)));
    bms.feed(frame(0x120, [...le16(30250), ...le16(6673), 0, 0, 0, 0]));
    expect(bms.batteryCurrent, isNull);
    expect(bms.hasData, isFalse);
    // raw 7220 -> 72.2 - 300 = -227.8 A, the discharge seen at 78 km/h.
    bms.feed(frame(0x140, [0, 0, 0, 0, ...le16(7220), 0, 0]));
    expect(bms.batteryCurrent, closeTo(-227.8, 1e-6));
  });

  test('clearLive forgets the fast frames and keeps cells and pack temperatures', () {
    final bms = BmsState();
    bms.feed(frame(0x1A5, [...le16(3890), ...le16(3892), ...le16(3889), ...le16(3893)]));
    bms.feed(frame(0x1A4, [...le16(820), ...le16(810), ...le16(830), ...le16(800)]));
    bms.feed(frame(0x140, [...le16(3200), ...le16(38000), ...le16(30250), 0, 0]));
    bms.feed(frame(0x150, [...le16(51200), ...le16(12), 90, 96, 0, 0]));
    bms.feed(frame(0x1A8, [0, 0, 0, 0, ...le16(55280), 0, 0]));
    bms.feed(frame(0x353, [0x04, 0, 0, 0, 0, 0x08, 0, 72]));
    bms.feed(frame(0x683, [0x10, 0x01, 0, 0, 0, 0, 0, 0]));
    bms.feed(frame(0x6F4, [...le16(46), 0, 0, 0, 0, 0, 0]));
    bms.feed(frame(0x144, [3, 0, 0, 0, 0, 0, 0, 0]));
    bms.clearLive();
    expect(bms.batteryCurrent, isNull);
    expect(bms.busVoltage, isNull);
    expect(bms.packVoltage, isNull);
    expect(bms.regenLimitW, isNull);
    expect(bms.dischargeLimitW, isNull);
    expect(bms.ambientBrightness, isNull);
    expect(bms.serviceIndicator, isNull);
    expect(bms.regenAvailability, isNull);
    expect(bms.towTheftState, isNull);
    expect(bms.trunkClosed, isNull);
    expect(bms.vehicleLockStateBcm, isNull);
    expect(bms.cells[0], closeTo(3.89, 1e-9));
    expect(bms.packTemps[0], closeTo(32.0, 1e-9));
    expect(bms.soh, 96);
  });

  test('0x353 carries ambient light, the service flag and the trunk latch', () {
    final bms = BmsState();
    expect(bms.ambientBrightness, isNull);
    expect(bms.serviceIndicator, isNull);
    expect(bms.regenAvailability, isNull);
    expect(bms.towTheftState, isNull);
    expect(bms.trunkClosed, isNull);
    // byte 5 bit 3 (bit 43) = service; byte 7 (bits 56-63) = ambient %;
    // byte 0 bit 2 = HVDP TellTails isTrunkLock (1 = closed).
    bms.feed(frame(0x353, [0x04, 0, 0, 0, 0, 0x08, 0, 72]));
    expect(bms.ambientBrightness, 72);
    expect(bms.serviceIndicator, isTrue);
    expect(bms.trunkClosed, isTrue);
    bms.feed(frame(0x353, [0x00, 0, 0, 0, 0, 0x00, 0, 150]));
    expect(bms.ambientBrightness, 100, reason: 'clamped');
    expect(bms.serviceIndicator, isFalse);
    expect(bms.trunkClosed, isFalse, reason: 'bit clear = isTrunkLock(false) = open');
    // The Appendix A live parked frame: byte 0 = 0x05 → bit 2 = 1 → closed.
    bms.feed(frame(0x353, [0x05, 0, 0, 0x7c, 0, 0, 0, 100]));
    expect(bms.trunkClosed, isTrue);
    expect(BmsState.canIds, containsAll([0x353, 0x683, 0x6F4]));
  });

  test('0x144 carries VehicleLockStateBCM in byte 0 bits 0-2', () {
    final bms = BmsState();
    expect(bms.vehicleLockStateBcm, isNull);
    bms.feed(frame(0x144, [0x01, 0, 0, 0, 0, 0, 0, 0]));
    expect(bms.vehicleLockStateBcm, 1, reason: 'Vehicle_Unlocked');
    bms.feed(frame(0x144, [0x03, 0, 0, 0, 0, 0, 0, 0]));
    expect(bms.vehicleLockStateBcm, 3, reason: 'Vehicle_Locked');
    bms.feed(frame(0x144, [0x04, 0, 0, 0, 0, 0, 0, 0]));
    expect(bms.vehicleLockStateBcm, 4, reason: 'Vehicle_Lock_Fail');
    // Upper bits of byte 0 are masked off (0x07).
    bms.feed(frame(0x144, [0xFB, 0, 0, 0, 0, 0, 0, 0]));
    expect(bms.vehicleLockStateBcm, 3, reason: '0xFB & 0x07 = 0x03');
    expect(BmsState.canIds, contains(0x144));
  });

  test('0x683 carries tow/theft and regen availability nibbles', () {
    final bms = BmsState();
    // byte 0 high nibble (bits 4-7) = tow/theft; byte 1 low nibble (bits 8-11) = regen availability
    bms.feed(frame(0x683, [0x20, 0x01, 0, 0, 0, 0, 0, 0]));
    expect(bms.towTheftState, 2);
    expect(bms.regenAvailability, 1);
  });

  test('0x6F4 word 0 is the Eco range', () {
    final bms = BmsState();
    expect(bms.rangeEcoCan, isNull);
    bms.feed(frame(0x6F4, [...le16(46), ...le16(110), ...le16(140), ...le16(90)]));
    expect(bms.rangeEcoCan, 46);
  });

  test('unknown ids and short frames are ignored', () {
    final bms = BmsState();
    bms.feed(frame(0x500, [1, 2, 3, 4, 5, 6, 7, 8])); // not in canIds
    bms.feed(Uint8List(5));
    expect(bms.hasData, isFalse);
  });

  test('0x313 is the MCU (controller) temperature, bits 16-31 x0.01', () {
    final bms = BmsState();
    // speed b0-1, MCU temp b2-3 = 0x0ea8 = 3752 -> 37.52C, motor temp b4-5, rpm b6-7
    bms.feed(frame(0x313, [0x6c, 0x00, 0xa8, 0x0e, 0xf8, 0x0c, 0x84, 0x01]));
    expect(bms.mcuTemp, closeTo(37.52, 1e-9));
    expect(bms.toDiagnostics().temps.firstWhere((t) => t.label == 'MCU').tempC, closeTo(37.52, 1e-9));
    expect(BmsState.canIds, contains(0x313));
  });

  test('derate thresholds come from the config frames 0x217 / 0x218 / 0x219', () {
    final bms = BmsState();
    expect(bms.thermalConfigSeen, isFalse);
    expect(bms.thermalLimits, const ThermalLimits(), reason: 'defaults until the frames arrive');
    // Bytes from a Gen 1 scooter.
    bms.feed(frame(0x217, [0x54, 0x2c, 0xd1, 0x45, 0x15, 0x66, 0x00, 0x00])); // MCU: SET 84, PARK 102
    bms.feed(frame(0x218, [0x93, 0x68, 0xd1, 0x09, 0x23, 0xa5, 0x00, 0x00])); // motor: SET 147, PARK 165
    bms.feed(frame(0x219, [0x37, 0xf5, 0xd9, 0xf4, 0x56, 0x45, 0x41, 0x06])); // cell 55/62, PDU 85/100
    expect(bms.thermalConfigSeen, isTrue);
    expect(bms.thermalLimits.mcuWarn, 84);
    expect(bms.thermalLimits.mcuError, 102);
    expect(bms.thermalLimits.motorWarn, 147);
    expect(bms.thermalLimits.motorError, 165);
    expect(bms.thermalLimits.cellWarn, 55);
    expect(bms.thermalLimits.cellError, 62);
    expect(bms.thermalLimits.pduWarn, 85);
    expect(bms.thermalLimits.pduError, 100);
  });

  test('toDiagnostics builds the model with motor temp alongside', () {
    final bms = BmsState();
    bms.feed(frame(0x1A5, [...le16(3890), ...le16(3892), ...le16(3889), ...le16(3893)]));
    bms.feed(frame(0x150, [...le16(51200), ...le16(12), 90, 96, 0, 0]));
    bms.feed(frame(0x1A4, [...le16(820), ...le16(810), ...le16(830), ...le16(800)]));
    final d = bms.toDiagnostics(motorTemp: 41);
    expect(d.cells.length, 14);
    expect(d.cells[0].voltage, closeTo(3.890, 1e-9));
    expect(d.cells[13].voltage, 0, reason: 'unseen cells are missing, not zero volts');
    expect(d.soh, 96);
    expect(d.busVoltage, closeTo(51.2, 1e-6));
    expect(d.temps.map((t) => t.label), contains('Motor'));
    expect(d.temps.firstWhere((t) => t.label == 'Pack 1').tempC, closeTo(32.0, 1e-9));
    expect(d.temps.firstWhere((t) => t.label == 'Pack 5').tempC, isNull);
  });

  // 0x150 b0-1 is the DC-link bus (25 V parked, contactor open);
  // the pack is 0x1A8 b4-5. Bytes from a parked capture.
  test('pack voltage comes from 0x1A8 b4-5, kept apart from the 0x150 bus voltage', () {
    final bms = BmsState();
    bms.feed(frame(0x1A8, [0xf1, 0x02, 0xf5, 0x02, 0xfc, 0xd4, 0x6d, 0x1e]));
    bms.feed(frame(0x150, [0x0e, 0x62, 0x60, 0x6c, 0x64, 0x64, 0, 0]));
    expect(bms.packVoltage, closeTo(54.524, 1e-9));
    expect(bms.busVoltage, closeTo(25.102, 1e-9));
    // Same 0x1A8 frame carries the PDU (BMS electronics) temperature in bits
    // 0-10 / 16-26 (x0.1 - 40): 753 -> 35.3, 757 -> 35.7, max 35.7
    // (BMS00_PDU_Temperature_01/02).
    expect(bms.pduTemp, closeTo(35.7, 1e-9));
    // Bits 48-63 are the cell-balancing-resistor temperature (x0.01 - 40,
    // BMS00_Cell_Balancing_Temperature): 0x1e6d=7789 -> 37.89.
    expect(bms.balancingTemp, closeTo(37.89, 1e-9));
    final d = bms.toDiagnostics();
    expect(d.packVoltage, closeTo(54.524, 1e-9));
    expect(d.busVoltage, closeTo(25.102, 1e-9));
    expect(d.temps.firstWhere((t) => t.label == 'PDU').tempC, closeTo(35.7, 1e-9));
    expect(d.balancingTemp, closeTo(37.89, 1e-9));
    expect(BmsState.canIds, contains(0x1A8));
  });
  test('0x356 is the odometer in metres; a zero is not a reading, and a lost stream forgets it', () {
    final bms = BmsState();
    expect(BmsState.canIds, contains(0x356));
    const m = 33101528;
    bms.feed(frame(0x356, [m & 0xff, (m >> 8) & 0xff, (m >> 16) & 0xff, (m >> 24) & 0xff, 0, 0, 0, 0]));
    expect(bms.odometerM, m);
    bms.feed(frame(0x356, [0, 0, 0, 0, 0, 0, 0, 0]));
    expect(bms.odometerM, m);
    bms.clearLive();
    expect(bms.odometerM, isNull);
  });

  test('0x651 and 0x653 give the pack layout and usable energy (14S16P, ~3.5 kWh)', () {
    final bms = BmsState();
    expect(BmsState.canIds, containsAll([0x651, 0x653]));
    bms.feed(frame(0x651, [0x01, 14, 16, 0, 0, 0, 0, 0]));
    // SOC_AH_USECAP_CELL = 432 (x0.01 = 4.32 Ah) at start bit 26; charge-end
    // 4130 mV at start bit 13. Build the 8 data bytes for those fields.
    int withSignal(int value, int startBit, int len) => (value & ((1 << len) - 1)) << startBit;
    final bits = withSignal(4130, 13, 13) | withSignal(432, 26, 12);
    final d = List<int>.generate(8, (i) => (bits >> (i * 8)) & 0xff);
    bms.feed(frame(0x653, d));
    expect(bms.cellsInSeries, 14);
    expect(bms.cellsInParallel, 16);
    expect(bms.usableAhPerCell, closeTo(4.32, 1e-9));
    expect(bms.chargeEndCellMv, 4130);
    expect(bms.usableKwh, closeTo(16 * 4.32 * 14 * 3.65 / 1000, 1e-6));
  });

  test('rider inputs decode from 0x113 (throttle/MCU V), 0x15B (brakes), 0x6AC/0x6AD (switches)', () {
    final bms = BmsState();
    expect(BmsState.canIds, containsAll([0x113, 0x15B, 0x6AC, 0x6AD]));
    expect(bms.liveInputs, isNull, reason: 'null until a frame arrives');
    // 0x113: Throttle_Value1 b8-23 x0.01 = 150 -> 1.50 V; MCU_Voltage b48-63 x0.001 = 52000 -> 52.0 V.
    bms.feed(frame(0x113, [0, ...le16(150), 0, 0, 0, ...le16(52000)]));
    // 0x15B: on this scooter the DBC's bit4/bit5 are reversed vs the physical
    // brakes — the front lever sets bit5, the rear sets bit4 (verified on the
    // vehicle). Here only bit5 is set, so the FRONT brake reads pressed.
    bms.feed(frame(0x15B, [0x20, 0, 0, 0, 0, 0, 0, 0]));
    // 0x6AC left cluster: Left_Indicator b2, Horn b4 -> 0b10100 = 0x14.
    bms.feed(frame(0x6AC, [0x14, 0, 0, 0, 0, 0, 0, 0]));
    // 0x6AD right cluster: Drive_Mode b0.
    bms.feed(frame(0x6AD, [0x01, 0, 0, 0, 0, 0, 0, 0]));
    final li = bms.liveInputs!;
    expect(li.throttleV, closeTo(1.50, 1e-9));
    expect(li.mcuVoltage, closeTo(52.0, 1e-9));
    expect((li.frontBrake, li.rearBrake), (true, false), reason: 'bit5 = front lever (DBC labels are reversed)');
    expect((li.leftIndicator, li.horn), (true, true));
    expect((li.beam, li.rightIndicator, li.cruise), (false, false, false));
    expect(li.driveModeBtn, isTrue);
  });

  test('motor electrical decodes from 0x223 (currents) and 0x224 (frequency)', () {
    final bms = BmsState();
    expect(BmsState.canIds, containsAll([0x223, 0x224]));
    // 0x223: Motor_Current b0-15 x1 off-1000 = 1150 -> 150 A;
    // MCU_DC_Current b40-55 x0.01 off-300 = 32000 -> 20.0 A.
    bms.feed(frame(0x223, [...le16(1150), 0, 0, 0, ...le16(32000), 0]));
    // 0x224: Motor_Frequency b0-9 = 220 Hz.
    bms.feed(frame(0x224, [220 & 0xff, (220 >> 8) & 0x03, 0, 0, 0, 0, 0, 0]));
    final li = bms.liveInputs!;
    expect(li.motorCurrent, closeTo(150, 1e-9));
    expect(li.mcuDcCurrent, closeTo(20.0, 1e-9));
    expect(li.motorFrequency, closeTo(220, 1e-9));
  });

  test('charging rate and to-full ETAs come from 0x180 and 0x190', () {
    final bms = BmsState();
    expect(BmsState.canIds, containsAll([0x180, 0x190]));
    // 0x180: Charging_Rate b32-39 = 45 (%).
    bms.feed(frame(0x180, [0, 0, 0, 0, 45, 0, 0, 0]));
    // 0x190: Time_to_Full_chargeSC_00 b16-31 = 210 min (slow), Time_to_chargeFC_100 b48-63 = 95 min (fast).
    bms.feed(frame(0x190, [0, 0, ...le16(210), 0, 0, ...le16(95)]));
    expect(bms.chargingRatePercent, 45);
    expect(bms.etaSlowToFullMin, 210);
    expect(bms.etaFastToFullMin, 95);
    final d = bms.toDiagnostics();
    expect(d.chargingRatePercent, 45);
    expect(d.etaSlowToFullMin, 210);
    expect(d.etaFastToFullMin, 95);
  });

  test('the cycle count comes from 0x6D8; 0x6DE, this charge\'s Wh, is not read as lifetime kWh', () {
    final bms = BmsState();
    expect(BmsState.canIds, contains(0x6D8));
    expect(BmsState.canIds, isNot(contains(0x6DE)));
    // 0x6D8: Cycle_Number b0-15 = 342; Factored_Charge_Amphr b32-47 x0.01.
    bms.feed(frame(0x6D8, [...le16(342), 0, 0, ...le16(1234), 0, 0]));
    expect(bms.cycleCount, 342);
    expect(bms.toDiagnostics().cycleCount, 342);
  });
}
