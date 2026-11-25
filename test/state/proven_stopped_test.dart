import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/app_catalog.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/services/recovery_service.dart';
import 'package:opendash/services/wifican_codec.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/control_panel.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/error_state.dart';
import 'package:opendash/state/media_state.dart';
import 'package:opendash/state/ota_state.dart';
import 'package:opendash/state/passcode_gate.dart';
import 'package:opendash/state/passcode_state.dart';
import 'package:opendash/state/recovery_panel.dart';
import 'package:opendash/state/riding_lockout.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/safety_watchdog.dart';
import 'package:opendash/state/scooter_restart.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:opendash/state/wifi_state.dart';
import '../helpers/stock.dart';

/// The mock's behaviour with HHMIS as the declared source, so the data can
/// go stale, drop, or contradict itself the way it does on the scooter.
class _Live extends VehicleNotifier {
  _Live({this.connected = true});
  final bool connected;
  int locks = 0;
  int autoParks = 0;
  int reboots = 0;

  @override
  VehicleData build() => super.build().copyWith(hhmisBacked: true, hhmisConnected: connected);

  void stale(bool on) => state = state.copyWith(hhmisStale: on);
  void rpm(int r) => state = state.copyWith(rpm: r);

  @override
  void lockScooter() => locks++;

  @override
  void autoPark() => autoParks++;

  @override
  Future<bool> rebootScooter() async {
    reboots++;
    return true;
  }
}

class _Shell implements RecoveryClient {
  final executed = <String>[];

  @override
  Future<WifiCanResponse> execute(String command, Duration timeout) async {
    executed.add(command);
    return WifiCanResponse(1, '');
  }

  @override
  Future<void> shutdown() async {}
}

const _grace = RidingLockout.grace;
const _hiccup = Duration(seconds: 1);

List<Map<String, Object?>> _cancels() =>
    [for (final e in AnalyticsLogger.instance.recent('safety', 'untrusted_cancel')) Map<String, Object?>.from(e['data'] as Map)];
List<Map<String, Object?>> _refusals() =>
    [for (final e in AnalyticsLogger.instance.recent('safety', 'untrusted_refused')) Map<String, Object?>.from(e['data'] as Map)];

void main() {
  setUp(AnalyticsLogger.instance.resetForTest);

  void live(void Function(FakeAsync async, ProviderContainer c, _Live v) body, {bool connected = true}) {
    fakeAsync((async) {
      final v = _Live(connected: connected);
      final platform = MockPlatformService();
      final c = ProviderContainer(overrides: [
        vehicleProvider.overrideWith(() => v),
        platformServiceProvider.overrideWithValue(platform),
      ]);
      c.listen(toastProvider, (_, _) {});
      c.listen(sessionProvider, (_, _) {});
      c.listen(ridingLockoutProvider, (_, _) {});
      if (connected) {
        v.setLocked(false);
        v.setVehicleState(VehicleState.parked);
      } else {
        // The mock's simulated boot would connect it after 2 s.
        v.dropConnection();
      }
      body(async, c, v);
      c.dispose();
    });
  }

  String? toast(ProviderContainer c) => c.read(toastProvider)?.message;

  group('VehicleData', () {
    const fresh = VehicleData(hhmisBacked: true, hhmisConnected: true);

    test('fresh, connected and consistent at 0 km/h is proven stopped', () {
      expect(fresh.speedTrusted, isTrue);
      expect(fresh.provenStopped, isTrue);
      expect(fresh.movingOrUnknown, isFalse);
      expect(fresh.speedUntrustedReason, isNull);
    });

    test('a speed above zero is never stopped, however trustworthy', () {
      final moving = fresh.copyWith(speed: 40, rpm: 12);
      expect(moving.speedTrusted, isTrue);
      expect(moving.provenStopped, isFalse);
      expect(moving.movingOrUnknown, isTrue);
    });

    test('stale: the 0 is frozen, not proven', () {
      final v = fresh.copyWith(hhmisStale: true);
      expect(v.provenStopped, isFalse);
      expect(v.speedUntrustedReason, 'stale');
    });

    test('disconnected wins over stale as the reason', () {
      final v = fresh.copyWith(hhmisConnected: false, hhmisStale: true);
      expect(v.provenStopped, isFalse);
      expect(v.speedUntrustedReason, 'disconnected');
    });

    test('speed 0 with the motor turning is a contradiction', () {
      expect(fresh.copyWith(rpm: 3).provenStopped, isTrue, reason: 'inside the tolerance');
      final v = fresh.copyWith(rpm: 4);
      expect(v.speedRpmMismatch, isTrue);
      expect(v.provenStopped, isFalse);
      expect(v.speedUntrustedReason, 'speed_rpm_mismatch');
      expect(fresh.copyWith(rpm: -4).speedRpmMismatch, isTrue, reason: 'direction does not matter');
      expect(fresh.copyWith(speed: 50, rpm: 0).speedRpmMismatch, isTrue, reason: 'and the other way round');
    });

    test('the widest pairs seen on recorded rides do not trip it', () {
      // (km/h, raw rpm): the extremes of 11,667 heartbeats.
      for (final (speed, rpm) in [(0, 1), (1, 0), (4, 0), (4, 2), (9, 1), (9, 3), (23, 5), (23, 8), (62, 20), (92, 27), (117, 36)]) {
        expect(fresh.copyWith(speed: speed, rpm: rpm).speedRpmMismatch, isFalse, reason: '$speed km/h at $rpm');
      }
    });

    test('the thresholds follow the stored rpm unit', () {
      expect(VehicleData.rpmPerKmh, 0.31 * VehicleData.rpmStoredPerRaw);
      expect(VehicleData.rpmSpeedTolerance, 3.0 * VehicleData.rpmStoredPerRaw);
    });

    test('the mock is its own source: never unknown', () {
      const mock = VehicleData();
      expect(mock.hhmisBacked, isFalse);
      expect(mock.provenStopped, isTrue, reason: 'even before its simulated boot connects');
      expect(mock.copyWith(hhmisStale: true, rpm: 30).provenStopped, isTrue);
      expect(mock.copyWith(speed: 1).provenStopped, isFalse);
    });

    test('the mock provider never produces HHMIS-backed data', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        final v = c.read(vehicleProvider.notifier);
        expect(c.read(vehicleProvider).speedTrusted, isTrue);
        v.dropConnection();
        v.setSpeed(30);
        v.setSpeed(0);
        async.elapse(const Duration(seconds: 10));
        expect(c.read(vehicleProvider).hhmisBacked, isFalse);
        expect(c.read(vehicleProvider).provenStopped, isTrue);
        expect(c.read(ridingLockoutProvider), isFalse);
        c.dispose();
      });
    });
  });

  group('riding lockout', () {
    test('moving engages at once, stopping releases at once', () {
      live((async, c, v) {
        expect(c.read(ridingLockoutProvider), isFalse);
        v.setSpeed(5);
        expect(c.read(ridingLockoutProvider), isTrue);
        v.setSpeed(0);
        expect(c.read(ridingLockoutProvider), isFalse);
      });
    });

    test('untrusted data engages only after the grace', () {
      live((async, c, v) {
        v.stale(true);
        async.elapse(_hiccup);
        expect(c.read(ridingLockoutProvider), isFalse);
        async.elapse(_grace - _hiccup);
        expect(c.read(ridingLockoutProvider), isTrue);
        v.stale(false);
        expect(c.read(ridingLockoutProvider), isFalse, reason: 'live again');
      });
    });

    test('a hiccup shorter than the grace changes nothing, and the clock restarts', () {
      live((async, c, v) {
        v.stale(true);
        async.elapse(_hiccup);
        v.stale(false);
        async.elapse(_grace);
        expect(c.read(ridingLockoutProvider), isFalse);
        v.setConnected(false);
        async.elapse(_hiccup);
        expect(c.read(ridingLockoutProvider), isFalse);
        async.elapse(_grace);
        expect(c.read(ridingLockoutProvider), isTrue, reason: 'a link lost after boot is unknown');
      });
    });

    test('stopping with untrusted data does not release it', () {
      live((async, c, v) {
        v.setSpeed(30);
        v.stale(true);
        v.setSpeed(0);
        expect(c.read(ridingLockoutProvider), isTrue);
        v.stale(false);
        expect(c.read(ridingLockoutProvider), isFalse);
      });
    });

    test('speed and rpm disagreeing counts as unknown', () {
      live((async, c, v) {
        v.rpm(9);
        async.elapse(_grace);
        expect(c.read(ridingLockoutProvider), isTrue);
      });
    });
  });

  group('boot with no data', () {
    test('never connected: locked out, until the rider continues without vehicle data', () {
      live(connected: false, (async, c, v) {
        expect(c.read(screenStateProvider), ScreenState.booting);
        expect(c.read(ridingLockoutProvider), isTrue);
        c.read(settingsScreenOpenProvider.notifier).open();
        expect(c.read(settingsScreenOpenProvider), isFalse);

        c.read(sessionProvider.notifier).continueWithoutData();
        expect(c.read(ridingLockoutProvider), isFalse, reason: 'the rider vouches; Settings and Recovery are the fix');
        v.setLocked(false);
        c.read(settingsScreenOpenProvider.notifier).open();
        expect(c.read(settingsScreenOpenProvider), isTrue);
        async.elapse(const Duration(minutes: 5));
        expect(c.read(settingsScreenOpenProvider), isTrue, reason: 'and it stays open');
      });
    });

    test('recovery runs on the vouch, vehicle commands do not', () {
      live(connected: false, (async, c, v) {
        final shell = _Shell();
        recoveryService = RecoveryService(clientFactory: (_, _) => shell);
        addTearDown(() => recoveryService = RecoveryService());
        c.listen(recoveryPanelProvider, (_, _) {});
        c.listen(lockingProvider, (_, _) {});
        c.read(recoveryPanelProvider.notifier).wakeDisplay();
        async.flushMicrotasks();
        expect(shell.executed, isEmpty, reason: 'not before the rider chose to continue');
        expect(toast(c), untrustedDataMessage);

        c.read(sessionProvider.notifier).continueWithoutData();
        c.read(recoveryPanelProvider.notifier).wakeDisplay();
        async.flushMicrotasks();
        expect(shell.executed, isNotEmpty);

        c.read(lockingProvider.notifier).start();
        expect(c.read(lockingProvider), isFalse, reason: 'a lock needs proof, not a vouch');
        async.elapse(const Duration(seconds: 3));
        expect(v.locks, 0);
      });
    });

    test('the vouch ends when HHMIS connects: a later drop is unknown again', () {
      live(connected: false, (async, c, v) {
        c.read(sessionProvider.notifier).continueWithoutData();
        v.setConnected(true);
        expect(c.read(sessionProvider).noData, isFalse);
        expect(c.read(ridingLockoutProvider), isFalse);
        v.setConnected(false);
        async.elapse(_grace);
        expect(c.read(ridingLockoutProvider), isTrue);
      });
    });

    test('a locked scooter unlocks with stale, disconnected or contradictory data', () {
      for (final breakIt in <void Function(_Live)>[(v) => v.stale(true), (v) => v.setConnected(false), (v) => v.rpm(9)]) {
        live((async, c, v) {
          c.listen(passcodeProvider, (_, _) {});
          v.setLocked(true);
          breakIt(v);
          async.elapse(const Duration(seconds: 10));
          expect(c.read(screenStateProvider), ScreenState.locked);
          for (final d in [1, 2, 3, 4, 5, 6]) {
            c.read(passcodeProvider.notifier).enterDigit(d);
          }
          async.flushMicrotasks();
          expect(c.read(vehicleProvider).locked, isFalse);
        });
      }
    });

    test('Restart scooter stays reachable with no data: the gate survives, the rider vouches', () {
      live((async, c, v) {
        final shell = _Shell();
        recoveryService = RecoveryService(clientFactory: (_, _) => shell);
        addTearDown(() => recoveryService = RecoveryService());
        c.listen(passcodeGateProvider, (_, _) {});
        c.listen(scooterRestartProvider, (_, _) {});
        v.setConnected(false);
        async.elapse(const Duration(seconds: 30));
        expect(c.read(ridingLockoutProvider), isTrue);
        expect(restartAvailable(c.read(vehicleProvider)), isTrue);
        c.read(scooterRestartProvider.notifier).request('test');
        expect(c.read(passcodeGateProvider).open, isTrue);
        async.elapse(const Duration(seconds: 5));
        expect(c.read(passcodeGateProvider).open, isTrue, reason: 'unknown data must not close this gate');
        for (final d in [1, 2, 3, 4, 5, 6]) {
          c.read(passcodeGateProvider.notifier).enterDigit(d);
        }
        async.flushMicrotasks();
        expect(c.read(scooterRestartProvider)?.liveData, isFalse);
        async.elapse(const Duration(seconds: 3));
        expect(c.read(scooterRestartProvider), isNotNull, reason: 'the vouch dialog is not auto-cancelled');
        c.read(scooterRestartProvider.notifier).confirm();
        async.flushMicrotasks();
        expect(shell.executed, isNotEmpty, reason: 'head unit reboot');
        expect(_cancels(), isEmpty);
      });
    });

    test('the restart gate still closes when the scooter moves', () {
      live((async, c, v) {
        c.listen(passcodeGateProvider, (_, _) {});
        v.setConnected(false);
        async.elapse(_grace);
        c.read(scooterRestartProvider.notifier).request('test');
        expect(c.read(passcodeGateProvider).open, isTrue);
        v.setSpeed(8);
        expect(c.read(passcodeGateProvider).open, isFalse);
      });
    });
  });

  group('overlays close on moving and on unknown', () {
    final overlays = <String, (bool Function(ProviderContainer), void Function(ProviderContainer))>{
      'Settings': ((c) => c.read(settingsScreenOpenProvider), (c) => c.read(settingsScreenOpenProvider.notifier).open()),
      'Apps': ((c) => c.read(appLauncherOpenProvider), (c) => c.read(appLauncherOpenProvider.notifier).open()),
      // Diagnostics is the one overlay that rides; tested on its own below.
      'Bluetooth devices': ((c) => c.read(btScreenOpenProvider), (c) => c.read(btScreenOpenProvider.notifier).open()),
      'Software update': ((c) => c.read(otaScreenOpenProvider), (c) => c.read(otaScreenOpenProvider.notifier).open()),
      'Licenses': ((c) => c.read(licensesScreenOpenProvider), (c) => c.read(licensesScreenOpenProvider.notifier).open()),
      'Service mode': ((c) => c.read(serviceModeOpenProvider), (c) => c.read(serviceModeOpenProvider.notifier).open()),
      'Battery health popup': ((c) => c.read(sohPopupOpenProvider), (c) => c.read(sohPopupOpenProvider.notifier).open()),
      'Wi-Fi details': ((c) => c.read(wifiDetailsOpenProvider), (c) => c.read(wifiDetailsOpenProvider.notifier).open()),
      'Change passcode': ((c) => c.read(changePasscodeOpenProvider), (c) => c.read(changePasscodeOpenProvider.notifier).open()),
      'Trip reset': ((c) => c.read(tripResetProvider), (c) => c.read(tripResetProvider.notifier).open()),
      'Volume': ((c) => c.read(volumeOverlayProvider), (c) => c.read(volumeOverlayProvider.notifier).open()),
      'Passcode gate': (
        (c) => c.read(passcodeGateProvider).open,
        (c) => c.read(passcodeGateProvider.notifier).request(purpose: 'test', onSuccess: () {}),
      ),
      'Side stand bypass prompt': (
        (c) => c.read(ridingSettingsProvider).standBypassPrompt,
        (c) {
          c.read(ridingSettingsProvider.notifier).setFeature(RidingFeature.sideStandCutOff, false);
          for (final d in [1, 2, 3, 4, 5, 6]) {
            c.read(passcodeGateProvider.notifier).enterDigit(d);
          }
        },
      ),
    };

    void keepAlive(ProviderContainer c) {
      for (final p in [
        settingsScreenOpenProvider, appLauncherOpenProvider, diagnosticsOpenProvider, btScreenOpenProvider,
        otaScreenOpenProvider, licensesScreenOpenProvider, serviceModeOpenProvider, sohPopupOpenProvider,
        wifiDetailsOpenProvider, changePasscodeOpenProvider, tripResetProvider, volumeOverlayProvider,
        passcodeGateProvider, ridingSettingsProvider,
      ]) {
        c.listen(p, (_, _) {});
      }
    }

    for (final MapEntry(key: name, value: (isOpen, open)) in overlays.entries) {
      test('$name closes the moment the scooter moves', () {
        live((async, c, v) {
          keepAlive(c);
          open(c);
          async.flushMicrotasks();
          expect(isOpen(c), isTrue);
          v.setSpeed(22);
          expect(isOpen(c), isFalse);
          open(c);
          async.flushMicrotasks();
          expect(isOpen(c), isFalse, reason: 'and does not open at speed');
        });
      });

      test('$name rides out a hiccup, closes after the grace on unknown data', () {
        live((async, c, v) {
          keepAlive(c);
          open(c);
          async.flushMicrotasks();
          v.stale(true);
          async.elapse(_hiccup);
          expect(isOpen(c), isTrue, reason: 'a brief HHMIS hiccup');
          v.stale(false);
          async.elapse(_hiccup);
          expect(isOpen(c), isTrue);
          v.stale(true);
          async.elapse(_grace);
          expect(isOpen(c), isFalse, reason: 'unknown is treated as moving');
          open(c);
          async.flushMicrotasks();
          expect(isOpen(c), isFalse, reason: 'and does not open on unknown data');
        });
      });
    }

    test('Diagnostics rides through moving and unknown data, but will not open then', () {
      live((async, c, v) {
        c.listen(diagnosticsOpenProvider, (_, _) {});
        // Opened stopped.
        c.read(diagnosticsOpenProvider.notifier).open();
        async.flushMicrotasks();
        expect(c.read(diagnosticsOpenProvider), isTrue);
        // Rides: stays open on the move (the island shows the speedo over it).
        v.setSpeed(22);
        expect(c.read(diagnosticsOpenProvider), isTrue, reason: 'stays open on the move');
        v.setSpeed(0);
        // And through unknown data — the connections tab is for diagnosing it.
        v.stale(true);
        async.elapse(_grace);
        expect(c.read(diagnosticsOpenProvider), isTrue, reason: 'stays open on unknown data');
        // But closed, it will not reopen until a standstill is proven.
        c.read(diagnosticsOpenProvider.notifier).close();
        c.read(diagnosticsOpenProvider.notifier).open();
        expect(c.read(diagnosticsOpenProvider), isFalse, reason: 'does not open on unknown data');
        v.stale(false);
        async.elapse(_grace);
        c.read(diagnosticsOpenProvider.notifier).open();
        expect(c.read(diagnosticsOpenProvider), isTrue);
      });
    });

    test('diagnosticsRiding latches on movement, holds a brief stop, releases when settled', () {
      live((async, c, v) {
        c.listen(diagnosticsRidingProvider, (_, _) {});
        c.read(diagnosticsOpenProvider.notifier).open();
        async.flushMicrotasks();
        expect(c.read(diagnosticsRidingProvider), isFalse, reason: 'opened stopped: not yet');
        v.setSpeed(20);
        async.flushMicrotasks();
        expect(c.read(diagnosticsRidingProvider), isTrue, reason: 'latches on movement');
        // A brief stop stays latched, so the speedo and toolbar do not flicker.
        v.setSpeed(0);
        async.elapse(const Duration(seconds: 2));
        expect(c.read(diagnosticsRidingProvider), isTrue, reason: 'held across a brief stop');
        v.setSpeed(15);
        async.flushMicrotasks();
        expect(c.read(diagnosticsRidingProvider), isTrue);
        // A settled stop past the hold releases it.
        v.setSpeed(0);
        async.elapse(DiagnosticsRiding.hold + const Duration(seconds: 1));
        expect(c.read(diagnosticsRidingProvider), isFalse, reason: 'released after a settled stop');
        // Moving again re-latches; closing the tab drops it at once.
        v.setSpeed(20);
        async.flushMicrotasks();
        expect(c.read(diagnosticsRidingProvider), isTrue);
        c.read(diagnosticsOpenProvider.notifier).close();
        async.flushMicrotasks();
        expect(c.read(diagnosticsRidingProvider), isFalse, reason: 'tab closed');
      });
    });

    test('the error card minimises on unknown data, like riding', () {
      live((async, c, v) {
        c.listen(errorMinimizedProvider, (_, _) {});
        c.read(appErrorProvider.notifier).report(StateError('boom'), StackTrace.empty);
        expect(c.read(errorMinimizedProvider), isFalse);
        v.stale(true);
        async.elapse(_grace);
        expect(c.read(errorMinimizedProvider), isTrue);
      });
    });
  });

  group('risky flows need proof and cancel themselves', () {
    test('lock: refused on untrusted data', () {
      live((async, c, v) {
        c.listen(lockingProvider, (_, _) {});
        v.stale(true);
        c.read(lockingProvider.notifier).start();
        expect(c.read(lockingProvider), isFalse);
        expect(toast(c), untrustedDataMessage);
        expect(_refusals(), [{'flow': 'lock', 'reason': 'stale'}]);
        async.elapse(const Duration(seconds: 3));
        expect(v.locks, 0);
      });
    });

    test('lock: in flight, cancelled the moment the data goes untrusted', () {
      live((async, c, v) {
        c.listen(lockingProvider, (_, _) {});
        c.read(lockingProvider.notifier).start();
        expect(c.read(lockingProvider), isTrue);
        async.elapse(const Duration(milliseconds: 500));
        v.setConnected(false);
        expect(c.read(lockingProvider), isFalse, reason: 'no grace for a vehicle command');
        expect(toast(c), untrustedDataMessage);
        expect(_cancels(), [{'flow': 'lock', 'reason': 'disconnected'}]);
        async.elapse(const Duration(seconds: 3));
        expect(v.locks, 0);
      });
    });

    test('lock: moving keeps its own message and is not logged as untrusted', () {
      live((async, c, v) {
        c.listen(lockingProvider, (_, _) {});
        c.read(lockingProvider.notifier).start();
        v.setSpeed(6);
        expect(c.read(lockingProvider), isFalse);
        expect(toast(c), 'Locking cancelled — scooter is moving');
        expect(_cancels(), isEmpty);
        c.read(lockingProvider.notifier).start();
        expect(toast(c), 'Stop to lock the scooter');
        expect(_refusals(), isEmpty);
      });
    });

    void armWatchdog(ProviderContainer c, _Live v) {
      c.listen(safetyWatchdogProvider, (_, _) {});
      c.read(ridingSettingsProvider.notifier).setAutoLockEnabled(true);
      v.setVehicleState(VehicleState.ready);
      v.setSpeed(20);
      v.setSideStand(true);
      v.setSpeed(0);
    }

    test('auto-park: the countdown cancels on untrusted data and restarts when it is back', () {
      live((async, c, v) {
        armWatchdog(c, v);
        expect(c.read(safetyWatchdogProvider).armed, isTrue);
        async.elapse(const Duration(seconds: 2));
        v.stale(true);
        expect(c.read(safetyWatchdogProvider).armed, isFalse);
        expect(toast(c), untrustedDataMessage);
        expect(_cancels(), [{'flow': 'auto_park', 'reason': 'stale'}]);
        expect((AnalyticsLogger.instance.recent('safety', 'watchdog_cancel').single['data'] as Map)['reason'], 'untrusted');
        async.elapse(const Duration(seconds: 30));
        expect(v.autoParks, 0, reason: 'nothing is sent on a frozen 0');
        v.stale(false);
        expect(c.read(safetyWatchdogProvider).armed, isTrue);
        expect(c.read(safetyWatchdogProvider).remainingSeconds, SafetyWatchdog.delay.inSeconds, reason: 'a full countdown again');
        async.elapse(SafetyWatchdog.delay);
        expect(v.autoParks, 1);
      });
    });

    test('auto-park: speed 0 with the motor turning cancels it too', () {
      live((async, c, v) {
        armWatchdog(c, v);
        v.rpm(8);
        expect(c.read(safetyWatchdogProvider).armed, isFalse);
        expect(_cancels(), [{'flow': 'auto_park', 'reason': 'speed_rpm_mismatch'}]);
        async.elapse(const Duration(seconds: 30));
        expect(v.autoParks, 0);
      });
    });

    test('auto-park: never arms on a stop it cannot prove', () {
      live((async, c, v) {
        c.listen(safetyWatchdogProvider, (_, _) {});
        c.read(ridingSettingsProvider.notifier).setAutoLockEnabled(true);
        v.setVehicleState(VehicleState.ready);
        v.setSpeed(20);
        v.setSideStand(true);
        v.stale(true);
        v.setSpeed(0);
        async.elapse(const Duration(seconds: 30));
        expect(c.read(safetyWatchdogProvider).armed, isFalse);
        expect(v.autoParks, 0);
      });
    });

    test('auto-park: "Keep riding" survives a data hiccup', () {
      live((async, c, v) {
        armWatchdog(c, v);
        c.read(safetyWatchdogProvider.notifier).cancel();
        v.stale(true);
        v.stale(false);
        async.elapse(const Duration(seconds: 30));
        expect(c.read(safetyWatchdogProvider).armed, isFalse);
        expect(v.autoParks, 0);
      });
    });

    test('auto-park: Retry after a failed lock is refused on untrusted data', () {
      live((async, c, v) {
        armWatchdog(c, v);
        async.elapse(SafetyWatchdog.delay);
        expect(c.read(safetyWatchdogProvider).awaitingLock, isTrue);
        expect(v.autoParks, 1);
        v.setConnected(false);
        c.read(safetyWatchdogProvider.notifier).retryLock();
        expect(v.autoParks, 1);
        expect(_refusals(), [{'flow': 'auto_park_retry', 'reason': 'disconnected'}]);
      });
    });

    void enterGate(ProviderContainer c) {
      for (final d in [1, 2, 3, 4, 5, 6]) {
        c.read(passcodeGateProvider.notifier).enterDigit(d);
      }
    }

    test('restart confirm: cancels when the data it checked goes away; asking again offers the vouch', () {
      live((async, c, v) {
        c.listen(passcodeGateProvider, (_, _) {});
        c.listen(scooterRestartProvider, (_, _) {});
        final r = c.read(scooterRestartProvider.notifier);
        r.request('test');
        enterGate(c);
        async.flushMicrotasks();
        expect(c.read(scooterRestartProvider)?.liveData, isTrue);
        v.stale(true);
        expect(c.read(scooterRestartProvider), isNull);
        expect(toast(c), untrustedDataMessage);
        expect(_cancels(), [{'flow': 'restart_confirm', 'reason': 'stale'}]);
        expect(v.reboots, 0);

        r.request('test');
        enterGate(c);
        async.flushMicrotasks();
        expect(c.read(scooterRestartProvider)?.liveData, isFalse, reason: 'the no-live-data fallback is still there');
      });
    });

    test('restart: speed 0 with the motor turning is not "parked"', () {
      live((async, c, v) {
        v.rpm(9);
        expect(canRestartScooter(c.read(vehicleProvider)), isFalse);
        expect(restartAvailable(c.read(vehicleProvider)), isFalse, reason: 'the data is live, so no vouching either');
        expect(restartBlockedReason(c.read(vehicleProvider)), untrustedDataMessage);
      });
    });

    test('recovery: refused on untrusted data, and the stock restart confirm cancels', () {
      live((async, c, v) {
        final shell = _Shell();
        recoveryService = RecoveryService(clientFactory: (_, _) => shell);
        addTearDown(() => recoveryService = RecoveryService());
        c.listen(recoveryPanelProvider, (_, _) {});
        final p = c.read(recoveryPanelProvider.notifier);
        p.askRestartStock();
        expect(c.read(recoveryPanelProvider), isTrue);
        v.stale(true);
        expect(c.read(recoveryPanelProvider), isFalse);
        expect(_cancels(), [{'flow': 'recovery_restart_stock', 'reason': 'stale'}]);
        p.stopStock();
        p.askRestartStock();
        async.flushMicrotasks();
        expect(shell.executed, isEmpty);
        expect(c.read(recoveryPanelProvider), isFalse);
        expect(_refusals().map((r) => r['flow']), ['recovery_stop-stock', 'recovery_restart-stock']);
        v.stale(false);
        p.stopStock();
        async.flushMicrotasks();
        expect(shell.executed, isNotEmpty);
      });
    });

    test('app launch: refused on untrusted data, even inside the grace', () {
      live((async, c, v) {
        c.listen(passcodeGateProvider, (_, _) {});
        c.listen(mockAppProvider, (_, _) {});
        c.listen(appManagerProvider, (_, _) {});
        async.flushMicrotasks();
        final settingsApp = appCatalog.firstWhere((a) => a.id == 'android-settings');
        c.read(appManagerProvider.notifier).launch(settingsApp);
        async.flushMicrotasks();
        v.stale(true);
        enterGate(c);
        async.elapse(const Duration(milliseconds: 500));
        expect(c.read(mockAppProvider), isNull);
        expect(toast(c), untrustedDataMessage);
        expect(_refusals(), [{'flow': 'app_launch', 'reason': 'stale'}]);
      });
    });

    test('an app in front comes back when the data goes unknown, projection does not', () {
      live((async, c, v) {
        c.listen(passcodeGateProvider, (_, _) {});
        c.listen(mockAppProvider, (_, _) {});
        c.listen(appManagerProvider, (_, _) {});
        async.flushMicrotasks();
        final apps = c.read(appManagerProvider.notifier);
        apps.launch(appCatalog.firstWhere((a) => a.id == 'android-settings'));
        async.flushMicrotasks();
        enterGate(c);
        async.elapse(const Duration(milliseconds: 500));
        expect(c.read(mockAppProvider)?.id, 'android-settings');
        v.stale(true);
        async.elapse(_grace);
        expect(c.read(mockAppProvider), isNull);
        expect(AnalyticsLogger.instance.recent('apps', 'auto_return'), hasLength(1));

        v.stale(false);
        apps.launch(appCatalog.firstWhere((a) => a.id == 'android-auto'));
        async.elapse(const Duration(milliseconds: 500));
        expect(c.read(mockAppProvider)?.id, 'android-auto');
        v.stale(true);
        async.elapse(_grace);
        expect(c.read(mockAppProvider)?.id, 'android-auto');
      });
    });
  });

  group('AidlVehicleNotifier', () {
    void aidl(void Function(FakeAsync async, ProviderContainer c, AidlVehicleNotifier n, List<String> calls) body) {
      fakeAsync((async) {
        AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
        final events = StreamController<dynamic>();
        final calls = <String>[];
        final c = ProviderContainer(overrides: [
          vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), 
                events: events.stream,
                invoke: (method, args) async {
                  final heartbeat = args is Map && (args['cmd'] == HhmisCmd.touchStatus || args['cmd'] == HhmisCmd.projectLoaded);
                  if (!heartbeat) calls.add('$method $args');
                  return true;
                },
              )),
        ]);
        c.listen(toastProvider, (_, _) {});
        body(async, c, c.read(vehicleProvider.notifier) as AidlVehicleNotifier, calls);
        c.dispose();
        events.close();
        AnalyticsLogger.instance.monoOverride = null;
      });
    }

    const unlocked = {'_connected': true, 'INT_VEHICLE_STATE': 3, 'INT_VEHICLE_ESCL_STATUS': 1, 'INT_VEHICLE_SPEED': 0, 'INT_VEHICLE_MOTOR_RPM': 0};
    final lockCmd = 'sendIntCmd {cmd: ${HhmisCmd.esclLock}, value: ${HhmisCmd.esclLockValue}}';
    final lockNowCmd = 'sendIntCmd {cmd: ${HhmisCmd.sideStandStatus}, value: ${HhmisCmd.sideStandLockNow}}';
    final trunkCmd = 'sendVoidCmd {cmd: ${HhmisCmd.unlockSeat}}';

    test('its data is HHMIS-backed: unknown until HHMIS answers', () {
      aidl((async, c, n, calls) {
        expect(c.read(vehicleProvider).hhmisBacked, isTrue);
        expect(c.read(vehicleProvider).provenStopped, isFalse);
        expect(c.read(vehicleProvider).speedUntrustedReason, 'disconnected');
        n.onEvent(unlocked);
        expect(c.read(vehicleProvider).provenStopped, isTrue);
      });
    });

    test('lock, Lock_Now and the boot go out on proven-stopped data', () {
      aidl((async, c, n, calls) {
        n.onEvent(unlocked);
        n.openTrunk();
        n.lockScooter();
        n.autoPark();
        async.flushMicrotasks();
        expect(calls, containsAll([trunkCmd, lockCmd, lockNowCmd]));
        expect(_refusals(), isEmpty);
      });
    });

    test('nothing goes out before HHMIS has connected', () {
      aidl((async, c, n, calls) {
        n.lockScooter();
        n.autoPark();
        n.openTrunk();
        async.flushMicrotasks();
        expect(calls, isEmpty);
        expect(c.read(vehicleProvider).pendingLock, isNull);
        expect(c.read(toastProvider)?.message, untrustedDataMessage);
        expect(_refusals(), [
          {'flow': 'userLock', 'reason': 'disconnected'},
          {'flow': 'autoPark', 'reason': 'disconnected'},
          {'flow': 'trunk', 'reason': 'disconnected'},
        ]);
      });
    });

    test('nothing goes out on stale data; fresh data lets it through again', () {
      aidl((async, c, n, calls) {
        n.onEvent(unlocked);
        async.elapse(AidlVehicleNotifier.staleAfter + const Duration(seconds: 1));
        expect(c.read(vehicleProvider).hhmisStale, isTrue);
        calls.clear();
        n.lockScooter();
        n.autoPark();
        n.openTrunk();
        async.flushMicrotasks();
        expect(calls.where((x) => x == lockCmd || x == lockNowCmd || x == trunkCmd), isEmpty);
        expect(_refusals().map((r) => r['reason']).toSet(), {'stale'});
        n.onEvent({'INT_VEHICLE_SPEED': 0});
        n.openTrunk();
        async.flushMicrotasks();
        expect(calls, contains(trunkCmd));
      });
    });

    test('nothing goes out when speed says 0 and the motor is turning, or when moving', () {
      aidl((async, c, n, calls) {
        n.onEvent({...unlocked, 'INT_VEHICLE_MOTOR_RPM': 7});
        n.lockScooter();
        n.openTrunk();
        async.flushMicrotasks();
        expect(calls.where((x) => x == lockCmd || x == trunkCmd), isEmpty);
        expect(_refusals().map((r) => r['reason']).toSet(), {'speed_rpm_mismatch'});
        AnalyticsLogger.instance.resetForTest();
        AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
        n.onEvent({'INT_VEHICLE_SPEED': 22});
        n.lockScooter();
        expect(c.read(toastProvider)?.message, 'Stop to lock the scooter');
        n.openTrunk();
        expect(c.read(toastProvider)?.message, 'Stop to open the boot');
        async.flushMicrotasks();
        expect(calls.where((x) => x == lockCmd || x == trunkCmd), isEmpty);
        expect(_refusals(), isEmpty, reason: 'moving is not "untrusted"');
      });
    });

    test('a BLE pairing prompt is declined when speed 0 contradicts the motor', () {
      aidl((async, c, n, calls) {
        n.onEvent({...unlocked, 'INT_VEHICLE_MOTOR_RPM': 7});
        n.onEvent({'STR_PROXIMITY_BLE_PASSCODE': '123456'});
        async.flushMicrotasks();
        expect(c.read(vehicleProvider).btPairingCode, isEmpty);
        expect(calls, contains('sendBoolCmd {cmd: ${HhmisCmd.blePairStat}, value: false}'));
      });
    });
  });
}
