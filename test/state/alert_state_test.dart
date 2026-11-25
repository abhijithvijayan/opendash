import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/state/alert_state.dart';
import 'package:opendash/state/overlay_state.dart';
import 'package:opendash/state/settings_state.dart';

void main() {
  void withAlerts(void Function(FakeAsync async, ProviderContainer c, VehicleNotifier v) body) {
    fakeAsync((async) {
      final c = ProviderContainer();
      c.listen(dismissedAlertsProvider, (_, _) {});
      c.listen(alertCycleProvider, (_, _) {});
      final v = c.read(vehicleProvider.notifier);
      v.setConnected(true);
      v.setLocked(false);
      // Unlocking raises the handlebar hint; let it expire first.
      async.elapse(const Duration(seconds: 5));
      body(async, c, v);
      c.dispose();
    });
  }

  List<AlertKind> visible(ProviderContainer c) =>
      c.read(visibleAlertsProvider).map((a) => a.kind).toList();

  test('dismissing a warning hides it until the condition cycles', () {
    withAlerts((async, c, v) {
      v.setBattery(8);
      expect(visible(c), [AlertKind.lowBattery]);
      c.read(dismissedAlertsProvider.notifier).dismiss(AlertKind.lowBattery);
      expect(visible(c), isEmpty);
      v.setBattery(7);
      expect(visible(c), isEmpty, reason: 'still the same condition cycle');
      v.setBattery(12);
      expect(c.read(dismissedAlertsProvider), isEmpty);
      v.setBattery(8);
      expect(visible(c), [AlertKind.lowBattery]);
    });
  });

  test('info alerts dismiss themselves after four seconds', () {
    withAlerts((async, c, v) {
      v.setCharging(true);
      v.setBattery(100);
      expect(visible(c), [AlertKind.chargingComplete]);
      async.elapse(const Duration(milliseconds: 3900));
      expect(visible(c), [AlertKind.chargingComplete]);
      async.elapse(const Duration(milliseconds: 200));
      expect(visible(c), isEmpty);
      // The charge status drops to "charging" and back on
      // every wake of a full scooter; one announcement per plug-in.
      v.setBattery(90);
      v.setBattery(100);
      expect(visible(c), isEmpty, reason: 'once per plug-in');
      v.setCharging(false);
      v.setCharging(true);
      v.setBattery(100);
      expect(visible(c), [AlertKind.chargingComplete], reason: 'a new plug-in announces again');
    });
  });

  test('critical alerts cannot be hidden by auto-dismiss logic', () {
    withAlerts((async, c, v) {
      v.setLimpMode(true);
      async.elapse(const Duration(seconds: 10));
      expect(visible(c), [AlertKind.limpMode]);
    });
  });

  test('queue orders critical first; the critical is pinned, the rest cycle', () {
    withAlerts((async, c, v) {
      v.setBrakeWorn(true);
      v.setDerating(true);
      v.setLimpMode(true);
      expect(visible(c), [AlertKind.limpMode, AlertKind.deratingActive, AlertKind.brakeWorn]);
      expect(c.read(alertCycleProvider), 0);
      async.elapse(const Duration(seconds: 10));
      expect(c.read(alertCycleProvider), 0, reason: 'critical never rotates away on its own');
      c.read(alertCycleProvider.notifier).next();
      expect(c.read(alertCycleProvider), 1);
      async.elapse(const Duration(seconds: 5));
      expect(c.read(alertCycleProvider), 2, reason: 'warnings still cycle');
      async.elapse(const Duration(seconds: 5));
      expect(c.read(alertCycleProvider), 0);
      async.elapse(const Duration(seconds: 5));
      expect(c.read(alertCycleProvider), 0, reason: 'back on the critical it stays');
    });
  });

  test('swiping restarts the auto-cycle clock and wraps', () {
    withAlerts((async, c, v) {
      v.setBrakeWorn(true);
      v.setDerating(true);
      async.elapse(const Duration(seconds: 4));
      c.read(alertCycleProvider.notifier).next();
      expect(c.read(alertCycleProvider), 1);
      async.elapse(const Duration(seconds: 4));
      expect(c.read(alertCycleProvider), 1, reason: 'clock restarted on swipe');
      c.read(alertCycleProvider.notifier).previous();
      expect(c.read(alertCycleProvider), 0);
      c.read(alertCycleProvider.notifier).previous();
      expect(c.read(alertCycleProvider), 1);
    });
  });

  // A held vehicle notice (every emitted
  // DashAlert of kind vehicleNotice is held - non-held commands go out
  // as toasts, not alerts) must not be auto-dismissed after 4 s. Stock
  // shows them until the next command or the clearing one (0).
  // Start-refusal hints (brakeToStart,
  // standToRide, driveModeInPark) show for ~3 s every time the
  // condition fires, not once per session.
  test('start-refusal hints show again each time the condition fires', () {
    withAlerts((async, c, v) {
      v.showBrakeHint();
      expect(c.read(visibleAlertsProvider).map((a) => a.kind), contains(AlertKind.brakeToStart));
      // Info alert auto-dismiss fires at ~4 s; let the hint's 5 s flash
      // also expire so the condition actually cycles.
      async.elapse(const Duration(seconds: 6));
      expect(c.read(visibleAlertsProvider), isEmpty);
      v.showBrakeHint();
      expect(c.read(visibleAlertsProvider).map((a) => a.kind), contains(AlertKind.brakeToStart),
          reason: 'fires again on the next press');
    });
  });

  test('held vehicle notices do not auto-dismiss', () {
    withAlerts((async, c, v) {
      v.setNotice(VehicleNotice(111, 'Battery critical', '', AlertPriority.info));
      expect(c.read(visibleAlertsProvider).map((a) => a.kind), contains(AlertKind.vehicleNotice));
      async.elapse(DismissedAlerts.infoAutoDismiss + const Duration(seconds: 1));
      expect(c.read(visibleAlertsProvider).map((a) => a.kind), contains(AlertKind.vehicleNotice),
          reason: 'held notices stay until the next command or 0');
    });
  });

  // Notice identity is the command ordinal, not the
  // AlertKind. Dismissing 142 must not mask 107 (a different notice) or
  // generic fault / "Power reduced" banners.
  group('vehicle notice masking is keyed by command', () {
    // Any held VehicleCommand ordinal produces a notice; the ordinal is
    // the identity we're testing, so the title/body don't matter here.
    void sendNotice(VehicleNotifier v, int ordinal) => v.setNotice(
        VehicleNotice(ordinal, 'n$ordinal', '', AlertPriority.warning));

    void dismissActiveNotice(ProviderContainer c) =>
        c.read(dismissedAlertsProvider.notifier).dismissAlert(
            c.read(activeAlertsProvider).firstWhere((a) => a.kind == AlertKind.vehicleNotice));

    test('dismissing 142 does not suppress 107', () {
      withAlerts((async, c, v) {
        sendNotice(v, 142);
        expect(visible(c), [AlertKind.vehicleNotice]);
        dismissActiveNotice(c);
        expect(visible(c), isEmpty);
        sendNotice(v, 107);
        expect(visible(c), contains(AlertKind.vehicleNotice),
            reason: '107 is a different notice identity; it must show');
      });
    });

    test('dismissing 142 does not suppress 13 (another notice)', () {
      withAlerts((async, c, v) {
        sendNotice(v, 142);
        dismissActiveNotice(c);
        sendNotice(v, 13);
        expect(visible(c), contains(AlertKind.vehicleNotice));
      });
    });

    test('dismissing 13 does not suppress a later 107', () {
      withAlerts((async, c, v) {
        sendNotice(v, 13);
        dismissActiveNotice(c);
        sendNotice(v, 107);
        expect(visible(c), contains(AlertKind.vehicleNotice));
      });
    });
  });

  // A countdown notice rewrites its text each second.
  // That is one alert: one buzz, one banner log, and a dismissal that holds.
  test('a countdown notice ticking is the same alert', () {
    withAlerts((async, c, v) {
      AnalyticsLogger.instance.resetForTest();
      final buzzes = <AlertPriority>[];
      DismissedAlerts.onHaptic = buzzes.add;
      VehicleNotice at(int s) => VehicleNotice(9, 'Overheating', 'Switching to Park in $s s', AlertPriority.warning);
      v.setNotice(at(10));
      v.setNotice(at(9));
      v.setNotice(at(8));
      expect(c.read(visibleAlertsProvider).single.body, 'Switching to Park in 8 s');
      expect(buzzes, [AlertPriority.warning]);
      expect(AnalyticsLogger.instance.recent('modal', 'show'), hasLength(1));
      c.read(dismissedAlertsProvider.notifier).dismissAlert(c.read(activeAlertsProvider).single);
      v.setNotice(at(7));
      expect(visible(c), isEmpty, reason: 'still the notice the rider dismissed');
      v.setNotice(null);
      expect(c.read(dismissedAlertsProvider), isEmpty);
      DismissedAlerts.onHaptic = null;
    });
  });

  // Command 59 with Diagnostics open showed nothing.
  test('inside a menu a refused start still shows; other infos and warnings wait', () {
    withAlerts((async, c, v) {
      AnalyticsLogger.instance.resetForTest();
      c.read(settingsScreenOpenProvider.notifier).open();
      expect(c.read(overlayToolbarVisibleProvider), isTrue);
      v.setBrakeWorn(true);
      v.showModeHint();
      expect(visible(c), isEmpty);
      v.showStandHint();
      expect(visible(c), [AlertKind.standToRide]);
      v.showBrakeHint();
      v.showUnplugHint();
      expect(visible(c), unorderedEquals([AlertKind.standToRide, AlertKind.brakeToStart, AlertKind.unplugChargerToRide]));
      final shown = AnalyticsLogger.instance.recent('modal', 'show').map((e) => (e['data']! as Map)['kind']);
      expect(shown, unorderedEquals(['standToRide', 'brakeToStart', 'unplugChargerToRide']));
      async.elapse(VehicleNotifier.hintDuration);
      expect(visible(c), isEmpty);
      c.read(settingsScreenOpenProvider.notifier).close();
      expect(visible(c), [AlertKind.brakeWorn]);
    });
  });

  test('index clamps when alerts clear', () {
    withAlerts((async, c, v) {
      v.setBrakeWorn(true);
      v.setDerating(true);
      c.read(alertCycleProvider.notifier).next();
      expect(c.read(alertCycleProvider), 1);
      v.setBrakeWorn(false);
      expect(c.read(alertCycleProvider), 0);
      v.setDerating(false);
      expect(visible(c), isEmpty);
      expect(c.read(alertCycleProvider), 0);
    });
  });
}
