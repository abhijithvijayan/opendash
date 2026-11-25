import 'dart:typed_data';

import 'bms_decoder.dart' show extractSignal;

/// How loud a fault is. Derived from the DBC signal name's own suffix
/// (Warning / Error / Permanent_Fault / Info), not hand-assigned.
enum FaultSeverity { info, warning, error, critical }

/// A single named fault flag: one bit on one CAN frame, with the component
/// that owns it. Title and severity come from the signal name.
class FaultDef {
  const FaultDef(this.frame, this.bit, this.signal, this.component);
  final int frame;
  final int bit;
  final String signal;
  final String component;

  FaultSeverity get severity => severityForSignal(signal);
  String get title => faultTitle(signal);
}

/// One active fault, decoded from a live frame.
class ActiveFault {
  const ActiveFault(this.def);
  final FaultDef def;
  String get title => def.title;
  String get component => def.component;
  FaultSeverity get severity => def.severity;
}

/// Severity from the signal name. Permanent faults and thermal runaway are
/// critical; explicit Warning/Info keep their level; everything else that
/// names a fault/error/short/open/overcurrent is an error.
FaultSeverity severityForSignal(String signal) {
  final s = signal.toLowerCase();
  if (s.contains('permanent') || s.contains('runaway') || s.contains('lockout')) return FaultSeverity.critical;
  if (s.contains('warning') || s.contains('warn')) return FaultSeverity.warning;
  if (s.contains('info') || s.contains('_10ms')) return FaultSeverity.info;
  return FaultSeverity.error;
}

/// A readable title from a raw DBC signal name: drop the BMS/vehicle prefix,
/// swap underscores for spaces, collapse repeats, and tidy the casing.
String faultTitle(String signal) {
  var s = signal;
  for (final p in ['BMS00_', 'BMS0_', 'BMS_', 'Battery_pack_', 'Vehicle_']) {
    if (s.startsWith(p)) {
      s = s.substring(p.length);
      break;
    }
  }
  // Drop the DBC's severity-grade and info suffixes (and Ola's "Gratde" typo);
  // severity shows as its own badge, so the title stays clean.
  s = s
      .replaceAll(RegExp(r'_(Grade|Gratde)_\d+$'), '')
      .replaceAll(RegExp(r'_info$', caseSensitive: false), '');
  s = s.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  // Common shorthands → words, and a leading capital.
  s = s
      .replaceAll('overtemperature', 'over-temperature')
      .replaceAll('Overtemperature', 'Over-temperature')
      .replaceAll('Over voltage', 'Over-voltage')
      .replaceAll('Over temperature', 'Over-temperature')
      .replaceAll('Under voltage', 'Under-voltage')
      .replaceAll('Over current', 'Over-current');
  if (s.isEmpty) return signal;
  return s[0].toUpperCase() + s.substring(1);
}

/// Per-frame fault bits (frame, component, [(bit, signal)]), taken from Ola's
/// own fault DBCs shipped in the OlaDiagnostics app (da_can_dbc + the bms/mcu/
/// vcu fault DBCs) — verified frame+bit-exact. Status/command bits and the
/// 10ms-duplicate frames are left out; each entry is a real fault flag.
const _frames = <(int, String, List<(int, String)>)>[
  (0x122, 'BMS', [
    (0, 'Battery_Precharge_failure_status_00'),
    (1, 'Battery_Precharge_failure_status_01'),
    (2, 'Battery_Precharge_failure_status_02'),
    // b8/16/24/32/40 are normal operational flags (charge/discharge inhibit,
    // derate, regen inhibit) — set on a healthy pack, so NOT listed as faults
    // (verified against real ride logs).
    (48, 'Battery_Permanent_Fault_00'),
    (49, 'Battery_Permanent_Fault_01'),
    (50, 'Battery_Permanent_Fault_02'),
    (51, 'Battery_Voltage_Deviation_Error'),
  ]),
  (0x210, 'MCU', [
    (0, 'Throttle_Deviation_Error'),
    (1, 'Derate_Warning'),
  ]),
  (0x213, 'Charger', [
    (40, 'Charger_output_Short_circuit_error'),
    (41, 'Charger_under_temperature_error'),
    (42, 'Charger_over_temperature_error'),
    (43, 'Low_AC_voltage_error'),
    (44, 'Rectifier_hardware_error'),
    (45, 'Authentication_Error'),
    (46, 'Battery_Parameter_Time_out_error'),
    (47, 'Data_Corruption_error'),
    (48, 'Charge_control_message_timeout_error'),
  ]),
  (0x333, 'MCU', [
    (0, 'Software_overcurrent_protection_Grade_3'),
    (1, 'Software_overvoltage_fault_Grade_3'),
    (3, 'Failure_for_motor_parameter_tuning'),
    (4, 'Drive_Overload_Grade_3'),
    (5, 'U_phase_hall_fault'),
    (6, 'Drive_overtemperature_Grade_3'),
    (7, 'Motor_overtemperature_Gratde_3'),
    (8, 'Encoder_disconnection_Grade_3'),
    (10, 'Stalling_Fault_Grade_3'),
    (11, 'DC_Bus_undervoltage_fault_Grade_3'),
    (12, 'CAN_communication_abnormal_failure'),
    (13, 'Motor_over_speed_fault_Grade_3'),
    (14, 'Motor_temperature_sensor_disconnection_fault_Grade_3'),
    (15, 'Hardware_overcurrent_fault'),
    (16, 'Hardware_overvoltage_fault'),
    (17, 'Drive_power_under_voltage_fault'),
    (19, 'Controller_drive_abnormal_fault'),
    (21, 'Low_voltage_power_supply_under_voltage_fault'),
    (22, 'U_phase_Hall_disconnection_fault'),
    (23, 'V_phase_Hall_disconnection_fault'),
    (24, 'W_phase_Hall_disconnection_fault'),
    (25, 'V_phase_Hall_abnormal_fault'),
    (26, 'W_phase_Hall_abnormal_fault'),
    (27, 'Throttle_Wiper1_Fail'),
    (28, 'Throttle_Wiper2_Fail'),
  ]),
  (0x334, 'MCU', [
    (0, 'Pos_Cnt_Mism_PWM_Fault'),
    (10, 'AB_Pulse_Mism_ZIPulse_Fault'),
    (23, 'ZIPulse_Missing_Fault'),
    (35, 'PWMMissingFault'),
  ]),
  (0x410, 'BMS', [
    (0, 'BMS00_Voltage_sensor_failureCell1'),
    (34, 'BMS00_Current_sensor_failure_Open_circuit'),
    (35, 'BMS00_Current_sensor_failure_Short_circuit'),
    (36, 'BMS00_Over_current_charge_Warning'),
    (37, 'BMS00_VOOR_CutOff_Error'),
    (38, 'BMS00_Precharge_too_fast_Info'),
    (39, 'BMS00_Precharge_too_slow_Info'),
    (40, 'BMS00_Precharge_failure'),
    (41, 'BMS00_MOSFETs_connection_failed'),
    (42, 'BMS00_MOSFETs_disconnection_failed'),
    (43, 'BMS00_PDU_temperature_warning_info'),
    (44, 'BMS00_PDU_temperature_error'),
    (45, 'BMS00_Over_voltage_charge_warning_info'),
    (46, 'BMS00_Over_voltage_charge_Error'),
    (47, 'BMS00_Over_voltage_charge_Permanent_Fault'),
    (48, 'BMS00_Over_voltage_regen_warning_info'),
    (49, 'BMS00_Over_voltage_regen_Error'),
    (50, 'BMS00_Under_voltage_warning_info'),
    (51, 'BMS00_Under_voltage_Error'),
    (52, 'BMS00_Under_voltage_Permanent_Fault'),
    (53, 'BMS00_Over_temperature_charge_warning_info'),
    (54, 'BMS00_Over_temperature_charge_Error'),
    (55, 'BMS00_Over_temperature_drive_warning_info'),
    (56, 'BMS00_Over_temperature_drive_Error'),
    (57, 'BMS00_Over_temperature_due_to_Cell_vent_error'),
    (58, 'BMS00_Over_temperature_due_to_Cell_vent_Failure'),
    (60, 'BMS00_Short_circuit_detection_permanent_fault'),
    (61, 'BMS00_Cell_failure_permanent_fault'),
    (62, 'BMS00_Over_current_charge_Error'),
    (63, 'BMS00_Low_temperature_during_charging_warning_info'),
  ]),
  (0x411, 'BMS', [
    (0, 'BMS00_Low_temperature_during_charging_Error'),
    (1, 'BMS00_Low_temperature_during_driving_Warning'),
    (2, 'BMS00_Low_temperature_during_driving_Error'),
    (3, 'Over_time_to_fast_charge_Error'),
    // b10 (Rat_Bite_Fault) is set on a healthy pack in real ride logs
    // — a benign/latched status bit, not an active fault — so it
    // is left out to avoid a false alarm.
    (11, 'CellDip_Error'),
    (12, 'CellDip_Fault'),
    (13, 'CompSpikeDtctn_Fault'),
    (14, 'CompSpike_Error'),
    (20, 'SBC_FAULT_ACTIVE'),
    (23, 'AFE_COM_LOST'),
    (24, 'External_Flash_COM_Lost'),
    (25, 'Battery_Temp_Fault_during_Slp'),
    (27, 'BMS_3.3V_Fault_Not_Good'),
    (30, 'PDU_Temperature_Error_during_Sleep'),
    (32, 'Battery_Pack_Temperature_Error_Sleep'),
    (34, 'Overcharge_Protection'),
    (38, 'Thermal_runaway_fault'),
    (39, 'Thermal_runaway_shadow_fault'),
  ]),
  (0x430, 'Body', [
    (2, 'Head_lamp_low_Overcurrent_fault'),
    (6, 'Head_lamp_high_Overcurrent_fault'),
    (10, 'Rear_position_Overcurrent_fault'),
    (14, 'Plate_Lamp_Overcurrent_Fault'),
    (18, 'Brake_lamp_Overcurrent_fault'),
    (22, 'Front_Position_lamp_Overcurrent_fault'),
    (26, 'Indicator_FL_Overcurrent_fault'),
    (30, 'Indicator_FR_Overcurrent_fault'),
    (34, 'Indicator_RL_Overcurrent_fault'),
    (38, 'Indicator_RR_Overcurrent_fault'),
    (42, 'Horn_Overcurrent_fault'),
    (46, 'Siren_Overcurrent_fault'),
    (50, 'Seat_Lock_Overcurrent_fault'),
    (54, 'Head_unit_Overcurrent_fault'),
    (58, 'Sidestand_sensor_Overcurrent_fault'),
    (62, 'HBC_Overcurrent_fault'),
  ]),
  (0x431, 'VCU', [
    (2, 'USB_charger_Overcurrent_fault'),
    (4, 'Fault_reported_by_BMS'),
    (5, 'Failure_reported_by_ESCL_ESCL_failure'),
    (6, 'Error_in_communication_with_HBC_Android'),
    (7, 'Error_in_communication_with_HBC_Vehicle'),
    (10, 'FC_Charger_Fault_Information'),
    (18, 'CPW_Overcurrent_fault'),
    (22, 'HV_FC_POS_contactor_Overcurrent_fault'),
    (24, 'Vehicle_DCDC_Open_circuit_fault'),
    (25, 'Vehicle_DCDC_Overtemperature_error'),
    (26, 'Vehicle_DCDC_Overcurrent_fault'),
    (27, 'Vehicle_DCDC_Overvoltage_fault'),
    (28, 'Vehicle_DCDC_Undervoltage_fault'),
    (30, 'ESCL_open_circuit_error'),
    (32, 'ESCL_Overcurrent_fault'),
  ]),
  (0x508, 'Charger', [
    (0, 'Charging_system_error'),
  ]),
  (0x66E, 'VCU', [
    (0, 'BMS_Board_Variant_SW_Mismatch'),
    (1, 'Cell_Chemistry_SW_Mismatch'),
    (3, 'VIN_Variant_mismatch'),
    (4, 'Variant_Dipswitch_Mismatch'),
    (5, 'BCM_BMS_Mismatch'),
    (6, 'SOM_BMS_Mismatch'),
    (7, 'MCU_SW_Variant_Mismatch'),
    (8, 'BCM_SW_Version_Variant_Mismatch'),
  ]),
  (0x670, 'VCU', [
    (32, 'VCU_Drive_Stop_Fault'),
    (33, 'VCU_Limp_Home_Fault'),
    (34, 'PDU_Error_BSW_signal'),
    (37, 'BMS_under_voltage_warning_BSW_signal'),
    (38, 'BMS_over_temp_drive_warning_BSW_signal'),
    (39, 'BMS_over_temp_drive_error_BSW_signal'),
  ]),
  (0x6DA, 'BMS', [
    // b2-5 are raw BMS monitoring inputs (SBC/AFE/charge/discharge), set during
    // normal riding in real logs — not latched faults, so omitted.
    (20, 'BMS_NVM_Failure_Status'),
  ]),
];

/// Every fault flag, flattened, in frame then bit order.
final List<FaultDef> faultCatalog = [
  for (final (frame, component, bits) in _frames)
    for (final (bit, signal) in bits) FaultDef(frame, bit, signal, component),
];

/// The CAN frames the catalog reads.
final Set<int> faultFrameIds = {for (final (frame, _, _) in _frames) frame};

/// A representative spread of faults for the dev panel / demo: one critical,
/// one error, one warning, across components.
List<ActiveFault> demoActiveFaults() {
  const signals = [
    'BMS00_Over_voltage_charge_Permanent_Fault',
    'Motor_overtemperature_Gratde_3',
    'BMS00_PDU_temperature_warning_info',
  ];
  return [
    for (final s in signals)
      if (faultCatalog.where((f) => f.signal == s).isNotEmpty) ActiveFault(faultCatalog.firstWhere((f) => f.signal == s)),
  ];
}

/// The faults active in [frames] (frame id → its 8 data bytes): a bit set to 1
/// means its fault is live. Returned severity-first (critical before info).
List<ActiveFault> activeFaultsIn(Map<int, Uint8List> frames) {
  final out = <ActiveFault>[];
  for (final def in faultCatalog) {
    final data = frames[def.frame];
    if (data == null) continue;
    if (extractSignal(data, def.bit, 1) != 0) out.add(ActiveFault(def));
  }
  out.sort((a, b) => b.severity.index.compareTo(a.severity.index));
  return out;
}
