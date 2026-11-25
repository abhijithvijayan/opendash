import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/theme/colors.dart';

void main() {
  late ProviderContainer container;
  late VehicleNotifier notifier;

  setUp(() {
    container = ProviderContainer();
    notifier = container.read(vehicleProvider.notifier);
  });
  tearDown(() => container.dispose());

  VehicleData read() => container.read(vehicleProvider);

  test('starts parked, locked, disconnected, with a plausible battery', () {
    expect(read().vehicleState, VehicleState.parked);
    expect(read().locked, isTrue);
    expect(read().hhmisConnected, isFalse);
    expect(read().batterySoc, inInclusiveRange(1, 100));
    expect(read().range, greaterThan(0));
  });

  test('verifyPasscode unlocks on the mock PIN and counts failures', () {
    expect(notifier.verifyPasscode('000000'), (false, 4));
    expect(notifier.verifyPasscode('111111'), (false, 3));
    expect(read().locked, isTrue);
    expect(notifier.verifyPasscode('123456'), (true, 5));
    expect(read().locked, isFalse);
    expect(notifier.passcodeAttemptsRemaining, 5);
  });

  test('verifyPasscode wraps the counter after the fifth failure', () {
    for (var i = 4; i >= 1; i--) {
      expect(notifier.verifyPasscode('000000'), (false, i));
    }
    expect(notifier.verifyPasscode('000000'), (false, 0));
    expect(notifier.passcodeAttemptsRemaining, 5);
  });

  test('setSpeed clamps to the contract range', () {
    notifier.setSpeed(200);
    expect(read().speed, 115);
    notifier.setSpeed(-5);
    expect(read().speed, 0);
  });

  test('selectDriveMode is a no-op while moving', () {
    notifier.setVehicleState(VehicleState.ready);
    notifier.selectDriveMode(DriveMode.eco);
    expect(read().driveMode, DriveMode.eco);
    notifier.setSpeed(30);
    notifier.selectDriveMode(DriveMode.hyper);
    expect(read().driveMode, DriveMode.eco, reason: 'a bumped row mid-corner must not change throttle response');
    notifier.setSpeed(0);
    notifier.selectDriveMode(DriveMode.hyper);
    expect(read().driveMode, DriveMode.hyper);
  });

  test('indicator taps within 150 ms coalesce; the next window toggles again', () {
    fakeAsync((async) {
      final c = ProviderContainer();
      final n = c.read(vehicleProvider.notifier);
      n.toggleLeftIndicator();
      n.toggleLeftIndicator();
      expect(c.read(vehicleProvider).turnLeft, isTrue, reason: 'the bounce does not cancel the first tap');
      async.elapse(VehicleNotifier.indicatorThrottle);
      n.toggleLeftIndicator();
      expect(c.read(vehicleProvider).turnLeft, isFalse);
      n.toggleHazard();
      n.toggleHazard();
      expect(n.hazardOn, isTrue);
      n.toggleRightIndicator();
      n.toggleRightIndicator();
      expect(c.read(vehicleProvider).turnRight, isTrue);
      expect(c.read(vehicleProvider).turnLeft, isFalse);
      c.dispose();
    });
  });

  test('moving sets riding state, stopping returns to ready', () {
    notifier.setSpeed(30);
    expect(read().vehicleState, VehicleState.riding);
    notifier.setSpeed(0);
    expect(read().vehicleState, VehicleState.ready);
  });

  test('unplugging the charger leaves the scooter parked', () {
    notifier.setCharging(true);
    notifier.setCharging(false);
    expect(read().vehicleState, VehicleState.parked);
  });

  test('status fields clamp and toggle', () {
    notifier.setSignalBars(9);
    expect(read().signalBars, 4);
    notifier.setWifi(false);
    notifier.setGps(false);
    notifier.setNotification(true);
    expect(read().wifiConnected, isFalse);
    expect(read().gpsFix, isFalse);
    expect(read().hasNotification, isTrue);
  });

  test('setBattery clamps and recomputes range by mode', () {
    notifier.setDriveMode(DriveMode.eco);
    notifier.setBattery(50);
    final eco = read().range;
    notifier.setDriveMode(DriveMode.hyper);
    expect(read().range, lessThan(eco));
    notifier.setBattery(500);
    expect(read().batterySoc, 100);
  });

  test('charging toggles state and accent', () {
    notifier.setCharging(true);
    expect(read().isCharging, isTrue);
    expect(read().vehicleState, VehicleState.charging);
    expect(container.read(accentProvider), DashColors.charging);
    notifier.setCharging(false);
    expect(read().vehicleState, VehicleState.parked);
  });

  test('media toggle populates sample track', () {
    notifier.setMediaPlaying(true);
    expect(read().songTitle, isNotEmpty);
    expect(read().btConnected, isTrue);
  });

  test('turn signals are mutually exclusive', () {
    notifier.setTurnLeft(true);
    notifier.setTurnRight(true);
    expect(read().turnLeft, isFalse);
    expect(read().turnRight, isTrue);
  });

  test('accent follows drive mode while riding', () {
    notifier.setLocked(false);
    notifier.setSpeed(20);
    notifier.setDriveMode(DriveMode.sport);
    expect(container.read(accentProvider), DashColors.sport);
  });

  test('demo tick advances the scenario deterministically', () {
    container.read(demoProvider.notifier).set(true);
    expect(container.read(demoProvider), isTrue);
    expect(notifier.demoRunning, isTrue);
    for (var i = 0; i < 300; i++) {
      notifier.demoTick(1 / 30);
    }
    expect(read().speed, greaterThan(0));
    expect(read().tripMeter, greaterThan(0));
    expect(read().batterySoc, inInclusiveRange(78, 82),
        reason: 'ten simulated seconds should cost well under a percent per second');
    container.read(demoProvider.notifier).set(false);
    expect(container.read(demoProvider), isFalse);
  });
}
