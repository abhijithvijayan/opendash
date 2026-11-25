import 'package:flutter/widgets.dart';

import '../../theme/colors.dart';

class TurnArrow extends StatefulWidget {
  const TurnArrow({super.key, required this.on, required this.left, this.hazard = false});
  final bool on;
  final bool left;

  /// Both arrows are on. Set in the same frame for both, so each restarts
  /// its cycle together even if one was already blinking solo.
  final bool hazard;

  @override
  State<TurnArrow> createState() => _TurnArrowState();
}

class _TurnArrowState extends State<TurnArrow> with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void initState() {
    super.initState();
    if (widget.on) _restart();
  }

  @override
  void didUpdateWidget(TurnArrow old) {
    super.didUpdateWidget(old);
    if (widget.on && (!old.on || (widget.hazard && !old.hazard))) _restart();
    if (!widget.on && old.on) _blink.stop();
  }

  /// Always start from phase 0 so two arrows switched on in the same frame
  /// blink together, whatever phase a solo indicator stopped or is at.
  void _restart() {
    _blink.value = 0;
    _blink.repeat();
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _blink,
      builder: (context, _) {
        final lit = widget.on && _blink.value < 0.5;
        return CustomPaint(
          size: const Size(56, 40),
          painter: _ArrowPainter(lit ? DashColors.warning : DashColors.slate, widget.left, lit),
        );
      },
    );
  }
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter(this.color, this.left, this.lit);
  final Color color;
  final bool left;
  final bool lit;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(0, h / 2)
      ..lineTo(w * 0.5, 0)
      ..lineTo(w * 0.5, h * 0.3)
      ..lineTo(w, h * 0.3)
      ..lineTo(w, h * 0.7)
      ..lineTo(w * 0.5, h * 0.7)
      ..lineTo(w * 0.5, h)
      ..close();
    if (!left) {
      canvas.translate(w, 0);
      canvas.scale(-1, 1);
    }
    if (lit) {
      canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.35)..maskFilter = null..strokeWidth = 10..style = PaintingStyle.stroke..strokeJoin = StrokeJoin.round);
    }
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.color != color || old.left != left || old.lit != lit;
}

/// Static turn-signal glyph for buttons and labels.
class TurnArrowIcon extends StatelessWidget {
  const TurnArrowIcon({super.key, required this.left, required this.color, this.size = const Size(30, 22)});
  final bool left;
  final Color color;
  final Size size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: size, painter: _ArrowPainter(color, left, false));
}
