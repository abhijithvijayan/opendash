import 'package:flutter/widgets.dart';

import '../../theme/colors.dart';

class BeamIcon extends StatelessWidget {
  const BeamIcon({super.key, required this.high, required this.on, this.color});
  final bool high;
  final bool on;

  /// Overrides the on/off colouring, for use inside buttons.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final color = this.color ?? (on ? (high ? DashColors.normal : DashColors.eco) : DashColors.slate);
    return CustomPaint(size: const Size(44, 28), painter: _BeamPainter(color, high));
  }
}

class _BeamPainter extends CustomPainter {
  _BeamPainter(this.color, this.high);
  final Color color;
  final bool high;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final lens = Path()
      ..moveTo(size.width - 2, 0)
      ..lineTo(size.width * 0.62, 0)
      ..arcToPoint(Offset(size.width * 0.62, h), radius: Radius.elliptical(h * 0.5, h * 0.5), clockwise: false)
      ..lineTo(size.width - 2, h)
      ..close();
    canvas.drawPath(lens, Paint()..color = color);
    final ray = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 3; i++) {
      final y = h * (0.2 + i * 0.3);
      final drop = high ? 0.0 : 4.0;
      canvas.drawLine(Offset(2, y + drop), Offset(size.width * 0.5, y), ray);
    }
  }

  @override
  bool shouldRepaint(_BeamPainter old) => old.color != color || old.high != high;
}
