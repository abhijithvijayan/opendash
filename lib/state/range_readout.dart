import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/battery_health.dart';
import '../providers/mock_provider.dart';
import 'battery_health_state.dart';
import 'riding_settings.dart';

enum RangeKind { stock, trueRange, limp }

/// The range figure every screen shows, so the lock screen and the home
/// page cannot disagree.
class RangeReadout {
  const RangeReadout({required this.km, required this.kind, this.approx = false, this.stockKm});

  /// Null while the range is not known (no HHMIS value yet, or stale):
  /// render '—'.
  final int? km;
  final RangeKind kind;

  /// Low confidence in the learned figure: shown rounded and dimmed. A
  /// '~' in front of it was a symbol nobody could read.
  final bool approx;

  /// What the screens print: [km], to the nearest 5 while it is [approx].
  int? get shownKm => km == null || !approx ? km : (km! / 5).round() * 5;

  /// The VCU's figure, set only when [km] is the learned one and the two
  /// disagree by more than 10 %. Not on the home screen any more: a tap on
  /// the range shows the VCU's figure whenever the learned one is in use.
  final int? stockKm;

  @override
  bool operator ==(Object other) =>
      other is RangeReadout && other.km == km && other.kind == kind && other.approx == approx && other.stockKm == stockKm;

  @override
  int get hashCode => Object.hash(km, kind, approx, stockKm);
}

/// The learned range replaces the VCU's once [trueRangeOn] and confidence
/// reaches 30 %, approximate below 70 %. In limp mode the VCU's own figure
/// stands: the learned km/% comes from full-power rides, and the VCU has
/// no separate limp estimate (CAN 0x6F4 word 0, once shown here, is the
/// Eco range).
RangeReadout rangeReadout({
  required bool known,
  required bool limp,
  required bool trueRangeOn,
  required TrueRange trueRange,
}) {
  final stock = trueRange.stockRangeKm;
  if (limp) return RangeReadout(km: known ? stock : null, kind: RangeKind.limp);
  final conf = trueRange.confidencePercent;
  if (!trueRangeOn || conf < 30) return RangeReadout(km: known ? stock : null, kind: RangeKind.stock);
  if (!known) return const RangeReadout(km: null, kind: RangeKind.trueRange);
  final trueKm = trueRange.trueRangeKm;
  final differs = stock > 0 && (stock - trueKm).abs() / stock * 100 > 10;
  return RangeReadout(
    km: trueKm,
    kind: RangeKind.trueRange,
    approx: conf < 70,
    stockKm: differs ? stock : null,
  );
}

final rangeReadoutProvider = Provider<RangeReadout>((ref) {
  final (known, limp) = ref.watch(vehicleProvider.select((v) => (v.rangeKnown, v.limpMode)));
  return rangeReadout(
    known: known,
    limp: limp,
    trueRangeOn: ref.watch(ridingSettingsProvider.select((s) => s.isOn(RidingFeature.predictedRange))),
    trueRange: ref.watch(trueRangeProvider),
  );
});
