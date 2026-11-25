import 'dart:math' as math;

import 'package:flutter/widgets.dart';

enum TripGlyph { route, topSpeed, average, regen, energy }

/// Drawn glyphs for the trip stats rows, so the widget panel carries no
/// Material icons.
class TripStatIcon extends StatelessWidget {
  const TripStatIcon({super.key, required this.glyph, required this.color, this.size = 22});
  final TripGlyph glyph;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _TripGlyphPainter(glyph, color));
}

class _TripGlyphPainter extends CustomPainter {
  _TripGlyphPainter(this.glyph, this.color);
  final TripGlyph glyph;
  final Color color;

  Paint get _stroke => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.2
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  @override
  void paint(Canvas c, Size s) {
    final w = s.width, h = s.height;
    switch (glyph) {
      case TripGlyph.route:
        // Winding road: two pins joined by an S-curve.
        final path = Path()
          ..moveTo(w * 0.2, h * 0.22)
          ..cubicTo(w * 0.95, h * 0.22, w * 0.05, h * 0.78, w * 0.8, h * 0.78);
        c.drawPath(path, _stroke);
        c.drawCircle(Offset(w * 0.2, h * 0.22), 3, Paint()..color = color);
        c.drawCircle(Offset(w * 0.8, h * 0.78), 3, Paint()..color = color);
      case TripGlyph.topSpeed:
        // Small dial with its needle pinned at the top of the scale.
        final rect = Rect.fromLTWH(2, h * 0.14, w - 4, h - 4);
        c.drawArc(rect, math.pi * 0.85, math.pi * 1.3, false, _stroke);
        final centre = rect.center;
        final tip = Offset(centre.dx + w * 0.28, centre.dy - h * 0.26);
        c.drawLine(centre, tip, _stroke..strokeWidth = 2.6);
        c.drawCircle(centre, 2.2, Paint()..color = color);
      case TripGlyph.average:
        // Rolling trend line with its mean marked.
        final path = Path()
          ..moveTo(w * 0.08, h * 0.7)
          ..lineTo(w * 0.34, h * 0.4)
          ..lineTo(w * 0.56, h * 0.6)
          ..lineTo(w * 0.92, h * 0.26);
        c.drawPath(path, _stroke);
        c.drawLine(Offset(w * 0.08, h * 0.88), Offset(w * 0.92, h * 0.88), _stroke..strokeWidth = 1.6);
      case TripGlyph.regen:
      case TripGlyph.energy:
        final bolt = Path()
          ..moveTo(w * 0.58, h * 0.06)
          ..lineTo(w * 0.24, h * 0.56)
          ..lineTo(w * 0.5, h * 0.56)
          ..lineTo(w * 0.42, h * 0.94)
          ..lineTo(w * 0.78, h * 0.42)
          ..lineTo(w * 0.52, h * 0.42)
          ..close();
        c.drawPath(bolt, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_TripGlyphPainter old) => old.glyph != glyph || old.color != color;
}
