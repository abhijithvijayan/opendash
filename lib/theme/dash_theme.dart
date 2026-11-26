import 'dart:ui';

import '../models/vehicle_data.dart';

/// A full colour set. The built-ins are below; custom accents are applied
/// with [copyWith] and keep the base theme's name.
class DashTheme {
  const DashTheme({
    required this.name,
    required this.ink,
    required this.inkLift,
    required this.bone,
    required this.ash,
    required this.slate,
    required this.eco,
    required this.normal,
    required this.sport,
    required this.hyper,
    required this.charging,
    required this.parked,
    required this.critical,
    required this.warning,
  });

  final String name;
  final Color ink;
  final Color inkLift;
  final Color bone;
  final Color ash;
  final Color slate;
  final Color eco;
  final Color normal;
  final Color sport;
  final Color hyper;
  final Color charging;
  final Color parked;
  final Color critical;
  final Color warning;

  static const dark = DashTheme(
    name: 'Dark',
    ink: Color(0xFF05070A),
    inkLift: Color(0xFF0B0E13),
    bone: Color(0xFFECEEF1),
    ash: Color(0xFF8A919C),
    slate: Color(0xFF232932),
    eco: Color(0xFF35D39E),
    normal: Color(0xFF78AEFF),
    sport: Color(0xFFFF7A1A),
    hyper: Color(0xFFD65CFF),
    charging: Color(0xFF4CE0D2),
    parked: Color(0xFF6E7886),
    critical: Color(0xFFFF3B4E),
    warning: Color(0xFFFFC53D),
  );

  static const midnight = DashTheme(
    name: 'Midnight',
    ink: Color(0xFF0A0A14),
    inkLift: Color(0xFF10101E),
    bone: Color(0xFFD8DCE6),
    ash: Color(0xFF6E7490),
    slate: Color(0xFF1E1E32),
    eco: Color(0xFF2EC48A),
    normal: Color(0xFF6B9EFF),
    sport: Color(0xFFFF6B2C),
    hyper: Color(0xFFC44DFF),
    charging: Color(0xFF40D6C8),
    parked: Color(0xFF5C6278),
    critical: Color(0xFFFF3040),
    warning: Color(0xFFFFB830),
  );

  static const ember = DashTheme(
    name: 'Ember',
    ink: Color(0xFF0C0806),
    inkLift: Color(0xFF141008),
    bone: Color(0xFFF0E8DC),
    ash: Color(0xFF9A8E7E),
    slate: Color(0xFF2A2218),
    eco: Color(0xFF4EC87A),
    normal: Color(0xFFE8A040),
    sport: Color(0xFFFF5522),
    hyper: Color(0xFFE04CC8),
    charging: Color(0xFF60C8A0),
    parked: Color(0xFF7A6E5E),
    critical: Color(0xFFFF2828),
    warning: Color(0xFFFFF04A),
  );

  static const light = DashTheme(
    name: 'Light',
    ink: Color(0xFFF2F4F7),
    inkLift: Color(0xFFFFFFFF),
    bone: Color(0xFF1A1D23),
    ash: Color(0xFF6B7280),
    slate: Color(0xFFE5E7EB),
    eco: Color(0xFF22B07D),
    normal: Color(0xFF4A8AE6),
    sport: Color(0xFFE5651A),
    hyper: Color(0xFFB84CE0),
    charging: Color(0xFF35B8AD),
    parked: Color(0xFF9CA3AF),
    critical: Color(0xFFDC2626),
    warning: Color(0xFFD97706),
  );

  /// Matte carbon telemetry with motorsport amber and titanium contrast.
  static const carbonGt = DashTheme(
    name: 'Carbon GT',
    ink: Color(0xFF090A0D),
    inkLift: Color(0xFF14171E),
    bone: Color(0xFFF5F7FA),
    ash: Color(0xFF8C95A6),
    slate: Color(0xFF292F3B),
    eco: Color(0xFF2ED573),
    normal: Color(0xFFFFB020),
    sport: Color(0xFFFF6A00),
    hyper: Color(0xFFFF2D55),
    charging: Color(0xFF38BDF8),
    parked: Color(0xFF6C7485),
    critical: Color(0xFFFF3B30),
    warning: Color(0xFFFFCC00),
  );

  /// Deep synth-indigo with electric cyan and magenta highlights.
  static const neonPulse = DashTheme(
    name: 'Neon Pulse',
    ink: Color(0xFF060814),
    inkLift: Color(0xFF0F142B),
    bone: Color(0xFFEEF6FF),
    ash: Color(0xFF7C8FB8),
    slate: Color(0xFF23305E),
    eco: Color(0xFF00FFA3),
    normal: Color(0xFF00F0FF),
    sport: Color(0xFF9B6BFF),
    hyper: Color(0xFFFF2E93),
    charging: Color(0xFF38F9D7),
    parked: Color(0xFF5D6B94),
    critical: Color(0xFFFF3366),
    warning: Color(0xFFFFD166),
  );

  /// Stealth obsidian pine with crisp emerald and mint gauges.
  static const emeraldStealth = DashTheme(
    name: 'Emerald Stealth',
    ink: Color(0xFF050B08),
    inkLift: Color(0xFF0D1A14),
    bone: Color(0xFFECFDF5),
    ash: Color(0xFF7EA695),
    slate: Color(0xFF1F3B2E),
    eco: Color(0xFF22E58B),
    normal: Color(0xFF38BDF8),
    sport: Color(0xFFF59E0B),
    hyper: Color(0xFFA855F7),
    charging: Color(0xFF6EF3B5),
    parked: Color(0xFF5A7A6B),
    critical: Color(0xFFFF4D4F),
    warning: Color(0xFFFBBF24),
  );

  /// Asphalt dark cockpit with hot magenta-coral crimson accents, kept off
  /// the alert-red hue so the mode accent never reads as a fault.
  static const crimsonTrack = DashTheme(
    name: 'Crimson Track',
    ink: Color(0xFF0D0709),
    inkLift: Color(0xFF1A0F13),
    bone: Color(0xFFFFF1F2),
    ash: Color(0xFFA8858B),
    slate: Color(0xFF3A2228),
    eco: Color(0xFF4ADE80),
    normal: Color(0xFFFF47C2),
    sport: Color(0xFFFF5536),
    hyper: Color(0xFFFF9500),
    charging: Color(0xFF38BDF8),
    parked: Color(0xFF7D5F66),
    critical: Color(0xFFFF1744),
    warning: Color(0xFFFFA726),
  );

  /// High-contrast arctic frost light theme built for direct sunlight.
  static const glacierLight = DashTheme(
    name: 'Glacier Light',
    ink: Color(0xFFEAF1F8),
    inkLift: Color(0xFFFFFFFF),
    bone: Color(0xFF0B1220),
    ash: Color(0xFF4B5C74),
    slate: Color(0xFFCBD7E6),
    eco: Color(0xFF059669),
    normal: Color(0xFF0066FF),
    sport: Color(0xFFEA580C),
    hyper: Color(0xFF9333EA),
    charging: Color(0xFF0891B2),
    parked: Color(0xFF7B8CA3),
    // Deeper than the stock-Light alert hues: amber/red on this cooler frost
    // ground otherwise dip below the stock-Light contrast floor (design-system
    // alert legibility — turn-signal amber and fault red).
    critical: Color(0xFFC81E1E),
    warning: Color(0xFFB45309),
  );

  static const builtIn = [
    dark,
    midnight,
    ember,
    light,
    carbonGt,
    neonPulse,
    emeraldStealth,
    crimsonTrack,
    glacierLight,
  ];

  bool get isLight => ink.computeLuminance() > 0.5;

  /// Glow halos wash out on a light background, so they are scaled down.
  double get glowScale => isLight ? 0.4 : 1.0;

  /// The accent colours that the picker can override, in display order.
  static const accentModes = ['ECO', 'NORMAL', 'SPORT', 'HYPER', 'CHARGING', 'PARKED'];

  Color accentFor(DriveMode mode) => switch (mode) {
        DriveMode.eco => eco,
        DriveMode.normal => normal,
        DriveMode.sport => sport,
        DriveMode.hyper => hyper,
      };

  /// The rider's own ride mode (MoveOS 5): one rose for every theme, apart
  /// from the four stock modes and from the warning amber.
  Color get custom => const Color(0xFFE0457B);

  Color accentNamed(String mode) => switch (mode) {
        'ECO' => eco,
        'NORMAL' => normal,
        'SPORT' => sport,
        'HYPER' => hyper,
        'CHARGING' => charging,
        _ => parked,
      };

  DashTheme withAccent(String mode, Color color) => switch (mode) {
        'ECO' => copyWith(eco: color),
        'NORMAL' => copyWith(normal: color),
        'SPORT' => copyWith(sport: color),
        'HYPER' => copyWith(hyper: color),
        'CHARGING' => copyWith(charging: color),
        _ => copyWith(parked: color),
      };

  DashTheme copyWith({
    Color? ink,
    Color? inkLift,
    Color? bone,
    Color? ash,
    Color? slate,
    Color? eco,
    Color? normal,
    Color? sport,
    Color? hyper,
    Color? charging,
    Color? parked,
    Color? critical,
    Color? warning,
  }) =>
      DashTheme(
        name: name,
        ink: ink ?? this.ink,
        inkLift: inkLift ?? this.inkLift,
        bone: bone ?? this.bone,
        ash: ash ?? this.ash,
        slate: slate ?? this.slate,
        eco: eco ?? this.eco,
        normal: normal ?? this.normal,
        sport: sport ?? this.sport,
        hyper: hyper ?? this.hyper,
        charging: charging ?? this.charging,
        parked: parked ?? this.parked,
        critical: critical ?? this.critical,
        warning: warning ?? this.warning,
      );

  static DashTheme lerp(DashTheme a, DashTheme b, double t) => DashTheme(
        name: t < 0.5 ? a.name : b.name,
        ink: Color.lerp(a.ink, b.ink, t)!,
        inkLift: Color.lerp(a.inkLift, b.inkLift, t)!,
        bone: Color.lerp(a.bone, b.bone, t)!,
        ash: Color.lerp(a.ash, b.ash, t)!,
        slate: Color.lerp(a.slate, b.slate, t)!,
        eco: Color.lerp(a.eco, b.eco, t)!,
        normal: Color.lerp(a.normal, b.normal, t)!,
        sport: Color.lerp(a.sport, b.sport, t)!,
        hyper: Color.lerp(a.hyper, b.hyper, t)!,
        charging: Color.lerp(a.charging, b.charging, t)!,
        parked: Color.lerp(a.parked, b.parked, t)!,
        critical: Color.lerp(a.critical, b.critical, t)!,
        warning: Color.lerp(a.warning, b.warning, t)!,
      );

  List<Object> get _f => [name, ink, inkLift, bone, ash, slate, eco, normal, sport, hyper, charging, parked, critical, warning];

  @override
  bool operator ==(Object other) {
    if (other is! DashTheme) return false;
    final a = _f, b = other._f;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_f);
}
