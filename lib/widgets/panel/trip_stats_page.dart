import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/vehicle_data.dart';
import '../../providers/mock_provider.dart';
import '../../state/energy_used_state.dart';
import '../../state/format_settings.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../util/format.dart';
import 'trip_icons.dart';
import 'widget_panel.dart';

/// One "By mode" bar: its label, colour, distance today and bar fraction.
class ModeBar {
  const ModeBar(this.key, this.label, this.color, this.km, this.fraction);
  final String key;
  final String label;
  final Color color;
  final double km;
  final double fraction;
}

/// The bars to draw, longest ride = 1. The rider's own mode (MoveOS 5) is
/// appended when the scooter has told us it exists, so it shows from boot
/// and not only once it is selected.
List<ModeBar> modeBars(VehicleData v) {
  final base = <(String, String, Color, double)>[
    ('eco', DriveMode.eco.label, DashColors.forMode(DriveMode.eco), v.ecoDistance),
    ('normal', DriveMode.normal.label, DashColors.forMode(DriveMode.normal), v.normalDistance),
    ('sport', DriveMode.sport.label, DashColors.forMode(DriveMode.sport), v.sportDistance),
    ('hyper', DriveMode.hyper.label, DashColors.forMode(DriveMode.hyper), v.hyperDistance),
    if (v.customRide.known)
      ('custom', v.customRide.label.toUpperCase(), DashColors.bone, v.customRide.todayKm ?? 0),
  ];
  final max = base.fold(0.0, (a, e) => a > e.$4 ? a : e.$4);
  return [for (final e in base) ModeBar(e.$1, e.$2, e.$3, e.$4, max <= 0 ? 0.0 : e.$4 / max)];
}

/// Bar fraction per mode, longest ride = 1. (Kept for existing callers.)
Map<DriveMode, double> modeBarFractions(VehicleData v) {
  final km = {
    DriveMode.eco: v.ecoDistance,
    DriveMode.normal: v.normalDistance,
    DriveMode.sport: v.sportDistance,
    DriveMode.hyper: v.hyperDistance,
  };
  final max = km.values.fold(0.0, (a, b) => a > b ? a : b);
  return {for (final e in km.entries) e.key: max <= 0 ? 0.0 : e.value / max};
}

class TripStatsPage extends ConsumerWidget {
  const TripStatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(
      vehicleProvider.select(
        (v) => (
          v.dailyDistance,
          v.dailyTopSpeed,
          v.dailyAvgSpeed,
          v.ecoDistance,
          v.normalDistance,
          v.sportDistance,
          v.hyperDistance,
          v.regenEnergy,
          v.customRide,
        ),
      ),
    );
    final energyUsed = ref.watch(energyUsedProvider);
    final efficiency = ref.watch(vehicleProvider.select((v) => v.rideEfficiency));
    final useMiles = ref.watch(useMilesProvider);
    final data = VehicleData(
      dailyDistance: v.$1,
      dailyTopSpeed: v.$2,
      dailyAvgSpeed: v.$3,
      ecoDistance: v.$4,
      normalDistance: v.$5,
      sportDistance: v.$6,
      hyperDistance: v.$7,
      regenEnergy: v.$8,
      energyUsed: energyUsed,
      customRide: v.$9,
    );
    final bars = modeBars(data);

    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 0, 40, WidgetPanel.dotsReserve),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('Today', style: DashText.caption(14)),
          const SizedBox(height: 10),
          _StatRow(
            glyph: TripGlyph.route,
            value: toDisplayDistance(data.dailyDistance, useMiles).toDouble(),
            unit: distanceUnit(useMiles),
          ),
          const SizedBox(height: 10),
          _StatRow(
            glyph: TripGlyph.topSpeed,
            value: toDisplayDistance(data.dailyTopSpeed, useMiles).toDouble(),
            unit: '${speedUnit(useMiles)} top',
          ),
          const SizedBox(height: 10),
          _StatRow(
            glyph: TripGlyph.average,
            value: toDisplayDistance(data.dailyAvgSpeed, useMiles).toDouble(),
            unit: '${speedUnit(useMiles)} avg',
          ),
          const SizedBox(height: 10),
          _StatRow(
            key: const ValueKey('trip-regen'),
            glyph: TripGlyph.regen,
            iconColor: DashColors.eco,
            value: data.regenEnergy,
            decimals: 2,
            unit: 'kWh regen',
          ),
          const SizedBox(height: 10),
          _StatRow(
            key: const ValueKey('trip-energy'),
            glyph: TripGlyph.energy,
            value: data.energyUsed,
            decimals: 2,
            unit: 'kWh used',
          ),
          if (efficiency > 0) ...[
            const SizedBox(height: 10),
            _StatRow(
              key: const ValueKey('efficiency'),
              glyph: TripGlyph.energy,
              value: useMiles ? efficiency * kmPerMile : efficiency,
              unit: 'Wh/${distanceUnit(useMiles)} this ride',
            ),
          ],
          const SizedBox(height: 20),
          Text('By mode', style: DashText.caption(14)),
          const SizedBox(height: 8),
          for (final bar in bars)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                key: ValueKey('mode-bar-${bar.key}'),
                children: [
                  SizedBox(
                    width: 72,
                    child: Text(
                      bar.label,
                      style: DashText.mode(bar.color, size: 10),
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: DataBar(
                        fraction: bar.fraction,
                        color: bar.color,
                        width: 88,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 62,
                    child: Text(
                      '${groupThousands(toDisplayDistanceD(bar.km, useMiles).round())} ${distanceUnit(useMiles)}',
                      style: DashText.caption(13, color: DashColors.bone),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    super.key,
    required this.glyph,
    required this.value,
    required this.unit,
    this.iconColor,
    this.decimals = 0,
  });
  final TripGlyph glyph;
  final Color? iconColor;
  final double value;
  final int decimals;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        TripStatIcon(glyph: glyph, color: iconColor ?? DashColors.ash),
        const SizedBox(width: 12),
        AnimatedValue(
          value: value,
          decimals: decimals,
          style: DashText.value(30),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            unit,
            style: DashText.caption(15),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
