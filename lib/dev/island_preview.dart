import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/dash_island.dart';
import '../theme/typography.dart';

/// The dash island as Chrome can show it, for the mock build only: the
/// same model that goes to Kotlin, drawn here over a stand-in background.
///
/// This is a second drawing of what `DashIsland.kt` draws, with the same
/// numbers, so the rules and the fit of the text can be looked at without
/// the scooter. It is not the Kotlin drawing: what the head unit shows is
/// still only proven on the head unit.
class IslandPreview extends ConsumerWidget {
  const IslandPreview({super.key, this.label = true});

  /// The line that says this is a stand-in; left out when it is filmed.
  final bool label;

  static const backgrounds = ['light map', 'dark map', 'music', 'white'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final background = ref.watch(islandPreviewProvider);
    if (background == null) return const SizedBox.shrink();
    final model = ref.watch(dashIslandProvider);
    final island = ref.read(dashIslandProvider.notifier);
    if (model != null) {
      // Stands in for Kotlin's "I drew it".
      WidgetsBinding.instance.addPostFrameCallback((_) => island.previewEvent('shown', {'seq': model.seq}));
    }
    final layout = model == null ? null : IslandLayout(model.content);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => island.previewEvent('outside', const {}),
            child: CustomPaint(painter: _BackgroundPainter(background)),
          ),
        ),
        if (layout != null)
          Positioned(
            left: (1280 - layout.size.width) / 2,
            top: 16,
            width: layout.size.width,
            height: layout.size.height,
            child: GestureDetector(
              key: const ValueKey('island-preview'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                final id = layout.hitAt(d.localPosition);
                if (id != null) island.previewEvent('tap', {'id': id});
              },
              child: CustomPaint(painter: _IslandPainter(model!.content, layout)),
            ),
          ),
        if (label)
        Positioned(
          left: 24,
          bottom: 20,
          child: Text(
            'Island preview over a stand-in $background. Drawn by Flutter, not by the head unit.',
            style: DashText.caption(15, color: const Color(0xFFFFFFFF)).copyWith(
              shadows: const [Shadow(color: Color(0xCC000000), blurRadius: 6)],
            ),
          ),
        ),
      ],
    );
  }
}

/// Sizes and touch targets, as `DashIsland.kt` lays them out.
class IslandLayout {
  IslandLayout(this.model) {
    final att = model['att'] as Map?;
    final expanded = model['state'] == 'expanded';
    final width = att != null
        ? (att['action'] != null ? 600.0 : 560.0)
        : expanded
            ? 680.0
            : model['pill'] == true
                ? 220.0
                : 460.0;
    final extra = att != null
        ? (att['action'] != null ? 120.0 : 96.0)
        : expanded
            ? 220.0
            : model['sub'] != null
                ? 44.0
                : 0.0;
    size = Size(width, row + extra);
    hits.add((Rect.fromLTWH(0, 0, width, row), 'row'));
    if (model['pill'] == true) return;
    if (att == null && !expanded && model['trunk'] == true) {
      hits.add((Rect.fromLTWH(width - 62 - boot, 0, boot, row), 'trunk'));
    }
    if (att != null) {
      hits.add((Rect.fromLTWH(0, row, width, extra), 'att'));
      var right = width - 12;
      for (final key in ['action', 'action2']) {
        final label = att[key] as String?;
        if (label == null) continue;
        final w = measure(label, 24, 600) + 60;
        final mid = row + extra / 2;
        buttons[key] = Rect.fromLTRB(right - w, mid - 48, right, mid + 48);
        hits.add((buttons[key]!, key));
        right -= w + 12;
      }
      textRight = right - 8;
    }
    if (expanded) {
      final controls = (model['controls'] as List? ?? const []).cast<Map>();
      const gap = 12.0;
      final inner = width - 36;
      final cw = controls.isEmpty ? 0.0 : (inner - gap * (controls.length - 1)) / controls.length;
      for (var i = 0; i < controls.length; i++) {
        final r = Rect.fromLTWH(18 + i * (cw + gap), row + 14, cw, 104);
        this.controls.add((r, controls[i]));
        if (controls[i]['enabled'] != false) hits.add((r, controls[i]['id'] as String));
      }
      final apps = (model['apps'] as List? ?? const []).cast<Map>();
      final unit = (inner - gap * apps.length) / (1.3 + apps.length);
      var x = 18.0;
      back = Rect.fromLTWH(x, row + 130, unit * 1.3, 72);
      hits.add((back!, 'back'));
      x += unit * 1.3 + gap;
      for (final app in apps) {
        final r = Rect.fromLTWH(x, row + 130, unit, 72);
        this.apps.add((r, app['label'] as String));
        hits.add((r, 'app:${app['id']}'));
        x += unit + gap;
      }
    }
  }

  static const row = 72.0;
  static const boot = 68.0;

  final Map<String, Object?> model;
  late final Size size;
  final hits = <(Rect, String)>[];
  final buttons = <String, Rect>{};
  final controls = <(Rect, Map)>[];
  final apps = <(Rect, String)>[];
  Rect? back;
  double textRight = 0;

  String? hitAt(Offset p) {
    for (final (rect, id) in hits.reversed) {
      if (rect.contains(p)) return id;
    }
    return null;
  }

  static TextStyle style(double size, double weight, {double width = 100, Color? color}) => TextStyle(
        fontFamily: DashText.family,
        fontSize: size,
        height: 1,
        color: color,
        fontVariations: [FontVariation('wght', weight), FontVariation('wdth', width)],
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static double measure(String text, double size, double weight, {double width = 100}) =>
      (TextPainter(text: TextSpan(text: text, style: style(size, weight, width: width)), textDirection: TextDirection.ltr)..layout())
          .width;
}

class _IslandPainter extends CustomPainter {
  _IslandPainter(this.m, this.layout);
  final Map<String, Object?> m;
  final IslandLayout layout;

  Color _c(String key) => Color((m[key] as int?) ?? 0xFFECEEF1);
  bool _b(String key) => m[key] == true;

  double _text(Canvas canvas, String text, double x, double baseline, double size, double weight, Color color,
      {double width = 100, double? maxWidth}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: IslandLayout.style(size, weight, width: width, color: color)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth == null ? double.infinity : math.max(0, maxWidth));
    tp.paint(canvas, Offset(x, baseline - tp.computeDistanceToActualBaseline(TextBaseline.alphabetic)));
    return tp.width;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final light = _b('light');
    final bone = _c('bone');
    final ash = _c('ash');
    final hair = bone.withValues(alpha: 0.12);
    final rect = Offset.zero & size;
    final radius = Radius.circular(m['state'] == 'expanded' ? 32 : 36);
    final rr = RRect.fromRectAndRadius(rect, radius);

    canvas.drawRRect(
      rr.shift(const Offset(0, 4)),
      Paint()
        ..color = light ? const Color(0x380A0F19) : const Color(0x4D000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: light
              ? const [Color(0xE6FFFFFF), Color(0xDBEEF1F5)]
              : const [Color(0xD61E232C), Color(0xE00C0F14)],
        ).createShader(rect),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = light ? const Color(0x241A1D23) : const Color(0x73000000),
    );
    canvas.drawRRect(
      rr.deflate(1.25),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0, 0.4, 0.72, 1],
          colors: [
            for (final a in light ? const [255, 128, 51, 178] : const [87, 20, 8, 31]) Color.fromARGB(a, 255, 255, 255),
          ],
        ).createShader(rect),
    );

    final att = m['att'] as Map?;
    if (att != null) {
      final p = att['priority'];
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = p == 'critical' ? _c('critical') : p == 'warning' ? _c('warning') : hair,
      );
    }

    _row(canvas, size.width, bone, ash, hair);
    if (size.height <= IslandLayout.row + 1) return;
    canvas.drawRect(Rect.fromLTWH(1, IslandLayout.row, size.width - 2, 1), Paint()..color = hair);
    if (att != null) {
      _attention(canvas, att, size, bone, ash, hair);
    } else if (m['state'] == 'expanded') {
      _expanded(canvas, bone, hair);
    } else if (m['sub'] is Map) {
      _sub(canvas, m['sub']! as Map, size.width, bone, hair);
    }
  }

  void _row(Canvas canvas, double w, Color bone, Color ash, Color hair) {
    const mid = IslandLayout.row / 2;
    if (_b('pill')) {
      _backLabel(canvas, w / 2, mid, 24, bone);
      return;
    }
    final warning = _c('warning');
    _arrow(canvas, 34, mid, true, _b('left') ? warning : bone.withValues(alpha: 0.16));
    _arrow(canvas, w - 34, mid, false, _b('right') ? warning : bone.withValues(alpha: 0.16));

    var x = 62.0;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(x, mid - 20, 5, 40), const Radius.circular(2.5)),
      Paint()..color = _c('accent'),
    );
    x += 17;
    x += _text(canvas, m['speed'] as String? ?? '', x, mid + 18, 50, 600, bone, width: 125) + 7;
    final unit = m['unit'] as String? ?? '';
    var unitWidth = unit.isEmpty ? 0.0 : _text(canvas, unit, x, mid + 18, 17, 400, ash);
    final mode = m['mode'] as String? ?? '';
    if (mode.isNotEmpty) {
      final w = _text(canvas, mode, x, mid - 3, 13, 600, _c('accent'));
      if (w > unitWidth) unitWidth = w;
    }
    x += unitWidth;
    x += 16;
    canvas.drawRect(Rect.fromLTWH(x, mid - 17, 1, 34), Paint()..color = hair);
    x += 17;

    final soc = m['soc'] as int?;
    if (soc != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, mid - 8, 30, 16), const Radius.circular(4)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = ash,
      );
      canvas.drawRect(Rect.fromLTWH(x + 31, mid - 3, 3, 6), Paint()..color = ash);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x + 3, mid - 5, 24 * soc.clamp(0, 100) / 100, 10), const Radius.circular(1.5)),
        Paint()..color = _c('socColor'),
      );
      x += 43;
      x += _text(canvas, '$soc', x, mid + 11, 30, 600, bone, width: 125) + 3;
      x += _text(canvas, '%', x, mid + 11, 17, 400, ash) + 14;
    }

    var right = w - 62;
    if (_b('trunk') && m['state'] == 'collapsed') {
      right -= IslandLayout.boot;
      final button = RRect.fromRectAndRadius(Rect.fromLTRB(right + 6, mid - 28, right + 62, mid + 28), const Radius.circular(28));
      canvas.drawRRect(button, Paint()..color = bone.withValues(alpha: 0.09));
      canvas.drawRRect(
        button,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = hair,
      );
      _boot(canvas, right + 34, mid, bone);
    }
    if (_b('dot') && right - 24 >= x) {
      right -= 24;
      canvas.drawCircle(Offset(right + 12, mid), 6, Paint()..color = warning);
    }
    if (_b('highBeam') && right - 40 >= x) {
      right -= 40;
      _beam(canvas, right + 20, mid, _c('beam'));
    }
    if (_b('trunkOpen') && right - 40 >= x) {
      right -= 40;
      _boot(canvas, right + 20, mid, warning);
    }
    final note = m['note'] as String? ?? '';
    final strong = _b('noteStrong');
    if (note.isNotEmpty && IslandLayout.measure(note, strong ? 20 : 17, strong ? 600 : 400) <= right - x - 6) {
      _text(canvas, note, x, mid + 7, strong ? 20 : 17, strong ? 600 : 400, _c('noteColor'));
    }
  }

  void _sub(Canvas canvas, Map sub, double w, Color bone, Color hair) {
    const mid = IslandLayout.row + 22;
    const from = 26.0;
    final end = w - 26;
    final text = sub['text'] as String? ?? '';
    final bar = (sub['bar'] as num?)?.toDouble();
    if (bar == null) {
      _text(canvas, text, from, mid + 6.5, 19, 600, bone, maxWidth: end - from);
      return;
    }
    final left = from + _text(canvas, text, from, mid + 6.5, 19, 600, bone) + 18;
    final percent = '${(bar * 100).toInt()}%';
    final pw = IslandLayout.measure(percent, 19, 600, width: 125);
    final right = end - pw - 14;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(left, mid - 3, right, mid + 3), const Radius.circular(3)), Paint()..color = hair);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(left, mid - 3, left + (right - left) * bar.clamp(0, 1), mid + 3), const Radius.circular(3)),
      Paint()..color = bone,
    );
    _text(canvas, percent, end - pw, mid + 6.5, 19, 600, bone, width: 125);
  }

  void _attention(Canvas canvas, Map att, Size size, Color bone, Color ash, Color hair) {
    final mid = IslandLayout.row + (size.height - IslandLayout.row) / 2;
    for (final MapEntry(:key, :value) in layout.buttons.entries) {
      final primary = key == 'action';
      final rr = RRect.fromRectAndRadius(value, const Radius.circular(28));
      canvas.drawRRect(rr, Paint()..color = primary ? bone : bone.withValues(alpha: 0.09));
      final label = att[key]! as String;
      _text(canvas, label, value.center.dx - IslandLayout.measure(label, 24, 600) / 2, mid + 8, 24, 600,
          primary ? (_b('light') ? const Color(0xFFFFFFFF) : const Color(0xFF0B0D11)) : bone);
    }
    final p = att['priority'];
    canvas.drawCircle(Offset(52, mid), 26, Paint()..color = p == 'critical' ? _c('critical') : p == 'warning' ? _c('warning') : ash);
    final badge = att['badge'] as String? ?? '';
    if (badge.isNotEmpty) {
      _text(canvas, badge, 52 - IslandLayout.measure(badge, 30, 600, width: 125) / 2, mid + 11, 30, 600,
          p == 'critical' ? const Color(0xFFFFFFFF) : const Color(0xFF14161A),
          width: 125);
    }
    final room = (layout.textRight == 0 ? size.width - 20 : layout.textRight) - 96;
    final body = att['body'] as String? ?? '';
    _text(canvas, att['title'] as String? ?? '', 96, body.isEmpty ? mid + 10 : mid - 2, 28, 600, bone, maxWidth: room);
    if (body.isNotEmpty) _text(canvas, body, 96, mid + 24, 19, 400, ash, maxWidth: room);
  }

  void _expanded(Canvas canvas, Color bone, Color hair) {
    for (final (rect, c) in layout.controls) {
      final on = c['on'] == true;
      final a = c['enabled'] != false ? 1.0 : 0.38;
      final id = c['id'] as String;
      final rr = RRect.fromRectAndRadius(rect, const Radius.circular(20));
      canvas.drawRRect(rr, Paint()..color = on ? (id == 'hazard' ? _c('warning') : _c('beam')) : bone.withValues(alpha: 0.09 * a));
      final ink = on ? const Color(0xFF0B0D11) : bone.withValues(alpha: a);
      switch (id) {
        case 'hazard':
          _hazard(canvas, rect.center.dx, rect.top + 38, ink);
        case 'highBeam':
          _beam(canvas, rect.center.dx, rect.top + 38, ink);
        default:
          _boot(canvas, rect.center.dx, rect.top + 38, ink);
      }
      final label = c['label'] as String? ?? '';
      _text(canvas, label, rect.center.dx - IslandLayout.measure(label, 18, 600) / 2, rect.top + 84, 18, 600, ink);
    }
    final back = layout.back;
    if (back != null) {
      canvas.drawRRect(RRect.fromRectAndRadius(back, const Radius.circular(20)), Paint()..color = bone);
      _backLabel(canvas, back.center.dx, back.center.dy, 22, _b('light') ? const Color(0xFFFFFFFF) : const Color(0xFF0B0D11));
    }
    for (final (rect, label) in layout.apps) {
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(20)), Paint()..color = bone.withValues(alpha: 0.09));
      _text(canvas, label, rect.center.dx - math.min(IslandLayout.measure(label, 22, 600), rect.width - 16) / 2, rect.center.dy + 8, 22, 600, bone,
          maxWidth: rect.width - 16);
    }
  }

  void _backLabel(Canvas canvas, double cx, double cy, double size, Color color) {
    const name = 'OpenDash';
    final arrow = size * 0.8;
    final gap = size * 0.45;
    final left = cx - (arrow + gap + IslandLayout.measure(name, size, 600)) / 2;
    canvas.drawPath(
      Path()
        ..moveTo(left + arrow, cy)
        ..lineTo(left, cy)
        ..moveTo(left + arrow * 0.45, cy - arrow * 0.45)
        ..lineTo(left, cy)
        ..lineTo(left + arrow * 0.45, cy + arrow * 0.45),
      _stroke(color)..strokeWidth = size * 0.11,
    );
    _text(canvas, name, left + arrow + gap, cy + size * 0.35, size, 600, color);
  }

  Paint _stroke(Color color) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.4
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round
    ..color = color;

  void _arrow(Canvas canvas, double cx, double cy, bool left, Color color) {
    final d = left ? -1.0 : 1.0;
    canvas.drawPath(
      Path()
        ..moveTo(cx + 13 * d, cy)
        ..lineTo(cx + 1 * d, cy - 11)
        ..lineTo(cx + 1 * d, cy - 4)
        ..lineTo(cx - 13 * d, cy - 4)
        ..lineTo(cx - 13 * d, cy + 4)
        ..lineTo(cx + 1 * d, cy + 4)
        ..lineTo(cx + 1 * d, cy + 11)
        ..close(),
      Paint()..color = color,
    );
  }

  void _boot(Canvas canvas, double cx, double cy, Color color) {
    const k = 1.1;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(cx - 14 * k, cy, cx + 14 * k, cy + 9.9 * k), const Radius.circular(3)),
      _stroke(color),
    );
    canvas.drawLine(Offset(cx - 11.4 * k, cy), Offset(cx + 6.6 * k, cy - 10 * k), _stroke(color));
  }

  void _beam(Canvas canvas, double cx, double cy, Color color) {
    canvas.drawPath(
      Path()
        ..moveTo(cx + 1, cy - 10)
        ..cubicTo(cx + 14, cy - 10, cx + 14, cy + 10, cx + 1, cy + 10)
        ..close(),
      _stroke(color),
    );
    for (final dy in [-7.0, 0.0, 7.0]) {
      canvas.drawLine(Offset(cx - 13, cy + dy), Offset(cx - 5, cy + dy), _stroke(color));
    }
  }

  void _hazard(Canvas canvas, double cx, double cy, Color color) {
    canvas.drawPath(
      Path()
        ..moveTo(cx, cy - 13)
        ..lineTo(cx + 15, cy + 12)
        ..lineTo(cx - 15, cy + 12)
        ..close()
        ..moveTo(cx, cy - 3)
        ..lineTo(cx + 6.5, cy + 7.5)
        ..lineTo(cx - 6.5, cy + 7.5)
        ..close(),
      _stroke(color),
    );
  }

  @override
  bool shouldRepaint(_IslandPainter old) => !identical(old.m, m);
}

/// Stand-ins for what is under the island: nothing here is a real app.
class _BackgroundPainter extends CustomPainter {
  _BackgroundPainter(this.kind);
  final String kind;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    switch (kind) {
      case 'white':
        canvas.drawRect(rect, Paint()..color = const Color(0xFFFDFDFD));
      case 'music':
        canvas.drawRect(
          rect,
          Paint()
            ..shader = const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF7A1F3D), Color(0xFFB5432C), Color(0xFFE08A2E), Color(0xFFF2C14E)],
            ).createShader(rect),
        );
      default:
        final dark = kind == 'dark map';
        canvas.drawRect(rect, Paint()..color = dark ? const Color(0xFF1B2027) : const Color(0xFFEEF0EA));
        Paint road(double w, Color c) => Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..color = c;
        final minor = dark ? const Color(0xFF39424F) : const Color(0xFFFFFFFF);
        canvas.drawPath(
          Path()
            ..moveTo(300, -20)
            ..cubicTo(340, 200, 260, 420, 420, 800)
            ..moveTo(860, -20)
            ..cubicTo(820, 180, 940, 380, 900, 800)
            ..moveTo(-20, 200)
            ..cubicTo(300, 240, 700, 120, 1320, 180),
          road(18, minor),
        );
        canvas.drawPath(
          Path()
            ..moveTo(-20, 560)
            ..cubicTo(200, 520, 380, 640, 620, 500)
            ..cubicTo(860, 360, 1000, 300, 1320, 360),
          road(26, dark ? const Color(0xFF5A6577) : const Color(0xFFF7C96B)),
        );
        canvas.drawPath(
          Path()
            ..moveTo(420, 800)
            ..cubicTo(420, 640, 560, 560, 620, 500)
            ..cubicTo(700, 420, 760, 380, 900, 330),
          road(14, dark ? const Color(0xFF4C8DFF) : const Color(0xFF2F7BF6))..strokeCap = StrokeCap.round,
        );
    }
  }

  @override
  bool shouldRepaint(_BackgroundPainter old) => old.kind != kind;
}
