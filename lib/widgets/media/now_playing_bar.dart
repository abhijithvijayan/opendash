import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../state/format_settings.dart';
import '../../state/media_state.dart';

import '../../state/riding_lockout.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';
import 'media_button.dart';

/// Right side of the trip strip while music plays. Transport controls stay
/// usable while riding; the album art tap (volume) does not.
class NowPlayingBar extends ConsumerWidget {
  const NowPlayingBar({super.key});

  static const width = 500.0;

  /// Previous, play / pause, next: usable while riding, so each is a full
  /// touch target (they were 44 px, under the 56 px floor, at first).
  static const skip = DashTouch.min;
  static const play = 64.0;
  static const gap = 4.0;
  static const controlsWidth = skip * 2 + play + gap * 2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final title = ref.watch(vehicleProvider.select((v) => v.songTitle));
    final artist = ref.watch(vehicleProvider.select((v) => v.songArtist));
    final playing = ref.watch(vehicleProvider.select((v) => v.mediaPlaying));
    final position = ref.watch(vehicleProvider.select((v) => v.mediaPosition));
    final duration = ref.watch(vehicleProvider.select((v) => v.mediaDuration));
    final hasArt = ref.watch(vehicleProvider.select((v) => v.hasAlbumArt));
    final accent = ref.watch(accentProvider);
    final riding = ref.watch(ridingLockoutProvider);
    final n = ref.read(vehicleProvider.notifier);

    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: width,
        minHeight: 72,
        maxHeight: 72,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            key: const ValueKey('np-art'),
            behavior: HitTestBehavior.opaque,
            onTap: riding
                ? null
                : ref.read(volumeOverlayProvider.notifier).open,
            // Phase 2 loads the bitmap; until then the art is a letter tile
            // in the mode accent, like a contact avatar.
            // The tile is 44; the target around it is the touch floor.
            child: Container(
              width: 44,
              height: 44,
              margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
              decoration: BoxDecoration(
                color: hasArt ? accent.withValues(alpha: 0.3) : DashColors.slate,
                borderRadius: BorderRadius.circular(DashRadius.chip),
              ),
              alignment: Alignment.center,
              child: hasArt && title.isNotEmpty
                  ? Text(
                      title.characters.first.toUpperCase(),
                      key: const ValueKey('np-letter'),
                      style: DashText.value(20, color: DashColors.bone),
                    )
                  : Icon(
                      Icons.music_note_rounded,
                      size: 22,
                      color: DashColors.ash,
                    ),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: DashText.value(20),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    artist,
                    style: DashText.caption(14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (duration > 0) ...[
                    const SizedBox(height: 5),
                    MediaProgressBar(
                      key: const ValueKey('np-progress'),
                      fraction: (position / duration).clamp(0.0, 1.0),
                      color: accent,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Flexible: with a long strip to its left the bar is
                        // squeezed, and the two times must give way, not
                        // overflow.
                        Flexible(
                          child: Text(
                            formatSeconds(position),
                            key: const ValueKey('np-elapsed'),
                            style: DashText.caption(13),
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.clip,
                          ),
                        ),
                        Flexible(
                          child: Text(
                            formatSeconds(duration),
                            key: const ValueKey('np-total'),
                            style: DashText.caption(13),
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.clip,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          MediaButton(
            key: const ValueKey('np-prev'),
            icon: Icons.skip_previous_rounded,
            size: skip,
            iconSize: 30,
            color: DashColors.ash,
            onTap: n.mediaPrev,
          ),
          const SizedBox(width: gap),
          MediaButton(
            key: const ValueKey('np-play'),
            icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: play,
            iconSize: 38,
            color: DashColors.bone,
            background: DashColors.slate.withValues(alpha: 0.6),
            onTap: playing ? n.mediaPause : n.mediaPlay,
          ),
          const SizedBox(width: gap),
          MediaButton(
            key: const ValueKey('np-next'),
            icon: Icons.skip_next_rounded,
            size: skip,
            iconSize: 30,
            color: DashColors.ash,
            onTap: n.mediaNext,
          ),
        ],
      ),
    );
  }
}

/// 3px track with the accent filling to [fraction].
class MediaProgressBar extends StatelessWidget {
  const MediaProgressBar({
    super.key,
    required this.fraction,
    required this.color,
  });
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: fraction),
      duration: DashMotion.value,
      curve: Curves.easeOut,
      builder: (context, f, _) => SizedBox(
        height: 3,
        child: LayoutBuilder(
          builder: (context, c) => Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: DashColors.slate,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
              Container(
                width: c.maxWidth * f,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
