import '../media/now_playing_bar.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../state/media_state.dart';
import '../../state/overlay_state.dart';
import '../../state/riding_lockout.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';

IconData volumeIconFor(int level) => switch (level) {
      0 => Icons.volume_off_rounded,
      <= 33 => Icons.volume_mute_rounded,
      <= 66 => Icons.volume_down_rounded,
      _ => Icons.volume_up_rounded,
    };

/// Bottom-right volume popup, right-aligned with the now playing bar.
class VolumeOverlay extends ConsumerWidget {
  const VolumeOverlay({super.key});

  static const popupWidth = 224.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(volumeOverlayProvider);
    final volume = ref.watch(vehicleProvider.select((v) => v.volume));
    final notifier = ref.read(volumeOverlayProvider.notifier);
    // Shown while riding for a level changed on the handlebar: look, not touch.
    final moving = ref.watch(ridingLockoutProvider);
    // On a full page (Settings, Bluetooth, Apps) there is no now-playing
    // bar for it to sit on, and in the corner it looked lost: there it is
    // centred at the bottom.
    final onPage = ref.watch(overlayTitleProvider) != null;

    return Stack(
      children: [
        if (open && !moving)
          Positioned.fill(
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: notifier.dismiss),
          ),
        // Over the now-playing bar's title, beside its transport controls:
        // the bar turns into the volume for a few seconds, where the finger
        // that opened it (the album tile) already is. A popup of its own
        // anywhere else crowded the bottom of the dashboard: it sat on the
        // trunk button, then on the dial's "0", then filled the gap in the
        // trip strip (seen in Chrome).
        Positioned(
          left: onPage ? (1280 - popupWidth) / 2 : 1280 - (DashSpace.gutter + NowPlayingBar.controlsWidth + 12) - popupWidth,
          top: 700,
          child: AnimatedOpacity(
            opacity: open ? 1 : 0,
            duration: DashMotion.fast,
            child: IgnorePointer(
              ignoring: !open || moving,
              child: Container(
                key: const ValueKey('volume-popup'),
                // Just the title's width, so the album tile stays visible
                // beside it; opaque, so the title does not show through.
                width: popupWidth,
                height: 64,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: DashColors.inkLift,
                  borderRadius: BorderRadius.circular(DashRadius.card),
                  border: Border.all(color: DashColors.slate, width: 1.5),
                ),
                child: Row(
                  children: [
                    Icon(volumeIconFor(volume), size: 20, color: DashColors.ash),
                    SizedBox(
                      width: 130,
                      child: SliderTheme(
                        data: SliderThemeData(
                          activeTrackColor: DashColors.bone,
                          inactiveTrackColor: DashColors.slate,
                          thumbColor: DashColors.bone,
                          overlayColor: DashColors.bone.withValues(alpha: 0.13),
                          trackHeight: 3,
                          thumbShape: RoundSliderThumbShape(enabledThumbRadius: 8),
                        ),
                        child: Slider(
                          value: volume.toDouble(),
                          max: 100,
                          onChanged: (x) => notifier.setLevel(x.round()),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text('$volume%', style: DashText.value(16), textAlign: TextAlign.right),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
