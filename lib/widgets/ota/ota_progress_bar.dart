import 'package:material_ui/material_ui.dart';

import '../../theme/colors.dart';
import '../../theme/tokens.dart';

/// 12px progress bar. The fill eases to its value, and while [active] a
/// lighter band sweeps across it every two seconds (a gradient, no blur).
class OtaProgressBar extends StatefulWidget {
  const OtaProgressBar({
    super.key,
    required this.progress,
    required this.color,
    this.active = false,
  });

  /// 0-100.
  final int progress;
  final Color color;
  final bool active;

  @override
  State<OtaProgressBar> createState() => _OtaProgressBarState();
}

class _OtaProgressBarState extends State<OtaProgressBar> with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _shimmer.repeat();
  }

  @override
  void didUpdateWidget(OtaProgressBar old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _shimmer.repeat();
    if (!widget.active && old.active) _shimmer.stop();
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: widget.progress.clamp(0, 100) / 100),
      duration: DashMotion.value,
      curve: Curves.easeOut,
      builder: (context, fraction, _) => AnimatedBuilder(
        animation: _shimmer,
        builder: (context, _) => SizedBox(
          height: 12,
          width: double.infinity,
          child: CustomPaint(
            painter: _BarPainter(fraction, widget.color, widget.active ? _shimmer.value : null),
          ),
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.fraction, this.color, this.shimmer);
  final double fraction;
  final Color color;
  final double? shimmer;

  @override
  void paint(Canvas canvas, Size size) {
    const r = Radius.circular(6);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, r), Paint()..color = DashColors.slate);
    if (fraction <= 0) return;
    final fill = Rect.fromLTWH(0, 0, size.width * fraction, size.height);
    canvas.drawRRect(RRect.fromRectAndRadius(fill, r), Paint()..color = color);
    if (shimmer == null) return;
    final bandWidth = fill.width * 0.35 + 24;
    final x = -bandWidth + (fill.width + bandWidth * 2) * shimmer!;
    final band = Rect.fromLTWH(x, 0, bandWidth, size.height);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(fill, r));
    canvas.drawRect(
      band,
      Paint()
        ..shader = LinearGradient(
          colors: [
            DashColors.bone.withValues(alpha: 0),
            DashColors.bone.withValues(alpha: 0.35),
            DashColors.bone.withValues(alpha: 0),
          ],
        ).createShader(band),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.fraction != fraction || old.color != color || old.shimmer != shimmer;
}
