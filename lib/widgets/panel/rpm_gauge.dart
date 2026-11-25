import 'package:flutter/widgets.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../gauges/arc_paint.dart';
import '../../theme/tokens.dart';

/// Real motor rpm. Gen 1 rides topped out at 3,600 to 3,699 at
/// 117 km/h (31.1 rpm per km/h), which is the scooter's top speed.
const rpmMax = 4000.0;

/// The dial's end for a scooter whose motor has turned faster than that:
/// the next whole thousand above the highest rpm it has reported.
double rpmMaxFor(int peakRpm) => peakRpm <= rpmMax ? rpmMax : (peakRpm / 1000).ceil() * 1000.0;
const _tickEvery = 500;
const _labelEvery = 1000;
const _startAngle = 180.0;
const _sweepAngle = 180.0;

/// Angle in radians for an rpm value, measured like the speed dial.
double rpmAngle(double rpm, [double max = rpmMax]) => deg(_startAngle + rpm.clamp(0, max) / max * _sweepAngle);

/// Sweep in radians of the fill for an rpm value.
double rpmSweep(double rpm, [double max = rpmMax]) => deg(rpm.clamp(0, max) / max * _sweepAngle);

/// 180x100 half dial in the speed dial's language: hairline track, glowing
/// accent fill, ticks every 500, numerals every 1000 (in thousands).
class RpmGauge extends StatelessWidget {
  const RpmGauge({super.key, required this.rpm, required this.accent, this.max = rpmMax});

  /// `rpmMaxFor` of the highest rpm seen.
  final double max;

  /// Real rpm (`VehicleData.rpm * VehicleData.rpmUnit`).
  final int rpm;
  final Color accent;

  static const size = Size(180, 100);
  static const center = Offset(90, 92);
  static const radius = 74.0;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: rpm.toDouble()),
      duration: DashMotion.gauge,
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => Stack(
        children: [
          RepaintBoundary(child: CustomPaint(size: RpmGauge.size, painter: _TrackPainter(max))),
          CustomPaint(size: RpmGauge.size, painter: _FillPainter(value, accent, max)),
        ],
      ),
    );
  }
}

class _TrackPainter extends CustomPainter {
  const _TrackPainter(this.max);
  final double max;

  @override
  void paint(Canvas canvas, Size size) {
    const c = RpmGauge.center;
    const r = RpmGauge.radius;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      deg(_startAngle),
      deg(_sweepAngle),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = DashColors.slate,
    );
    final minor = Paint()..color = DashColors.slate..strokeWidth = 1.2;
    final major = Paint()..color = DashColors.ash..strokeWidth = 1.6;
    for (var v = 0; v <= max; v += _tickEvery) {
      final a = rpmAngle(v.toDouble(), max);
      final isMajor = v % _labelEvery == 0;
      canvas.drawLine(
        onArc(c, r + (isMajor ? 5 : 6), a),
        onArc(c, r + (isMajor ? 13 : 10), a),
        isMajor ? major : minor,
      );
      if (isMajor) {
        final tp = TextPainter(
          text: TextSpan(text: '${v ~/ 1000}', style: DashText.scale.copyWith(fontSize: 14)),
          textDirection: TextDirection.ltr,
        )..layout();
        final p = onArc(c, r + 24, a);
        tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(_TrackPainter old) => old.max != max;
}

class _FillPainter extends CustomPainter {
  _FillPainter(this.rpm, this.accent, this.max);
  final double max;
  final double rpm;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    const c = RpmGauge.center;
    const r = RpmGauge.radius;
    final rect = Rect.fromCircle(center: c, radius: r);
    drawGlowArc(canvas, rect, deg(_startAngle), rpmSweep(rpm, max), accent, 6);
    final a = rpmAngle(rpm, max);
    canvas.drawLine(
      onArc(c, r - 8, a),
      onArc(c, r + 8, a),
      Paint()
        ..color = DashColors.bone
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_FillPainter old) => old.rpm != rpm || old.accent != accent;
}
