import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mock_provider.dart';
import '../services/prefs_service.dart';
import 'apps_state.dart';
import 'crash_recovery.dart';
import 'media_state.dart';
import 'ota_state.dart';
import 'passcode_state.dart';
import 'riding_lockout.dart';
import 'riding_settings.dart';
import 'screen_state.dart';
import 'theme_state.dart';
import 'toast_state.dart';
import '../services/analytics_logger.dart';
import 'auto_brightness.dart';

enum SettingsSection {
  display('Display'),
  profile('Profile'),
  sound('Sound'),
  riding('Riding'),
  connectivity('Connectivity'),
  vehicleInfo('Vehicle Info'),
  about('About'),
  developer('Developer');

  const SettingsSection(this.label);
  final String label;
}

bool _riding(Ref ref) => ref.read(ridingLockoutProvider);

/// Shared auto-close wiring for full-screen overlays: riding (or a speed
/// that can no longer be trusted), charge/lock transitions and session
/// changes all dismiss them. Listens on vehicle selects and the lockout
/// notifier, not derived providers (see media_state.dart).
/// [onRiding] false keeps the overlay open when the scooter starts moving —
/// only Diagnostics does this, with the island standing in for the dial it
/// covers. The lock and session closes still apply.
void autoCloseOverlay(Ref ref, void Function() close, {bool onRiding = true}) {
  if (onRiding) onRidingLockout(ref, close);
  // Lock only: HHMIS's charge state flaps (seen: a regen change
  // while plugged in flipped it twice in 8 s) and each flip used to throw the
  // rider out of Settings.
  ref.listen(vehicleProvider.select((v) => v.locked), (_, locked) {
    if (locked) close();
  });
  ref.listen(sessionProvider, (_, _) => close());
}

/// Dismisses every full-screen sub-screen so a newly opened one never
/// stacks on another. Diagnostics, Updates, Bluetooth devices and Licenses
/// are reached from inside Settings and keep it mounted underneath, so
/// their back arrow returns there; Settings and Apps are top level.
/// [self] is the caller's own provider, which a notifier may not read.
void closeAllOverlays(Ref ref, {required Object self, bool keepSettings = false}) {
  if (!keepSettings && self != settingsScreenOpenProvider) ref.read(settingsScreenOpenProvider.notifier).close();
  if (self != appLauncherOpenProvider) ref.read(appLauncherOpenProvider.notifier).close();
  if (self != diagnosticsOpenProvider) ref.read(diagnosticsOpenProvider.notifier).close();
  if (self != btScreenOpenProvider) ref.read(btScreenOpenProvider.notifier).close();
  if (self != otaScreenOpenProvider) ref.read(otaScreenOpenProvider.notifier).close();
  if (self != licensesScreenOpenProvider) ref.read(licensesScreenOpenProvider.notifier).close();
}

final settingsScreenOpenProvider =
    NotifierProvider<SettingsScreenOpen, bool>(SettingsScreenOpen.new);

class SettingsScreenOpen extends Notifier<bool> {
  @override
  bool build() {
    autoCloseOverlay(ref, close);
    return false;
  }

  void open() {
    if (_riding(ref) || ref.read(vehicleProvider).locked) return;
    closeAllOverlays(ref, self: settingsScreenOpenProvider, keepSettings: true);
    state = true;
  }

  /// Visits are brief and hours apart, so the next one starts at the top.
  void close() {
    state = false;
    ref.read(settingsSectionProvider.notifier).set(SettingsSection.display);
    ref.read(changePasscodeOpenProvider.notifier).close();
  }
}

final settingsSectionProvider =
    NotifierProvider<SettingsSectionNotifier, SettingsSection>(SettingsSectionNotifier.new);

class SettingsSectionNotifier extends Notifier<SettingsSection> {
  @override
  SettingsSection build() => SettingsSection.display;
  void set(SettingsSection s) => state = s;
}

final brightnessProvider = NotifierProvider<BrightnessNotifier, int>(BrightnessNotifier.new);

/// Screen brightness 0-100. Phase 2 sends `setBrightness` over AIDL.
class BrightnessNotifier extends Notifier<int> {
  @override
  int build() => PrefsService.getInt(PrefsKeys.brightness, 80).clamp(0, 100);

  /// Mirror from HHMIS's `INT_VEHICLE_BRIGHTNESS` echo. Called by
  /// `vehicle_provider.dart` on the push path so we don't create a circular
  /// Riverpod dependency via `ref.listen(vehicleProvider)` here.
  void mirror(int level) {
    final next = level.clamp(0, 100);
    if (next == state) return;
    logSettingsChange('brightness.mirror', state, next);
    state = next;
    PrefsService.setInt(PrefsKeys.brightness, state);
    // At each unlock the vehicle replays the level saved in the rider's
    // profile. With auto brightness on that is not the level for now: the
    // night level (30) was once pushed to 60 and stayed there
    // until the next minute tick. Auto brightness takes it straight back.
    ref.read(autoBrightnessProvider.notifier).apply();
  }

  /// [persist] false is a step on the way (a drag in progress, an
  /// auto-brightness step): the screen follows, but HHMIS does not write
  /// the level to the rider's profile. Stock does the same.
  void set(int v, {bool persist = true}) {
    final next = v.clamp(0, 100);
    logSettingsChange('brightness', state, next);
    state = next;
    PrefsService.setInt(PrefsKeys.brightness, state);
    ref.read(vehicleProvider.notifier).setBrightness(state, persist: persist);
  }

  /// Low -> medium -> high -> low, announced with a toast. With auto
  /// brightness on the step is a boost for this outing: auto stays on and
  /// takes the level back at the next lock (or on the fourth tap).
  void cyclePreset() {
    if (ref.read(ridingSettingsProvider).isOn(RidingFeature.autoBrightness)) {
      final level = ref.read(autoBrightnessProvider.notifier).boostTap();
      ref.read(toastProvider.notifier).show(
          level == null ? 'Brightness: Auto' : 'Brightness: ${brightnessLabel(level)} until you lock');
      return;
    }
    final next = nextBrightnessPreset(state);
    set(next);
    ref.read(toastProvider.notifier).show('Brightness: ${brightnessLabel(next)}');
  }
}

final licensesScreenOpenProvider = NotifierProvider<LicensesScreenOpen, bool>(LicensesScreenOpen.new);

class LicensesScreenOpen extends Notifier<bool> {
  @override
  bool build() {
    autoCloseOverlay(ref, close);
    return false;
  }

  void open() {
    if (_riding(ref)) return;
    closeAllOverlays(ref, self: licensesScreenOpenProvider, keepSettings: true);
    state = true;
  }
  void close() => state = false;
}

final sohPopupOpenProvider = NotifierProvider<SohPopupOpen, bool>(SohPopupOpen.new);

class SohPopupOpen extends Notifier<bool> {
  @override
  bool build() {
    autoCloseOverlay(ref, close);
    return false;
  }

  void open() {
    if (_riding(ref)) return;
    state = true;
  }

  void close() => state = false;
}

final chargeLimitPopupProvider = NotifierProvider<ChargeLimitPopupOpen, bool>(ChargeLimitPopupOpen.new);

class ChargeLimitPopupOpen extends Notifier<bool> {
  @override
  bool build() {
    ref.listen(vehicleProvider.select((v) => v.isCharging), (_, charging) {
      if (!charging) state = false;
    });
    return false;
  }

  void open() => state = true;
  void close() => state = false;
}

enum AutoThemeMode {
  off('Off'),
  timeBased('Time-based'),
  ambientSensor('Ambient sensor');

  const AutoThemeMode(this.label);
  final String label;
}

class AutoDarkMode {
  const AutoDarkMode({
    this.mode = AutoThemeMode.timeBased,
    this.darkAfter = const TimeOfDay(hour: 18, minute: 30),
    this.lightAfter = const TimeOfDay(hour: 6, minute: 30),
    this.ambientLightThreshold = 40,
    this.ambientDarkThreshold = 25,
  });
  final AutoThemeMode mode;
  final TimeOfDay darkAfter;
  final TimeOfDay lightAfter;

  /// Light above this ambient %, dark below [ambientDarkThreshold]; the gap
  /// stops the theme flapping in dappled shade.
  final int ambientLightThreshold;
  final int ambientDarkThreshold;

  bool get enabled => mode != AutoThemeMode.off;

  AutoDarkMode copyWith({AutoThemeMode? mode, TimeOfDay? darkAfter, TimeOfDay? lightAfter}) =>
      AutoDarkMode(
        mode: mode ?? this.mode,
        darkAfter: darkAfter ?? this.darkAfter,
        lightAfter: lightAfter ?? this.lightAfter,
        ambientLightThreshold: ambientLightThreshold,
        ambientDarkThreshold: ambientDarkThreshold,
      );

  @override
  bool operator ==(Object other) =>
      other is AutoDarkMode &&
      other.mode == mode &&
      other.darkAfter == darkAfter &&
      other.lightAfter == lightAfter &&
      other.ambientLightThreshold == ambientLightThreshold &&
      other.ambientDarkThreshold == ambientDarkThreshold;

  @override
  int get hashCode => Object.hash(mode, darkAfter, lightAfter, ambientLightThreshold, ambientDarkThreshold);

  Map<String, Object> toJson() => {
        'mode': mode.name,
        'darkAfter': _hhmm(darkAfter),
        'lightAfter': _hhmm(lightAfter),
      };

  /// Anything malformed yields the default schedule. An old-format
  /// `enabled: true` reads as time-based.
  factory AutoDarkMode.fromPrefs() {
    final raw = PrefsService.getString(PrefsKeys.autoDark, '');
    if (raw.isEmpty) return const AutoDarkMode();
    try {
      return AutoDarkMode.fromJsonObject(jsonDecode(raw));
    } on FormatException {
      return const AutoDarkMode();
    }
  }

  static AutoDarkMode fromJsonObject(Object? json) {
    if (json is! Map) return const AutoDarkMode();
    final dark = parseTimeOfDay(json['darkAfter']);
    final light = parseTimeOfDay(json['lightAfter']);
    if (dark == null || light == null) return const AutoDarkMode();
    final modeName = json['mode'];
    final mode = AutoThemeMode.values.cast<AutoThemeMode?>().firstWhere((m) => m!.name == modeName, orElse: () => null) ??
        (json['enabled'] == true ? AutoThemeMode.timeBased : AutoThemeMode.off);
    return AutoDarkMode(mode: mode, darkAfter: dark, lightAfter: light);
  }
}

String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// "HH:MM" -> TimeOfDay, or null when it is not one.
TimeOfDay? parseTimeOfDay(Object? raw) {
  if (raw is! String) return null;
  final parts = raw.split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) return null;
  return TimeOfDay(hour: h, minute: m);
}

final autoDarkModeProvider =
    NotifierProvider<AutoDarkModeNotifier, AutoDarkMode>(AutoDarkModeNotifier.new);

class AutoDarkModeNotifier extends Notifier<AutoDarkMode> {
  @override
  AutoDarkMode build() => AutoDarkMode.fromPrefs();

  void _save() => PrefsService.setString(PrefsKeys.autoDark, jsonEncode(state.toJson()));

  void setEnabled(bool on) => setMode(on ? AutoThemeMode.timeBased : AutoThemeMode.off);

  void setMode(AutoThemeMode mode) {
    logSettingsChange('autoDark.mode', state.mode, mode);
    state = state.copyWith(mode: mode);
    _save();
    ref.read(toastProvider.notifier).show(mode == AutoThemeMode.off ? 'Auto dark mode disabled' : 'Auto dark mode enabled');
  }

  void setDarkAfter(TimeOfDay t) {
    logSettingsChange('autoDark.darkAfter', _hhmm(state.darkAfter), _hhmm(t));
    state = state.copyWith(darkAfter: t);
    _save();
  }

  void setLightAfter(TimeOfDay t) {
    logSettingsChange('autoDark.lightAfter', _hhmm(state.lightAfter), _hhmm(t));
    state = state.copyWith(lightAfter: t);
    _save();
  }
}

final tripResetProvider = NotifierProvider<TripResetPopup, bool>(TripResetPopup.new);

/// Trip reset confirmation. Hidden while riding.
class TripResetPopup extends Notifier<bool> {
  @override
  bool build() {
    onRidingLockout(ref, () => state = false);
    return false;
  }

  void open() {
    if (_riding(ref)) return;
    state = true;
  }

  void cancel() => state = false;

  void confirm() {
    uiTap('trip-reset');
    ref.read(vehicleProvider.notifier).resetTrip();
    state = false;
  }
}

final changePasscodeOpenProvider =
    NotifierProvider<ChangePasscodeOpen, bool>(ChangePasscodeOpen.new);

class ChangePasscodeOpen extends Notifier<bool> {
  @override
  bool build() {
    onRidingLockout(ref, () => state = false);
    return false;
  }

  void open() {
    if (_riding(ref)) return;
    ref.read(changePasscodeProvider.notifier).reset();
    state = true;
  }

  void close() => state = false;
}

enum PasscodeStep { verify, create, confirm }

enum ChangePasscodeResult { failure, mismatch, success }

class ChangePasscodeState {
  const ChangePasscodeState({
    this.step = PasscodeStep.verify,
    this.enteredDigits = const [],
    this.newPasscode = '',
    this.lastResult,
    this.failures = 0,
  });

  final PasscodeStep step;
  final List<int> enteredDigits;
  final String newPasscode;
  final ChangePasscodeResult? lastResult;
  final int failures;

  ChangePasscodeState copyWith({
    PasscodeStep? step,
    List<int>? enteredDigits,
    String? newPasscode,
    ChangePasscodeResult? Function()? lastResult,
    int? failures,
  }) =>
      ChangePasscodeState(
        step: step ?? this.step,
        enteredDigits: enteredDigits ?? this.enteredDigits,
        newPasscode: newPasscode ?? this.newPasscode,
        lastResult: lastResult != null ? lastResult() : this.lastResult,
        failures: failures ?? this.failures,
      );
}

final changePasscodeProvider =
    NotifierProvider<ChangePasscodeNotifier, ChangePasscodeState>(ChangePasscodeNotifier.new);

/// Verify current -> enter new -> confirm. Mismatch returns to "enter new".
class ChangePasscodeNotifier extends Notifier<ChangePasscodeState> {
  static const length = PasscodeNotifier.length;
  static const clearDelay = Duration(milliseconds: 500);
  Timer? _timer;

  @override
  ChangePasscodeState build() {
    ref.onDispose(() => _timer?.cancel());
    return const ChangePasscodeState();
  }

  void reset() {
    _timer?.cancel();
    state = const ChangePasscodeState();
  }

  void enterDigit(int d) {
    if (state.lastResult == ChangePasscodeResult.success) return;
    if (state.lastResult != null) _clearNow();
    if (state.enteredDigits.length >= length) return;
    final digits = [...state.enteredDigits, d];
    uiTap('passcode-digit', {'screen': 'change_passcode', 'count': digits.length});
    state = state.copyWith(enteredDigits: digits);
    if (digits.length == length) _submit(digits.join());
  }

  void deleteDigit() {
    if (state.enteredDigits.isEmpty || state.lastResult != null) return;
    state = state.copyWith(
      enteredDigits: state.enteredDigits.sublist(0, state.enteredDigits.length - 1),
    );
  }

  void _submit(String pin) {
    final vehicle = ref.read(vehicleProvider.notifier);
    switch (state.step) {
      case PasscodeStep.verify:
        final result = vehicle.checkPasscode(pin);
        if (result is Future<bool?>) {
          result.then(_applyVerify);
        } else {
          _applyVerify(result);
        }
      case PasscodeStep.create:
        state = state.copyWith(step: PasscodeStep.confirm, enteredDigits: const [], newPasscode: pin);
      case PasscodeStep.confirm:
        if (pin == state.newPasscode) {
          final result = vehicle.changePasscode(pin);
          if (result is Future<bool>) {
            result.then(_applyChange);
          } else {
            _applyChange(result);
          }
        } else {
          _fail(ChangePasscodeResult.mismatch);
        }
    }
  }

  /// Closes only once the vehicle has confirmed; a refusal or a timeout
  /// leaves the screen open to try again.
  void _applyChange(bool ok) {
    if (state.step != PasscodeStep.confirm || state.enteredDigits.length < length) return;
    if (ok) {
      state = state.copyWith(lastResult: () => ChangePasscodeResult.success);
      ref.read(changePasscodeOpenProvider.notifier).close();
    } else {
      _fail(ChangePasscodeResult.failure);
    }
  }

  void _applyVerify(bool? ok) {
    if (state.step != PasscodeStep.verify || state.enteredDigits.length < length) return;
    // Null is 'no answer', not a wrong PIN.
    if (ok == null) {
      state = state.copyWith(enteredDigits: const []);
      return;
    }
    if (ok) {
      state = state.copyWith(step: PasscodeStep.create, enteredDigits: const []);
    } else {
      _fail(ChangePasscodeResult.failure);
    }
  }

  void _fail(ChangePasscodeResult result) {
    state = state.copyWith(lastResult: () => result, failures: state.failures + 1);
    _timer?.cancel();
    _timer = Timer(clearDelay, _clearNow);
  }

  void _clearNow() {
    _timer?.cancel();
    if (state.lastResult == null || state.lastResult == ChangePasscodeResult.success) return;
    final backToCreate = state.lastResult == ChangePasscodeResult.mismatch;
    state = state.copyWith(
      step: backToCreate ? PasscodeStep.create : null,
      newPasscode: backToCreate ? '' : null,
      enteredDigits: const [],
      lastResult: () => null,
    );
  }
}
