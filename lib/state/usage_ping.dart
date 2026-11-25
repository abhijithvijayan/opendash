import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import '../models/scooter_model.dart';
import '../models/vehicle_data.dart';
import '../providers/mock_provider.dart';
import '../services/analytics_logger.dart';
import '../services/build_info.dart';
import '../services/platform_provider.dart';
import '../services/prefs_service.dart';
import '../services/trusted_clock.dart';
import 'qr_card.dart';
import 'scooter_capabilities.dart';

final usagePingProvider = NotifierProvider<UsagePing, bool>(UsagePing.new);

/// Settings → Updates → "Count this install". At most once a week, one
/// request saying that an OpenDash ran that week, which version, and on
/// which scooter model and software ([usagePayload]). It carries no
/// identifier: weekly users are the rows of a week, installs the rows
/// marked `new`. On until the rider turns it off.
class UsagePing extends Notifier<bool> {
  /// The first try waits for the scooter to have said what it is. It was
  /// ten minutes, and starts again with every start of OpenDash: a rider
  /// whose rides are shorter was never counted.
  static const firstAfter = Duration(minutes: 1);

  /// Looked at again this often until the stock service has answered and
  /// the clock is set: nothing is sent while waiting, so it costs nothing.
  static const waitAfter = Duration(minutes: 1);

  /// After a send that failed.
  static const retryAfter = Duration(minutes: 30);

  /// A head unit can stay up for days: the week is looked at again.
  static const lookAgainAfter = Duration(hours: 6);

  /// Only from a real scooter, and only once the server exists.
  @visibleForTesting
  static bool Function() sendsHere = () => useAidlVehicle && usagePingUrl.isNotEmpty;

  Timer? _timer;
  bool _sending = false;

  @override
  bool build() {
    ref.onDispose(() => _timer?.cancel());
    final on = PrefsService.getBool(PrefsKeys.usagePing, true);
    if (on) _schedule(firstAfter);
    return on;
  }

  void set(bool on) {
    if (on == state) return;
    logSettingsChange('usage_ping', state, on);
    state = on;
    PrefsService.setBool(PrefsKeys.usagePing, on);
    _timer?.cancel();
    if (on) _schedule(firstAfter);
  }

  void _schedule(Duration after) {
    if (!sendsHere()) return;
    _timer?.cancel();
    _timer = Timer(after, () => unawaited(sendIfDue()));
  }

  /// Sends this week's ping unless it has gone; then looks again later.
  @visibleForTesting
  Future<void> sendIfDue() async {
    if (!state || _sending || !sendsHere()) return;
    // Counted only once the scooter's own service has answered: an emulator,
    // a test build or a dashboard that never reached the service is not an
    // install riding a scooter.
    // `hhmisBacked` alone is not enough: it is true from the start on any
    // Android device, a phone included. The stock service's version is read
    // from its installed package, which only a head unit has.
    final stockKnown = ref.read(scooterCapabilitiesProvider).software?.version.isNotEmpty ?? false;
    if (!TrustedClock.trusted || !ref.read(vehicleProvider).hhmisBacked || !stockKnown) {
      _schedule(waitAfter);
      return;
    }
    final week = isoWeek(TrustedClock.now());
    if (PrefsService.getString(PrefsKeys.usagePingWeek, '') == week) {
      _schedule(lookAgainAfter);
      return;
    }
    final counted = PrefsService.getBool(PrefsKeys.usagePingCounted, false);
    final body = jsonEncode(usagePayload(
      week: week,
      isNew: !counted,
      v: ref.read(vehicleProvider),
      software: ref.read(scooterCapabilitiesProvider).software,
      android: ref.read(platformServiceProvider).deviceInfo()['release'] ?? '',
    ));
    _sending = true;
    final status = await ref.read(platformServiceProvider).usagePing(usagePingUrl, body);
    _sending = false;
    if (!ref.mounted) return;
    // 409: the server already has this proof, from a send whose answer was lost.
    final ok = (status >= 200 && status < 300) || status == 409;
    logEvent('usage', 'ping', {'ok': ok, 'status': status, 'week': week, 'new': !counted});
    if (!ok) {
      _schedule(retryAfter);
      return;
    }
    PrefsService.setString(PrefsKeys.usagePingWeek, week);
    PrefsService.setBool(PrefsKeys.usagePingCounted, true);
    _schedule(lookAgainAfter);
  }
}

/// Everything the ping says. Nothing that tells one rider or scooter from
/// another: no VIN, serial, name, address, place or ID of any kind.
Map<String, Object?> usagePayload({
  required String week,
  required bool isNew,
  required VehicleData v,
  StockIdentity? software,
  required String android,
}) {
  final known = v.hhmisBacked;
  return {
    'v': 2,
    'week': week,
    'new': isNew,
    'app': appVersion,
    'build': BuildInfo.number ?? 0,
    'gen': generationOf(software?.name ?? '').replaceFirst('Gen ', ''),
    'model': !known || v.vehicleType == null ? '' : ScooterModel.nameFor(v.vehicleType) ?? 'type ${v.vehicleType}',
    'moveos': known ? v.moveOsVersion : '',
    'stock': software?.version ?? '',
    'android': android,
  };
}

/// The ISO 8601 week of [t]'s date, as `2026-W48`.
String isoWeek(DateTime t) {
  final day = DateTime.utc(t.year, t.month, t.day);
  final thursday = day.add(Duration(days: DateTime.thursday - day.weekday));
  final week = thursday.difference(DateTime.utc(thursday.year)).inDays ~/ 7 + 1;
  return '${thursday.year}-W${week.toString().padLeft(2, '0')}';
}
