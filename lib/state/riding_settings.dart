import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vehicle_data.dart';
import '../providers/mock_provider.dart';
import '../services/prefs_service.dart';
import 'passcode_gate.dart';
import 'riding_lockout.dart';
import 'toast_state.dart';
import '../services/analytics_logger.dart';
import 'package:flutter/foundation.dart';
import 'scooter_capabilities.dart';

enum RidingFeature {
  adaptivePowerBoost('Adaptive Power Boost', 'Adaptive Power Boost', true),
  hillHold('Hill hold assist', 'Hill hold', false),
  fallDetection('Fall detection', 'Fall detection', true),
  tamper('Tow/tamper detection', 'Tamper detection', true),
  proximityUnlock('Proximity unlock', 'Proximity unlock', false),
  smartHeadlight('Smart headlight', 'Smart headlight', true),
  smartDrl('Smart DRL', 'Smart DRL', true),
  autoHeadlight('Auto headlight', 'Auto headlight', true),
  autoTurnOff('Auto turn-off', 'Auto turn-off', true),
  motorCutOff('Motor cut-off', 'Motor cut-off', true),
  sideStandCutOff('Side stand sensor', 'Side stand sensor', true),
  vacationMode('Vacation mode', 'Vacation mode', false),
  predictedRange('True Range', 'True Range', true),
  takeMeHome('Take-me-home lights', 'Take-me-home lights', true),
  autoBrightness('Auto brightness', 'Auto brightness', true);

  const RidingFeature(this.label, this.toastName, this._defaultOn);
  final String label;
  final String toastName;
  final bool _defaultOn;

  /// Tests: defaults to use in place of the shipped ones. The suite pins
  /// auto brightness off so brightness stays where a test puts it.
  @visibleForTesting
  static Map<RidingFeature, bool> debugDefaults = const {};

  bool get defaultOn => debugDefaults[this] ?? _defaultOn;

  /// One line under the toggle saying what the feature does.
  String? get caption => switch (this) {
        adaptivePowerBoost => 'Momentary throttle boost for overtakes. Vehicle disables it on faults.',
        hillHold => "Holds the brake on slopes so you don't roll back",
        fallDetection => 'Detects a fall and triggers an alert',
        tamper => 'Alerts if the scooter is moved or tilted while locked',
        proximityUnlock => 'Unlocks automatically when your phone is nearby',
        smartHeadlight => 'Sets the headlight for day or night at local sunrise and sunset',
        smartDrl => 'Keeps the daytime running light on for visibility',
        autoHeadlight => 'Turns the headlight on automatically when riding',
        autoTurnOff => 'Turns off indicators after a set time',
        motorCutOff => 'Cuts motor power if the throttle is stuck open',
        sideStandCutOff =>
          'When disabled, the scooter ignores the side stand sensor. Enable this bypass if your stand sensor is damaged.',
        vacationMode => 'Reduces battery drain during long periods of no use',
        predictedRange => 'Learns your riding style to show a more accurate range estimate',
        takeMeHome => 'Keeps headlight on after parking for the set duration',
        autoBrightness => 'Follows the time of day, or a working light sensor',
      };
}

/// The two alarm sounds HHMIS has (`OLA_ALARM_ALERT1/2_ACTIVATE`); the
/// index is the ALARM_SOUND_ALERT value. There is no silent option.
enum AlarmSound {
  alert1('Alert 1'),
  alert2('Alert 2');

  const AlarmSound(this.label);
  final String label;
}

/// SAFETY_DETECTION_SENSITIVITY: the index is the wire value (0 sends
/// `Tow_Theft_Low_Sensitivity`, 1 `Tow_Theft_High_Sensitivity`).
enum DetectionSensitivity {
  low('Low'),
  high('High');

  const DetectionSensitivity(this.label);
  final String label;
}

class RidingSettings {
  RidingSettings({
    Map<RidingFeature, bool>? features,
    this.regenMode = RegenMode.standard,
    this.alarmSound = AlarmSound.alert1,
    this.detectionSensitivity = DetectionSensitivity.low,
    this.regenPending,
    this.hillHoldAcknowledged = false,
    this.hillHoldPrompt = false,
    this.vacationPrompt = false,
    this.speedLimitEnabled = true,
    this.speedLimit = 80,
    this.standBypassPrompt = false,
    this.standBypassIgnored = false,
    this.autoLockEnabled = false,
  }) : features = Map.unmodifiable(features ?? {for (final f in RidingFeature.values) f: f.defaultOn});

  final Map<RidingFeature, bool> features;
  final RegenMode regenMode;
  final AlarmSound alarmSound;
  final DetectionSensitivity detectionSensitivity;

  /// A regen mode sent and not yet echoed. [regenMode] only moves on the
  /// vehicle's `REGEN_SETTINGS_UPDATE`, and further picks wait for it.
  final RegenMode? regenPending;

  /// When true, the SafetyWatchdog fires Lock_Now at the end of a scenario-B
  /// countdown. Default **off** on this firmware: the VCU in a device test
  /// ignored unsolicited Lock_Now, leaving the modal to dismiss
  /// without the scooter actually locking. Flip on only once the echo-waiting
  /// modal pattern is in place (wait for `BOOL_VEHICLE_ESCL_STATUS = 3`
  /// before dismissing, fall through to "Lock failed" on timeout).
  /// Hidden from Settings for the public beta, and not restored at start.
  final bool autoLockEnabled;

  /// Rider has agreed to the hill hold disclaimer. The vehicle keeps it
  /// (`INT_PERSISTED_USER_HILLHOLD_CONDITIONACCEPTED`), so it is asked once.
  final bool hillHoldAcknowledged;

  /// Disclaimer is on screen awaiting "I understand".
  final bool hillHoldPrompt;

  final bool speedLimitEnabled;

  /// km/h, 30-120.
  final int speedLimit;

  /// The side stand bypass warning is on screen awaiting "Disable".
  final bool standBypassPrompt;

  /// This scooter refused over the stand while bypassed
  /// ([PrefsKeys.standBypassIgnored]).
  final bool standBypassIgnored;

  /// The vacation mode confirmation is on screen; nothing is sent before it.
  final bool vacationPrompt;

  bool isOn(RidingFeature f) => features[f] ?? f.defaultOn;

  /// Feature toggles live under `riding_<name>`; the knobs share one blob.
  factory RidingSettings.fromPrefs() {
    final features = {
      for (final f in RidingFeature.values) f: PrefsService.getBool(PrefsKeys.ridingFeature(f.name), _legacyDefault(f)),
    };
    // A sensor "off" that the rider did not choose came from the vehicle
    // mirror this build no longer applies (`hhmis_mapping.dart`): back on.
    if (features[RidingFeature.sideStandCutOff] == false && !PrefsService.getBool(PrefsKeys.standBypassConfirmed, false)) {
      features[RidingFeature.sideStandCutOff] = true;
    }
    final base = RidingSettings(features: features, standBypassIgnored: PrefsService.getBool(PrefsKeys.standBypassIgnored, false));
    final raw = PrefsService.getString(PrefsKeys.riding, '');
    if (raw.isEmpty) return base;
    final json = _decodeMap(raw);
    if (json == null) return base;
    final alarm = AlarmSound.values.cast<AlarmSound?>().firstWhere((a) => a!.name == json['alarmSound'], orElse: () => null);
    final sensitivity = DetectionSensitivity.values
        .cast<DetectionSensitivity?>()
        .firstWhere((d) => d!.name == json['detectionSensitivity'], orElse: () => null);
    final regen = json['regenMode'];
    final legacyRegen = json['regenLevel'];
    final limitOn = json['speedLimitEnabled'];
    final limit = json['speedLimit'];
    return base.copyWith(
      regenMode: RegenMode.values.cast<RegenMode?>().firstWhere((m) => m!.name == regen,
          orElse: () => legacyRegen is int ? RegenMode.fromWire(legacyRegen) : null),
      alarmSound: alarm,
      detectionSensitivity: sensitivity,
      speedLimitEnabled: limitOn is bool ? limitOn : null,
      speedLimit: limit is int ? limit.clamp(30, 120) : null,
      // Not read back while Settings does not offer it: a rider who
      // switched it on before it was hidden must not keep it on unseen.
    );
  }

  Map<String, Object> toJson() => {
        'regenMode': regenMode.name,
        'alarmSound': alarmSound.name,
        'detectionSensitivity': detectionSensitivity.name,
        'speedLimitEnabled': speedLimitEnabled,
        'speedLimit': speedLimit,
        'autoLockEnabled': autoLockEnabled,
      };

  /// Adaptive Power Boost was saved as `riding_apb` before it was named.
  static bool _legacyDefault(RidingFeature f) => f == RidingFeature.adaptivePowerBoost
      ? PrefsService.getBool(PrefsKeys.ridingFeature('apb'), f.defaultOn)
      : f.defaultOn;

  static Map<String, Object?>? _decodeMap(String raw) {
    try {
      final v = jsonDecode(raw);
      return v is Map ? v.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

  RidingSettings copyWith({
    Map<RidingFeature, bool>? features,
    RegenMode? regenMode,
    AlarmSound? alarmSound,
    DetectionSensitivity? detectionSensitivity,
    RegenMode? Function()? regenPending,
    bool? hillHoldAcknowledged,
    bool? hillHoldPrompt,
    bool? vacationPrompt,
    bool? speedLimitEnabled,
    int? speedLimit,
    bool? standBypassPrompt,
    bool? standBypassIgnored,
    bool? autoLockEnabled,
  }) =>
      RidingSettings(
        features: features ?? this.features,
        regenMode: regenMode ?? this.regenMode,
        alarmSound: alarmSound ?? this.alarmSound,
        detectionSensitivity: detectionSensitivity ?? this.detectionSensitivity,
        regenPending: regenPending != null ? regenPending() : this.regenPending,
        hillHoldAcknowledged: hillHoldAcknowledged ?? this.hillHoldAcknowledged,
        hillHoldPrompt: hillHoldPrompt ?? this.hillHoldPrompt,
        vacationPrompt: vacationPrompt ?? this.vacationPrompt,
        speedLimitEnabled: speedLimitEnabled ?? this.speedLimitEnabled,
        speedLimit: speedLimit ?? this.speedLimit,
        standBypassPrompt: standBypassPrompt ?? this.standBypassPrompt,
        standBypassIgnored: standBypassIgnored ?? this.standBypassIgnored,
        autoLockEnabled: autoLockEnabled ?? this.autoLockEnabled,
      );
}

final ridingSettingsProvider =
    NotifierProvider<RidingSettingsNotifier, RidingSettings>(RidingSettingsNotifier.new);

class RidingSettingsNotifier extends Notifier<RidingSettings> {
  /// How long a regen pick waits for `REGEN_SETTINGS_UPDATE` before the
  /// selector unlocks again.
  static const regenEchoTimeout = Duration(seconds: 3);

  /// HHMIS plays the chosen alarm sound as a preview until told to stop;
  /// stock stops it on leaving the picker.
  static const alarmPreview = Duration(seconds: 4);

  /// Stock `SettingsInfoManager.onRidingFeatureToggleRequestCApp`: the phone
  /// app's `INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST` values. 1-3 are regen
  /// (see [companionRegen]), 22/23 hazard on/off, 14-17 have no handler.
  static const companionToggles = {
    4: (RidingFeature.adaptivePowerBoost, true),
    5: (RidingFeature.adaptivePowerBoost, false),
    6: (RidingFeature.fallDetection, true),
    7: (RidingFeature.fallDetection, false),
    8: (RidingFeature.tamper, true),
    9: (RidingFeature.tamper, false),
    10: (RidingFeature.proximityUnlock, true),
    11: (RidingFeature.proximityUnlock, false),
    12: (RidingFeature.hillHold, true),
    13: (RidingFeature.hillHold, false),
    18: (RidingFeature.smartDrl, true),
    19: (RidingFeature.smartDrl, false),
    20: (RidingFeature.autoHeadlight, true),
    21: (RidingFeature.autoHeadlight, false),
    24: (RidingFeature.autoTurnOff, true),
    25: (RidingFeature.autoTurnOff, false),
    26: (RidingFeature.motorCutOff, true),
    27: (RidingFeature.motorCutOff, false),
  };
  static const companionRegen = {1: RegenMode.standard, 2: RegenMode.city, 3: RegenMode.highway};
  static const companionHazardOn = 22;
  static const companionHazardOff = 23;

  /// How long a feature toggle waits for HHMIS's `BOOL_*_TOGGLE_STAT`.
  /// The `*_PERSIST_*` keys are no answer: HHMIS sends them at profile
  /// load only, never after a toggle.
  static const featureAckTimeout = Duration(seconds: 3);

  Timer? _regenTimer;
  Timer? _alarmPreviewTimer;
  final Map<RidingFeature, (Timer, bool)> _awaitingAck = {};

  @override
  RidingSettings build() {
    ref.onDispose(() {
      _regenTimer?.cancel();
      _alarmPreviewTimer?.cancel();
      for (final (timer, _) in _awaitingAck.values) {
        timer.cancel();
      }
    });
    onRidingLockout(ref, () {
      if (state.standBypassPrompt) state = state.copyWith(standBypassPrompt: false);
    });
    // HVSM replays the VCU's persisted regen mode on bind and echoes every
    // change (`REGEN_SETTINGS_UPDATE`). The vehicle wins over what prefs
    // remember; we mirror it into settings without sending it back, and it
    // is what answers a pending pick.
    ref.listen(vehicleProvider.select((v) => v.regenMode), (_, mode) {
      _regenTimer?.cancel();
      if (state.regenMode == mode && state.regenPending == null) return;
      state = state.copyWith(regenMode: mode, regenPending: () => null);
      _save();
    });
    // The settings HPMS keeps and HHMIS replays at profile load: vehicle
    // wins, nothing is sent back.
    ref.listen(vehicleProvider.select((v) => v.hillHoldConsent), (_, ok) {
      if (ok != null && ok != state.hillHoldAcknowledged) state = state.copyWith(hillHoldAcknowledged: ok);
    });
    ref.listen(vehicleProvider.select((v) => v.alarmSoundIndex), (_, i) {
      if (i == null || i == state.alarmSound.index) return;
      logSettingsChange('riding.alarmSound.mirror', state.alarmSound, AlarmSound.values[i]);
      state = state.copyWith(alarmSound: AlarmSound.values[i]);
      _save();
    });
    ref.listen(vehicleProvider.select((v) => v.safetySensitivity), (_, i) {
      if (i == null || i == state.detectionSensitivity.index) return;
      logSettingsChange('riding.detectionSensitivity.mirror', state.detectionSensitivity, DetectionSensitivity.values[i]);
      state = state.copyWith(detectionSensitivity: DetectionSensitivity.values[i]);
      _save();
    });
    // Each `BOOL_*_PERSIST_TOGGLE_STAT` echo mirrors the vehicle's persisted
    // feature state; vehicle wins, no re-send. Features the vehicle hasn't
    // echoed are left to whatever prefs remember.
    ref.listen(vehicleProvider.select((v) => v.featureMirror), (_, mirror) {
      for (final entry in mirror.entries) {
        final feature = RidingFeature.values
            .where((f) => f.name == entry.key)
            .firstOrNull;
        if (feature == null) continue;
        if (state.isOn(feature) == entry.value) continue;
        logSettingsChange('riding.${feature.name}.mirror', state.isOn(feature), entry.value);
        state = state.copyWith(features: {...state.features, feature: entry.value});
        PrefsService.setBool(PrefsKeys.ridingFeature(feature.name), entry.value);
        if (feature == RidingFeature.sideStandCutOff) {
          entry.value ? PrefsService.remove(PrefsKeys.standBypassConfirmed) : PrefsService.setBool(PrefsKeys.standBypassConfirmed, true);
          _bypassFromMicros = entry.value ? null : AnalyticsLogger.instance.monoMicros;
        }
      }
    });
    final settings = RidingSettings.fromPrefs();
    final vehicle = ref.read(vehicleProvider.notifier);
    vehicle.syncFeatures(settings);
    vehicle.companionRequestHandler = _companionRequest;
    vehicle.featureAckHandler = _featureAck;
    ref.listen(vehicleProvider.select((v) => v.hintStandToRide), (_, on) {
      if (on) _standRefused();
    });
    // Moving off with the stand down while bypassed: this scooter takes it.
    ref.listen(vehicleProvider.select((v) => v.sideStand && v.vehicleState.motorOn), (_, on) {
      if (!on || state.isOn(RidingFeature.sideStandCutOff) || !state.standBypassIgnored) return;
      logEvent('settings', 'stand_bypass_held', {});
      PrefsService.remove(PrefsKeys.standBypassIgnored);
      state = state.copyWith(standBypassIgnored: false);
    });
    // What HHMIS replayed before this provider was first read.
    final v = ref.read(vehicleProvider);
    final alarm = v.alarmSoundIndex, sensitivity = v.safetySensitivity;
    return settings.copyWith(
      hillHoldAcknowledged: v.hillHoldConsent,
      alarmSound: alarm == null ? null : AlarmSound.values[alarm],
      detectionSensitivity: sensitivity == null ? null : DetectionSensitivity.values[sensitivity],
    );
  }

  bool _available(String feature) => ref.read(scooterCapabilitiesProvider).fitted(feature);

  void _save() => PrefsService.setString(PrefsKeys.riding, jsonEncode(state.toJson()));

  void setFeature(RidingFeature f, bool on) {
    if (f == RidingFeature.hillHold && on && !state.hillHoldAcknowledged) {
      state = state.copyWith(hillHoldPrompt: true);
      return;
    }
    // Ignoring the stand sensor is safety-critical: passcode first, then a
    // warning the rider has to accept.
    if (f == RidingFeature.sideStandCutOff && !on && state.isOn(f)) {
      ref.read(passcodeGateProvider.notifier).request(
        purpose: 'Enter passcode to bypass the side stand sensor',
        onSuccess: () => state = state.copyWith(standBypassPrompt: true),
      );
      return;
    }
    // Stock's vacation toggle only opens a confirmation; see
    // [VehicleNotifier.enterVacationMode] for what follows it.
    if (f == RidingFeature.vacationMode && on && !state.isOn(f)) {
      state = state.copyWith(vacationPrompt: true);
      return;
    }
    _apply(f, on);
  }

  void confirmVacation() {
    state = state.copyWith(vacationPrompt: false);
    if (_apply(RidingFeature.vacationMode, true, send: false)) ref.read(vehicleProvider.notifier).enterVacationMode();
  }

  void dismissVacationPrompt() => state = state.copyWith(vacationPrompt: false);

  void confirmStandBypass() {
    state = state.copyWith(standBypassPrompt: false);
    if (_apply(RidingFeature.sideStandCutOff, false)) PrefsService.setBool(PrefsKeys.standBypassConfirmed, true);
  }

  void dismissStandBypassPrompt() => state = state.copyWith(standBypassPrompt: false);

  /// How long after the bypass a stand refusal still counts as the one in
  /// flight before it: the VCU answered a change within 1.6 s on 5.0.2.
  static const bypassSettle = Duration(seconds: 2);
  int? _bypassFromMicros;

  /// The VCU refused over the stand (59 / 160) while we say bypassed: it
  /// does not take the bypass (2026-11-27, Gen 1 on 4.6.14: `5B` on CAN,
  /// HHMIS's ack, and three refusals). The sensor goes back on, sent so
  /// the scooter stops replaying the bypass, and the rider is told.
  void _standRefused() {
    final from = _bypassFromMicros;
    if (from == null || state.isOn(RidingFeature.sideStandCutOff)) return;
    if (AnalyticsLogger.instance.monoMicros - from < bypassSettle.inMicroseconds) return;
    logEvent('settings', 'stand_bypass_ignored', {});
    PrefsService.setBool(PrefsKeys.standBypassIgnored, true);
    state = state.copyWith(standBypassIgnored: true);
    _apply(RidingFeature.sideStandCutOff, true, toast: false);
    ref.read(toastProvider.notifier).show(standBypassIgnoredMessage, type: ToastType.warning, duration: const Duration(seconds: 6));
  }

  static const standBypassIgnoredMessage = "This scooter doesn't allow the side stand bypass. Sensor back on";

  /// Dev panel: sets a feature without the passcode gate or warning.
  void forceFeature(RidingFeature f, bool on) => _apply(f, on);

  /// False when the scooter lacks the feature and nothing was switched on.
  bool _apply(RidingFeature f, bool on, {bool send = true, bool toast = true}) {
    if (on && !_available(f.name)) return false;
    logSettingsChange('riding.${f.name}', state.isOn(f), on);
    state = state.copyWith(features: {...state.features, f: on});
    PrefsService.setBool(PrefsKeys.ridingFeature(f.name), on);
    if (f == RidingFeature.sideStandCutOff) {
      if (on) PrefsService.remove(PrefsKeys.standBypassConfirmed);
      _bypassFromMicros = on ? null : AnalyticsLogger.instance.monoMicros;
    }
    final vehicle = ref.read(vehicleProvider.notifier);
    if (send) vehicle.setFeature(f, on);
    if (send && vehicle.acksFeature(f)) {
      _awaitingAck.remove(f)?.$1.cancel();
      _awaitingAck[f] = (Timer(featureAckTimeout, () => _unconfirmed(f, on, null)), on);
    }
    if (f == RidingFeature.autoHeadlight) vehicle.setAutoHeadlight(on);
    if (f == RidingFeature.smartHeadlight) vehicle.setSmartHeadlight(on);
    if (toast) ref.read(toastProvider.notifier).show('${f.toastName} ${on ? 'enabled' : 'disabled'}');
    return true;
  }

  void _featureAck(RidingFeature f, bool ok) {
    final waiting = _awaitingAck.remove(f);
    if (waiting == null) return;
    waiting.$1.cancel();
    if (!ok) _unconfirmed(f, waiting.$2, false);
  }

  /// Like the regen pick: a toggle the scooter did not take goes back to
  /// what it was. Nothing is sent; the vehicle never had the new value.
  void _unconfirmed(RidingFeature f, bool asked, bool? ack) {
    _awaitingAck.remove(f)?.$1.cancel();
    if (state.isOn(f) != asked) return;
    logEvent('settings', 'feature_unanswered', {'feature': f.name, 'asked': asked, 'ack': ack});
    state = state.copyWith(features: {...state.features, f: !asked});
    PrefsService.setBool(PrefsKeys.ridingFeature(f.name), !asked);
    if (f == RidingFeature.autoHeadlight) ref.read(vehicleProvider.notifier).setAutoHeadlight(!asked);
    ref.read(toastProvider.notifier).show('Scooter did not confirm ${f.toastName}', type: ToastType.warning);
  }

  /// Stock ACTION_HILLHOLDDISCLAIMERPOPUP_AGREE: HILL_HOLD_CONDITION_ACCEPTED
  /// first, then the toggle.
  void acknowledgeHillHold() {
    state = state.copyWith(hillHoldAcknowledged: true, hillHoldPrompt: false);
    if (!_available(RidingFeature.hillHold.name)) return;
    ref.read(vehicleProvider.notifier).acceptHillHoldTerms();
    _apply(RidingFeature.hillHold, true);
  }

  void _companionRequest(int request) {
    final regen = companionRegen[request];
    if (regen != null) return setRegenMode(regen);
    if (request == companionHazardOn || request == companionHazardOff) {
      final on = request == companionHazardOn;
      final vehicle = ref.read(vehicleProvider.notifier);
      if (vehicle.hazardOn != on && (!on || _available('hazard'))) vehicle.toggleHazard();
      return;
    }
    final toggle = companionToggles[request];
    if (toggle == null) return;
    final (feature, on) = toggle;
    // Like stock: straight to the toggle, and only when it changes something.
    if (state.isOn(feature) != on) _apply(feature, on);
  }

  void dismissHillHoldPrompt() => state = state.copyWith(hillHoldPrompt: false);

  void setAutoLockEnabled(bool on) {
    if (state.autoLockEnabled == on) return;
    state = state.copyWith(autoLockEnabled: on);
    _save();
  }

  /// Stock ACTION_REGEN_SELECT: a pick is dropped while the last one is
  /// unanswered or when it is already active, and the selector only moves
  /// on the vehicle's echo (the listener in [build]).
  void setRegenMode(RegenMode mode) {
    if (state.regenPending != null || mode == state.regenMode) return;
    if (mode != RegenMode.standard && !_available('regen')) return;
    logSettingsChange('riding.regenMode', state.regenMode, mode);
    final vehicle = ref.read(vehicleProvider.notifier);
    // The vehicle already reports this mode and prefs had drifted: an echo
    // of the same value would not be a change, so take it now.
    if (ref.read(vehicleProvider).regenMode == mode) {
      state = state.copyWith(regenMode: mode);
      _save();
      vehicle.sendRegenMode(mode);
      return;
    }
    state = state.copyWith(regenPending: () => mode);
    _regenTimer?.cancel();
    _regenTimer = Timer(regenEchoTimeout, () {
      if (state.regenPending == null) return;
      logEvent('settings', 'regen_unanswered', {'asked': mode.name});
      state = state.copyWith(regenPending: () => null);
      ref.read(toastProvider.notifier).show('Scooter did not confirm the regen mode', type: ToastType.warning);
    });
    vehicle.sendRegenMode(mode);
  }

  void setAlarmSound(AlarmSound a) {
    logSettingsChange('riding.alarmSound', state.alarmSound, a);
    state = state.copyWith(alarmSound: a);
    _save();
    final vehicle = ref.read(vehicleProvider.notifier);
    vehicle.sendAlarmSound(a.index);
    _alarmPreviewTimer?.cancel();
    _alarmPreviewTimer = Timer(alarmPreview, vehicle.stopAlarmSound);
  }

  void setDetectionSensitivity(DetectionSensitivity d) {
    if (d == state.detectionSensitivity) return;
    logSettingsChange('riding.detectionSensitivity', state.detectionSensitivity, d);
    state = state.copyWith(detectionSensitivity: d);
    _save();
    ref.read(vehicleProvider.notifier).sendSafetySensitivity(d.index);
  }

  void setSpeedLimitEnabled(bool on) {
    logSettingsChange('riding.speedLimitEnabled', state.speedLimitEnabled, on);
    state = state.copyWith(speedLimitEnabled: on);
    _save();
    ref.read(toastProvider.notifier).show('Speed limit warning ${on ? 'enabled' : 'disabled'}');
  }

  int? _speedLimitDragFrom;

  /// [commit] false while the slider is being dragged: the value follows the
  /// finger, and it is logged and saved once, on release.
  void setSpeedLimit(int kmh, {bool commit = true}) {
    final limit = kmh.clamp(30, 120);
    if (!commit) {
      _speedLimitDragFrom ??= state.speedLimit;
      state = state.copyWith(speedLimit: limit);
      return;
    }
    final from = _speedLimitDragFrom ?? state.speedLimit;
    _speedLimitDragFrom = null;
    if (from != limit) logSettingsChange('riding.speedLimit', from, limit);
    state = state.copyWith(speedLimit: limit);
    _save();
  }
}
