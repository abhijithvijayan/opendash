import 'package:flutter/widgets.dart';

import '../../theme/dash_theme.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';
import 'arc_paint.dart';

const _startAngle = 120.0;
const _sweepAngle = 300.0;

class BatteryRing extends StatelessWidget {
  const BatteryRing({
    super.key,
    required this.soc,
    required this.accent,
    this.diameter = 260,
    this.stroke = 8,
    this.glow = 1.0,
    this.valueStyle,
    this.unitStyle,
    this.theme = DashTheme.dark,
    this.glowAnimation,
    this.glowOf,
  });

  /// Null while the vehicle has not reported it: empty ring and '—'.
  final int? soc;
  final Color accent;
  final double diameter;
  final double stroke;
  final double glow;
  final TextStyle? valueStyle;
  final TextStyle? unitStyle;
  final DashTheme theme;

  /// Optional driver for a breathing glow: the painter listens to
  /// [glowAnimation] and reads [glowOf] each repaint, so the numeral and
  /// the rest of the widget tree never rebuild per frame.
  final Listenable? glowAnimation;
  final double Function()? glowOf;

  @override
  Widget build(BuildContext context) {
    final soc = this.soc;
    final fill = soc == null
        ? theme.slate
        : soc < 10
            ? theme.critical
            : soc <= 20
                ? theme.warning
                : accent;
    return SizedBox(
      width: diameter,
      height: diameter,
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: fill),
        duration: DashMotion.slow,
        builder: (context, color, _) => TweenAnimationBuilder<double>(
          tween: Tween(end: (soc ?? 0).toDouble()),
          duration: DashMotion.value,
          curve: Curves.easeInOutCubic,
          builder: (context, value, _) {
            return Stack(
              children: [
                RepaintBoundary(
                  child: CustomPaint(
                    size: Size.square(diameter),
                    painter: _RingPainter(
                      value,
                      color!,
                      stroke,
                      glow * theme.glowScale,
                      theme.slate,
                      glowOf: glowOf == null ? null : () => glowOf!() * theme.glowScale,
                      repaint: glowAnimation,
                    ),
                  ),
                ),
                Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(soc == null ? '—' : value.round().toString(), style: (valueStyle ?? DashText.soc).copyWith(color: theme.bone)),
                        const SizedBox(width: 2),
                        Text('%', style: (unitStyle ?? DashText.socUnit).copyWith(color: theme.ash)),
                      ],
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

class _RingPainter extends CustomPainter {
  _RingPainter(this.soc, this.color, this.stroke, this.glow, this.track, {this.glowOf, super.repaint});
  final double soc;
  final Color color;
  final double stroke;
  final double glow;
  final Color track;
  final double Function()? glowOf;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - stroke * 2;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawArc(
      rect,
      deg(_startAngle),
      deg(_sweepAngle),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = track,
    );
    drawGlowArc(
      canvas,
      rect,
      deg(_startAngle),
      deg(soc.clamp(0, 100) / 100 * _sweepAngle),
      color,
      stroke,
      glow: glowOf?.call() ?? glow,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.soc != soc || old.color != color || old.glow != glow || old.stroke != stroke || old.track != track;
}
