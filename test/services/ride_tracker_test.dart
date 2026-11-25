import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/ride_tracker.dart';

void main() {
  setUp(() => AnalyticsLogger.instance.resetForTest());

  List<Map<String, Object?>> rides(String evt) => AnalyticsLogger.instance.recent('ride', evt);

  void withTracker(void Function(FakeAsync async, VehicleNotifier v) body) {
    fakeAsync((async) {
      AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
      final c = ProviderContainer();
      final v = c.read(vehicleProvider.notifier);
      v.setConnected(true);
      v.setLocked(false);
      final tracker = RideTracker(c)..start();
      body(async, v);
      tracker.stop();
      c.dispose();
    });
  }

  // 36 km/h is 10 m/s: the 100 m a ride needs take 10 s.
  void rideOff(FakeAsync async, VehicleNotifier v) {
    v.setVehicleState(VehicleState.ready);
    v.setSpeed(36);
    async.elapse(const Duration(seconds: 10));
  }

  test('ride.start waits for 100 m, and dates the ride from motor-on', () {
    withTracker((async, v) {
      v.setVehicleState(VehicleState.ready);
      async.elapse(const Duration(seconds: 20));
      v.setSpeed(36);
      async.elapse(const Duration(seconds: 9));
      expect(rides('start'), isEmpty, reason: '90 m so far');
      async.elapse(const Duration(seconds: 1));
      expect(rides('start').length, 1);
      final data = rides('start').single['data'] as Map;
      expect(data['ride_seq'], 1);
      expect(data['soc_start'], 82);
      expect(data['started_at_odo_km'], 12408);
      v.setSpeed(0);
      v.setVehicleState(VehicleState.parked);
      async.elapse(const Duration(seconds: 30));
      expect((rides('end').single['data'] as Map)['duration_s'], 60, reason: '20 s standing + 10 s moving + 30 s to end');
    });
  });

  test('unparking and parking in place is not a ride (47-49 s, 0.0 km)', () {
    withTracker((async, v) {
      v.setVehicleState(VehicleState.ready);
      async.elapse(const Duration(seconds: 48));
      v.setVehicleState(VehicleState.parked);
      async.elapse(const Duration(minutes: 2));
      expect(rides('start'), isEmpty);
      expect(rides('end'), isEmpty);
    });
  });

  test('shuffling it a few metres is not a ride either (38 s, 0.01 km, top 18)', () {
    withTracker((async, v) {
      v.setVehicleState(VehicleState.ready);
      async.elapse(const Duration(seconds: 10));
      v.setSpeed(18);
      async.elapse(const Duration(seconds: 2));
      v.setSpeed(4);
      async.elapse(const Duration(seconds: 20));
      v.setSpeed(0);
      v.setVehicleState(VehicleState.parked);
      async.elapse(const Duration(minutes: 1));
      expect(rides('start'), isEmpty);
    });
  });

  test('distance does not carry over from one motor-on to the next', () {
    withTracker((async, v) {
      for (var i = 0; i < 3; i++) {
        v.setVehicleState(VehicleState.ready);
        v.setSpeed(36);
        async.elapse(const Duration(seconds: 6));
        v.setSpeed(0);
        v.setVehicleState(VehicleState.parked);
        async.elapse(const Duration(seconds: 5));
      }
      expect(rides('start'), isEmpty, reason: 'three 60 m hops');
    });
  });

  test('back to parked for 30 s emits ride.end with the duration and stats', () {
    withTracker((async, v) {
      v.setVehicleState(VehicleState.ready);
      v.setSpeed(30);
      async.elapse(const Duration(seconds: 3));
      v.setSpeed(55);
      async.elapse(const Duration(seconds: 57));
      v.setSpeed(0);
      AnalyticsLogger.instance.log('modal', 'show', {'name': 'auto_park'});
      v.setVehicleState(VehicleState.parked);
      async.elapse(const Duration(seconds: 29));
      expect(rides('end'), isEmpty, reason: 'a long light must not end the ride');
      async.elapse(const Duration(seconds: 1));
      expect(rides('end').length, 1);
      final data = rides('end').single['data'] as Map;
      expect(data['ride_seq'], 1);
      expect(data['why'], 'motor_off');
      expect(data['duration_s'], 90);
      expect(data['top_speed'], 55);
      expect(data['fault_count'], 0);
      expect((data['modal_count_by_name'] as Map)['auto_park'], 1);
    });
  });

  test('rolling again inside 30 s keeps the same ride', () {
    withTracker((async, v) {
      rideOff(async, v);
      v.setSpeed(0);
      v.setVehicleState(VehicleState.parked);
      async.elapse(const Duration(seconds: 20));
      v.setVehicleState(VehicleState.ready);
      v.setSpeed(20);
      async.elapse(const Duration(seconds: 20));
      expect(rides('end'), isEmpty);
      v.setSpeed(0);
      v.setVehicleState(VehicleState.parked);
      async.elapse(const Duration(seconds: 30));
      expect(rides('start').length, 1);
      expect(rides('end').length, 1);
      rideOff(async, v);
      expect((rides('start').last['data'] as Map)['ride_seq'], 2);
    });
  });

  test('a lock ends the ride at once', () {
    withTracker((async, v) {
      rideOff(async, v);
      v.setSpeed(0);
      v.setVehicleState(VehicleState.parked);
      async.elapse(const Duration(seconds: 7));
      expect(rides('end'), isEmpty);
      v.setLocked(true);
      expect(rides('end').length, 1);
      final data = rides('end').single['data'] as Map;
      expect(data['why'], 'lock');
      expect(data['duration_s'], 17);
      async.elapse(const Duration(minutes: 1));
      expect(rides('end').length, 1, reason: 'the 30 s timer does not end it a second time');
    });
  });

  test('unlocking and standing after a ride does not open another', () {
    withTracker((async, v) {
      rideOff(async, v);
      v.setSpeed(0);
      v.setVehicleState(VehicleState.parked);
      v.setLocked(true);
      v.setLocked(false);
      v.setVehicleState(VehicleState.ready);
      async.elapse(const Duration(minutes: 2));
      expect(rides('start').length, 1);
      expect(rides('end').length, 1);
    });
  });

  test('Restart scooter ends the ride before the head unit loses power', () {
    withTracker((async, v) {
      rideOff(async, v);
      v.setSpeed(0);
      v.setVehicleState(VehicleState.parked);
      async.elapse(const Duration(seconds: 8));
      AnalyticsLogger.instance.log('recovery', 'reboot_scooter', {'via': 'hhmis'});
      expect(rides('end').length, 1);
      expect((rides('end').single['data'] as Map)['why'], 'restart');
    });
  });
}
