import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/vehicle_data.dart';
import '../../providers/mock_provider.dart';
import '../../state/riding_lockout.dart';
import '../../state/theme_state.dart';
import '../../state/toast_state.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';
import '../../services/analytics_logger.dart';

/// Drive modes stacked like a gear indicator, HYPER at the top. Tapping a row
/// requests that mode while stopped; on the move the ladder is read-only
/// so a bumped row cannot change throttle response mid-corner. A mode the
/// VCU reports as unavailable is dimmed further and refuses the tap.
class ModeLadder extends ConsumerWidget {
  const ModeLadder({super.key});

  static const rows = [DriveMode.hyper, DriveMode.sport, DriveMode.normal, DriveMode.eco];
  static const readOnlyOpacity = 0.4;
  static const unavailableOpacity = 0.2;
  static const rowHeight = 64.0;
  static const customRowHeight = 51.2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(vehicleProvider.select((v) => v.driveMode));
    final modesAvailable = ref.watch(vehicleProvider.select((v) => v.modesAvailable));
    // The rider's own mode (MoveOS 5), when it is switched on or in use.
    final (customLabel, customActive) = ref.watch(vehicleProvider.select((v) => (
          v.customRide.enabled == true || v.customRideActive ? v.customRide.label : null,
          v.customRideActive,
        )));
    // Each row in its own mode's colour, not the live accent: cruise turns
    // the dial green, and Normal lit in green would read as Eco.
    final theme = ref.watch(uiThemeProvider);
    final idle = theme.ash;
    final riding = ref.watch(ridingLockoutProvider);
    // Five rows fit the space of four.
    final height = customLabel == null ? rowHeight : customRowHeight;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (customLabel != null)
          _row(
            ref,
            key: 'custom',
            label: customLabel.toUpperCase(),
            active: customActive,
            riding: riding,
            available: true,
            accent: theme.custom,
            idle: idle,
            height: height,
            // Like the stock modes on the scooter, it is chosen on the
            // handlebar; OpenDash never sends the custom mode.
            onTap: () {
              uiTap('mode-ladder', {'mode': 'custom', 'allowed': true});
              ref.read(toastProvider.notifier).show('Mode is on the handlebar switch');
            },
          ),
        for (final mode in rows)
          _row(
            ref,
            key: mode.name,
            label: mode.label,
            active: mode == active && !customActive,
            riding: riding,
            // The mode the VCU is in is never drawn as unavailable.
            available: mode == active || mode.availableIn(modesAvailable),
            accent: theme.accentFor(mode),
            idle: idle,
            height: height,
            onTap: () {
              uiTap('mode-ladder', {'mode': mode.name, 'allowed': true});
              ref.read(vehicleProvider.notifier).selectDriveMode(mode);
            },
          ),
      ],
    );
  }

  Widget _row(
    WidgetRef ref, {
    required String key,
    required String label,
    required bool active,
    required bool riding,
    required bool available,
    required Color accent,
    required Color idle,
    required double height,
    required VoidCallback onTap,
  }) {
    void refused(String reason) => uiTap('mode-ladder', {'mode': key, 'allowed': false, 'reason': reason});
    return Listener(
      // While riding the gesture is dropped, not ignored; the pointer
      // listener still records that the rider tried.
      onPointerDown: riding ? (_) => refused('riding') : null,
      child: GestureDetector(
        key: ValueKey('mode-row-$key'),
        behavior: HitTestBehavior.opaque,
        onTap: riding
            ? null
            : () {
                if (!available) {
                  refused('unavailable');
                  ref.read(toastProvider.notifier).show('$label is not available right now', type: ToastType.warning);
                  return;
                }
                onTap();
              },
        child: AnimatedOpacity(
          duration: DashMotion.normal,
          curve: Curves.easeOut,
          opacity: !available ? unavailableOpacity : riding ? readOnlyOpacity : 1.0,
          child: SizedBox(
            height: height,
            width: 272,
            child: Row(
              children: [
                AnimatedContainer(
                  duration: DashMotion.slow,
                  curve: Curves.easeOut,
                  width: 4,
                  height: active ? 44 : 0,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: active ? [BoxShadow(color: accent.withValues(alpha: 0.5), blurRadius: 8)] : null,
                  ),
                ),
                const SizedBox(width: 20),
                AnimatedDefaultTextStyle(
                  duration: DashMotion.slow,
                  curve: Curves.easeOut,
                  style: active ? DashText.mode(accent) : DashText.mode(idle.withValues(alpha: 0.8), size: 20),
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
