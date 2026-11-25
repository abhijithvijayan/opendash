import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/vehicle_data.dart';
import '../../providers/mock_provider.dart';
import '../../state/format_settings.dart';
import '../../state/riding_settings.dart';
import '../../state/theme_state.dart';
import '../../state/toast_state.dart';
import '../../theme/dash_theme.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import 'telltale_icons.dart';

class Telltale {
  const Telltale(this.id, this.glyph, this.color, {this.pulse = false, this.label, this.description = ''});
  final String id;
  final TelltaleGlyph glyph;
  final Color color;
  final bool pulse;

  /// Text drawn inside the glyph (the speed limit sign).
  final String? label;

  /// What a tap on the symbol explains in a toast.
  final String description;
}

/// The speed limit sign: ash under the limit, warning above it.
Telltale? speedLimitTelltale(VehicleData v, RidingSettings r, [DashTheme t = DashTheme.dark, bool useMiles = false]) {
  if (!r.speedLimitEnabled) return null;
  final over = v.speed > r.speedLimit;
  return Telltale('speedLimit', TelltaleGlyph.speedLimit, over ? t.warning : t.ash,
      label: '${toDisplayDistance(r.speedLimit, useMiles)}',
      description: 'Speed limit warning — ${toDisplayDistance(r.speedLimit, useMiles)} ${speedUnit(useMiles)}');
}

/// Shown while the rider has bypassed a broken side stand sensor.
Telltale? standBypassTelltale(RidingSettings r, [DashTheme t = DashTheme.dark]) {
  if (r.isOn(RidingFeature.sideStandCutOff)) return null;
  return Telltale('standBypass', TelltaleGlyph.standBypass, t.warning, description: 'Side stand sensor bypassed');
}

/// Stands in for the full regen ceiling (0x140) until the battery has
/// reported one. A Gen 1 pack has reached 5.1 kW.
const regenMaxPowerW = 1500;

/// 0-1 share of the most regen this battery has ever allowed that it
/// allows right now.
double regenCapacity(VehicleData v) =>
    (v.regenPowerLimitW / (v.peaks.regenLimitW > 0 ? v.peaks.regenLimitW : regenMaxPowerW)).clamp(0.0, 1.0);

/// A zero ceiling confirmed by NOT_AVAILABLE (0) with the motor on: the
/// pack is full or cold. Parked, the BMS reports a zero ceiling and
/// NOT_AVAILABLE_THROTTLE (2) on a healthy pack, so neither counts there.
/// A fresh VehicleData reads a zero ceiling too, so nothing is "off" until
/// the flag has actually been read. Energy being recovered always wins.
bool regenOff(VehicleData v) =>
    // Use regenNotification (real HHMIS signal), not
    // regenActive (mock-only).
    !v.regenNotification &&
    v.vehicleState.motorOn &&
    v.regenPowerLimitW == 0 &&
    v.regenAvailabilityKnown &&
    v.regenAvailability == 0;

/// HVDP `RegenAvailability`: only 1 is AVAILABLE, and only once read.
bool regenAvailable(VehicleData v) => v.regenAvailabilityKnown && v.regenAvailability == 1;

Telltale? _regenTelltale(VehicleData v, DashTheme t) {
  // Not while reversing or under smart park. On MoveOS 5 the
  // regen-notification flag stayed set during easy-park creep, so the regen
  // icon appeared next to the speed-limit one with no ride context. Regen is
  // a forward-riding readout; suppress it when the scooter is not.
  if (v.reverse || v.parkAssist) return null;
  // The telltale is driven by regenNotification
  // (HHMIS's BOOL_VEHICLE_REGEN_NOTIFICATION_STATUS). regenActive is a
  // mock-only flag; on real hardware it never flipped, so the telltale
  // never lit.
  if (!v.regenNotification) return null;
  final color = regenAvailable(v) ? t.eco : t.ash;
  final capacity = v.regenPowerLimitW > 0 ? ' — ${(regenCapacity(v) * 100).round()}% available' : '';
  return Telltale('regen', TelltaleGlyph.regen, color,
      description: 'Regenerative braking — ${v.regenMode.label}$capacity');
}

List<Telltale> telltalesFor(VehicleData v, [DashTheme t = DashTheme.dark, bool useMiles = false]) => [
      if (v.cruiseMode == CruiseMode.standby)
        Telltale('cruise', TelltaleGlyph.cruise, t.ash, description: 'Cruise control — standby'),
      if (v.cruiseMode == CruiseMode.active)
        Telltale('cruise', TelltaleGlyph.cruise, t.eco, description: 'Cruise control — active at ${toDisplayDistance(v.speed, useMiles)} ${speedUnit(useMiles)}'),
      if (v.hillHoldActive) Telltale('hillHold', TelltaleGlyph.hillHold, t.normal, description: 'Hill hold assist — active'),
      if (v.apbActive) Telltale('apb', TelltaleGlyph.apb, t.normal, description: 'Adaptive Power Boost — active'),
      ?_regenTelltale(v, t),
      if (regenOff(v))
        Telltale('regenOff', TelltaleGlyph.regenOff, t.ash, description: 'Regen off — battery full or too cold'),
      if (v.brakeWorn)
        Telltale('brakeWorn', TelltaleGlyph.brakeWorn, t.warning, description: 'Brake pads worn — service recommended'),
      if (v.tamperDetected) Telltale('tamper', TelltaleGlyph.tamper, t.critical, description: 'Tow/tamper detected'),
      if (v.fallDetected) Telltale('fall', TelltaleGlyph.fall, t.critical, description: 'Fall detected'),
      if (v.takeMeHomeLights)
        Telltale('takeMeHome', TelltaleGlyph.takeMeHome, t.bone,
            description: 'Take-me-home lights — ${v.takeMeHomeLightsRemaining}s'),
      if (v.autoTurnOff)
        Telltale('autoTurnOff', TelltaleGlyph.autoTurnOff, t.warning, description: 'Auto turn-off — scooter will power down'),
    ];

/// Row of active tell-tales directly under the status bar. Left-aligned
/// at the dashboard's 72px margin: a centred row would sit on the dial's
/// "60" scale numeral. Tapping a symbol names it in a toast.
class TelltaleStrip extends ConsumerWidget {
  const TelltaleStrip({super.key});

  static const height = 36.0;
  static const iconSize = 28.0;
  static const spacing = 16.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (cruise, hill, apb, regen, regenMode, brake, tamper, fall, tmh, tmhLeft, auto, speed) = ref.watch(
      vehicleProvider.select((v) => (
            v.cruiseMode,
            v.hillHoldActive,
            v.apbActive,
            v.regenNotification,
            v.regenMode,
            v.brakeWorn,
            v.tamperDetected,
            v.fallDetected,
            v.takeMeHomeLights,
            v.takeMeHomeLightsRemaining,
            v.autoTurnOff,
            v.speed,
          )),
    );
    final (regenLimit, regenAvail, regenKnown, vehicleState) = ref.watch(
      vehicleProvider.select((v) => (v.regenPowerLimitW, v.regenAvailability, v.regenAvailabilityKnown, v.vehicleState)),
    );
    final theme = ref.watch(uiThemeProvider);
    final riding = ref.watch(ridingSettingsProvider.select((r) => (r.speedLimitEnabled, r.speedLimit, r.isOn(RidingFeature.sideStandCutOff))));
    final settings = RidingSettings(
      speedLimitEnabled: riding.$1,
      speedLimit: riding.$2,
      features: {RidingFeature.sideStandCutOff: riding.$3},
    );
    final useMiles = ref.watch(useMilesProvider);
    final limitTelltale = speedLimitTelltale(VehicleData(speed: speed), settings, theme, useMiles);
    final bypassTelltale = standBypassTelltale(settings, theme);
    final items = telltalesFor(VehicleData(
      cruiseMode: cruise,
      hillHoldActive: hill,
      apbActive: apb,
      regenNotification: regen,
      regenMode: regenMode,
      brakeWorn: brake,
      tamperDetected: tamper,
      fallDetected: fall,
      takeMeHomeLights: tmh,
      takeMeHomeLightsRemaining: tmhLeft,
      autoTurnOff: auto,
      speed: speed,
      regenPowerLimitW: regenLimit,
      regenAvailability: regenAvail,
      regenAvailabilityKnown: regenKnown,
      vehicleState: vehicleState,
    ), theme, useMiles);
    final byId = {for (final t in items) t.id: t, 'speedLimit': ?limitTelltale, 'standBypass': ?bypassTelltale};
    final toast = ref.read(toastProvider.notifier);

    return SizedBox(
      height: height,
      child: AnimatedSize(
        duration: DashMotion.fast,
        curve: DashMotion.valueCurve,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final id in _order)
              AnimatedSwitcher(
                duration: DashMotion.fast,
                switchInCurve: DashMotion.valueCurve,
                switchOutCurve: DashMotion.valueCurve,
                transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
                child: byId[id] == null
                    ? SizedBox.shrink(key: ValueKey('tt-$id-off'))
                    : GestureDetector(
                        key: ValueKey('tt-$id'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          toast.show(byId[id]!.description);
                        },
                        child: Padding(
                          padding: const EdgeInsets.only(right: spacing),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _Pulsing(
                                pulse: byId[id]!.pulse,
                                builder: (alpha) => TelltaleIcon(
                                  glyph: byId[id]!.glyph,
                                  color: byId[id]!.color.withValues(alpha: alpha),
                                  label: byId[id]!.label,
                                  background: theme.ink,
                                ),
                              ),
                              if (id == 'takeMeHome' && tmhLeft > 0)
                                Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: Text(
                                    '${tmhLeft}s',
                                    key: const ValueKey('tt-takeMeHome-countdown'),
                                    style: DashText.caption(13, color: theme.bone),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
              ),
          ],
        ),
      ),
    );
  }

  static const _order = [
    'cruise', 'hillHold', 'apb', 'regen', 'regenOff', 'brakeWorn', 'tamper', 'fall',
    'takeMeHome', 'autoTurnOff', 'speedLimit', 'standBypass',
  ];
}

/// Fades the glyph by painting it with a lower alpha; an Opacity widget
/// would cost a saveLayer per frame.
class _Pulsing extends StatefulWidget {
  const _Pulsing({required this.pulse, required this.builder});
  final bool pulse;
  final Widget Function(double alpha) builder;

  @override
  State<_Pulsing> createState() => _PulsingState();
}

class _PulsingState extends State<_Pulsing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulse) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_Pulsing old) {
    super.didUpdateWidget(old);
    if (widget.pulse && !old.pulse) _c.repeat(reverse: true);
    if (!widget.pulse && old.pulse) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => widget.builder(1 - 0.55 * _c.value),
    );
  }
}
