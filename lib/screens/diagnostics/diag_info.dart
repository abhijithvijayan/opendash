import 'package:material_ui/material_ui.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// A one-line explanation of a diagnostics readout, with an optional healthy
/// range (Sola-style), revealed when the tile is tapped.
class DiagInfo {
  const DiagInfo(this.description, {this.range});
  final String description;

  /// The normal/healthy band, shown under the description when present.
  final String? range;
}

/// Descriptions keyed by a stable id passed to the tile (not the visible
/// label, which can change — e.g. "Capacity (measured)" vs "(BMS)"). Only the
/// readouts that aren't self-evident get an entry; the rest stay plain.
const diagInfo = <String, DiagInfo>{
  'capacity': DiagInfo(
    'Usable pack energy — measured over your own charges when OpenDash has them, otherwise the BMS’s own figure. More honest than SoH on a worn pack.',
  ),
  'spread': DiagInfo(
    'The gap between the highest and lowest cell. Small is healthy; a widening gap points to a weak or ageing cell.',
    range: 'Under 20 mV healthy · over 40 mV investigate',
  ),
  'avg': DiagInfo('The pack’s average cell voltage — roughly where every cell sits at this charge level.'),
  'balance': DiagInfo(
    'Whether the cells are even. Flips to a red over-max callout if any cell climbs past the BMS’s charge-end voltage.',
  ),
  'confidence': DiagInfo(
    'How much to trust the learned True range. It grows ~10% per ride logged and maxes out after about ten rides.',
  ),
  'km-pct': DiagInfo('Distance per 1% of charge, learned from your rides — the number behind True range.'),
  'true-range': DiagInfo('Range learned from how far you actually go per %, not the stock estimate.'),
  'cycles': DiagInfo('Lifetime charge cycles the BMS has counted — a measure of pack age.'),
  'charge-rate': DiagInfo('How fast the pack is taking charge right now.'),
  'pdu-temp': DiagInfo(
    'The BMS power-electronics (PDU) temperature — runs hotter than the cells and has its own limit.',
    range: 'Derates near 85 °C',
  ),
  'mcu-temp': DiagInfo(
    'The motor-controller (inverter) temperature — usually the first thing to overheat and derate.',
    range: 'Derates near 84 °C',
  ),
  'motor-temp': DiagInfo('The motor winding temperature.', range: 'Derates near 147 °C'),
  'battery-temp': DiagInfo('The cell/pack temperature.', range: 'Warns near 55 °C'),
  'balancing-temp': DiagInfo(
    'Temperature of the cell-balancing resistor array, which heats while the BMS bleeds high cells.',
    range: '20–60 °C normal',
  ),
};

DiagInfo? infoFor(String? id) => id == null ? null : diagInfo[id];

/// Maps a temperature tile's label to its info id (the heatmap labels vary:
/// the mock calls the controller "Controller", the decoder "MCU").
String? tempInfoId(String label) => switch (label) {
      'PDU' => 'pdu-temp',
      'MCU' || 'Controller' => 'mcu-temp',
      'Motor' => 'motor-temp',
      'Balancing' => 'balancing-temp',
      _ => null,
    };

/// Shows a readout's one-line explanation (and healthy range, if any) in a
/// small dialog. Used by the tiles that carry an info entry.
void showDiagInfo(BuildContext context, String title, DiagInfo info) {
  showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: DashColors.inkLift,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: DashText.value(18)),
              const SizedBox(height: 10),
              Text(info.description, style: DashText.caption(15, color: DashColors.bone)),
              if (info.range != null) ...[
                const SizedBox(height: 10),
                Text(info.range!, style: DashText.caption(14, color: DashColors.eco)),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
