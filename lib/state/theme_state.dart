import 'screen_state.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:material_ui/material_ui.dart' show TimeOfDay;

import '../providers/mock_provider.dart';
import '../services/analytics_logger.dart';
import '../services/prefs_service.dart';
import '../theme/colors.dart';
import '../theme/dash_theme.dart';
import 'settings_state.dart';
import 'toast_state.dart';
import '../services/trusted_clock.dart';

/// Accent presets that read well on every built-in background.
const accentPresets = [
  Color(0xFF35D39E),
  Color(0xFF4CE0D2),
  Color(0xFF78AEFF),
  Color(0xFF6B5CE7),
  Color(0xFFD65CFF),
  Color(0xFFFF7A1A),
  Color(0xFFFF3B4E),
  Color(0xFFFFC53D),
];

/// The chosen theme, including any custom accents. Widgets should watch
/// [uiThemeProvider] instead, which eases between values.
final themeProvider = NotifierProvider<ThemeNotifier, DashTheme>(ThemeNotifier.new);

class ThemeNotifier extends Notifier<DashTheme> {
  @override
  DashTheme build() => themeFromPrefs();

  /// The built-in by saved name, with any saved accents laid over it.
  static DashTheme themeFromPrefs() {
    final name = PrefsService.getString(PrefsKeys.theme, DashTheme.light.name);
    var theme = DashTheme.builtIn.cast<DashTheme?>().firstWhere((t) => t!.name == name, orElse: () => null) ?? DashTheme.light;
    final raw = PrefsService.getString(PrefsKeys.customAccent, '');
    if (raw.isEmpty) return theme;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return theme;
      for (final e in json.entries) {
        final mode = e.key;
        final argb = e.value;
        if (mode is String && DashTheme.accentModes.contains(mode) && argb is int) {
          theme = theme.withAccent(mode, Color(argb));
        }
      }
    } on FormatException {
      return theme;
    }
    return theme;
  }

  /// Switching themes drops any custom accents.
  void setTheme(DashTheme theme) {
    logSettingsChange('theme', state.name, theme.name);
    state = theme;
    PrefsService.setString(PrefsKeys.theme, theme.name);
    PrefsService.remove(PrefsKeys.customAccent);
    ref.read(toastProvider.notifier).show('Theme: ${theme.name}');
  }

  void setAccent(String mode, Color color) {
    logSettingsChange('theme.accent.$mode', null, color.toARGB32().toRadixString(16));
    state = state.withAccent(mode, color);
    _saveAccents();
    ref.read(toastProvider.notifier).show('$mode accent updated');
  }

  /// Only the accents that differ from the built-in are stored.
  void _saveAccents() {
    final base = DashTheme.builtIn.cast<DashTheme?>().firstWhere((t) => t!.name == state.name, orElse: () => null) ?? DashTheme.dark;
    final accents = <String, int>{
      for (final mode in DashTheme.accentModes)
        if (state.accentNamed(mode) != base.accentNamed(mode)) mode: state.accentNamed(mode).toARGB32(),
    };
    if (accents.isEmpty) {
      PrefsService.remove(PrefsKeys.customAccent);
    } else {
      PrefsService.setString(PrefsKeys.customAccent, jsonEncode(accents));
    }
  }

  /// True when the active theme is the untouched built-in.
  bool isBase(DashTheme builtIn) => state == builtIn;
}

/// The palette on screen. A scooter on the charger sits for hours, often
/// at night in a garage: the charging screen is never a white panel, so a
/// rider on a light theme gets the dark palette while it is up.
final shownThemeProvider = Provider<DashTheme>((ref) {
  final chosen = ref.watch(themeProvider);
  if (!chosen.isLight) return chosen;
  final charging = ref.watch(screenStateProvider.select((s) => s == ScreenState.charging));
  return charging ? DashTheme.dark : chosen;
});

final uiThemeProvider = NotifierProvider<UiThemeNotifier, DashTheme>(UiThemeNotifier.new);

/// Eases every colour toward [themeProvider] over 500ms on a 16ms timer,
/// so painters that cannot animate a whole palette still transition.
class UiThemeNotifier extends Notifier<DashTheme> {
  static const duration = Duration(milliseconds: 500);
  static const step = Duration(milliseconds: 16);
  Timer? _timer;

  @override
  DashTheme build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen(shownThemeProvider, (_, target) => _animateTo(target));
    final initial = ref.read(shownThemeProvider);
    DashColors.current = initial;
    return initial;
  }

  void _animateTo(DashTheme target) {
    _timer?.cancel();
    // Static token readers snap to the target when the tree rebuilds; only
    // widgets watching this provider ease between palettes.
    DashColors.current = target;
    final from = state;
    var ticks = 0;
    // Counting ticks rather than reading the wall clock keeps the easing
    // deterministic under fake timers in tests.
    _timer = Timer.periodic(step, (t) {
      ticks++;
      final x = (ticks * step.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
      final eased = 1 - (1 - x) * (1 - x);
      state = x >= 1 ? target : DashTheme.lerp(from, target, eased);
      if (x >= 1) {
        t.cancel();
        _timer = null;
      }
    });
  }
}

final autoThemeProvider = NotifierProvider<AutoThemeScheduler, bool>(AutoThemeScheduler.new);

/// Switches to Light during the auto dark mode's light hours (or when the
/// ambient sensor reads bright) and back to the last dark theme otherwise.
/// Re-evaluates on every vehicle clock tick, on every ambient reading and
/// whenever the schedule changes, but switches the theme only when its
/// decision changes: a theme the rider picks holds until the next sunrise
/// or sunset, as automatic appearance does on phones. A change to the auto
/// setting itself applies at once. State is "currently light".
class AutoThemeScheduler extends Notifier<bool> {
  DashTheme _lastDark = DashTheme.dark;
  bool? _decided;

  /// When the saved decision was made, until the first evaluation after a
  /// start has checked it: a sunrise or sunset that passed while the
  /// scooter was off makes it stale.
  DateTime? _decidedAt;

  /// Test hook so time-based evaluation doesn't depend on the
  /// wall clock. Pin a specific moment and the suite stays deterministic.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  @override
  bool build() {
    final current = ref.read(themeProvider);
    final lastDarkName = PrefsService.getString(PrefsKeys.themeLastDark, '');
    _lastDark = DashTheme.builtIn.cast<DashTheme?>().firstWhere((t) => t!.name == lastDarkName && !t.isLight, orElse: () => null) ??
        DashTheme.dark;
    if (!current.isLight) {
      _lastDark = current;
      PrefsService.setString(PrefsKeys.themeLastDark, current.name);
    }
    final saved = PrefsService.getString(PrefsKeys.autoThemeDecision, '').split('|');
    final savedAt = saved.length == 2 ? int.tryParse(saved[1]) : null;
    if (savedAt != null && (saved[0] == 'light' || saved[0] == 'dark')) {
      _decided = saved[0] == 'light';
      _decidedAt = DateTime.fromMillisecondsSinceEpoch(savedAt);
    }
    ref.listen(themeProvider, (_, t) {
      if (t.isLight) return;
      _lastDark = t;
      PrefsService.setString(PrefsKeys.themeLastDark, t.name);
    });
    ref.listen(autoDarkModeProvider, (_, _) => _evaluate(force: true));
    ref.listen(vehicleProvider.select((v) => v.time), (_, _) => _evaluate());
    ref.listen(vehicleProvider.select((v) => v.ambientReading), (_, _) => _evaluate());
    // Once at start: otherwise a boot at night shows Light until the
    // minute turns over.
    Future.microtask(() {
      if (ref.mounted) _evaluate();
    });
    return false;
  }

  static bool isLightHours(TimeOfDay now, AutoDarkMode mode) {
    final n = now.hour * 60 + now.minute;
    final light = mode.lightAfter.hour * 60 + mode.lightAfter.minute;
    final dark = mode.darkAfter.hour * 60 + mode.darkAfter.minute;
    return light <= dark ? (n >= light && n < dark) : (n >= light || n < dark);
  }

  void _evaluate({bool force = false}) {
    if (force) _decided = null;
    final mode = ref.read(autoDarkModeProvider);
    if (mode.mode == AutoThemeMode.off) return;
    // The sensor mode goes by the light reading only on a scooter whose
    // sensor has proven itself (`VehicleData.ambientReading`). On a Gen 1
    // on 4.6.14 the value is the screen brightness echoed back: it once
    // fell 60 to 34 with the dusk dimming, never crossed the
    // dark threshold, and the dash was still Light 20 minutes after
    // sunset. Without a reading the schedule decides.
    final light = mode.mode == AutoThemeMode.ambientSensor ? ref.read(vehicleProvider).ambientReading : null;
    if (light != null) {
      evaluateAmbient(light);
      return;
    }
    // A clock that cannot be right (cold boot, no network: 19:17 on a
    // 2024 date in the middle of the afternoon) decides nothing; the theme stays
    // as it was. The clock string changes when the time arrives, which
    // brings the evaluation back here.
    if (!TrustedClock.trusted) return;
    final t = clock();
    final since = _decidedAt;
    if (since != null) {
      _decidedAt = null;
      if (switchedBetween(since, t, mode)) _decided = null;
    }
    _apply(isLightHours(TimeOfDay(hour: t.hour, minute: t.minute), mode));
  }

  /// Whether a light or dark switch time of [mode] falls after [from] and
  /// no later than [to].
  static bool switchedBetween(DateTime from, DateTime to, AutoDarkMode mode) {
    if (!to.isAfter(from)) return false;
    if (to.difference(from) >= const Duration(days: 1)) return true;
    for (final b in [mode.lightAfter, mode.darkAfter]) {
      var at = DateTime(from.year, from.month, from.day, b.hour, b.minute);
      if (!at.isAfter(from)) at = at.add(const Duration(days: 1));
      if (!at.isAfter(to)) return true;
    }
    return false;
  }

  /// Time-based pass. Public for tests and the dev panel.
  void evaluate(TimeOfDay now) {
    final mode = ref.read(autoDarkModeProvider);
    if (mode.mode != AutoThemeMode.timeBased) return;
    _apply(isLightHours(now, mode));
  }

  /// Ambient pass with hysteresis: bright above the light threshold, dark
  /// below the dark threshold, unchanged in between.
  void evaluateAmbient(int ambient) {
    final mode = ref.read(autoDarkModeProvider);
    if (mode.mode != AutoThemeMode.ambientSensor || ref.read(vehicleProvider).ambientReading == null) return;
    final String decision;
    if (ambient > mode.ambientLightThreshold) {
      decision = 'light';
      _apply(true);
    } else if (ambient < mode.ambientDarkThreshold) {
      decision = 'dark';
      _apply(false);
    } else {
      decision = 'hysteresis';
    }
    // Diagnostic: the ambient sensor on this hardware was observed reporting
    // 100 in dim indoor conditions. Log the value + thresholds
    // + decision so we can verify what's actually triggering theme flips.
    logEvent('safety', 'auto_theme_eval', {
      'ambient': ambient,
      'light_threshold': mode.ambientLightThreshold,
      'dark_threshold': mode.ambientDarkThreshold,
      'decision': decision,
    });
  }

  void _apply(bool light) {
    state = light;
    if (_decided == light) return;
    _decided = light;
    PrefsService.setString(PrefsKeys.autoThemeDecision, '${light ? 'light' : 'dark'}|${clock().millisecondsSinceEpoch}');
    final current = ref.read(themeProvider);
    if (light && !current.isLight) {
      ref.read(themeProvider.notifier).setTheme(DashTheme.light);
    } else if (!light && current.isLight) {
      ref.read(themeProvider.notifier).setTheme(_lastDark);
    }
  }
}

/// Ambient 0 (dark) reads at 30 so the cluster stays legible; 100 (sun)
/// is full brightness.
int autoScreenBrightness(int ambient) => (ambient * 0.7 + 30).round().clamp(30, 100);

/// Quick-adjust presets for the control panel's brightness button.
const brightnessPresets = [30, 60, 100];

/// Low / Medium / High for the presets; anything else shows as a percent.
String brightnessLabel(int level) => switch (level) {
      30 => 'Low',
      60 => 'Medium',
      100 => 'High',
      _ => '$level%',
    };

int nextBrightnessPreset(int current) {
  for (final p in brightnessPresets) {
    if (p > current) return p;
  }
  return brightnessPresets.first;
}
