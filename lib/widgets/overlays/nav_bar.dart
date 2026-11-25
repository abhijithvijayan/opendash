import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../state/theme_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';

enum TurnKind {
  left,
  right,
  straight,
  uTurn,
  slightLeft,
  slightRight,
  arrive,
  unknown,
}

/// Keyword match on the instruction string; Phase 2 gets structured types.
TurnKind turnKindFor(String instruction) {
  final s = instruction.toLowerCase();
  if (s.contains('u-turn') || s.contains('u turn') || s.contains('uturn')) {
    return TurnKind.uTurn;
  }
  if (s.contains('arrive') || s.contains('destination')) {
    return TurnKind.arrive;
  }
  if (s.contains('slight left') || s.contains('bear left')) {
    return TurnKind.slightLeft;
  }
  if (s.contains('slight right') || s.contains('bear right')) {
    return TurnKind.slightRight;
  }
  if (s.contains('left')) {
    return TurnKind.left;
  }
  if (s.contains('right')) {
    return TurnKind.right;
  }
  if (s.contains('continue') || s.contains('straight')) {
    return TurnKind.straight;
  }
  return TurnKind.unknown;
}

/// Turn-by-turn strip above the trip strip while navigation is active.
/// Dashboard only; it slides up from behind the trip strip.
class NavBar extends ConsumerWidget {
  const NavBar({super.key});

  static const height = 64.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(vehicleProvider.select((v) => v.navActive));
    final instruction = ref.watch(
      vehicleProvider.select((v) => v.nextTurnDirection),
    );
    final distance = ref.watch(vehicleProvider.select((v) => v.distanceToTurn));
    final totals = ref.watch(vehicleProvider.select(
      (v) => [v.navTotalDistance, v.navTotalTime].where((s) => s.isNotEmpty).join(' · '),
    ));
    final accent = ref.watch(accentProvider);
    final theme = ref.watch(uiThemeProvider);

    return AnimatedPositioned(
      duration: DashMotion.fast,
      curve: Curves.easeOut,
      left: 0,
      right: 0,
      bottom: active ? 72 : 72 - height,
      height: height,
      child: IgnorePointer(
        ignoring: !active,
        child: AnimatedOpacity(
          duration: DashMotion.fast,
          opacity: active ? 1 : 0,
          child: Container(
            key: const ValueKey('nav-bar'),
            padding: const EdgeInsets.symmetric(horizontal: 48),
            decoration: BoxDecoration(
              color: theme.inkLift.withValues(alpha: DashScrim.glass),
              border: Border(top: BorderSide(color: theme.slate, width: 1)),
            ),
            child: Row(
              children: [
                TurnIcon(kind: turnKindFor(instruction), color: theme.bone, hole: theme.inkLift),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    instruction,
                    style: DashText.value(20, color: theme.bone),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 16),
                Text(distance, style: DashText.value(22, color: accent)),
                const SizedBox(width: 24),
                if (totals.isNotEmpty) ...[
                  Text(totals, key: const ValueKey('nav-totals'), style: DashText.caption(14, color: theme.ash)),
                  const SizedBox(width: 24),
                ],
                GestureDetector(
                  key: const ValueKey('nav-close'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    ref.read(vehicleProvider.notifier).dismissNav();
                  },
                  child: SizedBox(
                    width: DashTouch.min,
                    height: DashTouch.min,
                    child: Icon(
                      Icons.close_rounded,
                      size: 24,
                      color: theme.ash,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TurnIcon extends StatelessWidget {
  const TurnIcon({
    super.key,
    required this.kind,
    this.color,
    this.size = 32,
    this.hole,
  });
  final TurnKind kind;
  final Color? color;
  final double size;

  /// Knock-out colour of the arrival pin's centre: the bar's background.
  final Color? hole;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _TurnPainter(kind, color ?? DashColors.bone, hole ?? DashColors.inkLift));
}

class _TurnPainter extends CustomPainter {
  _TurnPainter(this.kind, this.color, this.hole);
  final TurnKind kind;
  final Color color;
  final Color hole;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color;
    final c = Offset(w / 2, h / 2);

    void arrow(double angle) {
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate(angle);
      canvas.drawLine(Offset(0, h * 0.4), Offset(0, -h * 0.3), stroke);
      final head = Path()
        ..moveTo(0, -h * 0.46)
        ..lineTo(-w * 0.26, -h * 0.14)
        ..lineTo(w * 0.26, -h * 0.14)
        ..close();
      canvas.drawPath(head, fill);
      canvas.restore();
    }

    switch (kind) {
      case TurnKind.straight:
      case TurnKind.unknown:
        arrow(0);
      case TurnKind.left:
        arrow(-math.pi / 2);
      case TurnKind.right:
        arrow(math.pi / 2);
      case TurnKind.slightLeft:
        arrow(-math.pi / 4);
      case TurnKind.slightRight:
        arrow(math.pi / 4);
      case TurnKind.uTurn:
        final path = Path()
          ..moveTo(w * 0.72, h * 0.9)
          ..lineTo(w * 0.72, h * 0.4)
          ..arcToPoint(
            Offset(w * 0.28, h * 0.4),
            radius: Radius.circular(w * 0.22),
            clockwise: false,
          )
          ..lineTo(w * 0.28, h * 0.58);
        canvas.drawPath(path, stroke);
        final head = Path()
          ..moveTo(w * 0.28, h * 0.92)
          ..lineTo(w * 0.08, h * 0.6)
          ..lineTo(w * 0.48, h * 0.6)
          ..close();
        canvas.drawPath(head, fill);
      case TurnKind.arrive:
        final pin = Path()
          ..moveTo(w * 0.5, h * 0.95)
          ..quadraticBezierTo(w * 0.08, h * 0.45, w * 0.22, h * 0.25)
          ..arcToPoint(
            Offset(w * 0.78, h * 0.25),
            radius: Radius.circular(w * 0.28),
          )
          ..quadraticBezierTo(w * 0.92, h * 0.45, w * 0.5, h * 0.95)
          ..close();
        canvas.drawPath(pin, fill);
        canvas.drawCircle(
          Offset(w * 0.5, h * 0.36),
          w * 0.11,
          Paint()..color = hole,
        );
    }
  }

  @override
  bool shouldRepaint(_TurnPainter old) =>
      old.kind != kind || old.color != color || old.hole != hole;
}
