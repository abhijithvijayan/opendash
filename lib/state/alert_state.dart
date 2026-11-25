import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vehicle_data.dart';
import '../providers/mock_provider.dart';
import 'overlay_state.dart';
import 'riding_settings.dart';
import '../services/analytics_logger.dart';

/// Value-equal wrapper so `select` only notifies when the alert list
/// actually changes, not on every vehicle tick.
class AlertSnapshot {
  const AlertSnapshot(this.alerts);
  final List<DashAlert> alerts;

  @override
  bool operator ==(Object other) => other is AlertSnapshot && listEquals(other.alerts, alerts);

  @override
  int get hashCode => Object.hashAll(alerts);
}

/// Vehicle alerts plus the one that depends on settings, the speed limit
/// warning. Critical first, as before. The side stand alert is dropped
/// while the stand sensor bypass is on.
List<DashAlert> allAlerts(VehicleData v, RidingSettings riding, {bool? overSpeedLimit}) {
  final sensorOn = riding.isOn(RidingFeature.sideStandCutOff);
  final out = [
    for (final a in v.alerts)
      if (sensorOn || (a.kind != AlertKind.sideStand && a.kind != AlertKind.standToRide)) a,
  ];
  if (overSpeedLimit ?? (riding.speedLimitEnabled && v.speed > riding.speedLimit)) {
    out.add(DashAlert(
      AlertKind.speedLimitExceeded,
      AlertPriority.warning,
      'Speed ${v.speed} km/h',
      'Over your ${riding.speedLimit} km/h limit',
    ));
  }
  out.sort((a, b) => a.priority.index.compareTo(b.priority.index));
  return out;
}

/// The scooter's answer to a start press it refused. The rider is waiting
/// on it, so it shows even inside a menu (command 59 with Diagnostics open
/// once showed nothing at all).
const startRefusalKinds = {AlertKind.brakeToStart, AlertKind.standToRide, AlertKind.unplugChargerToRide};

/// Inside a menu only these interrupt; other warnings and infos wait until
/// the overlay closes (infos may have timed out by then).
bool showsOverMenu(DashAlert a) => a.priority == AlertPriority.critical || startRefusalKinds.contains(a.kind);

/// Over the rider's speed limit, with a margin on the way down: hovering at
/// the limit flashed the banner three times in two seconds.
final speedLimitOverProvider = NotifierProvider<SpeedLimitOver, bool>(SpeedLimitOver.new);

class SpeedLimitOver extends Notifier<bool> {
  /// km/h under the limit before the warning lets go.
  static const margin = 3;

  @override
  bool build() {
    ref.listen(vehicleProvider.select((v) => v.speed), (_, _) => _eval());
    ref.listen(ridingSettingsProvider.select((r) => (r.speedLimitEnabled, r.speedLimit)), (_, _) => _eval());
    return _over(false);
  }

  bool _over(bool was) {
    final r = ref.read(ridingSettingsProvider);
    if (!r.speedLimitEnabled) return false;
    final speed = ref.read(vehicleProvider).speed;
    if (speed > r.speedLimit) return true;
    return was && speed > r.speedLimit - margin;
  }

  void _eval() {
    final next = _over(state);
    if (next != state) state = next;
  }
}

// Selectors may not touch `ref`, so the settings are captured as values.
final activeAlertsProvider = Provider<List<DashAlert>>((ref) {
  final riding = ref.watch(ridingSettingsProvider);
  final over = ref.watch(speedLimitOverProvider);
  return ref.watch(vehicleProvider.select((v) => AlertSnapshot(allAlerts(v, riding, overSpeedLimit: over)))).alerts;
});

final dismissedAlertsProvider =
    NotifierProvider<DismissedAlerts, Set<AlertKey>>(DismissedAlerts.new);

/// Warnings the rider has swiped away and info alerts that have timed out.
/// A dismissal lasts until the alert's condition clears, so it fires again
/// on the next cycle. Also buzzes the handlebar when a new alert lands.
///
/// Keyed by [AlertKey], not just [AlertKind]: a vehicle notice carries its
/// command ordinal, so dismissing notice 142 does not mask notice 107. A
/// dismissed notice also never suppresses the generic fault / "Power
/// reduced" banner, because those have their own kinds and so their own
/// keys.
class DismissedAlerts extends Notifier<Set<AlertKey>> {
  static const infoAutoDismiss = Duration(seconds: 4);

  /// Reserved for future hints that should stay dismissed forever within
  /// a session. The three start-refusal hints
  /// used to live here, but stock shows each one for ~3 s every time the
  /// condition fires, so they're no longer silenced after the first.
  static const oncePerSession = <AlertKind>{};
  static const secondImpactDelay = Duration(milliseconds: 200);

  /// Test hook: receives the priority of every alert that would vibrate.
  static void Function(AlertPriority priority)? onHaptic;

  final Map<AlertKey, Timer> _infoTimers = {};
  Set<AlertKey> _known = const {};
  Timer? _secondImpact;
  final Set<AlertKey> _bannerShown = {};
  late RidingSettings _riding;
  bool _overlay = false;

  bool _overLimit = false;

  AlertSnapshot _snapshot(VehicleData v) => AlertSnapshot(allAlerts(v, _riding, overSpeedLimit: _overLimit));

  @override
  Set<AlertKey> build() {
    ref.onDispose(() {
      for (final t in _infoTimers.values) {
        t.cancel();
      }
      _secondImpact?.cancel();
    });
    _riding = ref.read(ridingSettingsProvider);
    ref.listen(vehicleProvider.select(_snapshot), (_, snap) => _sync(snap.alerts));
    ref.listen(vehicleProvider.select((v) => v.isCharging), (_, plugged) {
      if (!plugged) _chargeCompleteSeen = false;
    });
    ref.listen(ridingSettingsProvider, (_, r) {
      _riding = r;
      _sync(_snapshot(ref.read(vehicleProvider)).alerts);
    });
    _overLimit = ref.read(speedLimitOverProvider);
    ref.listen(speedLimitOverProvider, (_, over) {
      _overLimit = over;
      _sync(_snapshot(ref.read(vehicleProvider)).alerts);
    });
    _overlay = ref.read(overlayToolbarVisibleProvider);
    ref.listen(overlayToolbarVisibleProvider, (_, open) {
      _overlay = open;
      _sync(_snapshot(ref.read(vehicleProvider)).alerts);
    });
    _sync(_snapshot(ref.read(vehicleProvider)).alerts, initial: true);
    return const {};
  }

  /// "Charging complete" is announced once per plug-in. The charge status
  /// drops to "charging" and back each time the screen wakes on a full
  /// battery (three banners in 26 s at the lock screen); the
  /// lock and charging screens keep saying "Charged" all along.
  bool _chargeCompleteSeen = false;

  void _sync(List<DashAlert> alerts, {bool initial = false}) {
    final active = alerts.map((a) => a.key).toSet();
    var current = initial ? const <AlertKey>{} : state;
    for (final a in alerts) {
      if (a.kind != AlertKind.chargingComplete) continue;
      if (_chargeCompleteSeen && !initial && !current.contains(a.key)) {
        current = {...current, a.key};
        state = current;
      }
      _chargeCompleteSeen = true;
    }
    final cleared = current.where((k) => !active.contains(k) && !oncePerSession.contains(k.kind)).toSet();
    // Cancel info timers whose notice has changed identity (new command
    // ordinal), as well as timers for alerts that cleared.
    for (final k in _infoTimers.keys.toList()) {
      if (!active.contains(k)) _infoTimers.remove(k)!.cancel();
    }
    for (final a in alerts) {
      // A vehicle notice reaching this layer is
      // a held one (toasts go through the notifier's toast() path, not
      // DashAlert). Stock shows it until the next command or 0; never
      // time it out.
      if (a.priority == AlertPriority.info &&
          a.kind != AlertKind.vehicleNotice &&
          !current.contains(a.key) &&
          !_infoTimers.containsKey(a.key)) {
        final key = a.key;
        _infoTimers[key] = Timer(infoAutoDismiss, () {
          _infoTimers.remove(key);
          _dismissKey(key, reason: 'timeout');
        });
      }
    }
    final shown = {for (final a in alerts) if (!_overlay || showsOverMenu(a)) a.key};
    if (!initial) {
      for (final a in alerts) {
        if (shown.contains(a.key) && !_known.contains(a.key)) _buzz(a.priority);
      }
    }
    _known = shown;
    for (final a in alerts) {
      if (shown.contains(a.key) && !current.contains(a.key) && _bannerShown.add(a.key)) {
        logModalShow('alert_banner', reason: 'condition',
            extra: {'kind': a.kind.name, 'priority': a.priority.name, if (a.noticeCommand != null) 'command': a.noticeCommand});
      }
    }
    for (final k in _bannerShown.toList()) {
      if (!shown.contains(k)) {
        _bannerShown.remove(k);
        logModalDismiss('alert_banner', reason: active.contains(k) ? 'overlay' : 'condition_cleared',
            extra: {'kind': k.kind.name, if (k.command != null) 'command': k.command});
      }
    }
    if (cleared.isNotEmpty) state = current.difference(cleared);
  }

  /// Two heavy impacts for critical, one for warning, nothing for info.
  void _buzz(AlertPriority priority) {
    if (priority == AlertPriority.info) return;
    onHaptic?.call(priority);
    _impact();
    if (priority == AlertPriority.critical) {
      _secondImpact?.cancel();
      _secondImpact = Timer(secondImpactDelay, () {
        _secondImpact = null;
        _impact();
      });
    }
  }

  // Unit tests run without a platform binding; the failed future is dropped.
  static void _impact() => HapticFeedback.heavyImpact().catchError((_) {});

  /// Dismiss by alert kind (legacy entry point for alerts that have no
  /// command ordinal). For vehicle notices, pass the full DashAlert to
  /// [dismissAlert] so the command is preserved.
  void dismiss(AlertKind kind, {String reason = 'user'}) =>
      _dismissKey(AlertKey(kind), reason: reason);

  void dismissAlert(DashAlert a, {String reason = 'user'}) =>
      _dismissKey(a.key, reason: reason);

  void _dismissKey(AlertKey key, {String reason = 'user'}) {
    if (_bannerShown.remove(key)) {
      logModalDismiss('alert_banner', reason: reason,
          extra: {'kind': key.kind.name, if (key.command != null) 'command': key.command});
    }
    state = {...state, key};
  }

  void reset(AlertKind kind) => state = {for (final k in state) if (k.kind != kind) k};

  void resetAll() => state = const {};
}

final visibleAlertsProvider = Provider<List<DashAlert>>((ref) {
  final dismissed = ref.watch(dismissedAlertsProvider);
  final overlay = ref.watch(overlayToolbarVisibleProvider);
  return ref
      .watch(activeAlertsProvider)
      .where((a) => !dismissed.contains(a.key) && (!overlay || showsOverMenu(a)))
      .toList();
});

final alertCycleProvider = NotifierProvider<AlertCycle, int>(AlertCycle.new);

/// Which visible alert the banner shows. Warnings and infos auto-advance
/// every [period]; a critical alert is pinned and never rotates away on its
/// own. A swipe restarts the clock and can still page past a critical.
class AlertCycle extends Notifier<int> {
  static const period = Duration(seconds: 5);
  Timer? _timer;
  Set<AlertKey> _criticals = const {};

  @override
  int build() {
    ref.onDispose(() => _timer?.cancel());
    _criticals = _criticalKeys(ref.read(visibleAlertsProvider));
    ref.listen(visibleAlertsProvider, (_, alerts) {
      final criticals = _criticalKeys(alerts);
      final newCritical = criticals.any((k) => !_criticals.contains(k));
      _criticals = criticals;
      if (newCritical || state >= alerts.length) state = 0;
      _arm(alerts);
    });
    _arm(ref.read(visibleAlertsProvider));
    return 0;
  }

  static Set<AlertKey> _criticalKeys(List<DashAlert> alerts) =>
      {for (final a in alerts) if (a.priority == AlertPriority.critical) a.key};

  bool _pinned(List<DashAlert> alerts) =>
      alerts.isNotEmpty && alerts[state.clamp(0, alerts.length - 1)].priority == AlertPriority.critical;

  void _arm(List<DashAlert> alerts) {
    _timer?.cancel();
    _timer = alerts.length > 1 && !_pinned(alerts) ? Timer.periodic(period, (_) => next()) : null;
  }

  List<DashAlert> get _alerts => ref.read(visibleAlertsProvider);

  void next() {
    final alerts = _alerts;
    if (alerts.isEmpty) return;
    state = (state + 1) % alerts.length;
    _arm(alerts);
  }

  void previous() {
    final alerts = _alerts;
    if (alerts.isEmpty) return;
    state = (state - 1 + alerts.length) % alerts.length;
    _arm(alerts);
  }
}
