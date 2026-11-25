import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/constants.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/alert_state.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/overlay_state.dart';
import 'package:opendash/state/toast_state.dart';

void main() {
  void withApp(void Function(FakeAsync async, ProviderContainer c, VehicleNotifier v) body) {
    fakeAsync((async) {
      final c = ProviderContainer();
      c.listen(toastProvider, (_, _) {});
      c.listen(dismissedAlertsProvider, (_, _) {});
      c.listen(alertCycleProvider, (_, _) {});
      c.listen(settingsScreenOpenProvider, (_, _) {});
      c.listen(overlayToolbarVisibleProvider, (_, _) {});
      final v = c.read(vehicleProvider.notifier);
      v.setConnected(true);
      body(async, c, v);
      c.dispose();
    });
  }

  group('constants', () {
    test('stock dashboard package is the HMI client, not the Kanzi SDK', () {
      expect(stockDashboardPackage, 'com.olaelectric.hmiclient');
    });

    test('repo url carries the opendash name', () {
      expect(repoUrl, 'github.com/abhijithvijayan/opendash');
      expect(issuesUrl, 'github.com/abhijithvijayan/opendash/issues');
    });
  });

  group('defaults', () {
    test('reject with message is off until enabled, with the longer text', () {
      expect(const VehicleData().rejectCallAllowed, isFalse);
      expect(const VehicleData().rejectCallText, "Hey, I'm riding. I'll call you back later");
      withApp((async, c, v) {
        expect(c.read(vehicleProvider).rejectCallAllowed, isFalse);
        v.simulateIncomingCall();
        v.rejectCallWithMessage();
        expect(c.read(vehicleProvider).callIncoming, isTrue, reason: 'gated off by default');
      });
    });

    test('low beam is off at boot', () {
      withApp((async, c, v) {
        expect(c.read(vehicleProvider).lowBeam, isFalse);
        expect(c.read(vehicleProvider).highBeam, isFalse);
      });
    });
  });

  group('lights', () {
    test('position light toggles on its own and announces itself', () {
      withApp((async, c, v) {
        v.setPositionLight(false);
        v.togglePositionLight();
        expect(c.read(vehicleProvider).positionLight, isTrue);
        expect(c.read(toastProvider)?.message, 'Position light on');
        v.togglePositionLight();
        expect(c.read(vehicleProvider).positionLight, isFalse);
        expect(c.read(toastProvider)?.message, 'Position light off');
      });
    });

    test('cycleLights toggles the position light while parked and leaves the headlamp alone', () {
      withApp((async, c, v) {
        v.setLocked(false);
        v.setPositionLight(false);
        v.cycleLights();
        var s = c.read(vehicleProvider);
        expect(s.positionLight, isTrue);
        expect(s.lowBeam, isFalse);
        expect(s.highBeam, isFalse);
        v.cycleLights();
        s = c.read(vehicleProvider);
        expect(s.positionLight, isFalse);
        expect(s.lowBeam, isFalse);
      });
    });

    test('riding start lights the low beam and the position light', () {
      withApp((async, c, v) {
        v.setLocked(false);
        v.setPositionLight(false);
        v.setSpeed(20);
        final s = c.read(vehicleProvider);
        expect(s.vehicleState, VehicleState.riding);
        expect(s.lowBeam, isTrue);
        expect(s.highBeam, isFalse);
        expect(s.positionLight, isTrue);
      });
    });

    test('cycleLights swaps low and high beam while riding', () {
      withApp((async, c, v) {
        v.setLocked(false);
        v.setSpeed(20);
        v.cycleLights();
        var s = c.read(vehicleProvider);
        expect(s.highBeam, isTrue);
        expect(s.lowBeam, isFalse);
        expect(s.positionLight, isTrue, reason: 'position light stays on while riding');
        v.cycleLights();
        s = c.read(vehicleProvider);
        expect(s.highBeam, isFalse);
        expect(s.lowBeam, isTrue);
      });
    });

    test('a high beam set before moving survives the riding transition', () {
      withApp((async, c, v) {
        v.setLocked(false);
        v.setVehicleState(VehicleState.ready);
        v.setHighBeam(true);
        v.setSpeed(20);
        final s = c.read(vehicleProvider);
        expect(s.highBeam, isTrue);
        expect(s.lowBeam, isFalse);
      });
    });

    test('ready state and unlock turn the position light on; the low beam waits for riding', () {
      withApp((async, c, v) {
        v.setLocked(true);
        v.setPositionLight(false);
        v.setLocked(false);
        expect(c.read(vehicleProvider).positionLight, isTrue, reason: 'auto-enables after unlock');
        v.setPositionLight(false);
        v.setVehicleState(VehicleState.ready);
        final s = c.read(vehicleProvider);
        expect(s.positionLight, isTrue);
        expect(s.lowBeam, isFalse);
      });
    });

    test('the demo ride lights the low beam when it sets off', () {
      withApp((async, c, v) {
        v.setLocked(false);
        v.setVehicleState(VehicleState.ready);
        v.setDemo(true);
        async.elapse(const Duration(seconds: 6));
        final s = c.read(vehicleProvider);
        expect(s.speed, greaterThan(0));
        expect(s.lowBeam, isTrue);
        expect(s.positionLight, isTrue);
        v.setDemo(false);
      });
    });

    test('parking and locking put the headlamp out', () {
      withApp((async, c, v) {
        v.setLocked(false);
        v.setSpeed(20);
        v.toggleHighBeam();
        v.setSpeed(0);
        expect(c.read(vehicleProvider).highBeam, isTrue, reason: 'a stop keeps the lights');
        v.autoPark();
        var s = c.read(vehicleProvider);
        expect(s.lowBeam, isFalse);
        expect(s.highBeam, isFalse);
        expect(s.positionLight, isTrue, reason: 'the halo stays while unlocked');
        v.setSpeed(20);
        v.setLocked(true);
        s = c.read(vehicleProvider);
        expect(s.lowBeam, isFalse);
        expect(s.highBeam, isFalse);
        expect(s.positionLight, isFalse);
      });
    });
  });

  group('lights follow settings and the charger', () {
    test('auto headlight off leaves the low beam alone at riding start', () {
      withApp((async, c, v) {
        v.setLocked(false);
        c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoHeadlight, false);
        v.setSpeed(20);
        final s = c.read(vehicleProvider);
        expect(s.lowBeam, isFalse);
        expect(s.highBeam, isFalse);
        expect(s.positionLight, isTrue, reason: 'the halo is not the headlight');
      });
    });

    test('plugging in puts the headlamp out and unplugging leaves it out', () {
      withApp((async, c, v) {
        v.setLocked(false);
        v.setSpeed(20);
        v.setSpeed(0);
        expect(c.read(vehicleProvider).lowBeam, isTrue);
        v.setCharging(true);
        var s = c.read(vehicleProvider);
        expect(s.lowBeam, isFalse);
        expect(s.highBeam, isFalse);
        v.setCharging(false);
        s = c.read(vehicleProvider);
        expect(s.vehicleState, VehicleState.parked);
        expect(s.lowBeam, isFalse);
        v.setSpeed(20);
        v.toggleHighBeam();
        v.setSpeed(0);
        v.setChargerState(ChargingState.charging);
        expect(c.read(vehicleProvider).highBeam, isFalse);
        v.setChargerState(ChargingState.normal);
        expect(c.read(vehicleProvider).highBeam, isFalse);
      });
    });
  });

  group('alerts inside a menu', () {
    test('a warning does not buzz until the overlay closes', () {
      final buzzes = <AlertPriority>[];
      DismissedAlerts.onHaptic = buzzes.add;
      try {
        withApp((async, c, v) {
          v.setLocked(false);
          c.read(settingsScreenOpenProvider.notifier).open();
          expect(c.read(overlayToolbarVisibleProvider), isTrue);
          v.setBrakeWorn(true);
          expect(buzzes, isEmpty, reason: 'nothing on screen to explain a buzz');
          v.setLimpMode(true);
          expect(buzzes, [AlertPriority.critical], reason: 'criticals still interrupt');
          c.read(settingsScreenOpenProvider.notifier).close();
          // Riverpod rebuilds dependents on its scheduler, which fake_async holds.
          async.elapse(Duration.zero);
          expect(buzzes, [AlertPriority.critical, AlertPriority.warning], reason: 'the warning buzzes as it surfaces');
        });
      } finally {
        DismissedAlerts.onHaptic = null;
      }
    });
  });

  group('handlebar hint', () {
    test('unlocking raises no alert', () {
      withApp((async, c, v) {
        v.setLocked(true);
        v.setLocked(false);
        expect(c.read(visibleAlertsProvider), isEmpty);
        async.elapse(const Duration(seconds: 1));
        expect(c.read(visibleAlertsProvider), isEmpty);
      });
    });

    test('the alert kind no longer exists', () {
      expect(AlertKind.values.map((k) => k.name), isNot(contains('handlebarUnlock')));
    });
  });
}
