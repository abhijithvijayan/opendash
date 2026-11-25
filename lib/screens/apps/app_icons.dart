import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../models/app_catalog.dart';

class AppIcon extends StatelessWidget {
  const AppIcon({super.key, required this.appId, required this.color, this.size = 64});
  final String appId;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _AppIconPainter(appId, color));
}

class _AppIconPainter extends CustomPainter {
  _AppIconPainter(this.appId, this.color);
  final String appId;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.06
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color;

    switch (appId) {
      case 'android-auto':
        final c = Offset(w * 0.42, h * 0.5);
        canvas.drawCircle(c, w * 0.3, stroke);
        canvas.drawCircle(c, w * 0.08, fill);
        for (final a in [0.0, 2.094, 4.189]) {
          canvas.drawLine(c, Offset(c.dx + w * 0.3 * math.cos(a - 1.571), c.dy + w * 0.3 * math.sin(a - 1.571)), stroke);
        }
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.7, h * 0.3, w * 0.22, h * 0.42), Radius.circular(w * 0.04)),
          stroke,
        );
      case 'carplay':
        // Steering wheel outline with phone screen inside.
        final cx = w * 0.5, cy = h * 0.5;
        canvas.drawCircle(Offset(cx, cy), w * 0.36, stroke);
        canvas.drawCircle(Offset(cx, cy), w * 0.1, stroke);
        // Spokes at 8, 4, and 6 o'clock.
        for (final angle in [-2.356, -0.785, 1.571]) {
          final inner = w * 0.1;
          final outer = w * 0.36;
          canvas.drawLine(
            Offset(cx + inner * math.cos(angle), cy + inner * math.sin(angle)),
            Offset(cx + outer * math.cos(angle), cy + outer * math.sin(angle)),
            stroke,
          );
        }
      case 'android-settings':
        // A gear: eight teeth around a ring.
        final c = Offset(w * 0.5, h * 0.5);
        final teeth = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = w * 0.13
          ..strokeCap = StrokeCap.butt;
        for (var i = 0; i < 8; i++) {
          final a = i * math.pi / 4;
          canvas.drawLine(
            Offset(c.dx + w * 0.27 * math.cos(a), c.dy + w * 0.27 * math.sin(a)),
            Offset(c.dx + w * 0.4 * math.cos(a), c.dy + w * 0.4 * math.sin(a)),
            teeth,
          );
        }
        canvas.drawCircle(c, w * 0.26, stroke);
        canvas.drawCircle(c, w * 0.09, stroke);
      case 'browser':
        // A globe: outline, equator and one meridian.
        final c = Offset(w * 0.5, h * 0.5);
        canvas.drawCircle(c, w * 0.38, stroke);
        canvas.drawLine(Offset(w * 0.12, h * 0.5), Offset(w * 0.88, h * 0.5), stroke);
        canvas.drawOval(Rect.fromCenter(center: c, width: w * 0.34, height: w * 0.76), stroke);
      case 'maps':
        // A map pin.
        final pin = Path()
          ..moveTo(w * 0.5, h * 0.92)
          ..cubicTo(w * 0.2, h * 0.6, w * 0.18, h * 0.45, w * 0.18, h * 0.38)
          ..arcToPoint(Offset(w * 0.82, h * 0.38), radius: Radius.circular(w * 0.32))
          ..cubicTo(w * 0.82, h * 0.45, w * 0.8, h * 0.6, w * 0.5, h * 0.92)
          ..close();
        canvas.drawPath(pin, stroke);
        canvas.drawCircle(Offset(w * 0.5, h * 0.38), w * 0.1, stroke);
      case 'newpipe':
        // A screen with a play triangle.
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.1, h * 0.2, w * 0.8, h * 0.6), Radius.circular(w * 0.1)),
          stroke,
        );
        canvas.drawPath(
          Path()
            ..moveTo(w * 0.42, h * 0.36)
            ..lineTo(w * 0.64, h * 0.5)
            ..lineTo(w * 0.42, h * 0.64)
            ..close(),
          fill,
        );
      case 'file-manager':
        final folder = Path()
          ..moveTo(w * 0.1, h * 0.28)
          ..lineTo(w * 0.38, h * 0.28)
          ..lineTo(w * 0.46, h * 0.38)
          ..lineTo(w * 0.9, h * 0.38)
          ..lineTo(w * 0.9, h * 0.78)
          ..lineTo(w * 0.1, h * 0.78)
          ..close();
        canvas.drawPath(folder, stroke);
      case 'terminal':
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.08, h * 0.18, w * 0.84, h * 0.64), Radius.circular(w * 0.06)),
          stroke,
        );
        final prompt = Path()
          ..moveTo(w * 0.24, h * 0.38)
          ..lineTo(w * 0.38, h * 0.5)
          ..lineTo(w * 0.24, h * 0.62);
        canvas.drawPath(prompt, stroke);
        canvas.drawLine(Offset(w * 0.46, h * 0.62), Offset(w * 0.66, h * 0.62), stroke);
      case CatalogApp.otaShieldId:
        final shield = Path()
          ..moveTo(w * 0.5, h * 0.1)
          ..lineTo(w * 0.84, h * 0.24)
          ..cubicTo(w * 0.84, h * 0.58, w * 0.7, h * 0.78, w * 0.5, h * 0.9)
          ..cubicTo(w * 0.3, h * 0.78, w * 0.16, h * 0.58, w * 0.16, h * 0.24)
          ..close();
        canvas.drawPath(shield, stroke);
        final arrow = Path()
          ..moveTo(w * 0.5, h * 0.66)
          ..lineTo(w * 0.5, h * 0.32)
          ..moveTo(w * 0.38, h * 0.44)
          ..lineTo(w * 0.5, h * 0.32)
          ..lineTo(w * 0.62, h * 0.44);
        canvas.drawPath(arrow, stroke);
        canvas.drawLine(Offset(w * 0.34, h * 0.66), Offset(w * 0.66, h * 0.36), stroke);
      case CatalogApp.stockDashboardId:
        final house = Path()
          ..moveTo(w * 0.12, h * 0.5)
          ..lineTo(w * 0.5, h * 0.16)
          ..lineTo(w * 0.88, h * 0.5)
          ..moveTo(w * 0.22, h * 0.42)
          ..lineTo(w * 0.22, h * 0.84)
          ..lineTo(w * 0.78, h * 0.84)
          ..lineTo(w * 0.78, h * 0.42);
        canvas.drawPath(house, stroke);
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.42, h * 0.6, w * 0.16, h * 0.24), Radius.circular(w * 0.03)),
          stroke,
        );
    }
  }

  @override
  bool shouldRepaint(_AppIconPainter old) => old.appId != appId || old.color != color;
}
