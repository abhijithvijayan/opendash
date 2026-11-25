// Findings from a ride log: lock confirms on the charger, held notices and toasts.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/state/toast_state.dart';
import 'helpers/stock.dart';

class _Harness {
  _Harness() {
    container = ProviderContainer(overrides: [
      vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), 
            events: events.stream,
            invoke: (method, args) async {
              final housekeeping = args is Map &&
                  (args['cmd'] == HhmisCmd.projectLoaded || args['cmd'] == HhmisCmd.touchStatus);
              if (!housekeeping) calls.add('$method $args');
              return true;
            },
          )),
    ]);
    container.listen(toastProvider, (_, t) {
      if (t != null) toasts.add(t.message);
    });
  }

  final events = StreamController<dynamic>();
  final calls = <String>[];
  final toasts = <String>[];
  late final ProviderContainer container;

  AidlVehicleNotifier get notifier => container.read(vehicleProvider.notifier) as AidlVehicleNotifier;
  VehicleData get state => container.read(vehicleProvider);

  void dispose() {
    container.dispose();
    events.close();
  }
}

List<Map<String, Object?>> _events(String cat, String evt) => AnalyticsLogger.instance.recent(cat, evt);

void _onFakeClock(void Function(FakeAsync async, _Harness h) body) {
  fakeAsync((async) {
    AnalyticsLogger.instance.resetForTest();
    AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
    final h = _Harness();
    body(async, h);
    h.dispose();
  });
}

void main() {
  test('on the charger a repeated CHARGING state does not confirm a lock; the lock itself does', () {
    _onFakeClock((async, h) {
      h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, 'INT_VEHICLE_SPEED': 0});
      h.notifier.onEvent({'INT_VEHICLE_STATE': 6});
      expect(h.state.locked, isFalse, reason: 'unlocked, on the charger');
      async.elapse(const Duration(seconds: 1));
      h.notifier.lockScooter();
      async.flushMicrotasks();
      expect(h.state.pendingLock, isNotNull);
      // 84 ms after the send HHMIS repeated its state, as it does all the time.
      async.elapse(const Duration(milliseconds: 84));
      h.notifier.onEvent({'INT_VEHICLE_STATE': 6});
      expect(h.state.pendingLock, isNotNull, reason: 'still waiting for the scooter');
      expect(_events('safety', 'lock_confirmed'), isEmpty);
      // 7.4 s later the scooter locked: 6 -> 0 -> 6.
      async.elapse(const Duration(milliseconds: 7300));
      h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
      h.notifier.onEvent({'INT_VEHICLE_STATE': 6});
      expect(h.state.pendingLock, isNull);
      expect(_events('safety', 'lock_confirmed'), hasLength(1));
    });
  });

  test('a notice the vehicle already cleared goes away when the rider sets off', () {
    _onFakeClock((async, h) {
      h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 4, 'INT_VEHICLE_SPEED': 0});
      h.notifier.onEvent({'INT_VEHICLE_COMMAND': 134});
      async.elapse(const Duration(milliseconds: 300));
      h.notifier.onEvent({'INT_VEHICLE_COMMAND': 0});
      expect(h.state.notice?.command, 134, reason: 'held so it can be read');
      async.elapse(const Duration(seconds: 1));
      h.notifier.onEvent({'INT_VEHICLE_SPEED': 3});
      expect(h.state.notice, isNull);
      expect(_events('hhmis', 'notice_hold_ended').single['data'], {'command': 134, 'reason': 'moved_off'});
    });
  });

  test('a notice the vehicle has not cleared stays while moving', () {
    _onFakeClock((async, h) {
      h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 4, 'INT_VEHICLE_SPEED': 0});
      h.notifier.onEvent({'INT_VEHICLE_COMMAND': 134});
      h.notifier.onEvent({'INT_VEHICLE_SPEED': 3});
      expect(h.state.notice?.command, 134);
    });
  });

  test('position light: the toast says what the scooter reported, not what was asked', () {
    _onFakeClock((async, h) {
      h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, 'BOOL_POSITION_LAMP_STATUS': true});
      expect(h.state.positionLight, isTrue);
      h.notifier.togglePositionLight();
      async.flushMicrotasks();
      expect(h.calls.single, contains(HhmisCmd.frontDrlOff));
      expect(h.toasts, isEmpty, reason: 'nothing claimed before the scooter answers');
      async.elapse(AidlVehicleNotifier.positionLightEcho);
      expect(h.toasts.single, 'Position light: scooter did not confirm');

      h.toasts.clear();
      h.notifier.togglePositionLight();
      h.notifier.onEvent({'BOOL_POSITION_LAMP_STATUS': false});
      async.elapse(AidlVehicleNotifier.positionLightEcho);
      expect(h.toasts.single, 'Position light off');
    });
  });

  test('a switch-cube music key with no phone connected says so', () {
    _onFakeClock((async, h) {
      h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, '_bt': false});
      h.notifier.onEvent({'INT_BT_MUSIC_COMMAND': 0});
      async.flushMicrotasks();
      expect(h.toasts, contains('No phone connected'));
      expect(_events('media', 'key_no_phone'), hasLength(1));
    });
  });
}
