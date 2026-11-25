import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/app_catalog.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/boot/boot_screen.dart';
import 'package:opendash/screens/charging/charging_screen.dart';
import 'package:opendash/screens/locked/keypad.dart';
import 'package:opendash/screens/locked/locked_screen.dart';
import 'package:opendash/state/passcode_state.dart';
import 'package:opendash/state/passcode_gate.dart';
import 'package:opendash/state/scooter_restart.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/theme_state.dart';
import 'package:opendash/theme/colors.dart';
import 'package:opendash/widgets/gauges/battery_ring.dart';
import 'package:opendash/widgets/gauges/speed_dial.dart';
import 'package:opendash/widgets/indicators/mode_ladder.dart';

void main() {
  late ProviderContainer container;

  Finder ladderText(String t) =>
      find.descendant(of: find.byType(ModeLadder), matching: find.text(t));

  Future<void> pumpApp(WidgetTester tester, {bool boot = true}) async {
    await tester.pumpWidget(const ProviderScope(child: OpenDashApp()));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    if (boot) {
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 500));
      container.read(vehicleProvider.notifier).setLocked(false);
      // The unlock raises the handlebar hint; let it expire before tapping.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  Finder lockKeypad() =>
      find.descendant(of: find.byType(LockedScreen), matching: find.byType(Keypad));

  Finder key(String label) => find.descendant(of: lockKeypad(), matching: find.text(label));

  Future<void> enterPin(WidgetTester tester, String pin) async {
    for (final ch in pin.split('')) {
      await tester.tap(key(ch));
      await tester.pump();
    }
  }

  testWidgets('boot splash shows until HHMIS connects', (tester) async {
    await pumpApp(tester, boot: false);
    expect(find.byType(BootScreen), findsOneWidget);
    expect(find.text('OpenDash'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(BootScreen), findsNothing);
    expect(find.byType(LockedScreen), findsOneWidget, reason: 'scooter starts locked');
  });

  testWidgets('lock screen shows clock, battery, keypad; correct PIN unlocks', (tester) async {
    await pumpApp(tester);
    container.read(vehicleProvider.notifier).setLocked(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(LockedScreen), findsOneWidget);
    expect(lockKeypad(), findsOneWidget);
    expect(find.text('km range'), findsOneWidget);
    expect(find.text('Forgot PIN?'), findsNothing);
    await enterPin(tester, '123456');
    expect(container.read(vehicleProvider).locked, isFalse);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SpeedDial), findsOneWidget);
  });

  testWidgets('wrong PIN keeps the lock screen and clears the digits', (tester) async {
    await pumpApp(tester);
    container.read(vehicleProvider.notifier).setLocked(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await enterPin(tester, '000000');
    expect(container.read(passcodeProvider).attemptsRemaining, 4);
    expect(find.byType(LockedScreen), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    expect(container.read(passcodeProvider).enteredDigits, isEmpty);
  });

  testWidgets('five failures show the countdown and disable the keypad', (tester) async {
    await pumpApp(tester);
    container.read(vehicleProvider.notifier).setLocked(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    for (var i = 0; i < 5; i++) {
      await enterPin(tester, '999999');
      await tester.pump(const Duration(milliseconds: 600));
    }
    expect(find.textContaining('Try again in'), findsOneWidget);
    expect(tester.widget<Keypad>(lockKeypad()).enabled, isFalse);
    expect(find.textContaining('Too many attempts'), findsOneWidget);
    await tester.pump(PasscodeNotifier.lockoutDuration + const Duration(seconds: 1));
    expect(find.textContaining('Try again in'), findsNothing);
    expect(tester.widget<Keypad>(lockKeypad()).enabled, isTrue);
  });

  testWidgets('emergency button opens the contact card', (tester) async {
    await pumpApp(tester);
    container.read(vehicleProvider.notifier).setLocked(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Emergency'));
    await tester.pump();
    expect(find.text('Blood type'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pump();
    expect(find.text('Blood type'), findsNothing);
  });

  testWidgets('sleep blanks the screen and a tap wakes it', (tester) async {
    await pumpApp(tester);
    container.read(sessionProvider.notifier).sleep();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SpeedDial), findsNothing);
    await tester.tapAt(const Offset(300, 300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SpeedDial), findsNothing, reason: 'a single tap does not wake');
    await tester.tapAt(const Offset(300, 300));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(const Offset(300, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SpeedDial), findsOneWidget);
  });

  testWidgets('losing HHMIS shows Reconnecting over the last data', (tester) async {
    await pumpApp(tester);
    container.read(vehicleProvider.notifier).setSpeed(37);
    await tester.pump(const Duration(milliseconds: 400));
    container.read(vehicleProvider.notifier).setConnected(false);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Reconnecting…'), findsOneWidget);
    expect(find.descendant(of: find.byType(SpeedDial), matching: find.text('37')), findsOneWidget);
  });

  testWidgets('dashboard shows speed, battery and mode', (tester) async {
    await pumpApp(tester);
    expect(find.byType(SpeedDial), findsOneWidget);
    expect(find.byType(BatteryRing), findsOneWidget);
    expect(find.descendant(of: find.byType(SpeedDial), matching: find.text('P')), findsOneWidget, reason: 'parked: the throttle is dead');
    expect(ladderText('NORMAL'), findsNothing, reason: 'the ladder waits for the motor');
    container.read(vehicleProvider.notifier).setVehicleState(VehicleState.ready);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(ladderText('NORMAL'), findsOneWidget);
    expect(find.descendant(of: find.byType(SpeedDial), matching: find.text('0')), findsOneWidget, reason: 'ready keeps its 0: a live throttle never looks like a dead one');
    expect(find.descendant(of: find.byType(SpeedDial), matching: find.text('km/h')), findsOneWidget);
  });

  testWidgets('the dial shows P, H and R where a 0 would say nothing, and the speed the moment it moves', (tester) async {
    await pumpApp(tester);
    final v = container.read(vehicleProvider.notifier);
    Finder inDial(String text) => find.descendant(of: find.byType(SpeedDial), matching: find.text(text));
    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    expect(inDial('P'), findsOneWidget);
    v.setSideStand(true);
    await settle();
    expect(inDial('P'), findsOneWidget, reason: 'parked is the scooter\'s state, whatever the stand does');

    v.setSideStand(false);
    v.setVehicleState(VehicleState.ready);
    v.setHillHold(true);
    await settle();
    expect(inDial('H'), findsOneWidget);
    expect(find.text('HILL HOLD'), findsOneWidget);

    v.setSpeed(7);
    await settle();
    expect(inDial('H'), findsNothing, reason: 'moving off, the speed is back at once');
    expect(inDial('7'), findsOneWidget);

    v.setHillHold(false);
    v.setSpeed(0);
    v.activateReverse();
    await settle();
    expect(inDial('R'), findsOneWidget);
    expect(inDial('0 km/h'), findsOneWidget, reason: 'the scooter moves in reverse, so the speed stays, small, underneath');
    expect(find.byKey(const ValueKey('mode-ladder')), findsNothing, reason: 'reverse is none of the drive modes');
    expect(container.read(accentProvider), container.read(uiThemeProvider).warning, reason: 'the arc and the ring go with the R');
    v.setSpeed(3);
    await settle();
    expect(inDial('R'), findsOneWidget, reason: 'reverse keeps its letter while it moves');
    expect(inDial('3 km/h'), findsOneWidget);
    expect(find.byKey(const ValueKey('mode-ladder')), findsNothing);
    v.setSpeed(0);
    v.activateReverse();
    await settle();
    expect(inDial('0'), findsOneWidget, reason: 'the mock goes back to where reverse was entered from: ready');
  });

  testWidgets('cruise: green dial and number, the set speed marked, the mode row still in its own colour', (tester) async {
    await pumpApp(tester);
    final v = container.read(vehicleProvider.notifier);
    final theme = container.read(uiThemeProvider);
    v.setVehicleState(VehicleState.ready);
    v.setSpeed(60);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.widget<SpeedDial>(find.byType(SpeedDial)).cruiseSet, isNull);
    expect(container.read(accentProvider), theme.accentFor(DriveMode.normal));

    v.setCruise(CruiseMode.active);
    v.setSpeed(51);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.widget<SpeedDial>(find.byType(SpeedDial)).cruiseSet, 60, reason: 'the speed it was set at, not the speed now');
    expect(container.read(accentProvider), theme.eco);
    final number = tester.widget<Text>(find.descendant(of: find.byType(SpeedDial), matching: find.text('51')));
    expect(number.style!.color, theme.eco, reason: 'the number says cruise; it is still the speed');
    expect(tester.widget<RichText>(find.descendant(of: ladderText('NORMAL'), matching: find.byType(RichText))).text.style!.color,
        theme.accentFor(DriveMode.normal),
        reason: 'Normal lit in cruise green would read as Eco');
    expect(find.text('CRUISE 60'), findsOneWidget);

    v.setCruise(CruiseMode.off);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.widget<SpeedDial>(find.byType(SpeedDial)).cruiseSet, isNull);
    expect(container.read(accentProvider), theme.accentFor(DriveMode.normal));
  });

  testWidgets('speed numeral follows the provider', (tester) async {
    await pumpApp(tester);
    container.read(vehicleProvider.notifier).setSpeed(64);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.descendant(of: find.byType(SpeedDial), matching: find.text('64')), findsOneWidget);
  });

  testWidgets('side stand while ready raises a critical banner', (tester) async {
    await pumpApp(tester);
    container.read(vehicleProvider.notifier).setVehicleState(VehicleState.ready);
    container.read(vehicleProvider.notifier).setSideStand(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Side stand down'), findsOneWidget);
    container.read(vehicleProvider.notifier).setSideStand(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Side stand down'), findsNothing);
  });

  testWidgets('tapping a mode row changes the drive mode', (tester) async {
    await pumpApp(tester);
    container.read(vehicleProvider.notifier).setVehicleState(VehicleState.ready);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(ladderText('SPORT'));
    await tester.pump();
    expect(container.read(vehicleProvider).driveMode, DriveMode.sport);
  });

  testWidgets('a locked scooter on the charger shows the charging line, like stock passcode', (tester) async {
    await pumpApp(tester);
    container.read(vehicleProvider.notifier).setLocked(true);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('lock-charge-status')), findsNothing);
    container.read(vehicleProvider.notifier).setCharging(true);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(LockedScreen), findsOneWidget, reason: 'locked still wins over charging');
    final line = find.byKey(const ValueKey('lock-charge-status'));
    expect(find.descendant(of: line, matching: find.text('Charging')), findsOneWidget);
    container.read(vehicleProvider.notifier).setChargerState(ChargingState.notCharging);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.descendant(of: line, matching: find.text('Not charging')), findsOneWidget);
  });

  testWidgets('locked at boot on the charger: INT_CHARGE_MODE alone shows the charging line', (tester) async {
    await pumpApp(tester);
    container.read(vehicleProvider.notifier).setLocked(true);
    await tester.pump(const Duration(milliseconds: 500));
    final n = container.read(vehicleProvider.notifier);
    n.state = n.state.copyWith(chargeMode: 3);
    await tester.pump(const Duration(milliseconds: 500));
    final line = find.byKey(const ValueKey('lock-charge-status'));
    expect(find.descendant(of: line, matching: find.text('Charging')), findsOneWidget);
    n.state = n.state.copyWith(chargeMode: 0);
    await tester.pump(const Duration(milliseconds: 500));
    expect(line, findsNothing);
  });

  testWidgets('restart: passcode, then a dialog that needs a tap and counts down to cancel', (tester) async {
    await pumpApp(tester);
    final n = container.read(vehicleProvider.notifier);
    n.setConnected(true);
    n.setVehicleState(VehicleState.parked);
    await tester.pump(const Duration(milliseconds: 300));
    container.read(scooterRestartProvider.notifier).request('test');
    await tester.pump(const Duration(milliseconds: 300));
    for (final d in [1, 2, 3, 4, 5, 6]) {
      container.read(passcodeGateProvider.notifier).enterDigit(d);
    }
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Restart the scooter?'), findsOneWidget);
    expect(find.textContaining('Cancels in 10 s'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Cancels in 9 s'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Restart the scooter?'), findsNothing);
  });

  testWidgets('after an emergency return the dashboard offers the way back to navigation', (tester) async {
    await pumpApp(tester);
    final n = container.read(vehicleProvider.notifier);
    n.setVehicleState(VehicleState.riding);
    n.setSpeed(30);
    await tester.pump(const Duration(milliseconds: 300));
    final auto = appCatalog.firstWhere((a) => a.id == 'android-auto');
    container.read(projectionResumeProvider.notifier).offer(auto);
    await tester.pump(const Duration(milliseconds: 300));
    final chip = find.byKey(const ValueKey('resume-projection'));
    expect(find.descendant(of: chip, matching: find.text('Auto')), findsOneWidget);
    await tester.tap(chip);
    await tester.pump(const Duration(milliseconds: 300));
    expect(container.read(projectionResumeProvider), isNull, reason: 'the relaunch itself is covered in app_manager_test');
    expect(chip, findsNothing);
  });

  testWidgets('plugging in switches to the charging screen', (tester) async {
    await pumpApp(tester);
    container.read(vehicleProvider.notifier).setCharging(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.descendant(of: find.byType(ChargingScreen), matching: find.text('Charging')),
      findsOneWidget,
    );
    expect(find.text('100% at'), findsOneWidget);
  });

  testWidgets('the 80% row shows only below 80% SOC', (tester) async {
    await pumpApp(tester);
    final n = container.read(vehicleProvider.notifier);
    n.setCharging(true);
    n.setBattery(60);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('charge-to-80')), findsOneWidget);
    n.setBattery(80);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('charge-to-80')), findsNothing);
    expect(find.text('100% at'), findsOneWidget);
  });
}
