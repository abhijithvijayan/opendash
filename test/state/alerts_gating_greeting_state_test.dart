import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/painting.dart' show HSVColor, Size;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/constants.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/alert_state.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/error_state.dart';
import 'package:opendash/state/greeting_state.dart';
import 'package:opendash/state/media_state.dart';
import 'package:opendash/state/ota_state.dart';
import 'package:opendash/state/passcode_gate.dart';
import 'package:opendash/state/passcode_state.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/safety_watchdog.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:opendash/state/wifi_state.dart';
import 'package:opendash/theme/dash_theme.dart';
import 'package:opendash/widgets/gauges/speed_dial.dart';
import 'package:opendash/widgets/indicators/telltale_strip.dart';

void main() {
  /// A container with the always-on notifiers kept alive, unlocked and
  /// connected, inside fakeAsync so timers can be driven.
  void withApp(void Function(FakeAsync async, ProviderContainer c, VehicleNotifier v) body) {
    fakeAsync((async) {
      final c = ProviderContainer();
      for (final p in [
        sessionProvider, toastProvider, safetyWatchdogProvider, dismissedAlertsProvider, alertCycleProvider,
        passcodeGateProvider, greetingProvider, errorMinimizedProvider, licensesScreenOpenProvider,
        serviceModeOpenProvider, sohPopupOpenProvider, wifiDetailsOpenProvider, ridingSettingsProvider,
        settingsScreenOpenProvider, appLauncherOpenProvider, btScreenOpenProvider, otaScreenOpenProvider,
      ]) {
        c.listen(p, (_, _) {});
      }
      final v = c.read(vehicleProvider.notifier);
      v.setConnected(true);
      v.setLocked(false);
      // Let the handlebar hint (an info alert) expire so it does not sit in
      // the alert queue during the test.
      async.elapse(const Duration(seconds: 5));
      body(async, c, v);
      c.dispose();
    });
  }

  String? toast(ProviderContainer c) => c.read(toastProvider)?.message;

  group('rename', () {
    test('the app name is OpenDash and the passcode is six digits', () {
      expect(appName, 'OpenDash');
      expect(PasscodeNotifier.length, 6);
      expect(VehicleNotifier.defaultPasscode, '123456');
      expect(ChangePasscodeNotifier.length, 6);
    });
  });

  group('alerts', () {
    test('a critical alert is pinned while warnings keep cycling', () {
      withApp((async, c, v) {
        v.setBrakeWorn(true);
        v.setDerating(true);
        async.elapse(const Duration(seconds: 5));
        expect(c.read(alertCycleProvider), 1, reason: 'warnings cycle');
        v.setLimpMode(true);
        expect(c.read(alertCycleProvider), 0, reason: 'a new critical jumps to the front');
        async.elapse(const Duration(seconds: 15));
        expect(c.read(alertCycleProvider), 0, reason: 'pinned');
        expect(c.read(visibleAlertsProvider).first.kind, AlertKind.limpMode);
      });
    });

    test('haptics: two impacts for critical, one for warning, none for info', () {
      final buzzes = <AlertPriority>[];
      DismissedAlerts.onHaptic = buzzes.add;
      addTearDown(() => DismissedAlerts.onHaptic = null);
      withApp((async, c, v) {
        v.setBrakeWorn(true);
        expect(buzzes, [AlertPriority.warning]);
        v.setLimpMode(true);
        expect(buzzes, [AlertPriority.warning, AlertPriority.critical]);
        async.elapse(const Duration(seconds: 6));
        expect(buzzes.length, 2, reason: 'cycling the banner does not re-buzz');
        v.setCharging(true);
        v.setBattery(100);
        expect(buzzes.length, 2, reason: 'info alerts are silent');
      });
    });

    test('the side stand alert is suppressed while the sensor is bypassed', () {
      withApp((async, c, v) {
        v.setVehicleState(VehicleState.ready);
        v.setSideStand(true);
        expect(c.read(visibleAlertsProvider).map((a) => a.kind), contains(AlertKind.sideStand));
        c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.sideStandCutOff, false);
        expect(c.read(visibleAlertsProvider).map((a) => a.kind), isNot(contains(AlertKind.sideStand)));
        c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.sideStandCutOff, true);
        expect(c.read(visibleAlertsProvider).map((a) => a.kind), contains(AlertKind.sideStand));
      });
    });
  });

  group('safety watchdog with the stand bypass', () {
    // Scenario B: stand dropped while moving, then rolled to a stop.
    void dropWhileMoving(VehicleNotifier v) {
      v.setVehicleState(VehicleState.ready);
      v.setSpeed(20);
      v.setSideStand(true);
      v.setSpeed(0);
    }

    test('disabled while the bypass is on, re-armed when the sensor comes back', () {
      withApp((async, c, v) {
        c.read(ridingSettingsProvider.notifier).setAutoLockEnabled(true);
        c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.sideStandCutOff, false);
        dropWhileMoving(v);
        expect(c.read(safetyWatchdogProvider).armed, isFalse);
        async.elapse(const Duration(seconds: 6));
        expect(c.read(vehicleProvider).vehicleState, VehicleState.ready, reason: 'no auto-park');
        c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.sideStandCutOff, true);
        expect(c.read(safetyWatchdogProvider).armed, isTrue, reason: 'arms as soon as the sensor counts again');
        async.elapse(const Duration(seconds: 5));
        expect(c.read(vehicleProvider).vehicleState, VehicleState.parked);
      });
    });

    test('enabling the bypass mid-countdown cancels the timer', () {
      withApp((async, c, v) {
        c.read(ridingSettingsProvider.notifier).setAutoLockEnabled(true);
        dropWhileMoving(v);
        expect(c.read(safetyWatchdogProvider).armed, isTrue);
        async.elapse(const Duration(seconds: 2));
        c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.sideStandCutOff, false);
        expect(c.read(safetyWatchdogProvider).armed, isFalse);
        async.elapse(const Duration(seconds: 5));
        expect(c.read(vehicleProvider).vehicleState, VehicleState.ready);
      });
    });

    test('bypassing from settings goes through the passcode gate and the warning', () {
      withApp((async, c, v) {
        final riding = c.read(ridingSettingsProvider.notifier);
        riding.setFeature(RidingFeature.sideStandCutOff, false);
        expect(c.read(ridingSettingsProvider).isOn(RidingFeature.sideStandCutOff), isTrue, reason: 'not yet');
        expect(c.read(passcodeGateProvider).open, isTrue);
        expect(c.read(passcodeGateProvider).purpose, contains('side stand'));
        for (final d in [1, 2, 3, 4, 5, 6]) {
          c.read(passcodeGateProvider.notifier).enterDigit(d);
        }
        expect(c.read(passcodeGateProvider).open, isFalse);
        expect(c.read(ridingSettingsProvider).standBypassPrompt, isTrue);
        expect(c.read(ridingSettingsProvider).isOn(RidingFeature.sideStandCutOff), isTrue, reason: 'still waiting on the warning');
        riding.confirmStandBypass();
        expect(c.read(ridingSettingsProvider).standBypassPrompt, isFalse);
        expect(c.read(ridingSettingsProvider).isOn(RidingFeature.sideStandCutOff), isFalse);
        expect(toast(c), 'Side stand sensor disabled');
        expect(standBypassTelltale(c.read(ridingSettingsProvider)), isNotNull);
        riding.setFeature(RidingFeature.sideStandCutOff, true);
        expect(c.read(passcodeGateProvider).open, isFalse, reason: 're-enabling needs no passcode');
        expect(c.read(ridingSettingsProvider).isOn(RidingFeature.sideStandCutOff), isTrue);
        expect(standBypassTelltale(c.read(ridingSettingsProvider)), isNull);
      });
    });
  });

  group('passcode gate', () {
    test('opens, rejects a wrong code, accepts the right one and runs the callback', () {
      withApp((async, c, v) {
        var ran = 0;
        final g = c.read(passcodeGateProvider.notifier);
        g.request(purpose: 'Enter passcode to install update', onSuccess: () => ran++);
        expect(c.read(passcodeGateProvider).open, isTrue);
        for (final d in [0, 0, 0, 0, 0, 0]) {
          g.enterDigit(d);
        }
        expect(c.read(passcodeGateProvider).failed, isTrue);
        expect(c.read(passcodeGateProvider).failures, 1);
        expect(ran, 0);
        async.elapse(const Duration(milliseconds: 600));
        expect(c.read(passcodeGateProvider).enteredDigits, isEmpty);
        for (final d in [1, 2, 3, 4, 5, 6]) {
          g.enterDigit(d);
        }
        expect(ran, 1);
        expect(c.read(passcodeGateProvider).open, isFalse);
        expect(c.read(vehicleProvider).locked, isFalse);
      });
    });

    test('cancel closes without running the callback', () {
      withApp((async, c, v) {
        var ran = 0;
        final g = c.read(passcodeGateProvider.notifier);
        g.request(purpose: 'x', onSuccess: () => ran++);
        g.enterDigit(1);
        g.cancel();
        expect(c.read(passcodeGateProvider).open, isFalse);
        for (final d in [1, 2, 3, 4, 5, 6]) {
          g.enterDigit(d);
        }
        expect(ran, 0, reason: 'digits are ignored once closed');
      });
    });

    test('riding cancels the gate; five failures lock it out', () {
      withApp((async, c, v) {
        final g = c.read(passcodeGateProvider.notifier);
        g.request(purpose: 'x', onSuccess: () {});
        v.setSpeed(10);
        expect(c.read(passcodeGateProvider).open, isFalse);
        v.setSpeed(0);
        g.request(purpose: 'x', onSuccess: () {});
        for (var i = 0; i < 5; i++) {
          for (final d in [9, 9, 9, 9, 9, 9]) {
            g.enterDigit(d);
          }
          async.elapse(const Duration(milliseconds: 600));
        }
        expect(c.read(passcodeGateProvider).lockedOut, isTrue);
        g.enterDigit(1);
        expect(c.read(passcodeGateProvider).enteredDigits, isEmpty);
        async.elapse(const Duration(seconds: 31));
        expect(c.read(passcodeGateProvider).lockedOut, isFalse);
      });
    });

  });

  group('overlays auto-close when riding', () {
    test('licenses, service mode, SOH and Wi-Fi details all drop', () {
      withApp((async, c, v) {
        c.read(licensesScreenOpenProvider.notifier).open();
        c.read(serviceModeOpenProvider.notifier).open();
        c.read(sohPopupOpenProvider.notifier).open();
        c.read(wifiDetailsOpenProvider.notifier).open();
        v.setSpeed(15);
        expect(c.read(licensesScreenOpenProvider), isFalse);
        expect(c.read(serviceModeOpenProvider), isFalse);
        expect(c.read(sohPopupOpenProvider), isFalse);
        expect(c.read(wifiDetailsOpenProvider), isFalse);
      });
    });

    test('an error minimises to a chip while riding and expands again by tap', () {
      withApp((async, c, v) {
        c.listen(appErrorProvider, (_, _) {});
        c.read(appErrorProvider.notifier).report(StateError('boom'));
        expect(c.read(errorMinimizedProvider), isFalse);
        v.setSpeed(20);
        expect(c.read(errorMinimizedProvider), isTrue);
        c.read(errorMinimizedProvider.notifier).expand();
        expect(c.read(errorMinimizedProvider), isFalse);
        v.setSpeed(0);
        v.setSpeed(20);
        c.read(appErrorProvider.notifier).dismiss();
        expect(c.read(errorMinimizedProvider), isFalse, reason: 'clearing the error clears the chip');
        c.read(appErrorProvider.notifier).report(StateError('again'));
        expect(c.read(errorMinimizedProvider), isTrue, reason: 'an error raised at speed starts minimised');
      });
    });
  });

  group('lock screen gating', () {
    test('settings, apps, Bluetooth and OTA refuse to open while locked', () {
      withApp((async, c, v) {
        v.setLocked(true);
        c.read(settingsScreenOpenProvider.notifier).open();
        c.read(appLauncherOpenProvider.notifier).open();
        c.read(btScreenOpenProvider.notifier).open();
        c.read(otaScreenOpenProvider.notifier).open();
        expect(c.read(settingsScreenOpenProvider), isFalse);
        expect(c.read(appLauncherOpenProvider), isFalse);
        expect(c.read(btScreenOpenProvider), isFalse);
        expect(c.read(otaScreenOpenProvider), isFalse);
        v.setLocked(false);
        c.read(settingsScreenOpenProvider.notifier).open();
        expect(c.read(settingsScreenOpenProvider), isTrue);
      });
    });

    test('diagnostics, OTA and apps leave settings mounted underneath', () {
      withApp((async, c, v) {
        c.listen(diagnosticsOpenProvider, (_, _) {});
        c.read(settingsScreenOpenProvider.notifier).open();
        c.read(diagnosticsOpenProvider.notifier).open();
        expect(c.read(settingsScreenOpenProvider), isTrue);
        c.read(diagnosticsOpenProvider.notifier).close();
        expect(c.read(settingsScreenOpenProvider), isTrue, reason: 'back lands on settings');
      });
    });
  });

  group('welcome greeting', () {
    test('wording by hour and name', () {
      expect(greetingFor(DateTime(2026, 11, 7, 7), 'Owner'), 'Good morning, Owner');
      expect(greetingFor(DateTime(2026, 11, 7, 11, 59), 'Owner'), 'Good morning, Owner');
      expect(greetingFor(DateTime(2026, 11, 7, 12), 'Owner'), 'Good afternoon, Owner');
      expect(greetingFor(DateTime(2026, 11, 7, 17), 'Owner'), 'Good evening, Owner');
      expect(greetingFor(DateTime(2026, 11, 7, 3), 'Owner'), 'Good evening, Owner');
      expect(greetingFor(DateTime(2026, 11, 7, 9), ''), 'Good morning');
    });

    test('shows on the first unlock only, for three seconds', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        c.listen(sessionProvider, (_, _) {});
        c.listen(greetingProvider, (_, _) {});
        final v = c.read(vehicleProvider.notifier);
        v.setConnected(true);
        expect(c.read(greetingProvider), isNull);
        v.setLocked(false);
        expect(c.read(greetingProvider), startsWith('Good '));
        expect(c.read(greetingProvider), endsWith(', Owner'));
        async.elapse(const Duration(seconds: 3));
        expect(c.read(greetingProvider), isNull);
        v.setLocked(true);
        v.setLocked(false);
        expect(c.read(greetingProvider), isNull, reason: 'once per boot');
        c.dispose();
      });
    });

  });

  group('call over pairing', () {
    test('an incoming call drops a pending pairing request', () {
      withApp((async, c, v) {
        v.startPairing();
        expect(c.read(vehicleProvider).btPairingCode, isNotEmpty);
        v.simulateIncomingCall();
        expect(c.read(vehicleProvider).btPairingCode, isEmpty);
        expect(c.read(vehicleProvider).callIncoming, isTrue);
      });
    });
  });

  group('tell-tales', () {
    test('every symbol has a description, and the bypass glyph follows the setting', () {
      final all = telltalesFor(const VehicleData(
        cruiseMode: CruiseMode.active,
        speed: 42,
        hillHoldActive: true,
        apbActive: true,
        regenActive: true, regenNotification: true,
        regenMode: RegenMode.city,
        brakeWorn: true,
        tamperDetected: true,
        fallDetected: true,
        takeMeHomeLights: true,
        takeMeHomeLightsRemaining: 30,
        autoTurnOff: true,
        positionLight: true,
      ));
      expect(all.map((t) => t.description), everyElement(isNotEmpty));
      expect(all.firstWhere((t) => t.id == 'cruise').description, 'Cruise control — active at 42 km/h');
      expect(all.firstWhere((t) => t.id == 'regen').description, 'Regenerative braking — City (strong)');
      expect(all.firstWhere((t) => t.id == 'takeMeHome').description, 'Take-me-home lights — 30s');
      expect(speedLimitTelltale(const VehicleData(speed: 10), RidingSettings(speedLimitEnabled: true, speedLimit: 60))!.description,
          'Speed limit warning — 60 km/h');
      expect(standBypassTelltale(RidingSettings()), isNull);
      expect(standBypassTelltale(RidingSettings(features: {RidingFeature.sideStandCutOff: false}))!.description,
          'Side stand sensor bypassed');
    });
  });

  group('visual tokens', () {
    test('Ember keeps warning and critical away from the mode accents', () {
      final e = DashTheme.ember;
      double hue(c) => HSVColor.fromColor(c).hue;
      double gap(a, b) {
        final d = (hue(a) - hue(b)).abs() % 360;
        return d > 180 ? 360 - d : d;
      }

      expect(e.warning, isNot(e.normal));
      expect(gap(e.warning, e.normal), greaterThan(15));
      expect(gap(e.hyper, e.critical), greaterThan(40));
      expect(gap(e.warning, e.sport), greaterThan(30));
    });

    test('scale numerals stay clear of the widget panel and share one inner-edge gap', () {
      // The box edge toward the centre lands on numeralInnerRadius for every
      // numeral, so the gap from the tick is the same whatever the width.
      double innerRadius(double v, Size size) {
        final p = scaleNumeralCenter(v, size);
        final d = p - SpeedDial.center;
        final dist = d.distance;
        // Direction back to centre gives cos/sin of the angle; project the
        // half-box onto it to recover where the inner edge sits.
        final inset = (size.width / 2) * (d.dx / dist).abs() + (size.height / 2) * (d.dy / dist).abs();
        return dist - inset;
      }
      for (final (v, size) in [(100.0, const Size(44, 22)), (120.0, const Size(44, 22)), (60.0, const Size(22, 22)), (0.0, const Size(22, 22))]) {
        expect(innerRadius(v, size), closeTo(numeralInnerRadius, 0.5), reason: 'inner edge aligned for $v');
      }
      for (final v in [100.0, 120.0]) {
        final p = scaleNumeralCenter(v, const Size(44, 22));
        expect(p.dx + 22, lessThanOrEqualTo(numeralMaxRight), reason: '$v clears the panel content');
      }
    });

    test('no user-facing caption below 13px outside the lock-screen version', () {
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart') || f.path.contains('/dev/')) continue;
        if (f.path.endsWith('locked_screen.dart')) continue;
        final src = f.readAsStringSync();
        final m = RegExp(r'caption\((9|10|11|12)[,)]').firstMatch(src);
        if (m != null) offenders.add('${f.path}: ${m.group(0)}');
      }
      expect(offenders, isEmpty);
    });

    test('no raw ink hex outside the theme files', () {
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart') || f.path.contains('/theme/') || f.path.contains('/dev/')) continue;
        if (f.readAsStringSync().contains('0xFF05070A') || f.readAsStringSync().contains('0x22ECEEF1')) offenders.add(f.path);
      }
      expect(offenders, isEmpty);
    });
  });
}
