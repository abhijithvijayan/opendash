import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/alert_state.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/profile_state.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:opendash/theme/colors.dart';
import 'package:opendash/widgets/indicators/telltale_strip.dart';

void main() {
  void withApp(void Function(FakeAsync async, ProviderContainer c, VehicleNotifier v) body) {
    fakeAsync((async) {
      final c = ProviderContainer();
      for (final p in [
        sessionProvider, toastProvider, dismissedAlertsProvider, alertCycleProvider,
        crashRecoveryProvider, serviceModeOpenProvider, diagnosticsOpenProvider,
      ]) {
        c.listen(p, (_, _) {});
      }
      final v = c.read(vehicleProvider.notifier);
      v.setConnected(true);
      v.setLocked(false);
      async.elapse(const Duration(seconds: 5));
      body(async, c, v);
      c.dispose();
    });
  }

  String? toast(ProviderContainer c) => c.read(toastProvider)?.message;
  List<AlertKind> visible(ProviderContainer c) => c.read(visibleAlertsProvider).map((a) => a.kind).toList();

  group('speed limit', () {
    test('alert fires over the limit, clears under it, and re-arms after dismissal', () {
      withApp((async, c, v) {
        final r = c.read(ridingSettingsProvider.notifier);
        r.setSpeedLimitEnabled(true);
        r.setSpeedLimit(40);
        v.setSpeed(40);
        expect(visible(c), isNot(contains(AlertKind.speedLimitExceeded)));
        v.setSpeed(41);
        expect(visible(c), contains(AlertKind.speedLimitExceeded));
        final alert = c.read(visibleAlertsProvider).firstWhere((a) => a.kind == AlertKind.speedLimitExceeded);
        expect(alert.priority, AlertPriority.warning);
        expect(alert.body, contains('40 km/h'));
        c.read(dismissedAlertsProvider.notifier).dismiss(AlertKind.speedLimitExceeded);
        expect(visible(c), isEmpty);
        v.setSpeed(30);
        v.setSpeed(60);
        expect(visible(c), contains(AlertKind.speedLimitExceeded), reason: 'condition cycled');
        r.setSpeedLimitEnabled(false);
        expect(visible(c), isEmpty);
      });
    });

    test('limit clamps to 30-120', () {
      withApp((async, c, v) {
        final r = c.read(ridingSettingsProvider.notifier);
        r.setSpeedLimit(5);
        expect(c.read(ridingSettingsProvider).speedLimit, 30);
        r.setSpeedLimit(500);
        expect(c.read(ridingSettingsProvider).speedLimit, 120);
      });
    });

    test('tell-tale shows the limit and turns amber when exceeded', () {
      expect(speedLimitTelltale(const VehicleData(speed: 10), RidingSettings(speedLimitEnabled: false)), isNull);
      expect(speedLimitTelltale(const VehicleData(speed: 10), RidingSettings()), isNotNull, reason: 'on at 80 by default');
      final under = speedLimitTelltale(const VehicleData(speed: 50), RidingSettings(speedLimitEnabled: true, speedLimit: 80))!;
      expect(under.label, '80');
      expect(under.color, DashColors.ash);
      final over = speedLimitTelltale(const VehicleData(speed: 90), RidingSettings(speedLimitEnabled: true, speedLimit: 80))!;
      expect(over.color, DashColors.warning);
    });
  });

  group('profile', () {
    test('mock data and deferred editing', () {
      withApp((async, c, v) {
        final p = c.read(profileProvider);
        expect(p.name, 'Owner');
        expect(p.registrationNumber, 'KL 01 AB 1234');
        expect(p.isPrimary, isTrue);
        c.read(profileProvider.notifier).requestEdit();
        expect(toast(c), 'Editing requires a keyboard (Phase 2)');
        c.read(profileProvider.notifier).setScooterName('Bolt');
        expect(c.read(profileProvider).scooterName, 'Bolt');
      });
    });
  });

  group('crash recovery', () {
    test('three crashes enter safe mode; retry clears; a stable boot resets the count', () {
      withApp((async, c, v) {
        final r = c.read(crashRecoveryProvider.notifier);
        r.recordCrash();
        r.recordCrash();
        expect(c.read(crashRecoveryProvider).safeMode, isFalse);
        r.recordCrash();
        expect(c.read(crashRecoveryProvider).safeMode, isTrue);
        expect(c.read(crashRecoveryProvider).lastCrash, isNotNull);
        r.retry();
        expect(c.read(crashRecoveryProvider).safeMode, isFalse);
        expect(c.read(crashRecoveryProvider).consecutiveCrashes, 0);
        r.recordCrash();
        v.setConnected(false);
        v.setConnected(true);
        async.elapse(const Duration(seconds: 11));
        expect(c.read(crashRecoveryProvider).consecutiveCrashes, 0);
        r.enterSafeMode();
        expect(c.read(crashRecoveryProvider).safeMode, isTrue);
        r.launchStockApp();
        async.flushMicrotasks();
        expect(toast(c), 'Stock dashboard not installed');
      });
    });
  });

  group('service and diagnostics', () {
    test('service mode closes on riding; diagnostics rides but refuses to open at speed, and closes on lock', () {
      withApp((async, c, v) {
        final s = c.read(serviceModeOpenProvider.notifier);
        s.open();
        expect(c.read(serviceModeOpenProvider), isTrue);
        s.launch('com.ola.mfgapp');
        async.flushMicrotasks();
        expect(toast(c), 'Could not launch com.ola.mfgapp');
        v.setSpeed(30);
        expect(c.read(serviceModeOpenProvider), isFalse, reason: 'closes the moment the scooter moves');
        v.setSpeed(0);
        s.open();
        s.close();
        expect(c.read(serviceModeOpenProvider), isFalse);

        // Diagnostics is the one overlay that rides: opened stopped, it stays
        // up on the move (the island shows the speedo over it), but it never
        // opens at speed, and it still closes on lock.
        final d = c.read(diagnosticsOpenProvider.notifier);
        d.open();
        expect(c.read(diagnosticsOpenProvider), isTrue);
        v.setSpeed(40);
        expect(c.read(diagnosticsOpenProvider), isTrue, reason: 'it rides: stays open on the move');
        // Closed by hand, it will not reopen until the scooter is stopped.
        d.close();
        d.open();
        expect(c.read(diagnosticsOpenProvider), isFalse, reason: 'and it does not open at speed');
        v.setSpeed(0);
        d.open();
        expect(c.read(diagnosticsOpenProvider), isTrue);
        v.setLocked(true);
        expect(c.read(diagnosticsOpenProvider), isFalse, reason: 'but still closes on lock');
      });
    });
  });
}
