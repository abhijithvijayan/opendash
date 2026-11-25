import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/scooter_model.dart';
import '../models/vehicle_data.dart';
import '../models/connection_health.dart';
import '../services/analytics_logger.dart';
import '../services/prefs_service.dart';
import '../services/scooter_survey.dart';
import '../state/firmware_state.dart';
import '../state/format_settings.dart';
import '../state/riding_settings.dart';
import '../state/toast_state.dart';
import 'vehicle_provider.dart';
import '../services/trusted_clock.dart';

/// Real vehicle data only on the head unit. Chrome, desktop and tests get
/// the mock; `--dart-define=OPENDASH_MOCK=true` forces it on a device too.
bool get useAidlVehicle {
  if (debugUseAidlVehicle != null) return debugUseAidlVehicle!;
  if (kIsWeb || const bool.fromEnvironment('OPENDASH_MOCK')) return false;
  return Platform.isAndroid;
}

/// Tests set this to render the head unit's variant of a screen; they
/// override [vehicleProvider] with an `AidlVehicleNotifier` themselves.
@visibleForTesting
bool? debugUseAidlVehicle;

final vehicleProvider = NotifierProvider<VehicleNotifier, VehicleData>(
  useAidlVehicle ? AidlVehicleNotifier.new : VehicleNotifier.new,
);

/// Mock data source, and the base class of the AIDL bridge: every
/// user-facing command lives here so the UI compiles against one type.
class VehicleNotifier extends Notifier<VehicleData> {
  ScooterPeaks? _peaksLoaded;

  /// The highest limits, rpm and torque this scooter has reported, saved
  /// whenever one grows (each is rounded, so that is a few dozen writes in
  /// the scooter's life).
  ScooterPeaks get peaks => _peaksLoaded ??= ScooterPeaks.decode(PrefsService.getString(PrefsKeys.scooterPeaks, ''));

  /// Every state passes through here, so the peaks cannot be dropped by a
  /// state that was built from scratch.
  @override
  set state(VehicleData next) {
    final seen = peaks.seen(
      dischargeLimitW: next.dischargePowerLimitW,
      regenLimitW: next.regenPowerLimitW,
      rpm: next.rpm,
      torque: next.torque,
    );
    if (!identical(seen, _peaksLoaded)) {
      _peaksLoaded = seen;
      PrefsService.setString(PrefsKeys.scooterPeaks, seen.encode());
      logEvent('vehicle', 'peaks', {'discharge_w': seen.dischargeLimitW, 'regen_w': seen.regenLimitW, 'rpm': seen.rpm, 'torque': seen.torque});
    }
    super.state = next.peaks == seen ? next : next.copyWith(peaks: seen);
  }

  /// How long a first "locked" is given to correct itself before the lock
  /// screen is shown (`SessionNotifier`). The mock says what it means at
  /// once; HHMIS does not.
  Duration get firstLockSettle => Duration.zero;

  /// A finger on the screen, for the vehicle's touch heartbeat; the mock
  /// has no vehicle to keep awake.
  void markTouched() {}

  /// Diagnostics → Connections; only the HHMIS bridge has one.
  HhmisHealth? get health => null;
  void reattachNow() {}

  /// Asks Android to log what is still connected three seconds from now
  /// (`bt.snapshot`), after the rider disconnected a phone or switched
  /// Bluetooth off. The mock has no adapter to ask.
  void btSnapshot(String reason) {}

  /// Whole-scooter restart through the vehicle; false when there is no
  /// vehicle to ask (the mock), so the caller falls back to the head unit.
  Future<bool> rebootScooter() async => false;

  Timer? _clock;
  Timer? _demo;
  final List<Timer> _boot = [];
  Timer? _callTimer;
  final Map<String, Timer> _flags = {};
  bool _limitToasted = false;
  int _track = 0;

  static const tracks = [
    ('Nightcall', 'Kavinsky'),
    ('Blinding Lights', 'The Weeknd'),
    ('Starboy', 'The Weeknd'),
    ('Get Lucky', 'Daft Punk'),
    ('Midnight City', 'M83'),
  ];
  static const mockDeviceName = "Rahul's iPhone";
  int _passcodeAttempts = maxPasscodeAttempts;
  String _passcode = defaultPasscode;

  static const defaultPasscode = '123456';
  static const maxPasscodeAttempts = 5;

  /// `remaining` of a verify the vehicle never answered: neither right nor
  /// wrong, and no attempt spent.
  static const passcodeNoAnswer = -2;

  @visibleForTesting
  String get passcode => _passcode;
  double _demoT = 0;
  double _demoSpeed = 0;
  double _demoSoc = 0;
  double _demoMotorTemp = 41;
  double _demoBatteryTemp = 33;
  double _demoEfficiency = 0;

  static const whPerKm = {
    DriveMode.eco: 30.0,
    DriveMode.normal: 42.0,
    DriveMode.sport: 55.0,
    DriveMode.hyper: 68.0,
  };

  static const kmPerPercent = {
    DriveMode.eco: 1.8,
    DriveMode.normal: 1.4,
    DriveMode.sport: 1.1,
    DriveMode.hyper: 0.9,
  };

  @override
  VehicleData build() {
    startClock();
    _startBoot();
    const soc = 82;
    return _derived(VehicleData(
      peaks: peaks,
      volume: PrefsService.getInt(PrefsKeys.volume, 50),
      batterySoc: soc,
      rawBatterySoc: soc - 0.7,
      range: _rangeFor(soc, DriveMode.normal),
      driveMode: DriveMode.normal,
      vehicleState: VehicleState.parked,
      lockState: 4,
      odometer: 12408,
      tripMeter: 128.4,
      time: _now(),
      lowBeam: false,
      rejectCallAllowed: false,
      motorTemp: 41,
      batteryTemp: 33,
      pduTemp: 48,
      pduTempSeen: true,
      mcuTemp: 39,
      mcuTempSeen: true,
      // Resting rider inputs: throttle released, MCU rail up, nothing pressed.
      liveInputs: const LiveInputs(
        throttleV: 0.82,
        mcuVoltage: 51.9,
        motorCurrent: 0,
        mcuDcCurrent: 0,
        motorFrequency: 0,
      ),
      dailyDistance: 18,
      dailyTopSpeed: 72,
      dailyAvgSpeed: 34,
      ecoDistance: 3120.5,
      normalDistance: 6804.2,
      sportDistance: 2211.9,
      hyperDistance: 271.4,
      rangeEco: 180,
      rangeNormal: 140,
      rangeSport: 110,
      rangeHyper: 90,
      minutesToFull: 100,
      minutesTo80: 55,
    ));
  }

  /// Values the BMS and VCU derive from the rest of the state: pack
  /// electricals, regen and discharge ceilings, limp range.
  static VehicleData _derived(VehicleData v) {
    final soc = v.batterySoc;
    final volts = 48 + 10.5 * soc / 100;
    // Positive into the pack, as on the scooter (0x140, FLOAT_VEHICLE_CURRENT).
    final amps = v.isCharging ? (v.isHyperCharger ? 25.0 : 9.0) : 0.0;
    return v.copyWith(
      busVoltage: double.parse(volts.toStringAsFixed(2)),
      packVoltage: double.parse(volts.toStringAsFixed(2)),
      packCurrent: amps,
      regenPowerLimitW: soc >= 95 ? 0 : 1500,
      regenAvailability: soc > 95 ? 0 : 1,
      regenAvailabilityKnown: true,
      // Pack watts: 12 kW at the pack is the 8.5 kW the power bar is drawn for.
      dischargePowerLimitW: v.motorTemp > 75 || soc < 10 ? 4500 : 12000,
      rangeEcoCan: v.rangeEco,
    );
  }

  // Mirrors of the riding settings. The settings notifier pushes them
  // here (it already listens to the vehicle, so the vehicle cannot read
  // them back without a provider cycle): once at build from prefs, then
  // on every toggle.
  bool _autoHeadlight = true;
  bool _smartHeadlight = true;

  /// Called from the settings notifier's build: fields only, no side
  /// effects, since other providers may not change during a build.
  void syncFeatures(RidingSettings s) {
    _autoHeadlight = s.isOn(RidingFeature.autoHeadlight);
    _smartHeadlight = s.isOn(RidingFeature.smartHeadlight);
  }

  void setAutoHeadlight(bool on) => _autoHeadlight = on;

  void setSmartHeadlight(bool on) {
    _smartHeadlight = on;
    _applyAmbient();
  }

  /// Dev: whether the light sensor counts as working (`AmbientHealth` on
  /// the bridge), to see the fallbacks.
  void setAmbientUsable(bool on) {
    state = state.copyWith(ambientUsable: on);
    _applyAmbient();
  }

  /// Ambient light sensor, 0-100.
  void setAmbient(int percent) {
    state = state.copyWith(ambientBrightness: percent.clamp(0, 100));
    _applyAmbient();
  }

  /// Re-applies the ambient-driven features after a new reading; the
  /// bridge calls it when CAN delivers one.
  @protected
  void applyAmbient() => _applyAmbient();

  /// On hardware the VCU owns the lamp once SMART_HEADLIGHT_TOGGLE is on
  /// and HHMIS echoes BOOL_LOW_BEAM_STATUS; the mock emulates that by
  /// writing lowBeam itself. AidlVehicleNotifier turns this off so the
  /// real lamp state is never shadowed.
  @protected
  bool get managesSmartHeadlightLocally => true;

  /// Smart headlight: low beam below 40% ambient while riding, unless auto
  /// headlight already forces it. Auto brightness is `autoBrightnessProvider`.
  void _applyAmbient() {
    // Only a reading from a sensor that works: on some scooters the value
    // is a fixed number (`VehicleData.ambientReading`).
    final ambient = state.ambientReading;
    if (ambient == null) return;
    if (managesSmartHeadlightLocally &&
        _smartHeadlight &&
        !_autoHeadlight &&
        state.vehicleState == VehicleState.riding &&
        !state.highBeam) {
      final low = ambient < smartHeadlightAmbient;
      if (low != state.lowBeam) state = state.copyWith(lowBeam: low);
    }
  }

  static const smartHeadlightAmbient = 40;

  /// Wall clock, media and take-me-home ticks. The AIDL bridge keeps these
  /// too: HHMIS carries no clock, and the head unit keeps its own time.
  @protected
  void startClock() {
    ref.onDispose(() {
      _clock?.cancel();
      _demo?.cancel();
      _callTimer?.cancel();
      for (final t in _flags.values) {
        t.cancel();
      }
      for (final t in _cooling.values) {
        t.cancel();
      }
      _cancelBoot();
    });
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => _tickClock());
    ref.listen(use24HourProvider, (_, _) => _syncClock());
  }

  @protected
  String now() => _now();

  /// What the clock positions show while the head unit's time cannot be
  /// right (`TrustedClock`).
  static const unknownClock = '--:--';

  String _now() {
    if (!TrustedClock.trusted) return unknownClock;
    final n = TrustedClock.wall();
    return formatClock(n.hour, n.minute, use24Hour: ref.read(use24HourProvider));
  }

  bool? _clockTrusted;

  /// The head unit's clock became believable, or stopped being so.
  @protected
  void onClockTrust(bool trusted) {}

  /// What was connected, for the `time.*` events: the point is to see what
  /// set the clock.
  Map<String, Object?> _clockContext() => {
        'wifi': state.wifiConnected,
        'signal_bars': state.signalBars,
        'gps_fix': state.gpsFix,
        'hhmis_up': state.hhmisConnected,
        'locked': state.locked,
      };

  @protected
  void toast(String message, [ToastType type = ToastType.info]) => _toast(message, type);

  void _tickClock() {
    _syncClock();
    tickMedia();
    tickTakeMeHome();
  }

  /// One second of the take-me-home countdown. Public so tests can drive it.
  void tickTakeMeHome() {
    if (!state.takeMeHomeLights) return;
    final left = state.takeMeHomeLightsRemaining - 1;
    state = left <= 0
        ? state.copyWith(takeMeHomeLights: false, takeMeHomeLightsRemaining: 0)
        : state.copyWith(takeMeHomeLightsRemaining: left);
  }

  void _syncClock() {
    final trusted = TrustedClock.tick(_clockContext);
    if (_clockTrusted != null && _clockTrusted != trusted) onClockTrust(trusted);
    _clockTrusted = trusted;
    final t = _now();
    if (t != state.time) state = state.copyWith(time: t);
  }

  /// One second of playback. Public so tests can drive it without timers.
  void tickMedia() {
    if (!state.mediaPlaying || state.mediaDuration <= 0) return;
    final next = state.mediaPosition + 1;
    if (next >= state.mediaDuration) {
      mediaNext();
    } else {
      state = state.copyWith(mediaPosition: next);
    }
  }

  static int _rangeFor(int soc, DriveMode mode) =>
      (soc * kmPerPercent[mode]!).round();

  /// Mirrors the real handshake: the first trunk callback lands before the
  /// service reports ready.
  void _startBoot() {
    _cancelBoot();
    _boot.addAll([
      Timer(const Duration(seconds: 1),
          () => state = state.copyWith(trunkStateKnown: true)),
      Timer(const Duration(seconds: 2),
          () => state = state.copyWith(hhmisConnected: true)),
    ]);
  }

  void _cancelBoot() {
    for (final t in _boot) {
      t.cancel();
    }
    _boot.clear();
  }

  void simulateBoot() {
    state = state.copyWith(hhmisConnected: false, trunkStateKnown: false);
    _startBoot();
  }

  /// Boot with no HHMIS answer at all, for the timeout flow.
  void dropConnection() {
    _cancelBoot();
    state = state.copyWith(hhmisConnected: false, trunkStateKnown: false);
  }

  void setConnected(bool on) {
    _cancelBoot();
    state = on
        ? state.copyWith(hhmisConnected: true, trunkStateKnown: true)
        : state.copyWith(hhmisConnected: false);
  }

  /// A parked scooter stays parked at zero speed until something moves it.
  VehicleState _stateFor(int speed, {bool? charging}) {
    if (charging ?? state.isCharging) return VehicleState.charging;
    if (speed > 0) return VehicleState.riding;
    return state.vehicleState == VehicleState.parked
        ? VehicleState.parked
        : VehicleState.ready;
  }

  void setVehicleState(VehicleState s) {
    if (state.isCharging && (s == VehicleState.ready || s == VehicleState.riding)) {
      _flash('unplug', (on) => state.copyWith(unplugToRideWarning: on), const Duration(seconds: 5));
      return;
    }
    state = _withAutoLights(state.copyWith(
      vehicleState: s,
      speed: s == VehicleState.riding ? (state.speed > 0 ? state.speed : 24) : 0,
      isCharging: s == VehicleState.charging,
      chargingState: s == VehicleState.charging
          ? ChargingState.charging
          : ChargingState.normal,
      lockState: 0,
    ));
    state = _derived(state);
  }

  /// Lights follow the vehicle state like the stock BCM: the halo comes on
  /// with the motor, the headlamp when the scooter sets off, and the
  /// headlamp goes out again when it parks. A stop (riding -> ready) keeps
  /// whatever beam was lit.
  VehicleData _withAutoLights(VehicleData next) {
    final was = state.vehicleState;
    if (next.vehicleState == was) return next;
    return switch (next.vehicleState) {
      VehicleState.riding => next.copyWith(
          positionLight: true,
          lowBeam: next.highBeam
              ? null
              : _autoHeadlight
                  ? true
                  : _smartHeadlight
                      ? next.ambientBrightness < smartHeadlightAmbient
                      : null,
        ),
      VehicleState.ready => next.copyWith(positionLight: true),
      VehicleState.parked || VehicleState.charging => next.copyWith(lowBeam: false, highBeam: false),
      _ => next,
    };
  }

  /// Phase 2 sends `lockNow` (0x54) over AIDL instead. The mock simply
  /// parks the scooter; tests drive pendingLock / lockFailedAtMicros
  /// through [debugSetPendingLock] etc. to exercise the modal states.
  void autoPark() {
    state = _withAutoLights(state.copyWith(
      vehicleState: VehicleState.parked,
      speed: 0,
      power: 0,
      lockFailedAtMicros: () => null,
    ));
  }

  void setSignalBars(int bars) =>
      state = state.copyWith(signalBars: bars.clamp(0, 4));

  void setWifi(bool on) => state = state.copyWith(wifiConnected: on);

  void setGps(bool on) => state = state.copyWith(gpsFix: on);

  void setNotification(bool on) => state = state.copyWith(hasNotification: on);

  /// Where firmware news goes. `FirmwareNotifier` sets these: it listens to
  /// this provider, so this notifier cannot read that one back. A firmware
  /// update callback; a firmware version (hardware-info index, or MoveOS);
  /// HHMIS has taken our callback (a bind, or a reattach).
  void Function(Map<Object?, Object?> notice)? onFirmwareNotice;
  void Function(String key, String value)? onFirmwareVersion;
  void Function()? onHhmisAttached;

  /// Seconds until the scooter locks itself for want of a touch, while that
  /// is close; null otherwise. The vehicle decides the lock, about a minute
  /// after the last touch it was told of; this is only the warning
  /// (`IdleLockWarning`). A plain notifier, not vehicle state: it ticks
  /// every second while it shows and nothing else needs to rebuild for it.
  final idleLockIn = ValueNotifier<int?>(null);

  /// Parked and unlocked with the side stand up for as long as a lock would
  /// have taken: the scooter does not lock itself there, and
  /// `IdleLockWarning` says so, once for each time it is left like that.
  final standUpHint = ValueNotifier<bool>(false);

  /// The last passcode got no answer from the scooter (not a wrong code).
  /// The lock screen then offers the stock dashboard; an answer of either
  /// kind clears it.
  final passcodeUnanswered = ValueNotifier<bool>(false);

  /// What about this scooter OpenDash has not been checked on, while the
  /// rider has not answered (`UncheckedScooterDialog`); null otherwise.
  final unchecked = ValueNotifier<UncheckedScooter?>(null);

  /// Which build of the stock software the scooter has; null before it is
  /// known, and always in the mock, where every command exists.
  final software = ValueNotifier<StockIdentity?>(null);

  /// The shape of this scooter's data, for the log (`survey.*`).
  final survey = ScooterSurvey(
    isText: (key) =>
        key.startsWith('_hwInfo_') && FirmwareNotifier.versionIds.contains(int.tryParse(key.substring('_hwInfo_'.length))),
  );

  /// Set while a raw recording runs (`RawRecordingNotifier`): every batch
  /// from the stock service, as it arrived.
  void Function(Map<Object?, Object?> delta)? rawBatch;
  void allowUnchecked() => unchecked.value = null;
  void dismissUnchecked() => unchecked.value = null;

  /// Dev panel: the stock auto-download setting as the vehicle would
  /// replay it (null: not seen yet).
  void setStockAutoDownload(int? value) => state = state.copyWith(stockAutoDownload: () => value);

  /// ClientCmd 53. The mock answers as HHMIS does at the next profile
  /// replay: the stored value is the one sent.
  Future<bool> sendStockAutoDownload(int value) async {
    state = state.copyWith(stockAutoDownload: () => value);
    return true;
  }

  /// ClientCmd 21, the rider's "Check now".
  Future<bool> checkFirmwareUpdate() async => true;

  /// HHMIS transaction 5: watch the firmware update callbacks.
  Future<bool> subscribeFirmware() async => true;

  void setSpeed(int speed) {
    final s = speed.clamp(0, 115);
    state = _withAutoLights(state.copyWith(
      speed: s,
      vehicleState: _stateFor(s),
      rpm: (s * 0.311).floor(),
      // Reverse stays while it moves, as on the scooter: it is left at a
      // stop, the way it was entered.
    ));
  }

  void setPower(double kw) {
    state = state.copyWith(power: kw.clamp(-4.0, 8.5));
  }

  void setBattery(int soc) {
    final s = soc.clamp(0, 100);
    state = state.copyWith(
      batterySoc: s,
      rawBatterySoc: (s - 0.7).clamp(0, 100),
      range: _rangeFor(s, state.driveMode),
      chargingState: _chargingStateFor(s),
      safeToUnplug: state.isCharging && s >= 100,
    );
    state = _derived(state);
    _checkChargeLimit();
  }

  ChargingState _chargingStateFor(int soc) {
    if (!state.isCharging) return state.chargingState;
    if (state.chargingState == ChargingState.initializing ||
        state.chargingState == ChargingState.notCharging) {
      return state.chargingState;
    }
    return soc >= 100 ? ChargingState.complete : ChargingState.charging;
  }

  void _checkChargeLimit() {
    final reached = state.isCharging && state.chargeLimit < 100 && state.batterySoc >= state.chargeLimit;
    if (reached && !_limitToasted) {
      _limitToasted = true;
      _toast('Charge limit reached (${state.chargeLimit}%)', ToastType.info);
    }
    if (!reached) _limitToasted = false;
  }

  void setChargeLimit(int percent) {
    state = state.copyWith(chargeLimit: percent.clamp(50, 100));
    _checkChargeLimit();
  }

  /// Raise a transient flag for [duration]; the alert list reads it.
  @protected
  void flash(String name, VehicleData Function(bool on) apply, Duration duration) =>
      _flash(name, apply, duration);

  void _flash(String name, VehicleData Function(bool on) apply, Duration duration) {
    _flags.remove(name)?.cancel();
    state = apply(true);
    _flags[name] = Timer(duration, () {
      _flags.remove(name);
      state = apply(false);
    });
  }

  void failLock() => _flash('lock', (on) => state.copyWith(lockFailedWarning: on), const Duration(seconds: 5));

  void failUnlock() => _flash('unlock', (on) => state.copyWith(unlockFailedWarning: on), const Duration(seconds: 5));

  void setChargerState(ChargingState cs) {
    final plugged = cs != ChargingState.normal && cs != ChargingState.low;
    if (!plugged && state.chargingState == ChargingState.charging) _toast('Charger disconnected', ToastType.info);
    state = _withAutoLights(state.copyWith(
      chargingState: cs,
      isCharging: plugged,
      speed: plugged ? 0 : null,
      vehicleState: plugged ? VehicleState.charging : VehicleState.parked,
      chargeStartTime: plugged && state.chargeStartTime.isEmpty ? _now() : (plugged ? null : ''),
      safeToUnplug: cs == ChargingState.complete,
    ));
    state = _derived(state);
    _checkChargeLimit();
  }

  void _toast(String message, ToastType type) =>
      ref.read(toastProvider.notifier).show(message, type: type);

  /// The mode ladder's tap: a parked scooter accepts the change but the
  /// motor is off, so say when it takes effect.
  void selectDriveMode(DriveMode mode) {
    if (state.speed > 0) return;
    setDriveMode(mode);
    if (state.vehicleState == VehicleState.parked) {
      _toast('Mode change applies when riding', ToastType.info);
      _flash('modeHint', (on) => state.copyWith(hintModeInPark: on), hintDuration);
    }
  }

  void setHyperCharger(bool on) => state = _derived(state.copyWith(
        isHyperCharger: on,
        isBoostCharger: on ? false : null,
        hyperMinutesTo80: on ? 25 : 0,
      ));

  void setBoostCharger(bool on) => state = _derived(state.copyWith(
        isBoostCharger: on,
        isHyperCharger: on ? false : null,
        boostMinutesTo80: on ? 40 : 0,
      ));

  void setFcChargeIdle(bool on) => state = state.copyWith(fcChargeIdle: on);

  static const mockPairingCode = '482917';

  void startPairing([String code = mockPairingCode]) => state = state.copyWith(btPairingCode: code);

  void confirmPairing() {
    if (state.btPairingCode.isEmpty) return;
    state = state.copyWith(btPairingCode: '', btConnected: true,
        btDeviceName: state.btDeviceName.isEmpty ? mockDeviceName : null);
    _toast('Pairing confirmed', ToastType.success);
  }

  void cancelPairing() {
    if (state.btPairingCode.isEmpty) return;
    state = state.copyWith(btPairingCode: '');
    _toast('Pairing cancelled', ToastType.info);
  }

  void setDriveMode(DriveMode mode) {
    state = _derived(state.copyWith(
      driveMode: mode,
      range: _rangeFor(state.batterySoc, mode),
    ));
    _toast('Drive mode: ${mode.label}', ToastType.info);
  }

  void setModesAvailable(int status) => state = state.copyWith(modesAvailable: status.clamp(0, 3));

  void setTurnLeft(bool on) =>
      state = state.copyWith(turnLeft: on, turnRight: on ? false : null);

  void setTurnRight(bool on) =>
      state = state.copyWith(turnRight: on, turnLeft: on ? false : null);

  void setHighBeam(bool on) =>
      state = state.copyWith(highBeam: on, lowBeam: !on);

  void setLowBeam(bool on) =>
      state = state.copyWith(lowBeam: on, highBeam: on ? false : null);

  @visibleForTesting
  void setSmartHeadlightMode(SmartHeadlight mode) => state = state.copyWith(smartHeadlight: mode);

  bool get hazardOn => state.hazard;

  /// A finger bouncing on a pothole must not fire a frame per tap.
  static const indicatorThrottle = Duration(milliseconds: 150);
  final _cooling = <String, Timer>{};

  /// True when [key] fired within the last [indicatorThrottle]; otherwise
  /// opens a new window.
  @protected
  bool throttled(String key, [Duration window = indicatorThrottle]) {
    if (_cooling.containsKey(key)) return true;
    _cooling[key] = Timer(window, () => _cooling.remove(key));
    return false;
  }

  void toggleLeftIndicator() {
    if (throttled('left')) return;
    final on = !state.turnLeft || hazardOn;
    state = state.copyWith(turnLeft: on, turnRight: false, hazard: false);
  }

  void toggleRightIndicator() {
    if (throttled('right')) return;
    final on = !state.turnRight || hazardOn;
    state = state.copyWith(turnRight: on, turnLeft: false, hazard: false);
  }

  void toggleHazard() {
    if (throttled('hazard')) return;
    final on = !hazardOn;
    state = state.copyWith(hazard: on, turnLeft: on, turnRight: on);
  }

  void toggleHighBeam() {
    setHighBeam(!state.highBeam);
    _toast(state.highBeam ? 'High beam on' : 'High beam off', ToastType.info);
  }

  /// Long-press on the beam button: hand the lamp back to a paused smart
  /// headlight. Only the bridge has one to pause.
  void resumeSmartHeadlight() {}

  void togglePositionLight() {
    state = state.copyWith(positionLight: !state.positionLight);
    _toast(state.positionLight ? 'Position light on' : 'Position light off', ToastType.info);
  }

  /// The one light button: a beam switch while the headlamp is lit (always
  /// the case once riding), the halo switch before that.
  void cycleLights() {
    if (state.vehicleState == VehicleState.riding || state.lowBeam || state.highBeam) {
      toggleHighBeam();
    } else {
      togglePositionLight();
    }
  }

  bool _reverseFromParked = false;

  void activateReverse() {
    if (state.speed != 0) {
      _toast('Stop to use reverse', ToastType.warning);
      return;
    }
    debugPrint('[CMD] reverse requested (0x04)');
    // On the scooter reverse is a motor-on state of its own, entered from
    // park; here it goes back to where it came from.
    final entering = !state.reverse;
    if (entering) _reverseFromParked = state.vehicleState == VehicleState.parked;
    state = state.copyWith(
      reverse: entering,
      vehicleState: entering
          ? VehicleState.ready
          : _reverseFromParked
              ? VehicleState.parked
              : null,
    );
    _toast(state.reverse ? 'Reverse mode' : 'Reverse off', ToastType.info);
  }

  /// Recovery path: opens the boot whatever the service reports, since a
  /// helmet locked inside is the one thing a broken dashboard must still
  /// give back.
  void openTrunk() {
    if (state.speed > 0) {
      _toast('Stop to open the boot', ToastType.warning);
      return;
    }
    state = state.copyWith(trunkOpen: true);
    _toast('Boot opened', ToastType.success);
  }

  void toggleTrunk() {
    if (!state.trunkStateKnown) return;
    state = state.copyWith(trunkOpen: !state.trunkOpen);
    _toast(state.trunkOpen ? 'Boot opened' : 'Boot closed', ToastType.success);
  }

  void lockScooter() {
    setLocked(true);
    _toast('Scooter locked', ToastType.success);
  }

  void setFault(bool on) => state = state.copyWith(faultActive: on);
  void setFaultCode(String code) => state = state.copyWith(faultCode: code.trim().toUpperCase());
  void setDerating(bool on) => state = state.copyWith(deratingActive: on);
  void setBrakeWorn(bool on) => state = state.copyWith(brakeWorn: on);
  void setTamper(bool on) => state = state.copyWith(tamperDetected: on, towTheftState: on ? 1 : 2);

  /// INT_VEHICLE_STATE = 1. The VCU enters ALARM from LOCK; leaving it
  /// takes the tamper, fall and accident flags down, as the mapping does.
  void setAlarm(bool on) => state = on
      ? state.copyWith(alarmActive: true, lockState: 4, speed: 0, vehicleState: VehicleState.parked)
      : state.copyWith(alarmActive: false, tamperDetected: false, fallDetected: false, accidentDetected: false);

  void setServiceIndicator(bool on) => state = state.copyWith(serviceIndicator: on);
  void setFall(bool on) => state = state.copyWith(fallDetected: on);
  void setAccident(bool on) => state = state.copyWith(accidentDetected: on);
  void setThermalWarning(bool on) => state = state.copyWith(thermalWarning: on);
  void setThermalRunaway(bool on) => state = state.copyWith(thermalRunaway: on);
  @visibleForTesting
  void setNotice(VehicleNotice? n) => state = state.copyWith(notice: () => n);
  @visibleForTesting
  void debugSetPendingLock(LockSource source) => state = state.copyWith(
        pendingLock: () => LockAttempt(sentAtMicros: 0, source: source),
        lockFailedAtMicros: () => null,
      );
  @visibleForTesting
  void debugMarkLockFailed() => state = state.copyWith(lockFailedAtMicros: () => 1);
  @visibleForTesting
  void debugClearPendingLock() => state = state.copyWith(
        pendingLock: () => null,
        lockFailedAtMicros: () => null,
      );
  void setBatteryHealth(bool good) => state = state.copyWith(
        batteryHealthGood: good,
        batteryHealthKnown: true,
        batterySohDescription: good ? '' : 'Capacity below 80% of new. Service recommended.',
      );
  void setCruise(CruiseMode mode) {
    final activating = mode == CruiseMode.active && state.cruiseMode != CruiseMode.active;
    state = state.copyWith(
      cruiseMode: mode,
      cruiseSetSpeed: activating ? state.speed : mode == CruiseMode.off ? 0 : null,
    );
  }

  static const hintDuration = Duration(seconds: 5);

  void showBrakeHint() => _flash('brakeHint', (on) => state.copyWith(hintBrakeToStart: on), hintDuration);
  void showStandHint() => _flash('standHint', (on) => state.copyWith(hintStandToRide: on), hintDuration);
  void showUnplugHint() => _flash('unplug', (on) => state.copyWith(unplugToRideWarning: on), hintDuration);
  void showModeHint() => _flash('modeHint', (on) => state.copyWith(hintModeInPark: on), hintDuration);

  void setEfficiency(double whPerKm) {
    _demoEfficiency = whPerKm;
    state = state.copyWith(rideEfficiency: whPerKm.clamp(0, 100).toDouble());
  }
  void setHillHold(bool on) => state = state.copyWith(hillHoldActive: on);
  void setApb(bool on) => state = state.copyWith(apbActive: on);
  // The telltale is driven by regenNotification. The
  // mock setter keeps regenActive in sync for existing callers; new code
  // should prefer setRegenNotification directly.
  void setRegenActive(bool on) => state = state.copyWith(regenActive: on, regenNotification: on);
  void setRegenNotification(bool on) => state = state.copyWith(regenNotification: on);
  void setRegenMode(RegenMode mode) => state = state.copyWith(regenMode: mode);

  /// AidlVehicleNotifier sends REGEN_SETTINGS_UPDATE and HVSM echoes the
  /// mode back; the mock is its own echo, since the setting only moves on one.
  void sendRegenMode(RegenMode mode) => state = state.copyWith(regenMode: mode);
  void setTakeMeHome(bool on) => state = state.copyWith(
        takeMeHomeLights: on,
        takeMeHomeLightsRemaining: on ? 45 : 0,
      );
  void setPositionLight(bool on) => state = state.copyWith(positionLight: on);
  void setAutoTurnOff(bool on) => state = state.copyWith(autoTurnOff: on);

  void setSideStand(bool down) => state = state.copyWith(sideStand: down);

  void setLimpMode(bool on) => state = state.copyWith(limpMode: on);

  /// Dev panel: a MoveOS 5 custom ride mode, as a MoveOS 5 scooter
  /// reported one.
  void setCustomRideSetUp(bool on) => state = state.copyWith(
        customRide: on
            ? const CustomRideMode(
                name: 'MyRide', enabled: true, isDefault: false, topSpeedKmh: 65, powerPercent: 40, throttle: 2, regen: 2, rangeKm: 124)
            : const CustomRideMode(),
        customRideActive: on && state.customRideActive,
      );

  void setCustomRideActive(bool on) => state = state.copyWith(customRideActive: on && state.customRide.known);

  void setTrunkOpen(bool open) => state = state.copyWith(trunkOpen: open);

  /// The bridge answers asynchronously through `onPassCodeVerify`; the mock
  /// answers in place, so callers accept either.
  FutureOr<(bool, int)> verifyPasscode(String pin) {
    if (pin == _passcode) {
      _passcodeAttempts = maxPasscodeAttempts;
      setLocked(false);
      return (true, maxPasscodeAttempts);
    }
    _passcodeAttempts -= 1;
    final remaining = _passcodeAttempts;
    if (remaining <= 0) _passcodeAttempts = maxPasscodeAttempts;
    return (false, remaining);
  }

  int get passcodeAttemptsRemaining => _passcodeAttempts;

  /// Side-effect-free check for the change-passcode flow.
  /// Null means the vehicle did not answer within
  /// the timeout; the gate must not treat that as a wrong PIN.
  FutureOr<bool?> checkPasscode(String pin) => pin == _passcode;

  /// True once the vehicle has confirmed the new passcode.
  FutureOr<bool> changePasscode(String pin) {
    _passcode = pin;
    _toast('Passcode updated', ToastType.success);
    return true;
  }

  void resetTrip() {
    state = state.copyWith(tripMeter: 0);
    _toast('Trip meter reset', ToastType.success);
  }

  void resetPasscodeAttempts() => _passcodeAttempts = maxPasscodeAttempts;

  void setLocked(bool locked) {
    state = state.copyWith(
      lockState: locked ? 4 : 0,
      speed: locked ? 0 : null,
      vehicleState: locked ? VehicleState.parked : null,
      positionLight: !locked,
      lowBeam: locked ? false : null,
      highBeam: locked ? false : null,
    );
  }

  void setCharging(bool on) {
    if (!on && state.isCharging && state.chargingState == ChargingState.charging) {
      _toast('Charger disconnected', ToastType.info);
    }
    state = _withAutoLights(state.copyWith(
      isCharging: on,
      speed: 0,
      power: on ? -3.2 : 0,
      chargingState: on
          ? (state.batterySoc >= 100 ? ChargingState.complete : ChargingState.charging)
          : ChargingState.normal,
      vehicleState: on ? VehicleState.charging : VehicleState.parked,
      safeToUnplug: on && state.batterySoc >= 100,
      chargeStartTime: on ? _now() : '',
    ));
    state = _derived(state);
    _checkChargeLimit();
  }

  void setMediaPlaying(bool on) {
    final (title, artist) = tracks[_track];
    state = state.copyWith(
      mediaPlaying: on,
      mediaPosition: on && state.songTitle.isEmpty ? 0 : null,
      btConnected: on ? true : state.btConnected,
      btDeviceName: on && state.btDeviceName.isEmpty ? mockDeviceName : null,
      songTitle: on ? title : state.songTitle,
      songArtist: on ? artist : state.songArtist,
      albumArt: on && state.albumArt.isEmpty ? 'mock://art/$_track' : null,
      mediaDuration: on ? 258 : null,
    );
  }

  void mediaPlay() {
    setMediaPlaying(true);
    _toast('Playing', ToastType.info);
  }

  void mediaPause() {
    state = state.copyWith(mediaPlaying: false);
    _toast('Paused', ToastType.info);
  }

  void _loadTrack(int index) {
    _track = index % tracks.length;
    final (title, artist) = tracks[_track];
    state = state.copyWith(songTitle: title, songArtist: artist, albumArt: 'mock://art/$_track', mediaPosition: 0, mediaDuration: 258);
    _toast(title, ToastType.info);
  }

  void mediaNext() => _loadTrack(_track + 1);

  void mediaPrev() => _loadTrack(_track - 1 + tracks.length);

  void setVolume(int level, {bool announce = true}) {
    state = state.copyWith(volume: level.clamp(0, 100));
    PrefsService.setInt(PrefsKeys.volume, state.volume);
    if (announce) announceVolume();
  }

  /// Screen brightness; the bridge forwards it to HHMIS, the mock has no
  /// screen to dim. [persist] is false for a step that is not the rider's
  /// final choice (a slider drag in progress, an auto-brightness step).
  void setBrightness(int level, {bool persist = true}) {}

  /// Engine-sound and chime levels on stock's 0-14 slider scale, and the
  /// mood id (`SoundPreset.moodId`). Only the bridge has somewhere to send
  /// them.
  void setMotorVolume(int level) {}
  void setChimeVolume(int level) {}
  void setSoundMood(int mood) {}

  /// A riding feature toggle; the bridge forwards it as a ClientCmd.
  void setFeature(RidingFeature feature, bool on) {}

  /// The rest of the riding settings that reach the vehicle; all ClientCmds
  /// on the bridge, nothing to do in the mock.
  void acceptHillHoldTerms() {}
  void sendAlarmSound(int index) {}
  void stopAlarmSound() {}
  void sendSafetySensitivity(int level) {}

  /// The accident screen's answer: ACCIDENT_RECOVERY_IAM_SAFE or
  /// ACCIDENT_RECOVERY_NEED_HELP, once. False when it did not reach the
  /// vehicle; the screen then stays for another try.
  Future<bool> accidentReply({required bool safe}) async {
    state = state.copyWith(accidentDetected: false);
    return true;
  }

  /// The alarm screen's Unlock: ALARM_UNLOCK_NOW. The mock answers as the
  /// VCU is expected to, by leaving ALARM for the passcode keypad.
  Future<bool> alarmUnlock() async {
    setAlarm(false);
    return true;
  }

  /// A tow/theft alert that never became an ALARM state has no state
  /// change to end it; Unlock takes it down here.
  void dismissTamper() => state = state.copyWith(tamperDetected: false);

  /// Vacation mode after the rider confirmed it; the bridge runs stock's
  /// hazards-off, wait, send sequence.
  void enterVacationMode() {}

  /// Set by RidingSettings: the phone app's riding-setting requests
  /// (`INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST`) are carried out there, where
  /// the feature states live.
  void Function(int request)? companionRequestHandler;

  /// Set by RidingSettings: HHMIS's answer to a feature toggle
  /// (`BOOL_*_TOGGLE_STAT`, true = handed to the vehicle).
  void Function(RidingFeature feature, bool ok)? featureAckHandler;

  /// The profile's "calls on the dashboard" value and its consent, as the
  /// vehicle replays them at unlock (null = not in this batch). Set by the
  /// Bluetooth settings notifier.
  void Function(bool? allowed, bool? consent)? phoneCallsHandler;

  /// Answers or ends a call another way when the head unit's own HFP
  /// client refused; `accept` or `end`. Set by the Bluetooth settings
  /// notifier (HSSS `callAction`).
  Future<bool> Function(String action)? callActionFallback;

  String _phonebookName = '';

  /// The caller's name from the phonebook HSSS pulled, for the call whose
  /// HFP state is [callState] (7 = over). It can arrive before or after the
  /// call itself.
  void applyCallerName(int callState, String name) {
    _phonebookName = callState == 7 ? '' : name;
    if (_phonebookName.isNotEmpty && (state.callIncoming || state.callActive)) {
      state = state.copyWith(callerName: _phonebookName);
    }
  }

  @protected
  String get phonebookName => _phonebookName;

  /// Whether a toggle of [feature] is answered through [featureAckHandler].
  bool acksFeature(RidingFeature feature) => false;

  /// Overridden on Android to release CAN ownership of regen.
  void releaseCanOwnership() {}

  /// Resend CTA_UNLOCK after an unlock
  /// failure (ESCL 2). The mock just clears the warning.
  void retryUnlock() {
    state = state.copyWith(unlockFailedWarning: false);
  }

  /// Called when the head unit reports a volume nobody here asked for
  /// (the handlebar buttons, the phone). Set by the volume popup.
  void Function()? onExternalVolume;

  void announceVolume() => _toast('Volume: ${state.volume}%', ToastType.info);

  void toggleMusicOnSpeaker() {
    state = state.copyWith(musicOnSpeaker: !state.musicOnSpeaker);
    _toast(state.musicOnSpeaker ? 'Music on speaker' : 'Music on phone', ToastType.info);
  }

  void setBtConnected(bool on, {String? name}) {
    state = on
        ? state.copyWith(
            btConnected: true,
            btDeviceName: name ?? (state.btDeviceName.isEmpty ? mockDeviceName : null),
          )
        : state.copyWith(
            btConnected: false,
            mediaPlaying: false,
            songTitle: '',
            songArtist: '',
            btDeviceName: '',
            callActive: false,
            callIncoming: false,
          );
    if (!on) _stopCallTimer();
  }

  void disconnectBt() => setBtConnected(false);

  void simulateIncomingCall({String name = 'Rahul', String number = '+91 98765 43210'}) {
    state = state.copyWith(
      callIncoming: true,
      callActive: false,
      btPairingCode: '',
      callerName: name,
      callerNumber: number,
      btConnected: true,
      btDeviceName: state.btDeviceName.isEmpty ? mockDeviceName : null,
    );
  }

  void acceptCall() {
    state = state.copyWith(callActive: true, callIncoming: false, callDuration: 0, callMuted: false);
    _startCallTimer();
    _toast('Call connected', ToastType.success);
  }

  void rejectCall() {
    state = state.copyWith(callIncoming: false, callActive: false);
    _toast('Call rejected', ToastType.info);
  }

  /// Rejects and sends [VehicleData.rejectCallText]; the BT send is Phase 2.
  void rejectCallWithMessage() {
    if (!state.rejectCallAllowed) return;
    state = state.copyWith(callIncoming: false, callActive: false);
    _flash('messageSent', (on) => state.copyWith(messageSentPopup: on), const Duration(seconds: 3));
    _toast('Message sent', ToastType.success);
  }

  void setRejectCallAllowed(bool on) => state = state.copyWith(rejectCallAllowed: on);

  /// Dev hook: empty clears the art so the note icon shows.
  void setAlbumArt(String url) => state = state.copyWith(albumArt: url);

  void endCall() {
    _stopCallTimer();
    state = state.copyWith(callActive: false, callIncoming: false, callDuration: 0, callMuted: false);
    _toast('Call ended', ToastType.info);
  }

  /// Dev shortcut that skips the ringing stage.
  void setCallActive(bool on) {
    if (on) {
      if (state.callerName.isEmpty) simulateIncomingCall();
      state = state.copyWith(callActive: true, callIncoming: false, callDuration: 0);
      _startCallTimer();
    } else {
      endCall();
    }
  }

  /// False where there is no microphone mute to drive; the call bar then
  /// leaves the button out.
  bool get callMuteSupported => true;

  void toggleCallMute() {
    state = state.copyWith(callMuted: !state.callMuted);
    _toast(state.callMuted ? 'Muted' : 'Unmuted', ToastType.info);
  }

  void _startCallTimer() {
    _callTimer?.cancel();
    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      state = state.copyWith(callDuration: state.callDuration + 1);
    });
  }

  void _stopCallTimer() {
    _callTimer?.cancel();
    _callTimer = null;
  }

  void setNavActive(bool on) {
    state = state.copyWith(
      navActive: on,
      nextTurnDirection: on ? 'Turn right onto MG Road' : '',
      distanceToTurn: on ? '400 m' : '',
      navTotalDistance: on ? '7.6 km' : '',
      navTotalTime: on ? '23 min' : '',
    );
  }

  /// Dev toggle for the trip totals on their own, to check the bar without them.
  void setNavEta(bool on) => state = state.copyWith(
        navTotalDistance: on ? '7.6 km' : '',
        navTotalTime: on ? '23 min' : '',
      );

  void setNavDirection(String direction, {String? distance}) {
    state = state.copyWith(
      navActive: true,
      nextTurnDirection: direction,
      distanceToTurn: distance ?? state.distanceToTurn,
      navTotalDistance: state.navTotalDistance.isEmpty ? '7.6 km' : null,
      navTotalTime: state.navTotalTime.isEmpty ? '23 min' : null,
    );
  }

  void dismissNav() {
    setNavActive(false);
    _toast('Navigation dismissed', ToastType.info);
  }

  bool get demoRunning => _demo != null;

  void setDemo(bool on) {
    if (on == demoRunning) return;
    if (on) {
      _demoT = 0;
      _demoSpeed = state.speed.toDouble();
      _demoSoc = state.batterySoc.toDouble();
      _demoMotorTemp = state.motorTemp.toDouble();
      _demoBatteryTemp = state.batteryTemp.toDouble();
      _demoEfficiency = state.rideEfficiency;
      _demo = Timer.periodic(
        const Duration(milliseconds: 33),
        (_) => demoTick(0.033),
      );
    } else {
      _demo?.cancel();
      _demo = null;
    }
  }

  /// One step of the scripted ride. Public so tests can drive it without timers.
  void demoTick(double dt) {
    _demoT += dt;
    final t = _demoT % 60;

    final target = switch (t) {
      < 3 => 0.0,
      < 10 => 42.0,
      < 16 => 38.0 + 4 * math.sin(t * 1.3),
      < 19 => 0.0,
      < 22 => 0.0,
      < 30 => 88.0,
      < 36 => 92.0 + 3 * math.sin(t * 0.9),
      < 42 => 0.0,
      < 46 => 0.0,
      < 52 => 28.0,
      _ => 0.0,
    };

    final mode = switch (t) {
      < 19 => DriveMode.normal,
      < 42 => DriveMode.sport,
      < 46 => DriveMode.eco,
      _ => DriveMode.eco,
    };

    final accelRate = target > _demoSpeed ? (mode == DriveMode.sport ? 14.0 : 9.0) : 22.0;
    final delta = (target - _demoSpeed).clamp(-accelRate * dt, accelRate * dt);
    _demoSpeed = (_demoSpeed + delta).clamp(0, 115);
    final accel = delta / dt;

    final drag = _demoSpeed / 115 * 2.2;
    var power = drag + accel * 0.35;
    if (accel < -0.5) power = (accel * 0.18).clamp(-4.0, 0.0);
    power = power.clamp(-4.0, 8.5);

    final turnLeft = t >= 10 && t < 14;
    final turnRight = t >= 46 && t < 49;
    final sideStand = t >= 56 && t < 59;

    final dKm = _demoSpeed / 3600 * dt;
    _demoSoc = (_demoSoc - (power > 0 ? power * dt * 0.02 : 0)).clamp(0, 100);
    final soc = _demoSoc.round();

    // Motor warms toward 65° while moving and cools back to 41° at rest;
    // the pack drifts between 33° and 37°, warmer in sport.
    final motorTarget = _demoSpeed > 1 ? 65.0 : 41.0;
    _demoMotorTemp += (motorTarget - _demoMotorTemp) * dt * (_demoSpeed > 1 ? 0.12 : 0.08);
    final batteryTarget = mode == DriveMode.sport ? 37.0 : 33.0;
    _demoBatteryTemp += (batteryTarget - _demoBatteryTemp) * dt * 0.05;
    final speedInt = _demoSpeed.round();

    // Efficiency settles on the mode's figure, a little worse under hard
    // acceleration, and only moves while the scooter does.
    if (_demoSpeed > 1) {
      final efficiencyTarget = whPerKm[mode]! + (power > 4 ? 8 : 0);
      _demoEfficiency += (efficiencyTarget - _demoEfficiency) * dt * 0.4;
    }
    final energyUsed = state.energyUsed + (power > 0 ? power * dt / 3600 : 0);

    state = _withAutoLights(state.copyWith(
      speed: speedInt,
      power: double.parse(power.toStringAsFixed(2)),
      rpm: (speedInt * 0.311).floor(),
      torque: (power * 6.8).clamp(0, 58).toDouble(),
      driveMode: mode,
      batterySoc: soc,
      rawBatterySoc: (soc - 0.7).clamp(0, 100),
      range: _rangeFor(soc, mode),
      tripMeter: state.tripMeter + dKm,
      turnLeft: turnLeft,
      turnRight: turnRight,
      sideStand: sideStand,
      vehicleState: _stateFor(speedInt),
      regenEnergy: state.regenEnergy + (power < 0 ? -power * dt / 3600 : 0),
      motorTemp: _demoMotorTemp.round(),
      batteryTemp: _demoBatteryTemp.round(),
      rideEfficiency: double.parse(_demoEfficiency.toStringAsFixed(1)),
      energyUsed: energyUsed,
    ));
    state = _derived(state);
  }

  void setMotorTemp(int c) => state = _derived(state.copyWith(motorTemp: c.clamp(0, 200)));

  void setBatteryTemp(int c) => state = state.copyWith(batteryTemp: c.clamp(0, 80));

  void setPduTemp(int c) => state = state.copyWith(pduTemp: c.clamp(0, 130), pduTempSeen: true);

  void setMcuTemp(int c) => state = state.copyWith(mcuTemp: c.clamp(0, 130), mcuTempSeen: true);
}

final demoProvider = NotifierProvider<DemoNotifier, bool>(DemoNotifier.new);

class DemoNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool on) {
    ref.read(vehicleProvider.notifier).setDemo(on);
    state = on;
  }
}
