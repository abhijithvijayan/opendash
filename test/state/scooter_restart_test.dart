import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/recovery_service.dart';
import 'package:opendash/services/wifican_codec.dart';
import 'package:opendash/state/passcode_gate.dart';
import 'package:opendash/state/scooter_restart.dart';
import 'package:opendash/state/toast_state.dart';

class _Vehicle extends VehicleNotifier {
  int reboots = 0;
  bool accept = true;

  @override
  Future<bool> rebootScooter() async {
    reboots++;
    return accept;
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

void main() {
  late ProviderContainer c;
  late _Vehicle vehicle;
  late _Shell shell;

  setUp(() {
    AnalyticsLogger.instance.resetForTest();
    vehicle = _Vehicle();
    shell = _Shell();
    recoveryService = RecoveryService(clientFactory: (_, _) => shell);
    c = ProviderContainer(overrides: [vehicleProvider.overrideWith(() => vehicle)]);
    c.listen(toastProvider, (_, _) {});
    c.listen(passcodeGateProvider, (_, _) {});
    c.listen(scooterRestartProvider, (_, _) {});
    c.read(vehicleProvider);
  });

  tearDown(() {
    c.dispose();
    recoveryService = RecoveryService();
  });

  ScooterRestart restart() => c.read(scooterRestartProvider.notifier);

  void park() {
    vehicle.setConnected(true);
    vehicle.setLocked(false);
    vehicle.setVehicleState(VehicleState.parked);
  }

  void enterPasscode() {
    for (final d in [1, 2, 3, 4, 5, 6]) {
      c.read(passcodeGateProvider.notifier).enterDigit(d);
    }
  }

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  group('rules', () {
    const parked = VehicleData(vehicleState: VehicleState.parked, lockState: 0, hhmisConnected: true);

    test('live data: parked, unlocked, stopped and unplugged only', () {
      expect(canRestartScooter(parked), isTrue);
      expect(canRestartScooter(parked.copyWith(vehicleState: VehicleState.charging)), isFalse, reason: 'charging');
      expect(canRestartScooter(parked.copyWith(vehicleState: VehicleState.ready)), isFalse, reason: 'motor on');
      expect(canRestartScooter(parked.copyWith(speed: 3)), isFalse, reason: 'moving');
      expect(canRestartScooter(parked.copyWith(lockState: 4)), isFalse, reason: 'locked');
      expect(canRestartScooter(parked.copyWith(isCharging: true)), isFalse, reason: 'charger plugged, HHMIS still PARK');
      expect(canRestartScooter(parked.copyWith(chargeMode: 3)), isFalse, reason: 'charge mode says plugged');
      expect(canRestartScooter(parked.copyWith(chargingState: ChargingState.initializing)), isFalse);
    });

    test('no live data: available (the dashboard may be what is stuck), the rider vouches', () {
      expect(restartAvailable(parked.copyWith(hhmisConnected: false, vehicleState: VehicleState.riding)), isTrue);
      expect(restartAvailable(parked.copyWith(hhmisStale: true, chargeMode: 3)), isTrue);
      expect(restartAvailable(parked.copyWith(chargeMode: 3)), isFalse);
      expect(restartBlockedReason(parked.copyWith(chargeMode: 3)), 'Unplug the charger to restart');
      expect(restartBlockedReason(parked.copyWith(vehicleState: VehicleState.ready)), 'Park the scooter to restart');
    });
  });

  test('not parked with live data: a toast, no passcode, no restart', () {
    park();
    vehicle.setVehicleState(VehicleState.ready);
    restart().request('test');
    expect(c.read(passcodeGateProvider).open, isFalse);
    expect(c.read(toastProvider)?.message, 'Park the scooter to restart');
    expect(vehicle.reboots, 0);
  });

  test('passcode, then a confirm dialog; only the Restart tap restarts', () async {
    park();
    restart().request('test');
    expect(c.read(passcodeGateProvider).open, isTrue);
    enterPasscode();
    await settle();
    expect(c.read(scooterRestartProvider)?.liveData, isTrue);
    expect(vehicle.reboots, 0, reason: 'the passcode alone does not restart');
    await restart().confirm();
    expect(vehicle.reboots, 1);
    expect(c.read(scooterRestartProvider), isNull);
    expect(shell.executed, isEmpty);
  });

  test('Cancel closes it and nothing restarts', () async {
    park();
    restart().request('test');
    enterPasscode();
    await settle();
    restart().cancel();
    expect(c.read(scooterRestartProvider), isNull);
    expect(vehicle.reboots, 0);
  });

  test('the countdown only cancels; it never restarts', () {
    fakeAsync((async) {
      park();
      restart().request('test');
      enterPasscode();
      async.flushMicrotasks();
      expect(c.read(scooterRestartProvider)?.secondsLeft, ScooterRestart.confirmFor);
      async.elapse(const Duration(seconds: 5));
      expect(c.read(scooterRestartProvider)?.secondsLeft, ScooterRestart.confirmFor - 5);
      async.elapse(const Duration(seconds: ScooterRestart.confirmFor));
      expect(c.read(scooterRestartProvider), isNull);
      expect(vehicle.reboots, 0);
    });
  });

  test('plugged in while the dialog was up: refused at the tap', () async {
    park();
    restart().request('test');
    enterPasscode();
    await settle();
    vehicle.state = vehicle.state.copyWith(chargeMode: 3);
    await restart().confirm();
    expect(vehicle.reboots, 0);
    expect(AnalyticsLogger.instance.recent('recovery', 'restart_blocked'), hasLength(1));
  });

  test('live data and the vehicle refuses: say so, no head-unit-only reboot', () async {
    park();
    vehicle.accept = false;
    restart().request('test');
    enterPasscode();
    await settle();
    await restart().confirm();
    expect(vehicle.reboots, 1);
    expect(shell.executed, isEmpty);
    expect(c.read(toastProvider)?.message, "Couldn't restart the scooter");
  });

  test('no data and HHMIS gone: the dialog says so, and the head unit reboots', () async {
    park();
    vehicle.setConnected(false);
    restart().request('test');
    enterPasscode();
    await settle();
    expect(c.read(scooterRestartProvider)?.liveData, isFalse);
    await restart().confirm();
    expect(vehicle.reboots, 0, reason: 'no HHMIS to ask');
    expect(shell.executed, ['reboot']);
  });

  test('stale data with HHMIS still bound: tries the scooter restart, then the head unit', () async {
    park();
    vehicle.state = vehicle.state.copyWith(hhmisStale: true);
    vehicle.accept = false;
    restart().request('test');
    enterPasscode();
    await settle();
    await restart().confirm();
    expect(vehicle.reboots, 1);
    expect(shell.executed, ['reboot']);
  });
}
