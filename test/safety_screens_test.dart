import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/app_catalog.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/screens/locked/locked_screen.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/error_state.dart';
import 'package:opendash/state/passcode_gate.dart';
import 'package:opendash/state/safety_screen.dart';
import 'package:opendash/state/scooter_restart.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/toast_state.dart';
import 'helpers/stock.dart';

/// The HHMIS bridge with a scripted channel: what the vehicle sends in, and
/// every command that goes out.
class _Bridge {
  _Bridge({bool sendOk = true, String software = 'gen1-moveos4-4.6.14'}) {
    container = ProviderContainer(overrides: [
      vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(software), 
            events: events.stream,
            invoke: (method, args) async {
              if (args is Map && method == 'sendVoidCmd' && args['cmd'] == HhmisCmd.projectLoaded) {
                projectLoaded++;
              } else if (args is Map && method == 'sendVoidCmd') {
                voids.add(args['cmd'] as String);
              }
              return sendOk;
            },
          )),
    ]);
    for (final p in [sessionProvider, toastProvider, safetyScreenProvider]) {
      container.listen(p, (_, _) {});
    }
  }

  final events = StreamController<dynamic>();
  final voids = <String>[];
  var projectLoaded = 0;
  late final ProviderContainer container;

  AidlVehicleNotifier get vehicle => container.read(vehicleProvider.notifier) as AidlVehicleNotifier;
  VehicleData get state => container.read(vehicleProvider);
  SafetyScreen? get screen => container.read(safetyScreenProvider).screen;
  SafetyScreenNotifier get safety => container.read(safetyScreenProvider.notifier);

  void dispose() {
    container.dispose();
    events.close();
  }
}

List<Map<Object?, Object?>> _logged(String evt, [String cat = 'safety']) =>
    [for (final e in AnalyticsLogger.instance.recent(cat, evt)) e['data']! as Map];

void _bridge(void Function(FakeAsync async, _Bridge b) body, {bool sendOk = true, String software = 'gen1-moveos4-4.6.14'}) {
  fakeAsync((async) {
    final b = _Bridge(sendOk: sendOk, software: software);
    b.vehicle.onEvent({'_connected': true});
    body(async, b);
    b.dispose();
    async.flushTimers();
  });
}

const _afterDelay = Duration(milliseconds: 250);

void main() {
  setUp(() => AnalyticsLogger.instance.resetForTest());

  group('command names', () {
    test('are the stock ones', () {
      expect(HhmisCmd.accidentIAmSafe, 'ACCIDENT_RECOVERY_IAM_SAFE');
      expect(HhmisCmd.accidentNeedHelp, 'ACCIDENT_RECOVERY_NEED_HELP');
      expect(HhmisCmd.stopAlarmSound, 'STOP_ALARM_SOUND');
      expect(HhmisCmd.alarmUnlockNow, 'ALARM_UNLOCK_NOW');
    });
  });

  group('accident', () {
    test('BOOL_ACCIDENT_SEVERITY_STAT true shows the screen 200 ms later', () {
      _bridge((async, b) {
        b.vehicle.onEvent({'INT_VEHICLE_STATE': 4, 'BOOL_ACCIDENT_SEVERITY_STAT': true});
        async.elapse(const Duration(milliseconds: 150));
        expect(b.screen, isNull, reason: 'stock posts the switch with a 200 ms delay');
        async.elapse(const Duration(milliseconds: 100));
        expect(b.screen, SafetyScreen.accident);
        expect(_logged('accident'), hasLength(1));
      });
    });

    test('the keys stock ignores do not show it', () {
      _bridge((async, b) {
        b.vehicle.onEvent({'BOOL_FALL_DETECTED_L2_PHASE': true});
        b.vehicle.onEvent({'BOOL_FALL_DETECTED_L1_PHASE': true});
        b.vehicle.onEvent({'BOOL_ACCIDENT_SEVERITY_STAT': false});
        b.vehicle.onEvent({'BOOL_ACCIDENT_DETECTION_TOGGLE_STAT': true});
        async.elapse(_afterDelay);
        expect(b.screen, isNull);
        expect(_logged('accident'), isEmpty);
      });
    });

    test('MoveOS 5: the vehicle command is the accident, as stock 5.0.2 has no other signal', () {
      for (final command in [152, 186]) {
        _bridge((async, b) {
          b.vehicle.onEvent({'INT_VEHICLE_STATE': 4, 'INT_VEHICLE_COMMAND': command});
          async.elapse(_afterDelay);
          expect(b.screen, SafetyScreen.accident, reason: 'command $command');
          b.vehicle.onEvent({'INT_VEHICLE_COMMAND': 0});
          async.flushMicrotasks();
          expect(b.screen, SafetyScreen.accident, reason: 'the clear does not answer it');
          b.safety.reply(safe: true);
          async.flushMicrotasks();
          expect(b.voids, [HhmisCmd.accidentIAmSafe]);
          expect(b.screen, isNull);
          b.vehicle.onEvent({'INT_VEHICLE_COMMAND': command});
          async.elapse(_afterDelay);
          expect(b.screen, SafetyScreen.accident, reason: 'a second accident is a new one');
        }, software: 'gen1-moveos5-5.0.2');
      }
    });

    test('MoveOS 4: the vehicle command alone does not raise it (4.6.14 sends the severity key)', () {
      _bridge((async, b) {
        b.vehicle.onEvent({'INT_VEHICLE_STATE': 4, 'INT_VEHICLE_COMMAND': 152});
        async.elapse(_afterDelay);
        expect(b.screen, isNull);
      });
    });

    test('a later false leaves the question up', () {
      _bridge((async, b) {
        b.vehicle.onEvent({'BOOL_ACCIDENT_SEVERITY_STAT': true});
        async.elapse(_afterDelay);
        b.vehicle.onEvent({'BOOL_ACCIDENT_SEVERITY_STAT': false});
        async.flushMicrotasks();
        expect(b.screen, SafetyScreen.accident);
      });
    });

    for (final (safe, cmd, reply) in [(true, HhmisCmd.accidentIAmSafe, 'safe'), (false, HhmisCmd.accidentNeedHelp, 'help')]) {
      test('"$reply" sends $cmd once and closes the screen', () {
        _bridge((async, b) {
          b.vehicle.onEvent({'BOOL_ACCIDENT_SEVERITY_STAT': true});
          async.elapse(_afterDelay);
          b.safety.reply(safe: safe);
          b.safety.reply(safe: safe);
          b.safety.reply(safe: !safe);
          async.flushMicrotasks();
          expect(b.voids, [cmd]);
          expect(b.screen, isNull);
          expect(_logged('accident_reply').single, {'reply': reply, 'sent': true});
          final toast = b.container.read(toastProvider)!.message;
          expect(toast, safe ? 'Alert deactivated' : contains('Call $emergencyNumber'));
          expect(toast, isNot(contains('get in touch')), reason: 'the cloud alert is not ours to promise');
        });
      });
    }

    test('a reply that does not reach HHMIS keeps the screen for another try', () {
      _bridge((async, b) {
        b.vehicle.onEvent({'BOOL_ACCIDENT_SEVERITY_STAT': true});
        async.elapse(_afterDelay);
        b.safety.reply(safe: true);
        async.flushMicrotasks();
        expect(b.screen, SafetyScreen.accident);
        expect(b.container.read(safetyScreenProvider).busy, isFalse);
        expect(_logged('accident_reply').single['sent'], isFalse);
      }, sendOk: false);
    });

    test('an answered accident is not replayed by a reattach', () {
      _bridge((async, b) {
        b.vehicle.onEvent({'BOOL_ACCIDENT_SEVERITY_STAT': true});
        async.elapse(_afterDelay);
        b.safety.reply(safe: true);
        async.flushMicrotasks();
        b.vehicle.onEvent({'_connected': true, 'BOOL_ACCIDENT_SEVERITY_STAT': true, 'INT_VEHICLE_STATE': 3});
        async.elapse(_afterDelay);
        expect(b.screen, isNull);
        expect(_logged('accident'), hasLength(1));
        // A real second accident: HHMIS sends false, then true.
        b.vehicle.onEvent({'BOOL_ACCIDENT_SEVERITY_STAT': false});
        b.vehicle.onEvent({'BOOL_ACCIDENT_SEVERITY_STAT': true});
        async.elapse(_afterDelay);
        expect(b.screen, SafetyScreen.accident);
      });
    });
  });

  group('fall', () {
    test('INT_FALL_DETECTION_ALERT 1 shows the screen; the phase keys do not', () {
      _bridge((async, b) {
        b.vehicle.onEvent({'BOOL_FALL_DETECTED_L1_PHASE': true});
        async.flushMicrotasks();
        expect(b.screen, isNull);
        b.vehicle.onEvent({'INT_FALL_DETECTION_ALERT': 1});
        async.flushMicrotasks();
        expect(b.screen, SafetyScreen.fall);
        expect(_logged('fall'), hasLength(1));
        b.vehicle.onEvent({'INT_FALL_DETECTION_ALERT': 3});
        async.flushMicrotasks();
        expect(b.screen, isNull, reason: 'RECOVERED');
      });
    });

    test('the accident screen wins while it is unanswered, then the fall screen shows', () {
      _bridge((async, b) {
        b.vehicle.onEvent({'INT_FALL_DETECTION_ALERT': 1, 'BOOL_ACCIDENT_SEVERITY_STAT': true});
        async.flushMicrotasks();
        expect(b.screen, SafetyScreen.fall);
        async.elapse(_afterDelay);
        expect(b.screen, SafetyScreen.accident);
        b.safety.reply(safe: true);
        async.flushMicrotasks();
        expect(b.screen, SafetyScreen.fall);
      });
    });

    test('a fall is not replayed by a reattach', () {
      _bridge((async, b) {
        b.vehicle.onEvent({'INT_VEHICLE_STATE': 1, 'INT_FALL_DETECTION_ALERT': 1});
        b.vehicle.onEvent({'INT_VEHICLE_STATE': 3});
        async.flushMicrotasks();
        expect(b.state.fallDetected, isFalse);
        b.vehicle.onEvent({'_connected': true, 'INT_FALL_DETECTION_ALERT': 1});
        async.flushMicrotasks();
        expect(b.screen, isNull);
      });
    });
  });

  group('alarm', () {
    test('ALARM shows the alarm screen and logs it', () {
      _bridge((async, b) {
        b.vehicle.onEvent({'INT_VEHICLE_STATE': 0});
        b.vehicle.onEvent({'INT_VEHICLE_STATE': 1});
        async.flushMicrotasks();
        expect(b.screen, SafetyScreen.alarm);
        expect(b.state.locked, isTrue, reason: 'the lock screen is what is underneath');
        expect(_logged('alarm').single['on'], isTrue);
      });
    });

    test('Unlock sends ALARM_UNLOCK_NOW once, with no passcode gate, and reports the unlock', () {
      _bridge((async, b) {
        b.vehicle.onEvent({'INT_VEHICLE_STATE': 1});
        async.flushMicrotasks();
        b.safety.unlock();
        b.safety.unlock();
        async.flushMicrotasks();
        expect(b.voids, [HhmisCmd.alarmUnlockNow]);
        expect(b.container.read(passcodeGateProvider).open, isFalse);
        expect(b.container.read(safetyScreenProvider).busy, isTrue);
        async.elapse(const Duration(seconds: 1));
        b.vehicle.onEvent({'INT_VEHICLE_STATE': 2});
        async.flushMicrotasks();
        expect(b.screen, isNull);
        expect(_logged('alarm_unlock').single['result'], 'unlocked');
        expect(_logged('alarm').last['on'], isFalse);
        async.elapse(SafetyScreenNotifier.unlockWait);
        expect(_logged('alarm_unlock'), hasLength(1));
      });
    });

    test('an Unlock the vehicle does not act on steps aside for the keypad', () {
      _bridge((async, b) {
        b.vehicle.onEvent({'INT_VEHICLE_STATE': 1});
        async.flushMicrotasks();
        b.safety.unlock();
        async.elapse(SafetyScreenNotifier.unlockWait + const Duration(milliseconds: 10));
        expect(b.state.alarmActive, isTrue);
        expect(b.screen, isNull, reason: 'the lock screen and its keypad are reachable');
        expect(_logged('alarm_unlock').single['result'], 'no_change');
        // The next alarm brings the screen back.
        b.vehicle.onEvent({'INT_VEHICLE_STATE': 2});
        b.vehicle.onEvent({'INT_VEHICLE_STATE': 1});
        async.flushMicrotasks();
        expect(b.screen, SafetyScreen.alarm);
      });
    });

    test('starting in ALARM: alarm screen, locked underneath, no PROJECT_LOADED', () {
      fakeAsync((async) {
        final b = _Bridge();
        b.vehicle.onEvent({'_connected': true, 'INT_VEHICLE_STATE': 1, 'INT_VEHICLE_SPEED': 0});
        async.elapse(const Duration(seconds: 10));
        expect(b.screen, SafetyScreen.alarm);
        expect(b.state.locked, isTrue);
        expect(b.projectLoaded, 0, reason: 'HHMIS skips its reply in ALARM, and the one send would be spent');
        expect(b.container.read(screenStateProvider), ScreenState.locked);
        b.dispose();
        async.flushTimers();
      });
    });
  });

  group('tow / theft', () {
    test('0, 2 and 153 are ignored; 1 raises the alarm screen', () {
      _bridge((async, b) {
        for (final value in [0, 2, 153]) {
          b.vehicle.onEvent({'INT_TOW_THEFT_DETECTION_ALERT': value});
          async.flushMicrotasks();
          expect(b.screen, isNull, reason: 'value $value');
          expect(b.state.tamperDetected, isFalse, reason: 'value $value');
        }
        expect(b.state.towTheftState, 2, reason: '153 is not a tow state');
        b.vehicle.onEvent({'INT_TOW_THEFT_DETECTION_ALERT': 1});
        async.flushMicrotasks();
        expect(b.screen, SafetyScreen.alarm);
        for (final value in [2, 153, 0]) {
          b.vehicle.onEvent({'INT_TOW_THEFT_DETECTION_ALERT': value});
          async.flushMicrotasks();
          expect(b.screen, SafetyScreen.alarm, reason: 'value $value does not clear it');
        }
        expect([for (final e in _logged('tow_theft')) e['value']], [0, 2, 153, 1, 2, 153, 0]);
      });
    });

    test('the alert clears on leaving ALARM, and a reattach does not replay it', () {
      _bridge((async, b) {
        b.vehicle.onEvent({'INT_VEHICLE_STATE': 1, 'INT_TOW_THEFT_DETECTION_ALERT': 1});
        async.flushMicrotasks();
        expect(b.screen, SafetyScreen.alarm);
        b.vehicle.onEvent({'INT_VEHICLE_STATE': 2});
        async.flushMicrotasks();
        expect(b.state.tamperDetected, isFalse);
        expect(b.screen, isNull);
        b.vehicle.onEvent({'_connected': true, 'INT_TOW_THEFT_DETECTION_ALERT': 1, 'INT_VEHICLE_STATE': 2});
        async.flushMicrotasks();
        expect(b.screen, isNull);
        expect(_logged('tow_theft').last['repeat'], isTrue);
      });
    });

    test('an alert that never became ALARM is taken down by Unlock', () {
      _bridge((async, b) {
        b.vehicle.onEvent({'INT_VEHICLE_STATE': 0, 'INT_TOW_THEFT_DETECTION_ALERT': 1});
        async.flushMicrotasks();
        b.safety.unlock();
        async.flushMicrotasks();
        expect(b.voids, [HhmisCmd.alarmUnlockNow]);
        expect(b.screen, isNull);
        expect(_logged('alarm_unlock').single['result'], 'dismissed');
      });
    });

    test('an alert on an unlocked scooter stays a banner: the cluster is not covered', () {
      _bridge((async, b) {
        b.vehicle.onEvent({'INT_VEHICLE_STATE': 4, 'INT_VEHICLE_SPEED': 20});
        b.vehicle.onEvent({'INT_TOW_THEFT_DETECTION_ALERT': 1});
        async.flushMicrotasks();
        expect(b.screen, isNull);
        expect(b.state.alerts.map((a) => a.kind), contains(AlertKind.tamper));
        b.vehicle.onEvent({'INT_VEHICLE_SPEED': 0, 'INT_VEHICLE_STATE': 0});
        async.flushMicrotasks();
        expect(b.screen, SafetyScreen.alarm, reason: 'locked: the screen');
      });
    });

    test('the Kotlin bridge keeps the alert keys out of its replay snapshot', () {
      final kotlin = File('android/app/src/main/kotlin/in/abhijithvijayan/opendash/VehicleChannel.kt').readAsStringSync();
      final oneShots = kotlin.substring(kotlin.indexOf('ONE_SHOT_KEYS = setOf('), kotlin.indexOf('private var events'));
      for (final key in [
        'INT_TOW_THEFT_DETECTION_ALERT',
        'BOOL_ACCIDENT_SEVERITY_STAT',
        'INT_FALL_DETECTION_ALERT',
        'INT_THERMAL_RUNAWAY',
      ]) {
        expect(oneShots, contains('"$key"'));
      }
    });
  });

  group('bringing the dashboard back', () {
    late ProviderContainer c;
    late MockPlatformService platform;

    void start() {
      platform = MockPlatformService();
      c = ProviderContainer(overrides: [platformServiceProvider.overrideWithValue(platform)]);
      for (final p in [sessionProvider, toastProvider, appManagerProvider, mockAppProvider, safetyScreenProvider]) {
        c.listen(p, (_, _) {});
      }
      c.read(vehicleProvider.notifier)
        ..setConnected(true)
        ..setLocked(false);
    }

    List<Map<Object?, Object?>> returns() => _logged('emergency_return', 'apps');

    for (final (name, trigger, screen) in <(String, void Function(VehicleNotifier), String)>[
      ('accident', (v) => v.setAccident(true), 'accident'),
      ('fall', (v) => v.setFall(true), 'fall'),
      ('alarm', (v) => v.setAlarm(true), 'alarm'),
      ('tow/theft', (v) {
        v.setLocked(true);
        v.setTamper(true);
      }, 'alarm'),
    ]) {
      test('$name returns from an app that is not projection', () {
        fakeAsync((async) {
          start();
          c.read(appManagerProvider.notifier).trackOutsidePackage('files', 'Files', 'com.example.files');
          async.flushMicrotasks();
          trigger(c.read(vehicleProvider.notifier));
          async.elapse(_afterDelay);
          expect(platform.broughtToFront, 1);
          expect(returns().single, {'id': 'files', 'alerts': [screen], 'screen': true});
          expect(c.read(projectionResumeProvider), isNull);
          c.dispose();
        });
      });
    }

    test('an accident returns from projection once, and offers the way back', () {
      fakeAsync((async) {
        start();
        final auto = appCatalog.firstWhere((a) => a.id == 'android-auto');
        final v = c.read(vehicleProvider.notifier);
        v.setVehicleState(VehicleState.riding);
        v.setSpeed(30);
        c.read(appManagerProvider.notifier).launch(auto);
        async.flushMicrotasks();
        v.setAccident(true);
        async.elapse(_afterDelay);
        expect(platform.broughtToFront, 1, reason: 'the screen returns; the banner underneath does not return again');
        expect(c.read(projectionResumeProvider), auto);
        c.dispose();
      });
    });

    test('a screen raised while asleep wakes the display', () {
      fakeAsync((async) {
        start();
        c.read(sessionProvider.notifier).sleep();
        c.read(vehicleProvider.notifier).setAlarm(true);
        async.flushMicrotasks();
        expect(c.read(sessionProvider).asleep, isFalse);
        c.dispose();
      });
    });
  });

  group('screens', () {
    late ProviderContainer container;
    VehicleNotifier v() => container.read(vehicleProvider.notifier);
    Finder k(String key) => find.byKey(ValueKey(key));

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> pumpReady(WidgetTester tester) async {
      await tester.pumpWidget(const ProviderScope(child: OpenDashApp()));
      await tester.pump();
      container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      v().setLocked(false);
      await settle(tester);
      v().setVehicleState(VehicleState.ready);
      await settle(tester);
    }

    testWidgets('accident: stock content, and each button answers', (tester) async {
      await pumpReady(tester);
      v().setAccident(true);
      await settle(tester);
      expect(k('safety-accident'), findsOneWidget);
      expect(find.text('Are you safe?'), findsOneWidget);
      expect(find.text('Looks like you had an accident.'), findsOneWidget);
      expect(find.text('Let us know if you are safe or need any help.'), findsOneWidget);
      expect(k('safety-accident-help').hitTestable(), findsOneWidget);
      await tester.tap(k('safety-accident-safe'));
      await settle(tester);
      expect(k('safety-accident'), findsNothing);
      expect(find.text('Alert deactivated'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('fall: stock content and no button', (tester) async {
      await pumpReady(tester);
      v().setFall(true);
      await settle(tester);
      expect(k('safety-fall'), findsOneWidget);
      expect(find.text('Fall detected'), findsOneWidget);
      expect(find.text('Live location tracking on'), findsOneWidget);
      v().setFall(false);
      await settle(tester);
      expect(k('safety-fall'), findsNothing);
    });

    testWidgets('ALARM shows the alarm screen, not the lock screen; Unlock leads to the keypad', (tester) async {
      await pumpReady(tester);
      v().setAlarm(true);
      await settle(tester);
      expect(k('safety-alarm'), findsOneWidget);
      expect(find.text('Tamper detected'), findsOneWidget);
      expect(find.text('Unlock scooter to deactivate the alert'), findsOneWidget);
      expect(find.byType(LockedScreen).hitTestable(), findsNothing, reason: 'covered');
      expect(find.text('Stop alarm'), findsNothing, reason: 'stock offers no silence button here');
      await tester.tap(k('safety-alarm-unlock'));
      await settle(tester);
      expect(k('safety-alarm'), findsNothing);
      expect(find.byType(LockedScreen), findsOneWidget);
    });

    testWidgets('each screen is on top of every other overlay', (tester) async {
      await pumpReady(tester);
      v().setFault(true);
      v().simulateIncomingCall();
      container.read(serviceModeOpenProvider.notifier).open();
      container.read(passcodeGateProvider.notifier).request(purpose: 'Enter passcode', onSuccess: () {});
      container.read(appErrorProvider.notifier).capture(() => throw StateError('boom'));
      await settle(tester);
      for (final under in ['alert-banner', 'incoming-call', 'passcode-gate', 'error-overlay']) {
        expect(k(under), findsOneWidget, reason: '$under is up');
      }

      for (final (raise, clear, screen, button) in <(VoidCallback, VoidCallback, String, String?)>[
        (() => v().setAccident(true), () => v().setAccident(false), 'safety-accident', 'safety-accident-safe'),
        (() => v().setFall(true), () => v().setFall(false), 'safety-fall', null),
        (() => v().setAlarm(true), () {
          v().setAlarm(false);
          v().setLocked(false);
        }, 'safety-alarm', 'safety-alarm-unlock'),
      ]) {
        raise();
        await settle(tester);
        expect(k(screen).hitTestable(), findsOneWidget, reason: screen);
        if (button != null) expect(k(button).hitTestable(), findsOneWidget, reason: button);
        for (final under in ['alert-banner', 'call-accept', 'gate-cancel', 'error-retry', 'service-mode']) {
          expect(k(under).hitTestable(), findsNothing, reason: '$under is covered by $screen');
        }
        clear();
        await settle(tester);
        expect(k(screen), findsNothing);
      }
      expect(k('error-retry').hitTestable(), findsOneWidget, reason: 'and what was underneath is still there');
    });

    testWidgets('on top of the restart confirm as well', (tester) async {
      await pumpReady(tester);
      v().setVehicleState(VehicleState.parked);
      await settle(tester);
      container.read(scooterRestartProvider.notifier).request('test');
      await settle(tester);
      for (final d in [1, 2, 3, 4, 5, 6]) {
        container.read(passcodeGateProvider.notifier).enterDigit(d);
      }
      await settle(tester);
      expect(k('restart-confirm'), findsOneWidget);
      v().setAccident(true);
      await settle(tester);
      expect(k('safety-accident-safe').hitTestable(), findsOneWidget);
      expect(find.text('Restart').hitTestable(), findsNothing);
      container.read(scooterRestartProvider.notifier).cancel();
      await settle(tester);
    });

    testWidgets('the dev panel triggers each state', (tester) async {
      await pumpReady(tester);
      v().setAlarm(true);
      await settle(tester);
      expect(container.read(safetyScreenProvider).screen, SafetyScreen.alarm);
      v().setAlarm(false);
      v().setFall(true);
      await settle(tester);
      expect(container.read(safetyScreenProvider).screen, SafetyScreen.fall);
      v().setAccident(true);
      await settle(tester);
      expect(container.read(safetyScreenProvider).screen, SafetyScreen.accident);
      v().setAlarm(true);
      v().setAlarm(false);
      await settle(tester);
      expect(container.read(safetyScreenProvider).screen, isNull, reason: 'leaving ALARM clears all three');
    });
  });
}
