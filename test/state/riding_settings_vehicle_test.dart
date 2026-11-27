import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/stock.dart';

/// Riding settings against the real bridge notifier, with the method
/// channel replaced by a list: what reaches HHMIS, in order.
class _Harness {
  _Harness() {
    container = ProviderContainer(overrides: [
      vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), 
            events: events.stream,
            invoke: (method, args) async {
              final housekeeping = args is Map &&
                  (args['cmd'] == HhmisCmd.projectLoaded || args['cmd'] == HhmisCmd.touchStatus) &&
                  method != 'sendIntCmd';
              if (!housekeeping) calls.add('$method $args');
              return true;
            },
          )),
    ]);
    riding;
  }

  final events = StreamController<dynamic>();
  final calls = <String>[];
  late final ProviderContainer container;

  AidlVehicleNotifier get vehicle => container.read(vehicleProvider.notifier) as AidlVehicleNotifier;
  RidingSettingsNotifier get riding => container.read(ridingSettingsProvider.notifier);
  RidingSettings get settings => container.read(ridingSettingsProvider);
  void hhmis(Map<String, Object?> batch) => vehicle.onEvent(batch);

  void dispose() {
    container.dispose();
    events.close();
  }
}

String _int(String cmd, int value) => 'sendIntCmd {cmd: $cmd, value: $value}';
String _void(String cmd) => 'sendVoidCmd {cmd: $cmd}';

void main() {
  setUp(AnalyticsLogger.instance.resetForTest);

  group('feature availability gate', () {
    test('"on" is never sent for a feature the scooter lacks; "off" still is', () {
      fakeAsync((async) {
        final h = _Harness();
        h.hhmis({'INT_TOW_TAMPER_DETECTION_FEATURE_AVAILABLE': 2, 'BOOL_SMART_HEAD_LIGHT_FEATURE_AVAILABLE': false});
        expect(h.container.read(vehicleProvider).isFeatureAvailable('tamper'), isFalse);
        h.riding.setFeature(RidingFeature.tamper, true);
        h.vehicle.setFeature(RidingFeature.tamper, true);
        async.flushMicrotasks();
        expect(h.calls, isEmpty);
        expect(h.container.read(toastProvider), isNull, reason: 'no "enabled" toast for a refused toggle');
        expect(AnalyticsLogger.instance.recent('hhmis', 'feature_blocked').single['data'], {'feature': 'tamper', 'value': 1});
        h.vehicle.setFeature(RidingFeature.tamper, false);
        async.flushMicrotasks();
        expect(h.calls, [_int('TOW_THEFT_TOGGLE', 0)]);
        h.dispose();
      });
    });

    test('smart headlight is sent even when reported unavailable; the flag is still logged', () {
      fakeAsync((async) {
        final h = _Harness();
        h.hhmis({'BOOL_SMART_HEAD_LIGHT_FEATURE_AVAILABLE': false, 'BOOL_PROXIMITY_LOCK_FEATURE_AVAILABLE': false});
        expect(h.container.read(vehicleProvider).featureAvailable['smartHeadlight'], isFalse);
        expect(
          [for (final e in AnalyticsLogger.instance.recent('hhmis', 'feature_available')) (e['data'] as Map)['key']],
          contains('BOOL_SMART_HEAD_LIGHT_FEATURE_AVAILABLE'),
        );
        h.riding.setFeature(RidingFeature.smartHeadlight, false);
        h.riding.setFeature(RidingFeature.smartHeadlight, true);
        h.riding.setFeature(RidingFeature.proximityUnlock, true);
        async.flushMicrotasks();
        expect(h.calls, [_int('SMART_HEADLIGHT_TOGGLE', 0), _int('SMART_HEADLIGHT_TOGGLE', 1)]);
        expect(h.settings.isOn(RidingFeature.smartHeadlight), isTrue);
        expect(AnalyticsLogger.instance.recent('hhmis', 'feature_blocked'), isEmpty, reason: 'proximity stops in the settings layer');
        h.dispose();
      });
    });

    test('a feature HHMIS has not reported yet still works', () {
      fakeAsync((async) {
        final h = _Harness();
        h.riding.setFeature(RidingFeature.smartDrl, false);
        h.riding.setFeature(RidingFeature.smartDrl, true);
        async.flushMicrotasks();
        expect(h.calls, [_int('SMART_DRL_TOGGLE', 0), _int('SMART_DRL_TOGGLE', 1)]);
        h.dispose();
      });
    });

    test('each availability change is logged with its raw value', () {
      final h = _Harness();
      h.hhmis({'INT_TOW_TAMPER_DETECTION_FEATURE_AVAILABLE': 2, 'INT_VEHICLE_SPEED': 0});
      h.hhmis({'INT_TOW_TAMPER_DETECTION_FEATURE_AVAILABLE': 2});
      h.hhmis({'INT_TECH_PACH_REGEN': 1});
      expect(AnalyticsLogger.instance.recent('hhmis', 'feature_available').map((e) => e['data']), [
        {'key': 'INT_TOW_TAMPER_DETECTION_FEATURE_AVAILABLE', 'value': 2},
        {'key': 'INT_TECH_PACH_REGEN', 'value': 1},
      ]);
      h.dispose();
    });
  });

  // This session got none of the nine BOOL availability keys
  // (HHMIS forwards each once), so Adaptive Power Boost and Smart headlight
  // were offered and "on" was sent for both.
  group('feature availability survives sessions', () {
    Future<void> boot(Map<String, Object> stored) async {
      SharedPreferences.setMockInitialValues(stored);
      await PrefsService.init();
      addTearDown(PrefsService.resetForTest);
    }

    Future<Object?> saved() async {
      final raw = (await SharedPreferences.getInstance()).getString(PrefsKeys.featureAvailable);
      return raw == null ? null : jsonDecode(raw);
    }

    test('the last report seeds the next start, is logged, and blocks an "on"', () async {
      await boot({
        PrefsKeys.featureAvailable: jsonEncode({'adaptivePowerBoost': false, 'smartHeadlight': false, 'hazard': true}),
      });
      final h = _Harness();
      final v = h.container.read(vehicleProvider);
      expect(v.isFeatureAvailable('adaptivePowerBoost'), isFalse);
      expect(v.featureAvailable['smartHeadlight'], isFalse);
      expect(v.isFeatureAvailable('smartHeadlight'), isTrue, reason: 'exempt: this VCU acts on it anyway');
      expect(v.isFeatureAvailable('hazard'), isTrue);
      expect(v.isFeatureAvailable('hillHold'), isTrue, reason: 'never reported: still counts as available');
      expect(AnalyticsLogger.instance.recent('hhmis', 'feature_available_seed').single['data'], {
        'features': {'adaptivePowerBoost': false, 'smartHeadlight': false, 'hazard': true},
      });
      h.hhmis({'_connected': true, 'INT_VEHICLE_STATE': 3});
      h.riding.setFeature(RidingFeature.adaptivePowerBoost, true);
      await Future<void>.delayed(Duration.zero);
      expect(h.calls, isEmpty);
      expect(h.container.read(toastProvider), isNull, reason: 'a refused toggle is not announced as enabled');
      h.dispose();
    });

    test('a fresh value from the vehicle wins and is written back', () async {
      await boot({PrefsKeys.featureAvailable: jsonEncode({'adaptivePowerBoost': false, 'takeMeHome': false})});
      final h = _Harness();
      h.hhmis({'BOOL_BOOST_MODE_FEATURE_AVAILABLE': true, 'BOOL_PROXIMITY_LOCK_FEATURE_AVAILABLE': false});
      final v = h.container.read(vehicleProvider);
      expect(v.isFeatureAvailable('adaptivePowerBoost'), isTrue);
      expect(v.isFeatureAvailable('proximityUnlock'), isFalse);
      expect(v.isFeatureAvailable('takeMeHome'), isFalse, reason: 'not reported again: the seed stands');
      expect(await saved(), {'adaptivePowerBoost': true, 'takeMeHome': false, 'proximityUnlock': false});
      h.hhmis({'INT_TAKE_ME_HOME_FEATURE_AVAILABLE': 1});
      expect(await saved(), {'adaptivePowerBoost': true, 'takeMeHome': true, 'proximityUnlock': false});
      h.dispose();
    });

    test('nothing saved, or a damaged value: no seed, nothing logged', () async {
      await boot({PrefsKeys.featureAvailable: '{not json'});
      final h = _Harness();
      expect(h.container.read(vehicleProvider).featureAvailable, isEmpty);
      expect(AnalyticsLogger.instance.recent('hhmis', 'feature_available_seed'), isEmpty);
      h.dispose();
    });
  });

  // HHMIS answers a toggle with BOOL_*_TOGGLE_STAT (true = handed to HVDP);
  // the *_PERSIST_* keys only come at profile load.
  group('a feature toggle the scooter does not confirm', () {
    test('the ack within 3 s keeps it', () {
      fakeAsync((async) {
        final h = _Harness();
        h.container.listen(toastProvider, (_, _) {});
        h.hhmis({'_connected': true, 'INT_VEHICLE_STATE': 3});
        h.riding.setFeature(RidingFeature.proximityUnlock, true);
        async.elapse(const Duration(seconds: 1));
        h.hhmis({'BOOL_PROXIMITY_TOGGLE_STAT': true});
        async.elapse(RidingSettingsNotifier.featureAckTimeout * 2);
        expect(h.settings.isOn(RidingFeature.proximityUnlock), isTrue);
        expect(h.container.read(toastProvider), isNull, reason: 'the "enabled" toast has timed out, no other came');
        expect(AnalyticsLogger.instance.recent('settings', 'feature_unanswered'), isEmpty);
        expect(AnalyticsLogger.instance.recent('hhmis', 'feature_ack').single['data'],
            {'feature': 'proximityUnlock', 'ok': true});
        h.dispose();
      });
    });

    test('no ack: it goes back, says so, and sends nothing more', () {
      fakeAsync((async) {
        final h = _Harness();
        h.container.listen(toastProvider, (_, _) {});
        h.hhmis({'_connected': true, 'INT_VEHICLE_STATE': 3});
        h.riding.setFeature(RidingFeature.adaptivePowerBoost, false);
        async.elapse(RidingSettingsNotifier.featureAckTimeout - const Duration(milliseconds: 1));
        expect(h.settings.isOn(RidingFeature.adaptivePowerBoost), isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(h.settings.isOn(RidingFeature.adaptivePowerBoost), isTrue);
        expect(h.container.read(toastProvider)?.message, 'Scooter did not confirm Adaptive Power Boost');
        expect(h.container.read(toastProvider)?.type, ToastType.warning);
        expect(h.calls, [_int('ADAPTIVE_POWERBOOST_TOGGLE', 0)]);
        expect(AnalyticsLogger.instance.recent('settings', 'feature_unanswered').single['data'],
            {'feature': 'adaptivePowerBoost', 'asked': false, 'ack': null});
        h.dispose();
      });
    });

    test('HHMIS could not hand it on (ack false): back at once', () {
      fakeAsync((async) {
        final h = _Harness();
        h.container.listen(toastProvider, (_, _) {});
        h.hhmis({'_connected': true, 'INT_VEHICLE_STATE': 3});
        h.riding.setFeature(RidingFeature.fallDetection, false);
        h.hhmis({'BOOL_ACCIDENT_DETECTION_TOGGLE_STAT': false});
        expect(h.settings.isOn(RidingFeature.fallDetection), isTrue);
        expect(h.container.read(toastProvider)?.message, 'Scooter did not confirm Fall detection');
        expect(AnalyticsLogger.instance.recent('settings', 'feature_unanswered').single['data'],
            {'feature': 'fallDetection', 'asked': false, 'ack': false});
        h.dispose();
      });
    });

    test('an ack nobody is waiting for, or for another feature, changes nothing', () {
      fakeAsync((async) {
        final h = _Harness();
        h.hhmis({'_connected': true, 'INT_VEHICLE_STATE': 3, 'BOOL_APB_TOGGLE_STAT': false});
        expect(h.settings.isOn(RidingFeature.adaptivePowerBoost), isTrue);
        h.riding.setFeature(RidingFeature.tamper, false);
        h.hhmis({'BOOL_APB_TOGGLE_STAT': true});
        async.elapse(RidingSettingsNotifier.featureAckTimeout);
        expect(h.settings.isOn(RidingFeature.tamper), isTrue, reason: 'its own ack never came');
        h.dispose();
      });
    });

    test('features with no ack key are left alone', () {
      fakeAsync((async) {
        final h = _Harness();
        h.hhmis({'_connected': true, 'INT_VEHICLE_STATE': 3});
        expect(h.vehicle.acksFeature(RidingFeature.predictedRange), isFalse);
        expect(h.vehicle.acksFeature(RidingFeature.smartHeadlight), isFalse, reason: '47 is re-sent every minute');
        expect(h.vehicle.acksFeature(RidingFeature.autoBrightness), isFalse);
        h.riding.setFeature(RidingFeature.predictedRange, false);
        h.riding.setFeature(RidingFeature.smartHeadlight, false);
        async.elapse(RidingSettingsNotifier.featureAckTimeout * 2);
        expect(h.settings.isOn(RidingFeature.predictedRange), isFalse);
        expect(h.settings.isOn(RidingFeature.smartHeadlight), isFalse);
        h.dispose();
      });
    });

    test('the mock has no acks and reverts nothing', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        c.read(ridingSettingsProvider.notifier).setFeature(RidingFeature.tamper, false);
        async.elapse(RidingSettingsNotifier.featureAckTimeout * 2);
        expect(c.read(ridingSettingsProvider).isOn(RidingFeature.tamper), isFalse);
        c.dispose();
      });
    });
  });

  group('hill-hold consent (ClientCmd 62)', () {
    test('agreeing sends HILL_HOLD_CONDITION_ACCEPTED, then the toggle', () {
      fakeAsync((async) {
        final h = _Harness();
        h.riding.setFeature(RidingFeature.hillHold, true);
        expect(h.settings.hillHoldPrompt, isTrue);
        async.flushMicrotasks();
        expect(h.calls, isEmpty);
        h.riding.acknowledgeHillHold();
        async.flushMicrotasks();
        expect(h.calls, [_void('HILL_HOLD_CONDITION_ACCEPTED'), _int('HILL_HOLD_TOGGLE', 1)]);
        expect(h.settings.isOn(RidingFeature.hillHold), isTrue);
        h.dispose();
      });
    });

    test('the vehicle remembers the consent: no disclaimer after a restart', () {
      fakeAsync((async) {
        final h = _Harness();
        h.hhmis({'INT_PERSISTED_USER_HILLHOLD_CONDITIONACCEPTED': 1});
        expect(h.settings.hillHoldAcknowledged, isTrue);
        h.riding.setFeature(RidingFeature.hillHold, true);
        async.flushMicrotasks();
        expect(h.settings.hillHoldPrompt, isFalse);
        expect(h.calls, [_int('HILL_HOLD_TOGGLE', 1)]);
        h.dispose();
      });
    });

    test('a consent replayed before the settings were first read still counts', () {
      final events = StreamController<dynamic>();
      final c = ProviderContainer(overrides: [
        vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: events.stream, invoke: (_, _) async => true)),
      ]);
      (c.read(vehicleProvider.notifier) as AidlVehicleNotifier).onEvent({
        'INT_PERSISTED_USER_HILLHOLD_CONDITIONACCEPTED': 1,
        'INT_PERSISTED_ALARM_ALERT_SOUND': 1,
        'INT_PERSISTED_SAFETY_SENSITIVITY': 1,
      });
      final r = c.read(ridingSettingsProvider);
      expect(r.hillHoldAcknowledged, isTrue);
      expect(r.alarmSound, AlarmSound.alert2);
      expect(r.detectionSensitivity, DetectionSensitivity.high);
      c.dispose();
      events.close();
    });
  });

  group('vacation mode (stock ACTION_LOCKSCOOTER sequence)', () {
    test('the toggle only asks; confirm sends hazards off, waits 200 ms, then 55 = 1', () {
      fakeAsync((async) {
        final h = _Harness();
        h.vehicle.toggleHazard();
        async.flushMicrotasks();
        expect(h.calls, [_int('HAZARD_LIGHT_TOGGLE', 1)]);
        h.calls.clear();

        h.riding.setFeature(RidingFeature.vacationMode, true);
        async.elapse(const Duration(seconds: 1));
        expect(h.settings.vacationPrompt, isTrue);
        expect(h.settings.isOn(RidingFeature.vacationMode), isFalse);
        expect(h.calls, isEmpty, reason: 'nothing before the rider confirms');

        h.riding.confirmVacation();
        async.flushMicrotasks();
        expect(h.settings.vacationPrompt, isFalse);
        expect(h.calls, [_int('HAZARD_LIGHT_TOGGLE', 0)]);
        async.elapse(AidlVehicleNotifier.vacationSendDelay - const Duration(milliseconds: 1));
        expect(h.calls, [_int('HAZARD_LIGHT_TOGGLE', 0)]);
        async.elapse(const Duration(milliseconds: 1));
        expect(h.calls, [_int('HAZARD_LIGHT_TOGGLE', 0), _int('VACATION_MODE_TOGGLE', 1)]);
        expect(h.settings.isOn(RidingFeature.vacationMode), isTrue);
        h.dispose();
      });
    });

    test('hazards already off: only the delayed 55 = 1; cancel sends nothing; off is direct', () {
      fakeAsync((async) {
        final h = _Harness();
        h.riding.setFeature(RidingFeature.vacationMode, true);
        h.riding.dismissVacationPrompt();
        async.elapse(const Duration(seconds: 1));
        expect(h.calls, isEmpty);
        expect(h.settings.isOn(RidingFeature.vacationMode), isFalse);

        h.riding.setFeature(RidingFeature.vacationMode, true);
        h.riding.confirmVacation();
        async.elapse(AidlVehicleNotifier.vacationSendDelay);
        expect(h.calls, [_int('VACATION_MODE_TOGGLE', 1)]);

        h.riding.setFeature(RidingFeature.vacationMode, false);
        async.flushMicrotasks();
        expect(h.calls, [_int('VACATION_MODE_TOGGLE', 1), _int('VACATION_MODE_TOGGLE', 0)]);
        h.dispose();
      });
    });
  });

  group('alarm sound and sensitivity (ClientCmd 58 / 60 / 59)', () {
    test('picking a sound sends its index, then stops the preview', () {
      fakeAsync((async) {
        final h = _Harness();
        h.riding.setAlarmSound(AlarmSound.alert2);
        async.flushMicrotasks();
        expect(h.calls, [_int('ALARM_SOUND_ALERT', 1)]);
        async.elapse(RidingSettingsNotifier.alarmPreview);
        expect(h.calls, [_int('ALARM_SOUND_ALERT', 1), _void('STOP_ALARM_SOUND')]);
        h.dispose();
      });
    });

    test('a second pick restarts the preview window: one stop, after the last pick', () {
      fakeAsync((async) {
        final h = _Harness();
        h.riding.setAlarmSound(AlarmSound.alert2);
        async.elapse(const Duration(seconds: 2));
        h.riding.setAlarmSound(AlarmSound.alert1);
        async.elapse(const Duration(seconds: 2));
        expect(h.calls, [_int('ALARM_SOUND_ALERT', 1), _int('ALARM_SOUND_ALERT', 0)]);
        async.elapse(const Duration(seconds: 2));
        expect(h.calls, [_int('ALARM_SOUND_ALERT', 1), _int('ALARM_SOUND_ALERT', 0), _void('STOP_ALARM_SOUND')]);
        h.dispose();
      });
    });

    test('the persisted sound and sensitivity are mirrored without a send', () {
      fakeAsync((async) {
        final h = _Harness();
        h.hhmis({'INT_PERSISTED_ALARM_ALERT_SOUND': 1, 'INT_PERSISTED_SAFETY_SENSITIVITY': 1});
        async.elapse(const Duration(seconds: 10));
        expect(h.settings.alarmSound, AlarmSound.alert2);
        expect(h.settings.detectionSensitivity, DetectionSensitivity.high);
        expect(h.calls, isEmpty);
        h.dispose();
      });
    });

    test('sensitivity: 0 low, 1 high; an unchanged pick sends nothing', () {
      fakeAsync((async) {
        final h = _Harness();
        h.riding.setDetectionSensitivity(DetectionSensitivity.low);
        h.riding.setDetectionSensitivity(DetectionSensitivity.high);
        h.riding.setDetectionSensitivity(DetectionSensitivity.low);
        async.flushMicrotasks();
        expect(h.calls, [_int('SAFETY_DETECTION_SENSITIVITY', 1), _int('SAFETY_DETECTION_SENSITIVITY', 0)]);
        h.dispose();
      });
    });
  });

  group('side stand', () {
    test('a bypass the scooter keeps shows here, is remembered, and nothing goes back', () async {
      SharedPreferences.setMockInitialValues({});
      await PrefsService.init();
      addTearDown(PrefsService.resetForTest);
      final h = _Harness();
      final before = h.calls.length;
      h.hhmis({'BOOL_SIDE_STAND_PERSIST_TOGGLE': true});
      await Future<void>.delayed(Duration.zero);
      expect(h.settings.isOn(RidingFeature.sideStandCutOff), isFalse);
      expect(RidingSettings.fromPrefs().isOn(RidingFeature.sideStandCutOff), isFalse, reason: 'survives a restart');
      expect(AnalyticsLogger.instance.recent('hhmis', 'side_stand_persist').last['data'], {'bypass': true});
      h.hhmis({'BOOL_SIDE_STAND_PERSIST_TOGGLE': false});
      await Future<void>.delayed(Duration.zero);
      expect(h.settings.isOn(RidingFeature.sideStandCutOff), isTrue);
      expect(h.calls.length, before);
      h.dispose();
    });
  });

  // 2026-11-27, Gen 1 on 4.6.14: `5B` on CAN and HHMIS's ack, then three
  // refusals over the stand. The scooter does not take the bypass.
  group('a bypass the scooter ignores', () {
    test('a stand refusal after the bypass settled puts the sensor back on and says so', () {
      fakeAsync((async) {
        AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
        final h = _Harness();
        h.riding.forceFeature(RidingFeature.sideStandCutOff, false);
        async.flushMicrotasks();
        expect(h.calls.last, _int('SIDE_STAND_TOGGLE', 1));
        h.hhmis({'BOOL_SIDE_STAND_TOGGLE_STAT': true});
        h.hhmis({'INT_VEHICLE_COMMAND': 59});
        async.flushMicrotasks();
        expect(h.settings.isOn(RidingFeature.sideStandCutOff), isFalse, reason: 'one in flight before the bypass landed');
        h.hhmis({'INT_VEHICLE_COMMAND': 0});
        async.elapse(const Duration(seconds: 5));
        h.hhmis({'INT_VEHICLE_COMMAND': 59});
        async.flushMicrotasks();
        expect(h.settings.isOn(RidingFeature.sideStandCutOff), isTrue);
        expect(h.settings.standBypassIgnored, isTrue);
        expect(h.calls.last, _int('SIDE_STAND_TOGGLE', 0));
        expect(AnalyticsLogger.instance.recent('settings', 'stand_bypass_ignored'), hasLength(1));
        expect(h.container.read(toastProvider)?.message, RidingSettingsNotifier.standBypassIgnoredMessage);
        expect(AnalyticsLogger.instance.recent('ui', 'toast').map((e) => (e['data'] as Map)['message']),
            isNot(contains('Side stand sensor enabled')), reason: 'one message for the revert');
        h.dispose();
      });
    });

    test('a refusal with the sensor on changes nothing', () {
      fakeAsync((async) {
        AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
        final h = _Harness();
        final before = h.calls.length;
        async.elapse(const Duration(seconds: 5));
        h.hhmis({'INT_VEHICLE_COMMAND': 59});
        async.flushMicrotasks();
        expect(h.settings.standBypassIgnored, isFalse);
        expect(h.calls.length, before);
        h.dispose();
      });
    });
  });

  group('regen (echo-driven, in-flight guard)', () {
    test('the selector moves on REGEN_SETTINGS_UPDATE, and a second pick waits for it', () {
      fakeAsync((async) {
        final h = _Harness();
        h.riding.setRegenMode(RegenMode.city);
        h.riding.setRegenMode(RegenMode.highway);
        async.flushMicrotasks();
        expect(h.calls, [_int('REGEN_SETTINGS_UPDATE', 2)], reason: 'the second pick is dropped while the first is unanswered');
        expect(h.settings.regenMode, RegenMode.standard);
        expect(h.settings.regenPending, RegenMode.city);

        h.hhmis({'REGEN_SETTINGS_UPDATE': 2});
        expect(h.settings.regenMode, RegenMode.city);
        expect(h.settings.regenPending, isNull);

        h.riding.setRegenMode(RegenMode.city);
        h.riding.setRegenMode(RegenMode.highway);
        async.flushMicrotasks();
        expect(h.calls, [_int('REGEN_SETTINGS_UPDATE', 2), _int('REGEN_SETTINGS_UPDATE', 1)], reason: 'the active mode is not re-sent');
        async.elapse(const Duration(seconds: 10));
        h.dispose();
      });
    });

    test('no echo: the selector unlocks after the timeout and says so', () {
      fakeAsync((async) {
        final h = _Harness();
        h.riding.setRegenMode(RegenMode.city);
        async.elapse(RidingSettingsNotifier.regenEchoTimeout);
        expect(h.settings.regenPending, isNull);
        expect(h.settings.regenMode, RegenMode.standard);
        expect(h.container.read(toastProvider)?.message, 'Scooter did not confirm the regen mode');
        expect(AnalyticsLogger.instance.recent('settings', 'regen_unanswered').single['data'], {'asked': 'city'});
        h.riding.setRegenMode(RegenMode.highway);
        async.flushMicrotasks();
        expect(h.calls, [_int('REGEN_SETTINGS_UPDATE', 2), _int('REGEN_SETTINGS_UPDATE', 1)]);
        async.elapse(const Duration(seconds: 10));
        h.dispose();
      });
    });

    test('without the regen tech pack only Default can be sent', () {
      fakeAsync((async) {
        final h = _Harness();
        h.hhmis({'REGEN_SETTINGS_UPDATE': 2, 'INT_TECH_PACH_REGEN': 0});
        h.riding.setRegenMode(RegenMode.highway);
        h.vehicle.sendRegenMode(RegenMode.off);
        async.flushMicrotasks();
        expect(h.calls, isEmpty);
        expect(h.settings.regenPending, isNull);
        h.riding.setRegenMode(RegenMode.standard);
        async.flushMicrotasks();
        expect(h.calls, [_int('REGEN_SETTINGS_UPDATE', 0)]);
        async.elapse(const Duration(seconds: 10));
        h.dispose();
      });
    });
  });

  group('phone-app requests (INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST)', () {
    test('feature requests go straight to the toggle, only when they change something', () {
      fakeAsync((async) {
        final h = _Harness();
        expect(h.settings.isOn(RidingFeature.hillHold), isFalse);
        h.hhmis({'INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST': 12});
        h.hhmis({'INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST': 12});
        h.hhmis({'INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST': 7});
        h.hhmis({'INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST': 4});
        h.hhmis({'INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST': 19});
        h.hhmis({'INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST': 15});
        async.flushMicrotasks();
        expect(h.calls, [_int('HILL_HOLD_TOGGLE', 1), _int('ACCIDENT_DETECTION_TOGGLE', 0), _int('SMART_DRL_TOGGLE', 0)],
            reason: 'hill hold on once, fall detection off, APB already on, smart DRL off, 15 has no handler');
        expect(h.settings.hillHoldPrompt, isFalse, reason: 'stock sends without the disclaimer');
        expect(h.settings.isOn(RidingFeature.hillHold), isTrue);
        expect(h.settings.isOn(RidingFeature.fallDetection), isFalse);
        expect(AnalyticsLogger.instance.recent('hhmis', 'companion_request'), hasLength(6));
        h.dispose();
      });
    });

    test('an "on" request for a feature the scooter lacks is not sent', () {
      fakeAsync((async) {
        final h = _Harness();
        h.hhmis({'INT_TOW_TAMPER_DETECTION_FEATURE_AVAILABLE': 2, 'BOOL_TOW_THEFT_PERSIST_TOGGLE_STAT': false});
        h.hhmis({'INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST': 8});
        async.flushMicrotasks();
        expect(h.calls, isEmpty);
        expect(h.settings.isOn(RidingFeature.tamper), isFalse);
        h.dispose();
      });
    });

    test('regen 1/2/3 are Default / City / Highway; 22 and 23 switch the hazards', () {
      fakeAsync((async) {
        final h = _Harness();
        h.hhmis({'INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST': 2});
        h.hhmis({'REGEN_SETTINGS_UPDATE': 2});
        h.hhmis({'INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST': 3});
        h.hhmis({'REGEN_SETTINGS_UPDATE': 1});
        h.hhmis({'INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST': 1});
        h.hhmis({'REGEN_SETTINGS_UPDATE': 0});
        h.hhmis({'INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST': 1});
        async.flushMicrotasks();
        expect(h.calls, [_int('REGEN_SETTINGS_UPDATE', 2), _int('REGEN_SETTINGS_UPDATE', 1), _int('REGEN_SETTINGS_UPDATE', 0)]);
        h.calls.clear();

        h.hhmis({'INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST': 23});
        h.hhmis({'INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST': 22});
        async.elapse(const Duration(seconds: 2));
        h.hhmis({'INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST': 22});
        h.hhmis({'INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST': 23});
        async.flushMicrotasks();
        expect(h.calls, [_int('HAZARD_LIGHT_TOGGLE', 1), _int('HAZARD_LIGHT_TOGGLE', 0)]);
        h.dispose();
      });
    });
  });
}
