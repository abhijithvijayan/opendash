import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../theme/colors.dart';

Color _tone(bool on) => on ? DashColors.bone : DashColors.ash.withValues(alpha: 0.45);

/// The unlit part of a signal, Wi-Fi or battery glyph: the same shape, faint,
/// as on a phone's status bar.
Color _faint(Color c) => c.withValues(alpha: 0.3);

class SignalIcon extends StatelessWidget {
  const SignalIcon({super.key, required this.bars});
  final int bars;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(26, 20), painter: _SignalPainter(bars));
}

class _SignalPainter extends CustomPainter {
  _SignalPainter(this.bars);
  final int bars;

  @override
  void paint(Canvas canvas, Size size) {
    const n = 4;
    const gap = 2.5;
    final w = (size.width - (n - 1) * gap) / n;
    for (var i = 0; i < n; i++) {
      final h = size.height * (0.4 + 0.6 * i / (n - 1));
      final rect = Rect.fromLTWH(i * (w + gap), size.height - h, w, h);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1.6)),
        Paint()..color = i < bars ? DashColors.bone : _faint(DashColors.bone),
      );
    }
  }

  @override
  bool shouldRepaint(_SignalPainter old) => old.bars != bars;
}

class WifiIcon extends StatelessWidget {
  const WifiIcon({super.key, required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(26, 20), painter: _WifiPainter(on));
}

class _WifiPainter extends CustomPainter {
  _WifiPainter(this.on);
  final bool on;

  @override
  void paint(Canvas canvas, Size size) {
    // A quarter-circle fan: a wedge at the foot and two bands above it.
    final c = Offset(size.width / 2, size.height - 0.5);
    final color = on ? DashColors.bone : _faint(DashColors.bone);
    const start = math.pi * 1.25;
    const sweep = math.pi * 0.5;
    canvas.drawArc(Rect.fromCircle(center: c, radius: 5.2), start, sweep, true, Paint()..color = color);
    final band = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.6;
    for (final r in [9.6, 15.8]) {
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), start, sweep, false, band);
    }
  }

  @override
  bool shouldRepaint(_WifiPainter old) => old.on != on;
}

class BluetoothIcon extends StatelessWidget {
  const BluetoothIcon({super.key, required this.on, this.dot, this.color, this.size = 22});
  final bool on;
  final double size;

  /// Small status dot at the bottom-right: music or call.
  final Color? dot;
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size(size * 14 / 22, size), painter: _BtPainter(on, dot, color));
}

class _BtPainter extends CustomPainter {
  _BtPainter(this.on, this.dot, this.color);
  final bool on;
  final Color? dot;
  final Color? color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(w * 0.15, h * 0.28)
      ..lineTo(w * 0.85, h * 0.72)
      ..lineTo(w * 0.5, h)
      ..lineTo(w * 0.5, 0)
      ..lineTo(w * 0.85, h * 0.28)
      ..lineTo(w * 0.15, h * 0.72);
    canvas.drawPath(
      path,
      Paint()
        ..color = color ?? _tone(on)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.height / 10
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    if (dot != null) {
      canvas.drawCircle(Offset(w + 1, h - 1), 4.5, Paint()..color = DashColors.ink);
      canvas.drawCircle(Offset(w + 1, h - 1), 3, Paint()..color = dot!);
    }
  }

  @override
  bool shouldRepaint(_BtPainter old) => old.on != on || old.dot != dot || old.color != color;
}

class GpsIcon extends StatelessWidget {
  const GpsIcon({super.key, required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(22, 22), painter: _GpsPainter(on));
}

class _GpsPainter extends CustomPainter {
  _GpsPainter(this.on);
  final bool on;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(w * 0.5, 0)
      ..lineTo(w, h)
      ..lineTo(w * 0.5, h * 0.72)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(path, Paint()..color = _tone(on));
  }

  @override
  bool shouldRepaint(_GpsPainter old) => old.on != on;
}

class BellIcon extends StatelessWidget {
  const BellIcon({super.key, required this.badge});
  final bool badge;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(22, 24), painter: _BellPainter(badge));
}

class _BellPainter extends CustomPainter {
  _BellPainter(this.badge);
  final bool badge;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final body = Path()
      ..moveTo(w * 0.5, h * 0.05)
      ..arcToPoint(Offset(w * 0.18, h * 0.42), radius: Radius.circular(w * 0.36), clockwise: false)
      ..lineTo(w * 0.18, h * 0.66)
      ..lineTo(w * 0.05, h * 0.82)
      ..lineTo(w * 0.95, h * 0.82)
      ..lineTo(w * 0.82, h * 0.66)
      ..lineTo(w * 0.82, h * 0.42)
      ..arcToPoint(Offset(w * 0.5, h * 0.05), radius: Radius.circular(w * 0.36), clockwise: false)
      ..close();
    final color = _tone(badge);
    canvas.drawPath(body, Paint()..color = color);
    canvas.drawCircle(Offset(w * 0.5, h * 0.92), 2.2, Paint()..color = color);
    if (badge) {
      canvas.drawCircle(Offset(w * 0.86, h * 0.14), 5, Paint()..color = DashColors.ink);
      canvas.drawCircle(Offset(w * 0.86, h * 0.14), 3.4, Paint()..color = DashColors.warning);
    }
  }

  @override
  bool shouldRepaint(_BellPainter old) => old.badge != badge;
}

/// Seat with the lid up. Only shown once the trunk state is actually known.
class TrunkOpenIcon extends StatelessWidget {
  const TrunkOpenIcon({super.key, this.color});
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(30, 22), painter: _TrunkPainter(color ?? DashColors.warning));
}

class _TrunkPainter extends CustomPainter {
  const _TrunkPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(1, h * 0.5, w - 2, h * 0.45), Radius.circular(3)),
      paint,
    );
    canvas.drawLine(Offset(w * 0.12, h * 0.5), Offset(w * 0.72, 1), paint);
  }

  @override
  bool shouldRepaint(_TrunkPainter old) => old.color != color;
}

/// Four squares: the app launcher.
class AppsIcon extends StatelessWidget {
  const AppsIcon({super.key, this.color, this.size = 18});
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _AppsPainter(color ?? DashColors.ash));
}

class _AppsPainter extends CustomPainter {
  _AppsPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = (size.width - 4) / 2;
    final paint = Paint()..color = color;
    for (final (x, y) in [(0.0, 0.0), (s + 4, 0.0), (0.0, s + 4), (s + 4, s + 4)]) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, s, s), const Radius.circular(2)), paint);
    }
  }

  @override
  bool shouldRepaint(_AppsPainter old) => old.color != color;
}

/// Small thermometer for the battery temperature warning.
class ThermometerIcon extends StatelessWidget {
  const ThermometerIcon({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(16, 16), painter: _ThermometerPainter(color));
}

class _ThermometerPainter extends CustomPainter {
  _ThermometerPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.36, 1, w * 0.28, h * 0.6), Radius.circular(w * 0.14)),
      stroke,
    );
    canvas.drawCircle(Offset(w / 2, h * 0.76), w * 0.22, Paint()..color = color);
    canvas.drawLine(Offset(w / 2, h * 0.3), Offset(w / 2, h * 0.7), Paint()..color = color..strokeWidth = 2.4);
  }

  @override
  bool shouldRepaint(_ThermometerPainter old) => old.color != color;
}

/// Eight-tooth gear for the settings entry.
/// Service-due wrench, the same 16px footprint as the thermometer.
class WrenchIcon extends StatelessWidget {
  const WrenchIcon({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(16, 16), painter: _WrenchPainter(color));
}

class _WrenchPainter extends CustomPainter {
  _WrenchPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    // Handle from bottom-left up to the head.
    canvas.drawLine(Offset(w * 0.18, h * 0.82), Offset(w * 0.58, h * 0.42), stroke);
    // Open-ended head: an arc with a notch.
    final head = Rect.fromCircle(center: Offset(w * 0.68, h * 0.32), radius: w * 0.24);
    canvas.drawArc(head, -math.pi * 0.15, math.pi * 1.55, false, stroke);
  }

  @override
  bool shouldRepaint(_WrenchPainter old) => old.color != color;
}

class GearIcon extends StatelessWidget {
  const GearIcon({super.key, this.color, this.size = 22});
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _GearPainter(color ?? DashColors.ash));
}

class _GearPainter extends CustomPainter {
  _GearPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final outer = size.width / 2;
    final inner = outer * 0.72;
    final path = Path();
    const teeth = 8;
    for (var i = 0; i < teeth * 2; i++) {
      final r = i.isEven ? outer : inner;
      final a0 = (i / (teeth * 2)) * math.pi * 2 - math.pi / 2;
      final a1 = ((i + 0.55) / (teeth * 2)) * math.pi * 2 - math.pi / 2;
      final p0 = Offset(c.dx + math.cos(a0) * r, c.dy + math.sin(a0) * r);
      final p1 = Offset(c.dx + math.cos(a1) * r, c.dy + math.sin(a1) * r);
      if (i == 0) path.moveTo(p0.dx, p0.dy);
      path.lineTo(p0.dx, p0.dy);
      path.lineTo(p1.dx, p1.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
    canvas.drawCircle(c, outer * 0.3, Paint()..color = color..blendMode = BlendMode.clear);
  }

  @override
  bool shouldRepaint(_GearPainter old) => old.color != color;
}

/// Battery with an exclamation mark for cell health warnings.
class CellWarningIcon extends StatelessWidget {
  const CellWarningIcon({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(16, 16), painter: _CellWarningPainter(color));
}

class _CellWarningPainter extends CustomPainter {
  _CellWarningPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final capW = w * 0.14;
    final body = Rect.fromLTWH(0.8, h * 0.15, w - capW - 1.6, h * 0.7);
    canvas.drawRRect(RRect.fromRectAndRadius(body, Radius.circular(h * 0.12)), stroke);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(body.right + 0.8, h * 0.35, capW - 0.8, h * 0.3), const Radius.circular(1)),
      Paint()..color = color,
    );
    final fill = Paint()..color = color;
    canvas.drawLine(Offset(w * 0.42, h * 0.32), Offset(w * 0.42, h * 0.58), fill..strokeWidth = 2.0..strokeCap = StrokeCap.round);
    canvas.drawCircle(Offset(w * 0.42, h * 0.70), 1.4, fill..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(_CellWarningPainter old) => old.color != color;
}

/// Battery outline with a fill proportional to [soc]; red below 10%,
/// amber below 20%, otherwise the given [color].
class BatteryIcon extends StatelessWidget {
  const BatteryIcon({super.key, required this.soc, this.height = 14, this.color});
  final int soc;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(height * 1.9, height),
        painter: _BatteryPainter(soc.clamp(0, 100), color ?? DashColors.ash),
      );
}

class _BatteryPainter extends CustomPainter {
  _BatteryPainter(this.soc, this.color);
  final int soc;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final capW = h * 0.18;
    final body = Rect.fromLTWH(0.6, 0.6, size.width - capW - 1.2, h - 1.2);
    // A faint shell and a solid charge inside it.
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, Radius.circular(h * 0.3)),
      Paint()
        ..color = color.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(body.right + 1.2, h * 0.32, capW - 1.2, h * 0.36), const Radius.circular(1.2)),
      Paint()..color = color.withValues(alpha: 0.45),
    );
    final fill = body.deflate(2);
    final fillColor = soc < 10 ? DashColors.critical : soc <= 20 ? DashColors.warning : color;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(fill.left, fill.top, fill.width * soc.clamp(0, 100) / 100, fill.height),
        Radius.circular(h * 0.18),
      ),
      Paint()..color = fillColor,
    );
  }

  @override
  bool shouldRepaint(_BatteryPainter old) => old.soc != soc || old.color != color;
}
