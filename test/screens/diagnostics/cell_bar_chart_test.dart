import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/battery_diagnostics.dart';
import 'package:opendash/screens/diagnostics/cell_bar_chart.dart';
import 'package:opendash/theme/colors.dart';

CellReading cell(int i, double v, CellState s) =>
    CellReading(index: i, voltage: v, deviationMv: 0, state: s);

void main() {
  group('cell bar chart painter', () {
    test('an overvoltage cell paints critical red, over the amber of a strayed cell', () {
      final p = CellBarChartPainter(cells: const [], avgVoltage: null, textColor: DashColors.ash);
      expect(p.colorFor(cell(1, 4.30, CellState.over)), DashColors.critical);
      expect(p.colorFor(cell(1, 3.95, CellState.high)), DashColors.warning);
      expect(p.colorFor(cell(1, 3.90, CellState.ok)), DashColors.eco);
      expect(p.colorFor(cell(1, 0, CellState.missing)), DashColors.inkLift);
    });

    test('the painter knows which cells the BMS is bleeding', () {
      final p = CellBarChartPainter(
        cells: [for (var i = 1; i <= 14; i++) cell(i, 3.9, CellState.ok)],
        avgVoltage: 3.9,
        textColor: DashColors.ash,
        balancingCells: const [3, 11],
      );
      expect(p.bleeding(3), isTrue);
      expect(p.bleeding(11), isTrue);
      expect(p.bleeding(1), isFalse);
    });
  });

  group('cell readout', () {
    test('prompts to tap when nothing is picked', () {
      expect(cellReadout(null, bleeding: false), 'Tap a bar for its voltage');
    });

    test('a healthy cell shows its voltage and signed deviation', () {
      expect(cellReadout(cell(4, 3.901, CellState.ok), bleeding: false),
          'Cell 4 · 3.901 V · +0.0 mV');
    });

    test('an overvoltage cell is called out as over max', () {
      final r = cellReadout(
          const CellReading(index: 7, voltage: 4.305, deviationMv: 45, state: CellState.over),
          bleeding: false);
      expect(r, contains('over max'));
      expect(r, contains('4.305 V'));
    });

    test('a bleeding cell says it is balancing', () {
      final r = cellReadout(
          const CellReading(index: 3, voltage: 3.95, deviationMv: 22, state: CellState.high),
          bleeding: true);
      expect(r, contains('balancing'));
    });

    test('a missing cell reports no reading', () {
      expect(cellReadout(cell(2, 0, CellState.missing), bleeding: false), 'Cell 2 · no reading');
    });
  });

  group('balancing caption', () {
    test('is null when nothing is balancing', () {
      expect(balancingCaption(const []), isNull);
    });

    test('names a single balancing cell', () {
      expect(balancingCaption(const [3]), 'Balancing cell 3');
    });

    test('lists several balancing cells in order', () {
      expect(balancingCaption(const [11, 3]), 'Balancing cells 3, 11');
    });
  });
}
