import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/screen_state.dart';

void main() {
  late ProviderContainer c;
  late VehicleNotifier v;

  setUp(() {
    c = ProviderContainer();
    v = c.read(vehicleProvider.notifier);
    c.listen(sessionProvider, (_, _) {});
    v.setLocked(false);
  });
  tearDown(() => c.dispose());

  ScreenState screen() => c.read(screenStateProvider);

  test('boots until HHMIS connects, then lands parked', () {
    expect(screen(), ScreenState.booting);
    v.setConnected(true);
    expect(screen(), ScreenState.parked);
  });

  test('a fresh scooter boots into the lock screen', () {
    final c2 = ProviderContainer();
    c2.listen(sessionProvider, (_, _) {});
    c2.read(vehicleProvider.notifier).setConnected(true);
    expect(c2.read(screenStateProvider), ScreenState.locked);
    c2.dispose();
  });

  test('mock handshake completes on its own after two seconds', () {
    fakeAsync((async) {
      final c2 = ProviderContainer();
      c2.listen(sessionProvider, (_, _) {});
      expect(c2.read(screenStateProvider), ScreenState.booting);
      async.elapse(const Duration(milliseconds: 1100));
      expect(c2.read(vehicleProvider).trunkStateKnown, isTrue);
      expect(c2.read(screenStateProvider), ScreenState.booting);
      async.elapse(const Duration(seconds: 1));
      expect(c2.read(screenStateProvider), ScreenState.locked);
      c2.dispose();
    });
  });

  test('vehicle state drives the riding screens', () {
    v.setConnected(true);
    v.setVehicleState(VehicleState.ready);
    expect(screen(), ScreenState.ready);
    v.setSpeed(30);
    expect(screen(), ScreenState.riding);
    v.setSpeed(0);
    expect(screen(), ScreenState.ready);
  });

  test('parked stays parked at zero speed', () {
    v.setConnected(true);
    v.setSpeed(0);
    expect(screen(), ScreenState.parked);
    v.setSpeed(10);
    expect(screen(), ScreenState.riding);
  });

  // Observed on a scooter: after a lock-while-charging transition the
  // dashboard showed the charging screen with no visible passcode keypad.
  // Locked wins over charging so the rider can always reach the keypad.
  test('locked wins over charging; charging only shows while unlocked', () {
    v.setConnected(true);
    v.setLocked(true);
    expect(screen(), ScreenState.locked);
    v.setCharging(true);
    expect(screen(), ScreenState.locked,
        reason: 'the passcode keypad must stay visible even while charging');
    v.setLocked(false);
    expect(screen(), ScreenState.charging,
        reason: 'once unlocked, the charging screen takes over');
    v.setCharging(false);
    expect(screen(), ScreenState.parked);
  });

  test('sleep and wake', () {
    v.setConnected(true);
    c.read(sessionProvider.notifier).sleep();
    expect(screen(), ScreenState.sleep);
    c.read(sessionProvider.notifier).wake();
    expect(screen(), ScreenState.parked);
  });

  test('losing HHMIS mid-ride does not return to the boot screen', () {
    v.setConnected(true);
    v.setSpeed(40);
    v.setConnected(false);
    expect(screen(), ScreenState.riding);
    expect(c.read(vehicleProvider).speed, 40);
  });

  test('reboot shows the splash again and reconnects', () {
    fakeAsync((async) {
      final c2 = ProviderContainer();
      c2.listen(sessionProvider, (_, _) {});
      c2.read(vehicleProvider.notifier).setConnected(true);
      c2.read(vehicleProvider.notifier).setLocked(false);
      expect(c2.read(screenStateProvider), ScreenState.parked);
      c2.read(sessionProvider.notifier).reboot();
      expect(c2.read(screenStateProvider), ScreenState.booting);
      expect(c2.read(vehicleProvider).trunkStateKnown, isFalse);
      async.elapse(const Duration(seconds: 2));
      expect(c2.read(screenStateProvider), ScreenState.parked);
      c2.dispose();
    });
  });
}
