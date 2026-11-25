// Findings from a 23.5 h log: stale data while asleep, the speed-limit warning and toasts.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/state/alert_state.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/toast_state.dart';
import 'helpers/stock.dart';

List<Map<String, Object?>> _events(String cat, String evt) => AnalyticsLogger.instance.recent(cat, evt);

void main() {
  setUp(AnalyticsLogger.instance.resetForTest);

  test('a sleeping scooter logs "stale" once per screen-off, not every minute', () {
    fakeAsync((async) {
      AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
      final events = StreamController<dynamic>();
      final c = ProviderContainer(overrides: [
        vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: events.stream, invoke: (_, _) async => true)),
      ]);
      final n = c.read(vehicleProvider.notifier) as AidlVehicleNotifier;
      n.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 0});
      async.elapse(const Duration(seconds: 1));
      n.onLifecyclePause();
      // Data once a minute, as the locked scooter sends it.
      for (var minute = 0; minute < 10; minute++) {
        async.elapse(const Duration(minutes: 1));
        n.onEvent({'INT_BATTERY_SOC': 72});
      }
      final stale = _events('hhmis', 'stale');
      expect(stale, hasLength(1));
      expect(stale.single['data'], containsPair('in_front', false));
      expect(c.read(vehicleProvider).speedUntrustedReason, isNull, reason: 'fresh data just arrived');
      async.elapse(const Duration(seconds: 5));
      expect(c.read(vehicleProvider).speedUntrustedReason, 'stale', reason: 'the rule itself still runs');
      c.dispose();
      events.close();
    });
  });

  test('the speed-limit warning lets go 3 km/h under the limit, not at it', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.listen(speedLimitOverProvider, (_, _) {});
    final v = c.read(vehicleProvider.notifier);
    final r = c.read(ridingSettingsProvider.notifier);
    r.setSpeedLimitEnabled(true);
    r.setSpeedLimit(60);
    bool banner() => c.read(activeAlertsProvider).any((a) => a.kind == AlertKind.speedLimitExceeded);
    v.setSpeed(60);
    expect(banner(), isFalse);
    v.setSpeed(61);
    expect(banner(), isTrue);
    for (final s in [60, 61, 59, 60, 58]) {
      v.setSpeed(s);
      expect(banner(), isTrue, reason: 'hovering at the limit ($s) does not flash it');
    }
    v.setSpeed(57);
    expect(banner(), isFalse);
    v.setSpeed(60);
    expect(banner(), isFalse, reason: 'and it does not come back until over the limit');
  });

  test('dragging the speed-limit slider logs and saves once, on release', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final r = c.read(ridingSettingsProvider.notifier);
    for (var kmh = 79; kmh >= 60; kmh--) {
      r.setSpeedLimit(kmh, commit: false);
    }
    expect(c.read(ridingSettingsProvider).speedLimit, 60, reason: 'the value follows the finger');
    expect(_events('settings', 'change'), isEmpty);
    r.setSpeedLimit(60);
    final change = _events('settings', 'change').single['data']! as Map;
    expect(change['key'], 'riding.speedLimit');
    expect(change['from'], 80);
    expect(change['to'], 60);
  });

  test('the same toast again while it is up is one toast', () {
    fakeAsync((async) {
      final c = ProviderContainer();
      final t = c.read(toastProvider.notifier);
      t.show('Charger connected but not charging', type: ToastType.warning);
      final id = c.read(toastProvider)!.id;
      async.elapse(const Duration(milliseconds: 300));
      t.show('Charger connected but not charging', type: ToastType.warning);
      expect(c.read(toastProvider)!.id, id);
      expect(_events('ui', 'toast'), hasLength(1));
      t.show('Boot open');
      expect(_events('ui', 'toast'), hasLength(2));
      async.elapse(const Duration(seconds: 10));
      expect(c.read(toastProvider), isNull);
      c.dispose();
    });
  });
}
