import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mock_provider.dart';
import '../services/analytics_logger.dart';
import '../services/prefs_service.dart';
import '../services/trusted_clock.dart';
import 'riding_settings.dart';
import 'settings_state.dart';
import 'sun_times.dart';
import 'theme_state.dart';

class AutoBrightnessState {
  const AutoBrightnessState({required this.day, required this.night, this.boost});

  /// The rider's usual brightness by day and by night.
  final int day;
  final int night;

  /// A level tapped on the control panel; holds until the scooter is
  /// locked, then the usual level comes back.
  final int? boost;

  AutoBrightnessState copyWith({int? day, int? night, int? Function()? boost}) => AutoBrightnessState(
        day: day ?? this.day,
        night: night ?? this.night,
        boost: boost != null ? boost() : this.boost,
      );
}

final autoBrightnessProvider =
    NotifierProvider<AutoBrightness, AutoBrightnessState>(AutoBrightness.new);

/// Auto brightness. A light sensor that has proven itself on this scooter
/// (`VehicleData.ambientReading`) sets the level; otherwise the time of day
/// does: the rider's night level from sunset, and by day a level that
/// follows the sun, from half way to their day level in the morning up to
/// all of it at midday and back, eased across the hour around sunrise and
/// the hour before sunset. (It
/// used to ease across sunset: six minutes after it, auto was once still
/// at 42 and the rider put it on Low.) The settings
/// slider teaches the level for the period it is moved in; the control
/// panel button is a boost for this outing.
class AutoBrightness extends Notifier<AutoBrightnessState> {
  /// The level for the middle of the day, when the sun is highest. It was
  /// 60 all day, which left the screen readable but dim in late-morning sun;
  /// it builds up towards noon rather than sit at full all day.
  static const defaultDay = 90;
  static const defaultNight = 30;
  static const ramp = Duration(minutes: 30);

  /// Time of day for the day/night decision; tests pin it.
  static DateTime Function() clock = DateTime.now;

  /// Taps on the button since the boost began; the fourth returns to auto.
  int _boostTaps = 0;

  @override
  AutoBrightnessState build() {
    ref.listen(vehicleProvider.select((v) => (v.time, v.ambientReading)), (_, _) => apply());
    ref.listen(vehicleProvider.select((v) => v.locked), (_, locked) {
      if (locked) endBoost('lock');
    });
    ref.listen(ridingSettingsProvider.select((r) => r.isOn(RidingFeature.autoBrightness)), (_, on) {
      if (on) {
        apply();
      } else {
        endBoost('auto_off');
      }
    });
    ref.listen(sunTimesProvider, (_, _) => apply());
    Future.microtask(() {
      if (ref.mounted) apply();
    });
    return AutoBrightnessState(
      day: PrefsService.getInt(PrefsKeys.autoBrightnessDay, defaultDay).clamp(0, 100),
      night: PrefsService.getInt(PrefsKeys.autoBrightnessNight, defaultNight).clamp(0, 100),
    );
  }

  bool get _on => ref.read(ridingSettingsProvider).isOn(RidingFeature.autoBrightness);

  /// How much of the day level applies at [now]: 0 at night, 1 by day,
  /// in between across the hour around sunrise and the hour that ends at
  /// sunset.
  static double dayWeight(DateTime now, SunTimes sun) {
    final minute = now.hour * 60 + now.minute;
    final rise = sun.known ? sun.sunrise!.hour * 60 + sun.sunrise!.minute : SunTimes.fallbackSunriseHour * 60;
    final set = sun.known ? sun.sunset!.hour * 60 + sun.sunset!.minute : SunTimes.fallbackSunsetHour * 60;
    final half = ramp.inMinutes;
    if (minute <= rise - half || minute >= set) return 0;
    if (minute < rise + half) return (minute - (rise - half)) / (2 * half);
    if (minute <= set - 2 * half) return 1;
    return 1 - (minute - (set - 2 * half)) / (2 * half);
  }

  /// How high the sun is at [now]: 0 at sunrise and sunset, 1 half way
  /// between them.
  static double sunHeight(DateTime now, SunTimes sun) {
    final minute = now.hour * 60 + now.minute;
    final rise = sun.known ? sun.sunrise!.hour * 60 + sun.sunrise!.minute : SunTimes.fallbackSunriseHour * 60;
    final set = sun.known ? sun.sunset!.hour * 60 + sun.sunset!.minute : SunTimes.fallbackSunsetHour * 60;
    if (set <= rise) return 1;
    return math.sin(math.pi * ((minute - rise) / (set - rise)).clamp(0.0, 1.0));
  }

  /// How far from the night level to the day level the screen is at [now]:
  /// half way once it is day, the rest following the sun up to midday and
  /// back down.
  static double levelWeight(DateTime now, SunTimes sun) => dayWeight(now, sun) * (0.5 + 0.5 * sunHeight(now, sun));

  static int timeLevel(DateTime now, SunTimes sun, {required int day, required int night}) =>
      (night + (day - night) * levelWeight(now, sun)).round();

  /// What auto brightness wants right now; null when it has nothing to go
  /// by (no proven sensor and a clock that cannot be right).
  int? target() {
    final light = ref.read(vehicleProvider).ambientReading;
    if (light != null) return autoScreenBrightness(light);
    if (!TrustedClock.trusted) return null;
    return timeLevel(clock(), ref.read(sunTimesProvider), day: state.day, night: state.night);
  }

  /// Puts the screen at the level auto brightness wants: the boost while
  /// one is held, otherwise [target]. Nothing with auto off.
  void apply() {
    if (!_on) return;
    final level = state.boost ?? target();
    if (level == null || level == ref.read(brightnessProvider)) return;
    ref.read(brightnessProvider.notifier).set(level, persist: false);
  }

  /// The settings slider was let go at [level]: with auto on and no light
  /// sensor, that is the rider's level for this part of the day.
  void learn(int level) {
    if (!_on || ref.read(vehicleProvider).ambientReading != null || !TrustedClock.trusted) return;
    final sun = ref.read(sunTimesProvider);
    final night = dayWeight(clock(), sun) < 0.5;
    final set = level.clamp(0, 100);
    // By day the slider sets the level for now, and the midday level is
    // worked back from it, so the screen stays where it was put. A level
    // that would need a midday above 100 is held as a boost instead.
    final midday = night ? set : (state.night + (set - state.night) / levelWeight(clock(), sun)).round();
    final next = midday.clamp(0, 100);
    logSettingsChange(night ? 'brightness.night_level' : 'brightness.day_level', night ? state.night : state.day, next);
    PrefsService.setInt(night ? PrefsKeys.autoBrightnessNight : PrefsKeys.autoBrightnessDay, next);
    _boostTaps = 0;
    state = night
        ? state.copyWith(night: next, boost: () => null)
        : state.copyWith(day: next, boost: () => midday > 100 ? set : null);
    apply();
  }

  /// A tap on the control panel button with auto on: the next preset, held
  /// until lock. After the three presets the next tap goes back to auto.
  /// Returns the level now showing, or null when it returned to auto.
  int? boostTap() {
    if (_boostTaps >= brightnessPresets.length) {
      endBoost('cycle');
      return null;
    }
    _boostTaps++;
    final level = nextBrightnessPreset(ref.read(brightnessProvider));
    logEvent('ui', 'brightness_boost', {'on': true, 'level': level});
    state = state.copyWith(boost: () => level);
    ref.read(brightnessProvider.notifier).set(level, persist: false);
    return level;
  }

  void endBoost(String reason) {
    _boostTaps = 0;
    if (state.boost == null) return;
    logEvent('ui', 'brightness_boost', {'on': false, 'reason': reason});
    state = state.copyWith(boost: () => null);
    apply();
  }
}
