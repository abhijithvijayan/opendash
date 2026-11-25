import 'dart:math' as math;
import 'dart:typed_data';

import '../models/battery_diagnostics.dart';
import '../models/vehicle_data.dart' show ThermalLimits, LiveInputs;
import 'fault_catalog.dart';

/// Reads one CAN signal: Intel byte order, `raw * scale + offset`, as in
/// the community CAN decoders. Bits past the end of [data] read as zero.
double extractSignal(Uint8List data, int startBit, int bitLength, {double scale = 1, double offset = 0}) {
  final startByte = startBit >> 3;
  final shift = startBit & 7;
  final byteCount = (shift + bitLength + 7) >> 3;
  if (startByte + byteCount > data.length) return 0;
  var raw = 0;
  for (var i = 0; i < byteCount; i++) {
    raw |= data[startByte + i] << (i * 8);
  }
  raw = (raw >> shift) & ((1 << bitLength) - 1);
  return raw * scale + offset;
}

/// The BMS frames the diagnostics page needs plus the body/VCU sensor
/// frames HHMIS does not carry, accumulated as they arrive. Frame layout
/// from `diagnostics_server`: 4-byte big-endian CAN id, 1-byte DLC, 3 bytes
/// padding, 8 data bytes.
class BmsState {
  // 0x120 (SOC, current) and the 0x160 temperatures are not read here:
  // HHMIS carries them (FLOAT_BATTERY_OVERALL_SOC, _EFF_TEMP, _MIN_TEMP,
  // _MAX_TEMP) and the current comes from 0x140 as in stock.
  static const canIds = [
    0x140, 0x150, 0x160, 0x170, 0x1A4, 0x1A5, 0x1A6, 0x1A7,
    0x1A8, // pack voltage
    0x1A9, 0x1AA,
    0x144, // BCM lock state (VehicleLockStateBCM)
    0x356, // odometer in metres
    0x353, // "ambient light" (the screen brightness echoed, on a Gen 1), service indicator, trunk latch
    0x683, // tow/theft, regen availability
    0x6F4, // range by mode; word 0 is Eco
    0x651, // pack layout: cells in series/parallel, cell type
    0x653, // usable Ah per cell, charge-end cell mV
    0x313, // MCU_Data_1: controller (inverter) temperature
    0x217, // Vehicle_Config_Data_6: MCU derate thresholds
    0x218, // Vehicle_Config_Data_7: motor derate thresholds
    0x219, // BMS_Configuration_Info4: cell and PDU derate thresholds
    0x113, // MCU_Data_2: throttle voltage, MCU voltage, cruise engaged
    0x143, // Vehicle_Mode: cruise control availability
    0x15B, // Vehicle_Discharge_Mode_Request: front/rear brake pressed
    0x6AC, // Vehicle_Left_HBC_Packet: left handlebar switches
    0x6AD, // Vehicle_Right_HBC_Packet: right handlebar switches
    0x6D8, // BMS00_Cloud_Data_1: charge cycle count
    // Not 0x6DE (BMS00_Cloud_Data_4): its "Total_Kwhr_Charged_in_the_Mode"
    // is the Wh taken in this charge (Ah x pack voltage, x0.01, from 0 at
    // each plug-in), not lifetime kWh, and it tops out at 655 Wh, short of
    // a full charge (seen in bus logs).
    0x223, // MCU_Data_3: motor current, MCU DC current
    0x224, // MCU_Data_4: motor electrical frequency
    0x180, // BMS00_Parameter_5: charging rate %
    0x190, // BMS00_Parameter_6: time-to-full ETAs (slow/fast charger)
    // Fault-flag frames (decoded via the fault catalog, not the switch below).
    0x122, 0x210, 0x213, 0x333, 0x334, 0x410, 0x411, 0x430, 0x431, 0x508, 0x66E, 0x670, 0x6DA,
  ];

  final cells = List<double>.filled(14, 0);
  final packTemps = List<double?>.filled(6, null);

  /// 0x140 b4-5, the copy stock reads (HVDP `BatteryInfoParser.parseBMSParam2`
  /// → `onBatteryCurrent` → HHMIS `FLOAT_VEHICLE_CURRENT`), so the CAN and
  /// HHMIS writers of `packCurrent` carry the same sample. 0x120 b0-1 holds
  /// the same signal; negative is discharge.
  double? batteryCurrent;

  /// 0x150 b0-1: DC-link bus volts (HVDP `onBusVoltage`), not the pack.
  double? busVoltage;

  /// 0x1A8 b4-5: measured pack volts (community DBC `pack_voltage_measured`).
  double? packVoltage;

  /// 0x1A8 bits 0-10 / 16-26: the PDU (power-distribution-unit) temperature —
  /// the BMS power electronics (community DBC `BMS00_PDU_Temperature_01/02`).
  /// Distinct from, and hotter than, the cell/pack temperature, and governed
  /// by its own limits (warns at 85C, not the cells' 55C). Max of the two.
  double? pduTemp;

  /// 0x1A8 bits 48-63: the cell-balancing-resistor temperature (community
  /// DBC `BMS00_Cell_Balancing_Temperature`, x0.01 - 40). Rises while the BMS
  /// bleeds high cells; the diagnostics app surfaces it alongside balancing.
  double? balancingTemp;

  /// 0x6D8 b0-15: the pack's charge-cycle count (BMS cloud telemetry).
  int? cycleCount;

  /// 0x180 b32-39: charging rate (%). 0x190: minutes to a full charge on the
  /// slow (b16-31) and fast (b48-63) chargers. Null until those frames arrive.
  int? chargingRatePercent;
  int? etaSlowToFullMin;
  int? etaFastToFullMin;

  // Live rider inputs (0x113 / 0x15B / 0x6AC / 0x6AD), null/false until seen.
  bool _liveInputsSeen = false;
  double? _throttleV;
  double? _mcuVoltageInput;
  bool _frontBrake = false;
  bool _rearBrake = false;
  bool _beam = false;
  bool _leftIndicator = false;
  bool _rightIndicator = false;
  bool _horn = false;
  bool _cruise = false;
  bool _cruiseEngaged = false;
  int? _cruiseAvailability;
  bool _driveModeBtn = false;
  double? _motorCurrent;
  double? _mcuDcCurrent;
  double? _motorFrequency;

  /// The decoded rider inputs, or null until any of their frames has arrived.
  LiveInputs? get liveInputs => _liveInputsSeen
      ? LiveInputs(
          throttleV: _throttleV,
          mcuVoltage: _mcuVoltageInput,
          frontBrake: _frontBrake,
          rearBrake: _rearBrake,
          beam: _beam,
          leftIndicator: _leftIndicator,
          rightIndicator: _rightIndicator,
          horn: _horn,
          cruise: _cruise,
          cruiseEngaged: _cruiseEngaged,
          cruiseAvailability: _cruiseAvailability,
          driveModeBtn: _driveModeBtn,
          motorCurrent: _motorCurrent,
          mcuDcCurrent: _mcuDcCurrent,
          motorFrequency: _motorFrequency,
        )
      : null;

  /// 0x313 bits 16-31: the MCU (motor controller / inverter) temperature
  /// (`MCU_Temperatute`, x0.01). A prime derate trigger — the VCU limits to
  /// Normal when it passes 84C (0x217). Not on HHMIS, so only from this frame.
  double? mcuTemp;

  /// The scooter's own derate thresholds, read from its config frames
  /// (0x217/0x218/0x219). Null until each frame has been seen; [thermalLimits]
  /// falls back to the defaults for any not yet present.
  int? _mcuWarn, _mcuError, _motorWarn, _motorError;
  int? _cellWarn, _cellError, _pduWarn, _pduError;
  bool thermalConfigSeen = false;

  /// The live thresholds, defaults filled in for frames not yet decoded.
  ThermalLimits get thermalLimits {
    const d = ThermalLimits();
    return ThermalLimits(
      motorWarn: _motorWarn ?? d.motorWarn,
      motorError: _motorError ?? d.motorError,
      cellWarn: _cellWarn ?? d.cellWarn,
      cellError: _cellError ?? d.cellError,
      pduWarn: _pduWarn ?? d.pduWarn,
      pduError: _pduError ?? d.pduError,
      mcuWarn: _mcuWarn ?? d.mcuWarn,
      mcuError: _mcuError ?? d.mcuError,
    );
  }
  double? soh;
  double? regenLimitW;
  double? dischargeLimitW;
  bool balancingActive = false;
  List<int> balancingCells = const [];
  bool hasData = false;

  /// Null until the frame has been seen, so a missing sensor is not
  /// mistaken for a reading and never overwrites what HHMIS reported.
  int? ambientBrightness;
  bool? serviceIndicator;
  int? regenAvailability;
  int? towTheftState;
  int? rangeEcoCan;

  /// 0x651: the pack's layout, as the BMS states it (a Gen 1 pack is 14S16P).
  /// Config frames, so they stay across a stream drop (not in clearLive).
  int? cellsInSeries;
  int? cellsInParallel;

  /// 0x653 SOC_AH_USECAP_CELL: usable amp-hours of one cell string, and
  /// SLC_MV_THDVTG_CHRGEND_CELL: the per-cell voltage at which charging
  /// stops (4130 mV on a Gen 1 pack — a high cell ends the charge early).
  double? usableAhPerCell;
  int? chargeEndCellMv;

  /// Usable pack energy the BMS implies: parallel strings x usable Ah x
  /// (series x a nominal cell voltage). Null until both frames are in.
  double? get usableKwh {
    final p = cellsInParallel, sAh = usableAhPerCell, ser = cellsInSeries;
    if (p == null || sAh == null || ser == null || p <= 0 || sAh <= 0 || ser <= 0) return null;
    return p * sAh * (ser * nominalCellV) / 1000;
  }

  /// A per-cell nominal for the usable-energy estimate; NMC mid-point.
  static const nominalCellV = 3.65;

  /// 0x356 `Odometer_Value_in_mtrs`, 32 bits LE: metres. Confirmed against
  /// riding a Gen 1 scooter (about 5.8 a second at 21 km/h).
  int? odometerM;

  /// 0x353 byte 0 bit 2 is HVDP's TellTails trunk-latch flag
  /// (`DisplayInfoParser.parseTellTailsData` → `isTrunkLock(bit)`).
  /// HHMIS maps `isTrunkLock(true)` to `INT_VEHICLE_TRUNK_STATUS=3` (closed),
  /// so our `trunkOpen` is the logical inverse of this bit.
  bool? trunkClosed;

  /// 0x144 byte 0 bits 0-2: HVDP's `VehicleLockStateBCM` enum
  /// (`VehicleModeParser.parseVehicleLockStateBCM`). HHMIS routes the same
  /// value to `INT_VEHICLE_ESCL_STATUS`, but event-only; the CAN frame
  /// carries the persistent state so we know lock state at boot.
  /// 0 SNA, 1 Unlocked, 2 Unlock_Fail, 3 Locked, 4 Lock_Fail.
  int? vehicleLockStateBcm;

  /// Forgets everything that arrives at 10 Hz, for when the stream is lost:
  /// a reconnect refills these within a frame or two, and until then they
  /// must not be republished as readings. Cells and pack temperatures (a
  /// full set takes ~5 s) stay for the diagnostics page.
  void clearLive() {
    batteryCurrent = null;
    busVoltage = null;
    packVoltage = null;
    regenLimitW = null;
    dischargeLimitW = null;
    ambientBrightness = null;
    serviceIndicator = null;
    regenAvailability = null;
    towTheftState = null;
    rangeEcoCan = null;
    odometerM = null;
    trunkClosed = null;
    vehicleLockStateBcm = null;
  }

  static int canIdOf(List<int> frame) => (frame[0] << 24) | (frame[1] << 16) | (frame[2] << 8) | frame[3];

  static final _wanted = canIds.toSet();

  /// Client-side stand-in for the server's `Init` filter on `CanDumpStream`.
  static bool wants(List<int> frame) => frame.length >= 16 && _wanted.contains(canIdOf(frame));

  /// Latest 8 data bytes of each fault-flag frame seen, for the catalog.
  final Map<int, Uint8List> _faultFrames = {};

  /// Every fault the catalog finds active in the frames seen so far,
  /// most-severe first.
  List<ActiveFault> get activeFaults => activeFaultsIn(_faultFrames);

  void feed(Uint8List frame) {
    if (frame.length < 16) return;
    final id = canIdOf(frame);
    final data = Uint8List.sublistView(frame, 8, 16);
    if (faultFrameIds.contains(id)) _faultFrames[id] = Uint8List.fromList(data);
    switch (id) {
      case 0x140:
        regenLimitW = extractSignal(data, 0, 16);
        // The word is signed about 50000 with discharge negative, like the
        // current next to it: rides on a Gen 1 read -10016..-11907 W
        // whenever HV was up (peak draw 10.1 kW) and exactly 0
        // parked or charging. Kept as a magnitude; the raw sign made the
        // power bar treat every reading as "no limit".
        // The community CAN database defines Discharge_Power_Limit_00 as
        // raw - 50000 W, so this is its magnitude.
        dischargeLimitW = math.max(0, 50000 - extractSignal(data, 16, 16));
        batteryCurrent = extractSignal(data, 32, 16, scale: 0.01, offset: -300);
      case 0x150:
        busVoltage = extractSignal(data, 0, 16, scale: 0.001);
        soh = extractSignal(data, 40, 8);
      case 0x160:
        balancingActive = extractSignal(data, 0, 1) != 0;
      case 0x170:
        balancingCells = [
          for (var i = 0; i < 14; i++)
            if (extractSignal(data, i, 1) != 0) i + 1,
        ];
      case 0x1A4:
        for (var i = 0; i < 4; i++) {
          packTemps[i] = extractSignal(data, i * 16, 16, scale: 0.1, offset: -50);
        }
      case 0x1A7:
        packTemps[4] = extractSignal(data, 0, 16, scale: 0.1, offset: -50);
        packTemps[5] = extractSignal(data, 16, 16, scale: 0.1, offset: -50);
      case 0x313:
        mcuTemp = extractSignal(data, 16, 16, scale: 0.01);
      case 0x217:
        // Vehicle_Config_Data_6: MCU_WARN_NORMAL_SET (b0-9), MCU_ERR_PARK_SET (b40-49).
        _mcuWarn = extractSignal(data, 0, 10).round();
        _mcuError = extractSignal(data, 40, 10).round();
        thermalConfigSeen = true;
      case 0x218:
        // Vehicle_Config_Data_7: MOTOR_WARN_NORMAL_SET (b0-9), MOTOR_ERR_PARK_SET (b40-49).
        _motorWarn = extractSignal(data, 0, 10).round();
        _motorError = extractSignal(data, 40, 10).round();
        thermalConfigSeen = true;
      case 0x219:
        // BMS_Configuration_Info4: cell drive warn (b0-6) / error (b11-17),
        // PDU warn (b36-43) / error (b52-59).
        _cellWarn = extractSignal(data, 0, 7).round();
        _cellError = extractSignal(data, 11, 7).round();
        _pduWarn = extractSignal(data, 36, 8).round();
        _pduError = extractSignal(data, 52, 8).round();
        thermalConfigSeen = true;
      case 0x1A8:
        packVoltage = extractSignal(data, 32, 16, scale: 0.001);
        pduTemp = _maxOf(
          extractSignal(data, 0, 11, scale: 0.1, offset: -40),
          extractSignal(data, 16, 11, scale: 0.1, offset: -40),
        );
        balancingTemp = extractSignal(data, 48, 16, scale: 0.01, offset: -40);
      case 0x113:
        _liveInputsSeen = true;
        _throttleV = extractSignal(data, 8, 16, scale: 0.01);
        _mcuVoltageInput = extractSignal(data, 48, 16, scale: 0.001);
        _cruiseEngaged = extractSignal(data, 40, 1) != 0;
      case 0x143:
        _liveInputsSeen = true;
        _cruiseAvailability = extractSignal(data, 59, 3).round();
      case 0x15B:
        _liveInputsSeen = true;
        // The DBC labels bit4 Front_Brake_Press and bit5 Rear_Brake_Press, but
        // on-vehicle testing shows they are reversed on the real
        // scooter: the front lever sets bit5 and the rear sets bit4. Map to the
        // physical brakes so the Live Data readout is right.
        _frontBrake = extractSignal(data, 5, 1) != 0;
        _rearBrake = extractSignal(data, 4, 1) != 0;
      case 0x6AC:
        _liveInputsSeen = true;
        _beam = extractSignal(data, 0, 1) != 0;
        _cruise = extractSignal(data, 1, 1) != 0;
        _leftIndicator = extractSignal(data, 2, 1) != 0;
        _rightIndicator = extractSignal(data, 3, 1) != 0;
        _horn = extractSignal(data, 4, 1) != 0;
      case 0x6AD:
        _liveInputsSeen = true;
        _driveModeBtn = extractSignal(data, 0, 1) != 0;
      case 0x6D8:
        cycleCount = extractSignal(data, 0, 16).round();
      case 0x223:
        _liveInputsSeen = true;
        _motorCurrent = extractSignal(data, 0, 16, offset: -1000);
        _mcuDcCurrent = extractSignal(data, 40, 16, scale: 0.01, offset: -300);
      case 0x224:
        _liveInputsSeen = true;
        _motorFrequency = extractSignal(data, 0, 10);
      case 0x180:
        chargingRatePercent = extractSignal(data, 32, 8).round();
      case 0x190:
        etaSlowToFullMin = extractSignal(data, 16, 16).round();
        etaFastToFullMin = extractSignal(data, 48, 16).round();
      case 0x1A5:
        _cells(data, 0, 4);
      case 0x1A6:
        _cells(data, 4, 4);
      case 0x1A9:
        _cells(data, 8, 4);
      case 0x1AA:
        _cells(data, 12, 2);
      case 0x144:
        vehicleLockStateBcm = extractSignal(data, 0, 3).round();
      case 0x353:
        ambientBrightness = extractSignal(data, 56, 8).round().clamp(0, 100);
        serviceIndicator = extractSignal(data, 43, 1) != 0;
        trunkClosed = extractSignal(data, 2, 1) != 0;
      case 0x683:
        regenAvailability = extractSignal(data, 8, 4).round();
        towTheftState = extractSignal(data, 4, 4).round();
      case 0x6F4:
        rangeEcoCan = extractSignal(data, 0, 16).round();
      case 0x651:
        final ser = extractSignal(data, 8, 8).round();
        final par = extractSignal(data, 16, 8).round();
        if (ser > 0) cellsInSeries = ser;
        if (par > 0) cellsInParallel = par;
      case 0x653:
        final ah = extractSignal(data, 26, 12, scale: 0.01);
        final end = extractSignal(data, 13, 13).round();
        if (ah > 0) usableAhPerCell = ah;
        if (end > 0) chargeEndCellMv = end;
      case 0x356:
        final m = extractSignal(data, 0, 32).round();
        if (m > 0) odometerM = m;
      default:
        return;
    }
    hasData = true;
  }

  void _cells(Uint8List data, int first, int count) {
    for (var i = 0; i < count; i++) {
      cells[first + i] = extractSignal(data, i * 16, 16, scale: 0.001);
    }
  }

  static double _maxOf(double a, double b) => a > b ? a : b;

  BatteryDiagnostics toDiagnostics({double? motorTemp, double? controllerTemp}) => BatteryDiagnostics.compute(
        cellVoltages: List.of(cells),
        temps: [
          for (var i = 0; i < 6; i++) PackTemperature(label: 'Pack ${i + 1}', tempC: packTemps[i]),
          PackTemperature(label: 'PDU', tempC: pduTemp),
          PackTemperature(label: 'MCU', tempC: mcuTemp ?? controllerTemp),
          PackTemperature(label: 'Motor', tempC: motorTemp),
        ],
        soh: soh,
        busVoltage: busVoltage,
        packVoltage: packVoltage,
        batteryCurrent: batteryCurrent,
        dischargeLimitW: dischargeLimitW,
        regenLimitW: regenLimitW,
        balancingActive: balancingActive,
        balancingCells: balancingCells,
        cellsInSeries: cellsInSeries,
        cellsInParallel: cellsInParallel,
        usableKwh: usableKwh,
        chargeEndCellMv: chargeEndCellMv,
        balancingTemp: balancingTemp,
        cycleCount: cycleCount,
        chargingRatePercent: chargingRatePercent,
        etaSlowToFullMin: etaSlowToFullMin,
        etaFastToFullMin: etaFastToFullMin,
      );
}
