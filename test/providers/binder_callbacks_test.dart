import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/sound_settings.dart';
import 'package:opendash/state/sun_times.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/stock.dart';

class _Harness {
  _Harness() {
    Future<Object?> invoke(String method, Object? args) async {
      if (args is Map && method == 'sendBoolCmd' && args['cmd'] == HhmisCmd.touchStatus) {
        touches.add(args['value'] as bool);
      } else if (args is Map && method == 'sendVoidCmd' && args['cmd'] == HhmisCmd.projectLoaded) {
        projectLoaded++;
      } else {
        calls.add(args is Map ? '$method ${args['cmd']}=${args['value']}' : '$method $args');
      }
      return true;
    }

    container = ProviderContainer(overrides: [
      vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: events.stream, invoke: invoke)),
    ]);
  }

  final events = StreamController<dynamic>();
  final calls = <String>[];
  final touches = <bool>[];
  var projectLoaded = 0;
  late final ProviderContainer container;

  AidlVehicleNotifier get notifier => container.read(vehicleProvider.notifier) as AidlVehicleNotifier;

  void dispose() {
    container.dispose();
    events.close();
  }
}

List<Map<String, Object?>> _events(String cat, String evt) => AnalyticsLogger.instance.recent(cat, evt);
Map<String, Object?> _data(Map<String, Object?> e) => (e['data'] as Map).cast<String, Object?>();

void _onFakeClock(void Function(FakeAsync async, _Harness h) body) {
  fakeAsync((async) {
    final h = _Harness();
    h.notifier;
    body(async, h);
    async.flushMicrotasks();
    h.dispose();
  });
}

const _smartOn = {'INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT': 1};
const _trigger = 'sendBoolCmd ${HhmisCmd.triggerSmartLight}';
const _toggleOn = 'sendIntCmd SMART_HEADLIGHT_TOGGLE=1';

void main() {
  setUp(() {
    AnalyticsLogger.instance.resetForTest();
    AidlVehicleNotifier.clock = () => DateTime(2026, 11, 12, 12);
  });
  tearDown(() {
    AnalyticsLogger.instance.resetForTest();
    AidlVehicleNotifier.clock = DateTime.now;
  });

  group('sunrise / sunset (callback TX 8)', () {
    test('parses stock\'s "yyyy-MM-dd HH:mm:ss" and logs a new value once', () {
      final h = _Harness();
      const sun = {'sunrise': '2026-11-12 06:30:40', 'sunset': '2026-11-12 18:20:05'};
      h.notifier.onEvent({'_connected': true, '_sunTimes': sun});
      h.notifier.onEvent({'_sunTimes': sun});
      final times = h.container.read(sunTimesProvider);
      expect(times.sunrise, DateTime(2026, 11, 12, 6, 30, 40));
      expect(times.sunset, DateTime(2026, 11, 12, 18, 20, 5));
      expect(_events('hhmis', 'sun_times'), hasLength(1), reason: 'HHMIS repeats it every minute');
      expect(_data(_events('hhmis', 'sun_times').single)['parsed'], isTrue);
      h.dispose();
    });

    test('an empty or malformed report is "not known"', () {
      expect(SunTimes.parse('', '').known, isFalse);
      expect(SunTimes.parse('soon', '2026-11-12 18:20:05').known, isFalse);
      expect(SunTimes.parse(null, 7).known, isFalse);
    });

    test('day is strictly between sunrise and sunset; a stale date still works', () {
      final t = SunTimes.parse('2026-11-10 06:30:40', '2026-11-10 18:20:05');
      expect(t.isNight(DateTime(2026, 11, 12, 6, 30)), isTrue);
      expect(t.isNight(DateTime(2026, 11, 12, 6, 31)), isFalse);
      expect(t.isNight(DateTime(2026, 11, 12, 18, 19)), isFalse);
      expect(t.isNight(DateTime(2026, 11, 12, 18, 20)), isTrue);
      expect(t.isNight(DateTime(2026, 11, 12, 23, 30)), isTrue);
    });

    test('without a report stock\'s 06:00 / 18:00 fallback applies', () {
      const t = SunTimes();
      expect(t.isNight(DateTime(2026, 11, 12, 5, 59)), isTrue);
      expect(t.isNight(DateTime(2026, 11, 12, 6, 1)), isFalse);
      expect(t.isNight(DateTime(2026, 11, 12, 17, 59)), isFalse);
      expect(t.isNight(DateTime(2026, 11, 12, 18, 19)), isTrue);
    });
  });

  group('smart-headlight day/night trigger (ClientCmd 3 before 47)', () {
    test('nothing is sent from the prefs default alone', () {
      _onFakeClock((async, h) {
        expect(RidingFeature.smartHeadlight.defaultOn, isTrue);
        h.container.read(ridingSettingsProvider);
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3});
        async.elapse(AidlVehicleNotifier.smartLightEvery * 3);
        h.notifier.onLifecyclePause();
        h.notifier.onLifecycleResume();
        async.flushMicrotasks();
        expect(h.calls.where((c) => c.startsWith(_trigger) || c == _toggleOn), isEmpty);
      });
    });

    test('nothing is sent while the vehicle reports it off', () {
      _onFakeClock((async, h) {
        h.notifier.onEvent({'_connected': true, 'INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT': 0});
        async.elapse(AidlVehicleNotifier.smartLightEvery * 2);
        expect(h.calls, isEmpty);
      });
    });

    test('the persisted "on" restores it: trigger, then the toggle, by day', () {
      _onFakeClock((async, h) {
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, ..._smartOn});
        async.flushMicrotasks();
        expect(h.calls, ['$_trigger=false', _toggleOn]);
        final e = _events('hhmis', 'smart_light_trigger').single;
        expect(_data(e), containsPair('reason', 'restore'));
        expect(_data(e), containsPair('night', false));
        expect(_data(e), containsPair('sun_known', false));
      });
    });

    test('uses the vehicle\'s sunset once TX 8 has arrived', () {
      _onFakeClock((async, h) {
        AidlVehicleNotifier.clock = () => DateTime(2026, 11, 12, 17, 45);
        h.notifier.onEvent({
          '_connected': true,
          'INT_VEHICLE_STATE': 3,
          '_sunTimes': {'sunrise': '2026-11-12 06:30:40', 'sunset': '2026-11-12 17:40:00'},
        });
        h.notifier.onEvent(_smartOn);
        async.flushMicrotasks();
        expect(h.calls, ['$_trigger=true', _toggleOn], reason: '17:45 is day by the 18:00 fallback, night by the report');
      });
    });

    test('repeats every minute and on resume; logs only a change of the answer', () {
      _onFakeClock((async, h) {
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, ..._smartOn});
        async.elapse(AidlVehicleNotifier.smartLightEvery);
        expect(h.calls, ['$_trigger=false', _toggleOn, '$_trigger=false', _toggleOn]);
        expect(_events('hhmis', 'smart_light_trigger'), hasLength(1));
        AidlVehicleNotifier.clock = () => DateTime(2026, 11, 12, 18, 30);
        async.elapse(AidlVehicleNotifier.smartLightEvery);
        expect(h.calls.sublist(4), ['$_trigger=true', _toggleOn]);
        expect(_events('hhmis', 'smart_light_trigger').map((e) => _data(e)['night']), [false, true]);
        h.notifier.onLifecyclePause();
        h.notifier.onLifecycleResume();
        async.flushMicrotasks();
        expect(h.calls.sublist(6), ['$_trigger=true', _toggleOn]);
        expect(_data(_events('hhmis', 'smart_light_trigger').last)['reason'], 'resume');
      });
    });

    test('the rider switching it on sends the trigger before the toggle; off sends only 47 = 0', () {
      _onFakeClock((async, h) {
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3});
        h.container.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.smartHeadlight, true);
        async.flushMicrotasks();
        expect(h.calls, ['$_trigger=false', _toggleOn]);
        h.calls.clear();
        h.container.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.smartHeadlight, false);
        async.elapse(AidlVehicleNotifier.smartLightEvery * 2);
        expect(h.calls, ['sendIntCmd SMART_HEADLIGHT_TOGGLE=0']);
      });
    });

    test('reported unavailable, it still sends: this VCU acts on the trigger anyway', () {
      _onFakeClock((async, h) {
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, 'BOOL_SMART_HEAD_LIGHT_FEATURE_AVAILABLE': false});
        expect(h.container.read(vehicleProvider).featureAvailable['smartHeadlight'], isFalse);
        expect(_data(_events('hhmis', 'feature_available').single), {'key': 'BOOL_SMART_HEAD_LIGHT_FEATURE_AVAILABLE', 'value': false});
        h.container.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.smartHeadlight, true);
        async.flushMicrotasks();
        expect(h.calls, ['$_trigger=false', _toggleOn]);
        expect(_events('hhmis', 'feature_blocked'), isEmpty);
      });
    });

    test('nothing goes out before HHMIS is bound', () {
      _onFakeClock((async, h) {
        h.notifier.onEvent(_smartOn);
        async.elapse(AidlVehicleNotifier.smartLightEvery);
        expect(h.calls.where((c) => c.startsWith(_trigger)), isEmpty);
      });
    });

    test('the caption no longer promises an ambient-light sensor', () {
      expect(RidingFeature.smartHeadlight.caption, isNot(contains('ambient')));
      expect(RidingFeature.smartHeadlight.caption, contains('sunrise'));
    });
  });

  // Seen on a ride: smart headlight on, the VCU lit the high beam at every
  // motor start, four taps on the beam button sent highBeamOff and changed
  // nothing, and nothing on the dash said why.
  group('smart headlight: shown, and paused from the beam button', () {
    const pauseOff = 'sendIntCmd SMART_HEADLIGHT_TOGGLE=0';
    const beamOff = 'sendVoidCmd ${HhmisCmd.highBeamOff}=null';
    const beamOn = 'sendVoidCmd ${HhmisCmd.highBeamOn}=null';

    VehicleData state(_Harness h) => h.container.read(vehicleProvider);

    /// Smart headlight on, motor on, the VCU holding the high beam.
    void vcuHoldsBeam(FakeAsync async, _Harness h) {
      h.container.listen(toastProvider, (_, _) {});
      h.container.listen(ridingSettingsProvider, (_, _) {});
      h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, ..._smartOn});
      h.notifier.onEvent({'INT_VEHICLE_STATE': 4, 'BOOL_HIGH_BEAM_STATUS': true});
      async.flushMicrotasks();
      h.calls.clear();
    }

    List<Map<String, Object?>> pauses() => _events('hhmis', 'smart_light_pause').map(_data).toList();

    test('the icon follows the reported beam, and the mode says who drives it', () {
      _onFakeClock((async, h) {
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3});
        expect(state(h).smartHeadlight, SmartHeadlight.off);
        h.notifier.onEvent(_smartOn);
        expect(state(h).smartHeadlight, SmartHeadlight.auto);
        expect(state(h).highBeam, isFalse);
        h.notifier.onEvent({'INT_VEHICLE_STATE': 4, 'BOOL_HIGH_BEAM_STATUS': true});
        expect(state(h).highBeam, isTrue, reason: 'the VCU switched it on at motor start');
        h.notifier.onEvent({'INT_VEHICLE_STATE': 3, 'BOOL_HIGH_BEAM_STATUS': false});
        expect(state(h).highBeam, isFalse, reason: 'and off at park');
        h.notifier.onEvent({'INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT': 0});
        expect(state(h).smartHeadlight, SmartHeadlight.off);
      });
    });

    // Seen on a scooter: unlock after a pause that
    // had ended at the lock. 47 = 1 went out, the profile then replayed the
    // pause's own 0, the setting showed "off" with the vehicle's on, and
    // thirteen taps on the beam button did nothing.
    test('after a pause, the replay of its own "off" at the next unlock does not switch the setting off', () {
      _onFakeClock((async, h) {
        vcuHoldsBeam(async, h);
        h.notifier.toggleHighBeam();
        async.flushMicrotasks();
        expect(state(h).smartHeadlight, SmartHeadlight.paused);
        // Lock: the pause ends, nothing is sent to a locked scooter.
        h.notifier.onEvent({'INT_VEHICLE_STATE': 0, 'BOOL_HIGH_BEAM_STATUS': false});
        async.elapse(const Duration(seconds: 30));
        h.calls.clear();
        // Unlock, and the profile replay just behind it.
        h.notifier.onEvent({'INT_VEHICLE_STATE': 3, '_unlocked': true});
        async.flushMicrotasks();
        expect(h.calls, contains(_toggleOn), reason: 'the resume: \$_trigger then 47 = 1');
        h.notifier.onEvent({'INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT': 0});
        expect(state(h).smartHeadlight, SmartHeadlight.auto, reason: 'that 0 is the pause\'s own');
        expect(_events('hhmis', 'smart_light_stale_off'), hasLength(1));

        // So the beam button still pauses, which is what releases the lamp.
        h.notifier.onEvent({'INT_VEHICLE_STATE': 4, 'BOOL_HIGH_BEAM_STATUS': true});
        h.calls.clear();
        h.notifier.toggleHighBeam();
        async.flushMicrotasks();
        expect(h.calls, contains('sendIntCmd SMART_HEADLIGHT_TOGGLE=0'));
        expect(state(h).smartHeadlight, SmartHeadlight.paused);
      });
    });

    test('the vehicle\'s "on" settles it; an "off" after that is the vehicle\'s own word again', () {
      _onFakeClock((async, h) {
        vcuHoldsBeam(async, h);
        h.notifier.toggleHighBeam();
        h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
        h.notifier.onEvent({'INT_VEHICLE_STATE': 3, '_unlocked': true});
        h.notifier.onEvent({'INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT': 0});
        expect(state(h).smartHeadlight, SmartHeadlight.auto);
        h.notifier.onEvent({'INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT': 1});
        h.notifier.onEvent({'INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT': 0});
        expect(state(h).smartHeadlight, SmartHeadlight.off, reason: 'switched off somewhere else, for real');
        async.elapse(const Duration(seconds: 5));
      });
    });

    test('a plain "off" the vehicle does not obey is said, not toasted as done', () {
      _onFakeClock((async, h) {
        h.container.listen(toastProvider, (_, _) {});
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 4, 'BOOL_HIGH_BEAM_STATUS': true});
        async.flushMicrotasks();
        expect(state(h).smartHeadlight, SmartHeadlight.off);
        h.notifier.toggleHighBeam();
        async.elapse(AidlVehicleNotifier.highBeamEcho + const Duration(milliseconds: 100));
        expect(h.container.read(toastProvider)?.message, 'The scooter is keeping the high beam on');
        expect(_events('hhmis', 'high_beam_held'), hasLength(1));
        expect(state(h).highBeam, isTrue);
        async.elapse(const Duration(seconds: 10));
      });
    });

    test('reported as not available on this scooter: auto all the same', () {
      _onFakeClock((async, h) {
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, 'BOOL_SMART_HEAD_LIGHT_FEATURE_AVAILABLE': false, ..._smartOn});
        expect(state(h).smartHeadlight, SmartHeadlight.auto);
        expect(h.calls, isNotEmpty, reason: 'the trigger and 47 = 1 go out');
      });
    });

    test('a tap on a beam the VCU holds says it is day, sends 47 = 0, then highBeamOff, and pauses', () {
      _onFakeClock((async, h) {
        vcuHoldsBeam(async, h);
        h.notifier.cycleLights();
        async.flushMicrotasks();
        expect(h.calls, ['sendBoolCmd BOOL_TRIGGER_SMART_LIGHT_ACTION=false', pauseOff, beamOff]);
        expect(state(h).smartHeadlight, SmartHeadlight.paused);
        expect(h.container.read(toastProvider)?.message, 'Smart headlight paused');
        expect(pauses(), [
          {'on': true, 'source': 'tap'},
        ]);
        expect(h.container.read(ridingSettingsProvider).isOn(RidingFeature.smartHeadlight), isTrue,
            reason: 'only the vehicle is told');
        expect(state(h).highBeam, isTrue, reason: 'still what the vehicle reports');
        h.notifier.onEvent({'BOOL_HIGH_BEAM_STATUS': false});
        expect(state(h).highBeam, isFalse);
      });
    });

    test('while paused the minute tick and a return to the foreground send nothing', () {
      _onFakeClock((async, h) {
        vcuHoldsBeam(async, h);
        h.notifier.toggleHighBeam();
        async.flushMicrotasks();
        h.calls.clear();
        async.elapse(AidlVehicleNotifier.smartLightEvery * 3);
        h.notifier.onLifecyclePause();
        h.notifier.onLifecycleResume();
        async.flushMicrotasks();
        expect(h.calls, isEmpty);
        expect(state(h).smartHeadlight, SmartHeadlight.paused);
      });
    });

    test('while paused the button is the manual high-beam switch', () {
      _onFakeClock((async, h) {
        vcuHoldsBeam(async, h);
        h.notifier.toggleHighBeam();
        h.notifier.onEvent({'BOOL_HIGH_BEAM_STATUS': false});
        async.flushMicrotasks();
        h.calls.clear();
        h.notifier.toggleHighBeam();
        async.flushMicrotasks();
        expect(h.calls, [beamOn]);
        expect(state(h).highBeam, isTrue);
        h.notifier.toggleHighBeam();
        async.flushMicrotasks();
        expect(h.calls, [beamOn, beamOff]);
        expect(state(h).highBeam, isFalse);
        expect(state(h).smartHeadlight, SmartHeadlight.paused);
      });
    });

    test('the persisted 0 that follows our own 47 = 0 does not switch the setting off', () {
      _onFakeClock((async, h) {
        vcuHoldsBeam(async, h);
        h.notifier.toggleHighBeam();
        async.flushMicrotasks();
        h.calls.clear();
        h.notifier.onEvent({'INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT': 0});
        expect(h.container.read(ridingSettingsProvider).isOn(RidingFeature.smartHeadlight), isTrue);
        expect(state(h).featureMirror['smartHeadlight'], isTrue);
        expect(state(h).smartHeadlight, SmartHeadlight.paused);
        h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
        h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
        async.flushMicrotasks();
        expect(h.calls, containsAllInOrder(['$_trigger=false', _toggleOn]), reason: 'resume still works');
      });
    });

    // The stand going down at a stop reports PARK and undid a
    // pause 13 s after the tap.
    test('a park does not end the pause; a lock does, and the unlock sends the enable', () {
      _onFakeClock((async, h) {
        vcuHoldsBeam(async, h);
        h.notifier.toggleHighBeam();
        async.flushMicrotasks();
        h.calls.clear();
        h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
        h.notifier.onEvent({'INT_VEHICLE_STATE': 4});
        async.flushMicrotasks();
        expect(state(h).smartHeadlight, SmartHeadlight.paused);
        expect(h.calls, isEmpty);
        h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
        async.flushMicrotasks();
        expect(state(h).smartHeadlight, SmartHeadlight.auto);
        expect(pauses().last, {'on': false, 'source': 'lock'});
        expect(h.calls, isNot(contains(_toggleOn)), reason: 'nothing is sent to a locked scooter');
        expect(h.container.read(toastProvider)?.message, 'Smart headlight paused');
        h.calls.clear();
        h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
        async.flushMicrotasks();
        expect(h.calls, ['$_trigger=false', _toggleOn]);
        expect(_data(_events('hhmis', 'smart_light_trigger').last)['reason'], 'unlock');
        async.elapse(AidlVehicleNotifier.smartLightEvery);
        expect(h.calls.sublist(2), ['$_trigger=false', _toggleOn], reason: 'the tick is back');
      });
    });

    test('nothing is sent while locked or with the screen off', () {
      _onFakeClock((async, h) {
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, ..._smartOn});
        async.flushMicrotasks();
        h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
        async.flushMicrotasks();
        h.calls.clear();
        // The hourly wake of a locked scooter, then the minute tick.
        h.notifier.onLifecyclePause();
        h.notifier.onLifecycleResume();
        async.elapse(AidlVehicleNotifier.smartLightEvery);
        expect(h.calls.where((c) => c == _toggleOn), isEmpty);
        // Unlocked but behind another app / screen off: still nothing.
        h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
        async.flushMicrotasks();
        h.calls.clear();
        h.notifier.onLifecyclePause();
        async.elapse(AidlVehicleNotifier.smartLightEvery);
        expect(h.calls.where((c) => c == _toggleOn), isEmpty);
      });
    });

    test('a long-press resumes it and says so; a manual beam of ours goes off first', () {
      _onFakeClock((async, h) {
        vcuHoldsBeam(async, h);
        h.notifier.resumeSmartHeadlight();
        async.flushMicrotasks();
        expect(h.calls, isEmpty, reason: 'nothing to resume');
        h.notifier.toggleHighBeam();
        h.notifier.onEvent({'BOOL_HIGH_BEAM_STATUS': false});
        h.notifier.toggleHighBeam();
        async.flushMicrotasks();
        h.calls.clear();
        h.notifier.resumeSmartHeadlight();
        async.flushMicrotasks();
        expect(h.calls, [beamOff, '$_trigger=false', _toggleOn]);
        expect(state(h).smartHeadlight, SmartHeadlight.auto);
        expect(state(h).highBeam, isFalse, reason: 'back to the reported value');
        expect(h.container.read(toastProvider)?.message, 'Smart headlight resumed');
        expect(pauses().last, {'on': false, 'source': 'long_press'});
      });
    });

    test('switching the setting off while paused ends the pause', () {
      _onFakeClock((async, h) {
        vcuHoldsBeam(async, h);
        h.notifier.toggleHighBeam();
        async.flushMicrotasks();
        h.calls.clear();
        h.container.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.smartHeadlight, false);
        h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
        async.elapse(AidlVehicleNotifier.smartLightEvery);
        expect(h.calls, [pauseOff]);
        expect(state(h).smartHeadlight, SmartHeadlight.off);
        expect(pauses().last, {'on': false, 'source': 'setting'});
      });
    });

    test('a low beam, or our own manual high beam, is not a pause', () {
      _onFakeClock((async, h) {
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 4, 'BOOL_LOW_BEAM_STATUS': true, ..._smartOn});
        async.flushMicrotasks();
        h.calls.clear();
        h.notifier.toggleHighBeam();
        h.notifier.toggleHighBeam();
        async.flushMicrotasks();
        expect(h.calls, [beamOn, beamOff]);
        expect(state(h).smartHeadlight, SmartHeadlight.auto);
      });
    });

    test('the sends are logged as commands, except a tick whose answer did not change', () {
      _onFakeClock((async, h) {
        List<String> sent() => [
              for (final e in _events('hhmis', 'cmd_send')) '${_data(e)['name']}=${_data(e)['value']}',
            ];
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 4, ..._smartOn, 'BOOL_HIGH_BEAM_STATUS': true});
        async.flushMicrotasks();
        expect(sent(), ['triggerSmartLight=false', 'smartHeadlight=1']);
        expect(_events('hhmis', 'cmd_result'), hasLength(2));
        async.elapse(AidlVehicleNotifier.smartLightEvery * 2);
        expect(sent(), hasLength(2), reason: 'two quiet ticks');
        AidlVehicleNotifier.clock = () => DateTime(2026, 11, 12, 18, 30);
        async.elapse(AidlVehicleNotifier.smartLightEvery);
        expect(sent().sublist(2), ['triggerSmartLight=true', 'smartHeadlight=1']);
        h.notifier.toggleHighBeam();
        async.flushMicrotasks();
        expect(sent().sublist(4), ['triggerSmartLight=false', 'smartHeadlight=0', 'highBeamOff=null']);
      });
    });

    test('a pause that outlived the process: the profile\'s 0 is ignored and the next park resumes', () async {
      SharedPreferences.setMockInitialValues({PrefsKeys.smartHeadlightPaused: true});
      await PrefsService.init();
      addTearDown(PrefsService.resetForTest);
      final h = _Harness();
      h.container.listen(ridingSettingsProvider, (_, _) {});
      expect(state(h).smartHeadlight, SmartHeadlight.paused);
      h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 6, 'INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT': 0});
      await Future<void>.delayed(Duration.zero);
      expect(h.calls, isEmpty);
      expect(h.container.read(ridingSettingsProvider).isOn(RidingFeature.smartHeadlight), isTrue);
      h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
      h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
      await Future<void>.delayed(Duration.zero);
      expect(h.calls, containsAllInOrder(['$_trigger=false', _toggleOn]));
      expect(state(h).smartHeadlight, SmartHeadlight.auto);
      expect((await SharedPreferences.getInstance()).getBool(PrefsKeys.smartHeadlightPaused), isFalse);
      h.dispose();
    });
  });

  group('sound levels (callback TX 10 / 11, server TX 12 / 13)', () {
    test('the vehicle\'s stored 0-7 levels land on the sliders and are not sent back', () {
      final h = _Harness();
      h.notifier.onEvent({'_connected': true, '_motorVolume': 0, '_chimeVolume': 4});
      final s = h.container.read(soundSettingsProvider);
      expect(s.motorVolume, 0);
      expect(s.chimeVolume, 57);
      expect(h.calls, isEmpty);
      expect(_data(_events('hhmis', 'sound_levels').single), {'motor': 0, 'chime': 4});
      h.dispose();
    });

    test('every stored level survives the round trip through the slider', () {
      for (var level = 0; level <= 7; level++) {
        final percent = SoundSettingsNotifier.percentOfStored(level);
        expect(SoundSettingsNotifier.vehicleLevel(percent), level * 2, reason: 'HHMIS halves 0-14 back to $level');
      }
      expect(SoundSettingsNotifier.vehicleLevel(100), 14);
    });

    test('a drag sends one call per step of the 0-14 scale', () async {
      final h = _Harness();
      h.notifier.onEvent({'_connected': true, '_motorVolume': 4});
      final n = h.container.read(soundSettingsProvider.notifier);
      n.setMotorVolume(57);
      n.setMotorVolume(58);
      n.setMotorVolume(64);
      n.setMotorVolume(100);
      n.setMotorVolume(0);
      n.setChimeVolume(50);
      n.setChimeVolume(51);
      await Future<void>.delayed(Duration.zero);
      expect(h.calls, ['setMotorVolume 9', 'setMotorVolume 14', 'setMotorVolume 0', 'setChimeVolume 7']);
      expect(h.container.read(soundSettingsProvider).motorVolume, 0);
      h.dispose();
    });

    test('chime volume stops at stock\'s 40 % floor; a lower stored level is shown as it is', () async {
      final h = _Harness();
      h.notifier.onEvent({'_connected': true, '_chimeVolume': 1});
      expect(h.container.read(soundSettingsProvider).chimeVolume, 14, reason: 'the vehicle wins');
      final n = h.container.read(soundSettingsProvider.notifier);
      n.setChimeVolume(1);
      await Future<void>.delayed(Duration.zero);
      expect(h.container.read(soundSettingsProvider).chimeVolume, SoundSettingsNotifier.chimeFloor);
      expect(h.calls, ['setChimeVolume 6']);
      h.dispose();
    });

    test('a preset is the stock mood id on INT_MODE_UPDATE', () async {
      final h = _Harness();
      h.notifier.onEvent({'_connected': true});
      final n = h.container.read(soundSettingsProvider.notifier);
      n.setPreset(SoundPreset.eclipse);
      n.setPreset(SoundPreset.vintage);
      n.setPreset(SoundPreset.bolt);
      await Future<void>.delayed(Duration.zero);
      expect(HhmisCmd.modeUpdate, 'INT_MODE_UPDATE');
      expect(h.calls, ['sendIntCmd INT_MODE_UPDATE=0', 'sendIntCmd INT_MODE_UPDATE=1', 'sendIntCmd INT_MODE_UPDATE=2']);
      h.dispose();
    });

    test('the mock has nowhere to send them', () {
      final c = ProviderContainer();
      c.read(soundSettingsProvider.notifier)
        ..setMotorVolume(80)
        ..setPreset(SoundPreset.vintage);
      expect(c.read(soundSettingsProvider).motorVolume, 80);
      c.dispose();
    });
  });

  group('popup command (callback TX 12)', () {
    test('is logged, shows nothing and sends nothing', () {
      final h = _Harness();
      h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3});
      final before = h.container.read(vehicleProvider);
      h.notifier.onEvent({
        '_popupCommand': {'id': 3, 'header': 'Battery health', 'content': 'x' * 40, 'icon': 2},
      });
      expect(_data(_events('hhmis', 'popup_command').single),
          {'id': 3, 'header': 'Battery health', 'content_len': 40, 'icon': 2});
      expect(_events('hhmis', 'popup_command_dropped'), isEmpty);
      expect(h.container.read(vehicleProvider), before);
      expect(h.calls, isEmpty);
      h.dispose();
    });

    test('null fields do not break the log line', () {
      final h = _Harness();
      h.notifier.onEvent({
        '_popupCommand': {'id': null, 'header': null, 'content': null, 'icon': null},
      });
      expect(_data(_events('hhmis', 'popup_command').single)['content_len'], isNull);
      h.dispose();
    });
  });

  group('BOOL_TOUCH_STATUS', () {
    test('a touch above 1 km/h does not count, as on stock', () {
      _onFakeClock((async, h) {
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 4, 'INT_VEHICLE_SPEED': 30});
        h.notifier.markTouched();
        async.elapse(AidlVehicleNotifier.touchStatusEvery);
        h.notifier.onEvent({'INT_VEHICLE_SPEED': 1});
        h.notifier.markTouched();
        async.elapse(AidlVehicleNotifier.touchStatusEvery);
        // Nothing at the touch at 30 km/h; at 1 km/h, at the touch and at the tick.
        expect(h.touches, [false, true, true]);
      });
    });
  });

  // Seen on a scooter: nothing on screen said the scooter was
  // about to lock itself; a touch at about 62 s was a second too late.
  group('idle-lock warning', () {
    const unlockedParked = {'_connected': true, '_unlocked': true, 'INT_VEHICLE_STATE': 3, 'INT_VEHICLE_SPEED': 0, 'BOOL_SIDE_STAND_ICON_STATUS': true};
    const after = AidlVehicleNotifier.idleLockAfter;
    const warn = AidlVehicleNotifier.idleLockWarning;

    void clock(FakeAsync async, void Function() body) {
      AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
      try {
        body();
      } finally {
        AnalyticsLogger.instance.monoOverride = null;
      }
    }

    test('counts down the last seconds before the vehicle locks, and a touch clears it', () {
      _onFakeClock((async, h) {
        clock(async, () {
          h.notifier.onEvent(unlockedParked);
          h.notifier.markTouched();
          async.elapse(after - warn - const Duration(seconds: 2));
          expect(h.notifier.idleLockIn.value, isNull);
          async.elapse(const Duration(seconds: 3));
          expect(h.notifier.idleLockIn.value, inInclusiveRange(warn.inSeconds - 3, warn.inSeconds));
          final first = h.notifier.idleLockIn.value!;
          async.elapse(const Duration(seconds: 5));
          expect(h.notifier.idleLockIn.value, first - 5);
          expect(_data(_events('safety', 'idle_lock_warning').single), containsPair('shown', true));

          h.notifier.markTouched();
          expect(h.notifier.idleLockIn.value, isNull, reason: 'at the touch, not a second later');
          expect(h.touches.last, isTrue);
          expect(_data(_events('safety', 'idle_lock_warning').last), {'shown': false, 'outcome': 'awake', 'was_s': first - 5});
          async.elapse(after - warn - const Duration(seconds: 3));
          expect(h.notifier.idleLockIn.value, isNull, reason: 'the minute starts again');
        });
      });
    });

    test('with the side stand up the scooter does not lock itself: no countdown, one quiet hint', () {
      _onFakeClock((async, h) {
        clock(async, () {
          h.notifier.onEvent({...unlockedParked, 'BOOL_SIDE_STAND_ICON_STATUS': false});
          h.notifier.markTouched();
          async.elapse(after - const Duration(seconds: 2));
          expect(h.notifier.idleLockIn.value, isNull, reason: '"Locking in 14 s" stood over a scooter that stayed unlocked');
          expect(h.notifier.standUpHint.value, isFalse);
          async.elapse(const Duration(seconds: 4));
          expect(h.notifier.standUpHint.value, isTrue, reason: 'said when a lock would have come');
          expect(h.notifier.idleLockIn.value, isNull);
          async.elapse(AidlVehicleNotifier.standUpHintFor + const Duration(seconds: 2));
          expect(h.notifier.standUpHint.value, isFalse);
          async.elapse(after * 3);
          expect(h.notifier.standUpHint.value, isFalse, reason: 'once for each time it is left like that');
          expect(_events('safety', 'stand_up_hint'), hasLength(1));
        });
      });
    });

    test('the stand going down starts the minute', () {
      _onFakeClock((async, h) {
        clock(async, () {
          h.notifier.onEvent({...unlockedParked, 'BOOL_SIDE_STAND_ICON_STATUS': false});
          h.notifier.markTouched();
          async.elapse(const Duration(seconds: 67));
          h.notifier.onEvent({'BOOL_SIDE_STAND_ICON_STATUS': true});
          async.elapse(const Duration(seconds: 1));
          expect(h.notifier.standUpHint.value, isFalse, reason: 'the hint goes with the stand');
          async.elapse(after - warn - const Duration(seconds: 3));
          expect(h.notifier.idleLockIn.value, isNull, reason: 'the scooter locked 61 s after the stand, not after parking');
          async.elapse(const Duration(seconds: 5));
          expect(h.notifier.idleLockIn.value, isNotNull);
        });
      });
    });

    test('coming to a stop starts the minute: a touch made while riding does not count against it', () {
      _onFakeClock((async, h) {
        clock(async, () {
          h.notifier.onEvent({...unlockedParked, 'INT_VEHICLE_STATE': 4, 'INT_VEHICLE_SPEED': 0});
          h.notifier.markTouched();
          async.elapse(const Duration(seconds: 51));
          h.notifier.onEvent({'INT_VEHICLE_STATE': 3, 'INT_VEHICLE_SPEED': 0});
          async.elapse(const Duration(seconds: 20));
          expect(h.notifier.idleLockIn.value, isNull, reason: 'twenty seconds after the stop');
          async.elapse(after - warn - const Duration(seconds: 15));
          expect(h.notifier.idleLockIn.value, isNotNull, reason: 'a minute after the stop, less the warning');
        });
      });
    });

    test('a lock that does not come takes the warning down', () {
      _onFakeClock((async, h) {
        clock(async, () {
          h.notifier.onEvent(unlockedParked);
          h.notifier.markTouched();
          async.elapse(after + const Duration(seconds: 2));
          expect(h.notifier.idleLockIn.value, 0);
          async.elapse(AidlVehicleNotifier.idleLockOverdue + const Duration(seconds: 2));
          expect(h.notifier.idleLockIn.value, isNull);
          expect(_data(_events('safety', 'idle_lock_warning').last), containsPair('outcome', 'overdue'));
        });
      });
    });

    test('reaches "Locking" and goes when the scooter locks', () {
      _onFakeClock((async, h) {
        clock(async, () {
          h.notifier.onEvent(unlockedParked);
          h.notifier.markTouched();
          async.elapse(after + const Duration(seconds: 2));
          expect(h.notifier.idleLockIn.value, 0);
          h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
          async.elapse(const Duration(seconds: 2));
          expect(h.notifier.idleLockIn.value, isNull);
          expect(_data(_events('safety', 'idle_lock_warning').last), containsPair('outcome', 'locked'));
        });
      });
    });

    test('not while locked, on the charger, moving, or with another app in front', () {
      for (final (name, events, paused) in [
        ('locked', {'_connected': true, 'INT_VEHICLE_STATE': 2, 'INT_VEHICLE_SPEED': 0}, false),
        ('charging', {...unlockedParked, 'INT_VEHICLE_STATE': 6}, false),
        ('riding', {...unlockedParked, 'INT_VEHICLE_STATE': 4, 'INT_VEHICLE_SPEED': 20}, false),
        ('another app', unlockedParked, true),
      ]) {
        _onFakeClock((async, h) {
          clock(async, () {
            h.notifier.onEvent(events);
            if (paused) h.notifier.onLifecyclePause();
            async.elapse(after + const Duration(seconds: 5));
            expect(h.notifier.idleLockIn.value, isNull, reason: name);
            expect(_events('safety', 'idle_lock_warning'), isEmpty, reason: name);
          });
        });
        AnalyticsLogger.instance.resetForTest();
      }
    });

    test('what keeps the vehicle awake keeps the warning away: music while parked', () {
      _onFakeClock((async, h) {
        clock(async, () {
          h.notifier.onEvent(unlockedParked);
          h.notifier.onEvent({'media_state': 'playing', 'media_title': 't', 'media_artist': 'a', 'media_live': true});
          async.elapse(after + const Duration(seconds: 10));
          if (h.container.read(vehicleProvider).mediaPlaying) {
            expect(h.notifier.idleLockIn.value, isNull);
          }
        });
      });
    });

    test('leaving for another app takes the warning down', () {
      _onFakeClock((async, h) {
        clock(async, () {
          h.notifier.onEvent(unlockedParked);
          h.notifier.markTouched();
          async.elapse(after - const Duration(seconds: 5));
          expect(h.notifier.idleLockIn.value, isNotNull);
          h.notifier.onLifecyclePause();
          async.elapse(const Duration(seconds: 2));
          expect(h.notifier.idleLockIn.value, isNull);
        });
      });
    });
  });

  group('PROJECT_LOADED', () {
    test('waits out LOCK and PASSCODE, goes once at PARK', () {
      _onFakeClock((async, h) {
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 0, 'INT_VEHICLE_SPEED': 0});
        async.elapse(const Duration(seconds: 5));
        h.notifier.onEvent({'INT_VEHICLE_STATE': 2});
        async.elapse(const Duration(seconds: 5));
        expect(h.projectLoaded, 0, reason: 'HHMIS skips the reply when the saved state is PASSCODE 3 s later');
        h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
        async.elapse(const Duration(seconds: 10));
        h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
        expect(h.projectLoaded, 1);
      });
    });
  });
}
