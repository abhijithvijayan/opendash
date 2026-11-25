import 'dart:math' as math;
import 'dart:ui';

double deg(double degrees) => degrees * math.pi / 180;

Offset onArc(Offset center, double radius, double angle) =>
    Offset(center.dx + radius * math.cos(angle), center.dy + radius * math.sin(angle));

/// A thick accent stroke with a soft halo built from two wider, fainter
/// strokes. Costs three arc draws and no blur pass.
void drawGlowArc(
  Canvas canvas,
  Rect rect,
  double start,
  double sweep,
  Color color,
  double width, {
  double glow = 1.0,
}) {
  if (sweep <= 0) return;
  final halo = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  canvas.drawArc(rect, start, sweep, false,
      halo..strokeWidth = width * 3.4..color = color.withValues(alpha: 0.07 * glow));
  canvas.drawArc(rect, start, sweep, false,
      halo..strokeWidth = width * 2.0..color = color.withValues(alpha: 0.16 * glow));
  canvas.drawArc(
    rect,
    start,
    sweep,
    false,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = color
      ..strokeCap = StrokeCap.butt,
  );
}
