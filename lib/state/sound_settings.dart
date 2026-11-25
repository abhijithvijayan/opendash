import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mock_provider.dart';
import '../services/prefs_service.dart';
import 'toast_state.dart';
import '../services/analytics_logger.dart';

enum SoundPreset {
  bolt('Bolt', 'Aggressive & digital', 2),
  vintage('Vintage', 'Classic motor feel', 1),
  eclipse('Eclipse', 'Futuristic & smooth', 0);

  const SoundPreset(this.label, this.tagline, this.moodId);
  final String label;
  final String tagline;

  /// Stock `Constants.Moods`, the value of ClientCmd `INT_MODE_UPDATE`.
  final int moodId;
}

/// Engine sound preset and mix. On the scooter the preset, Motor Volume and
/// Chime Volume go to HHMIS and the two volumes follow the vehicle's stored
/// levels; the rest is local (hidden there).
class SoundSettings {
  const SoundSettings({
    this.preset = SoundPreset.bolt,
    this.boltBite = 50,
    this.boltBlend = 50,
    this.vintageAge = 30,
    this.vintageSize = 60,
    this.eclipseOrbit = 50,
    this.eclipsePhase = 50,
    this.soundVolume = 70,
    this.motorVolume = 50,
    this.chimeVolume = 60,
    this.systemSound = true,
  });

  final SoundPreset preset;
  final int boltBite;
  final int boltBlend;
  final int vintageAge;
  final int vintageSize;
  final int eclipseOrbit;
  final int eclipsePhase;
  final int soundVolume;
  final int motorVolume;
  final int chimeVolume;
  final bool systemSound;

  /// (label, value) pairs for the active preset's two parameters.
  List<(String, int)> get presetParams => switch (preset) {
        SoundPreset.bolt => [('Bite', boltBite), ('Analog / Cyber', boltBlend)],
        SoundPreset.vintage => [('Age', vintageAge), ('Size', vintageSize)],
        SoundPreset.eclipse => [('Orbit', eclipseOrbit), ('Phase', eclipsePhase)],
      };

  SoundSettings copyWith({
    SoundPreset? preset,
    int? boltBite,
    int? boltBlend,
    int? vintageAge,
    int? vintageSize,
    int? eclipseOrbit,
    int? eclipsePhase,
    int? soundVolume,
    int? motorVolume,
    int? chimeVolume,
    bool? systemSound,
  }) =>
      SoundSettings(
        preset: preset ?? this.preset,
        boltBite: boltBite ?? this.boltBite,
        boltBlend: boltBlend ?? this.boltBlend,
        vintageAge: vintageAge ?? this.vintageAge,
        vintageSize: vintageSize ?? this.vintageSize,
        eclipseOrbit: eclipseOrbit ?? this.eclipseOrbit,
        eclipsePhase: eclipsePhase ?? this.eclipsePhase,
        soundVolume: soundVolume ?? this.soundVolume,
        motorVolume: motorVolume ?? this.motorVolume,
        chimeVolume: chimeVolume ?? this.chimeVolume,
        systemSound: systemSound ?? this.systemSound,
      );

  List<Object> get _f => [
        preset, boltBite, boltBlend, vintageAge, vintageSize, eclipseOrbit,
        eclipsePhase, soundVolume, motorVolume, chimeVolume, systemSound,
      ];

  @override
  bool operator ==(Object other) {
    if (other is! SoundSettings) return false;
    final a = _f, b = other._f;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_f);

  Map<String, Object> toJson() => {
        'preset': preset.name,
        'boltBite': boltBite,
        'boltBlend': boltBlend,
        'vintageAge': vintageAge,
        'vintageSize': vintageSize,
        'eclipseOrbit': eclipseOrbit,
        'eclipsePhase': eclipsePhase,
        'soundVolume': soundVolume,
        'motorVolume': motorVolume,
        'chimeVolume': chimeVolume,
        'systemSound': systemSound,
      };

  /// Field by field, so one bad value keeps the others.
  factory SoundSettings.fromPrefs() {
    const d = SoundSettings();
    final raw = PrefsService.getString(PrefsKeys.sound, '');
    if (raw.isEmpty) return d;
    Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException {
      return d;
    }
    if (json is! Map) return d;
    final map = json;
    int level(String key, int fallback) {
      final v = map[key];
      return v is int ? v.clamp(0, 100) : fallback;
    }
    final preset = SoundPreset.values.cast<SoundPreset?>().firstWhere((p) => p!.name == map['preset'], orElse: () => null);
    final system = map['systemSound'];
    return SoundSettings(
      preset: preset ?? d.preset,
      boltBite: level('boltBite', d.boltBite),
      boltBlend: level('boltBlend', d.boltBlend),
      vintageAge: level('vintageAge', d.vintageAge),
      vintageSize: level('vintageSize', d.vintageSize),
      eclipseOrbit: level('eclipseOrbit', d.eclipseOrbit),
      eclipsePhase: level('eclipsePhase', d.eclipsePhase),
      soundVolume: level('soundVolume', d.soundVolume),
      motorVolume: level('motorVolume', d.motorVolume),
      chimeVolume: level('chimeVolume', d.chimeVolume),
      systemSound: system is bool ? system : d.systemSound,
    );
  }
}

final soundSettingsProvider =
    NotifierProvider<SoundSettingsNotifier, SoundSettings>(SoundSettingsNotifier.new);

class SoundSettingsNotifier extends Notifier<SoundSettings> {
  @override
  SoundSettings build() => SoundSettings.fromPrefs();

  void _set(SoundSettings next) {
    logSettingsChange('sound', state.toJson().toString(), next.toJson().toString());
    state = next;
    PrefsService.setString(PrefsKeys.sound, jsonEncode(next.toJson()));
  }

  void setPreset(SoundPreset p) {
    _set(state.copyWith(preset: p));
    ref.read(vehicleProvider.notifier).setSoundMood(p.moodId);
  }

  /// Stock's slider scale for `updateMotorVolume` / `updateChimeVolume`;
  /// HHMIS halves it to the 0-7 stream level it stores and reports back.
  static const vehicleSteps = 14;

  static int vehicleLevel(int percent) => (percent.clamp(0, 100) * vehicleSteps / 100).round();
  static int percentOfStored(int level) => (level.clamp(0, 7) * 100 / 7).round();

  /// Stock's System Sounds slider stops here and says "System sounds
  /// cannot be set below 40%" (both builds: `SoundSettings_New`,
  /// `SystemChimeSounds/WarningContainer`). Below it the lock, unlock and
  /// indicator chimes go quiet (seen dragged to 1 on a MoveOS 5 scooter). A lower level the vehicle reports is shown as it is.
  static const chimeFloor = 40;

  /// Last level sent or reported per volume, so a drag sends one call per
  /// step of the vehicle's scale rather than one per pixel.
  int? _motorLevel;
  int? _chimeLevel;

  /// The vehicle's stored levels (HHMIS callback TX 10 / 11, 0-7). The
  /// vehicle wins and nothing is sent back.
  void mirrorVehicle({int? motorLevel, int? chimeLevel}) {
    if (motorLevel != null) _motorLevel = motorLevel.clamp(0, 7) * 2;
    if (chimeLevel != null) _chimeLevel = chimeLevel.clamp(0, 7) * 2;
    final next = state.copyWith(
      motorVolume: motorLevel == null ? null : percentOfStored(motorLevel),
      chimeVolume: chimeLevel == null ? null : percentOfStored(chimeLevel),
    );
    if (next != state) _set(next);
  }

  /// Sets the n-th parameter (0 or 1) of the active preset.
  void setPresetParam(int index, int value) {
    final v = value.clamp(0, 100);
    _set(switch ((state.preset, index)) {
      (SoundPreset.bolt, 0) => state.copyWith(boltBite: v),
      (SoundPreset.bolt, _) => state.copyWith(boltBlend: v),
      (SoundPreset.vintage, 0) => state.copyWith(vintageAge: v),
      (SoundPreset.vintage, _) => state.copyWith(vintageSize: v),
      (SoundPreset.eclipse, 0) => state.copyWith(eclipseOrbit: v),
      (SoundPreset.eclipse, _) => state.copyWith(eclipsePhase: v),
    });
  }

  void setSoundVolume(int v) => _set(state.copyWith(soundVolume: v.clamp(0, 100)));

  void setMotorVolume(int v) {
    _set(state.copyWith(motorVolume: v.clamp(0, 100)));
    final level = vehicleLevel(v);
    if (level == _motorLevel) return;
    _motorLevel = level;
    ref.read(vehicleProvider.notifier).setMotorVolume(level);
  }

  void setChimeVolume(int v) {
    final percent = v.clamp(chimeFloor, 100);
    _set(state.copyWith(chimeVolume: percent));
    final level = vehicleLevel(percent);
    if (level == _chimeLevel) return;
    _chimeLevel = level;
    ref.read(vehicleProvider.notifier).setChimeVolume(level);
  }

  void setSystemSound(bool on) => _set(state.copyWith(systemSound: on));

  void reset() {
    _set(const SoundSettings());
    ref.read(toastProvider.notifier).show('Sound settings reset');
  }
}
