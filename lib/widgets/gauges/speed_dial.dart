import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../state/format_settings.dart';
import '../../theme/dash_theme.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';
import 'arc_paint.dart';

const _maxScale = 120.0;
const _startAngle = 150.0;
const _sweepAngle = 240.0;

/// What stands in the middle of the dial in place of the speed, where the
/// speed says nothing: a 0 reads the same parked (throttle dead), held on a
/// slope and ready to go.
enum DialMark {
  /// Parked: the throttle does nothing.
  park('P'),

  /// Reverse. The scooter moves, so the speed stays, small, underneath.
  reverse('R'),

  /// Stopped and held by hill hold, throttle live.
  hillHold('H');

  const DialMark(this.letter);
  final String letter;
}

/// 680x560. Dial centre at (340, 340), radius 280. The opening at the bottom
/// is left free for the power bar.
class SpeedDial extends StatefulWidget {
  const SpeedDial({
    super.key,
    required this.speed,
    required this.accent,
    this.glow = 1.0,
    this.theme = DashTheme.dark,
    this.useMiles = false,
    this.stale = false,
    this.mark,
    this.cruiseSet,
  });

  final int speed;
  final Color accent;
  final double glow;
  final DashTheme theme;

  /// Numeral and scale in mph; [speed] stays km/h.
  final bool useMiles;

  /// The vehicle stopped reporting: a frozen number would read as live.
  final bool stale;

  /// A letter in place of the number; null shows the speed.
  final DialMark? mark;

  /// The speed cruise control is holding, in km/h, marked on the arc while
  /// it is active: above or below it is read at a glance, and the number
  /// stays the speed.
  final int? cruiseSet;

  static const size = Size(680, 560);
  static const center = Offset(340, 340);
  static const radius = 280.0;

  @override
  State<SpeedDial> createState() => _SpeedDialState();
}

class _SpeedDialState extends State<SpeedDial> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void didUpdateWidget(SpeedDial old) {
    super.didUpdateWidget(old);
    if (old.accent != widget.accent) _pulse.forward(from: 0);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.fromSize(
      size: SpeedDial.size,
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: widget.accent),
        duration: DashMotion.slow,
        curve: Curves.easeOut,
        builder: (context, accent, _) {
          return TweenAnimationBuilder<double>(
            tween: Tween(end: widget.speed.toDouble()),
            duration: DashMotion.gauge,
            curve: Curves.easeOutCubic,
            builder: (context, speed, _) {
              return Stack(
                children: [
                  RepaintBoundary(
                    child: CustomPaint(size: SpeedDial.size, painter: _TrackPainter(widget.theme, widget.useMiles, widget.cruiseSet)),
                  ),
                  AnimatedBuilder(
                    animation: _pulse,
                    builder: (context, _) {
                      final pulse = 1 + (1 - _pulse.value) * (_pulse.isAnimating ? 1.2 : 0);
                      return CustomPaint(
                        size: SpeedDial.size,
                        painter: _FillPainter(speed, accent!, widget.glow * pulse * widget.theme.glowScale, widget.theme),
                      );
                    },
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: SpeedDial.center.dy - 128,
                    child: _centre(speed, accent!),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

double _angleFor(double value) => deg(_startAngle + value / _maxScale * _sweepAngle);

extension on _SpeedDialState {
  /// The number, or the letter for [SpeedDial.mark]. No fade between the
  /// two: moving off, the speed has to be there at once.
  Widget _centre(double speed, Color accent) {
    final theme = widget.theme;
    final mark = widget.stale ? null : widget.mark;
    final shown = toDisplayDistance(speed.round(), widget.useMiles);
    final unit = speedUnit(widget.useMiles);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (mark == null)
          Text(
            widget.stale ? '—' : '$shown',
            key: const ValueKey('speed-numeral'),
            // Green while cruise holds the speed: the arc keeps the drive
            // mode's colour, which has to stay readable on a ride.
            style: DashText.speed.copyWith(
              color: widget.stale
                  ? theme.ash
                  : widget.cruiseSet != null
                      ? theme.eco
                      : theme.bone,
            ),
            textAlign: TextAlign.center,
          )
        else
          Text(
            mark.letter,
            key: ValueKey('dial-mark-${mark.name}'),
            style: DashText.speed.copyWith(
              color: switch (mark) {
                DialMark.park => theme.ash,
                DialMark.reverse => theme.warning,
                DialMark.hillHold => accent,
              },
            ),
            textAlign: TextAlign.center,
          ),
        const SizedBox(height: 2),
        // A unit under a letter that is not a speed would be wrong; the
        // line keeps its height so nothing moves when the number returns.
        Text(
          switch (mark) { null => unit, DialMark.reverse => '$shown $unit', _ => ' ' },
          key: const ValueKey('speed-unit'),
          style: DashText.caption(22, color: mark == DialMark.reverse ? theme.bone : theme.ash),
        ),
      ],
    );
  }
}

/// The radius at which every numeral's *inner* edge (the edge facing the
/// dial centre) sits, so the gap from the tick is the same for all of them.
/// Placing their centres at one radius instead looked uneven: a wide "100"
/// or "120" on the side had its half-width eat the gap (tight), while a
/// narrow "0" at the bottom had a big one. The major tick ends at
/// `radius + 26`, so this is a ~6px gap.
const numeralInnerRadius = SpeedDial.radius + 32;

/// Where the rightmost numeral's right edge may reach: the panel's content
/// (its left at dial-x 700 once the panel is nudged right), not its
/// background. The test keeps numerals clear of this.
const numeralMaxRight = 700.0;

/// Centre for a numeral of [textSize], placed so its box edge toward the
/// dial centre lands on [numeralInnerRadius] whatever the angle or digit
/// count. The box's reach along the outward radial is its half-width times
/// |cos| plus its half-height times |sin|.
Offset scaleNumeralCenter(double value, Size textSize) {
  final a = _angleFor(value);
  final inset = (textSize.width / 2) * math.cos(a).abs() + (textSize.height / 2) * math.sin(a).abs();
  return onArc(SpeedDial.center, numeralInnerRadius + inset, a);
}

class _TrackPainter extends CustomPainter {
  const _TrackPainter(this.theme, this.useMiles, this.cruiseSet);
  final DashTheme theme;
  final bool useMiles;
  final int? cruiseSet;

  @override
  void paint(Canvas canvas, Size size) {
    const c = SpeedDial.center;
    const r = SpeedDial.radius;

    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [theme.inkLift, theme.ink],
          stops: const [0.2, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      deg(_startAngle),
      deg(_sweepAngle),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = theme.slate,
    );

    final minor = Paint()..color = theme.slate..strokeWidth = 1.5;
    final major = Paint()..color = theme.ash..strokeWidth = 2;
    // Ticks every 5 of the display unit; in mph the dial runs to 70, which
    // sits just inside the 120 km/h scale.
    final ticks = useMiles ? 14 : 24;
    for (var i = 0; i <= ticks; i++) {
      final v = i * 5;
      final kmh = useMiles ? v * kmPerMile : v.toDouble();
      final a = _angleFor(kmh);
      final isMajor = v % (useMiles ? 10 : 20) == 0;
      final inner = onArc(c, r + (isMajor ? 10 : 12), a);
      final outer = onArc(c, r + (isMajor ? 26 : 18), a);
      canvas.drawLine(inner, outer, isMajor ? major : minor);
      if (isMajor) {
        final tp = TextPainter(
          text: TextSpan(text: '$v', style: DashText.scale.copyWith(color: theme.ash)),
          textDirection: TextDirection.ltr,
        )..layout();
        final p = scaleNumeralCenter(kmh, tp.size);
        tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
      }
    }

    final set = cruiseSet;
    if (set != null) {
      // A wedge inside the arc, pointing at the set speed. White, since the
      // arc is green while cruise is active; a wedge and nothing across the
      // arc, so it is never taken for the needle, which is a line across it.
      final a = _angleFor(set.clamp(0, _maxScale).toDouble());
      final tip = onArc(c, r - 18, a);
      final back = onArc(c, r - 54, a);
      final across = Offset(-math.sin(a), math.cos(a)) * 17;
      canvas.drawPath(
        Path()
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(back.dx + across.dx, back.dy + across.dy)
          ..lineTo(back.dx - across.dx, back.dy - across.dy)
          ..close(),
        Paint()..color = theme.bone,
      );
    }
  }

  @override
  bool shouldRepaint(_TrackPainter old) => old.theme != theme || old.useMiles != useMiles || old.cruiseSet != cruiseSet;
}

// Built once per (accent, glow) rather than every speed frame.
Shader? _glowShader;
Color? _glowAccent;
double? _glowAlpha;

Shader _innerGlow(Color accent, double alpha, Rect rect) {
  if (_glowShader == null || _glowAccent != accent || _glowAlpha != alpha) {
    _glowAccent = accent;
    _glowAlpha = alpha;
    _glowShader = RadialGradient(
      colors: [accent.withValues(alpha: 0.0), accent.withValues(alpha: alpha)],
      stops: const [0.6, 1.0],
    ).createShader(rect);
  }
  return _glowShader!;
}

class _FillPainter extends CustomPainter {
  _FillPainter(this.speed, this.accent, this.glow, this.theme);
  final double speed;
  final Color accent;
  final double glow;
  final DashTheme theme;

  @override
  void paint(Canvas canvas, Size size) {
    const c = SpeedDial.center;
    const r = SpeedDial.radius;
    final rect = Rect.fromCircle(center: c, radius: r);
    final sweep = deg(speed.clamp(0, _maxScale) / _maxScale * _sweepAngle);

    canvas.drawCircle(c, r - 8, Paint()..shader = _innerGlow(accent, 0.05 * glow, rect));

    drawGlowArc(canvas, rect, deg(_startAngle), sweep, accent, 12, glow: glow);

    final a = _angleFor(speed.clamp(0, _maxScale));
    canvas.drawLine(
      onArc(c, r - 14, a),
      onArc(c, r + 14, a),
      Paint()
        ..color = theme.bone
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_FillPainter old) =>
      old.speed != speed || old.accent != accent || old.glow != glow || old.theme != theme;
}
