import 'dart:convert';

import '../providers/hhmis_mapping.dart';
import '../state/scooter_capabilities.dart';

/// The largest values this scooter has itself reported, kept across
/// starts (`VehicleNotifier`), so a scale follows the scooter in front of
/// it and not one model's data sheet. Zero means not seen yet.
class ScooterPeaks {
  const ScooterPeaks({this.dischargeLimitW = 0, this.regenLimitW = 0, this.rpm = 0, this.torque = 0});

  /// Pack watts, rounded up to 100.
  final int dischargeLimitW;
  final int regenLimitW;

  /// In `VehicleData.rpm` units.
  final int rpm;

  /// Whole Nm, rounded up.
  final int torque;

  /// Folds one reading in; returns this when nothing grew.
  ScooterPeaks seen({required int dischargeLimitW, required int regenLimitW, required int rpm, required double torque}) {
    final d = _up(dischargeLimitW, 100);
    final g = _up(regenLimitW, 100);
    final r = rpm.abs();
    final t = torque.isFinite ? torque.abs().ceil() : 0;
    if (d <= this.dischargeLimitW && g <= this.regenLimitW && r <= this.rpm && t <= this.torque) return this;
    return ScooterPeaks(
      dischargeLimitW: d > this.dischargeLimitW ? d : this.dischargeLimitW,
      regenLimitW: g > this.regenLimitW ? g : this.regenLimitW,
      rpm: r > this.rpm ? r : this.rpm,
      torque: t > this.torque ? t : this.torque,
    );
  }

  static int _up(int v, int step) => v <= 0 ? 0 : ((v + step - 1) ~/ step) * step;

  /// The unit basis the fields are stored in. Bumped whenever a build
  /// changes how a value is kept, so an older blob is discarded and
  /// re-learned instead of being read in the wrong unit. v2: rpm is in
  /// `VehicleData.rpm` units (hundreds). Before the MoveOS 5 profile, a
  /// build with no profile stored raw rpm here (a 60 km/h ride left
  /// rpm=1711), which a later build read as 1711 hundreds = 171,100 rpm and
  /// blew up the rpm gauge's scale.
  /// The StockProfile now normalises rpm before it is stored, so every
  /// profile keeps the same unit and only the schema needs tracking.
  static const _schema = 2;

  String encode() => '$_schema|$dischargeLimitW|$regenLimitW|$rpm|$torque';

  static ScooterPeaks decode(String raw) {
    final p = raw.split('|').map(int.tryParse).toList();
    // A blob from before the schema (4 fields, no version) or from another
    // schema is dropped: re-learning takes one ride.
    if (p.length != 5 || p[0] != _schema || p.any((x) => x == null || x < 0)) return const ScooterPeaks();
    return ScooterPeaks(dischargeLimitW: p[1]!, regenLimitW: p[2]!, rpm: p[3]!, torque: p[4]!);
  }

  @override
  bool operator ==(Object other) =>
      other is ScooterPeaks &&
      other.dischargeLimitW == dischargeLimitW &&
      other.regenLimitW == regenLimitW &&
      other.rpm == rpm &&
      other.torque == torque;

  @override
  int get hashCode => Object.hash(dischargeLimitW, regenLimitW, rpm, torque);
}

/// The rider's own ride mode (MoveOS 5: events 178 to 188). Set from the
/// stock dashboard or the phone app; OpenDash only shows it. Null is not
/// sent. [name] is the rider's own word: it is shown, never logged.
class CustomRideMode {
  const CustomRideMode({
    this.name,
    this.enabled,
    this.isDefault,
    this.topSpeedKmh,
    this.powerPercent,
    this.throttle,
    this.regen,
    this.rangeKm,
    this.todayKm,
  });

  final String? name;

  /// `CUSTOM_RIDE_MODE` 1: the mode is switched on, so the handlebar
  /// switch offers it.
  final bool? enabled;

  /// `DEFAULT_RIDE_MODE` 1: the scooter starts in it.
  final bool? isDefault;
  final int? topSpeedKmh;

  /// Power and torque, 30 to 100 in tens.
  final int? powerPercent;

  /// Throttle response and regen strength, each a level from 0.
  final int? throttle;
  final int? regen;

  /// `INT_DIY_RANGE_CHANGED`: range left in this mode.
  final int? rangeKm;

  /// Distance ridden in this mode today.
  final double? todayKm;

  /// Whether the scooter has said anything about it.
  bool get known => name != null || topSpeedKmh != null || enabled != null;

  /// The name to show; stock's own default when the rider gave none.
  String get label => (name == null || name!.trim().isEmpty) ? 'MYMODE' : name!.trim();

  CustomRideMode copyWith({
    String? name,
    bool? enabled,
    bool? isDefault,
    int? topSpeedKmh,
    int? powerPercent,
    int? throttle,
    int? regen,
    int? rangeKm,
    double? todayKm,
  }) =>
      CustomRideMode(
        name: name ?? this.name,
        enabled: enabled ?? this.enabled,
        isDefault: isDefault ?? this.isDefault,
        topSpeedKmh: topSpeedKmh ?? this.topSpeedKmh,
        powerPercent: powerPercent ?? this.powerPercent,
        throttle: throttle ?? this.throttle,
        regen: regen ?? this.regen,
        rangeKm: rangeKm ?? this.rangeKm,
        todayKm: todayKm ?? this.todayKm,
      );

  /// The settled configuration, for keeping across starts so the mode shows
  /// from boot (HHMIS only re-sends these on a change). The live figures
  /// (`rangeKm`, `todayKm`) are left out: they are not identity.
  String encodeConfig() => jsonEncode({
        if (name != null) 'name': name,
        if (enabled != null) 'enabled': enabled,
        if (isDefault != null) 'isDefault': isDefault,
        if (topSpeedKmh != null) 'topSpeedKmh': topSpeedKmh,
        if (powerPercent != null) 'powerPercent': powerPercent,
        if (throttle != null) 'throttle': throttle,
        if (regen != null) 'regen': regen,
      });

  static CustomRideMode decodeConfig(String raw) {
    if (raw.isEmpty) return const CustomRideMode();
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return const CustomRideMode();
      T? pick<T>(String k) => j[k] is T ? j[k] as T : null;
      return CustomRideMode(
        name: pick<String>('name'),
        enabled: pick<bool>('enabled'),
        isDefault: pick<bool>('isDefault'),
        topSpeedKmh: pick<int>('topSpeedKmh'),
        powerPercent: pick<int>('powerPercent'),
        throttle: pick<int>('throttle'),
        regen: pick<int>('regen'),
      );
    } on FormatException {
      return const CustomRideMode();
    }
  }

  List<Object?> get _fields => [name, enabled, isDefault, topSpeedKmh, powerPercent, throttle, regen, rangeKm, todayKm];

  @override
  bool operator ==(Object other) {
    if (other is! CustomRideMode) return false;
    final a = _fields, b = other._fields;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_fields);
}

enum DriveMode {
  eco('ECO'),
  normal('NORMAL'),
  sport('SPORT'),
  hyper('HYPER');

  const DriveMode(this.label);
  final String label;

  static DriveMode parse(String raw) {
    final upper = raw.toUpperCase();
    return values.firstWhere((m) => m.label == upper, orElse: () => normal);
  }

  /// [status] is [VehicleData.modesAvailable].
  bool availableIn(int status) => switch (status) {
        1 => this == eco || this == normal,
        2 => this == eco,
        3 => false,
        _ => true,
      };
}

/// Who drives the headlamp: nobody's automation, the VCU's smart headlight
/// (day/night, on at motor start and off at park), or the rider after
/// pausing it from the beam button until the next park or lock.
enum SmartHeadlight { off, auto, paused }

/// HVSM `RegenState`, the value REGEN_SETTINGS_UPDATE carries both ways.
/// The ordinal is the wire value; [off] sends no 0x6BC frame at all.
enum RegenMode {
  standard('Default'),
  highway('Highway (light)'),
  city('City (strong)'),
  off('Off');

  const RegenMode(this.label);
  final String label;

  static RegenMode? fromWire(int raw) => raw >= 0 && raw < values.length ? values[raw] : null;
}

enum LockSource { userLock, autoPark }

/// A lock command in flight, waiting for the ESCL echo.
class LockAttempt {
  const LockAttempt({required this.sentAtMicros, required this.source});
  final int sentAtMicros;
  final LockSource source;

  @override
  bool operator ==(Object other) =>
      other is LockAttempt && other.sentAtMicros == sentAtMicros && other.source == source;

  @override
  int get hashCode => Object.hash(sentAtMicros, source);
}

enum VehicleState {
  parked,
  ready,
  riding,
  charging,
  fault,
  unknown;

  static VehicleState fromInt(int raw) =>
      raw >= 0 && raw < values.length ? values[raw] : unknown;

  bool get motorOn => this == ready || this == riding;
}

/// Charger detail. [VehicleData.isCharging] is the coarse "plugged in"
/// flag that drives the charging screen; this is what the charger is doing.
enum ChargingState { normal, low, initializing, charging, notCharging, complete }

/// The charging substate HHMIS broadcasts via `INT_HMI_STATUSBAR_STATUS`
/// (HVDP `HmiStatusBarStt`, of which HHMIS forwards only these four). Stock
/// HHMIC reads it, so it is for the dashboard.
enum ChargeSubstate {
  sna,                      // 0: no data
  chargeComplete,           // 1
  chargingSlowly,           // 2
  notCharging,              // 3
}

enum CruiseMode { off, standby, active }

enum AlertPriority { critical, warning, info }

enum AlertKind {
  sideStand,
  limpMode,
  fault,
  accidentDetected,
  thermalWarning,
  thermalRunaway,
  criticalBattery,
  batteryAtLimit,
  lowBattery,
  trunkOpen,
  deratingActive,
  brakeWorn,
  chargingComplete,
  tamper,
  speedLimitExceeded,
  unplugChargerToRide,
  lockFailed,
  unlockFailed,
  driveModeInPark,
  brakeToStart,
  standToRide,
  vehicleNotice,
}

const emergencyNumber = '112';

/// The vehicle's own message for a `CommandFromVehicle` (see
/// `providers/vehicle_commands.dart`): one at a time, held until the next
/// command or 0, as stock HHMIC shows it.
class VehicleNotice {
  const VehicleNotice(this.command, this.title, this.body, this.priority, {this.action});
  final int command;
  final String title;

  /// Changes every second on a countdown notice, so it is part of equality.
  final String body;
  final AlertPriority priority;
  final AlertAction? action;

  @override
  bool operator ==(Object other) => other is VehicleNotice && other.command == command && other.body == body;

  @override
  int get hashCode => Object.hash(command, body);
}

/// The button a banner carries. Stock's restart popup (faults 72 / 75) and
/// its handlebar-unlock popup both have one.
enum AlertAction {
  restartScooter('Restart'),
  retryUnlock('Retry unlock');

  const AlertAction(this.label);
  final String label;
}

/// Identity used to dismiss and track an alert. Most alerts are one per
/// `AlertKind`, but vehicle notices share
/// `AlertKind.vehicleNotice` across many commands: 142 ("Charger not
/// recognised") and 107 ("Battery fault") must be distinct dismissals,
/// never masking each other.
class AlertKey {
  const AlertKey(this.kind, [this.command]);
  final AlertKind kind;
  final int? command;

  @override
  bool operator ==(Object other) =>
      other is AlertKey && other.kind == kind && other.command == command;

  @override
  int get hashCode => Object.hash(kind, command);

  @override
  String toString() => command == null ? kind.name : '${kind.name}#$command';
}

class DashAlert {
  const DashAlert(this.kind, this.priority, this.title, this.body, {this.noticeCommand, this.action});
  final AlertKind kind;
  final AlertPriority priority;
  final String title;
  final String body;

  /// Command ordinal when this alert is a vehicle notice; null otherwise.
  /// Carried into AlertKey so two notices with the same kind are two
  /// distinct identities.
  final int? noticeCommand;
  final AlertAction? action;

  AlertKey get key => AlertKey(kind, noticeCommand);

  @override
  bool operator ==(Object other) =>
      other is DashAlert &&
      other.kind == kind &&
      other.priority == priority &&
      other.title == title &&
      other.body == body &&
      other.noticeCommand == noticeCommand &&
      other.action == action;

  @override
  int get hashCode => Object.hash(kind, priority, title, body, noticeCommand, action);
}

/// The scooter's own derate thresholds, in Celsius. The warn value is where it
/// limits to Normal (starts cutting current); the error value is where it forces
/// Park. Read live from the config frames the BMS/VCU broadcast — 0x217 (MCU),
/// 0x218 (motor), 0x219 (cell + PDU). The defaults are the Gen-1
/// values decoded from a Gen 1 scooter; a scooter that broadcasts its config
/// overrides them, so the warning matches whatever firmware it runs.
class ThermalLimits {
  const ThermalLimits({
    this.motorWarn = 147,
    this.motorError = 165,
    this.cellWarn = 55,
    this.cellError = 62,
    this.pduWarn = 85,
    this.pduError = 100,
    this.mcuWarn = 84,
    this.mcuError = 102,
  });

  final int motorWarn;
  final int motorError;
  final int cellWarn;
  final int cellError;
  final int pduWarn;
  final int pduError;
  final int mcuWarn;
  final int mcuError;

  List<Object> get _fields => [motorWarn, motorError, cellWarn, cellError, pduWarn, pduError, mcuWarn, mcuError];

  @override
  bool operator ==(Object other) =>
      other is ThermalLimits && _listEquals(other._fields, _fields);

  @override
  int get hashCode => Object.hashAll(_fields);
}

bool _listEquals(List<Object> a, List<Object> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Live rider/control inputs off CAN: throttle (0x113), brakes (0x15B), and the
/// handlebar switch clusters (0x6AC left, 0x6AD right). Shown on the Live Data
/// tab so a stuck throttle or a dead switch can be seen as it's pressed.
class LiveInputs {
  const LiveInputs({
    this.throttleV,
    this.mcuVoltage,
    this.frontBrake = false,
    this.rearBrake = false,
    this.beam = false,
    this.leftIndicator = false,
    this.rightIndicator = false,
    this.horn = false,
    this.cruise = false,
    this.cruiseEngaged = false,
    this.cruiseAvailability,
    this.driveModeBtn = false,
    this.motorCurrent,
    this.mcuDcCurrent,
    this.motorFrequency,
  });

  final double? throttleV;
  final double? mcuVoltage;
  final bool frontBrake;
  final bool rearBrake;
  final bool beam;
  final bool leftIndicator;
  final bool rightIndicator;
  final bool horn;
  final bool cruise;

  /// 0x113 `Cruise_Control_Status`: cruise is actively holding speed.
  final bool cruiseEngaged;

  /// 0x143 `Cruise_Control_Availability` ordinal (0 ready, 1 active,
  /// 2 mode-unsuitable, 3 speed-out-of-range, 4 not-available); null until seen.
  final int? cruiseAvailability;
  final bool driveModeBtn;

  /// Motor-electrical telemetry (0x223/0x224): phase current (A), MCU DC-bus
  /// current (A), and electrical frequency (Hz). Null until seen.
  final double? motorCurrent;
  final double? mcuDcCurrent;
  final double? motorFrequency;

  List<Object?> get _fields => [
        throttleV, mcuVoltage, frontBrake, rearBrake, beam, leftIndicator, rightIndicator, horn, cruise,
        cruiseEngaged, cruiseAvailability, driveModeBtn,
        motorCurrent, mcuDcCurrent, motorFrequency,
      ];

  @override
  bool operator ==(Object other) => other is LiveInputs && _listEqualsN(other._fields, _fields);

  @override
  int get hashCode => Object.hashAll(_fields);
}

bool _listEqualsN(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class VehicleData {
  const VehicleData({
    this.speed = 0,
    this.batterySoc = 100,
    this.range = 180,
    this.socSeen = true,
    this.rangeSeen = true,
    this.driveMode = DriveMode.normal,
    this.modesAvailable = 0,
    this.odometer = 0,
    this.odometerM = 0,
    this.tripMeter = 0,
    this.turnLeft = false,
    this.turnRight = false,
    this.hazard = false,
    this.hhmisStale = false,
    this.hhmisSilent = false,
    this.hhmisBacked = false,
    this.highBeam = false,
    this.smartHeadlight = SmartHeadlight.off,
    this.lowBeam = false,
    this.sideStand = false,
    this.lockState = 0,
    this.trunkOpen = false,
    this.trunkStateKnown = false,
    this.time = '00:00',
    this.vehicleState = VehicleState.parked,
    this.limpMode = false,
    this.cruiseMode = CruiseMode.off,
    this.apbActive = false,
    this.faultActive = false,
    this.faultCode = '',
    this.hillHoldActive = false,
    this.regenActive = false,
    this.regenMode = RegenMode.standard,
    this.brakeWorn = false,
    this.tamperDetected = false,
    this.fallDetected = false,
    this.takeMeHomeLights = false,
    this.takeMeHomeLightsRemaining = 0,
    this.autoTurnOff = false,
    this.positionLight = false,
    this.accidentDetected = false,
    this.thermalWarning = false,
    this.thermalRunaway = false,
    this.alarmActive = false,
    this.deratingActive = false,
    this.rpm = 0,
    this.power = 0,
    this.torque = 0,
    this.motorTemp = 30,
    this.batteryTemp = 28,
    this.pduTemp = 40,
    this.mcuTemp = 40,
    this.motorTempSeen = true,
    this.batteryTempSeen = true,
    this.pduTempSeen = false,
    this.mcuTempSeen = false,
    this.thermalLimits = const ThermalLimits(),
    this.liveInputs,
    this.regenEnergy = 0,
    this.dailyDistance = 0,
    this.dailyTopSpeed = 0,
    this.dailyAvgSpeed = 0,
    this.ecoDistance = 0,
    this.normalDistance = 0,
    this.sportDistance = 0,
    this.hyperDistance = 0,
    this.isCharging = false,
    this.chargingState = ChargingState.normal,
    this.minutesToFull = 0,
    this.minutesTo80 = 0,
    this.safeToUnplug = false,
    this.chargeStartTime = '',
    this.chargeLimit = 100,
    this.reverse = false,
    this.parkAssist = false,
    this.unplugToRideWarning = false,
    this.lockFailedWarning = false,
    this.notice,
    this.unlockFailedWarning = false,
    this.rangeEco = 0,
    this.rangeNormal = 0,
    this.rangeSport = 0,
    this.rangeHyper = 0,
    this.isHyperCharger = false,
    this.isBoostCharger = false,
    this.chargeMode = 0,
    this.btConnected = false,
    this.mediaPlaying = false,
    this.songTitle = '',
    this.songArtist = '',
    this.callActive = false,
    this.callerName = '',
    this.callerNumber = '',
    this.albumArt = '',
    this.mediaPosition = 0,
    this.mediaDuration = 0,
    this.volume = 50,
    this.musicOnSpeaker = false,
    this.callIncoming = false,
    this.callMuted = false,
    this.callDuration = 0,
    this.btDeviceName = '',
    this.btBondedDevices = const [],
    this.profileUserName = '',
    this.vehicleType,
    this.scooterBtName = 'S1Pro-2408',
    this.signalBars = 3,
    this.wifiConnected = true,
    this.gpsFix = true,
    this.hasNotification = false,
    this.hhmisConnected = false,
    this.navActive = false,
    this.nextTurnDirection = '',
    this.distanceToTurn = '',
    this.btPairingCode = '',
    this.hyperMinutesToFull = 0,
    this.hyperMinutesTo80 = 0,
    this.boostMinutesTo80 = 0,
    this.chargeSubstate = ChargeSubstate.sna,
    this.batteryMaxTemp,
    this.batteryMinTemp,
    this.fcChargeIdle = false,
    this.regenNotification = false,
    this.vehicleBrightness,
    this.rideEfficiency = 0,
    this.energyUsed = 0,
    this.navTotalDistance = '',
    this.navTotalTime = '',
    this.hintBrakeToStart = false,
    this.hintStandToRide = false,
    this.hintModeInPark = false,
    this.cruiseSetSpeed = 0,
    this.rejectCallAllowed = false,
    this.rejectCallText = "Hey, I'm riding. I'll call you back later",
    this.messageSentPopup = false,
    this.customerSupportNumber = '080-33113311',
    this.batteryHealthGood = true,
    this.batteryHealthKnown = false,
    this.batterySohDescription = '',
    this.moveOsVersion = '4.6.0',
    this.vswVersion = '4.6.0.0',
    this.vdpVersion = '2.1.3',
    this.hmiVersion = '1.0.0',
    this.bcmVersion = '3.2.1',
    this.bmsVersion = '2.8.4',
    this.mcuVersion = '4.1.0',
    this.hbcVersion = '1.3.2',
    this.huVersion = '1.0.0',
    this.bleVersion = '2.0.1',
    this.vin = 'OLA•••••••2408',
    this.iccid = '8991••••••••0042',
    this.wifiMac = 'AA:BB:CC:DD:EE:FF',
    this.ipAddress = '192.168.1.42',
    this.btMac = '11:22:33:44:55:66',
    this.rawBatterySoc = 0,
    this.ambientBrightness = 50,
    this.ambientKnown = true,
    this.ambientUsable = true,
    this.serviceIndicator = false,
    this.busVoltage = 0,
    this.packVoltage = 0,
    this.packCurrent = 0,
    this.regenPowerLimitW = 0,
    this.dischargePowerLimitW = 0,
    this.peaks = const ScooterPeaks(),
    this.customRide = const CustomRideMode(),
    this.customRideActive = false,
    this.rangeEcoCan = 0,
    this.regenAvailability = 0,
    this.regenAvailabilityKnown = false,
    this.towTheftState = 0,
    this.pendingLock,
    this.lockFailedAtMicros,
    this.featureMirror = const {},
    this.featureAvailable = const {},
    this.hillHoldConsent,
    this.alarmSoundIndex,
    this.safetySensitivity,
    this.stockAutoDownload,
    this.inclinationDegrees,
    this.touchDisabled = false,
  });

  final int speed;
  final int batterySoc;
  final int range;

  /// False on the scooter until HHMIS has sent the value once; the
  /// constructor defaults above are placeholders, not readings. The mock
  /// leaves these true. Widgets read the `*Known` getters, not these.
  final bool socSeen;
  final bool rangeSeen;
  final DriveMode driveMode;

  /// HHMIS `INT_VEHICLE_MODE_AVAILABLE_STATUS`, the VCU's
  /// `AvailableDrivingModes`: 0 all, 1 Sport and Hyper unavailable,
  /// 2 only Eco, 3 none.
  final int modesAvailable;
  final int odometer;

  /// CAN 0x356 `Odometer_Value_in_mtrs`: the same odometer in metres, at
  /// 10 Hz. 0 until the frame has been seen (and again when the CAN stream
  /// is lost); then use [odometer], which HHMIS sends in whole km.
  final int odometerM;
  final double tripMeter;
  final bool turnLeft;
  final bool turnRight;

  /// The BCM's hazard mode (BOOL_HAZARD_LIGHT_PERSIST_TOGGLE_STAT), not
  /// both turn signals: those flash on separate frames and are never true
  /// together.
  final bool hazard;

  /// Bound to HHMIS but no data for [AidlVehicleNotifier.staleAfter] while in
  /// front: the values on screen are frozen, not live.
  final bool hhmisStale;

  /// No HHMIS data for [AidlVehicleNotifier.staleAfter] while another app was
  /// in front (the stock dashboard takes the callback slot; the screen
  /// sleeps). Not shown: it stays until data arrives again, so a frozen 0
  /// proves nothing behind another app or in the moment after coming back.
  final bool hhmisSilent;

  /// HHMIS is the source of this data (Android). The mock is its own source:
  /// what it says is the truth, so it is never "unknown".
  final bool hhmisBacked;
  final bool highBeam;
  final SmartHeadlight smartHeadlight;
  final bool lowBeam;
  final bool sideStand;
  final int lockState;
  final bool trunkOpen;
  final bool trunkStateKnown;
  final String time;
  final VehicleState vehicleState;
  final bool limpMode;
  final CruiseMode cruiseMode;
  final bool apbActive;
  final bool faultActive;
  final String faultCode;
  final bool hillHoldActive;
  final bool regenActive;
  final RegenMode regenMode;
  final bool brakeWorn;
  final bool tamperDetected;
  final bool fallDetected;
  final bool takeMeHomeLights;
  final int takeMeHomeLightsRemaining;
  final bool autoTurnOff;
  final bool positionLight;
  final bool accidentDetected;
  final bool thermalWarning;
  final bool thermalRunaway;
  /// INT_VEHICLE_STATE = 1 (ALARM): the alarm screen, not the lock screen
  /// With [tamperDetected], [fallDetected] and
  /// [accidentDetected] it feeds `safetyScreenProvider`; leaving ALARM
  /// clears all three, as stock's TamperFallStatus = 0 does.
  final bool alarmActive;
  final bool deratingActive;

  /// Motor speed as HHMIS sends it, in units of [rpmUnit] rpm: 36 is
  /// 3,600 to 3,699 rpm. Multiply by [rpmUnit] to show it.
  final int rpm;

  /// HHMIS `VehicleManager.setMotorRpm` sends `rpm / 100` (`div-int/lit8
  /// 0x64`) of the CAN 0x313 word, which HVDP `MotorInfoParser.parserMcuData`
  /// passes on unscaled. Measured on Gen 1 rides: 31.1 rpm per km/h, 3,600
  /// at 117 km/h.
  static const rpmUnit = 100;
  final double power;
  final double torque;
  final int motorTemp;
  final int batteryTemp;

  /// PDU (BMS power-electronics) temperature from CAN 0x1A8; runs hotter than
  /// the cells and has its own limits. Null-sourced (CAN only), so [pduTempSeen]
  /// stays false until a reading arrives.
  final int pduTemp;

  /// MCU (motor controller / inverter) temperature from CAN 0x313. The fastest
  /// to heat (Ola covered its heatsink) and the usual derate trigger. CAN only.
  final int mcuTemp;
  final bool motorTempSeen;
  final bool batteryTempSeen;
  final bool pduTempSeen;
  final bool mcuTempSeen;

  /// The scooter's own derate thresholds (defaults until its config frames
  /// arrive). The thermal banners and the temp readout colours read these.
  final ThermalLimits thermalLimits;

  /// Live rider inputs (throttle, brakes, handlebar switches) off CAN; null
  /// until those frames arrive. Surfaced on the Live Data diagnostics tab.
  final LiveInputs? liveInputs;
  final double regenEnergy;
  final int dailyDistance;
  final int dailyTopSpeed;
  final int dailyAvgSpeed;
  final double ecoDistance;
  final double normalDistance;
  final double sportDistance;
  final double hyperDistance;

  final bool isCharging;
  final ChargingState chargingState;
  /// Minutes until full / 80% (HHMIS INT_BATTERY_TIME_TO_FULL_CHARGE_UPDATE /
  /// INT_BATTERY_OPTIMUM_CHARGE_TIME); 0 while the charger is idle. Stock
  /// shows the clock time they land on, recomputed every minute.
  final int minutesToFull;
  final int minutesTo80;
  final bool safeToUnplug;
  final String chargeStartTime;

  /// 50-100; 100 means no limit.
  final int chargeLimit;
  final bool reverse;

  /// MoveOS 5 smart/easy park: the scooter creeps forward or back on its
  /// own (`INT_VEHICLE_STATE` 7). Shown as its own wordmark; the creep
  /// direction is a separate event not read yet.
  final bool parkAssist;

  // Transient event flags. The source (mock now, AIDL later) raises them
  // and clears them after a few seconds; the alert list reads them.
  final bool unplugToRideWarning;
  final bool lockFailedWarning;
  final VehicleNotice? notice;
  final bool unlockFailedWarning;

  bool get chargingComplete => chargingState == ChargingState.complete;

  /// Stock arms the charge limit on a hyper or boost charger only
  /// (`BatteryInfoManager.setHyperChargeStatus`).
  bool get hyperCharging => isHyperCharger || isBoostCharger;
  final int rangeEco;
  final int rangeNormal;
  final int rangeSport;
  final int rangeHyper;
  final bool isHyperCharger;
  final bool isBoostCharger;

  /// HHMIS `INT_CHARGE_MODE` (`ChargingModes` ordinal): 3 charging, 4 hyper,
  /// 6 fast/boost, 0 SNA. Sent continuously, so unlike INT_CHARGE_STATUS it
  /// is known at boot while the scooter sits locked on the charger.
  final int chargeMode;

  /// Stock HHMIC's passcode-screen charging line keys off these three modes.
  bool get chargerCharging => const {3, 4, 6}.contains(chargeMode);

  final bool btConnected;
  final bool mediaPlaying;
  final String songTitle;
  final String songArtist;
  final bool callActive;
  final String callerName;
  final String callerNumber;
  final String albumArt;
  final int mediaPosition;
  final int mediaDuration;
  final int volume;
  final bool musicOnSpeaker;
  final bool callIncoming;
  final bool callMuted;
  final int callDuration;
  final String btDeviceName;

  /// Paired phones, by name. Android only; the mock has none.
  final List<String> btBondedDevices;

  /// The rider's name from the Ola app (`STR_PROFILE_USER_NAME`).
  final String profileUserName;

  /// `INT_PROFILE_VEHICLE_TYPE`: which scooter model this is (3 on an
  /// S1 Pro Gen 1). Null until HHMIS replays the profile.
  final int? vehicleType;
  final String scooterBtName;

  final int signalBars;
  final bool wifiConnected;
  final bool gpsFix;
  final bool hasNotification;
  final bool hhmisConnected;

  final bool navActive;
  final String nextTurnDirection;
  final String distanceToTurn;

  /// Six digits while a phone is pairing; empty otherwise.
  final String btPairingCode;
  /// Fast-charger companions: INT_FC_BATTERY_TIME_TO_FULL_CHARGE_UPDATE and
  /// INT_FC_BATTERY_OPTIMUM_CHARGE_UPDATE (optimum is 80%), in minutes.
  final int hyperMinutesToFull;
  final int hyperMinutesTo80;
  final int boostMinutesTo80;

  /// `INT_HMI_STATUSBAR_STATUS` — HVDP's `HmiStatusBarStt` enum, an
  /// independent charging substate HHMIS broadcasts in every batch.
  /// Richer than `isCharging` because it distinguishes slow / complete /
  /// not-charging / hyper-init.
  final ChargeSubstate chargeSubstate;

  /// `FLOAT_BATTERY_MIN_TEMP` / `_MAX_TEMP`. Null until HHMIS has sent
  /// the key; the CAN path does not write these.
  final double? batteryMinTemp;
  final double? batteryMaxTemp;

  /// `BOOL_FC_CHARGE_IDLE_STATUS` — fast charger is idling (plugged, not
  /// drawing current). Appears on the charging screen as "Idle".
  final bool fcChargeIdle;

  /// `BOOL_VEHICLE_REGEN_NOTIFICATION_STATUS` — VCU notification that
  /// regen was just applied. Stock shows a brief toast.
  final bool regenNotification;

  /// `INT_VEHICLE_BRIGHTNESS` — the vehicle's view of the current
  /// brightness (0-100). Used to mirror external changes back into our
  /// brightness slider without re-sending to HHMIS.
  final int? vehicleBrightness;

  /// Wh/km for the current ride; 0 until there is data.
  final double rideEfficiency;

  /// kWh consumed this ride.
  final double energyUsed;

  final String navTotalDistance;
  final String navTotalTime;

  /// Start button pressed without the brake held.
  final bool hintBrakeToStart;

  /// Side stand still down with the motor on.
  final bool hintStandToRide;

  /// Mode button pressed while parked.
  final bool hintModeInPark;

  /// Speed captured when cruise went active.
  final int cruiseSetSpeed;

  final bool rejectCallAllowed;
  final String rejectCallText;
  final bool messageSentPopup;
  final String customerSupportNumber;

  /// BatteryHealth and BatterySoHDescription; the schema has no SOH percentage.
  final bool batteryHealthGood;
  /// BOOL_PACK_SOH_STAT drives this; until it
  /// arrives, batteryHealthGood is unknown. Was defaulting to Good.
  final bool batteryHealthKnown;
  final String batterySohDescription;

  final String moveOsVersion;
  final String vswVersion;
  final String vdpVersion;
  final String hmiVersion;
  final String bcmVersion;
  final String bmsVersion;
  final String mcuVersion;
  final String hbcVersion;
  final String huVersion;
  final String bleVersion;
  final String vin;
  final String iccid;
  final String wifiMac;
  final String ipAddress;
  final String btMac;

  /// Raw BMS SOC at 0.01% resolution (CAN 0x120). More accurate than
  /// the display SOC but still can't predict a weak-cell BMS cutoff.
  final double rawBatterySoc;

  /// Ambient light sensor, 0-100 (CAN 0x353).
  final int ambientBrightness;

  /// False until the sensor has reported; the bridge starts false so the
  /// ambient-driven theme and brightness stay inert without a reading.
  final bool ambientKnown;

  /// Whether [ambientBrightness] has been seen to behave like a light
  /// sensor on this scooter (`AmbientHealth`): on some it is a fixed
  /// number. True in the mock, where the dev slider is the sensor.
  final bool ambientUsable;

  /// The light reading when there is one worth acting on, otherwise null
  /// and the caller falls back to the time of day.
  int? get ambientReading => ambientKnown && ambientUsable ? ambientBrightness : null;
  final bool serviceIndicator;

  /// TODO(service-indicator): HVDP does not read bit 43 of 0x353, so the decoded
  /// wrench is unverified. The field and decoder stay; the display is
  /// hidden until a real frame has been observed with the bit set.
  static const serviceIndicatorVerified = false;

  /// DC-link bus volts (0x150 b0-1, HVDP `onBusVoltage`; also HHMIS
  /// FLOAT_VEHICLE_VOLTAGE). Reads ~25 V parked with the contactor open, so
  /// it is not the pack.
  final double busVoltage;

  /// Measured pack volts (0x1A8 b4-5); 0 until the frame arrives.
  final double packVoltage;

  /// Pack amps (0x120); negative while the battery is being drawn from, positive while charging.
  final double packCurrent;

  /// BMS ceilings in watts (0x140); regen 0 means the pack will not take charge.
  final int regenPowerLimitW;
  final int dischargePowerLimitW;
  final ScooterPeaks peaks;

  /// The rider's own ride mode, and whether the scooter is in it now
  /// (MoveOS 5; never sent by 4.6.14).
  final CustomRideMode customRide;
  final bool customRideActive;

  /// Eco-mode range from CAN 0x6F4 word 0 (HVDP `VehicleRangeBasedOnModes`
  /// takes the four words as Eco, Sport, Normal, Hyper). Not a limp range:
  /// the VCU has none. 0 until the frame arrives.
  final int rangeEcoCan;

  /// HVDP `RegenAvailability` (0x683): 0 NOT_AVAILABLE, 1 AVAILABLE,
  /// 2 NOT_AVAILABLE_THROTTLE, 3 reserved. Meaningless until
  /// [regenAvailabilityKnown]; the telltale stays neutral before then.
  final int regenAvailability;
  final bool regenAvailabilityKnown;

  /// `TowTheftDetection` (0x683 / HHMIS): 0 SNA, 1 ACTIVE, 2 INACTIVE.
  final int towTheftState;

  /// Lock sent, ESCL "locked" not yet seen. Stays set through the failure
  /// hold so the UI can tell "locking…" from "lock failed"
  /// ([lockFailedAtMicros]); both clear together when the hold ends.
  final LockAttempt? pendingLock;

  /// Analytics-clock micros when the pending lock timed out; cleared by
  /// the echo or after a few seconds.
  final int? lockFailedAtMicros;

  /// What the vehicle says is persisted for each riding feature, keyed by
  /// the `RidingFeature.name` slug. Driven by the `BOOL_*_PERSIST_TOGGLE_STAT`
  /// echoes HHMIS broadcasts (R-9: only the PERSIST variants mean "on";
  /// the plain `_TOGGLE_STAT` variants mean "sent"). Mirrored into
  /// `RidingSettings` without re-sending so vehicle-wins at boot.
  final Map<String, bool> featureMirror;

  /// What the vehicle says it has, from the `BOOL_*_FEATURE_AVAILABLE` /
  /// `INT_*_FEATURE_AVAILABLE` keys (the INT ones mean available only at 1)
  /// and `INT_TECH_PACH_REGEN`. Keyed like [featureMirror], plus `hazard`
  /// and `regen`. A missing key means HHMIS has not said yet.
  final Map<String, bool> featureAvailable;

  /// What the scooter says it is fitted with. Senders and screens ask
  /// `ScooterCapabilities` (`lib/state/scooter_capabilities.dart`), which
  /// also knows what the scooter's software can be told; this is its
  /// "fitted" half, kept here for code that only has the data.
  bool isFeatureAvailable(String feature) => ScooterCapabilities(available: featureAvailable).fitted(feature);

  /// `INT_PERSISTED_USER_HILLHOLD_CONDITIONACCEPTED == 1`; null until HHMIS
  /// replays the profile.
  final bool? hillHoldConsent;

  /// `INT_PERSISTED_ALARM_ALERT_SOUND`: 0 or 1, the two stock alarm sounds.
  final int? alarmSoundIndex;

  /// `INT_PERSISTED_SAFETY_SENSITIVITY`: 0 low, 1 high (tow/theft).
  final int? safetySensitivity;

  /// The stock dashboard's auto-download setting in the rider's profile
  /// (`AUTODOWNLOAD_UPDATE`, 1 on / 0 off), null until HHMIS has replayed
  /// it. Only the stock dashboard acts on it; see `firmware_state.dart`.
  final int? stockAutoDownload;

  /// `INT_VEHICLE_INCLINATION_DEGREE`, whole degrees.
  final int? inclinationDegrees;

  /// True when the VCU has cut (or is cutting) the head-unit's power supply
  /// (`BOOL_HEAD_UNIT_POWER_FLAG = false`). Stock HHMIC's `setTouchDisabled`
  /// gates touch input the same way during the grace window before the 12 V
  /// rail drops. We wrap the DesignCanvas in an IgnorePointer driven by this.
  final bool touchDisabled;

  /// The one "is this number worth showing" decision: bound to HHMIS and
  /// the values are live. Per-value getters add "and it has arrived", since
  /// the first batches can lack a key (motor temperature is sparse).
  /// Render '—' when false.
  bool get hhmisKnown => hhmisConnected && !hhmisStale;

  /// [rpm] is stored as HHMIS sends it (about 100 rpm a unit). If the stored
  /// unit changes, this is the one number to change with it.
  static const rpmStoredPerRaw = 1;

  /// Over a day of Gen 1 rides (11,667 heartbeats, 0-117 km/h) the motor rpm
  /// followed the speed at 0.31 raw per km/h; the widest gap was 2.13 raw
  /// (5 at 23 km/h) and at 0 km/h it never read above 1. Further apart than
  /// the tolerance, one of the two is wrong and the speed proves nothing.
  // TODO(speed-rpm): one scooter's ratio (survey.ratio measured 0.30 on a Gen 1). On another motor or wheel a
  // correct speed would be called untrusted. Learn it per scooter; design first, it gates commands.
  static const rpmPerKmh = 0.31 * rpmStoredPerRaw;
  static const rpmSpeedTolerance = 3.0 * rpmStoredPerRaw;
  bool get speedRpmMismatch => (rpm.abs() - speed * rpmPerKmh).abs() > rpmSpeedTolerance;

  /// Why [speed] can't be relied on (the `safety.untrusted_cancel` reason),
  /// or null when it can. A frozen 0 looks exactly like a parked scooter.
  String? get speedUntrustedReason => !hhmisBacked
      ? null
      : !hhmisConnected
          ? 'disconnected'
          : hhmisStale || hhmisSilent
              ? 'stale'
              : speedRpmMismatch
                  ? 'speed_rpm_mismatch'
                  : null;
  bool get speedTrusted => speedUntrustedReason == null;

  /// The battery is holding the scooter back: it has lowered its own
  /// discharge limit (CAN `BMS_Parameter_Limit`) well below the most it
  /// has ever offered, and the motor is drawing all of what is left. It
  /// needs no voltage of ours: the battery knows where it cuts out,
  /// OpenDash does not. Reaching a full limit on a hard pull is normal
  /// and shows nothing: on one ride the pulls reached 85 to 91 % of a
  /// limit that ran from 12.2 kW full to 9.8 kW at 56 %.
  /// The limit is in pack watts and `power` is on stock's display scale,
  /// so the limit takes the same factor (as in `powerBarMaxFor`).
  bool get batteryAtLimit =>
      dischargePowerLimitW > 0 &&
      dischargePowerLimitW <= peaks.dischargeLimitW * batteryLimitLowered &&
      power >= batteryLimitMinKw &&
      power * 1000 >= dischargePowerLimitW * HhmisPower.displayScale * batteryLimitShare;

  /// The draw counts as "at the limit" from this share of it, only above
  /// a draw that is worth the name, and only once the limit is down to
  /// this share of the highest this battery has reported.
  static const batteryLimitShare = 0.9;
  static const batteryLimitMinKw = 1.0;
  // TODO(battery-limit): 0.9, 1.0 kW and 0.75 are choices; no ride has raised this banner. Confirm on a low or
  // cold battery that it shows when the scooter is really held back, and not otherwise.
  static const batteryLimitLowered = 0.75;

  /// The only "stopped" an action may be gated on.
  bool get provenStopped => speed == 0 && speedTrusted;
  bool get movingOrUnknown => !provenStopped;
  bool get socKnown => hhmisKnown && socSeen;
  bool get rangeKnown => hhmisKnown && rangeSeen;
  bool get motorTempKnown => hhmisKnown && motorTempSeen;
  bool get batteryTempKnown => hhmisKnown && batteryTempSeen;

  /// PDU temp comes from the CAN diagnostics stream, not HHMIS.
  bool get pduTempKnown => pduTempSeen;

  /// MCU temp comes from the CAN diagnostics stream, not HHMIS.
  bool get mcuTempKnown => mcuTempSeen;

  /// Labelled for riders, not the ECU glossary.
  List<(String, String)> get firmwareVersions => [
        ('MoveOS', moveOsVersion),
        ('Vehicle Software', vswVersion),
        ('Vehicle Data Protocol', vdpVersion),
        ('Dashboard', hmiVersion),
        ('Body Control Module', bcmVersion),
        ('Battery Management', bmsVersion),
        ('Motor Controller', mcuVersion),
        ('Hub Controller', hbcVersion),
        ('Head Unit', huVersion),
        ('Bluetooth', bleVersion),
      ];

  bool get hasAlbumArt => albumArt.isNotEmpty;

  bool get locked => lockState == 4;

  /// Not gated on [btConnected]: on a ride that flag stayed false with
  /// music playing, and a playing session is itself proof of a phone.
  bool get mediaVisible => mediaPlaying;

  String get callerLabel => callerName.isNotEmpty
      ? callerName
      : callerNumber.isNotEmpty
          ? callerNumber
          : 'Unknown';

  /// Our advance warning fires this many degrees *below* the scooter's own
  /// derate point, so the rider can ease off before the scooter cuts power. 9
  /// is the MCU's own hysteresis band (SET 84, RESET 75), the component that
  /// matters; the other reset values are too uneven to use (motor 57 below,
  /// cell/PDU none), so SET-9 is the cleaner advance for all four.
  static const thermalAdvance = 9;

  bool get thermalHot =>
      thermalWarning ||
      motorTemp > thermalLimits.motorError ||
      batteryTemp > thermalLimits.cellError ||
      (pduTempSeen && pduTemp > thermalLimits.pduError) ||
      (mcuTempSeen && mcuTemp > thermalLimits.mcuError);

  /// Within [thermalAdvance] of the scooter's derate point: the pre-derate
  /// heads-up, which also stays up while it is derating (the scooter does not
  /// announce Normal mode persistently).
  bool get thermalWarm =>
      motorTemp > thermalLimits.motorWarn - thermalAdvance ||
      batteryTemp > thermalLimits.cellWarn - thermalAdvance ||
      (pduTempSeen && pduTemp > thermalLimits.pduWarn - thermalAdvance) ||
      (mcuTempSeen && mcuTemp > thermalLimits.mcuWarn - thermalAdvance);

  List<DashAlert> get alerts {
    final out = <DashAlert>[];
    if (sideStand && vehicleState.motorOn) {
      out.add(const DashAlert(AlertKind.sideStand, AlertPriority.critical,
          'Side stand down', 'Retract the side stand to ride'));
    }
    final n = notice;
    if (n != null) {
      out.add(DashAlert(AlertKind.vehicleNotice, n.priority, n.title, n.body, noticeCommand: n.command, action: n.action));
    }
    if (limpMode) {
      out.add(const DashAlert(AlertKind.limpMode, AlertPriority.critical,
          'Limp mode', 'Power is limited. Pull over when safe'));
    }
    // The vehicle's own message says it better while it is up.
    if (faultActive && n == null) {
      out.add(DashAlert(
        AlertKind.fault,
        AlertPriority.critical,
        'Vehicle fault',
        faultCode.isEmpty
            ? 'Stop safely and contact service'
            : 'Fault $faultCode. Stop safely and contact service',
      ));
    }
    if (accidentDetected) {
      out.add(const DashAlert(AlertKind.accidentDetected, AlertPriority.critical,
          'Accident detected', 'Call $emergencyNumber if emergency services are needed'));
    }
    // Two tiers, both ahead of the scooter's own action: a warning banner a
    // few degrees before it derates ([thermalAdvance]), so the rider can ease
    // off and avoid it, which also stays up while it is derating (the scooter
    // does not show Normal mode persistently); and a critical banner at the
    // Park error. The controller (MCU) leads, since it heats fastest.
    if (thermalHot || thermalWarm) {
      final hot = thermalHot;
      const m = thermalAdvance;
      final parts = <String>[
        if (mcuTempSeen && mcuTemp > (hot ? thermalLimits.mcuError : thermalLimits.mcuWarn - m)) 'MCU $mcuTemp°',
        if (pduTempSeen && pduTemp > (hot ? thermalLimits.pduError : thermalLimits.pduWarn - m)) 'BMS $pduTemp°',
        if (motorTemp > (hot ? thermalLimits.motorError : thermalLimits.motorWarn - m)) 'Motor $motorTemp°',
        if (batteryTemp > (hot ? thermalLimits.cellError : thermalLimits.cellWarn - m)) 'Battery $batteryTemp°',
      ];
      out.add(DashAlert(
        AlertKind.thermalWarning,
        hot ? AlertPriority.critical : AlertPriority.warning,
        hot ? 'Overheating' : 'Heating up',
        parts.isEmpty
            ? (hot ? 'Pull over and let the scooter cool' : 'Ease off to avoid reduced performance')
            : hot
                ? '${parts.join(', ')}. Pull over and let it cool'
                : '${parts.join(', ')}. Ease off to avoid reduced performance',
      ));
    }
    // Stock HHMIC text for INT_THERMAL_RUNAWAY.
    // Separate from thermalHot because plugging in must not clear it.
    if (thermalRunaway) {
      out.add(const DashAlert(AlertKind.thermalRunaway, AlertPriority.critical,
          'Scooter Issue', 'please maintain a safe distance'));
    }
    if (batteryAtLimit) {
      out.add(const DashAlert(AlertKind.batteryAtLimit, AlertPriority.warning,
          'Battery at its limit', 'It cannot give more power right now. Ease off, and charge soon'));
    }
    if (batterySoc < 5 && !isCharging) {
      out.add(const DashAlert(AlertKind.criticalBattery, AlertPriority.critical,
          'Battery critical', 'Charge now. The scooter may stop soon'));
    } else if (batterySoc < 10 && !isCharging) {
      out.add(const DashAlert(AlertKind.lowBattery, AlertPriority.warning,
          'Battery low', 'Charge soon to avoid being stranded'));
    }
    // Ours only: stock shows its boot popup in PARK and CHARGING (a toast
    // here, from AidlVehicleNotifier) and nothing while moving.
    if (trunkOpen && trunkStateKnown && vehicleState == VehicleState.riding) {
      out.add(const DashAlert(AlertKind.trunkOpen, AlertPriority.warning,
          'Boot open', 'Close the boot before riding on'));
    }
    if (deratingActive && n == null) {
      out.add(const DashAlert(AlertKind.deratingActive, AlertPriority.warning,
          'Power reduced', 'Power reduced to protect the battery'));
    }
    if (brakeWorn) {
      out.add(const DashAlert(AlertKind.brakeWorn, AlertPriority.warning,
          'Brakes worn', 'Get brake pads inspected'));
    }
    if (chargingComplete) {
      out.add(const DashAlert(AlertKind.chargingComplete, AlertPriority.info,
          'Charging complete', 'Battery full. Safe to unplug'));
    }
    if (tamperDetected) {
      out.add(const DashAlert(AlertKind.tamper, AlertPriority.critical,
          'Tamper alert', 'Movement detected while locked'));
    }
    if (unplugToRideWarning) {
      out.add(const DashAlert(AlertKind.unplugChargerToRide, AlertPriority.warning,
          'Unplug charger to ride', 'Disconnect the charger before setting off'));
    }
    if (lockFailedWarning) {
      out.add(const DashAlert(AlertKind.lockFailed, AlertPriority.warning,
          'Handlebars not locked', 'Turn the handlebars left and try again'));
    }
    if (unlockFailedWarning) {
      out.add(const DashAlert(AlertKind.unlockFailed, AlertPriority.warning,
          'Unlock failed', 'Turn the handlebars and try again', action: AlertAction.retryUnlock));
    }
    if (hintBrakeToStart) {
      out.add(const DashAlert(AlertKind.brakeToStart, AlertPriority.info,
          'Hold the brake', 'Press and hold the brake lever, then press the start button'));
    }
    if (hintStandToRide) {
      out.add(const DashAlert(AlertKind.standToRide, AlertPriority.info,
          'Retract side stand', 'Lift the side stand, or hold brake + cruise + power to ride'));
    }
    // The scooter's hint is about a mode button pressed in park. It was
    // still up 3 s later with the scooter under way, because Settings had
    // covered it until then (seen on a scooter).
    if (hintModeInPark && vehicleState == VehicleState.parked) {
      out.add(const DashAlert(AlertKind.driveModeInPark, AlertPriority.info,
          'Mode selected', 'Mode change applies when riding'));
    }
    out.sort((a, b) => a.priority.index.compareTo(b.priority.index));
    return out;
  }

  VehicleData copyWith({
    int? speed,
    int? batterySoc,
    int? range,
    bool? socSeen,
    bool? rangeSeen,
    DriveMode? driveMode,
    int? modesAvailable,
    int? odometer,
    int? odometerM,
    double? tripMeter,
    bool? turnLeft,
    bool? turnRight,
    bool? hazard,
    bool? hhmisStale,
    bool? hhmisSilent,
    bool? hhmisBacked,
    bool? highBeam,
    SmartHeadlight? smartHeadlight,
    bool? lowBeam,
    bool? sideStand,
    int? lockState,
    bool? trunkOpen,
    bool? trunkStateKnown,
    String? time,
    VehicleState? vehicleState,
    bool? limpMode,
    CruiseMode? cruiseMode,
    bool? apbActive,
    bool? faultActive,
    String? faultCode,
    bool? hillHoldActive,
    bool? regenActive,
    RegenMode? regenMode,
    bool? brakeWorn,
    bool? tamperDetected,
    bool? fallDetected,
    bool? takeMeHomeLights,
    int? takeMeHomeLightsRemaining,
    bool? autoTurnOff,
    bool? positionLight,
    bool? accidentDetected,
    bool? thermalWarning,
    bool? thermalRunaway,
    bool? alarmActive,
    bool? deratingActive,
    int? rpm,
    double? power,
    double? torque,
    int? motorTemp,
    int? batteryTemp,
    int? pduTemp,
    int? mcuTemp,
    bool? motorTempSeen,
    bool? batteryTempSeen,
    bool? pduTempSeen,
    bool? mcuTempSeen,
    ThermalLimits? thermalLimits,
    LiveInputs? liveInputs,
    double? regenEnergy,
    int? dailyDistance,
    int? dailyTopSpeed,
    int? dailyAvgSpeed,
    double? ecoDistance,
    double? normalDistance,
    double? sportDistance,
    double? hyperDistance,
    bool? isCharging,
    ChargingState? chargingState,
    int? minutesToFull,
    int? minutesTo80,
    bool? safeToUnplug,
    String? chargeStartTime,
    int? chargeLimit,
    bool? reverse,
    bool? parkAssist,
    bool? unplugToRideWarning,
    bool? lockFailedWarning,
    bool? unlockFailedWarning,
    int? rangeEco,
    int? rangeNormal,
    int? rangeSport,
    int? rangeHyper,
    bool? isHyperCharger,
    bool? isBoostCharger,
    int? chargeMode,
    bool? btConnected,
    bool? mediaPlaying,
    String? songTitle,
    String? songArtist,
    bool? callActive,
    String? callerName,
    String? callerNumber,
    String? albumArt,
    int? mediaPosition,
    int? mediaDuration,
    int? volume,
    bool? musicOnSpeaker,
    bool? callIncoming,
    bool? callMuted,
    int? callDuration,
    String? btDeviceName,
    List<String>? btBondedDevices,
    String? profileUserName,
    int? vehicleType,
    String? scooterBtName,
    int? signalBars,
    bool? wifiConnected,
    bool? gpsFix,
    bool? hasNotification,
    bool? hhmisConnected,
    bool? navActive,
    String? nextTurnDirection,
    String? distanceToTurn,
    String? btPairingCode,
    int? hyperMinutesToFull,
    int? hyperMinutesTo80,
    int? boostMinutesTo80,
    ChargeSubstate? chargeSubstate,
    double? Function()? batteryMinTemp,
    double? Function()? batteryMaxTemp,
    bool? fcChargeIdle,
    bool? regenNotification,
    int? Function()? vehicleBrightness,
    double? rideEfficiency,
    double? energyUsed,
    String? navTotalDistance,
    String? navTotalTime,
    bool? hintBrakeToStart,
    bool? hintStandToRide,
    bool? hintModeInPark,
    int? cruiseSetSpeed,
    bool? rejectCallAllowed,
    String? rejectCallText,
    bool? messageSentPopup,
    String? customerSupportNumber,
    bool? batteryHealthGood,
    bool? batteryHealthKnown,
    String? batterySohDescription,
    String? moveOsVersion,
    String? vswVersion,
    String? vdpVersion,
    String? hmiVersion,
    String? bcmVersion,
    String? bmsVersion,
    String? mcuVersion,
    String? hbcVersion,
    String? huVersion,
    String? bleVersion,
    String? vin,
    String? iccid,
    String? wifiMac,
    String? ipAddress,
    String? btMac,
    double? rawBatterySoc,
    int? ambientBrightness,
    bool? ambientKnown,
    bool? ambientUsable,
    bool? serviceIndicator,
    double? busVoltage,
    double? packVoltage,
    double? packCurrent,
    int? regenPowerLimitW,
    int? dischargePowerLimitW,
    ScooterPeaks? peaks,
    CustomRideMode? customRide,
    bool? customRideActive,
    int? rangeEcoCan,
    int? regenAvailability,
    bool? regenAvailabilityKnown,
    int? towTheftState,
    LockAttempt? Function()? pendingLock,
    VehicleNotice? Function()? notice,
    int? Function()? lockFailedAtMicros,
    Map<String, bool>? featureMirror,
    Map<String, bool>? featureAvailable,
    bool? Function()? hillHoldConsent,
    int? Function()? alarmSoundIndex,
    int? Function()? safetySensitivity,
    int? Function()? stockAutoDownload,
    int? Function()? inclinationDegrees,
    bool? touchDisabled,
  }) {
    return VehicleData(
      speed: speed ?? this.speed,
      batterySoc: batterySoc ?? this.batterySoc,
      range: range ?? this.range,
      socSeen: socSeen ?? this.socSeen,
      rangeSeen: rangeSeen ?? this.rangeSeen,
      driveMode: driveMode ?? this.driveMode,
      modesAvailable: modesAvailable ?? this.modesAvailable,
      odometer: odometer ?? this.odometer,
      odometerM: odometerM ?? this.odometerM,
      tripMeter: tripMeter ?? this.tripMeter,
      turnLeft: turnLeft ?? this.turnLeft,
      turnRight: turnRight ?? this.turnRight,
      hazard: hazard ?? this.hazard,
      hhmisStale: hhmisStale ?? this.hhmisStale,
      hhmisSilent: hhmisSilent ?? this.hhmisSilent,
      hhmisBacked: hhmisBacked ?? this.hhmisBacked,
      highBeam: highBeam ?? this.highBeam,
      smartHeadlight: smartHeadlight ?? this.smartHeadlight,
      lowBeam: lowBeam ?? this.lowBeam,
      sideStand: sideStand ?? this.sideStand,
      lockState: lockState ?? this.lockState,
      trunkOpen: trunkOpen ?? this.trunkOpen,
      trunkStateKnown: trunkStateKnown ?? this.trunkStateKnown,
      time: time ?? this.time,
      vehicleState: vehicleState ?? this.vehicleState,
      limpMode: limpMode ?? this.limpMode,
      cruiseMode: cruiseMode ?? this.cruiseMode,
      apbActive: apbActive ?? this.apbActive,
      faultActive: faultActive ?? this.faultActive,
      faultCode: faultCode ?? this.faultCode,
      hillHoldActive: hillHoldActive ?? this.hillHoldActive,
      regenActive: regenActive ?? this.regenActive,
      regenMode: regenMode ?? this.regenMode,
      brakeWorn: brakeWorn ?? this.brakeWorn,
      tamperDetected: tamperDetected ?? this.tamperDetected,
      fallDetected: fallDetected ?? this.fallDetected,
      takeMeHomeLights: takeMeHomeLights ?? this.takeMeHomeLights,
      takeMeHomeLightsRemaining: takeMeHomeLightsRemaining ?? this.takeMeHomeLightsRemaining,
      autoTurnOff: autoTurnOff ?? this.autoTurnOff,
      positionLight: positionLight ?? this.positionLight,
      accidentDetected: accidentDetected ?? this.accidentDetected,
      thermalWarning: thermalWarning ?? this.thermalWarning,
      thermalRunaway: thermalRunaway ?? this.thermalRunaway,
      alarmActive: alarmActive ?? this.alarmActive,
      deratingActive: deratingActive ?? this.deratingActive,
      rpm: rpm ?? this.rpm,
      power: power ?? this.power,
      torque: torque ?? this.torque,
      motorTemp: motorTemp ?? this.motorTemp,
      batteryTemp: batteryTemp ?? this.batteryTemp,
      pduTemp: pduTemp ?? this.pduTemp,
      mcuTemp: mcuTemp ?? this.mcuTemp,
      motorTempSeen: motorTempSeen ?? this.motorTempSeen,
      batteryTempSeen: batteryTempSeen ?? this.batteryTempSeen,
      pduTempSeen: pduTempSeen ?? this.pduTempSeen,
      mcuTempSeen: mcuTempSeen ?? this.mcuTempSeen,
      thermalLimits: thermalLimits ?? this.thermalLimits,
      liveInputs: liveInputs ?? this.liveInputs,
      regenEnergy: regenEnergy ?? this.regenEnergy,
      dailyDistance: dailyDistance ?? this.dailyDistance,
      dailyTopSpeed: dailyTopSpeed ?? this.dailyTopSpeed,
      dailyAvgSpeed: dailyAvgSpeed ?? this.dailyAvgSpeed,
      ecoDistance: ecoDistance ?? this.ecoDistance,
      normalDistance: normalDistance ?? this.normalDistance,
      sportDistance: sportDistance ?? this.sportDistance,
      hyperDistance: hyperDistance ?? this.hyperDistance,
      isCharging: isCharging ?? this.isCharging,
      chargingState: chargingState ?? this.chargingState,
      minutesToFull: minutesToFull ?? this.minutesToFull,
      minutesTo80: minutesTo80 ?? this.minutesTo80,
      safeToUnplug: safeToUnplug ?? this.safeToUnplug,
      chargeStartTime: chargeStartTime ?? this.chargeStartTime,
      chargeLimit: chargeLimit ?? this.chargeLimit,
      reverse: reverse ?? this.reverse,
      parkAssist: parkAssist ?? this.parkAssist,
      unplugToRideWarning: unplugToRideWarning ?? this.unplugToRideWarning,
      lockFailedWarning: lockFailedWarning ?? this.lockFailedWarning,
      unlockFailedWarning: unlockFailedWarning ?? this.unlockFailedWarning,
      rangeEco: rangeEco ?? this.rangeEco,
      rangeNormal: rangeNormal ?? this.rangeNormal,
      rangeSport: rangeSport ?? this.rangeSport,
      rangeHyper: rangeHyper ?? this.rangeHyper,
      isHyperCharger: isHyperCharger ?? this.isHyperCharger,
      isBoostCharger: isBoostCharger ?? this.isBoostCharger,
      chargeMode: chargeMode ?? this.chargeMode,
      btConnected: btConnected ?? this.btConnected,
      mediaPlaying: mediaPlaying ?? this.mediaPlaying,
      songTitle: songTitle ?? this.songTitle,
      songArtist: songArtist ?? this.songArtist,
      callActive: callActive ?? this.callActive,
      callerName: callerName ?? this.callerName,
      callerNumber: callerNumber ?? this.callerNumber,
      albumArt: albumArt ?? this.albumArt,
      mediaPosition: mediaPosition ?? this.mediaPosition,
      mediaDuration: mediaDuration ?? this.mediaDuration,
      volume: volume ?? this.volume,
      musicOnSpeaker: musicOnSpeaker ?? this.musicOnSpeaker,
      callIncoming: callIncoming ?? this.callIncoming,
      callMuted: callMuted ?? this.callMuted,
      callDuration: callDuration ?? this.callDuration,
      btDeviceName: btDeviceName ?? this.btDeviceName,
      btBondedDevices: btBondedDevices ?? this.btBondedDevices,
      profileUserName: profileUserName ?? this.profileUserName,
      vehicleType: vehicleType ?? this.vehicleType,
      scooterBtName: scooterBtName ?? this.scooterBtName,
      signalBars: signalBars ?? this.signalBars,
      wifiConnected: wifiConnected ?? this.wifiConnected,
      gpsFix: gpsFix ?? this.gpsFix,
      hasNotification: hasNotification ?? this.hasNotification,
      hhmisConnected: hhmisConnected ?? this.hhmisConnected,
      navActive: navActive ?? this.navActive,
      nextTurnDirection: nextTurnDirection ?? this.nextTurnDirection,
      distanceToTurn: distanceToTurn ?? this.distanceToTurn,
      btPairingCode: btPairingCode ?? this.btPairingCode,
      hyperMinutesToFull: hyperMinutesToFull ?? this.hyperMinutesToFull,
      hyperMinutesTo80: hyperMinutesTo80 ?? this.hyperMinutesTo80,
      boostMinutesTo80: boostMinutesTo80 ?? this.boostMinutesTo80,
      chargeSubstate: chargeSubstate ?? this.chargeSubstate,
      batteryMinTemp: batteryMinTemp != null ? batteryMinTemp() : this.batteryMinTemp,
      batteryMaxTemp: batteryMaxTemp != null ? batteryMaxTemp() : this.batteryMaxTemp,
      fcChargeIdle: fcChargeIdle ?? this.fcChargeIdle,
      regenNotification: regenNotification ?? this.regenNotification,
      vehicleBrightness: vehicleBrightness != null ? vehicleBrightness() : this.vehicleBrightness,
      rideEfficiency: rideEfficiency ?? this.rideEfficiency,
      energyUsed: energyUsed ?? this.energyUsed,
      navTotalDistance: navTotalDistance ?? this.navTotalDistance,
      navTotalTime: navTotalTime ?? this.navTotalTime,
      hintBrakeToStart: hintBrakeToStart ?? this.hintBrakeToStart,
      hintStandToRide: hintStandToRide ?? this.hintStandToRide,
      hintModeInPark: hintModeInPark ?? this.hintModeInPark,
      cruiseSetSpeed: cruiseSetSpeed ?? this.cruiseSetSpeed,
      rejectCallAllowed: rejectCallAllowed ?? this.rejectCallAllowed,
      rejectCallText: rejectCallText ?? this.rejectCallText,
      messageSentPopup: messageSentPopup ?? this.messageSentPopup,
      customerSupportNumber: customerSupportNumber ?? this.customerSupportNumber,
      batteryHealthGood: batteryHealthGood ?? this.batteryHealthGood,
      batteryHealthKnown: batteryHealthKnown ?? this.batteryHealthKnown,
      batterySohDescription: batterySohDescription ?? this.batterySohDescription,
      moveOsVersion: moveOsVersion ?? this.moveOsVersion,
      vswVersion: vswVersion ?? this.vswVersion,
      vdpVersion: vdpVersion ?? this.vdpVersion,
      hmiVersion: hmiVersion ?? this.hmiVersion,
      bcmVersion: bcmVersion ?? this.bcmVersion,
      bmsVersion: bmsVersion ?? this.bmsVersion,
      mcuVersion: mcuVersion ?? this.mcuVersion,
      hbcVersion: hbcVersion ?? this.hbcVersion,
      huVersion: huVersion ?? this.huVersion,
      bleVersion: bleVersion ?? this.bleVersion,
      vin: vin ?? this.vin,
      iccid: iccid ?? this.iccid,
      wifiMac: wifiMac ?? this.wifiMac,
      ipAddress: ipAddress ?? this.ipAddress,
      btMac: btMac ?? this.btMac,
      rawBatterySoc: rawBatterySoc ?? this.rawBatterySoc,
      ambientBrightness: ambientBrightness ?? this.ambientBrightness,
      ambientKnown: ambientKnown ?? this.ambientKnown,
      ambientUsable: ambientUsable ?? this.ambientUsable,
      serviceIndicator: serviceIndicator ?? this.serviceIndicator,
      busVoltage: busVoltage ?? this.busVoltage,
      packVoltage: packVoltage ?? this.packVoltage,
      packCurrent: packCurrent ?? this.packCurrent,
      regenPowerLimitW: regenPowerLimitW ?? this.regenPowerLimitW,
      dischargePowerLimitW: dischargePowerLimitW ?? this.dischargePowerLimitW,
      peaks: peaks ?? this.peaks,
      customRide: customRide ?? this.customRide,
      customRideActive: customRideActive ?? this.customRideActive,
      rangeEcoCan: rangeEcoCan ?? this.rangeEcoCan,
      regenAvailability: regenAvailability ?? this.regenAvailability,
      regenAvailabilityKnown: regenAvailabilityKnown ?? this.regenAvailabilityKnown,
      towTheftState: towTheftState ?? this.towTheftState,
      pendingLock: pendingLock != null ? pendingLock() : this.pendingLock,
      notice: notice != null ? notice() : this.notice,
      lockFailedAtMicros: lockFailedAtMicros != null ? lockFailedAtMicros() : this.lockFailedAtMicros,
      featureMirror: featureMirror ?? this.featureMirror,
      featureAvailable: featureAvailable ?? this.featureAvailable,
      hillHoldConsent: hillHoldConsent != null ? hillHoldConsent() : this.hillHoldConsent,
      alarmSoundIndex: alarmSoundIndex != null ? alarmSoundIndex() : this.alarmSoundIndex,
      safetySensitivity: safetySensitivity != null ? safetySensitivity() : this.safetySensitivity,
      stockAutoDownload: stockAutoDownload != null ? stockAutoDownload() : this.stockAutoDownload,
      inclinationDegrees: inclinationDegrees != null ? inclinationDegrees() : this.inclinationDegrees,
      touchDisabled: touchDisabled ?? this.touchDisabled,
    );
  }

  List<Object?> get _fields => [
        speed, batterySoc, range, socSeen, rangeSeen, driveMode, modesAvailable, odometer, odometerM, tripMeter,
        turnLeft, turnRight, hazard, hhmisStale, hhmisSilent, hhmisBacked, highBeam, smartHeadlight, lowBeam, sideStand, lockState,
        trunkOpen, trunkStateKnown, time, vehicleState, limpMode, cruiseMode,
        apbActive, faultActive, faultCode, hillHoldActive, regenActive,
        regenMode, brakeWorn, tamperDetected, fallDetected, takeMeHomeLights,
        takeMeHomeLightsRemaining, autoTurnOff, positionLight,
        accidentDetected, thermalWarning, thermalRunaway, alarmActive, deratingActive, rpm, power, torque, motorTemp, batteryTemp,
        motorTempSeen, batteryTempSeen, pduTemp, pduTempSeen, mcuTemp, mcuTempSeen, thermalLimits, liveInputs,
        regenEnergy, dailyDistance, dailyTopSpeed, dailyAvgSpeed,
        ecoDistance, normalDistance, sportDistance, hyperDistance,
        isCharging, chargingState, minutesToFull, minutesTo80,
        safeToUnplug, chargeStartTime, chargeLimit, reverse, parkAssist, unplugToRideWarning,
        lockFailedWarning, unlockFailedWarning, notice,
        rangeEco, rangeNormal, rangeSport,
        rangeHyper, isHyperCharger, isBoostCharger, chargeMode, btConnected, mediaPlaying,
        songTitle, songArtist, callActive, callerName, callerNumber,
        albumArt, mediaPosition, mediaDuration, volume, musicOnSpeaker,
        callIncoming, callMuted, callDuration, btDeviceName, scooterBtName,
        btBondedDevices, profileUserName, vehicleType,
        signalBars, wifiConnected, gpsFix, hasNotification, hhmisConnected,
        navActive, nextTurnDirection, distanceToTurn,
        btPairingCode, hyperMinutesToFull, boostMinutesTo80,
        rideEfficiency, energyUsed, navTotalDistance, navTotalTime,
        hintBrakeToStart, hintStandToRide, hintModeInPark, cruiseSetSpeed, rejectCallAllowed,
        rejectCallText, messageSentPopup, customerSupportNumber,
        batteryHealthGood, batterySohDescription, moveOsVersion, vswVersion, vdpVersion, hmiVersion,
        bcmVersion, bmsVersion, mcuVersion, hbcVersion, huVersion, bleVersion, vin, iccid,
        wifiMac, ipAddress, btMac, rawBatterySoc,
        ambientBrightness, ambientKnown, ambientUsable, serviceIndicator, busVoltage, packVoltage, packCurrent,
        regenPowerLimitW, dischargePowerLimitW, peaks, rangeEcoCan, regenAvailability, regenAvailabilityKnown, towTheftState,
        pendingLock, lockFailedAtMicros,
        // These were missing from equality once, so a
        // copyWith that changed only one of them compared equal to the
        // original and the widget tree skipped the rebuild.
        batteryHealthKnown,
        batteryMaxTemp, batteryMinTemp, chargeSubstate, fcChargeIdle,
        featureMirror, featureAvailable, hillHoldConsent, alarmSoundIndex, safetySensitivity, stockAutoDownload, inclinationDegrees,
        hyperMinutesTo80, regenNotification, touchDisabled,
        vehicleBrightness, customRide, customRideActive,
      ];

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! VehicleData) return false;
    final a = _fields, b = other._fields;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_fields);
}
