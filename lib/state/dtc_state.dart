import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/recovery_service.dart';
import '../services/uds_dtc.dart';

/// Result of a live DTC read across the three ECUs.
class DtcReadState {
  const DtcReadState({this.loading = false, this.ran = false, this.results = const {}, this.error});
  final bool loading;
  final bool ran;
  final Map<DtcEcu, EcuFaultResult> results;
  final String? error;

  List<Dtc> get all => [for (final r in results.values) ...r.dtcs];
}

/// Reads the real trouble codes from the BMS/MCU/VCU on demand (user-triggered
/// button), the authoritative fault read matching Ola's own app.
final dtcReadProvider = NotifierProvider<DtcReadNotifier, DtcReadState>(DtcReadNotifier.new);

class DtcReadNotifier extends Notifier<DtcReadState> {
  @override
  DtcReadState build() => const DtcReadState();

  DtcCatalog? _catalog;

  Future<DtcCatalog> _loadCatalog() async {
    _catalog ??= parseDtcCatalog(
      json.decode(await rootBundle.loadString('assets/diagnostics/fault_codes.json')) as Map<String, dynamic>,
    );
    return _catalog!;
  }

  /// Query each ECU for its DTCs. Read-only: sends only the ReadDTCInformation
  /// request per ECU.
  Future<void> read() async {
    if (state.loading) return;
    state = const DtcReadState(loading: true);
    try {
      final cat = await _loadCatalog();
      final results = <DtcEcu, EcuFaultResult>{};
      for (final ecu in DtcEcu.values) {
        results[ecu] = await recoveryService.readFaults(ecu, cat);
      }
      state = DtcReadState(ran: true, results: results);
    } catch (e) {
      state = DtcReadState(ran: true, error: e.toString());
    }
  }
}
