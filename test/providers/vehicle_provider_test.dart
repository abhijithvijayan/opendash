import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_commands.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/ambient_health.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/state/alert_state.dart';
import 'package:opendash/state/passcode_state.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/theme_state.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:opendash/theme/dash_theme.dart';
import 'package:opendash/state/auto_brightness.dart';
import '../helpers/stock.dart';

class _Harness {
  _Harness({bool sendOk = true}) {
    container = ProviderContainer(overrides: [
      vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), 
            events: events.stream,
            invoke: (method, args) async {
              // The boot handshake and the 1 Hz touch heartbeat get their
              // own lists so command-order tests stay about commands.
              if (args is Map && method == 'sendVoidCmd' && args['cmd'] == HhmisCmd.projectLoaded) {
                projectLoaded++;
              } else if (args is Map && method == 'sendBoolCmd' && args['cmd'] == HhmisCmd.touchStatus) {
                touches.add(args['value'] as bool);
              } else {
                calls.add('$method $args');
              }
              return sendOk;
            },
          )),
    ]);
  }

  final events = StreamController<dynamic>();
  final calls = <String>[];
  final touches = <bool>[];
  var projectLoaded = 0;
  late final ProviderContainer container;

  AidlVehicleNotifier get notifier => container.read(vehicleProvider.notifier) as AidlVehicleNotifier;
  VehicleData get state => container.read(vehicleProvider);

  void dispose() {
    container.dispose();
    events.close();
  }
}

void main() {
  test('starts disconnected and locked, keeps the dashboard honest', () {
    final h = _Harness();
    expect(h.state.hhmisConnected, isFalse);
    expect(h.state.locked, isTrue);
    expect(h.state.wifiConnected, isFalse);
    expect(h.state.vin, '');
    h.dispose();
  });

  test('applies batches and flags the connection', () {
    final h = _Harness();
    h.notifier.onEvent({'_connected': true});
    expect(h.state.hhmisConnected, isTrue);
    h.notifier.onEvent({'INT_VEHICLE_SPEED': 37, 'INT_VEHICLE_STATE': 4});
    expect(h.state.speed, 37);
    expect(h.state.vehicleState, VehicleState.riding);
    h.dispose();
  });

  // Seen at a cold boot: ESCL 1 (handlebar free) came with the vehicle
  // in PASSCODE and the dashboard showed for 129 ms.
  test('a free handlebar does not unlock while the vehicle says LOCK, ALARM or PASSCODE', () {
    for (final locked in [0, 1, 2]) {
      final h = _Harness();
      h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': locked, 'INT_VEHICLE_ESCL_STATUS': 1});
      expect(h.state.locked, isTrue, reason: 'state $locked, same batch');
      h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 3});
      h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 1});
      expect(h.state.locked, isTrue, reason: 'state $locked, later batch');
      h.dispose();
    }
    final h = _Harness();
    h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 6, 'INT_VEHICLE_ESCL_STATUS': 3});
    expect(h.state.locked, isTrue);
    h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 1});
    expect(h.state.locked, isFalse, reason: 'on the charger the state stays 6 and ESCL is the unlock');
    h.dispose();
  });

  test('losing HHMIS keeps the last data on screen', () {
    final h = _Harness();
    h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_SPEED': 37, 'INT_BATTERY_SOC': 61});
    h.notifier.onEvent({'_connected': false});
    expect(h.state.hhmisConnected, isFalse);
    expect(h.state.speed, 37);
    expect(h.state.batterySoc, 61);
    h.notifier.onEvent({'INT_VEHICLE_SPEED': 12});
    expect(h.state.hhmisConnected, isTrue, reason: 'data flowing again means HHMIS is back');
    h.dispose();
  });

  test('stream events reach the notifier', () async {
    final h = _Harness();
    h.notifier;
    h.events.add({'INT_VEHICLE_SPEED': 9});
    await Future<void>.delayed(Duration.zero);
    expect(h.state.speed, 9);
    h.dispose();
  });

  test('commands go out as ClientCmds', () async {
    final h = _Harness();
    // Unlock so the openTrunk guard doesn't swallow it.
    h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 1});
    h.notifier.lockScooter();
    // toggleLeftIndicator is a no-op; the test verifies the
    // other commands still go out.
    h.notifier.openTrunk();
    h.notifier.resetTrip();
    h.notifier.setFeature(RidingFeature.hillHold, true);
    h.notifier.setBrightness(40);
    h.notifier.setVolume(30, announce: false);
    h.notifier.mediaNext();
    await Future<void>.delayed(Duration.zero);
    expect(h.calls, containsAll([
      'sendIntCmd {cmd: INT_ESCL_LOCK_CMD, value: 0}',
      'sendVoidCmd {cmd: VOID_UNLOCK_SEAT}',
      'sendVoidCmd {cmd: VOID_RESET_TRIPO_METER_B}',
      'sendIntCmd {cmd: HILL_HOLD_TOGGLE, value: 1}',
      'setBrightness {value: 40, persist: true}',
      // 30 % of the 15 STREAM_MUSIC steps.
      'setVolume 5',
      'mediaKey next',
    ]));
    expect(h.state.volume, 30);
    h.dispose();
  });

  group('high beam (PARTY_MODE 29/30, never echoed)', () {
    test('a second tap sends Off even though HHMIS never reported the beam on', () async {
      final h = _Harness();
      h.notifier.onEvent({'INT_VEHICLE_STATE': 4, 'BOOL_HIGH_BEAM_STATUS': false});
      h.notifier.toggleHighBeam();
      expect(h.state.highBeam, isTrue);
      h.notifier.onEvent({'INT_VEHICLE_SPEED': 30, 'BOOL_HIGH_BEAM_STATUS': false});
      expect(h.state.highBeam, isTrue, reason: 'a later false echo must not hide the override');
      h.notifier.toggleHighBeam();
      expect(h.state.highBeam, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(h.calls, ['sendVoidCmd {cmd: PARTY_MODE_HIGH_BEAM_ON}', 'sendVoidCmd {cmd: PARTY_MODE_HIGH_BEAM_OFF}']);
      h.dispose();
    });

    test('LOCK switches an override off', () async {
      final h = _Harness();
      h.notifier.onEvent({'INT_VEHICLE_STATE': 4});
      h.notifier.toggleHighBeam();
      h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
      expect(h.state.highBeam, isTrue);
      h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
      expect(h.state.highBeam, isFalse);
      h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
      await Future<void>.delayed(Duration.zero);
      expect(h.calls, ['sendVoidCmd {cmd: PARTY_MODE_HIGH_BEAM_ON}', 'sendVoidCmd {cmd: PARTY_MODE_HIGH_BEAM_OFF}'], reason: 'Off goes out once');
      h.dispose();
    });
  });

  test('ignored HHMIS keys are not reported unknown; others log their first value', () {
    AnalyticsLogger.instance.resetForTest();
    final h = _Harness();
    h.notifier.onEvent({'FLOAT_VEHICLE_GYRO_X': 0.4, 'INT_SOMETHING_NEW': 7});
    final seen = AnalyticsLogger.instance.recent('hhmis', 'unknown_key_seen').map((e) => e['data']! as Map).toList();
    expect(seen.map((d) => d['key']), ['INT_SOMETHING_NEW']);
    expect(seen.single['value'], 7);
    h.dispose();
  });

  test('restart is stock\'s VOID_REBOOT_ON_FAULT_ACK (23)', () async {
    final h = _Harness();
    expect(await h.notifier.rebootScooter(), isTrue);
    expect(h.calls, ['sendVoidCmd {cmd: VOID_REBOOT_ON_FAULT_ACK}']);
    h.dispose();
  });

  group('INT_VEHICLE_COMMAND (CommandFromVehicle ordinals)', () {
    test('side stand (59) and no brake (62) flash their hint banners; 0 and 148 do nothing', () {
      fakeAsync((async) {
        AnalyticsLogger.instance.resetForTest();
        final h = _Harness();
        h.notifier.onEvent({'INT_VEHICLE_COMMAND': 59});
        expect(h.state.hintStandToRide, isTrue);
        h.notifier.onEvent({'INT_VEHICLE_COMMAND': 0});
        h.notifier.onEvent({'INT_VEHICLE_COMMAND': 62});
        expect(h.state.hintBrakeToStart, isTrue);
        async.elapse(VehicleNotifier.hintDuration);
        expect(h.state.hintStandToRide, isFalse);
        expect(h.state.hintBrakeToStart, isFalse);
        h.notifier.onEvent({'INT_VEHICLE_COMMAND': 148});
        expect(h.state.alerts, isEmpty);
        expect(AnalyticsLogger.instance.recent('hhmis', 'vehicle_command'), hasLength(4));
        h.dispose();
      });
    });

    // A refused start reaches us as a vehicle command (59 / 62), as a TX 14
    // popup (3 / 4 / 6 / 7), or as both: one banner, never a toast as well.
    test('a ride refusal is one surface: its banner, no toast and no notice', () {
      fakeAsync((async) {
        AnalyticsLogger.instance.resetForTest();
        final h = _Harness();
        h.container.listen(toastProvider, (_, _) {});
        const refusals = <(Map<String, Object?>, AlertKind)>[
          ({'INT_VEHICLE_COMMAND': 59}, AlertKind.standToRide),
          ({'INT_VEHICLE_COMMAND': 62}, AlertKind.brakeToStart),
          ({'_notificationPopup': {'id': 3, 'type': 0, 'status': true}}, AlertKind.driveModeInPark),
          ({'_notificationPopup': {'id': 4, 'type': 0, 'status': true}}, AlertKind.brakeToStart),
          ({'_notificationPopup': {'id': 6, 'type': 0, 'status': true}}, AlertKind.unplugChargerToRide),
          ({'_notificationPopup': {'id': 7, 'type': 0, 'status': true}}, AlertKind.standToRide),
          // Both callbacks for the one refusal.
          ({'INT_VEHICLE_COMMAND': 59, '_notificationPopup': {'id': 7, 'type': 0, 'status': true}}, AlertKind.standToRide),
        ];
        for (final (batch, kind) in refusals) {
          h.notifier.onEvent(batch);
          expect(h.state.alerts.map((a) => a.kind), [kind], reason: '$batch');
          expect(h.state.notice, isNull, reason: '$batch');
          async.elapse(VehicleNotifier.hintDuration);
          expect(h.state.alerts, isEmpty);
        }
        expect(AnalyticsLogger.instance.recent('ui', 'toast'), isEmpty);
        h.dispose();
      });
    });

    test('a derate holds its notice until 0, latches derating until a rerate', () {
      final h = _Harness();
      final shown = <String>[];
      h.container.listen(toastProvider, (_, t) {
        if (t != null) shown.add(t.message);
      });
      h.notifier.onEvent({'INT_VEHICLE_COMMAND': 13});
      expect(h.state.notice?.title, 'Overheating');
      expect(h.state.alerts.map((a) => a.kind), [AlertKind.vehicleNotice], reason: 'the generic "Power reduced" waits behind it');
      h.notifier.onEvent({'INT_VEHICLE_COMMAND': 0});
      expect(h.state.notice, isNull);
      expect(h.state.alerts.map((a) => a.kind), [AlertKind.deratingActive]);
      h.notifier.onEvent({'INT_VEHICLE_COMMAND': 51});
      expect(h.state.deratingActive, isFalse);
      expect(shown, ['Full performance restored']);
      h.dispose();
    });

    group('touchDisabled release path', () {
      test('first-ever false is ignored (no true seen yet)', () {
        final h = _Harness();
        h.notifier.onEvent({'BOOL_HEAD_UNIT_POWER_FLAG': false});
        expect(h.state.touchDisabled, isFalse,
            reason: 'first false after bind: pin pad must stay alive');
        h.dispose();
      });

      test('a false after a true disables touch and clears digits', () {
        final h = _Harness();
        // Prime: see a true.
        h.notifier.onEvent({'BOOL_HEAD_UNIT_POWER_FLAG': true, 'INT_VEHICLE_SPEED': 30, 'INT_VEHICLE_STATE': 4});
        // Fill some passcode digits.
        final p = h.container.read(passcodeProvider.notifier);
        p.enterDigit(1);
        p.enterDigit(2);
        p.enterDigit(3);
        expect(h.container.read(passcodeProvider).enteredDigits, [1, 2, 3]);
        // Now power drops: touch disabled, digits wiped.
        h.notifier.onEvent({'BOOL_HEAD_UNIT_POWER_FLAG': false, 'INT_VEHICLE_SPEED': 30, 'INT_VEHICLE_STATE': 4});
        expect(h.state.touchDisabled, isTrue);
        expect(h.container.read(passcodeProvider).enteredDigits, isEmpty);
        h.dispose();
      });

      // At the lock screen the scooter is parked, the gate is
      // released in the same batch, and two typed digits survived the
      // screen timing out.
      test('screen off at the lock screen clears typed digits though the gate stays open', () {
        AnalyticsLogger.instance.resetForTest();
        final h = _Harness();
        h.notifier.onEvent({'BOOL_HEAD_UNIT_POWER_FLAG': true, 'INT_VEHICLE_STATE': 2});
        final p = h.container.read(passcodeProvider.notifier);
        p.enterDigit(1);
        p.enterDigit(2);
        h.notifier.onEvent({'BOOL_HEAD_UNIT_POWER_FLAG': false});
        expect(h.state.touchDisabled, isFalse);
        expect(h.container.read(passcodeProvider).enteredDigits, isEmpty);
        expect(AnalyticsLogger.instance.recent('safety', 'passcode_cleared').single['data'], {'reason': 'screen_off', 'digits': 2});
        h.notifier.onEvent({'BOOL_HEAD_UNIT_POWER_FLAG': true});
        p.enterDigit(3);
        expect(h.container.read(passcodeProvider).enteredDigits, [3]);
        h.dispose();
      });

      test('PARK or low speed releases the gate', () {
        final h = _Harness();
        // Set up a 'touch disabled' state.
        h.notifier.onEvent({'BOOL_HEAD_UNIT_POWER_FLAG': true, 'INT_VEHICLE_SPEED': 30, 'INT_VEHICLE_STATE': 4});
        h.notifier.onEvent({'BOOL_HEAD_UNIT_POWER_FLAG': false, 'INT_VEHICLE_SPEED': 30, 'INT_VEHICLE_STATE': 4});
        expect(h.state.touchDisabled, isTrue);
        // Slowing down below 2 km/h clears it.
        h.notifier.onEvent({'INT_VEHICLE_SPEED': 1});
        expect(h.state.touchDisabled, isFalse);
        h.dispose();
      });
    });

    // An unknown INT_VEHICLE_COMMAND ordinal
    // must not clear the current notice. Only a 0 close or a new known
    // ordinal replaces it. knownUnmappedCommands log as known but also
    // do not clear.
    test('unknown or knownUnmapped ordinal does not clear the current notice', () {
      fakeAsync((async) {
        final h = _Harness();
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 4});
        h.notifier.onEvent({'INT_VEHICLE_COMMAND': 162});
        expect(h.state.notice?.command, 162);
        // An unknown ordinal (999 is not in any table) leaves the notice.
        h.notifier.onEvent({'INT_VEHICLE_COMMAND': 999});
        expect(h.state.notice?.command, 162, reason: 'unknown must not clear');
        // A knownUnmapped ordinal (148) also leaves the notice.
        h.notifier.onEvent({'INT_VEHICLE_COMMAND': 148});
        expect(h.state.notice?.command, 162, reason: 'knownUnmapped must not clear');
        async.elapse(AidlVehicleNotifier.noticeMinDisplay);
        expect(h.state.notice?.command, 162, reason: 'nothing asked to close it');
        // 0 clears, as stock does.
        h.notifier.onEvent({'INT_VEHICLE_COMMAND': 0});
        expect(h.state.notice, isNull);
        h.dispose();
      });
    });

    // CAN_FAIL (93) latches faultActive; the matching
    // rerate (98 _readyAgain) must clear it. Without this the fault
    // stays shown even after the vehicle reports normal again.
    test('rerate (98) clears a latched fault (CAN_FAIL 93)', () {
      final h = _Harness();
      h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 4});
      h.notifier.onEvent({'INT_VEHICLE_COMMAND': 93});
      expect(h.state.faultActive, isTrue);
      expect(h.state.faultCode, 'C93');
      h.notifier.onEvent({'INT_VEHICLE_COMMAND': 98});
      expect(h.state.faultActive, isFalse);
      expect(h.state.faultCode, '');
      expect(h.state.deratingActive, isFalse);
      h.dispose();
    });

    test('a fault latches until LOCK; a new command replaces the notice', () {
      fakeAsync((async) {
        final h = _Harness();
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 4});
        h.notifier.onEvent({'INT_VEHICLE_COMMAND': 162});
        expect(h.state.notice?.priority, AlertPriority.critical);
        expect(h.state.faultActive, isTrue);
        expect(h.state.faultCode, 'C162');
        async.elapse(AidlVehicleNotifier.noticeMinDisplay);
        h.notifier.onEvent({'INT_VEHICLE_COMMAND': 58});
        expect(h.state.notice?.command, 58);
        async.elapse(AidlVehicleNotifier.noticeMinDisplay);
        h.notifier.onEvent({'INT_VEHICLE_COMMAND': 0});
        expect(h.state.notice, isNull);
        expect(h.state.faultActive, isTrue, reason: '0 closes the popup, not the fault');
        h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
        h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
        expect(h.state.faultActive, isFalse);
        h.dispose();
      });
    });

    group('minimum display time of a held notice', () {
      List<Object?> banners(String evt) => [
            for (final e in AnalyticsLogger.instance.recent('modal', evt))
              if ((e['data']! as Map)['name'] == 'alert_banner') (e['data']! as Map)['command'],
          ];

      // Seen on a ride: 134 / 0 about 400 ms apart, three times.
      test('134 / 0 three times in three seconds is one notice, up for 4 s', () {
        fakeAsync((async) {
          AnalyticsLogger.instance.resetForTest();
          final h = _Harness();
          h.container.listen(dismissedAlertsProvider, (_, _) {});
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 4});
          var changes = 0;
          h.container.listen(vehicleProvider.select((v) => v.notice), (_, _) => changes++);
          const ms = Duration(milliseconds: 1);
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 134});
          async.elapse(ms * 384);
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 0});
          expect(h.state.notice?.command, 134, reason: 'the close waits');
          async.elapse(ms * 617);
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 134});
          async.elapse(ms * 375);
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 0});
          async.elapse(ms * 718);
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 134});
          async.elapse(ms * 379);
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 0});
          expect(h.state.notice?.title, 'Hill hold');
          expect(changes, 1, reason: 'a repeat does not re-trigger the banner');
          async.elapse(AidlVehicleNotifier.noticeMinDisplay - ms * 2473 - ms);
          expect(h.state.notice?.command, 134);
          async.elapse(ms);
          expect(h.state.notice, isNull, reason: '4 s after it first appeared');
          expect(banners('show'), [134]);
          expect(banners('dismiss'), [134]);
          expect(AnalyticsLogger.instance.recent('hhmis', 'notice_deferred'), hasLength(3));
          h.dispose();
        });
      });

      test('a repeat after the close was deferred keeps the notice up', () {
        fakeAsync((async) {
          final h = _Harness();
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 134});
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 0});
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 134});
          async.elapse(AidlVehicleNotifier.noticeMinDisplay * 2);
          expect(h.state.notice?.command, 134, reason: 'the condition came back and was not closed again');
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 0});
          expect(h.state.notice, isNull, reason: 'past the minimum a close is immediate');
          h.dispose();
        });
      });

      test('equal or higher priority replaces at once; lower priority waits', () {
        fakeAsync((async) {
          final h = _Harness();
          // info -> info
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 134});
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 58});
          expect(h.state.notice?.command, 58);
          // info -> critical
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 162});
          expect(h.state.notice?.command, 162);
          expect(h.state.faultActive, isTrue);
          // critical -> warning waits, but its latch does not
          async.elapse(const Duration(seconds: 1));
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 3});
          expect(h.state.notice?.command, 162);
          expect(h.state.deratingActive, isTrue);
          async.elapse(const Duration(seconds: 3));
          expect(h.state.notice?.command, 3, reason: 'shown once the fault notice had its 4 s');
          async.elapse(const Duration(seconds: 1));
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 0});
          expect(h.state.notice?.command, 3, reason: 'the waiting notice gets its own minimum');
          async.elapse(const Duration(seconds: 3));
          expect(h.state.notice, isNull);
          h.dispose();
        });
      });

      test('countdowns and the hill-hold release keep their own timing', () {
        fakeAsync((async) {
          final h = _Harness();
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 9});
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 0});
          expect(h.state.notice, isNull, reason: 'a countdown closes on 0 at once');
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 162});
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 9});
          expect(h.state.notice?.body, 'Switching to Park in 10 s', reason: 'a countdown does not wait its turn');
          async.elapse(const Duration(seconds: 10));
          expect(h.state.notice, isNull);
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 162});
          h.notifier.onEvent({'INT_HILL_HOLD_STATUS': 4});
          expect(h.state.notice?.command, hillHoldNoticeId, reason: 'not held back by the minimum');
          async.elapse(const Duration(seconds: 3));
          expect(h.state.notice, isNull);
          h.dispose();
        });
      });

      test('LOCK clears a notice inside its minimum, and a waiting one is dropped', () {
        fakeAsync((async) {
          final h = _Harness();
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3});
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 162});
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 3});
          h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
          expect(h.state.notice, isNull);
          async.elapse(AidlVehicleNotifier.noticeMinDisplay);
          expect(h.state.notice, isNull);
          h.dispose();
        });
      });
    });

    // Text read from stock HHMIC
    // `VehicleInfoManager.handleDerateEvents` + `NotificationText`.
    test('the 16 once-parked ordinals now show stock\'s message', () => fakeAsync((async) {
      AnalyticsLogger.instance.resetForTest();
      final h = _Harness();
      final shown = <String>[];
      h.container.listen(toastProvider, (_, t) {
        if (t != null) shown.add(t.message);
      });
      const held = {
        108: 'Charging not started',
        109: 'Charging not started',
        125: 'Riding access revoked',
        134: 'Hill hold',
        138: 'Access revoked',
        139: 'Scooter issue',
        140: 'Scooter issue',
        180: 'Not delivered yet',
        181: 'Scooter ready',
        182: 'Service mode',
        183: 'Service mode',
        184: 'Part mismatch',
        185: "Can't ride",
      };
      for (final MapEntry(key: ordinal, value: title) in held.entries) {
        h.notifier.onEvent({'INT_VEHICLE_COMMAND': ordinal});
        async.elapse(AidlVehicleNotifier.noticeMinDisplay);
        expect(h.state.notice?.command, ordinal);
        expect(h.state.notice?.title, title);
        expect(h.state.notice?.body, isNotEmpty);
      }
      // Red in stock, but a refusal: critical banner, no fault latch.
      for (final ordinal in [125, 138, 180, 182, 184, 185]) {
        expect(vehicleCommands[ordinal]!.priority, AlertPriority.critical, reason: '$ordinal');
        expect(vehicleCommands[ordinal]!.effect, CommandEffect.info, reason: '$ordinal');
      }
      expect(vehicleCommands[181]!.priority, AlertPriority.warning);
      expect(vehicleCommands[139]!.effect, CommandEffect.fault, reason: 'stock reuses the text of 73');
      h.notifier.onEvent({'INT_VEHICLE_COMMAND': 0});
      expect(h.state.notice, isNull);
      // 3 s popups in stock: toasts.
      h.notifier.onEvent({'INT_VEHICLE_COMMAND': 146});
      h.notifier.onEvent({'INT_VEHICLE_COMMAND': 147});
      expect(shown, ['Not allowed to switch to Sport or Hyper', 'Not allowed to switch to Hyper']);
      expect(h.state.notice, isNull);
      // 160 is 59's popup.
      h.notifier.onEvent({'INT_VEHICLE_COMMAND': 160});
      expect(h.state.hintStandToRide, isTrue);
      expect(knownUnmappedCommands, {60, 111, 148}, reason: '60 and 148: stock shows nothing of its own; 111: the charge status says it once');
      final logged = AnalyticsLogger.instance.recent('hhmis', 'vehicle_command').map((e) => e['data']! as Map);
      expect(logged.where((d) => d['value'] != 0).every((d) => d['known'] == true), isTrue);
      expect(logged.any((d) => d['unmapped'] == true), isFalse);
      h.dispose();
    }));

    // The VCU's own low-battery message.
    test('GENERAL_LOW_BATTERY (34) is a held warning that latches nothing', () {
      final h = _Harness();
      h.notifier.onEvent({'INT_VEHICLE_COMMAND': 34});
      expect(h.state.notice?.title, 'Low battery');
      expect(h.state.notice?.priority, AlertPriority.warning);
      expect(h.state.deratingActive, isFalse);
      h.dispose();
    });

    test('restart faults 72 and 75 carry the restart action', () {
      final h = _Harness();
      for (final ordinal in [72, 75]) {
        h.notifier.onEvent({'INT_VEHICLE_COMMAND': ordinal});
        expect(h.state.notice?.action, AlertAction.restartScooter);
        expect(h.state.alerts.first.action, AlertAction.restartScooter);
      }
      h.notifier.onEvent({'INT_VEHICLE_COMMAND': 73});
      expect(h.state.notice?.action, isNull);
      h.dispose();
    });

    // Stock's DERATION_BASED_POPUP with a timer.
    group('countdown notices', () {
      test('9 counts down from 10 s and closes; the derate latch stays', () {
        fakeAsync((async) {
          final h = _Harness();
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 9});
          expect(h.state.notice?.body, 'Switching to Park in 10 s');
          async.elapse(const Duration(seconds: 1));
          expect(h.state.notice?.body, 'Switching to Park in 9 s');
          async.elapse(const Duration(seconds: 8));
          expect(h.state.notice?.body, 'Switching to Park in 1 s');
          async.elapse(const Duration(seconds: 1));
          expect(h.state.notice, isNull);
          expect(h.state.alerts.map((a) => a.kind), [AlertKind.deratingActive]);
          h.dispose();
        });
      });

      test('32 is 30 s, 154 is 5 s', () {
        fakeAsync((async) {
          final h = _Harness();
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 32});
          expect(h.state.notice?.body, 'Switching to Normal in 30 s');
          async.elapse(const Duration(seconds: 29));
          expect(h.state.notice?.body, 'Switching to Normal in 1 s');
          async.elapse(const Duration(seconds: 1));
          expect(h.state.notice, isNull);
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 154});
          expect(h.state.notice?.body, 'Cruise off in 5 s');
          async.elapse(const Duration(seconds: 5));
          expect(h.state.notice, isNull);
          h.dispose();
        });
      });

      test('a repeat while it is up does not restart it; 0 and a new command end it', () {
        fakeAsync((async) {
          final h = _Harness();
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 13});
          async.elapse(const Duration(seconds: 4));
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 13});
          expect(h.state.notice?.body, 'Switching to Normal in 6 s');
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 0});
          expect(h.state.notice, isNull);
          async.elapse(const Duration(seconds: 10));
          expect(h.state.notice, isNull);
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 13});
          async.elapse(const Duration(seconds: 2));
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 162});
          async.elapse(const Duration(seconds: 20));
          expect(h.state.notice?.command, 162, reason: 'a held notice is not closed by the old countdown');
          h.dispose();
        });
      });

      test('LOCK ends a countdown', () {
        fakeAsync((async) {
          final h = _Harness();
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 4});
          h.notifier.onEvent({'INT_VEHICLE_COMMAND': 9});
          h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
          expect(h.state.notice, isNull);
          async.elapse(const Duration(seconds: 3));
          expect(h.state.notice, isNull);
          h.dispose();
        });
      });
    });

    test('a brief stock popup is a toast, not a notice', () {
      final h = _Harness();
      final shown = <String>[];
      h.container.listen(toastProvider, (_, t) {
        if (t != null) shown.add(t.message);
      });
      h.notifier.onEvent({'INT_VEHICLE_COMMAND': 47});
      expect(h.state.notice, isNull);
      expect(h.state.deratingActive, isTrue);
      expect(shown, ["Reduced performance. Can't switch modes"]);
      h.dispose();
    });
  });

  // Stock `VehicleInfoManager.onHillHoldActive`.
  group('hill hold popups (INT_HILL_HOLD_STATUS)', () {
    test('2 toasts "Hill hold activated"; 4 counts down 3 s to the release', () {
      fakeAsync((async) {
        AnalyticsLogger.instance.resetForTest();
        final h = _Harness();
        final shown = <String>[];
        h.container.listen(toastProvider, (_, t) {
          if (t != null) shown.add(t.message);
        });
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 4});
        h.notifier.onEvent({'INT_HILL_HOLD_STATUS': 2});
        expect(h.state.hillHoldActive, isTrue);
        expect(shown, ['Hill hold activated']);
        h.notifier.onEvent({'INT_HILL_HOLD_STATUS': 2});
        expect(shown, hasLength(1), reason: 'only a change shows it');
        h.notifier.onEvent({'INT_HILL_HOLD_STATUS': 4});
        expect(h.state.notice?.command, hillHoldNoticeId);
        expect(h.state.notice?.title, 'Hill hold');
        expect(h.state.notice?.body, 'Releasing in 3 s');
        expect(h.state.notice?.priority, AlertPriority.warning);
        async.elapse(const Duration(seconds: 2));
        expect(h.state.notice?.body, 'Releasing in 1 s');
        async.elapse(const Duration(seconds: 1));
        expect(h.state.notice, isNull);
        final logged = AnalyticsLogger.instance.recent('hhmis', 'hill_hold').map((e) => (e['data']! as Map)['to']);
        expect(logged, [2, 4]);
        h.dispose();
      });
    });

    test('the status leaving 4 closes the countdown at once, and only that notice', () {
      fakeAsync((async) {
        final h = _Harness();
        h.notifier.onEvent({'INT_HILL_HOLD_STATUS': 4});
        h.notifier.onEvent({'INT_HILL_HOLD_STATUS': 3});
        expect(h.state.notice, isNull);
        h.notifier.onEvent({'INT_VEHICLE_COMMAND': 162});
        h.notifier.onEvent({'INT_HILL_HOLD_STATUS': 0});
        expect(h.state.notice?.command, 162);
        h.dispose();
      });
    });
  });

  group('trunk', () {
    void can(_Harness h, {required bool closed}) => h.notifier.applySensorUpdate(
          ambientBrightness: null,
          serviceIndicator: null,
          regenPowerLimitW: null,
          dischargePowerLimitW: null,
          rangeEcoCan: null,
          regenAvailability: null,
          towTheftState: null,
          busVoltage: null,
          packVoltage: null,
          packCurrent: null,
          trunkClosed: closed,
          vehicleLockStateBcm: null,
        );

    test('the raw CAN bit stands in until HHMIS reports, then only follows in LOCK / PASSCODE', () {
      final h = _Harness();
      h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3});
      can(h, closed: false);
      expect(h.state.trunkOpen, isTrue, reason: 'HHMIS has said nothing yet');
      h.notifier.onEvent({'INT_VEHICLE_TRUNK_STATUS': 3});
      expect(h.state.trunkOpen, isFalse);
      can(h, closed: false);
      expect(h.state.trunkOpen, isFalse, reason: 'PARK: HHMIS does not forward the latch here, CAN must not override');
      h.notifier.onEvent({'INT_VEHICLE_STATE': 4});
      can(h, closed: false);
      expect(h.state.trunkOpen, isFalse, reason: 'riding');
      h.notifier.onEvent({'INT_VEHICLE_STATE': 6});
      can(h, closed: false);
      expect(h.state.trunkOpen, isFalse, reason: 'charging');
      h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
      can(h, closed: false);
      expect(h.state.trunkOpen, isTrue, reason: 'LOCK is a state HHMIS forwards');
      h.notifier.onEvent({'INT_VEHICLE_STATE': 2});
      can(h, closed: true);
      expect(h.state.trunkOpen, isFalse, reason: 'PASSCODE too');
      h.dispose();
    });

    test('a boot opening or closing is announced in PARK and CHARGING only', () {
      final h = _Harness();
      final shown = <String>[];
      h.container.listen(toastProvider, (_, t) {
        if (t != null) shown.add(t.message);
      });
      h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3});
      h.notifier.onEvent({'INT_VEHICLE_TRUNK_STATUS': 3});
      expect(shown, isEmpty, reason: 'the first value is a report, not a change');
      h.notifier.onEvent({'INT_VEHICLE_TRUNK_STATUS': 2});
      h.notifier.onEvent({'INT_VEHICLE_TRUNK_STATUS': 2});
      h.notifier.onEvent({'INT_VEHICLE_TRUNK_STATUS': 3});
      expect(shown, ['Boot open', 'Boot closed']);
      h.notifier.onEvent({'INT_VEHICLE_STATE': 6});
      h.notifier.onEvent({'INT_VEHICLE_TRUNK_STATUS': 2});
      expect(shown.last, 'Boot open');
      h.notifier.onEvent({'INT_VEHICLE_STATE': 4, 'INT_VEHICLE_SPEED': 20});
      h.notifier.onEvent({'INT_VEHICLE_TRUNK_STATUS': 3});
      h.notifier.onEvent({'INT_VEHICLE_TRUNK_STATUS': 2});
      expect(shown, hasLength(3), reason: 'riding: stock shows nothing');
      expect(h.state.alerts.map((a) => a.kind), contains(AlertKind.trunkOpen), reason: 'ours only: the riding banner');
      h.dispose();
    });
  });

  group('charge limit', () {
    test('is kept but not sent on a home charger', () async {
      final h = _Harness();
      h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 6, 'INT_CHARGE_MODE': 3});
      h.notifier.setChargeLimit(80);
      await Future<void>.delayed(Duration.zero);
      expect(h.state.chargeLimit, 80);
      expect(h.calls.where((c) => c.contains('cmd: 18')), isEmpty);
      h.dispose();
    });

    test('a hypercharge start sends 0, then the limit 150 ms later, as stock does', () {
      fakeAsync((async) {
        AnalyticsLogger.instance.resetForTest();
        final h = _Harness();
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 6, 'INT_BATTERY_SOC': 40});
        h.notifier.setChargeLimit(80);
        h.notifier.onEvent({'INT_BOOST_HYPER_CHARGE_STATUS': 2});
        async.flushMicrotasks();
        expect(h.calls, ['sendIntCmd {cmd: INT_HC_SOC_LIMIT_SET, value: 0}']);
        async.elapse(AidlVehicleNotifier.chargeLimitDelay);
        expect(h.calls, ['sendIntCmd {cmd: INT_HC_SOC_LIMIT_SET, value: 0}', 'sendIntCmd {cmd: INT_HC_SOC_LIMIT_SET, value: 80}']);
        h.notifier.onEvent({'INT_BOOST_HYPER_CHARGE_STATUS': 2});
        async.elapse(const Duration(seconds: 1));
        expect(h.calls, hasLength(2), reason: 'only the start re-arms it');
        // A change while hypercharging goes straight out.
        h.notifier.setChargeLimit(90);
        async.flushMicrotasks();
        expect(h.calls.last, 'sendIntCmd {cmd: INT_HC_SOC_LIMIT_SET, value: 90}');
        final armed = AnalyticsLogger.instance.recent('hhmis', 'charge_limit_armed').single['data']! as Map;
        expect(armed['limit'], 80);
        expect(AnalyticsLogger.instance.recent('hhmis', 'hyper_charge_status'), hasLength(1));
        h.dispose();
      });
    });

    test('a limit the pack is already past is sent as 100; stop-charge (25) is never sent', () {
      fakeAsync((async) {
        final h = _Harness();
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 6, 'INT_BATTERY_SOC': 85});
        h.notifier.setChargeLimit(80);
        h.notifier.onEvent({'INT_CHARGE_MODE': 6});
        expect(h.state.isBoostCharger, isTrue);
        async.elapse(const Duration(seconds: 1));
        expect(h.calls, ['sendIntCmd {cmd: INT_HC_SOC_LIMIT_SET, value: 0}', 'sendIntCmd {cmd: INT_HC_SOC_LIMIT_SET, value: 100}']);
        h.notifier.onEvent({'INT_BATTERY_SOC': 100});
        async.elapse(const Duration(seconds: 1));
        expect(h.calls.where((c) => c.contains('cmd: 25')), isEmpty);
        h.dispose();
      });
    });
  });

  // Stock `updateVehicleESCLLockStatus`.
  group('handlebar prompt (ESCL unlock-failed -> unlocked)', () {
    test('2 -> 1 raises the prompt with Retry unlock; it closes after 10 s', () {
      fakeAsync((async) {
        AnalyticsLogger.instance.resetForTest();
        final h = _Harness();
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, 'INT_VEHICLE_ESCL_STATUS': 3});
        h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 2});
        expect(h.state.notice, isNull);
        h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 1});
        expect(h.state.notice?.command, handlebarNoticeId);
        expect(h.state.notice?.action, AlertAction.retryUnlock);
        expect(h.state.unlockFailedWarning, isFalse);
        expect(AnalyticsLogger.instance.recent('safety', 'handlebar_prompt'), hasLength(1));
        async.elapse(const Duration(seconds: 9));
        expect(h.state.notice?.body, 'Turn the handlebar, then retry', reason: 'timed, but no countdown in the text');
        async.elapse(const Duration(seconds: 1));
        expect(h.state.notice, isNull);
        h.dispose();
      });
    });

    test('the retry sends CTA_UNLOCK; a plain unlock raises nothing; riding off closes it', () {
      fakeAsync((async) {
        final h = _Harness();
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, 'INT_VEHICLE_ESCL_STATUS': 3});
        h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 1});
        expect(h.state.notice, isNull);
        h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 2});
        h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 1});
        h.calls.clear();
        h.notifier.retryUnlock();
        async.flushMicrotasks();
        expect(h.calls, ['sendIntCmd {cmd: INT_ESCL_LOCK_CMD, value: 1}']);
        h.notifier.onEvent({'INT_VEHICLE_STATE': 4});
        expect(h.state.notice, isNull);
        async.elapse(const Duration(seconds: 5));
        h.dispose();
      });
    });
  });

  group('HHMIS notification popups (TX 14)', () {
    test('unplug-charger-to-ride flashes its banner and is logged', () {
      AnalyticsLogger.instance.resetForTest();
      final h = _Harness();
      h.container.listen(toastProvider, (_, _) {});
      h.notifier.onEvent({'_notificationPopup': {'id': 6, 'type': 0, 'status': true}});
      expect(h.state.unplugToRideWarning, isTrue);
      expect(h.container.read(toastProvider), isNull);
      final logged = AnalyticsLogger.instance.recent('hhmis', 'notification_popup').single['data']! as Map;
      expect(logged['id'], 6);
      expect(logged['known'], isTrue);
      h.dispose();
    });

    test('a cleared state popup, the side-stand id and unknown ids show nothing', () {
      AnalyticsLogger.instance.resetForTest();
      final h = _Harness();
      h.container.listen(toastProvider, (_, _) {});
      h.notifier.onEvent({'_notificationPopup': {'id': 4, 'type': 1, 'status': false}});
      h.notifier.onEvent({'_notificationPopup': {'id': 1, 'type': 0, 'status': true}});
      h.notifier.onEvent({'_notificationPopup': {'id': 99, 'type': 0, 'status': true}});
      expect(h.container.read(toastProvider), isNull);
      expect(AnalyticsLogger.instance.recent('hhmis', 'notification_popup'), hasLength(3));
      h.dispose();
    });
  });

  // Indicator toggles were PARTY_MODE_*_ON/OFF commands that
  // kept the lamp steady, not blinking. They're no-ops now; the state
  // comes from the handlebar via BOOL_*_INDICATOR_STATUS.
  test('toggleLeftIndicator / toggleRightIndicator send nothing', () async {
    final h = _Harness();
    h.notifier.onEvent({'BOOL_LEFT_INDICATOR_STATUS': true});
    h.notifier.toggleRightIndicator();
    h.notifier.toggleLeftIndicator();
    await Future<void>.delayed(Duration.zero);
    expect(h.calls, isEmpty);
    h.dispose();
  });

  test('hazard is HAZARD_LIGHT_TOGGLE(50) with 1 then 0, not two turn signals', () {
    fakeAsync((async) {
      final h = _Harness();
      h.notifier.toggleHazard();
      async.flushMicrotasks();
      expect(h.calls, ['sendIntCmd {cmd: ${HhmisCmd.hazardToggle}, value: 1}']);
      expect(HhmisCmd.hazardToggle, 'HAZARD_LIGHT_TOGGLE');
      expect(h.notifier.hazardOn, isTrue, reason: 'held locally like stock HHMIC');
      // Real indicators flash on separate frames; one lamp lit is not hazard off.
      h.notifier.onEvent({'BOOL_LEFT_INDICATOR_STATUS': true, 'BOOL_RIGHT_INDICATOR_STATUS': false});
      expect(h.notifier.hazardOn, isTrue);
      async.elapse(VehicleNotifier.indicatorThrottle);
      h.notifier.toggleHazard();
      async.flushMicrotasks();
      expect(h.calls.last, 'sendIntCmd {cmd: HAZARD_LIGHT_TOGGLE, value: 0}');
      expect(h.state.hazard, isFalse);
      h.dispose();
    });
  });

  test('BOOL_HAZARD_LIGHT_PERSIST_TOGGLE_STAT is the hazard state', () {
    final h = _Harness();
    h.notifier.onEvent({'BOOL_HAZARD_LIGHT_PERSIST_TOGGLE_STAT': true});
    expect(h.state.hazard, isTrue);
    h.notifier.onEvent({'BOOL_HAZARD_LIGHT_PERSIST_TOGGLE_STAT': false});
    expect(h.state.hazard, isFalse);
    h.dispose();
  });

  test('locking with hazards on switches them off first, like stock', () async {
    final h = _Harness();
    h.notifier.onEvent({'BOOL_HAZARD_LIGHT_PERSIST_TOGGLE_STAT': true});
    h.notifier.lockScooter();
    await Future<void>.delayed(Duration.zero);
    expect(h.calls.take(2), ['sendIntCmd {cmd: HAZARD_LIGHT_TOGGLE, value: 0}', 'sendIntCmd {cmd: INT_ESCL_LOCK_CMD, value: 0}']);
    h.dispose();
  });

  test('autoPark sends INT_SIDE_STAND_STATUS = Lock_Now and only claims to be locking', () async {
    final h = _Harness();
    h.container.listen(toastProvider, (_, _) {});
    h.notifier.onEvent({'_connected': true});
    h.notifier.autoPark();
    await Future<void>.delayed(Duration.zero);
    expect(h.calls, ['sendIntCmd {cmd: ${HhmisCmd.sideStandStatus}, value: ${HhmisCmd.sideStandLockNow}}']);
    expect(h.container.read(toastProvider)?.message, 'Locking', reason: 'the vehicle state echo confirms the lock, not the send');
    expect(HhmisCmd.sideStandStatus, 'INT_SIDE_STAND_STATUS');
    expect(HhmisCmd.sideStandLockNow, 1);
    expect(HhmisCmd.sideStandRideNow, 0);
    h.dispose();
  });

  test('each regen mode sends one REGEN_SETTINGS_UPDATE(41) with its RegenState value', () async {
    final h = _Harness();
    for (final m in RegenMode.values) {
      h.notifier.sendRegenMode(m);
    }
    await Future<void>.delayed(Duration.zero);
    expect(HhmisCmd.regenSettingsUpdate, 'REGEN_SETTINGS_UPDATE');
    expect(h.calls, [
      'sendIntCmd {cmd: REGEN_SETTINGS_UPDATE, value: 0}',
      'sendIntCmd {cmd: REGEN_SETTINGS_UPDATE, value: 1}',
      'sendIntCmd {cmd: REGEN_SETTINGS_UPDATE, value: 2}',
      'sendIntCmd {cmd: REGEN_SETTINGS_UPDATE, value: 3}',
    ]);
    h.dispose();
  });

  // Indicators are no longer driven by the control panel;
  // hazard still throttles and can be verified standalone.
  test('hazard taps within 150 ms coalesce to one command', () {
    fakeAsync((async) {
      final h = _Harness();
      h.notifier.toggleHazard();
      h.notifier.toggleHazard();
      async.flushMicrotasks();
      expect(h.calls, ['sendIntCmd {cmd: HAZARD_LIGHT_TOGGLE, value: 1}']);
      async.elapse(VehicleNotifier.indicatorThrottle);
      h.notifier.toggleHazard();
      async.flushMicrotasks();
      expect(h.calls.length, 2, reason: 'a tap after the window sends again');
      h.dispose();
    });
  });

  test('hazard-on-lock is not a feature toggle HHMIS can carry', () {
    expect(HhmisCmd.features.values, isNot(contains(50)), reason: '50 is the live hazard switch');
    expect(RidingFeature.values.map((f) => f.name), isNot(contains('hazardOnLock')));
  });

  test('indicator state is not set locally; the vehicle echoes it', () {
    final h = _Harness();
    h.notifier.toggleLeftIndicator();
    expect(h.state.turnLeft, isFalse);
    h.notifier.onEvent({'BOOL_LEFT_INDICATOR_STATUS': true});
    expect(h.state.turnLeft, isTrue);
    h.dispose();
  });

  test('verifyPasscode resolves from the HHMIS callback', () async {
    final h = _Harness();
    final pending = h.notifier.verifyPasscode('000000') as Future<(bool, int)>;
    await Future<void>.delayed(Duration.zero);
    expect(h.calls.last, 'verifyPasscode {code: 000000, verifyOnly: false}');
    h.notifier.onEvent({'_passcode': {'success': true, 'remaining': 5}, '_unlocked': true, 'INT_VEHICLE_STATE': 0});
    expect(await pending, (true, 5));
    expect(h.state.locked, isFalse, reason: 'the unlock event wins over a stale LOCK state in the same batch');
    h.dispose();
  });

  test('a wrong passcode carries the remaining attempts', () async {
    final h = _Harness();
    final pending = h.notifier.verifyPasscode('111111') as Future<(bool, int)>;
    h.notifier.onEvent({'_passcode': {'success': false, 'remaining': 3}});
    expect(await pending, (false, 3));
    expect(h.notifier.passcodeAttemptsRemaining, 3);
    h.dispose();
  });

  test('verifyPasscode reports no answer, not a wrong PIN, when HHMIS stays silent', () {
    fakeAsync((async) {
      final h = _Harness();
      (bool, int)? result;
      (h.notifier.verifyPasscode('000000') as Future<(bool, int)>).then((r) => result = r);
      async.flushMicrotasks();
      expect(result, isNull);
      async.elapse(AidlVehicleNotifier.passcodeTimeout + const Duration(milliseconds: 1));
      expect(result, (false, VehicleNotifier.passcodeNoAnswer));
      h.dispose();
    });
  });

  test('verifyPasscode reports no answer at once when the bridge cannot send', () async {
    final h = _Harness(sendOk: false);
    h.container.listen(toastProvider, (_, _) {});
    expect(await (h.notifier.verifyPasscode('000000') as Future<(bool, int)>), (false, VehicleNotifier.passcodeNoAnswer));
    h.dispose();
  });

  test('checkPasscode asks HHMIS to verify only', () async {
    final h = _Harness();
    final pending = h.notifier.checkPasscode('123456') as Future<bool?>;
    await Future<void>.delayed(Duration.zero);
    expect(h.calls.last, 'verifyPasscode {code: 123456, verifyOnly: true}');
    h.notifier.onEvent({'_passcode': {'success': true, 'remaining': 5}});
    expect(await pending, isTrue);
    h.dispose();
  });

  test('switch cube music keys: 0 play/pause, 1 next, 2 previous', () async {
    final h = _Harness();
    h.notifier.onEvent({'INT_BT_MUSIC_COMMAND': 1});
    h.notifier.onEvent({'INT_BT_MUSIC_COMMAND': 2});
    h.notifier.onEvent({'INT_BT_MUSIC_COMMAND': 0});
    await Future<void>.delayed(Duration.zero);
    expect(h.calls, ['mediaKey next', 'mediaKey prev', 'mediaKey playPause'],
        reason: 'no session to read: the phone decides which way the toggle goes');
    expect(h.state.mediaPlaying, isFalse, reason: 'no guess at the playing state');
    h.notifier.onEvent({'INT_BT_MUSIC_COMMAND': 7});
    await Future<void>.delayed(Duration.zero);
    expect(h.calls.length, 3, reason: 'unknown keys do nothing');
    h.dispose();
  });

  test('a verify-only passcode check reports -1 attempts, which means untouched', () async {
    final h = _Harness();
    h.notifier.onEvent({'_passcode': {'success': false, 'remaining': 3}});
    expect(h.notifier.passcodeAttemptsRemaining, 3);
    h.notifier.onEvent({'_passcode': {'success': false, 'remaining': -1}});
    expect(h.notifier.passcodeAttemptsRemaining, VehicleNotifier.maxPasscodeAttempts);
    h.notifier.onEvent({'INT_PROFILE_REMAINING_ATTEMPTS': 2});
    expect(h.notifier.passcodeAttemptsRemaining, 2);
    h.notifier.onEvent({'INT_PROFILE_REMAINING_ATTEMPTS': -1});
    expect(h.notifier.passcodeAttemptsRemaining, VehicleNotifier.maxPasscodeAttempts);
    h.dispose();
  });

  test('the mode ladder cannot change the mode locally on hardware', () async {
    final h = _Harness();
    h.container.listen(toastProvider, (_, _) {});
    h.notifier.onEvent({'STR_VEHICLE_DRIVE_MODE': 'ECO'});
    h.notifier.selectDriveMode(DriveMode.sport);
    h.notifier.setDriveMode(DriveMode.hyper);
    await Future<void>.delayed(Duration.zero);
    expect(h.state.driveMode, DriveMode.eco);
    expect(h.calls, isEmpty);
    expect(h.container.read(toastProvider)?.message, 'Mode is on the handlebar switch');
    h.dispose();
  });

  test('a mode tap while moving does not even toast', () async {
    final h = _Harness();
    h.container.listen(toastProvider, (_, _) {});
    h.notifier.onEvent({'INT_VEHICLE_STATE': 4, 'INT_VEHICLE_SPEED': 18});
    h.notifier.selectDriveMode(DriveMode.sport);
    await Future<void>.delayed(Duration.zero);
    expect(h.container.read(toastProvider), isNull);
    h.dispose();
  });

  test('the take-me-home countdown is left to the vehicle', () {
    final h = _Harness();
    h.notifier.onEvent({'BOOL_TAKE_ME_HOME_TOGGLE_STAT': true});
    h.notifier.tickTakeMeHome();
    expect(h.state.takeMeHomeLights, isFalse);
    h.dispose();
  });

  test('ambient-driven features stay inert until the sensor reports', () async {
    final h = _Harness();
    expect(h.state.ambientKnown, isFalse);
    h.container.read(themeProvider.notifier).setTheme(DashTheme.ember);
    h.container.read(autoDarkModeProvider.notifier).setMode(AutoThemeMode.ambientSensor);
    h.container.read(autoThemeProvider.notifier).evaluateAmbient(h.state.ambientBrightness);
    expect(h.container.read(themeProvider), DashTheme.ember, reason: 'no reading, no switch');
    h.container.read(brightnessProvider.notifier).set(80);
    h.container.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoBrightness, true);
    expect(h.container.read(brightnessProvider), 80, reason: 'no reading, brightness untouched');
    h.dispose();
  });

  test('applySensorUpdate stores CAN sensor values and marks ambient known', () {
    final h = _Harness();
    h.notifier.onEvent({'FLOAT_VEHICLE_VOLTAGE': 52.0, 'FLOAT_VEHICLE_CURRENT': -8.0});
    h.notifier.applySensorUpdate(
      ambientBrightness: 72,
      serviceIndicator: true,
      regenPowerLimitW: 1200,
      dischargePowerLimitW: 7000,
      rangeEcoCan: 46,
      regenAvailability: 0,
      towTheftState: 1,
      busVoltage: null,
      packVoltage: null,
      packCurrent: null,
      trunkClosed: true,
      vehicleLockStateBcm: 3,
    );
    final s = h.state;
    expect(s.ambientBrightness, 72);
    expect(s.ambientKnown, isTrue);
    expect(s.serviceIndicator, isTrue);
    expect(s.regenPowerLimitW, 1200);
    expect(s.dischargePowerLimitW, 7000);
    expect(s.rangeEcoCan, 46);
    expect(s.regenAvailability, 0);
    expect(s.regenAvailabilityKnown, isTrue);
    expect(s.towTheftState, 1);
    expect(s.tamperDetected, isTrue);
    expect(s.busVoltage, 52.0, reason: 'a missing CAN reading keeps the HHMIS value');
    expect(s.packCurrent, -8.0);
    expect(s.trunkStateKnown, isTrue);
    expect(s.trunkOpen, isFalse, reason: '0x353 bit 2 = 1 is HVDP isTrunkLock(true) = closed');
    expect(s.lockState, 4, reason: 'no HHMIS vehicle state yet, so BCM Locked (3) may assert locked');
    h.notifier.applySensorUpdate(
      ambientBrightness: null,
      serviceIndicator: null,
      regenPowerLimitW: null,
      dischargePowerLimitW: null,
      rangeEcoCan: null,
      regenAvailability: null,
      towTheftState: null,
      busVoltage: 51.5,
      packVoltage: null,
      packCurrent: -9.0,
      trunkClosed: null,
      vehicleLockStateBcm: null,
    );
    expect(h.state.ambientBrightness, 72, reason: 'unknown ambient leaves the last reading');
    expect(h.state.rangeEcoCan, 46);
    expect(h.state.tamperDetected, isTrue, reason: 'an unseen 0x683 does not clear the alert');
    expect(h.state.serviceIndicator, isTrue);
    expect(h.state.regenPowerLimitW, 1200);
    expect(h.state.busVoltage, 51.5);
    expect(h.state.trunkStateKnown, isTrue, reason: 'a null trunkClosed keeps the last reading');
    expect(h.state.trunkOpen, isFalse);
    h.notifier.applySensorUpdate(
      ambientBrightness: null,
      serviceIndicator: null,
      regenPowerLimitW: null,
      dischargePowerLimitW: null,
      rangeEcoCan: null,
      regenAvailability: null,
      towTheftState: 2,
      busVoltage: null,
      packVoltage: null,
      packCurrent: null,
      trunkClosed: false,
      vehicleLockStateBcm: 1,
    );
    expect(h.state.tamperDetected, isTrue, reason: 'INACTIVE (2) does not clear it; leaving ALARM does');
    expect(h.state.towTheftState, 2);
    expect(h.state.trunkOpen, isTrue, reason: '0x353 bit 2 = 0 is isTrunkLock(false) = open');
    expect(h.state.lockState, 4, reason: 'CAN never unlocks: 0x144 is the last lock operation, not the lock');
    expect(h.state.unlockFailedWarning, isFalse);
    expect(h.state.lockFailedWarning, isFalse);
    h.dispose();
  });

  test('an HHMIS tamper alert survives publishes until 0x683 is seen', () {
    final h = _Harness();
    h.notifier.onEvent({'INT_TOW_THEFT_DETECTION_ALERT': 1});
    h.notifier.applySensorUpdate(
      ambientBrightness: 40, serviceIndicator: null, regenPowerLimitW: null, dischargePowerLimitW: null,
      rangeEcoCan: null, regenAvailability: null, towTheftState: null, busVoltage: null, packVoltage: null, packCurrent: null, trunkClosed: null, vehicleLockStateBcm: null,
    );
    expect(h.state.tamperDetected, isTrue);
    expect(h.state.towTheftState, 1);
    h.dispose();
  });

  test('CAN owns regen availability once it has reported', () {
    final h = _Harness();
    h.notifier.onEvent({'BOOL_VEHICLE_REGEN_AVAIL_STATUS': false});
    expect(h.state.regenAvailability, 0);
    h.notifier.applySensorUpdate(
      ambientBrightness: null, serviceIndicator: null, regenPowerLimitW: null, dischargePowerLimitW: null,
      rangeEcoCan: null, regenAvailability: 1, towTheftState: null, busVoltage: null, packVoltage: null, packCurrent: null, trunkClosed: null, vehicleLockStateBcm: null,
    );
    expect(h.state.regenAvailability, 1);
    h.notifier.onEvent({'BOOL_VEHICLE_REGEN_AVAIL_STATUS': false, 'INT_VEHICLE_SPEED': 3});
    expect(h.state.regenAvailability, 1, reason: 'the HHMIS bool no longer overwrites the CAN nibble');
    expect(h.state.speed, 3);
    h.dispose();
  });

  test('smart headlight never writes lowBeam on the device; HHMIS owns the lamp', () {
    final h = _Harness();
    h.container.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.smartHeadlight, true);
    h.container.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoHeadlight, false);
    h.notifier.onEvent({'INT_VEHICLE_STATE': 4, 'INT_VEHICLE_SPEED': 20, 'BOOL_LOW_BEAM_STATUS': false, 'BOOL_HIGH_BEAM_STATUS': false});
    expect(h.state.vehicleState, VehicleState.riding);
    h.notifier.applySensorUpdate(
      ambientBrightness: 5, serviceIndicator: null, regenPowerLimitW: null, dischargePowerLimitW: null,
      rangeEcoCan: null, regenAvailability: null, towTheftState: null, busVoltage: null, packVoltage: null, packCurrent: null, trunkClosed: null, vehicleLockStateBcm: null,
    );
    expect(h.state.lowBeam, isFalse, reason: 'dark ambient must not flip the lamp locally');
    expect(h.notifier.managesSmartHeadlightLocally, isFalse);
    h.notifier.onEvent({'BOOL_LOW_BEAM_STATUS': true});
    expect(h.state.lowBeam, isTrue, reason: 'the vehicle echo is the only writer');
    h.dispose();
  });

  test('CAN ambient drives auto brightness on the device', () {
    // On a scooter whose sensor has shown itself to work.
    AidlVehicleNotifier.debugAmbientHealth = AmbientHealth.proven;
    addTearDown(() => AidlVehicleNotifier.debugAmbientHealth = null);
    final h = _Harness();
    h.container.read(autoBrightnessProvider);
    h.container.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoBrightness, true);
    h.container.read(brightnessProvider.notifier).set(80);
    h.notifier.applySensorUpdate(
      ambientBrightness: 0, serviceIndicator: null, regenPowerLimitW: null, dischargePowerLimitW: null,
      rangeEcoCan: null, regenAvailability: null, towTheftState: null, busVoltage: null, packVoltage: null, packCurrent: null, trunkClosed: null, vehicleLockStateBcm: null,
    );
    expect(h.container.read(brightnessProvider), 30);
    h.dispose();
  });

  test('the mock is still the default outside Android', () {
    expect(useAidlVehicle, isFalse);
    final c = ProviderContainer();
    expect(c.read(vehicleProvider.notifier), isNot(isA<AidlVehicleNotifier>()));
    c.dispose();
  });

  group('connections, stale data, boot handshake and lock echo', () {
    setUp(AnalyticsLogger.instance.resetForTest);
    tearDown(AnalyticsLogger.instance.resetForTest);

    List<Map<String, Object?>> events(String cat, String evt) => AnalyticsLogger.instance.recent(cat, evt);
    Map<Object?, Object?> data(Map<String, Object?> e) => e['data']! as Map<Object?, Object?>;

    /// Runs [body] on the fake clock, with the analytics clock following it.
    void onFakeClock(void Function(FakeAsync async, _Harness h) body) {
      fakeAsync((async) {
        AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
        final h = _Harness();
        h.container.listen(toastProvider, (_, _) {});
        body(async, h);
        h.dispose();
      });
    }

    int reattaches(_Harness h) => h.calls.where((c) => c.startsWith('reattachCallback')).length;

    test('the Connections snapshot reflects what HHMIS and the commands did', () {
      onFakeClock((async, h) {
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3});
        async.elapse(const Duration(seconds: 2));
        h.notifier.resetTrip();
        async.flushMicrotasks();
        h.notifier.onEvent({'INT_VEHICLE_COMMAND': 59});
        final health = h.notifier.health;
        expect(health.connectedForMicros, greaterThanOrEqualTo(2000000));
        expect(health.lastCommand, 'resetTrip');
        expect(health.lastCommandOk, isTrue);
        expect(health.lastVehicleCommand, 59);
        expect(health.projectLoadedSent, isTrue);
        h.notifier.reattachNow();
        async.flushMicrotasks();
        expect(h.notifier.health.reattaches, 1);
        expect(reattaches(h), 1);
      });
    });

    // The model's 100 % / 180 km / 30° / 28° defaults
    // are not readings.
    group('known flags', () {
      test('nothing is known at bind; each value becomes known when HHMIS sends it', () {
        onFakeClock((async, h) {
          expect([h.state.socKnown, h.state.rangeKnown, h.state.motorTempKnown, h.state.batteryTempKnown], everyElement(isFalse));
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 4});
          expect(h.state.hhmisKnown, isTrue);
          expect([h.state.socKnown, h.state.rangeKnown, h.state.motorTempKnown, h.state.batteryTempKnown], everyElement(isFalse),
              reason: 'bound, but the first batch carried none of them');
          h.notifier.onEvent({'INT_BATTERY_SOC': 97});
          expect(h.state.socKnown, isTrue);
          expect(h.state.rangeKnown, isFalse);
          h.notifier.onEvent({'INT_VEHICLE_RANGE': 132, 'FLOAT_BATTERY_EFF_TEMP': 34.0});
          expect(h.state.rangeKnown, isTrue);
          expect(h.state.batteryTempKnown, isTrue);
          expect(h.state.motorTempKnown, isFalse, reason: 'motor temperature is sparse');
          h.notifier.onEvent({'FLOAT_MOTOR_TEMPERATURE': 41.5});
          expect(h.state.motorTempKnown, isTrue);
        });
      });

      test('a wrong-typed value does not count as an arrival', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_BATTERY_SOC': 'n/a', 'INT_VEHICLE_RANGE': null});
          expect(h.state.socSeen, isFalse);
          expect(h.state.rangeSeen, isFalse);
        });
      });

      test('stale data and a lost bind hide the values; fresh data brings them back', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 4, 'INT_BATTERY_SOC': 80, 'INT_VEHICLE_RANGE': 100});
          expect(h.state.socKnown && h.state.rangeKnown, isTrue);
          async.elapse(AidlVehicleNotifier.staleAfter + const Duration(seconds: 1));
          expect(h.state.hhmisStale, isTrue);
          expect(h.state.socKnown || h.state.rangeKnown, isFalse);
          h.notifier.onEvent({'INT_VEHICLE_SPEED': 0});
          expect(h.state.socKnown && h.state.rangeKnown, isTrue);
          h.notifier.onEvent({'_connected': false});
          expect(h.state.socKnown || h.state.rangeKnown, isFalse);
        });
      });
    });

    group('stale HHMIS data', () {
      test('3 s of silence in front marks the data stale; the next batch clears it', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 4, 'INT_VEHICLE_SPEED': 42});
          async.elapse(AidlVehicleNotifier.staleAfter - const Duration(milliseconds: 600));
          expect(h.state.hhmisStale, isFalse);
          async.elapse(const Duration(seconds: 1));
          expect(h.state.hhmisStale, isTrue);
          expect(h.state.hhmisConnected, isTrue, reason: 'still bound; only the data is frozen');
          h.notifier.onEvent({'INT_VEHICLE_SPEED': 40});
          expect(h.state.hhmisStale, isFalse);
          expect(events('hhmis', 'stale').map((e) => data(e)['on']), [true, false]);
        });
      });

      test('nothing is flagged while paused (the stock dashboard may hold the slot)', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3});
          h.notifier.onLifecyclePause();
          async.elapse(const Duration(seconds: 30));
          expect(h.state.hhmisStale, isFalse);
        });
      });

      // Overnight, every wake flashed "Reconnecting…" for 0.5 s
      // because the gap was measured from the data before the screen went off.
      test('a wake after a long pause gets the full grace period before stale', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 0});
          h.notifier.onLifecyclePause();
          async.elapse(const Duration(minutes: 67));
          h.notifier.onLifecycleResume();
          async.elapse(AidlVehicleNotifier.staleAfter - const Duration(milliseconds: 600));
          expect(h.state.hhmisStale, isFalse);
          expect([for (final e in events('hhmis', 'stale')) (e['data'] as Map)['in_front']], [false],
              reason: 'only the unseen flag raised behind the pause');
          async.elapse(const Duration(seconds: 1));
          expect(h.state.hhmisStale, isTrue, reason: 'still silent 3 s after the wake');
        });
      });

      test('a reattach echo is not live data and does not clear it', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3});
          async.elapse(AidlVehicleNotifier.stalenessThreshold + const Duration(seconds: 1));
          expect(h.state.hhmisStale, isTrue);
          h.notifier.onEvent({'INT_VEHICLE_STATE': 0, '_volume': 5});
          expect(h.state.hhmisStale, isTrue);
        });
      });
    });

    group('boot handshake and touch heartbeat (stock HHMIC parity)', () {
      test('PROJECT_LOADED waits out LOCK/PASSCODE, then goes out once', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 0});
          h.notifier.onEvent({'INT_VEHICLE_STATE': 2});
          async.flushMicrotasks();
          expect(h.projectLoaded, 0, reason: 'HHMIS ignores it while its saved state is PASSCODE');
          h.notifier.onEvent({'INT_VEHICLE_STATE': 6});
          h.notifier.onEvent({'INT_VEHICLE_SPEED': 0});
          async.flushMicrotasks();
          expect(h.projectLoaded, 1);
          expect(data(events('hhmis', 'project_loaded_sent').single)['state'], 6);
        });
      });

      test('a restart mid-ride waits until the scooter is stationary', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 4, 'INT_VEHICLE_SPEED': 32});
          async.flushMicrotasks();
          expect(h.projectLoaded, 0);
          h.notifier.onEvent({'INT_VEHICLE_STATE': 3, 'INT_VEHICLE_SPEED': 0});
          async.flushMicrotasks();
          expect(h.projectLoaded, 1);
        });
      });

      test("HHMIS's PARK-then-saved-state reply never flashes the charging screen to parked", () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 6});
          expect(h.state.vehicleState, VehicleState.charging);
          async.elapse(const Duration(seconds: 3));
          h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
          expect(h.state.vehicleState, VehicleState.charging, reason: 'the PARK is held');
          async.elapse(const Duration(milliseconds: 20));
          h.notifier.onEvent({'INT_VEHICLE_STATE': 6});
          async.elapse(AidlVehicleNotifier.projectLoadedEchoHold);
          expect(h.state.vehicleState, VehicleState.charging);
          expect(data(events('hhmis', 'project_loaded_echo').single)['then'], 6);
        });
      });

      test('a real PARK in the window still lands after the hold', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 6});
          async.elapse(const Duration(seconds: 3));
          h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
          async.elapse(AidlVehicleNotifier.projectLoadedEchoHold + const Duration(milliseconds: 1));
          expect(h.state.vehicleState, VehicleState.parked);
        });
      });

      // After the scooter rebooted, HHMIS's first
      // state values flashed PASSCODE -> PARK -> PASSCODE in 300 ms. We held
      // the dashboard behind the pin screen for that window, confusing the
      // rider typing digits. The guard drops a PARK that comes right after
      // the first PASSCODE and is revoked within the hold.
      test('a PARK right after the first PASSCODE is held and dropped when PASSCODE returns', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 2});
          async.elapse(const Duration(milliseconds: 47));
          h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
          async.elapse(const Duration(milliseconds: 200));
          expect(h.state.vehicleState, VehicleState.parked, reason: 'still held');
          expect(h.state.locked, isTrue, reason: 'lock screen stays up during the hold');
          h.notifier.onEvent({'INT_VEHICLE_STATE': 2});
          async.elapse(AidlVehicleNotifier.coldBindParkHold + const Duration(seconds: 1));
          expect(h.state.locked, isTrue, reason: 'the transient PARK was dropped');
          expect(events('hhmis', 'cold_bind_park_dropped'), hasLength(1));
        });
      });

      // A real PARK (after a correct passcode) must still go through.
      test('a PARK that holds is applied after the hold', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 2});
          async.elapse(const Duration(milliseconds: 47));
          h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
          async.elapse(AidlVehicleNotifier.coldBindParkHold + const Duration(milliseconds: 1));
          expect(h.state.vehicleState, VehicleState.parked);
          expect(h.state.locked, isFalse);
        });
      });

      // Outside the cold-bind window (e.g. normal unlock a minute later),
      // PASSCODE -> PARK is instant and must not be held.
      test('PASSCODE -> PARK outside the cold-bind window is applied at once', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 2});
          async.elapse(AidlVehicleNotifier.coldBindParkWindow + const Duration(seconds: 1));
          h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
          expect(h.state.vehicleState, VehicleState.parked);
          expect(h.state.locked, isFalse);
          expect(events('hhmis', 'cold_bind_park_dropped'), isEmpty);
        });
      });

      test('BOOL_TOUCH_STATUS: true after a touch, false after, nothing while paused', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3});
          h.notifier.markTouched();
          async.elapse(AidlVehicleNotifier.touchStatusEvery);
          async.elapse(AidlVehicleNotifier.touchStatusEvery);
          // At the touch itself (the vehicle locks about a
          // minute after the last one it heard of, and waiting for the tick
          // cost up to a second), again at the tick, then false.
          expect(h.touches, [true, true, false]);
          h.notifier.onLifecyclePause();
          h.notifier.markTouched();
          async.elapse(AidlVehicleNotifier.touchStatusEvery * 3);
          expect(h.touches, hasLength(3), reason: 'nothing while paused, a touch included');
          expect(events('hhmis', 'touch_status').map((e) => data(e)['on']), [true, false]);
        });
      });
    });

    group('callback-slot watchdog', () {
      test('an unanswered passcode with silent HHMIS takes the slot back at once', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 2});
          async.elapse(const Duration(seconds: 1));
          h.notifier.verifyPasscode('123456');
          async.elapse(AidlVehicleNotifier.passcodeTimeout + const Duration(milliseconds: 1));
          expect(reattaches(h), 1, reason: '6 s of silence is far past 2 s; the 12 s window is not waited out');
          expect(events('safety', 'passcode_no_answer'), hasLength(1));
          expect(h.container.read(toastProvider)?.message, "Scooter didn't answer, try again");
        });
      });

      test('an unanswered passcode while HHMIS still streams does not reattach', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 2});
          h.notifier.verifyPasscode('123456');
          for (var i = 0; i < 10; i++) {
            async.elapse(const Duration(milliseconds: 510));
            h.notifier.onEvent({'INT_VEHICLE_SPEED': 0});
          }
          expect(reattaches(h), 0);
          expect(events('safety', 'passcode_no_answer'), hasLength(1));
        });
      });

      test('resume with fresh data does not reattach', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_SPEED': 0});
          h.notifier.onLifecyclePause();
          async.elapse(const Duration(seconds: 5));
          h.notifier.onLifecycleResume();
          async.flushMicrotasks();
          expect(reattaches(h), 0);
          expect(events('hhmis', 'lifecycle_resume'), hasLength(1));
        });
      });

      test('resume with stale data reattaches at once', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_SPEED': 0});
          h.notifier.onLifecyclePause();
          async.elapse(const Duration(seconds: 74));
          h.notifier.onLifecycleResume();
          async.flushMicrotasks();
          expect(reattaches(h), 1);
          expect(data(events('hhmis', 'reattach_scheduled').single)['resume_triggered'], isTrue);
        });
      });

      test('13 s of silence while resumed reattaches once, then waits for the backoff', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_SPEED': 0});
          async.elapse(const Duration(seconds: 13));
          expect(reattaches(h), 1);
          expect(h.calls.last, 'reattachCallback null', reason: 'a single platform call, nothing else');
          async.elapse(const Duration(seconds: 6));
          expect(reattaches(h), 1, reason: 'the 3 s ticks do not pile on');
          expect(events('hhmis', 'reattach_scheduled'), hasLength(1));
        });
      });

      test('the backoff ladder gives up after its last rung until real data arrives', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_SPEED': 0});
          async.elapse(const Duration(seconds: 12));
          expect(reattaches(h), 1);
          async.elapse(const Duration(seconds: 12));
          expect(reattaches(h), 2, reason: '10 s after the first');
          async.elapse(const Duration(seconds: 30));
          expect(reattaches(h), 3, reason: '30 s after the second');
          async.elapse(const Duration(minutes: 5));
          expect(reattaches(h), 3, reason: 'a legitimately quiet HHMIS is not poked forever');
          h.notifier.onEvent({'INT_VEHICLE_SPEED': 0});
          expect(data(events('hhmis', 'reattach_recovered').single)['attempts'], 3);
          async.elapse(const Duration(seconds: 13));
          expect(reattaches(h), 4, reason: 'real data re-arms the watchdog');
        });
      });

      test('data arriving resets the backoff', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_SPEED': 0});
          async.elapse(const Duration(seconds: 13));
          expect(reattaches(h), 1);
          h.notifier.onEvent({'INT_VEHICLE_SPEED': 0});
          expect(events('hhmis', 'reattach_recovered'), hasLength(1));
          async.elapse(const Duration(seconds: 15));
          expect(reattaches(h), 2, reason: 'a fresh 12 s silence, not a 10 s backoff');
          expect(data(events('hhmis', 'reattach_scheduled').last)['attempt'], 0, reason: 'back at the first rung');
        });
      });

      test('paused, nothing reattaches however long the silence', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_SPEED': 0});
          h.notifier.onLifecyclePause();
          async.elapse(const Duration(minutes: 5));
          expect(reattaches(h), 0);
          expect(events('hhmis', 'reattach_scheduled'), isEmpty);
        });
      });

      // HHMIS answers addCallback with a forced LOCK (setStarTup) and the
      // system volume (updateInitialSystemVolume).
      const echo = {'INT_VEHICLE_STATE': 0, '_volume': 6};

      test('the reattach echo is neither liveness nor the vehicle state, so the ladder still caps', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, 'INT_VEHICLE_SPEED': 0});
          expect(h.state.locked, isFalse);
          for (var i = 0; i < 3; i++) {
            final before = reattaches(h);
            while (reattaches(h) == before) {
              async.elapse(const Duration(seconds: 1));
            }
            async.elapse(const Duration(milliseconds: 20));
            h.notifier.onEvent(echo);
            expect(h.state.locked, isFalse, reason: 'the forced LOCK is not applied (attempt $i)');
          }
          async.elapse(const Duration(minutes: 5));
          expect(reattaches(h), 3);
          expect(events('hhmis', 'reattach_recovered'), isEmpty);
          expect(events('hhmis', 'reattach_echo'), hasLength(3));
          expect(h.state.volume, 40, reason: 'the volume is still real');
        });
      });

      test('outside the echo window, or with real keys alongside, the batch is live data', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, 'INT_VEHICLE_SPEED': 0});
          async.elapse(const Duration(seconds: 12));
          expect(reattaches(h), 1);
          h.notifier.onEvent({...echo, 'INT_VEHICLE_SPEED': 0});
          expect(events('hhmis', 'reattach_recovered'), hasLength(1));
          expect(h.state.locked, isTrue, reason: 'with real data alongside, LOCK is taken as-is');
          async.elapse(const Duration(seconds: 2));
          h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
          expect(events('hhmis', 'reattach_echo'), isEmpty);
        });
      });

      test('HHMIS callbacks on underscore keys count as liveness; bridge keys do not', () {
        for (final key in ['_rangeByMode', '_passcode', '_unlocked', '_volume']) {
          onFakeClock((async, h) {
            h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_SPEED': 0});
            async.elapse(const Duration(seconds: 10));
            h.notifier.onEvent({key: key == '_passcode' ? {'success': false, 'remaining': 4} : key == '_rangeByMode' ? [1, 2, 3, 4] : 1});
            async.elapse(const Duration(seconds: 10));
            expect(reattaches(h), 0, reason: key);
          });
        }
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_SPEED': 0});
          async.elapse(const Duration(seconds: 10));
          h.notifier.onEvent({'_wifi': true, '_bt': false});
          async.elapse(const Duration(seconds: 3));
          expect(reattaches(h), 1);
        });
      });
    });

    group('lock waits for the ESCL echo', () {
      test('lockScooter is pending until ESCL says locked', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true});
          h.notifier.lockScooter();
          async.flushMicrotasks();
          expect(h.state.pendingLock?.source, LockSource.userLock);
          expect(data(events('safety', 'lock_sent').single), {'source': 'userLock', 'cmd': 'INT_ESCL_LOCK_CMD', 'value': 0});
          async.elapse(const Duration(milliseconds: 800));
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 3});
          expect(h.state.pendingLock, isNull);
          expect(data(events('safety', 'lock_confirmed').single), {'source': 'userLock', 'took_ms': 800, 'after_failure': false});
          async.elapse(AidlVehicleNotifier.lockEchoTimeout);
          expect(events('safety', 'lock_timeout'), isEmpty);
          expect(h.state.lockFailedAtMicros, isNull);
        });
      });

      test('no echo within the window marks the lock failed, then the failure clears', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true});
          h.notifier.autoPark();
          async.flushMicrotasks();
          expect(h.state.pendingLock?.source, LockSource.autoPark);
          async.elapse(AidlVehicleNotifier.lockEchoTimeout);
          expect(h.state.pendingLock, isNotNull, reason: 'the UI tells locking from failed by lockFailedAtMicros');
          expect(h.state.lockFailedAtMicros, isNotNull);
          expect(data(events('safety', 'lock_timeout').single),
              {'source': 'autoPark', 'waited_ms': AidlVehicleNotifier.lockEchoTimeout.inMilliseconds});
          expect(h.container.read(toastProvider)?.message, 'Scooter did not confirm the lock');
          async.elapse(AidlVehicleNotifier.lockFailedHold);
          expect(h.state.lockFailedAtMicros, isNull);
          expect(h.state.pendingLock, isNull, reason: 'the attempt is over; a spinner must not outlive it');
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4});
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 3});
          expect(events('safety', 'lock_rejected'), isEmpty, reason: 'a later ESCL report is not this attempt');
          expect(events('safety', 'lock_confirmed'), isEmpty);
        });
      });

      test('a late echo still clears the pending lock and takes back the warning', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true});
          h.notifier.lockScooter();
          async.elapse(AidlVehicleNotifier.lockEchoTimeout + const Duration(seconds: 1));
          expect(h.state.lockFailedAtMicros, isNotNull);
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 3});
          expect(h.state.pendingLock, isNull);
          expect(h.state.lockFailedAtMicros, isNull);
          expect(data(events('safety', 'lock_confirmed').single)['after_failure'], isTrue);
          expect(h.container.read(toastProvider)?.message, 'Scooter locked');
        });
      });

      test('ESCL "lock failed" (4) fails the lock at once', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true});
          h.notifier.lockScooter();
          async.elapse(const Duration(milliseconds: 600));
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4});
          expect(h.state.lockFailedAtMicros, isNotNull);
          expect(data(events('safety', 'lock_rejected').single), {'source': 'userLock', 'took_ms': 600});
          expect(h.container.read(toastProvider)?.message, 'Steering lock failed');
          async.elapse(AidlVehicleNotifier.lockEchoTimeout);
          expect(events('safety', 'lock_timeout'), isEmpty, reason: 'one failure, not two');
        });
      });

      test('a lock the bridge could not send is not left pending', () {
        fakeAsync((async) {
          final h = _Harness(sendOk: false);
          h.notifier.onEvent({'_connected': true});
          h.notifier.lockScooter();
          async.flushMicrotasks();
          expect(h.state.pendingLock, isNull);
          async.elapse(AidlVehicleNotifier.lockEchoTimeout);
          expect(events('safety', 'lock_timeout'), isEmpty);
          h.dispose();
        });
      });

      // 2 s was too short: a ride log showed
      // the confirm arriving ~12 s after the send. The timeout is now ~15 s
      // so a real lock is no longer reported as "did not confirm".
      test('lockEchoTimeout waits ~15 s, not the old 2 s', () {
        expect(AidlVehicleNotifier.lockEchoTimeout, greaterThanOrEqualTo(const Duration(seconds: 15)));
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true});
          h.notifier.lockScooter();
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 2));
          expect(h.state.lockFailedAtMicros, isNull, reason: '2 s is now within the echo window');
          // Late confirm within the window still counts.
          async.elapse(const Duration(seconds: 10));
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 3});
          expect(h.state.pendingLock, isNull);
          expect(data(events('safety', 'lock_confirmed').single)['took_ms'], 12000);
        });
      });

      // ESCL is not the only truth. The vehicle state going
      // to LOCK (0) means the scooter locked; so does CHARGING (6) during a
      // lock-while-charging. Confirms don't need ESCL = 3.
      test('vehicle state going to LOCK confirms a pending lock', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true});
          h.notifier.lockScooter();
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 500));
          h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
          expect(h.state.pendingLock, isNull);
          expect(events('safety', 'lock_confirmed'), hasLength(1));
        });
      });

      test('vehicle state going to CHARGING while locking confirms it', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true});
          h.notifier.lockScooter();
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 500));
          h.notifier.onEvent({'INT_VEHICLE_STATE': 6});
          expect(h.state.pendingLock, isNull);
          expect(events('safety', 'lock_confirmed'), hasLength(1));
        });
      });

      // ESCL 4 + a state change to LOCK = locked, handlebar free. Warn,
      // do not fail. ESCL 4 with no state change still fails.
      test('ESCL 4 with a lock state transition warns, does not fail', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true});
          h.notifier.lockScooter();
          async.flushMicrotasks();
          async.elapse(const Duration(milliseconds: 500));
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4, 'INT_VEHICLE_STATE': 0});
          expect(h.state.pendingLock, isNull, reason: 'confirmed via the state change');
          expect(h.state.lockFailedAtMicros, isNull);
          expect(events('safety', 'lock_rejected'), isEmpty);
          expect(events('safety', 'lock_confirmed'), hasLength(1));
        });
      });
    });

    group('passcode change waits for the HPMS ack', () {
      Future<bool>? change;
      bool? result;

      void start(_Harness h) {
        result = null;
        change = h.notifier.changePasscode('246810')..then((ok) => result = ok);
      }

      test('a positive ack within 3 s confirms', () {
        onFakeClock((async, h) {
          start(h);
          async.flushMicrotasks();
          h.notifier.onEvent({'BOOL_PROFILE_PASSCODE_CHANGED_ACK': true});
          async.flushMicrotasks();
          expect(result, isTrue);
          expect(h.container.read(toastProvider)?.message, 'Passcode updated');
          expect(change, isNotNull);
        });
      });

      test('a negative ack fails', () {
        onFakeClock((async, h) {
          start(h);
          async.flushMicrotasks();
          h.notifier.onEvent({'BOOL_PROFILE_PASSCODE_CHANGED_ACK': false});
          async.flushMicrotasks();
          expect(result, isFalse);
          expect(h.container.read(toastProvider)?.message, 'Change failed');
        });
      });

      test('no ack within 3 s fails without claiming success', () {
        onFakeClock((async, h) {
          start(h);
          async.elapse(AidlVehicleNotifier.passcodeChangeTimeout);
          expect(result, isFalse);
          expect(h.container.read(toastProvider)?.message, 'No confirmation — try again');
        });
      });

      test('the change screen closes only on the ack', () {
        onFakeClock((async, h) {
          h.container.listen(changePasscodeOpenProvider, (_, _) {});
          h.container.listen(changePasscodeProvider, (_, _) {});
          h.notifier.onEvent({'_connected': true});
          h.container.read(changePasscodeOpenProvider.notifier).open();
          final n = h.container.read(changePasscodeProvider.notifier);
          void enter(String pin) {
            for (final ch in pin.split('')) {
              n.enterDigit(int.parse(ch));
            }
          }

          enter('123456');
          async.flushMicrotasks();
          h.notifier.onEvent({'_passcode': {'success': true, 'remaining': -1}});
          async.flushMicrotasks();
          expect(h.container.read(changePasscodeProvider).step, PasscodeStep.create);
          enter('246810');
          enter('246810');
          async.flushMicrotasks();
          expect(h.container.read(changePasscodeOpenProvider), isTrue, reason: 'not before HPMS confirms');
          h.notifier.onEvent({'BOOL_PROFILE_PASSCODE_CHANGED_ACK': false});
          async.flushMicrotasks();
          expect(h.container.read(changePasscodeOpenProvider), isTrue);
          expect(h.container.read(changePasscodeProvider).lastResult, ChangePasscodeResult.failure);
          async.elapse(ChangePasscodeNotifier.clearDelay);
          enter('246810');
          async.flushMicrotasks();
          h.notifier.onEvent({'BOOL_PROFILE_PASSCODE_CHANGED_ACK': true});
          async.flushMicrotasks();
          expect(h.container.read(changePasscodeOpenProvider), isFalse);
        });
      });
    });

    test('every passcode result is logged with its round trip', () {
      onFakeClock((async, h) {
        h.notifier.verifyPasscode('111111');
        async.elapse(const Duration(milliseconds: 180));
        h.notifier.onEvent({'_passcode': {'success': false, 'remaining': 4}});
        expect(data(events('safety', 'passcode_result').single), {'success': false, 'remaining': 4, 'round_trip_ms': 180});
        expect(h.container.read(passcodeReportProvider)?.remaining, 4, reason: 'the lock screen hears HPMS too');
      });
    });

    // HHMIS calls onPasscodeVerify twice per verification,
    // ~80 ms apart, and the second line had `round_trip_ms: null`.
    test('HHMIS repeating a passcode result is one log line; a new result is another', () {
      onFakeClock((async, h) {
        h.notifier.verifyPasscode('111111');
        async.elapse(const Duration(milliseconds: 204));
        h.notifier.onEvent({'_passcode': {'success': true, 'remaining': 5}});
        async.elapse(const Duration(milliseconds: 87));
        h.notifier.onEvent({'_passcode': {'success': true, 'remaining': 5}});
        expect(data(events('safety', 'passcode_result').single), {'success': true, 'remaining': 5, 'round_trip_ms': 204});
        h.notifier.onEvent({'_passcode': {'success': false, 'remaining': 4}});
        expect(events('safety', 'passcode_result'), hasLength(2), reason: 'a different answer is not a repeat');
        async.elapse(AidlVehicleNotifier.passcodeRepeatWindow);
        h.notifier.onEvent({'_passcode': {'success': false, 'remaining': 4}});
        expect(events('safety', 'passcode_result'), hasLength(3), reason: 'nor is the same answer a second later');
        expect(h.container.read(passcodeReportProvider)?.remaining, 4);
      });
    });

    // Seen on a ride: two `ui.tap ctl-trunk` 157 ms apart, cmd 26 twice.
    test('two taps on the boot button inside 2 s send unlockSeat once', () {
      onFakeClock((async, h) {
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, 'INT_VEHICLE_ESCL_STATUS': 1});
        h.notifier.onEvent({'INT_VEHICLE_TRUNK_STATUS': 3});
        async.flushMicrotasks();
        h.calls.clear();
        h.notifier.toggleTrunk();
        async.elapse(const Duration(milliseconds: 157));
        h.notifier.toggleTrunk();
        async.flushMicrotasks();
        expect(h.calls, ['sendVoidCmd {cmd: ${HhmisCmd.unlockSeat}}']);
        async.elapse(AidlVehicleNotifier.trunkThrottle);
        h.notifier.openTrunk();
        async.flushMicrotasks();
        expect(h.calls, hasLength(2), reason: 'a later press is a new press');
      });
    });

    test('HHMIS throwing is "refused", not "not connected"', () {
      fakeAsync((async) {
        final c = ProviderContainer(overrides: [
          vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), 
                events: const Stream.empty(),
                invoke: (_, _) async => throw PlatformException(code: hhmisErrorCode),
              )),
        ]);
        c.listen(toastProvider, (_, _) {});
        (c.read(vehicleProvider.notifier) as AidlVehicleNotifier).resetTrip();
        async.flushMicrotasks();
        expect(c.read(toastProvider)?.message, 'Scooter refused the command');
        c.dispose();
      });
    });

    test('a batch that says disconnected is not overridden by its data keys', () {
      final h = _Harness();
      h.notifier.onEvent({'_connected': true});
      h.notifier.onEvent({'_connected': false, 'INT_VEHICLE_SPEED': 3});
      expect(h.state.hhmisConnected, isFalse);
      h.dispose();
    });

    test('Adaptive Power Boost is ClientCmd 42 and its echo drives the telltale', () async {
      final h = _Harness();
      h.notifier.setFeature(RidingFeature.adaptivePowerBoost, true);
      await Future<void>.delayed(Duration.zero);
      expect(h.calls, ['sendIntCmd {cmd: ADAPTIVE_POWERBOOST_TOGGLE, value: 1}']);
      h.notifier.onEvent({'BOOL_VEHICLE_ADAPTIVE_POWER_BOOST_STATUS': true});
      expect(h.state.apbActive, isTrue);
      expect(HhmisCmd.features.keys.map((f) => f.name), isNot(contains('regen')), reason: 'REGEN_TOGGLE never disabled regen');
      h.dispose();
    });

    // openTrunk refuses while locked (helmet stays put;
    // what the vehicle does on unlockSeat when locked is still open).
    test('openTrunk refuses while locked', () async {
      final h = _Harness();
      expect(h.state.locked, isTrue);
      h.notifier.openTrunk();
      await Future<void>.delayed(Duration.zero);
      expect(h.calls, isEmpty);
      // Unlock and try again - now it sends.
      h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 1});
      h.notifier.openTrunk();
      await Future<void>.delayed(Duration.zero);
      expect(h.calls, ['sendVoidCmd {cmd: ${HhmisCmd.unlockSeat}}']);
      h.dispose();
    });

    // ClientCmd 67 polarity is unknown - 1 may enable
    // either the stand interlock or the override. Until a capture settles
    // it, setFeature for sideStandCutOff must send nothing.
    test('sideStandCutOff sends nothing (cmd 67 polarity unknown)', () async {
      final h = _Harness();
      h.notifier.setFeature(RidingFeature.sideStandCutOff, true);
      h.notifier.setFeature(RidingFeature.sideStandCutOff, false);
      await Future<void>.delayed(Duration.zero);
      expect(h.calls, isEmpty);
      expect(HhmisCmd.features.keys, isNot(contains(RidingFeature.sideStandCutOff)));
      expect(HhmisCmd.names.values, isNot(contains('sideStandCutOff')));
      h.dispose();
    });

    group('analytics fidelity', () {
      test('each unknown key logs once per distinct value, capped at 10', () {
        onFakeClock((async, h) {
          for (var i = 0; i < 100; i++) {
            h.notifier.onEvent({'INT_SOMETHING_OLD': 60, 'INT_SOMETHING_NEW': i});
            async.elapse(AidlVehicleNotifier.unknownKeysRollup);
          }
          final seen = events('hhmis', 'unknown_key_seen').map((e) => data(e)['key']).toList();
          // Steady key: one event (same value each time).
          expect(seen.where((k) => k == 'INT_SOMETHING_OLD').length, 1);
          // Fluctuating key: 10 distinct values logged, then capped.
          expect(seen.where((k) => k == 'INT_SOMETHING_NEW').length, 10);
        });
      });

      test('batch and unknown_keys key lists are not cut at 20', () {
        onFakeClock((async, h) {
          final batch = {'_connected': true, for (var i = 0; i < 30; i++) 'INT_UNMAPPED_$i': i};
          h.notifier.onEvent(batch);
          expect((data(events('hhmis', 'batch').single)['keys']! as List).length, 31);
          async.elapse(AidlVehicleNotifier.unknownKeysRollup);
          expect((data(events('hhmis', 'unknown_keys').single)['keys']! as List).length, 30);
        });
      });

      test('the bind batch is logged on every reconnect', () {
        final h = _Harness();
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 0});
        h.notifier.onEvent({'INT_VEHICLE_SPEED': 0});
        h.notifier.onEvent({'_connected': false});
        h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3});
        final binds = events('hhmis', 'batch').where((e) => data(e)['nth'] == 1).toList();
        expect(binds, hasLength(2));
        expect(data(binds.last)['keys'], containsAll(['_connected', 'INT_VEHICLE_STATE']));
        h.dispose();
      });
    });

    test('_hwInfo_<id> from TX 2 populates firmware version and VIN fields', () {
      final h = _Harness();
      h.notifier.onEvent({'_hwInfo_0': 'BCM-1.2.3'});
      h.notifier.onEvent({'_hwInfo_1': 'BMS-4.5.6'});
      h.notifier.onEvent({'_hwInfo_2': 'BLE-2.0.1'});
      h.notifier.onEvent({'_hwInfo_3': 'HU-3.4.5'});
      h.notifier.onEvent({'_hwInfo_4': 'HBC-9.1'});
      h.notifier.onEvent({'_hwInfo_5': 'MCU-7.8.9'});
      h.notifier.onEvent({'_hwInfo_6': 'MA3LRDE43P000001'});
      expect(h.state.bcmVersion, 'BCM-1.2.3');
      expect(h.state.bmsVersion, 'BMS-4.5.6');
      expect(h.state.bleVersion, 'BLE-2.0.1');
      expect(h.state.huVersion, 'HU-3.4.5');
      expect(h.state.hbcVersion, 'HBC-9.1');
      expect(h.state.mcuVersion, 'MCU-7.8.9');
      expect(h.state.vin, 'MA3LRDE43P000001');
      // Unknown ids (bootloaders 0x14-0x16) are accepted without crashing.
      h.notifier.onEvent({'_hwInfo_20': 'BOOT-1.0'});
      expect(h.state.vin, 'MA3LRDE43P000001', reason: 'unknown id does not clobber VIN');
      // Empty value is ignored (otherwise a reset packet would wipe the field).
      h.notifier.onEvent({'_hwInfo_6': ''});
      expect(h.state.vin, 'MA3LRDE43P000001');
      h.dispose();
    });

    test('several hardware ids in one bridge batch all land', () {
      final h = _Harness();
      h.notifier.onEvent({'_hwInfo_5': 'MCU-7.8.9', '_hwInfo_6': 'MA3LRDE43P000001', '_hwInfo_0': 'BCM-1.2.3'});
      expect(h.state.mcuVersion, 'MCU-7.8.9');
      expect(h.state.vin, 'MA3LRDE43P000001');
      expect(h.state.bcmVersion, 'BCM-1.2.3');
      h.dispose();
    });

    group('CAN 0x144 lock state', () {
      void sensor(_Harness h, int? bcm) => h.notifier.applySensorUpdate(
            ambientBrightness: null, serviceIndicator: null, regenPowerLimitW: null, dischargePowerLimitW: null,
            rangeEcoCan: null, regenAvailability: null, towTheftState: null, busVoltage: null, packVoltage: null,
            packCurrent: null, trunkClosed: null, vehicleLockStateBcm: bcm,
          );

      void onClock(void Function(FakeAsync async, _Harness h) body) => fakeAsync((async) {
            AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
            final h = _Harness();
            body(async, h);
            h.dispose();
          });

      test('a fresh HHMIS PARK wins over a trailing BCM Locked after a passcode unlock', () {
        onClock((async, h) {
          h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
          expect(h.state.locked, isFalse);
          async.elapse(const Duration(milliseconds: 400));
          sensor(h, 3);
          expect(h.state.locked, isFalse, reason: 'the BCM trails PARK by 0.1-0.8 s; no flicker back to the lock screen');
        });
      });

      test('BCM Locked asserts locked once HHMIS vehicle state has gone stale', () {
        onClock((async, h) {
          h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
          async.elapse(AidlVehicleNotifier.stalenessThreshold + const Duration(seconds: 1));
          sensor(h, 3);
          expect(h.state.locked, isTrue);
        });
      });

      test('a CAN-asserted lock is logged with its source (G-11)', () {
        onClock((async, h) {
          h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
          async.elapse(AidlVehicleNotifier.stalenessThreshold + const Duration(seconds: 1));
          AnalyticsLogger.instance.resetForTest();
          AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
          sensor(h, 3);
          sensor(h, 3);
          final logged = AnalyticsLogger.instance.recent('can', 'lock_asserted');
          expect(logged, hasLength(1), reason: 'once per assertion, not once per 2 Hz publish');
          final data = logged.single['data'] as Map;
          expect(data['bcm'], 3);
          expect(data['hhmis_state_age_ms'], 13000);
        });
      });

      test('a BCM Locked that HHMIS overrules logs nothing', () {
        onClock((async, h) {
          h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
          AnalyticsLogger.instance.resetForTest();
          sensor(h, 3);
          expect(AnalyticsLogger.instance.recent('can', 'lock_asserted'), isEmpty);
        });
      });

      test('BCM Unlocked never unlocks, even with HHMIS stale', () {
        onClock((async, h) {
          h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
          expect(h.state.locked, isTrue);
          async.elapse(const Duration(minutes: 1));
          sensor(h, 1);
          expect(h.state.locked, isTrue, reason: 'only HHMIS (PARK, _unlocked) may lift the lock screen');
        });
      });

      test('a sticky BCM Lock_Fail or Unlock_Fail raises no alert', () {
        onClock((async, h) {
          h.notifier.onEvent({'INT_VEHICLE_STATE': 3});
          sensor(h, 4);
          sensor(h, 2);
          expect(h.state.lockFailedWarning, isFalse, reason: '0x144 read 4 for minutes on an unlocked scooter');
          expect(h.state.unlockFailedWarning, isFalse);
        });
      });

      test('the reattach echo LOCK does not refresh HHMIS state freshness', () {
        onClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3});
          async.elapse(AidlVehicleNotifier.stalenessThreshold + const Duration(seconds: 1));
          expect(h.calls.where((c) => c.startsWith('reattachCallback')), hasLength(1));
          h.notifier.onEvent({'INT_VEHICLE_STATE': 0, '_volume': 5});
          expect(h.state.locked, isFalse, reason: 'the echo LOCK is dropped');
          sensor(h, 3);
          expect(h.state.locked, isTrue, reason: 'the echo is not a fresh vehicle state, so a stale-HHMIS BCM Locked still applies');
        });
      });
    });

    group('ESCL failure reply (stock CTA_IGNORE)', () {
      List<String> ignores(_Harness h) =>
          h.calls.where((c) => c == 'sendIntCmd {cmd: INT_ESCL_LOCK_CMD, value: ${HhmisCmd.esclIgnoreValue}}').toList();

      test('a transition into lock-fail sends CTA_IGNORE once, at once', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_ESCL_STATUS': 1});
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4});
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4});
          async.flushMicrotasks();
          expect(ignores(h), hasLength(1));
          expect(data(events('safety', 'escl_ignore_sent').single)['trigger'], 'escl');
        });
      });

      test('an unlock-fail transition sends CTA_IGNORE too', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_ESCL_STATUS': 3});
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 2});
          async.flushMicrotasks();
          expect(ignores(h), hasLength(1));
        });
      });

      test('the inherited first value sends nothing', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 2});
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4});
          async.flushMicrotasks();
          expect(ignores(h), isEmpty);
        });
      });

      // Seen on a scooter: no ESCL until the rider's first lock, then 4 while
      // unlocked; without CTA_IGNORE the VCU took 9.5 s to lock.
      test('a first value of lock-fail while unlocked is live: CTA_IGNORE', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, '_unlocked': true});
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4});
          async.flushMicrotasks();
          expect(ignores(h), hasLength(1));
        });
      });

      test('LOCK, PASSCODE or MOTOR_ON clears the warning and a pending debounce', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, 'INT_VEHICLE_ESCL_STATUS': 1});
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4});
          async.elapse(AidlVehicleNotifier.esclFailDebounce);
          expect(h.state.lockFailedWarning, isTrue);
          h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
          expect(h.state.lockFailedWarning, isFalse);
          h.notifier.onEvent({'INT_VEHICLE_STATE': 3, 'INT_VEHICLE_ESCL_STATUS': 1});
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4});
          h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
          async.elapse(AidlVehicleNotifier.esclFailDebounce);
          expect(h.state.lockFailedWarning, isFalse, reason: 'the VCU locked before the 3 s check');
        });
      });

      test('locked on the charger (HHMIS reports 6, not 0): no banner from a later lock-fail', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 6, 'INT_VEHICLE_ESCL_STATUS': 1});
          h.notifier.onEvent({'INT_VEHICLE_STATE': 0});
          h.notifier.onEvent({'INT_VEHICLE_STATE': 6});
          expect(h.state.locked, isTrue);
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4});
          async.elapse(AidlVehicleNotifier.esclFailDebounce);
          expect(h.state.lockFailedWarning, isFalse);
        });
      });

      test('own lock still failed after 3 s: CTA_IGNORE again and the negative chime', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, 'INT_VEHICLE_ESCL_STATUS': 1});
          h.notifier.lockScooter();
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4});
          async.elapse(AidlVehicleNotifier.esclFailDebounce);
          expect(ignores(h), hasLength(2));
          expect(h.calls, contains('sendIntCmd {cmd: ${HhmisCmd.playChime}, value: ${HhmisCmd.chimeNegative}}'));
          expect(events('safety', 'escl_ignore_sent').map((e) => data(e)['trigger']), ['escl', 'lock_recheck']);
        });
      });

      test('own lock that succeeds within 3 s plays no chime', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 3, 'INT_VEHICLE_ESCL_STATUS': 1});
          h.notifier.lockScooter();
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 3});
          async.elapse(AidlVehicleNotifier.esclFailDebounce);
          expect(h.calls.where((c) => c.contains('cmd: ${HhmisCmd.playChime}')), isEmpty);
        });
      });
    });

    group('ESCL 3-second debounce (mimics stock HHMIC checkESCL*FailedStatus)', () {
      test('a lock-fail TRANSITION from Unlocked that persists past 3 s raises the warning', () {
        onFakeClock((async, h) {
          // Establish a prior value; only transitions from a real prior
          // value into 4 arm the debounce. (From Locked the scooter is locked,
          // and a locked scooter gets no lock-fail banner.)
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_ESCL_STATUS': 1});
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4});
          expect(h.state.lockFailedWarning, isFalse, reason: 'not yet — stock waits 3 s first');
          async.elapse(AidlVehicleNotifier.esclFailDebounce);
          expect(h.state.lockFailedWarning, isTrue);
          final logged = events('safety', 'escl_fail_debounced');
          expect(logged, hasLength(1));
          expect(data(logged.single)['kind'], 'lock');
        });
      });

      test('a lock-fail that resolves to Locked within 3 s raises no warning', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_ESCL_STATUS': 1});
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4});
          async.elapse(const Duration(seconds: 2));
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 3});
          async.elapse(const Duration(seconds: 2));
          expect(h.state.lockFailedWarning, isFalse);
          expect(events('safety', 'escl_fail_debounced'), isEmpty);
        });
      });

      test('a lock-fail that returns to Unlocked within 3 s raises no warning', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_ESCL_STATUS': 3});
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4});
          async.elapse(const Duration(seconds: 1));
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 1});
          async.elapse(const Duration(seconds: 5));
          expect(h.state.lockFailedWarning, isFalse);
        });
      });

      test('an unlock-fail TRANSITION from Locked that persists past 3 s raises the warning', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_ESCL_STATUS': 3});
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 2});
          expect(h.state.unlockFailedWarning, isFalse);
          async.elapse(AidlVehicleNotifier.esclFailDebounce);
          expect(h.state.unlockFailedWarning, isTrue);
          expect(data(events('safety', 'escl_fail_debounced').single)['kind'], 'unlock');
        });
      });

      test('a Locked while a lock-fail timer is pending cancels the debounce', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_ESCL_STATUS': 1});
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4});
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 3});
          async.elapse(const Duration(seconds: 5));
          expect(h.state.lockFailedWarning, isFalse);
          expect(events('safety', 'escl_fail_debounced'), isEmpty);
        });
      });

      test('repeated 4 reports after a transition do not restart the debounce clock', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_ESCL_STATUS': 1});
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4});
          for (var i = 0; i < 10; i++) {
            async.elapse(const Duration(milliseconds: 250));
            h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4});
          }
          // 10 × 250 ms = 2.5 s so far. Push one more half second to cross 3 s.
          async.elapse(const Duration(milliseconds: 600));
          expect(h.state.lockFailedWarning, isTrue,
              reason: 'the debounce started on the first ESCL=4 and fires once, 3 s later');
          expect(events('safety', 'escl_fail_debounced'), hasLength(1));
        });
      });

      // Observed in a ride log: scooter was charging, rider
      // was in PASSCODE mode, and HHMIS replayed ESCL=4 as the first-ever
      // value in this session (inherited from a prior lock where handlebars
      // weren't fully in position). The debounce fired at +3 s and showed
      // "Handlebars not locked" on screen — confusing noise, not an active
      // lock failure. Fix: ignore the initial observation.
      test('the INITIAL ESCL=4 (previous=null) does NOT raise the warning', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 2});
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 4});
          async.elapse(AidlVehicleNotifier.esclFailDebounce + const Duration(seconds: 2));
          expect(h.state.lockFailedWarning, isFalse,
              reason: 'inherited state, not a genuine lock-fail transition');
          expect(events('safety', 'escl_fail_debounced'), isEmpty);
        });
      });

      test('the INITIAL ESCL=2 (previous=null) does NOT raise the unlock warning', () {
        onFakeClock((async, h) {
          h.notifier.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 2});
          h.notifier.onEvent({'INT_VEHICLE_ESCL_STATUS': 2});
          async.elapse(AidlVehicleNotifier.esclFailDebounce + const Duration(seconds: 2));
          expect(h.state.unlockFailedWarning, isFalse);
          expect(events('safety', 'escl_fail_debounced'), isEmpty);
        });
      });
    });
  });
}
