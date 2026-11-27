import 'package:fake_async/fake_async.dart';
import 'package:material_ui/material_ui.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/constants.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/charging/charging_screen.dart';
import 'package:opendash/state/boot_timeout.dart';
import 'package:opendash/state/control_panel.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/error_state.dart';
import 'package:opendash/state/format_settings.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:opendash/state/widget_panel_state.dart';

void main() {
  late ProviderContainer c;
  VehicleNotifier v() => c.read(vehicleProvider.notifier);
  VehicleData read() => c.read(vehicleProvider);
  String? toast() => c.read(toastProvider)?.message;

  setUp(() {
    c = ProviderContainer();
    c.listen(toastProvider, (_, _) {});
    c.listen(sessionProvider, (_, _) {});
    v().setConnected(true);
    v().setLocked(false);
  });

  tearDown(() => c.dispose());

  group('media progress', () {
    test('position ticks while playing, holds while paused', () {
      v().setMediaPlaying(true);
      expect(read().mediaPosition, 0);
      expect(read().mediaDuration, 258);
      v().tickMedia();
      v().tickMedia();
      expect(read().mediaPosition, 2);
      v().mediaPause();
      v().tickMedia();
      expect(read().mediaPosition, 2);
    });

    test('skipping tracks resets the position', () {
      v().setMediaPlaying(true);
      v().tickMedia();
      v().mediaNext();
      expect(read().mediaPosition, 0);
      expect(read().songTitle, 'Blinding Lights');
    });

    test('the end of a track advances to the next one', () {
      v().setMediaPlaying(true);
      for (var i = 0; i < 257; i++) {
        v().tickMedia();
      }
      expect(read().mediaPosition, 257);
      expect(read().songTitle, 'Nightcall');
      v().tickMedia();
      expect(read().songTitle, 'Blinding Lights');
      expect(read().mediaPosition, 0);
    });

    test('formatSeconds renders M:SS', () {
      expect(formatSeconds(0), '0:00');
      expect(formatSeconds(154), '2:34');
      expect(formatSeconds(258), '4:18');
    });
  });

  group('bluetooth pairing', () {
    test('start sets the code; confirm and cancel clear it with a toast', () {
      v().startPairing();
      expect(read().btPairingCode, VehicleNotifier.mockPairingCode);
      v().confirmPairing();
      expect(read().btPairingCode, '');
      expect(read().btConnected, isTrue);
      expect(toast(), 'Pairing confirmed');
      v().startPairing('111222');
      v().cancelPairing();
      expect(read().btPairingCode, '');
      expect(toast(), 'Pairing cancelled');
    });
  });

  test('locking: the lock lands when the timer completes', () {
    fakeAsync((async) {
      final c2 = ProviderContainer();
      c2.listen(sessionProvider, (_, _) {});
      c2.listen(lockingProvider, (_, _) {});
      c2.read(vehicleProvider.notifier).setConnected(true);
      c2.read(vehicleProvider.notifier).setLocked(false);
      c2.read(lockingProvider.notifier).start();
      expect(c2.read(lockingProvider), isTrue);
      async.elapse(const Duration(milliseconds: 1500));
      expect(c2.read(lockingProvider), isFalse);
      expect(c2.read(vehicleProvider).locked, isTrue);
      c2.dispose();
    });
  });

  group('charger edge cases', () {
    test('unplugging mid-charge toasts; unplugging an idle charger does not', () {
      v().setCharging(true);
      v().setCharging(false);
      expect(toast(), 'Charger disconnected');
      c.read(toastProvider.notifier).dismiss();
      v().setCharging(false);
      expect(toast(), isNull);
    });

    test('charger state leaving "charging" toasts too', () {
      v().setChargerState(ChargingState.charging);
      v().setChargerState(ChargingState.normal);
      expect(toast(), 'Charger disconnected');
    });

    test('hyper and boost chargers use their own time to 80%', () {
      expect(chargeMinutesTo80(read()), 55);
      v().setHyperCharger(true);
      expect(read().hyperMinutesTo80, 25);
      expect(chargeMinutesTo80(read()), 25);
      v().setBoostCharger(true);
      expect(read().isHyperCharger, isFalse);
      expect(chargeMinutesTo80(read()), 40);
      v().setBoostCharger(false);
      expect(chargeMinutesTo80(read()), 55);
    });

    // "Charged" is the vehicle's word, not SOC against our limit.
    test('SOC at 100 % or at the limit does not say "charged" by itself', () {
      const v = VehicleData(isCharging: true, chargingState: ChargingState.charging, batterySoc: 100);
      expect(chargeLabel(v), 'Charging');
      expect(chargeLabel(v.copyWith(batterySoc: 80, chargeLimit: 80)), 'Charging');
      expect(chargeLabel(v.copyWith(chargingState: ChargingState.complete, safeToUnplug: true)), 'Charged. Safe to unplug');
      expect(chargeLabel(v.copyWith(chargingState: ChargingState.complete)), 'Charged');
    });

    test('an idle fast charger reads as initializing', () {
      const v = VehicleData(isCharging: true, chargingState: ChargingState.charging, isBoostCharger: true);
      expect(chargeLabel(v), 'Boost charging');
      expect(chargeLabel(v.copyWith(fcChargeIdle: true)), 'Initializing charger…');
    });

    test('charge times show the clock time they land on, like stock', () {
      final now = DateTime(2026, 11, 10, 23, 50);
      expect(chargeEta(45, now, use24Hour: false), '12:35 AM');
      expect(chargeEta(100, now, use24Hour: true), '01:30');
      expect(chargeEta(0, now, use24Hour: false), '—', reason: 'HHMIS idle value, not midnight');
    });
  });

  group('mode change toast', () {
    test('parked scooter explains when the change applies', () {
      expect(read().vehicleState, VehicleState.parked);
      v().selectDriveMode(DriveMode.sport);
      expect(read().driveMode, DriveMode.sport);
      expect(toast(), 'Mode change applies when riding');
    });

    test('ready scooter just confirms the mode', () {
      v().setVehicleState(VehicleState.ready);
      v().selectDriveMode(DriveMode.eco);
      expect(toast(), 'Drive mode: ECO');
    });
  });

  group('time and date format', () {
    test('12-hour and 24-hour clocks', () {
      expect(formatClock(14, 32, use24Hour: true), '14:32');
      expect(formatClock(14, 32, use24Hour: false), '2:32 PM');
      expect(formatClock(0, 5, use24Hour: false), '12:05 AM');
      expect(formatClock(12, 0, use24Hour: false), '12:00 PM');
      expect(formatClock(9, 7, use24Hour: true), '09:07');
      expect(formatTimeOfDay(const TimeOfDay(hour: 18, minute: 0), use24Hour: false), '6:00 PM');
    });

    test('the vehicle clock follows the setting, 12-hour by default', () {
      expect(read().time, matches(RegExp(r'^\d{1,2}:\d{2} [AP]M$')));
      c.read(use24HourProvider.notifier).set(true);
      expect(read().time, matches(RegExp(r'^\d{2}:\d{2}$')));
      c.read(use24HourProvider.notifier).set(false);
      expect(read().time, matches(RegExp(r'^\d{1,2}:\d{2} [AP]M$')));
    });

    test('lock screen date order', () {
      final d = DateTime(2026, 11, 5);
      expect(formatDate(d), 'Thursday 5 November');
      expect(formatDate(d, order: DateOrder.monthDay), 'Thursday November 5');
      expect(c.read(dateOrderProvider), DateOrder.dayMonth);
      c.read(dateOrderProvider.notifier).set(DateOrder.monthDay);
      expect(c.read(dateOrderProvider), DateOrder.monthDay);
    });
  });

  group('error recovery', () {
    test('report shows a summary and counts a crash; retry clears it', () {
      c.listen(appErrorProvider, (_, _) {});
      final n = c.read(appErrorProvider.notifier);
      n.report(StateError('boom\nsecond line'));
      expect(c.read(appErrorProvider), 'boom');
      expect(c.read(crashRecoveryProvider).consecutiveCrashes, 1);
      n.retry();
      expect(c.read(appErrorProvider), isNull);
    });

    test('capture routes a thrown exception through report', () {
      c.listen(appErrorProvider, (_, _) {});
      c.read(appErrorProvider.notifier).capture(() => throw Exception('Dev panel test error'));
      expect(c.read(appErrorProvider), 'Dev panel test error');
    });

    test('launchers report a missing package', () async {
      final r = c.read(crashRecoveryProvider.notifier);
      await r.launchStockApp();
      expect(toast(), 'Stock dashboard not installed');
      expect(ServiceModeOpen.apps.map((a) => a.$2), contains('com.ola.mfgapp'));
    });
  });

  group('boot timeout', () {
    test('warns at 15s, offers options at 30s, resets once booted', () {
      fakeAsync((async) {
        final c2 = ProviderContainer();
        c2.listen(sessionProvider, (_, _) {});
        c2.listen(bootTimeoutProvider, (_, _) {});
        c2.read(vehicleProvider.notifier).dropConnection();
        expect(c2.read(bootTimeoutProvider), BootTimeout.waiting);
        async.elapse(const Duration(seconds: 15));
        expect(c2.read(bootTimeoutProvider), BootTimeout.slow);
        async.elapse(const Duration(seconds: 15));
        expect(c2.read(bootTimeoutProvider), BootTimeout.options);
        c2.read(sessionProvider.notifier).continueWithoutData();
        expect(c2.read(sessionProvider).booted, isTrue);
        expect(c2.read(sessionProvider).noData, isTrue);
        expect(c2.read(bootTimeoutProvider), BootTimeout.waiting);
        c2.read(vehicleProvider.notifier).setConnected(true);
        expect(c2.read(sessionProvider).noData, isFalse, reason: 'live data clears the badge');
        c2.dispose();
      });
    });

    test('a normal boot never escalates', () {
      fakeAsync((async) {
        final c2 = ProviderContainer();
        c2.listen(sessionProvider, (_, _) {});
        c2.listen(bootTimeoutProvider, (_, _) {});
        async.elapse(const Duration(seconds: 40));
        expect(c2.read(sessionProvider).booted, isTrue);
        expect(c2.read(bootTimeoutProvider), BootTimeout.waiting);
        c2.dispose();
      });
    });
  });

  test('version constant and page count', () {
    expect(appVersion, '0.3.9-beta.3');
    expect(WidgetPage.count, 3);
  });
}
