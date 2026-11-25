import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/vehicle_data.dart';
import '../../providers/mock_provider.dart';
import '../../state/format_settings.dart';
import '../../state/theme_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/controls/apps_swipe_zone.dart';
import '../../widgets/controls/trunk_button.dart';
import '../../state/apps_state.dart';
import '../../state/riding_lockout.dart';
import '../../widgets/controls/resume_projection_chip.dart';
import '../../widgets/gauges/power_bar.dart';
import '../../widgets/gauges/speed_dial.dart';
import '../../widgets/indicators/mode_ladder.dart';
import '../../widgets/indicators/telltale_strip.dart';
import '../../widgets/indicators/trip_strip.dart';
import '../../widgets/overlays/alert_overlay.dart';
import '../../widgets/overlays/call_overlay.dart';
import '../../widgets/overlays/nav_bar.dart';
import '../../widgets/panel/widget_panel.dart';
import '../../theme/tokens.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  /// Below the power bar, inside the dial's bottom opening.
  static const wordmarkTop = 588.0;

  /// Under the mode ladder, clear of the nav bar and the toast lane.
  // Chosen so the mode ladder (ends y468), the boot button and the
  // back-to-app chip below it share even ~24px gaps down to the trip strip
  // (y696): 468 +24 +96(boot) +24 +60(chip) +24 = 696.
  static const trunkTop = 492.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(accentProvider);
    final theme = ref.watch(uiThemeProvider);
    // Each gauge sits in its own layer, so a speed tick repaints the dial
    // and nothing else on the head unit's GPU.
    return Stack(
      children: [
        Positioned(
          left: 300,
          top: 90,
          child: RepaintBoundary(
            child: Consumer(
              builder: (context, ref, _) => SpeedDial(
                speed: ref.watch(vehicleProvider.select((v) => v.speed)),
                accent: accent,
                theme: theme,
                useMiles: ref.watch(useMilesProvider),
                stale: ref.watch(vehicleProvider.select((v) => v.hhmisStale)),
                mark: ref.watch(vehicleProvider.select(dialMarkFor)),
                cruiseSet: ref.watch(vehicleProvider.select((v) => v.cruiseMode == CruiseMode.active ? v.cruiseSetSpeed : null)),
              ),
            ),
          ),
        ),
        Positioned(
          left: 300,
          width: 680,
          top: 90 + SpeedDial.center.dy + 118,
          child: RepaintBoundary(
            child: Center(
              child: Consumer(
                builder: (context, ref, _) => PowerBar(
                  power: ref.watch(vehicleProvider.select((v) => v.power)),
                  maxPower: ref.watch(vehicleProvider.select(powerBarMaxFor)),
                  maxRegen: ref.watch(vehicleProvider.select(regenBarMaxFor)),
                  accent: accent,
                  theme: theme,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 300,
          width: 680,
          top: wordmarkTop,
          child: const RepaintBoundary(child: StateWordmark()),
        ),
        // The ladder only matters once the motor is live; a parked scooter
        // shows the trunk button and nothing else in the left column.
        Positioned(
          left: 72,
          top: 212,
          child: Consumer(
            builder: (context, ref, _) {
              // Not in reverse: the scooter is in none of these modes then,
              // and stock's single mode label reads REVERSE.
              final motorOn = ref.watch(vehicleProvider.select((v) => v.vehicleState.motorOn && !v.reverse));
              return AnimatedSwitcher(
                duration: DashMotion.normal,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween(begin: const Offset(-0.15, 0), end: Offset.zero).animate(anim),
                    child: child,
                  ),
                ),
                child: motorOn
                    ? const RepaintBoundary(key: ValueKey('mode-ladder'), child: ModeLadder())
                    : const SizedBox.shrink(key: ValueKey('mode-ladder-off')),
              );
            },
          ),
        ),
        Positioned(
          left: 72,
          top: DashboardScreen.trunkTop,
          child: const RepaintBoundary(child: DashboardTrunkButton()),
        ),
        // The way back to a projection app. Below the boot button, in the
        // open space above the trip strip: above it there is no room — in
        // ride mode at a standstill the mode ladder (down to y468), the boot
        // button and this chip were all crowded into the same column.
        // Its own place, so it does not move when the boot
        // button hides on the move.
        Positioned(
          left: 72,
          top: DashboardScreen.trunkTop + 120,
          child: Consumer(
            builder: (context, ref, _) {
              final resume = ref.watch(projectionResumeProvider);
              // Only phone projection may open on the move: the way back
              // to anything else waits, out of sight, for the next stop.
              final hidden = resume == null || (!resume.projection && ref.watch(ridingLockoutProvider));
              return hidden ? const SizedBox.shrink() : RepaintBoundary(child: ResumeProjectionChip(name: resume.chipName));
            },
          ),
        ),
        const Positioned(left: WidgetPanel.left, top: WidgetPanel.top, child: RepaintBoundary(child: WidgetPanel())),
        const Positioned(left: 0, right: 0, bottom: 0, child: RepaintBoundary(child: TripStrip())),
        const Positioned(left: 0, right: 0, bottom: 0, child: AppsSwipeZone()),
        const NavBar(),
        Consumer(
          builder: (context, ref, _) {
            final shift = ref.watch(alertBannerShiftProvider) + ref.watch(callBarShiftProvider);
            return AnimatedPositioned(
              key: const ValueKey('telltale-strip-position'),
              duration: DashMotion.normal,
              curve: Curves.easeOutCubic,
              left: 72,
              top: 72 + shift,
              child: const RepaintBoundary(child: TelltaleStrip()),
            );
          },
        ),
      ],
    );
  }
}

/// The letter the dial shows in place of the speed: R whenever in reverse,
/// and standing still P when parked (whatever the side stand is doing: it
/// is the scooter's own state) or H when hill hold has it. Ready and not
/// held keeps its 0, so a live throttle never looks like a dead one.
DialMark? dialMarkFor(VehicleData v) {
  if (v.reverse) return DialMark.reverse;
  if (v.speed > 0) return null;
  if (v.vehicleState == VehicleState.parked) return DialMark.park;
  if (v.hillHoldActive) return DialMark.hillHold;
  return null;
}

/// REVERSE in warning above everything, HILL HOLD or READY in the mode
/// accent while the throttle is live, PARKED in ash otherwise, nothing once
/// moving.
/// Colour-blind riders get the word.
class StateWordmark extends ConsumerWidget {
  const StateWordmark({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(vehicleProvider.select((v) => v.speed > 0 ? null : v.vehicleState));
    final cruiseAt = ref.watch(vehicleProvider.select((v) => v.cruiseMode == CruiseMode.active ? v.cruiseSetSpeed : null));
    final reverse = ref.watch(vehicleProvider.select((v) => v.reverse));
    final parkAssist = ref.watch(vehicleProvider.select((v) => v.parkAssist));
    final held = ref.watch(vehicleProvider.select((v) => v.hillHoldActive && v.speed == 0));
    final useMiles = ref.watch(useMilesProvider);
    final accent = ref.watch(accentProvider);
    final theme = ref.watch(uiThemeProvider);
    // Reverse is a safety state and wins; park assist (MoveOS 5 creep) shows
    // even while moving, so it is not gated on the stopped `state`; cruise
    // only runs while moving, so it never competes with READY/PARKED.
    final (label, color, size) = switch ((cruiseAt, reverse, parkAssist, state)) {
      (_, true, _, _) => ('REVERSE', theme.warning, 24.0),
      (_, _, true, _) => ('PARK ASSIST', theme.normal, 16.0),
      (final int set, _, _, _) => ('CRUISE ${toDisplayDistance(set, useMiles)}', theme.eco, 20.0),
      (_, _, _, VehicleState.ready) => (held ? 'HILL HOLD' : 'READY', accent, 18.0),
      (_, _, _, VehicleState.parked) => ('PARKED', theme.ash, 18.0),
      _ => (null, theme.ash, 18.0),
    };
    return IgnorePointer(
      child: SizedBox(
        height: 24,
        child: AnimatedSwitcher(
          duration: DashMotion.fast,
          switchInCurve: DashMotion.valueCurve,
          switchOutCurve: DashMotion.valueCurve,
          child: label == null
              ? const SizedBox.shrink()
              : Text(
                  label,
                  key: ValueKey('wordmark-${reverse ? 'REVERSE' : parkAssist ? 'PARK_ASSIST' : cruiseAt != null ? 'CRUISE' : label}'),
                  style: DashText.mode(color, size: size),
                  textAlign: TextAlign.center,
                ),
        ),
      ),
    );
  }
}
