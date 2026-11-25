import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/battery_diagnostics.dart';
import 'package:opendash/providers/battery_diagnostics_provider.dart';
import 'package:opendash/providers/mock_provider.dart';

void main() {
  group('BatteryDiagnostics model', () {
    // Average 3.88871V: cell 7 sits 43.7mV low, cell 11 21.3mV high.
    const volts = [3.890, 3.892, 3.888, 3.895, 3.891, 3.889, 3.845, 3.893, 3.890, 3.887, 3.910, 3.892, 3.889, 3.891];
    final d = BatteryDiagnostics.compute(
      cellVoltages: volts,
      temps: const [PackTemperature(label: 'Pack 1', tempC: 31), PackTemperature(label: 'Motor')],
      soh: 96,
      busVoltage: 25.2,
      packVoltage: 51.2,
      batteryCurrent: -0.5,
      dischargeLimitW: 18000,
      regenLimitW: 3200,
      balancingActive: false,
    );

    test('cells carry their index, deviation from the average and a state', () {
      expect(d.cells.length, 14);
      expect(d.cells.first.index, 1);
      expect(d.cells.last.index, 14);
      final avg = volts.reduce((a, b) => a + b) / 14;
      expect(d.cellAvgV, closeTo(avg, 1e-9));
      expect(d.cells[6].deviationMv, closeTo((3.845 - avg) * 1000, 0.05), reason: 'rounded to 0.1mV');
      expect(d.cells[6].state, CellState.low);
      expect(d.cells[10].state, CellState.high);
      expect(d.cells[0].state, CellState.ok);
      expect(d.cells.where((c) => c.state == CellState.ok).length, 12);
    });

    test('spread is max minus min in millivolts, with min and max kept', () {
      expect(d.cellSpreadMv, closeTo(65, 1e-6));
      expect(d.cellMinV, 3.845);
      expect(d.cellMaxV, 3.910);
    });

    test('balancing is needed once any cell is more than 20mV off the average', () {
      expect(d.balancingNeeded, isTrue);
      final even = BatteryDiagnostics.compute(cellVoltages: List.filled(14, 3.9), temps: const []);
      expect(even.balancingNeeded, isFalse);
      expect(even.cellSpreadMv, 0);
      expect(even.cells.every((c) => c.state == CellState.ok), isTrue);
      final edge = BatteryDiagnostics.compute(cellVoltages: [...List.filled(13, 3.900), 3.900 + 0.0199 * 14 / 13], temps: const []);
      expect(edge.cells.last.deviationMv, lessThan(20));
      expect(edge.balancingNeeded, isFalse, reason: 'exactly inside the threshold');
    });

    test('exactly 20mV is still even, and the maths is not fooled by float noise', () {
      // 3.910 - 3.890 is 20.000000000000018 in doubles.
      final edge = BatteryDiagnostics.compute(cellVoltages: [...List.filled(13, 3.890), 3.910], temps: const []);
      expect(edge.cellSpreadMv, 20);
      final dev = edge.cells.last.deviationMv;
      expect(dev, lessThan(20));
      final twenty = BatteryDiagnostics.compute(cellVoltages: [3.880, 3.900], temps: const []);
      expect(twenty.cells.first.deviationMv, -10);
      expect(twenty.cells.last.deviationMv, 10);
      final exact = BatteryDiagnostics.compute(cellVoltages: [3.870, 3.890, 3.910], temps: const []);
      expect(exact.cells.first.deviationMv, -20);
      expect(exact.cells.first.state, CellState.ok, reason: '20mV off is the edge of even, not past it');
      expect(exact.cells.last.state, CellState.ok);
      expect(exact.balancingNeeded, isFalse);
    });

    test('non-finite readings count as missing', () {
      final m = BatteryDiagnostics.compute(cellVoltages: [3.9, double.nan, double.infinity, 3.9], temps: const []);
      expect(m.cells[1].state, CellState.missing);
      expect(m.cells[2].state, CellState.missing);
      expect(m.cellAvgV, closeTo(3.9, 1e-9));
      expect(m.cellSpreadMv, 0);
    });

    test('a zero cell is missing and does not drag the average down', () {
      final m = BatteryDiagnostics.compute(cellVoltages: [...List.filled(13, 3.9), 0], temps: const []);
      expect(m.cells.last.state, CellState.missing);
      expect(m.cellAvgV, closeTo(3.9, 1e-9));
      expect(m.cellSpreadMv, 0);
      expect(m.balancingNeeded, isFalse);
    });

    test('pack power is pack voltage (not bus) times current in kW', () {
      expect(d.packPowerKw, closeTo(51.2 * -0.5 / 1000, 1e-9));
      expect(BatteryDiagnostics.compute(cellVoltages: const [], temps: const []).packPowerKw, isNull);
    });

    test('a cell over the charge-end limit is overvoltage, whatever its deviation', () {
      // The BMS's own charge-stop voltage (0x653) is the max. One cell past
      // it is overvoltage (red), even when every cell drifted high together so
      // none is far from the average.
      final ov = BatteryDiagnostics.compute(
        cellVoltages: [...List.filled(13, 4.300), 4.305],
        temps: const [],
        chargeEndCellMv: 4200,
      );
      expect(ov.cells.every((c) => c.state == CellState.over), isTrue,
          reason: 'all 14 are above 4.200 V, so all are over — not "even" at 4.3');
      expect(ov.hasOvervoltage, isTrue);
      expect(ov.overCell?.index, 14, reason: 'the worst (highest) over cell is named');
      expect(ov.overCell?.voltage, 4.305);
    });

    test('overvoltage falls back to the M50 4.200 V max when 0x653 has not arrived', () {
      final noConfig = BatteryDiagnostics.compute(
        cellVoltages: [...List.filled(13, 3.900), 4.210],
        temps: const [],
      );
      expect(noConfig.cells.last.state, CellState.over);
      expect(noConfig.overCell?.index, 14);
      final under = BatteryDiagnostics.compute(
        cellVoltages: [...List.filled(13, 3.900), 4.190],
        temps: const [],
      );
      expect(under.hasOvervoltage, isFalse, reason: '4.190 is under the 4.200 fallback');
      expect(under.overCell, isNull);
    });
  });

  group('battery diagnostics mock', () {
    void withApp(void Function(FakeAsync async, ProviderContainer c, BatteryDiagnosticsNotifier n) body) {
      fakeAsync((async) {
        final c = ProviderContainer();
        c.listen(batteryDiagnosticsProvider, (_, _) {});
        c.read(vehicleProvider.notifier).setConnected(true);
        body(async, c, c.read(batteryDiagnosticsProvider.notifier));
        c.dispose();
      });
    }

    test('starts healthy with the documented figures', () {
      withApp((async, c, n) {
        final d = c.read(batteryDiagnosticsProvider);
        expect(d.cells.length, 14);
        expect(d.temps.length, 8);
        expect(d.temps.map((t) => t.label), ['Pack 1', 'Pack 2', 'Pack 3', 'Pack 4', 'Pack 5', 'Pack 6', 'Controller', 'Motor']);
        expect(d.soh, 96);
        expect(d.busVoltage, closeTo(51.2, 0.05));
        expect(d.batteryCurrent, closeTo(0.5, 0.05));
        expect(d.dischargeLimitW, 18000);
        expect(d.regenLimitW, 3200);
        expect(d.balancingActive, isFalse);
        expect(d.balancingNeeded, isFalse);
        expect(d.cellSpreadMv, inInclusiveRange(10, 16));
        expect(d.cells[6].voltage, d.cells.map((c) => c.voltage).reduce((a, b) => a < b ? a : b), reason: 'cell 7 runs lowest');
        expect(d.cells[10].voltage, d.cells.map((c) => c.voltage).reduce((a, b) => a > b ? a : b), reason: 'cell 11 runs highest');
        expect(d.cells[6].deviationMv, lessThan(-5));
        expect(d.cells[10].deviationMv, greaterThan(4));
        for (final t in d.temps.take(6)) {
          expect(t.tempC, inInclusiveRange(28, 35));
        }
        expect(d.temps[6].tempC, inInclusiveRange(40, 48));
        expect(d.temps[7].tempC, c.read(vehicleProvider).motorTemp.toDouble());
      });
    });

    test('the resistor temperature is present and warms while balancing', () {
      withApp((async, c, n) {
        final rest = c.read(batteryDiagnosticsProvider).balancingTemp;
        expect(rest, isNotNull);
        expect(rest, inInclusiveRange(20, 45));
        n.setBalancing(true);
        async.elapse(const Duration(seconds: 6));
        expect(c.read(batteryDiagnosticsProvider).balancingTemp, greaterThan(rest!),
            reason: 'bleeding the cells heats the resistors');
      });
    });

    test('the overvoltage demo pushes a cell over the max and flags it', () {
      withApp((async, c, n) {
        expect(c.read(batteryDiagnosticsProvider).hasOvervoltage, isFalse);
        n.setOvervoltage(true);
        final d = c.read(batteryDiagnosticsProvider);
        expect(d.hasOvervoltage, isTrue);
        expect(d.overCell!.voltage, greaterThan(4.2));
        n.setOvervoltage(false);
        expect(c.read(batteryDiagnosticsProvider).hasOvervoltage, isFalse);
      });
    });

    test('ticks every few seconds with tiny jitter and stays healthy', () {
      withApp((async, c, n) {
        final before = c.read(batteryDiagnosticsProvider);
        async.elapse(const Duration(seconds: 3));
        final after = c.read(batteryDiagnosticsProvider);
        expect(identical(before, after), isFalse, reason: 'a tick landed');
        for (var i = 0; i < 14; i++) {
          expect((after.cells[i].voltage - before.cells[i].voltage).abs(), lessThanOrEqualTo(0.0011));
        }
        for (var i = 0; i < 6; i++) {
          expect((after.temps[i].tempC! - before.temps[i].tempC!).abs(), lessThanOrEqualTo(0.11));
        }
        async.elapse(const Duration(seconds: 30));
        expect(c.read(batteryDiagnosticsProvider).balancingNeeded, isFalse, reason: 'jitter never drifts into uneven');
      });
    });

    test('degraded cells pulls cells 3 and 11 apart until the pack reads uneven', () {
      withApp((async, c, n) {
        n.setDegradedCells(true);
        final d = c.read(batteryDiagnosticsProvider);
        expect(d.cells[2].voltage, closeTo(3.780, 0.002));
        expect(d.cells[10].voltage, closeTo(3.950, 0.002));
        expect(d.cells[2].state, CellState.low);
        expect(d.cells[10].state, CellState.high);
        expect(d.balancingNeeded, isTrue);
        expect(d.cellSpreadMv, greaterThan(40));
        n.setDegradedCells(false);
        expect(c.read(batteryDiagnosticsProvider).balancingNeeded, isFalse);
      });
    });

    test('hot pack pushes the six pack sensors to 48-55C and back', () {
      withApp((async, c, n) {
        n.setHotPack(true);
        for (final t in c.read(batteryDiagnosticsProvider).temps.take(6)) {
          expect(t.tempC, inInclusiveRange(48, 55));
        }
        n.setHotPack(false);
        for (final t in c.read(batteryDiagnosticsProvider).temps.take(6)) {
          expect(t.tempC, inInclusiveRange(28, 35));
        }
      });
    });

    test('balancing flag toggles and the motor sensor follows the vehicle', () {
      withApp((async, c, n) {
        n.setBalancing(true);
        expect(c.read(batteryDiagnosticsProvider).balancingActive, isTrue);
        expect(n.balancing, isTrue);
        expect(n.degradedCells, isFalse);
        expect(n.hotPack, isFalse);
        c.read(vehicleProvider.notifier).setMotorTemp(52);
        expect(c.read(batteryDiagnosticsProvider).temps[7].tempC, 52);
      });
    });

    test('pack current follows the vehicle power, positive out of the pack', () {
      withApp((async, c, n) {
        expect(c.read(batteryDiagnosticsProvider).batteryCurrent, closeTo(0.5, 0.01), reason: 'idle drain leaves the pack');
        c.read(vehicleProvider.notifier).setPower(3.8);
        var d = c.read(batteryDiagnosticsProvider);
        expect(d.batteryCurrent, closeTo(3800 / d.busVoltage!, 0.05));
        expect(d.packPowerKw, closeTo(3.8, 0.01));
        c.read(vehicleProvider.notifier).setPower(-2.0);
        d = c.read(batteryDiagnosticsProvider);
        expect(d.batteryCurrent, lessThan(0), reason: 'regen flows in');
        expect(d.packPowerKw, closeTo(-2.0, 0.01));
      });
    });

    test('state of health follows the battery health flag', () {
      withApp((async, c, n) {
        expect(c.read(batteryDiagnosticsProvider).soh, 96);
        c.read(vehicleProvider.notifier).setBatteryHealth(false);
        expect(c.read(batteryDiagnosticsProvider).soh, lessThan(90));
        c.read(vehicleProvider.notifier).setBatteryHealth(true);
        expect(c.read(batteryDiagnosticsProvider).soh, 96);
      });
    });
  });
}
