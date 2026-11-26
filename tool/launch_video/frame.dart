import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart' show Icons;
import 'package:flutter/widgets.dart';

import 'package:opendash/widgets/overlays/qr_card_dialog.dart' show QrPainter;

import 'timeline.dart';

const videoSize = Size(1920, 1080);
const _ink = Color(0xFF0B0D10);
const _fg = Color(0xFFF2EFE9);
const _muted = Color(0xFF9AA3AD);
const _accent = Color(0xFF4A8FE8);

class FrameState {
  const FrameState(this.scene, this.frame, this.frames, {this.phone, this.tap, this.tapAge = 0});
  final Scene scene;
  final int frame;
  final int frames;

  /// The companion's filmed frame for a phone scene, and a finger on it:
  /// where (in the phone's pixels) and how far through its 0..1 fade.
  final ui.Image? phone;
  final Offset? tap;
  final double tapAge;

  /// The step of [Scene.words] that is current.
  int get step {
    var i = 0;
    for (var k = 0; k < scene.wordAt.length; k++) {
      if (seconds >= scene.wordAt[k]) i = k;
    }
    return i;
  }

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

  static const dashScale = 1.0;

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
            final w = 1280 * dashScale;
            final housing = DisplayHousing.sizeFor(w);
            return Stack(
              children: [
                if (scene.kind != SceneKind.phone) Positioned(
                  left: (1920 - housing.width) / 2,
                  top: card ? (1080 - housing.height) / 2 : 28,
                  width: housing.width,
                  height: housing.height,
                  child: Opacity(
                    opacity: scene.dashOpacity,
                    child: Transform.scale(
                      scale: push,
                      child: DisplayHousing(screenWidth: w, child: dash),
                    ),
                  ),
                ),
                if (scene.kind == SceneKind.dashWithCaption)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 28 + housing.height,
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
                          if (scene.words.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text(scene.words[s.step], style: _wide(28, color: _accent, weight: 650, width: 100)),
                          ],
                          if (scene.footnote != null) ...[
                            const SizedBox(height: 8),
                            Text(scene.footnote!, style: _wide(22, color: _muted.withValues(alpha: 0.85), weight: 400, width: 100)),
                          ],
                        ],
                      ),
                    ),
                  ),
                if (scene.kind == SceneKind.phone) Positioned.fill(child: _InstallScene(s)),
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

const companionUrl = 'https://github.com/abhijithvijayan/opendash-companion/releases/latest';

/// A scannable code on a white tile, with what it opens written under it.
class QrTile extends StatelessWidget {
  const QrTile({super.key, required this.url, required this.size, this.label, this.caption});

  final String url;
  final double size;
  final String? label;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          padding: EdgeInsets.all(size * 0.07),
          decoration: BoxDecoration(color: const Color(0xFFFFFFFF), borderRadius: BorderRadius.circular(size * 0.08)),
          child: CustomPaint(painter: QrPainter(url)),
        ),
        if (label != null) ...[
          SizedBox(height: size * 0.07),
          Text(label!, textAlign: TextAlign.center, style: _wide(size * 0.105, weight: 650, width: 100)),
        ],
        if (caption != null) ...[
          SizedBox(height: size * 0.02),
          Text(caption!, textAlign: TextAlign.center, style: _wide(size * 0.08, color: _muted, weight: 450, width: 100)),
        ],
      ],
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
        padding: const EdgeInsets.fromLTRB(170, 70, 150, 56),
        child: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('OpenDash', style: _wide(132, weight: 800, width: 125)),
                        const SizedBox(height: 16),
                        Opacity(
                          opacity: s.fadeIn(0.8),
                          child: Text('NOW AVAILABLE IN BETA', style: _wide(36, color: _accent, weight: 650, spacing: 8)),
                        ),
                        const SizedBox(height: 40),
                        Opacity(
                          opacity: s.fadeIn(1.5),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('github.com/abhijithvijayan/opendash', style: _wide(38, weight: 500, width: 100)),
                              const SizedBox(height: 12),
                              Text('Free and open source  ·  GPLv3 licence', style: _wide(26, color: _muted, weight: 450, width: 100)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 46),
                        Opacity(
                          opacity: s.fadeIn(2.3),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Thanks to Sid, Jacob and every beta tester', style: _wide(30, weight: 500, width: 100)),
                              const SizedBox(height: 12),
                              Text(
                                'Tested on Gen 1 (MoveOS 4 and MoveOS 5), Gen 2 (MoveOS 5) and Gen 3 (MoveOS 5).',
                                style: _wide(24, color: _muted, weight: 450, width: 100),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 46),
                        Opacity(
                          opacity: s.fadeIn(3.2),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Subscribe to @PracticalOverkill for updates', style: _wide(30, color: _accent, weight: 600, width: 105)),
                              const SizedBox(height: 10),
                              Text('Instagram  @practical.overkill', style: _wide(24, color: _muted, weight: 500, width: 100)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Opacity(
                    opacity: s.fadeIn(1.5),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        QrTile(url: companionUrl, size: 340, label: 'Scan to install', caption: 'OpenDash Companion for Android'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
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
            final push = 1 + 0.015 * s.frame / s.frames;
            const screenWidth = 960.0;
            final housing = DisplayHousing.sizeFor(screenWidth);
            const centreY = 1030.0;
            return Stack(
              children: [
                if (!card && scene.kind != SceneKind.phone)
                  Positioned(
                    left: (1080 - housing.width) / 2,
                    top: centreY - housing.height / 2,
                    width: housing.width,
                    height: housing.height + 260,
                    child: Opacity(
                      opacity: scene.dashOpacity,
                      child: Transform.scale(
                        scale: push,
                        alignment: Alignment.topCenter,
                        child: Column(
                          children: [
                            DisplayHousing(screenWidth: screenWidth, child: dash),
                            const _Mount(),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (scene.kind == SceneKind.phone)
                  Positioned(
                    left: (1080 - 1000 * phoneAspect) / 2,
                    top: 760,
                    height: 1000,
                    width: 1000 * phoneAspect,
                    child: Opacity(opacity: s.edge(10), child: PhoneHousing(state: s)),
                  ),
                if (scene.kind == SceneKind.dashWithCaption || scene.kind == SceneKind.titleCard || scene.kind == SceneKind.phone)
                  Positioned(
                    left: 70,
                    right: 110,
                    top: 230,
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
                          if (scene.kind == SceneKind.phone) ...[
                            const SizedBox(height: 18),
                            Text('${s.step + 1}. ${scene.words[s.step]}',
                                textAlign: TextAlign.center, style: _wide(38, color: _accent, weight: 600, width: 100).copyWith(height: 1.25)),
                          ] else if (scene.subtitle != null) ...[
                            const SizedBox(height: 18),
                            Text(scene.subtitle!, textAlign: TextAlign.center, style: _wide(36, color: _muted, weight: 450, width: 100).copyWith(height: 1.25)),
                          ],
                          if (scene.kind == SceneKind.dashWithCaption && scene.words.isNotEmpty) ...[
                            const SizedBox(height: 14),
                            Text(scene.words[s.step], textAlign: TextAlign.center, style: _wide(40, color: _accent, weight: 650, width: 100)),
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
      padding: const EdgeInsets.fromLTRB(70, 250, 110, 0),
      child: Column(
        children: [
          Opacity(opacity: s.fadeIn(0.05, 0.4), child: Text('OpenDash', style: _wide(124, weight: 800, width: 118))),
          const SizedBox(height: 16),
          Opacity(
            opacity: s.fadeIn(0.5),
            child: Text('NOW AVAILABLE IN BETA', style: _wide(38, color: _accent, weight: 650, spacing: 6)),
          ),
          const SizedBox(height: 50),
          Opacity(
            opacity: s.fadeIn(1.0),
            child: Column(
              children: [
                Text('Free and open source', style: _wide(44, weight: 600, width: 105)),
                const SizedBox(height: 14),
                Text('github.com/abhijithvijayan/opendash', textAlign: TextAlign.center, style: _wide(34, color: _muted, weight: 500, width: 100)),
                const SizedBox(height: 34),
                const QrTile(url: companionUrl, size: 270, label: 'Scan to install', caption: 'OpenDash Companion for Android'),
              ],
            ),
          ),
          const SizedBox(height: 50),
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
            child: Column(
              children: [
                Text('Follow for more', textAlign: TextAlign.center, style: _wide(38, color: _accent, weight: 650, width: 104)),
                const SizedBox(height: 14),
                Text('Instagram  @practical.overkill', textAlign: TextAlign.center, style: _wide(30, color: _fg, weight: 550, width: 100)),
                const SizedBox(height: 8),
                Text('YouTube  @PracticalOverkill', textAlign: TextAlign.center, style: _wide(30, color: _fg, weight: 550, width: 100)),
              ],
            ),
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


/// A generic instrument-display housing around the 1280x768 dash: a dark
/// bezel, a lit top edge and a faint glass sheen.
class DisplayHousing extends StatelessWidget {
  const DisplayHousing({super.key, required this.screenWidth, required this.child});

  final double screenWidth;
  final Widget child;

  static double _pad(double w) => w * 0.032;

  static Size sizeFor(double screenWidth) {
    final pad = _pad(screenWidth);
    return Size(screenWidth + 2 * pad, screenWidth * 0.6 + 2 * pad * 1.15);
  }

  @override
  Widget build(BuildContext context) {
    final pad = _pad(screenWidth);
    final size = sizeFor(screenWidth);
    final r = pad * 1.5;
    return SizedBox.fromSize(
      size: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(r),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF2A2E35), Color(0xFF15171B), Color(0xFF0E1013)],
            stops: [0, 0.35, 1],
          ),
          border: Border.all(color: const Color(0xFF3B4048), width: 1.5),
          boxShadow: const [
            BoxShadow(color: Color(0xCC000000), blurRadius: 60, offset: Offset(0, 30)),
            BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2)),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: pad, vertical: pad * 1.15),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(r * 0.35),
            child: Stack(
              fit: StackFit.expand,
              children: [
                FittedBox(child: SizedBox(width: 1280, height: 768, child: child)),
                const IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment(0.2, 0.3),
                        colors: [Color(0x14FFFFFF), Color(0x00FFFFFF)],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The stalk the display sits on, fading into the background.
class _Mount extends StatelessWidget {
  const _Mount();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      height: 200,
      child: ShaderMask(
        shaderCallback: (r) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFFFFF), Color(0x00FFFFFF)],
        ).createShader(r),
        blendMode: BlendMode.dstIn,
        child: CustomPaint(painter: _MountPainter()),
      ),
    );
  }
}

class _MountPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final path = Path()
      ..moveTo(w * 0.18, 0)
      ..lineTo(w * 0.82, 0)
      ..lineTo(w * 0.66, size.height)
      ..lineTo(w * 0.34, size.height)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFF14161A), Color(0xFF262A30), Color(0xFF14161A)],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(_MountPainter oldDelegate) => false;
}


/// Width over height of the filmed phone screen, with its housing.
const phoneAspect = 1080 / 2340 * 1.0;

/// A plain phone around the companion's frames: black body, a punch-hole
/// camera, a drawn status bar, and a dot where the finger lands.
class PhoneHousing extends StatelessWidget {
  const PhoneHousing({super.key, required this.state});

  final FrameState state;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth, h = box.maxHeight;
      final bezel = w * 0.028;
      final screenW = w - 2 * bezel, screenH = h - 2 * bezel;
      final k = screenW / 1080;
      return DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF050607),
          borderRadius: BorderRadius.circular(w * 0.13),
          border: Border.all(color: const Color(0xFF30343B), width: 2),
          boxShadow: const [BoxShadow(color: Color(0xCC000000), blurRadius: 60, offset: Offset(0, 30))],
        ),
        child: Padding(
          padding: EdgeInsets.all(bezel),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(w * 0.105),
            child: Stack(
              children: [
                if (state.phone != null)
                  Positioned.fill(child: RawImage(image: state.phone, fit: BoxFit.fill, filterQuality: FilterQuality.medium)),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: 63 * k,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 44 * k),
                    child: Row(
                      children: [
                        Text('10:24', style: _wide(30 * k, weight: 600, width: 100)),
                        const Spacer(),
                        Icon(Icons.wifi, size: 34 * k, color: _fg),
                        SizedBox(width: 8 * k),
                        Icon(Icons.battery_full, size: 34 * k, color: _fg),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: screenW / 2 - 14 * k,
                  top: 18 * k,
                  width: 28 * k,
                  height: 28 * k,
                  child: const DecoratedBox(decoration: BoxDecoration(color: Color(0xFF000000), shape: BoxShape.circle)),
                ),
                if (state.tap != null)
                  Positioned(
                    left: state.tap!.dx * k - 60 * k,
                    top: state.tap!.dy * k * (screenH / (2340 * k)) - 60 * k,
                    width: 120 * k,
                    height: 120 * k,
                    child: Opacity(
                      opacity: (1 - state.tapAge).clamp(0.0, 1.0) * 0.55,
                      child: Transform.scale(
                        scale: 0.6 + 0.6 * state.tapAge,
                        child: const DecoratedBox(decoration: BoxDecoration(color: Color(0xFFFFFFFF), shape: BoxShape.circle)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

/// The landscape install scene: the phone on the left, the steps on the right.
class _InstallScene extends StatelessWidget {
  const _InstallScene(this.s);
  final FrameState s;

  @override
  Widget build(BuildContext context) {
    final scene = s.scene;
    const phoneH = 960.0;
    return Opacity(
      opacity: s.edge(14),
      child: Stack(
        children: [
          Positioned(left: 330, top: 60, height: phoneH, width: phoneH * phoneAspect, child: PhoneHousing(state: s)),
          Positioned(
            left: 900,
            right: 120,
            top: 0,
            bottom: 0,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(scene.title, style: _wide(62, weight: 750, width: 110)),
                const SizedBox(height: 14),
                Text(scene.subtitle!, style: _wide(28, color: _muted, weight: 450, width: 100)),
                const SizedBox(height: 56),
                for (var i = 0; i < scene.words.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 30),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 54,
                          height: 54,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i < s.step ? _accent : const Color(0x00000000),
                              border: Border.all(color: i <= s.step ? _accent : _muted.withValues(alpha: 0.5), width: 2.5),
                            ),
                            child: Center(
                              child: i < s.step
                                  ? const Icon(Icons.check_rounded, size: 32, color: _ink)
                                  : Text('${i + 1}', style: _wide(24, color: i == s.step ? _accent : _muted, weight: 700, width: 100)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 26),
                        Expanded(
                          child: Text(
                            scene.words[i],
                            style: _wide(32, color: i == s.step ? _fg : i < s.step ? _fg.withValues(alpha: 0.75) : _muted.withValues(alpha: 0.6), weight: i == s.step ? 650 : 500, width: 100),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    const QrTile(url: companionUrl, size: 150),
                    const SizedBox(width: 28),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Scan to get OpenDash Companion', style: _wide(26, weight: 600, width: 100)),
                          const SizedBox(height: 8),
                          Text('github.com/abhijithvijayan/opendash-companion', style: _wide(22, color: _accent, weight: 550, width: 100)),
                          const SizedBox(height: 12),
                          Text(scene.footnote!, style: _wide(19, color: _muted.withValues(alpha: 0.85), weight: 400, width: 100)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
