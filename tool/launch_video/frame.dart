import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'timeline.dart';

const videoSize = Size(1920, 1080);
const _ink = Color(0xFF0B0D10);
const _fg = Color(0xFFF2EFE9);
const _muted = Color(0xFF9AA3AD);
const _accent = Color(0xFF4A8FE8);

class FrameState {
  const FrameState(this.scene, this.frame, this.frames);
  final Scene scene;
  final int frame;
  final int frames;

  double get seconds => frame / 60;

  /// 0 at a scene's edges, 1 once [over] frames in.
  double edge([int over = 14]) =>
      Curves.easeOut.transform((math.min(frame, frames - 1 - frame) / over).clamp(0.0, 1.0));

  double fadeIn(double at, [double over = 0.35]) =>
      Curves.easeOut.transform(((seconds - at) / over).clamp(0.0, 1.0));
}

TextStyle _wide(double size, {Color color = _fg, double weight = 700, double width = 118, double spacing = 0}) => TextStyle(
      fontFamily: 'Archivo',
      fontSize: size,
      color: color,
      height: 1.1,
      letterSpacing: spacing,
      fontVariations: [FontVariation('wght', weight), FontVariation('wdth', width)],
    );

/// The 1920x1080 picture: the dash, and the words over or under it.
class VideoFrame extends StatelessWidget {
  const VideoFrame({super.key, required this.state, required this.dash});

  final ValueListenable<FrameState> state;
  final Widget dash;

  static const dashScale = 1.14;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: _ink,
        child: ValueListenableBuilder<FrameState>(
          valueListenable: state,
          builder: (context, s, _) {
            final scene = s.scene;
            final card = scene.kind != SceneKind.dashWithCaption;
            // A slow push-in keeps a held screen alive.
            final push = 1 + 0.012 * s.frame / s.frames;
            final w = 1280 * dashScale, h = 768 * dashScale;
            return Stack(
              children: [
                Positioned(
                  left: (1920 - w) / 2,
                  top: card ? (1080 - h) / 2 : 34,
                  width: w,
                  height: h,
                  child: Opacity(
                    opacity: scene.dashOpacity,
                    child: Transform.scale(
                      scale: push,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(28),
                        child: FittedBox(child: SizedBox(width: 1280, height: 768, child: dash)),
                      ),
                    ),
                  ),
                ),
                if (scene.kind == SceneKind.dashWithCaption)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 34 + h,
                    bottom: 0,
                    child: Opacity(
                      opacity: s.edge(),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(scene.title, style: _wide(46, weight: 650, width: 110)),
                          if (scene.subtitle != null) ...[
                            const SizedBox(height: 10),
                            Text(scene.subtitle!, style: _wide(26, color: _muted, weight: 450, width: 100)),
                          ],
                          if (scene.footnote != null) ...[
                            const SizedBox(height: 8),
                            Text(scene.footnote!, style: _wide(22, color: _muted.withValues(alpha: 0.85), weight: 400, width: 100)),
                          ],
                        ],
                      ),
                    ),
                  ),
                if (scene.kind == SceneKind.titleCard) Positioned.fill(child: _TitleCard(s)),
                if (scene.kind == SceneKind.claims) Positioned.fill(child: _Claims(s)),
                if (scene.kind == SceneKind.endCard) Positioned.fill(child: _EndCard(s)),
                if (scene.fadeFromBlack || scene.fadeToBlack)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ColoredBox(
                        color: _ink.withValues(
                          alpha: math.max(
                            scene.fadeFromBlack ? 1 - (s.seconds / 1.2).clamp(0.0, 1.0) : 0.0,
                            scene.fadeToBlack ? 1 - ((s.frames - s.frame) / 60 / 1.5).clamp(0.0, 1.0) : 0.0,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _TitleCard extends StatelessWidget {
  const _TitleCard(this.s);
  final FrameState s;

  @override
  Widget build(BuildContext context) {
    final scene = s.scene;
    return Opacity(
      opacity: s.edge(18),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (scene.kicker != null)
            Opacity(
              opacity: s.fadeIn(0.3),
              child: Text(scene.kicker!.toUpperCase(), style: _wide(28, color: _accent, weight: 600, spacing: 8)),
            ),
          const SizedBox(height: 18),
          Opacity(
            opacity: s.fadeIn(scene.kicker == null ? 0.2 : 0.9),
            child: Text(scene.title, textAlign: TextAlign.center, style: _wide(scene.titleSize, weight: 800, width: 125)),
          ),
          if (scene.subtitle != null) ...[
            const SizedBox(height: 26),
            Opacity(
              opacity: s.fadeIn(scene.kicker == null ? 0.8 : 1.8),
              child: Text(scene.subtitle!, textAlign: TextAlign.center, style: _wide(34, color: _muted, weight: 450, width: 100)),
            ),
          ],
        ],
      ),
    );
  }
}

/// Words that land one at a time, on [Scene.wordAt].
class _Claims extends StatelessWidget {
  const _Claims(this.s);
  final FrameState s;

  @override
  Widget build(BuildContext context) {
    final scene = s.scene;
    return Opacity(
      opacity: math.min(1, (s.frames - 1 - s.frame) / 14),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < scene.words.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Opacity(
                opacity: s.fadeIn(scene.wordAt[i], 0.25),
                child: Transform.translate(
                  offset: Offset(0, 24 * (1 - s.fadeIn(scene.wordAt[i], 0.3))),
                  child: Text(scene.words[i], style: _wide(104, weight: 800, width: 125)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EndCard extends StatelessWidget {
  const _EndCard(this.s);
  final FrameState s;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: s.fadeIn(0.1, 0.6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 84),
        child: Column(
          children: [
            const Spacer(),
            Text('OpenDash', style: _wide(132, weight: 800, width: 125)),
            const SizedBox(height: 20),
            Opacity(
              opacity: s.fadeIn(0.8),
              child: Text('NOW AVAILABLE IN BETA', style: _wide(36, color: _accent, weight: 650, spacing: 8)),
            ),
            const SizedBox(height: 44),
            Opacity(
              opacity: s.fadeIn(1.5),
              child: Column(
                children: [
                  Text('github.com/abhijithvijayan/opendash', style: _wide(40, weight: 500, width: 100)),
                  const SizedBox(height: 14),
                  Text('Free and open source  ·  GPLv3 licence', style: _wide(26, color: _muted, weight: 450, width: 100)),
                ],
              ),
            ),
            const SizedBox(height: 56),
            Opacity(
              opacity: s.fadeIn(2.3),
              child: Column(
                children: [
                  Text('Thanks to Sid, Jacob and every beta tester', style: _wide(30, weight: 500, width: 100)),
                  const SizedBox(height: 14),
                  Text(
                    'Tested on Gen 1 (MoveOS 4 and MoveOS 5), Gen 2 (MoveOS 5) and Gen 3 (MoveOS 5).',
                    style: _wide(24, color: _muted, weight: 450, width: 100),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 52),
            Opacity(
              opacity: s.fadeIn(3.2),
              child: Text('Subscribe to @PracticalOverkill for updates', style: _wide(30, color: _accent, weight: 600, width: 105)),
            ),
            const Spacer(),
            Opacity(
              opacity: s.fadeIn(2.3),
              child: Text(
                'Independent project. Not affiliated with Ola Electric. '
                'CarPlay and Android Auto are trademarks of their owners and run through third-party apps.',
                style: _wide(18, color: _muted.withValues(alpha: 0.75), weight: 400, width: 100),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const reelSize = Size(1080, 1920);

/// The vertical cut for Shorts and Reels. Words sit in the top band, clear of
/// the app's own buttons along the bottom and the right edge.
class ReelFrame extends StatelessWidget {
  const ReelFrame({super.key, required this.state, required this.dash});

  final ValueListenable<FrameState> state;
  final Widget dash;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: _ink,
        child: ValueListenableBuilder<FrameState>(
          valueListenable: state,
          builder: (context, s, _) {
            final scene = s.scene;
            final card = scene.kind == SceneKind.endCard;
            final push = 1 + 0.02 * s.frame / s.frames;
            final w = 1040 * scene.zoom * push, h = w * 0.6;
            // The dash is seen through a window under the words; a zoomed
            // dash is cropped by it rather than running into them.
            const winTop = 700.0, winHeight = 820.0;
            final left = 540 - scene.focus.dx * w / 1280;
            final top = winHeight / 2 - scene.focus.dy * h / 768;
            return Stack(
              children: [
                if (!card)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: scene.kind == SceneKind.claims ? 550 : winTop,
                    height: winHeight,
                    child: ClipRect(
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned(
                            left: left,
                            top: top,
                            width: w,
                            height: h,
                            child: Opacity(
                              opacity: scene.dashOpacity,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(30 * scene.zoom),
                                child: FittedBox(child: SizedBox(width: 1280, height: 768, child: dash)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (scene.kind == SceneKind.dashWithCaption || scene.kind == SceneKind.titleCard)
                  Positioned(
                    left: 70,
                    right: 110,
                    top: 200,
                    height: 470,
                    child: Opacity(
                      opacity: s.edge(10),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (scene.kicker != null) ...[
                            Text(scene.kicker!.toUpperCase(), style: _wide(30, color: _accent, weight: 600, spacing: 7)),
                            const SizedBox(height: 18),
                          ],
                          Text(scene.title, textAlign: TextAlign.center, style: _wide(scene.kind == SceneKind.titleCard ? 104 : 58, weight: 750, width: 106)),
                          if (scene.subtitle != null) ...[
                            const SizedBox(height: 18),
                            Text(scene.subtitle!, textAlign: TextAlign.center, style: _wide(36, color: _muted, weight: 450, width: 100).copyWith(height: 1.25)),
                          ],
                          if (scene.footnote != null) ...[
                            const SizedBox(height: 12),
                            Text(scene.footnote!, textAlign: TextAlign.center, style: _wide(27, color: _muted.withValues(alpha: 0.85), weight: 400, width: 100).copyWith(height: 1.25)),
                          ],
                        ],
                      ),
                    ),
                  ),
                if (scene.kind == SceneKind.claims)
                  Positioned.fill(
                    child: Opacity(
                      opacity: math.min(1, (s.frames - 1 - s.frame) / 10),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < scene.words.length; i++)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Opacity(
                                opacity: s.fadeIn(scene.wordAt[i], 0.2),
                                child: Transform.translate(
                                  offset: Offset(0, 30 * (1 - s.fadeIn(scene.wordAt[i], 0.25))),
                                  child: Text(scene.words[i], textAlign: TextAlign.center, style: _wide(112, weight: 800, width: 118)),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (card) Positioned.fill(child: _ReelEndCard(s)),
                if (scene.fadeFromBlack || scene.fadeToBlack)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ColoredBox(
                        color: _ink.withValues(
                          alpha: math.max(
                            scene.fadeFromBlack ? 1 - (s.seconds / 0.35).clamp(0.0, 1.0) : 0.0,
                            scene.fadeToBlack ? 1 - ((s.frames - s.frame) / 60 / 1.2).clamp(0.0, 1.0) : 0.0,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ReelEndCard extends StatelessWidget {
  const _ReelEndCard(this.s);
  final FrameState s;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(70, 330, 110, 0),
      child: Column(
        children: [
          Opacity(opacity: s.fadeIn(0.05, 0.4), child: Text('OpenDash', style: _wide(124, weight: 800, width: 118))),
          const SizedBox(height: 16),
          Opacity(
            opacity: s.fadeIn(0.5),
            child: Text('NOW AVAILABLE IN BETA', style: _wide(38, color: _accent, weight: 650, spacing: 6)),
          ),
          const SizedBox(height: 70),
          Opacity(
            opacity: s.fadeIn(1.0),
            child: Column(
              children: [
                Text('Free and open source', style: _wide(44, weight: 600, width: 105)),
                const SizedBox(height: 14),
                Text('github.com/abhijithvijayan/opendash', textAlign: TextAlign.center, style: _wide(34, color: _muted, weight: 500, width: 100)),
              ],
            ),
          ),
          const SizedBox(height: 70),
          Opacity(
            opacity: s.fadeIn(1.6),
            child: Column(
              children: [
                Text('Thanks to Sid, Jacob and every beta tester', textAlign: TextAlign.center, style: _wide(32, weight: 500, width: 100)),
                const SizedBox(height: 14),
                Text(
                  'Tested on Gen 1 (MoveOS 4 and 5), Gen 2 and Gen 3 (MoveOS 5)',
                  textAlign: TextAlign.center,
                  style: _wide(27, color: _muted, weight: 450, width: 100).copyWith(height: 1.3),
                ),
              ],
            ),
          ),
          const SizedBox(height: 70),
          Opacity(
            opacity: s.fadeIn(2.2),
            child: Text('Follow @PracticalOverkill for more', textAlign: TextAlign.center, style: _wide(38, color: _accent, weight: 650, width: 104)),
          ),
          const SizedBox(height: 40),
          Opacity(
            opacity: s.fadeIn(2.2),
            child: Text(
              'Independent project. Not affiliated with Ola Electric.',
              textAlign: TextAlign.center,
              style: _wide(22, color: _muted.withValues(alpha: 0.75), weight: 400, width: 100),
            ),
          ),
        ],
      ),
    );
  }
}
