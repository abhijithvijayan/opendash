import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/fault_catalog.dart';

/// The faults the diagnostics decoder currently reports active, most-severe
/// first. Fed by the gRPC decode loop (and the mock); read by the Fault
/// codes tab. Kept separate from [vehicleProvider] so a fault frame doesn't
/// rebuild the whole dash.
final activeFaultsProvider =
    NotifierProvider<ActiveFaultsNotifier, List<ActiveFault>>(ActiveFaultsNotifier.new);

class ActiveFaultsNotifier extends Notifier<List<ActiveFault>> {
  @override
  List<ActiveFault> build() => const [];

  /// Replace the active set, but only when it actually changed, so a steady
  /// stream of identical fault frames doesn't churn the UI.
  void set(List<ActiveFault> faults) {
    if (!_same(state, faults)) state = faults;
  }

  static bool _same(List<ActiveFault> a, List<ActiveFault> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].def.frame != b[i].def.frame || a[i].def.bit != b[i].def.bit) return false;
    }
    return true;
  }
}
