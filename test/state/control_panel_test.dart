import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/control_panel.dart';
import 'package:opendash/state/riding_lockout.dart';
import 'package:opendash/state/screen_state.dart';

void main() {
  late ProviderContainer c;
  late VehicleNotifier v;

  setUp(() {
    c = ProviderContainer();
    v = c.read(vehicleProvider.notifier);
    c.listen(sessionProvider, (_, _) {});
    c.listen(controlPanelOpenProvider, (_, _) {});
    c.listen(lockConfirmProvider, (_, _) {});
    v.setConnected(true);
    v.setLocked(false);
  });
  tearDown(() => c.dispose());

  VehicleData read() => c.read(vehicleProvider);

  group('panel open state', () {
    test('toggles and closes', () {
      final p = c.read(controlPanelOpenProvider.notifier);
      expect(c.read(controlPanelOpenProvider), isFalse);
      p.toggle();
      expect(c.read(controlPanelOpenProvider), isTrue);
      p.close();
      expect(c.read(controlPanelOpenProvider), isFalse);
    });

    test('closes on screen transition', () {
      c.read(controlPanelOpenProvider.notifier).toggle();
      v.setCharging(true);
      expect(c.read(screenStateProvider), ScreenState.charging);
      expect(c.read(controlPanelOpenProvider), isFalse);
    });
  });

  group('indicator commands', () {
    test('left clears right and toggles off again', () {
      fakeAsync((async) {
        v.setTurnRight(true);
        v.toggleLeftIndicator();
        expect(read().turnLeft, isTrue);
        expect(read().turnRight, isFalse);
        async.elapse(VehicleNotifier.indicatorThrottle);
        v.toggleLeftIndicator();
        expect(read().turnLeft, isFalse);
      });
    });

    test('right clears left', () {
      v.toggleLeftIndicator();
      v.toggleRightIndicator();
      expect(read().turnRight, isTrue);
      expect(read().turnLeft, isFalse);
    });

    test('hazard toggles both', () {
      fakeAsync((async) {
        v.toggleHazard();
        expect(read().turnLeft && read().turnRight, isTrue);
        expect(v.hazardOn, isTrue);
        async.elapse(VehicleNotifier.indicatorThrottle);
        v.toggleHazard();
        expect(read().turnLeft || read().turnRight, isFalse);
      });
    });

    test('left while hazard is on leaves only left', () {
      v.toggleHazard();
      v.toggleLeftIndicator();
      expect(read().turnLeft, isTrue);
      expect(read().turnRight, isFalse);
      expect(v.hazardOn, isFalse);
    });

    test('high beam toggles and swaps low beam', () {
      v.toggleHighBeam();
      expect(read().highBeam, isTrue);
      expect(read().lowBeam, isFalse);
      v.toggleHighBeam();
      expect(read().highBeam, isFalse);
      expect(read().lowBeam, isTrue);
    });
  });

  group('trunk and lock', () {
    test('trunk toggle is ignored until the state is known', () {
      v.setConnected(false);
      v.simulateBoot();
      expect(read().trunkStateKnown, isFalse);
      v.toggleTrunk();
      expect(read().trunkOpen, isFalse);
      v.setConnected(true);
      v.toggleTrunk();
      expect(read().trunkOpen, isTrue);
    });

    test('lock confirmation: arm, confirm within window, lock lands after the animation', () {
      fakeAsync((async) {
        final c2 = ProviderContainer();
        c2.listen(sessionProvider, (_, _) {});
        c2.listen(lockConfirmProvider, (_, _) {});
        c2.listen(lockingProvider, (_, _) {});
        c2.read(vehicleProvider.notifier).setConnected(true);
        c2.read(vehicleProvider.notifier).setLocked(false);
        final lock = c2.read(lockConfirmProvider.notifier);
        lock.tap();
        expect(c2.read(lockConfirmProvider), isTrue);
        expect(c2.read(vehicleProvider).locked, isFalse);
        lock.tap();
        expect(c2.read(lockConfirmProvider), isFalse);
        expect(c2.read(lockingProvider), isTrue);
        expect(c2.read(vehicleProvider).locked, isFalse, reason: 'lock is in flight');
        async.elapse(const Duration(milliseconds: 1400));
        expect(c2.read(vehicleProvider).locked, isFalse);
        async.elapse(const Duration(milliseconds: 200));
        expect(c2.read(lockingProvider), isFalse);
        expect(c2.read(vehicleProvider).locked, isTrue);
        c2.dispose();
      });
    });

    test('lock confirmation times out after two seconds', () {
      fakeAsync((async) {
        final c2 = ProviderContainer();
        c2.listen(sessionProvider, (_, _) {});
        c2.listen(lockConfirmProvider, (_, _) {});
        c2.read(vehicleProvider.notifier).setConnected(true);
        c2.read(vehicleProvider.notifier).setLocked(false);
        c2.read(lockConfirmProvider.notifier).tap();
        async.elapse(const Duration(milliseconds: 1900));
        expect(c2.read(lockConfirmProvider), isTrue);
        async.elapse(const Duration(milliseconds: 200));
        expect(c2.read(lockConfirmProvider), isFalse);
        c2.read(lockConfirmProvider.notifier).tap();
        expect(c2.read(vehicleProvider).locked, isFalse, reason: 'first tap only arms');
        c2.dispose();
      });
    });
  });

  group('riding lockout', () {
    test('tracks speed', () {
      expect(c.read(ridingLockoutProvider), isFalse);
      v.setSpeed(12);
      expect(c.read(ridingLockoutProvider), isTrue);
      v.setSpeed(0);
      expect(c.read(ridingLockoutProvider), isFalse);
    });

    test('reverse is refused while moving', () {
      v.setSpeed(12);
      v.activateReverse();
      expect(read().speed, 12);
    });
  });
}
