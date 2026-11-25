enum CellState { ok, high, low, over, missing }

/// One of the fourteen series cells, as the BMS reports it over CAN
/// (0x1A5, 0x1A6, 0x1A9, 0x1AA).
class CellReading {
  const CellReading({required this.index, required this.voltage, required this.deviationMv, required this.state});

  /// 1-14.
  final int index;
  final double voltage;

  /// Millivolts from the pack average; signed.
  final double deviationMv;
  final CellState state;
}

/// A pack sensor (0x1A4, 0x1A7), or the controller and motor sensors that
/// ride alongside them in the heatmap. Null when the sensor is silent.
class PackTemperature {
  const PackTemperature({required this.label, this.tempC});
  final String label;
  final double? tempC;
}

class BatteryDiagnostics {
  const BatteryDiagnostics({
    this.cells = const [],
    this.temps = const [],
    this.soh,
    this.busVoltage,
    this.packVoltage,
    this.batteryCurrent,
    this.cellSpreadMv,
    this.cellAvgV,
    this.cellMinV,
    this.cellMaxV,
    this.dischargeLimitW,
    this.regenLimitW,
    this.balancingActive = false,
    this.balancingNeeded = false,
    this.balancingCells = const [],
    this.cellsInSeries,
    this.cellsInParallel,
    this.usableKwh,
    this.chargeEndCellMv,
    this.balancingTemp,
    this.cycleCount,
    this.chargingRatePercent,
    this.etaSlowToFullMin,
    this.etaFastToFullMin,
  });

  /// Cells further than this from the average are uneven.
  static const balanceThresholdMv = 20.0;

  /// The LG M50's datasheet max cell voltage (mV), used as the overvoltage
  /// line when the BMS's own charge-end limit (0x653) has not arrived.
  static const fallbackCellMaxMv = 4200.0;

  final List<CellReading> cells;
  final List<PackTemperature> temps;
  final double? soh;
  /// DC-link bus volts (0x150); ~25 V parked with the contactor open.
  final double? busVoltage;

  /// Measured pack volts (0x1A8 b4-5).
  final double? packVoltage;

  /// Amps; negative while the pack is drawn on, positive while charging
  /// or regenerating.
  final double? batteryCurrent;
  final double? cellSpreadMv;
  final double? cellAvgV;
  final double? cellMinV;
  final double? cellMaxV;
  final double? dischargeLimitW;
  final double? regenLimitW;
  final bool balancingActive;
  final bool balancingNeeded;

  /// 1-indexed cells the BMS reports as balancing (0x170).
  final List<int> balancingCells;

  /// Pack layout (0x651) and usable energy (0x651 x 0x653), as the BMS
  /// states them; null until those config frames arrive.
  final int? cellsInSeries;
  final int? cellsInParallel;
  final double? usableKwh;

  /// 0x653: the per-cell voltage (mV) at which charging stops.
  final int? chargeEndCellMv;

  /// 0x1A8 bits 48-63: the balancing-resistor temperature (°C). Null until the
  /// frame arrives.
  final double? balancingTemp;

  /// 0x6D8: lifetime charge-cycle count. Null until that BMS cloud frame
  /// arrives.
  final int? cycleCount;

  /// 0x180/0x190: charging rate (%), and minutes to a full charge on the slow
  /// and fast chargers. Null until those frames arrive (only while charging).
  final int? chargingRatePercent;
  final int? etaSlowToFullMin;
  final int? etaFastToFullMin;

  static bool _present(double v) => v.isFinite && v > 0;

  static double _mv(double volts) => (volts * 10000).round() / 10;

  /// Any cell above the pack's max cell voltage (0x653, else the M50 max).
  bool get hasOvervoltage => cells.any((c) => c.state == CellState.over);

  /// The highest-voltage cell over the max, or null when none is over. Names
  /// the worst offender for the pack warning.
  CellReading? get overCell {
    CellReading? worst;
    for (final c in cells) {
      if (c.state == CellState.over && (worst == null || c.voltage > worst.voltage)) worst = c;
    }
    return worst;
  }

  /// Pack voltage times battery current, in kW; null without both.
  double? get packPowerKw =>
      packVoltage == null || batteryCurrent == null ? null : packVoltage! * batteryCurrent! / 1000;

  /// Derives the per-cell states and the pack figures from raw readings. A
  /// zero, negative or non-finite cell is a missing reading and stays out
  /// of the maths. Millivolt figures are rounded to 0.1mV so a reading on
  /// the 20mV line is not pushed over it by float noise.
  factory BatteryDiagnostics.compute({
    required List<double> cellVoltages,
    required List<PackTemperature> temps,
    double? soh,
    double? busVoltage,
    double? packVoltage,
    double? batteryCurrent,
    double? dischargeLimitW,
    double? regenLimitW,
    bool balancingActive = false,
    List<int> balancingCells = const [],
    int? cellsInSeries,
    int? cellsInParallel,
    double? usableKwh,
    int? chargeEndCellMv,
    double? balancingTemp,
    int? cycleCount,
    int? chargingRatePercent,
    int? etaSlowToFullMin,
    int? etaFastToFullMin,
  }) {
    final present = cellVoltages.where(_present).toList();
    final avg = present.isEmpty ? null : present.reduce((a, b) => a + b) / present.length;
    double? min, max;
    for (final v in present) {
      if (min == null || v < min) min = v;
      if (max == null || v > max) max = v;
    }
    final overMv = (chargeEndCellMv?.toDouble() ?? fallbackCellMaxMv);
    final cells = <CellReading>[];
    var uneven = false;
    for (var i = 0; i < cellVoltages.length; i++) {
      final v = cellVoltages[i];
      if (!_present(v) || avg == null) {
        cells.add(CellReading(index: i + 1, voltage: 0, deviationMv: 0, state: CellState.missing));
        continue;
      }
      final dev = _mv(v - avg);
      if (dev > balanceThresholdMv || dev < -balanceThresholdMv) uneven = true;
      // Overvoltage is absolute (over the pack's own max cell voltage) and
      // wins over the deviation-relative high/low, so a pack that drifted high
      // together still shows red rather than a reassuring "even".
      final state = _mv(v) > overMv
          ? CellState.over
          : dev > balanceThresholdMv
              ? CellState.high
              : dev < -balanceThresholdMv
                  ? CellState.low
                  : CellState.ok;
      cells.add(CellReading(index: i + 1, voltage: v, deviationMv: dev, state: state));
    }
    return BatteryDiagnostics(
      cells: cells,
      temps: temps,
      soh: soh,
      busVoltage: busVoltage,
      packVoltage: packVoltage,
      batteryCurrent: batteryCurrent,
      cellSpreadMv: min == null || max == null ? null : _mv(max - min),
      cellAvgV: avg,
      cellMinV: min,
      cellMaxV: max,
      dischargeLimitW: dischargeLimitW,
      regenLimitW: regenLimitW,
      balancingActive: balancingActive,
      balancingNeeded: uneven,
      balancingCells: balancingCells,
      cellsInSeries: cellsInSeries,
      cellsInParallel: cellsInParallel,
      usableKwh: usableKwh,
      chargeEndCellMv: chargeEndCellMv,
      balancingTemp: balancingTemp,
      cycleCount: cycleCount,
      chargingRatePercent: chargingRatePercent,
      etaSlowToFullMin: etaSlowToFullMin,
      etaFastToFullMin: etaFastToFullMin,
    );
  }
}
