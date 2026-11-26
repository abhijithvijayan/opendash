import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/diagnostics/diagnostics_screen.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/control_panel.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/dash_island.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/theme_state.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:opendash/state/widget_panel_state.dart';
import 'package:opendash/theme/dash_theme.dart';

/// Puts the app where a scene needs it, through the providers the screens
/// themselves read.
class Director {
  Director(this.tester, this.container);

  final WidgetTester tester;
  final ProviderContainer container;

  final _done = <String>{};

  /// True the first time it is asked for [key].
  bool once(String key) => _done.add(key);

  VehicleNotifier get vehicle => container.read(vehicleProvider.notifier);
  VehicleData get data => container.read(vehicleProvider);

  /// Lets a screen change finish before a scene's first frame.
  /// Also clears the toast the set-up itself raised ("Drive mode: NORMAL").
  Future<void> settle([int ms = 700]) async {
    await tester.pump();
    container.read(toastProvider.notifier).dismiss();
    await tester.pump(Duration(milliseconds: ms));
  }

  bool get light => container.read(shownThemeProvider).isLight;

  void clearToast() => container.read(toastProvider.notifier).dismiss();

  void theme(DashTheme t) => container.read(themeProvider.notifier).setTheme(t);

  void drive(double speed, double kw) {
    vehicle.setSpeed(speed.round());
    vehicle.setPower(kw);
    // The mock derives torque only inside its own demo ride.
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    vehicle.state = vehicle.state.copyWith(torque: (kw * 6.8).clamp(0, 58).toDouble());
  }

  Future<void> tapKey(String key) => tester.tap(find.byKey(ValueKey(key)), warnIfMissed: false);

  void closeAll() {
    container.read(controlPanelOpenProvider.notifier).close();
    container.read(islandPreviewProvider.notifier).set(null);
    container.read(mockAppProvider.notifier).close();
    if (container.read(diagnosticsOpenProvider)) container.read(diagnosticsOpenProvider.notifier).close();
    if (container.read(appLauncherOpenProvider)) container.read(appLauncherOpenProvider.notifier).close();
    if (container.read(settingsScreenOpenProvider)) container.read(settingsScreenOpenProvider.notifier).close();
    if (container.read(sohPopupOpenProvider)) container.read(sohPopupOpenProvider.notifier).close();
  }

  /// Unlocked, stopped, on the riding screen with nothing over it.
  Future<void> ride({DriveMode mode = DriveMode.normal, int soc = 82}) async {
    closeAll();
    if (data.isCharging) vehicle.setCharging(false);
    if (data.locked) vehicle.setLocked(false);
    if (data.reverse) {
      vehicle.setSpeed(0);
      vehicle.activateReverse();
    }
    vehicle.setCruise(CruiseMode.off);
    vehicle.setHillHold(false);
    vehicle.setTurnLeft(false);
    vehicle.setTurnRight(false);
    vehicle.setSpeed(0);
    vehicle.setPower(0);
    vehicle.setVehicleState(VehicleState.ready);
    vehicle.setDriveMode(mode);
    vehicle.setBattery(soc);
    container.read(widgetPageProvider.notifier).set(0);
    await settle();
  }

  Future<void> parked() async {
    await ride();
    vehicle.setVehicleState(VehicleState.parked);
    await settle();
  }

  Future<void> diagnostics(DiagTab tab) async {
    await parked();
    container.read(diagnosticsOpenProvider.notifier).open();
    container.read(diagTabProvider.notifier).set(tab);
    await settle(1200);
  }
}
