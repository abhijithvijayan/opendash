import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';

enum TelltaleGlyph {
  cruise,
  hillHold,
  apb,
  regen,
  brakeWorn,
  tamper,
  fall,
  takeMeHome,
  autoTurnOff,
  positionLight,
  speedLimit,
  standBypass,
  regenOff,
}

/// Glyphs that render as a clean Material icon instead of a hand-drawn
/// path — the professionally-drawn symbol reads better small.
const _materialGlyph = <TelltaleGlyph, IconData>{
  TelltaleGlyph.regen: Icons.autorenew,
  TelltaleGlyph.regenOff: Icons.sync_disabled,
};

/// 28px tell-tale symbols: a Material icon where one fits, else hand-drawn.
class TelltaleIcon extends StatelessWidget {
  const TelltaleIcon({super.key, required this.glyph, required this.color, this.size = 28, this.label, this.background});
  final TelltaleGlyph glyph;
  final Color color;
  final double size;

  /// Text drawn inside the glyph, used by the speed limit sign.
  final String? label;

  /// Knock-out colour for the cut-outs; the strip passes the theme ink.
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final material = _materialGlyph[glyph];
    if (material != null) {
      return Icon(material, size: size, color: color);
    }
    return CustomPaint(size: Size.square(size), painter: _GlyphPainter(glyph, color, label, background ?? DashColors.ink));
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color, this.label, this.background);
  final TelltaleGlyph glyph;
  final Color color;
  final String? label;
  final Color background;

  Paint get _stroke => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.2
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  Paint get _fill => Paint()..color = color;

  void _text(Canvas c, String t, Offset center, double size, {double weight = 700}) {
    final tp = TextPainter(
      text: TextSpan(
        text: t,
        style: TextStyle(
          fontFamily: DashText.family,
          fontSize: size,
          color: color,
          height: 1,
          fontVariations: [FontVariation('wght', weight), const FontVariation('wdth', 100)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paint(Canvas c, Size s) {
    final w = s.width, h = s.height;
    final mid = Offset(w / 2, h / 2);
    switch (glyph) {
      case TelltaleGlyph.cruise:
        // A speedometer dial with a needle: the common cruise / set-speed
        // telltale, instead of the old "CC" lettering.
        final cr = w / 2 - 3;
        final cc = Offset(w / 2, h * 0.6);
        c.drawArc(Rect.fromCircle(center: cc, radius: cr), math.pi * 0.85, math.pi * 1.3, false, _stroke);
        for (var i = 0; i <= 4; i++) {
          final a = math.pi * 0.85 + math.pi * 1.3 * i / 4;
          c.drawLine(
            Offset(cc.dx + (cr - 1) * math.cos(a), cc.dy + (cr - 1) * math.sin(a)),
            Offset(cc.dx + (cr - 5) * math.cos(a), cc.dy + (cr - 5) * math.sin(a)),
            _stroke..strokeWidth = 1.6,
          );
        }
        final na = math.pi * 1.62; // needle up-right, as if "set"
        c.drawLine(cc, Offset(cc.dx + cr * 0.62 * math.cos(na), cc.dy + cr * 0.62 * math.sin(na)), _stroke..strokeWidth = 2.2);
        c.drawCircle(cc, 2.6, _fill);
      case TelltaleGlyph.hillHold:
        // A solid vehicle held on a bold slope: reads at 28px where a
        // detailed scooter did not.
        c.drawLine(Offset(w * 0.08, h * 0.84), Offset(w * 0.92, h * 0.42), _stroke..strokeWidth = 2.8);
        c.save();
        c.translate(w * 0.5, h * 0.52);
        c.rotate(-0.46);
        c.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: const Offset(0, -7), width: w * 0.42, height: h * 0.2), const Radius.circular(4)),
          _fill,
        );
        c.restore();
        c.drawLine(Offset(w * 0.34, h * 0.93), Offset(w * 0.34, h * 0.8), _stroke..strokeWidth = 2.8);
        c.drawLine(Offset(w * 0.6, h * 0.93), Offset(w * 0.6, h * 0.8), _stroke..strokeWidth = 2.8);
      case TelltaleGlyph.apb:
        // A lightning bolt: power boost, instead of a "P" in a circle.
        final bolt = Path()
          ..moveTo(w * 0.58, h * 0.08)
          ..lineTo(w * 0.3, h * 0.56)
          ..lineTo(w * 0.47, h * 0.56)
          ..lineTo(w * 0.4, h * 0.92)
          ..lineTo(w * 0.72, h * 0.4)
          ..lineTo(w * 0.53, h * 0.4)
          ..close();
        c.drawPath(bolt, _fill);
      case TelltaleGlyph.regen:
      case TelltaleGlyph.regenOff:
        // A battery taking charge in: regenerative braking.
        final bx = w * 0.2, bw = w * 0.5, by = h * 0.46, bh = h * 0.3;
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(bx, by, bw, bh), const Radius.circular(2.5)), _stroke..strokeWidth = 2.2);
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(bx + bw, by + bh * 0.28, w * 0.055, bh * 0.44), const Radius.circular(1)), _fill);
        final ax = bx + bw * 0.5;
        c.drawLine(Offset(ax, h * 0.1), Offset(ax, h * 0.4), _stroke..strokeWidth = 2.6);
        final head = Path()
          ..moveTo(ax - 5, h * 0.3)
          ..lineTo(ax, h * 0.43)
          ..lineTo(ax + 5, h * 0.3);
        c.drawPath(head, _stroke..strokeWidth = 2.6);
        if (glyph == TelltaleGlyph.regenOff) {
          c.drawLine(Offset(w * 0.08, h * 0.94), Offset(w * 0.92, h * 0.06), _stroke..strokeWidth = 2.8);
        }
      case TelltaleGlyph.brakeWorn:
        // The ISO brake-wear symbol: a brake disc (circle) flanked by the
        // dashes of the pads on each side.
        c.drawCircle(mid, w * 0.24, _stroke);
        c.drawCircle(mid, w * 0.12, _stroke..strokeWidth = 1.6);
        for (final dir in [-1.0, 1.0]) {
          for (var i = 0; i < 3; i++) {
            final y = h * (0.36 + 0.14 * i);
            final x0 = mid.dx + dir * w * 0.3;
            c.drawLine(Offset(x0, y), Offset(x0 + dir * w * 0.12, y), _stroke..strokeWidth = 2.2);
          }
        }
      case TelltaleGlyph.tamper:
        final p = Path()
          ..moveTo(w * 0.5, 1.5)
          ..lineTo(w - 2, h * 0.22)
          ..lineTo(w - 3.5, h * 0.6)
          ..quadraticBezierTo(w * 0.85, h * 0.88, w * 0.5, h - 1.5)
          ..quadraticBezierTo(w * 0.15, h * 0.88, 3.5, h * 0.6)
          ..lineTo(2, h * 0.22)
          ..close();
        c.drawPath(p, _stroke);
        // A keyhole: anti-theft / tamper, instead of a bare "!".
        c.drawCircle(Offset(w / 2, h * 0.42), 3.6, _stroke..strokeWidth = 1.8);
        c.drawLine(Offset(w / 2, h * 0.45), Offset(w / 2, h * 0.62), _stroke..strokeWidth = 2.4);
      case TelltaleGlyph.fall:
        // A scooter tipped onto the ground: a bold, simple silhouette.
        c.save();
        c.translate(mid.dx, mid.dy - h * 0.04);
        c.rotate(-1.3);
        c.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: w * 0.62, height: 7), const Radius.circular(3.5)),
          _fill,
        );
        c.drawCircle(const Offset(0, 0) + Offset(-w * 0.24, 9), 4.6, _stroke..strokeWidth = 2.6);
        c.drawCircle(const Offset(0, 0) + Offset(w * 0.24, 9), 4.6, _stroke..strokeWidth = 2.6);
        c.restore();
        c.drawLine(Offset(w * 0.1, h * 0.9), Offset(w * 0.9, h * 0.9), _stroke..strokeWidth = 2.4);
      case TelltaleGlyph.takeMeHome:
        // A house lit by a beam: the lights that stay on to see you home.
        final house = Path()
          ..moveTo(w * 0.32, h * 0.52)
          ..lineTo(w * 0.55, h * 0.28)
          ..lineTo(w * 0.78, h * 0.52)
          ..lineTo(w * 0.78, h * 0.82)
          ..lineTo(w * 0.32, h * 0.82)
          ..close();
        c.drawPath(house, _stroke);
        c.drawRect(Rect.fromLTWH(w * 0.49, h * 0.6, w * 0.12, h * 0.22), _stroke..strokeWidth = 1.6); // door
        for (var i = 0; i < 3; i++) {
          final y = h * (0.42 + 0.14 * i);
          c.drawLine(Offset(w * 0.04, y), Offset(w * 0.22, y), _stroke..strokeWidth = 1.8); // beam
        }
      case TelltaleGlyph.autoTurnOff:
        final r = w / 2 - 3;
        c.drawArc(Rect.fromCircle(center: mid, radius: r), -math.pi * 0.3, math.pi * 1.6, false, _stroke);
        c.drawLine(Offset(mid.dx, 2), Offset(mid.dx, h * 0.5), _stroke);
        c.drawCircle(Offset(w * 0.8, h * 0.8), 5, Paint()..color = background);
        c.drawCircle(Offset(w * 0.8, h * 0.8), 3.5, _stroke..strokeWidth = 1.5);
      case TelltaleGlyph.speedLimit:
        c.drawCircle(mid, w / 2 - 1.5, _stroke..strokeWidth = 2.6);
        _text(c, label ?? '', mid, (label ?? '').length > 2 ? h * 0.36 : h * 0.44);
      case TelltaleGlyph.standBypass:
        // A side stand: a mount bar, an angled leg and a foot. The telltale
        // is warning-coloured and names itself on tap ("side stand sensor
        // bypassed"), so no slash is needed — a slash read as "no entry".
        c.drawLine(Offset(w * 0.3, h * 0.24), Offset(w * 0.62, h * 0.24), _stroke..strokeWidth = 2.8); // mount
        c.drawLine(Offset(w * 0.56, h * 0.24), Offset(w * 0.34, h * 0.8), _stroke..strokeWidth = 3.0); // leg
        c.drawLine(Offset(w * 0.22, h * 0.8), Offset(w * 0.46, h * 0.8), _stroke..strokeWidth = 3.2); // foot
      case TelltaleGlyph.positionLight:
        // Two lamps facing out, each with rays: the ISO position/parking
        // lamp, drawn cleaner.
        for (final dir in [-1.0, 1.0]) {
          final cx = mid.dx + dir * w * 0.26;
          final bulb = Path()
            ..moveTo(cx, h * 0.34)
            ..arcToPoint(Offset(cx, h * 0.66), radius: Radius.circular(h * 0.16), clockwise: dir > 0)
            ..close();
          c.drawPath(bulb, _fill);
          for (var i = 0; i < 3; i++) {
            final y = h * (0.38 + 0.12 * i);
            c.drawLine(Offset(cx + dir * 6, y), Offset(cx + dir * 13, y), _stroke..strokeWidth = 2.0);
          }
        }
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color || old.label != label || old.background != background;
}
