import 'package:material_ui/material_ui.dart';

import '../../state/format_settings.dart';
import '../../models/battery_diagnostics.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';
import 'diag_info.dart';

/// Absolute stops, not theme colours: they stand for physical temperature,
/// the same scale the companion dashboard uses.
const tempStops = [
  (20.0, Color(0xFF1a3a4a)),
  (35.0, Color(0xFF2a3a2a)),
  (45.0, Color(0xFF4a3a1a)),
  (55.0, Color(0xFF5a2020)),
];

/// The balancing resistors run warmer than the pack: Sola calls 20-60°C the
/// healthy band, so the amber/red stops sit higher than the pack scale's.
const resistorTempStops = [
  (20.0, Color(0xFF1a3a4a)),
  (50.0, Color(0xFF2a3a2a)),
  (60.0, Color(0xFF4a3a1a)),
  (68.0, Color(0xFF5a2020)),
];

/// Grey for a silent or broken sensor.
const tempSilentColor = Color(0xFF1f2329);

/// Where each stop sits on the 20-55° legend bar.
final legendStops = [for (final (t, _) in tempStops) (t - tempStops.first.$1) / (tempStops.last.$1 - tempStops.first.$1)];

Color tempTileColor(double c, [List<(double, Color)> stops = tempStops]) {
  if (!c.isFinite) return tempSilentColor;
  if (c <= stops.first.$1) return stops.first.$2;
  if (c >= stops.last.$1) return stops.last.$2;
  for (var i = 1; i < stops.length; i++) {
    final (hi, hiColor) = stops[i];
    if (c <= hi) {
      final (lo, loColor) = stops[i - 1];
      return Color.lerp(loColor, hiColor, (c - lo) / (hi - lo))!;
    }
  }
  return stops.last.$2;
}

/// Six pack sensors plus the controller and motor, three across so the
/// card stands as tall as the chart and electrical cards beside it, with
/// the scale underneath.
class TempHeatmap extends StatelessWidget {
  const TempHeatmap({
    super.key,
    required this.temps,
    this.balancingTempC,
    this.columns = 3,
    this.tileHeight = 132,
    this.spacing = 10,
    this.useFahrenheit = false,
  });
  final List<PackTemperature> temps;

  /// The balancing-resistor temperature; when present it joins the grid as a
  /// final tile on its own warmer scale.
  final double? balancingTempC;
  final bool useFahrenheit;
  final int columns;
  final double tileHeight;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      for (final t in temps) (t, tempStops),
      if (balancingTempC != null) (PackTemperature(label: 'Balancing', tempC: balancingTempC), resistorTempStops),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (var i = 0; i < tiles.length; i++)
                  TempTile(
                      key: ValueKey('temp-tile-$i'),
                      reading: tiles[i].$1,
                      stops: tiles[i].$2,
                      width: w,
                      height: tileHeight,
                      useFahrenheit: useFahrenheit),
              ],
            ),
            const SizedBox(height: 14),
            _Legend(key: const ValueKey('temp-legend'), width: constraints.maxWidth, useFahrenheit: useFahrenheit),
          ],
        );
      },
    );
  }
}

class TempTile extends StatelessWidget {
  const TempTile(
      {super.key, required this.reading, required this.width, required this.height, this.stops = tempStops, this.useFahrenheit = false});
  final bool useFahrenheit;
  final PackTemperature reading;
  final List<(double, Color)> stops;
  final double width;
  final double height;

  Color get color => reading.tempC == null ? tempSilentColor : tempTileColor(reading.tempC!, stops);

  @override
  Widget build(BuildContext context) {
    final t = reading.tempC == null || !reading.tempC!.isFinite ? null : reading.tempC;
    final info = infoFor(tempInfoId(reading.label));
    final tile = _tile(t);
    if (info == null) return tile;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showDiagInfo(context, reading.label, info),
      child: tile,
    );
  }

  Widget _tile(double? t) {
    final info = infoFor(tempInfoId(reading.label));
    return AnimatedContainer(
      duration: DashMotion.value,
      curve: DashMotion.valueCurve,
      width: width,
      height: height,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(DashRadius.card)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(reading.label, style: DashText.caption(13, color: Colors.white.withValues(alpha: 0.7)))),
              if (info != null) Text('ⓘ', style: DashText.caption(13, color: Colors.white.withValues(alpha: 0.5))),
            ],
          ),
          const Spacer(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(t == null ? '—' : toDisplayTemp(t.round(), useFahrenheit).toString(), style: DashText.value(26, color: Colors.white)),
              const SizedBox(width: 3),
              Text(tempUnit(useFahrenheit), style: DashText.caption(13, color: Colors.white.withValues(alpha: 0.7))),
            ],
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({super.key, required this.width, required this.useFahrenheit});
  final double width;
  final bool useFahrenheit;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Row(
        children: [
          Text('${toDisplayTemp(tempStops.first.$1.round(), useFahrenheit)}°', style: DashText.caption(13)),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 6,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                gradient: LinearGradient(colors: [for (final (_, c) in tempStops) c], stops: legendStops),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text('${toDisplayTemp(tempStops.last.$1.round(), useFahrenheit)}°', style: DashText.caption(13)),
        ],
      ),
    );
  }
}
