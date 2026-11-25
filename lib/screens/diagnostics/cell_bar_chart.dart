import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';

import '../../models/battery_diagnostics.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// The under-chart line for the picked cell: its voltage and signed deviation,
/// with a flag when it is over the pack max or actively balancing.
String cellReadout(CellReading? picked, {required bool bleeding}) {
  if (picked == null) return 'Tap a bar for its voltage';
  if (picked.state == CellState.missing) return 'Cell ${picked.index} · no reading';
  final dev = '${picked.deviationMv >= 0 ? '+' : ''}${picked.deviationMv.toStringAsFixed(1)} mV';
  final flags = [
    if (picked.state == CellState.over) 'over max',
    if (bleeding) 'balancing',
  ];
  final tail = flags.isEmpty ? '' : ' · ${flags.join(' · ')}';
  return 'Cell ${picked.index} · ${picked.voltage.toStringAsFixed(3)} V · $dev$tail';
}

/// The always-on caption when no bar is picked: which cells the BMS is
/// bleeding, so balancing is visible without tapping. Null when none are.
String? balancingCaption(List<int> balancingCells) {
  if (balancingCells.isEmpty) return null;
  final sorted = [...balancingCells]..sort();
  final list = sorted.join(', ');
  return sorted.length == 1 ? 'Balancing cell $list' : 'Balancing cells $list';
}

/// Fourteen bars, one per cell, against a dashed line at the pack average.
/// A tap on a bar names it and its voltage under the chart.
class CellBarChart extends StatefulWidget {
  const CellBarChart({
    super.key,
    required this.cells,
    required this.avgVoltage,
    this.balancingCells = const [],
    this.height = 200,
  });
  final List<CellReading> cells;
  final double? avgVoltage;

  /// 1-indexed cells the BMS is bleeding (0x170).
  final List<int> balancingCells;
  final double height;

  @override
  State<CellBarChart> createState() => _CellBarChartState();
}

class _CellBarChartState extends State<CellBarChart> {
  int? _picked;

  @override
  Widget build(BuildContext context) {
    final picked = _picked == null || _picked! >= widget.cells.length ? null : widget.cells[_picked!];
    final balancing = balancingCaption(widget.balancingCells);
    final caption = picked != null
        ? cellReadout(picked, bleeding: widget.balancingCells.contains(picked.index))
        : (balancing ?? 'Tap a bar for its voltage');
    final captionColor = picked != null
        ? DashColors.bone
        : balancing != null
            ? DashColors.eco
            : DashColors.ash.withValues(alpha: 0.6);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, widget.height);
            final painter = CellBarChartPainter(
              cells: widget.cells,
              avgVoltage: widget.avgVoltage,
              textColor: DashColors.ash,
              balancingCells: widget.balancingCells,
            );
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) {
                final rects = painter.barRects(size);
                final hit = rects.indexWhere((r) => d.localPosition.dx >= r.left - 2 && d.localPosition.dx <= r.right + 2);
                setState(() => _picked = hit < 0 ? null : hit);
              },
              child: CustomPaint(key: const ValueKey('cell-chart'), size: size, painter: painter),
            );
          },
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 20,
          child: Text(
            caption,
            key: const ValueKey('cell-chart-pick'),
            style: DashText.caption(14, color: captionColor),
          ),
        ),
      ],
    );
  }
}

class CellBarChartPainter extends CustomPainter {
  CellBarChartPainter({
    required this.cells,
    required this.avgVoltage,
    required this.textColor,
    this.balancingCells = const [],
  });
  final List<CellReading> cells;
  final double? avgVoltage;
  final Color textColor;

  /// 1-indexed cells the BMS is actively bleeding (0x170).
  final List<int> balancingCells;

  static const gap = 4.0;
  static const labelBand = 22.0;
  static const topPad = 14.0;

  /// Voltage padding above the highest and below the lowest cell.
  static const yPad = 0.03;

  Color colorFor(CellReading c) => switch (c.state) {
        CellState.ok => DashColors.eco,
        CellState.high || CellState.low => DashColors.warning,
        CellState.over => DashColors.critical,
        CellState.missing => DashColors.inkLift,
      };

  /// Whether the BMS reports this 1-indexed cell as balancing right now.
  bool bleeding(int index) => balancingCells.contains(index);

  (double, double) _range() {
    final present = cells.where((c) => c.state != CellState.missing).map((c) => c.voltage).toList();
    if (present.isEmpty) return (3.0, 4.2);
    var lo = present.reduce((a, b) => a < b ? a : b) - yPad;
    var hi = present.reduce((a, b) => a > b ? a : b) + yPad;
    if (avgVoltage != null) {
      if (avgVoltage! < lo) lo = avgVoltage! - yPad;
      if (avgVoltage! > hi) hi = avgVoltage! + yPad;
    }
    return (lo, hi);
  }

  double _y(double v, Size size, (double, double) range) {
    final plot = size.height - labelBand - topPad;
    final t = ((v - range.$1) / (range.$2 - range.$1)).clamp(0.0, 1.0);
    return topPad + plot * (1 - t);
  }

  /// Bar rectangles for [size], left to right; a missing cell gets a
  /// 4px stub so its slot still reads.
  List<Rect> barRects(Size size) {
    if (cells.isEmpty) return const [];
    final n = cells.length;
    final w = (size.width - gap * (n - 1)) / n;
    final range = _range();
    final base = size.height - labelBand;
    return [
      for (var i = 0; i < n; i++)
        Rect.fromLTRB(
          i * (w + gap),
          cells[i].state == CellState.missing ? base - 4 : _y(cells[i].voltage, size, range),
          i * (w + gap) + w,
          base,
        ),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rects = barRects(size);
    final range = _range();
    for (var i = 0; i < rects.length; i++) {
      final r = rects[i];
      canvas.drawRRect(
        RRect.fromRectAndCorners(r, topLeft: const Radius.circular(4), topRight: const Radius.circular(4)),
        Paint()..color = colorFor(cells[i]),
      );
      // A balancing cell gets a bright cap: the BMS is bleeding it now.
      if (bleeding(cells[i].index) && cells[i].state != CellState.missing) {
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTRB(r.left, r.top, r.right, r.top + 4),
            topLeft: const Radius.circular(4),
            topRight: const Radius.circular(4),
          ),
          Paint()..color = DashColors.bone,
        );
      }
      _label(canvas, '${cells[i].index}', Offset(r.center.dx, size.height - labelBand / 2), 13);
    }
    final avg = avgVoltage;
    if (avg != null) {
      final y = _y(avg, size, range);
      final dash = Paint()
        ..color = textColor
        ..strokeWidth = 1;
      for (var x = 0.0; x < size.width; x += 10) {
        canvas.drawLine(Offset(x, y), Offset((x + 5).clamp(0, size.width), y), dash);
      }
      _label(canvas, 'avg ${avg.toStringAsFixed(3)} V', Offset(size.width, topPad / 2 - 2), 13, alignRight: true);
    }
  }

  void _label(Canvas canvas, String text, Offset at, double fontSize, {bool alignRight = false}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: DashText.caption(fontSize, color: textColor)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at - Offset(alignRight ? tp.width : tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(CellBarChartPainter old) {
    if (old.avgVoltage != avgVoltage ||
        old.textColor != textColor ||
        old.cells.length != cells.length ||
        !listEquals(old.balancingCells, balancingCells)) {
      return true;
    }
    for (var i = 0; i < cells.length; i++) {
      if (old.cells[i].voltage != cells[i].voltage || old.cells[i].state != cells[i].state) return true;
    }
    return false;
  }
}
