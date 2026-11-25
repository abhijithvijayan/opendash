import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/battery_diagnostics.dart';
import '../../models/battery_health.dart';
import '../../providers/battery_diagnostics_provider.dart';
import '../../providers/mock_provider.dart';
import '../../state/battery_health_state.dart';
import '../../state/charge_energy_state.dart';
import '../../state/format_settings.dart';
import '../../state/riding_settings.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';
import 'cell_bar_chart.dart';
import 'diag_info.dart';
import 'temp_heatmap.dart';

/// The label, value and colour of the balance stat tile. An overvoltage cell
/// (over the pack's own max) takes over the tile in red, since it matters more
/// than the deviation-based even/uneven read.
typedef BalanceTile = ({String label, String value, Color color});

BalanceTile balanceTile(BatteryDiagnostics d) {
  final over = d.overCell;
  if (over != null) {
    return (label: 'Cell ${over.index} over', value: '${over.voltage.toStringAsFixed(3)} V', color: DashColors.critical);
  }
  return (
    label: 'Balance',
    value: d.balancingNeeded ? 'Uneven' : 'Even',
    color: d.balancingNeeded ? DashColors.warning : DashColors.eco,
  );
}

/// What the companion dashboard shows on a laptop, on the scooter's own
/// screen: pack health, every cell, every sensor, and the bus figures.
class BatteryTab extends ConsumerWidget {
  const BatteryTab({super.key});

  static const gap = 12.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(batteryDiagnosticsProvider);
    final soh = d.soh;
    final spread = d.cellSpreadMv;
    final measuredKwh = ref.watch(measuredCapacityProvider);
    // The real capacity: measured over charges if we have them, else the
    // BMS's own usable-energy figure (0x651 x 0x653). The SoH, which reads
    // 100 on a worn pack, is no longer the headline.
    final capacityKwh = measuredKwh ?? d.usableKwh;
    final capacityLabel = measuredKwh != null
        ? 'Capacity (measured)'
        : d.usableKwh != null
            ? 'Capacity (BMS)'
            : 'State of health';
    final layout = d.cellsInSeries != null && d.cellsInParallel != null
        ? '  ·  ${d.cellsInSeries}S${d.cellsInParallel}P'
        : '';
    final trueRangeOn = ref.watch(
      ridingSettingsProvider.select((s) => s.isOn(RidingFeature.predictedRange)),
    );
    final trueRange = ref.watch(trueRangeProvider);
    final rangeKnown = ref.watch(vehicleProvider.select((v) => v.rangeKnown));
    final useMiles = ref.watch(useMilesProvider);
    final health = ref.watch(batteryHealthProvider);
    final (packMin, packMax) = ref.watch(vehicleProvider.select((v) => (v.batteryMinTemp, v.batteryMaxTemp)));
    final useF = ref.watch(useFahrenheitProvider);
    return SingleChildScrollView(
      key: const ValueKey('diag-battery'),
      physics: const ClampingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: DiagStatTile(
                  key: const ValueKey('diag-capacity'), infoId: 'capacity',
                  label: capacityLabel + layout,
                  value: capacityKwh != null
                      ? '${capacityKwh.toStringAsFixed(2)} kWh'
                      : soh == null
                          ? '—'
                          : '${soh.round()}%',
                  color: DashColors.bone,
                ),
              ),
              const SizedBox(width: gap),
              Expanded(
                child: DiagStatTile(
                  key: const ValueKey('diag-spread'), infoId: 'spread',
                  label: 'Cell spread',
                  value: spread == null ? '—' : '${spread.round()} mV',
                  color: spread == null ? DashColors.ash : spread <= 20 ? DashColors.eco : spread <= 40 ? DashColors.warning : DashColors.critical,
                ),
              ),
              const SizedBox(width: gap),
              Expanded(
                child: DiagStatTile(
                  key: const ValueKey('diag-avg'), infoId: 'avg',
                  label: 'Average cell',
                  value: d.cellAvgV == null ? '—' : '${d.cellAvgV!.toStringAsFixed(3)} V',
                  color: DashColors.bone,
                ),
              ),
              const SizedBox(width: gap),
              Expanded(
                child: Builder(builder: (_) {
                  final t = balanceTile(d);
                  return DiagStatTile(key: const ValueKey('diag-balance'), infoId: 'balance', label: t.label, value: t.value, color: t.color);
                }),
              ),
            ],
          ),
          if (d.cycleCount != null) ...[
            const SizedBox(height: gap),
            Row(
              children: [
                Expanded(
                  child: DiagStatTile(
                    key: const ValueKey('diag-cycles'), infoId: 'cycles',
                    label: 'Charge cycles',
                    value: d.cycleCount == null ? '—' : '${d.cycleCount}',
                    color: DashColors.bone,
                  ),
                ),
                const SizedBox(width: gap),
                const Expanded(child: SizedBox.shrink()),
                const SizedBox(width: gap),
                const Expanded(child: SizedBox.shrink()),
                const SizedBox(width: gap),
                const Expanded(child: SizedBox.shrink()),
              ],
            ),
          ],
          if (d.chargingRatePercent != null) ...[
            const SizedBox(height: gap),
            Row(
              children: [
                Expanded(
                  child: DiagStatTile(
                    key: const ValueKey('diag-charge-rate'), infoId: 'charge-rate',
                    label: 'Charge rate',
                    value: '${d.chargingRatePercent}%',
                    color: DashColors.eco,
                  ),
                ),
                const SizedBox(width: gap),
                Expanded(
                  child: DiagStatTile(
                    key: const ValueKey('diag-eta-fast'),
                    label: 'To full (fast)',
                    value: etaLabel(d.etaFastToFullMin),
                    color: DashColors.bone,
                  ),
                ),
                const SizedBox(width: gap),
                Expanded(
                  child: DiagStatTile(
                    key: const ValueKey('diag-eta-slow'),
                    label: 'To full (slow)',
                    value: etaLabel(d.etaSlowToFullMin),
                    color: DashColors.ash,
                  ),
                ),
                const SizedBox(width: gap),
                const Expanded(child: SizedBox.shrink()),
              ],
            ),
          ],
          if (trueRangeOn) ...[
            const SizedBox(height: gap),
            Row(
              children: [
                Expanded(
                  child: DiagStatTile(
                    key: const ValueKey('diag-true-range'), infoId: 'true-range',
                    label: 'True range',
                    value: rangeKnown ? '${toDisplayDistance(trueRange.trueRangeKm, useMiles)} ${distanceUnit(useMiles)}' : '—',
                    color: DashColors.bone,
                  ),
                ),
                const SizedBox(width: gap),
                Expanded(
                  child: DiagStatTile(
                    key: const ValueKey('diag-stock-range'),
                    label: 'Stock range',
                    value: rangeKnown ? '${toDisplayDistance(trueRange.stockRangeKm, useMiles)} ${distanceUnit(useMiles)}' : '—',
                    color: DashColors.ash,
                  ),
                ),
                const SizedBox(width: gap),
                Expanded(
                  child: DiagStatTile(
                    key: const ValueKey('diag-km-pct'), infoId: 'km-pct',
                    label: '${distanceUnit(useMiles)}/%',
                    value: trueRange.kmPerPercent > 0 ? toDisplayDistanceD(trueRange.kmPerPercent, useMiles).toStringAsFixed(2) : '—',
                    color: DashColors.bone,
                  ),
                ),
                const SizedBox(width: gap),
                Expanded(
                  child: DiagStatTile(
                    key: const ValueKey('diag-confidence'), infoId: 'confidence',
                    label: 'Confidence',
                    value: '${trueRange.confidencePercent}%',
                    color: trueRange.confidencePercent >= 70 ? DashColors.eco : trueRange.confidencePercent >= 30 ? DashColors.warning : DashColors.ash,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: gap),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  children: [
                    _Card(
                      title: 'Cell voltages',
                      child: CellBarChart(cells: d.cells, avgVoltage: d.cellAvgV, balancingCells: d.balancingCells),
                    ),
                    const SizedBox(height: gap),
                    _Card(title: 'Pack electrical', child: _PackElectrical(d)),
                  ],
                ),
              ),
              const SizedBox(width: gap),
              Expanded(
                child: Column(
                  children: [
                    _Card(
                      title: 'Temperatures',
                      child: Column(
                        children: [
                          TempHeatmap(temps: d.temps, balancingTempC: d.balancingTemp, useFahrenheit: useF),
                          const SizedBox(height: 8),
                          // HHMIS's own coldest / hottest pack reading
                          // (FLOAT_BATTERY_MIN_TEMP / MAX_TEMP); present
                          // even when the CAN stream is not.
                          _ValueRow(key: const ValueKey('diag-pack-min'), label: 'Pack min', value: _packTemp(packMin, useF)),
                          _ValueRow(key: const ValueKey('diag-pack-max'), label: 'Pack max', value: _packTemp(packMax, useF)),
                        ],
                      ),
                    ),
                    const SizedBox(height: gap),
                    if (health.snapshots.length >= 2)
                      _Card(
                        title: 'Cell spread trend',
                        child: _CellSpreadTrend(snapshots: health.snapshots),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (trueRangeOn && health.segments.isNotEmpty) ...[
            const SizedBox(height: gap),
            _Card(
              title: 'Ride history',
              child: _RideHistoryTable(segments: health.segments, useMiles: useMiles, useFahrenheit: useF),
            ),
          ],
        ],
      ),
    );
  }
}

/// Minutes to "Xh Ym" (or "Ym" under an hour); "—" when unknown or zero.
String etaLabel(int? minutes) {
  if (minutes == null || minutes <= 0) return '—';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return h > 0 ? '${h}h ${m}m' : '${m}m';
}

String _packTemp(double? celsius, bool useF) =>
    celsius == null ? '—' : '${(useF ? celsius * 9 / 5 + 32 : celsius).toStringAsFixed(1)} ${tempUnit(useF)}';

class _ValueRow extends StatelessWidget {
  const _ValueRow({super.key, required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 26,
      child: Row(
        children: [
          Text(label, style: DashText.caption(15)),
          const Spacer(),
          Text(value, style: DashText.value(17, color: color ?? DashColors.bone)),
        ],
      ),
    );
  }
}

/// The readout-card look, a size up: label on top, value centred. When given an
/// [infoId] with a catalog entry, a tap reveals its one-liner and the tile
/// carries a small ⓘ hint.
class DiagStatTile extends StatelessWidget {
  const DiagStatTile({super.key, required this.label, required this.value, required this.color, this.infoId});
  final String label;
  final String value;
  final Color color;
  final String? infoId;

  @override
  Widget build(BuildContext context) {
    final info = infoFor(infoId);
    final tile = Container(
      height: 72,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(color: DashColors.inkLift, borderRadius: BorderRadius.circular(DashRadius.card)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: DashText.caption(13))),
              if (info != null)
                Text('ⓘ', style: DashText.caption(13, color: DashColors.ash.withValues(alpha: 0.7))),
            ],
          ),
          Expanded(
            child: Center(
              child: AnimatedDefaultTextStyle(
                duration: DashMotion.fast,
                style: DashText.value(26, color: color),
                child: Text(value),
              ),
            ),
          ),
        ],
      ),
    );
    if (info == null) return tile;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showDiagInfo(context, label, info),
      child: tile,
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(DashSpace.cardPad),
      decoration: BoxDecoration(color: DashColors.inkLift, borderRadius: BorderRadius.circular(DashRadius.card)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: DashText.caption(13).copyWith(letterSpacing: 1.2)),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _PackElectrical extends StatelessWidget {
  const _PackElectrical(this.d);
  final BatteryDiagnostics d;

  @override
  Widget build(BuildContext context) {
    String signed(double? x, int decimals, String unit) =>
        x == null ? '—' : '${x >= 0 ? '+' : ''}${x.toStringAsFixed(decimals)} $unit';
    final rows = <(String, String, Color?)>[
      ('Voltage', d.packVoltage == null ? '—' : '${d.packVoltage!.toStringAsFixed(2)} V', null),
      ('Current', signed(d.batteryCurrent, 1, 'A'), null),
      ('Power', signed(d.packPowerKw, 2, 'kW'), null),
      ('Discharge limit', d.dischargeLimitW == null ? '—' : '${d.dischargeLimitW!.round()} W', null),
      ('Regen limit', d.regenLimitW == null ? '—' : '${d.regenLimitW!.round()} W', null),
      ('Balancing', d.balancingActive ? 'Active' : 'Inactive', d.balancingActive ? DashColors.eco : DashColors.ash),
    ];
    return Column(
      children: [
        for (final (label, value, color) in rows) _ValueRow(label: label, value: value, color: color),
      ],
    );
  }
}

class _RideHistoryTable extends StatelessWidget {
  const _RideHistoryTable({required this.segments, required this.useMiles, required this.useFahrenheit});
  final List<RideSegment> segments;
  final bool useMiles;
  final bool useFahrenheit;

  @override
  Widget build(BuildContext context) {
    final recent = segments.length > 10 ? segments.sublist(segments.length - 10) : segments;
    final reversed = recent.reversed.toList();
    final hStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: DashColors.ash, fontFeatures: [FontFeature.tabularFigures()]);
    final vStyle = DashText.caption(13, color: DashColors.bone);
    return Column(
      children: [
        Row(
          children: [
            SizedBox(width: 60, child: Text('Date', style: hStyle)),
            SizedBox(width: 60, child: Text('Mode', style: hStyle)),
            SizedBox(width: 72, child: Text('Distance', style: hStyle)),
            SizedBox(width: 72, child: Text('SOC used', style: hStyle)),
            SizedBox(width: 56, child: Text('${distanceUnit(useMiles)}/%', style: hStyle)),
            SizedBox(width: 48, child: Text('Temp', style: hStyle)),
          ],
        ),
        const SizedBox(height: 4),
        for (final seg in reversed)
          SizedBox(
            height: 24,
            child: Row(
              children: [
                SizedBox(width: 60, child: Text(_formatDate(seg.timestamp), style: vStyle)),
                SizedBox(width: 60, child: Text(driveModeFromIndex(seg.driveMode).label, style: vStyle)),
                SizedBox(width: 72, child: Text('${_segmentDistance(seg, useMiles)} ${distanceUnit(useMiles)}', style: vStyle)),
                SizedBox(width: 72, child: Text('${seg.socUsed.toStringAsFixed(1)}%', style: vStyle)),
                SizedBox(width: 56, child: Text(toDisplayDistanceD(seg.kmPerPercent, useMiles).toStringAsFixed(2), style: vStyle)),
                SizedBox(width: 48, child: Text('${toDisplayTemp(seg.avgTempC.round(), useFahrenheit)}${tempUnit(useFahrenheit)}', style: vStyle)),
              ],
            ),
          ),
      ],
    );
  }

  /// A distance measured in metres to one decimal; the whole-km
  /// odometer's to the kilometre it can tell.
  static String _segmentDistance(RideSegment seg, bool useMiles) => seg.distanceM != null
      ? toDisplayDistanceD(seg.distanceKm, useMiles).toStringAsFixed(1)
      : '${toDisplayDistance(seg.distanceKm.round(), useMiles)}';

  String _formatDate(int epoch) {
    final d = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${months[d.month - 1]} ${d.day.toString().padLeft(2, '0')}';
  }
}

class _CellSpreadTrend extends StatelessWidget {
  const _CellSpreadTrend({required this.snapshots});
  final List<BatteryHealthSnapshot> snapshots;

  @override
  Widget build(BuildContext context) {
    final points = snapshots.map((s) => s.cellSpreadMv).toList();
    if (points.length < 2) return const SizedBox.shrink();
    final trending = points.length >= 5 &&
        points.sublist(points.length - 5).reduce((a, b) => a + b) / 5 >
            points.sublist(0, (points.length / 2).floor()).reduce((a, b) => a + b) /
                (points.length / 2).floor();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 60,
          child: CustomPaint(
            size: const Size(double.infinity, 60),
            painter: _SparklinePainter(points),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text('${points.last.round()} mV', style: DashText.caption(13, color: DashColors.bone)),
            if (trending) ...[
              const SizedBox(width: 6),
              Text('↑', style: DashText.value(14, color: DashColors.warning)),
            ],
          ],
        ),
      ],
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.points);
  final List<double> points;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    var min = points[0], max = points[0];
    for (final p in points) {
      if (p < min) min = p;
      if (p > max) max = p;
    }
    final range = max - min;
    final yScale = range > 0 ? size.height * 0.8 / range : 1.0;
    final xStep = size.width / (points.length - 1);
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = i * xStep;
      final y = size.height * 0.9 - (points[i] - min) * yScale;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = DashColors.bone
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) => true;
}
