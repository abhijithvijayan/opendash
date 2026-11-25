import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mock_provider.dart';
import '../providers/vehicle_commands.dart';
import '../services/analytics_logger.dart';
import '../services/prefs_service.dart';
import '../services/trusted_clock.dart';

class FaultRecord {
  const FaultRecord({required this.code, required this.title, required this.raisedAt, this.clearedAt});

  final String code;
  final String title;

  /// Epoch milliseconds.
  final int raisedAt;
  final int? clearedAt;

  bool get cleared => clearedAt != null;

  FaultRecord clearedNow(int at) => FaultRecord(code: code, title: title, raisedAt: raisedAt, clearedAt: at);

  Map<String, Object?> toJson() => {'code': code, 'title': title, 'at': raisedAt, 'cleared': clearedAt};

  static FaultRecord? fromJson(Object? o) {
    if (o is! Map) return null;
    final code = o['code'], title = o['title'], at = o['at'], cleared = o['cleared'];
    if (code is! String || title is! String || at is! int) return null;
    return FaultRecord(code: code, title: title, raisedAt: at, clearedAt: cleared is int ? cleared : null);
  }
}

final faultHistoryProvider = NotifierProvider<FaultHistoryNotifier, List<FaultRecord>>(FaultHistoryNotifier.new);

/// The faults this dashboard has itself seen, newest first. The vehicle has
/// no fault-history key (stock shows live popups only), so the list is built
/// from the `faultActive` / `faultCode` latch and kept across restarts.
class FaultHistoryNotifier extends Notifier<List<FaultRecord>> {
  static const prefsKey = 'faultHistory';
  static const maxRecords = 20;

  static const mockSeed = [
    FaultRecord(code: 'E042', title: 'Motor controller fault', raisedAt: 1793188800000, clearedAt: 1793192400000),
    FaultRecord(code: 'E015', title: 'Battery communication timeout', raisedAt: 1792065600000, clearedAt: 1792069200000),
    FaultRecord(code: 'E003', title: 'Side stand sensor', raisedAt: 1790078400000, clearedAt: 1790082000000),
  ];

  @override
  List<FaultRecord> build() {
    ref.listen(vehicleProvider.select((v) => (v.faultActive, v.faultCode)), (_, next) => _onFault(next.$1, next.$2));
    if (!useAidlVehicle) return mockSeed;
    final loaded = <FaultRecord>[];
    try {
      final raw = jsonDecode(PrefsService.getString(prefsKey, '[]'));
      if (raw is List) {
        for (final e in raw) {
          final r = FaultRecord.fromJson(e);
          // The latch is per process: a fault left open by the last run
          // ended with it at the latest.
          if (r != null) loaded.add(r.cleared ? r : r.clearedNow(r.raisedAt));
        }
      }
    } catch (_) {}
    return loaded;
  }

  /// `C93` is `INT_VEHICLE_COMMAND` ordinal 93; its stock title is in
  /// [vehicleCommands].
  static String titleFor(String code) {
    final ordinal = code.startsWith('C') ? int.tryParse(code.substring(1)) : null;
    return vehicleCommands[ordinal]?.title ?? 'Fault';
  }

  void _onFault(bool active, String code) {
    final now = TrustedClock.now().millisecondsSinceEpoch;
    final open = state.isNotEmpty && !state.first.cleared ? state.first : null;
    if (active) {
      if (open != null && open.code == code) return;
      final next = [
        FaultRecord(code: code, title: titleFor(code), raisedAt: now),
        if (open != null) open.clearedNow(now),
        ...state.skip(open == null ? 0 : 1),
      ];
      state = next.take(maxRecords).toList();
      logEvent('state', 'fault_recorded', {'code': code, 'count': state.length});
    } else {
      if (open == null) return;
      state = [open.clearedNow(now), ...state.skip(1)];
    }
    if (useAidlVehicle) PrefsService.setString(prefsKey, jsonEncode([for (final r in state) r.toJson()]));
  }
}
