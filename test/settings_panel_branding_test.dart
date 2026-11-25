import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/dashboard/dashboard_screen.dart';
import 'package:opendash/screens/safe_mode/safe_mode_screen.dart';
import 'package:opendash/screens/settings/widgets.dart';
import 'package:opendash/state/control_panel.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/error_state.dart';
import 'package:opendash/state/format_settings.dart';
import 'package:opendash/state/passcode_gate.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/theme_state.dart';
import 'package:opendash/state/wifi_state.dart';
import 'package:opendash/theme/colors.dart';
import 'package:opendash/theme/tokens.dart';
import 'package:opendash/widgets/controls/control_panel.dart';
import 'package:opendash/widgets/status_bar/status_icons.dart';
import 'package:opendash/widgets/overlays/error_overlay.dart';
import 'package:opendash/widgets/overlays/toast_overlay.dart';

void main() {
  late ProviderContainer container;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);
  Finder k(String id) => find.byKey(ValueKey(id));

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> boot(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [platformServiceProvider.overrideWithValue(MockPlatformService())],
      child: const OpenDashApp(),
    ));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await boot(tester);
    v().setLocked(false);
    await settle(tester);
  }

  Future<void> openSettings(WidgetTester tester, String section) async {
    container.read(settingsScreenOpenProvider.notifier).open();
    await settle(tester);
    await tester.tap(k('section-$section'));
    await settle(tester);
  }

  Future<void> pumpWidget(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(ProviderScope(child: MaterialApp(home: Scaffold(body: SizedBox(width: 600, child: child)))));
    await tester.pump();
  }

  double scale(WidgetTester tester) => tester.getRect(
      find.byWidgetPredicate((w) => w is SizedBox && w.width == 1280 && w.height == 768).first).height / 768;

  group('settings spacing', () {
    testWidgets('a toggle row keeps a gap between its label and caption', (tester) async {
      await pumpWidget(tester, ToggleRow(label: 'Side stand sensor', caption: 'Ignores the stand', value: true, onChanged: (_) {}));
      final label = tester.getRect(find.text('Side stand sensor'));
      final caption = tester.getRect(find.text('Ignores the stand'));
      expect(caption.top - label.bottom, greaterThanOrEqualTo(4));
      expect(tester.getSize(find.byType(ToggleRow)).height, greaterThanOrEqualTo(DashTouch.min));
    });

    testWidgets('a toggle row without a caption carries no spacer', (tester) async {
      await pumpWidget(tester, ToggleRow(label: 'Plain', value: true, onChanged: (_) {}));
      final column = find.ancestor(of: find.text('Plain'), matching: find.byType(Column)).first;
      expect(tester.widget<Column>(column).children.length, 1);
    });

    testWidgets('slider rows keep their label clear of the track', (tester) async {
      await pumpWidget(tester, SliderRow(label: 'Brightness', value: 50, display: '50%', onChanged: (_) {}));
      final label = tester.getRect(find.text('Brightness'));
      final slider = tester.getRect(find.byType(Slider));
      expect(slider.top - label.bottom, greaterThanOrEqualTo(4));
    });

    test('every riding toggle explains itself in one line', () {
      for (final f in RidingFeature.values) {
        expect(f.caption, isNotNull, reason: f.name);
        expect(f.caption!.startsWith('When enabled'), isFalse, reason: f.name);
        if (f != RidingFeature.sideStandCutOff) expect(f.caption!.length, lessThanOrEqualTo(72), reason: f.name);
      }
      expect(RidingFeature.sideStandCutOff.caption, contains('ignores the side stand sensor'));
    });
  });

  group('control panel states', () {
    testWidgets('brightness shows its level and glows amber from medium up', (tester) async {
      await pumpApp(tester);
      await tester.tap(k('ctl-handle'));
      await settle(tester);
      final level = container.read(brightnessProvider);
      expect(find.descendant(of: k('ctl-brightness'), matching: find.text(brightnessLabel(level).toUpperCase())), findsOneWidget);
      container.read(brightnessProvider.notifier).set(30);
      await settle(tester);
      expect(find.descendant(of: k('ctl-brightness'), matching: find.text('LOW')), findsOneWidget);
      expect(tester.widget<ControlButton>(k('ctl-brightness')).active, isFalse);
      container.read(brightnessProvider.notifier).set(60);
      await settle(tester);
      expect(find.descendant(of: k('ctl-brightness'), matching: find.text('MEDIUM')), findsOneWidget);
      final btn = tester.widget<ControlButton>(k('ctl-brightness'));
      expect(btn.active, isTrue);
      expect(btn.activeColor, DashColors.warning);
    });

    testWidgets('settings replaces trunk in the panel and opens settings', (tester) async {
      await pumpApp(tester);
      await tester.tap(k('ctl-handle'));
      await settle(tester);
      expect(k('ctl-trunk'), findsNothing);
      expect(k('ctl-settings'), findsOneWidget);
      expect(find.descendant(of: k('ctl-settings'), matching: find.text('SET')), findsOneWidget);
      await tester.tap(k('ctl-settings'));
      await settle(tester);
      expect(container.read(settingsScreenOpenProvider), isTrue);
      container.read(settingsScreenOpenProvider.notifier).close();
      v().setSpeed(30);
      await settle(tester);
      container.read(controlPanelOpenProvider.notifier).open();
      await settle(tester);
      expect(k('ctl-settings'), findsNothing, reason: 'no settings while riding');
      v().setSpeed(0);
      v().setCharging(true);
      await settle(tester);
      container.read(controlPanelOpenProvider.notifier).open();
      await settle(tester);
      expect(k('ctl-settings'), findsOneWidget, reason: 'available while charging');
      expect(k('ctl-trunk'), findsNothing);
    });
  });

  group('position light', () {
    testWidgets('lives in the status bar, not the tell-tale strip or the panel', (tester) async {
      await pumpApp(tester);
      v().setPositionLight(true);
      await settle(tester);
      expect(k('status-position-light'), findsOneWidget);
      expect(k('tt-positionLight'), findsNothing);
      await tester.tap(k('ctl-handle'));
      await settle(tester);
      expect(k('ctl-beam'), findsNothing, reason: 'no DRL switch: it never moved the lamp');
    });
  });

  group('overlay toolbar', () {
    testWidgets('carries signal and wifi between the clock and the battery', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      final bar = k('overlay-toolbar');
      final signal = find.descendant(of: bar, matching: find.byType(SignalIcon));
      final wifi = find.descendant(of: bar, matching: find.byType(WifiIcon));
      expect(signal, findsOneWidget);
      expect(wifi, findsOneWidget);
      final clock = tester.getRect(k('toolbar-clock'));
      final battery = tester.getRect(find.descendant(of: bar, matching: find.byType(BatteryIcon)));
      expect(tester.getRect(signal).left, greaterThan(clock.right));
      expect(tester.getRect(wifi).left, greaterThan(tester.getRect(signal).right));
      expect(battery.left, greaterThan(tester.getRect(wifi).right));
      expect(tester.widget<SignalIcon>(signal).bars, container.read(vehicleProvider).signalBars);
      v().setWifi(false);
      await settle(tester);
      expect(tester.widget<WifiIcon>(wifi).on, isFalse);
      expect(DashSpace.overlayTop, 72);
      expect(tester.getRect(k('section-display')).top, greaterThanOrEqualTo(tester.getRect(bar).top + 72 * scale(tester) - 0.5));
    });
  });

  group('settings screen', () {
    testWidgets('sidebar items meet the touch floor with 20px labels', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      expect(tester.getSize(k('section-profile')).height, greaterThanOrEqualTo(56 * scale(tester) - 0.5));
      final label = tester.widget<AnimatedDefaultTextStyle>(
          find.descendant(of: k('section-profile'), matching: find.byType(AnimatedDefaultTextStyle)));
      expect(label.style.fontSize, 20);
    });

    testWidgets('reopening settings starts on Display again', (tester) async {
      await pumpApp(tester);
      await openSettings(tester, 'connectivity');
      expect(container.read(settingsSectionProvider), SettingsSection.connectivity);
      container.read(diagnosticsOpenProvider.notifier).open();
      await settle(tester);
      container.read(diagnosticsOpenProvider.notifier).close();
      await settle(tester);
      expect(container.read(settingsSectionProvider), SettingsSection.connectivity, reason: 'a child screen keeps the place');
      container.read(settingsScreenOpenProvider.notifier).close();
      await settle(tester);
      expect(container.read(settingsSectionProvider), SettingsSection.display);
    });

    testWidgets('display puts the screen group first and the theme under a divider', (tester) async {
      await pumpApp(tester);
      await openSettings(tester, 'display');
      final screen = tester.getRect(find.text('SCREEN'));
      final theme = tester.getRect(find.text('THEME', skipOffstage: false));
      expect(screen.top, lessThan(theme.top));
      final divider = find.byType(SettingsDivider, skipOffstage: false);
      expect(tester.getRect(divider.first).top, greaterThan(screen.bottom));
      expect(tester.getRect(divider.first).top, lessThan(theme.top));
    });

    test('date order chips show an example date', () {
      expect(DateOrder.dayMonth.label, '8 November');
      expect(DateOrder.monthDay.label, 'November 8');
    });

    test('the clock defaults to 12-hour', () {
      final c = ProviderContainer();
      expect(c.read(use24HourProvider), isFalse);
      c.dispose();
    });
  });

  group('trunk from broken states', () {
    testWidgets('the error overlay opens the trunk', (tester) async {
      await pumpApp(tester);
      container.read(appErrorProvider.notifier).report(StateError('boom'));
      await settle(tester);
      expect(k('error-overlay'), findsOneWidget);
      expect(k('error-trunk'), findsOneWidget);
      expect(find.descendant(of: k('error-trunk'), matching: find.byType(TrunkOpenIcon)), findsOneWidget);
      await tester.tap(k('error-trunk'));
      await settle(tester);
      expect(container.read(vehicleProvider).trunkOpen, isTrue);
      expect(k('error-retry'), findsOneWidget);
    });

    testWidgets('the error overlay refuses the trunk at speed and shows its toast on top', (tester) async {
      await pumpApp(tester);
      // At speed the error screen folds into a status chip, so the only path
      // to the trunk is the notifier itself (Phase 2: a raw CAN frame).
      v().setSpeed(40);
      v().openTrunk();
      await settle(tester);
      expect(container.read(vehicleProvider).trunkOpen, isFalse, reason: 'the seat stays shut at 40 km/h');
      expect(find.text('Stop to open the boot'), findsOneWidget);
      v().setSpeed(0);
      container.read(appErrorProvider.notifier).report(StateError('boom'));
      await settle(tester);
      expect(k('error-trunk'), findsOneWidget);
      final stack = tester.widget<Stack>(find.ancestor(of: find.byType(ErrorOverlay), matching: find.byType(Stack)).first);
      final error = stack.children.indexWhere((w) => w is ErrorOverlay);
      final toast = stack.children.indexWhere((w) => w is ToastOverlay);
      expect(toast, greaterThan(error), reason: 'the toast paints over the error screen');
      await tester.tap(k('error-trunk'));
      await settle(tester);
      expect(container.read(vehicleProvider).trunkOpen, isTrue);
      expect(find.text('Boot opened'), findsOneWidget);
    });

    testWidgets('safe mode opens the trunk', (tester) async {
      await pumpApp(tester);
      container.read(crashRecoveryProvider.notifier).enterSafeMode();
      await settle(tester);
      expect(find.byType(SafeModeScreen), findsOneWidget);
      await tester.tap(k('safe-trunk'));
      await settle(tester);
      expect(container.read(vehicleProvider).trunkOpen, isTrue);
    });

    testWidgets('the boot timeout options offer no boot button: it cannot work without the service', (tester) async {
      await boot(tester);
      container.read(sessionProvider.notifier).simulateAidlTimeout();
      await settle(tester);
      await tester.pump(const Duration(seconds: 30));
      await settle(tester);
      expect(k('boot-options'), findsOneWidget);
      expect(k('boot-trunk'), findsNothing);
      expect(k('boot-stock'), findsOneWidget);
    });
  });

  group('vehicle info', () {
    test('firmware labels read as words', () {
      final labels = const VehicleData().firmwareVersions.map((e) => e.$1).toList();
      expect(labels, [
        'MoveOS', 'Vehicle Software', 'Vehicle Data Protocol', 'Dashboard', 'Body Control Module',
        'Battery Management', 'Motor Controller', 'Hub Controller', 'Head Unit', 'Bluetooth',
      ]);
    });

    testWidgets('the SIM row says what an ICCID is', (tester) async {
      await pumpApp(tester);
      await openSettings(tester, 'vehicleInfo');
      expect(find.text('SIM Card (ICCID)', skipOffstage: false), findsOneWidget);
      expect(find.text('Battery Management', skipOffstage: false), findsOneWidget);
      expect(find.text('BMS', skipOffstage: false), findsNothing);
    });
  });

  group('diagnostics service mode', () {
    testWidgets('a footer link opens the passcode gate and then service mode', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      container.read(diagnosticsOpenProvider.notifier).open();
      await settle(tester);
      for (final tab in ['liveData', 'faultCodes', 'battery']) {
        await tester.tap(k('diag-tab-$tab'));
        await settle(tester);
        expect(k('diag-service-mode'), findsOneWidget, reason: tab);
      }
      expect(tester.getSize(k('diag-service-mode')).height, greaterThanOrEqualTo(DashTouch.min * scale(tester) - 0.5));
      await tester.tap(k('diag-service-mode'));
      await settle(tester);
      expect(container.read(passcodeGateProvider).open, isTrue);
      expect(container.read(serviceModeOpenProvider), isFalse);
      for (final d in [1, 2, 3, 4, 5, 6]) {
        container.read(passcodeGateProvider.notifier).enterDigit(d);
      }
      await settle(tester);
      expect(container.read(serviceModeOpenProvider), isTrue);
    });

    testWidgets('diagnostics and service mode refuse to open at speed', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      container.read(diagnosticsOpenProvider.notifier).open();
      await settle(tester);
      expect(k('diag-service-mode'), findsOneWidget);
      // Diagnostics rides, so close it before moving to prove it will not
      // re-open at speed.
      container.read(diagnosticsOpenProvider.notifier).close();
      await settle(tester);
      v().setSpeed(30);
      await settle(tester);
      container.read(diagnosticsOpenProvider.notifier).open();
      await settle(tester);
      expect(container.read(diagnosticsOpenProvider), isFalse);
      container.read(serviceModeOpenProvider.notifier).open();
      await settle(tester);
      expect(container.read(serviceModeOpenProvider), isFalse, reason: 'no technician screen on a moving scooter');
    });
  });

  group('branding', () {
    test('mock data and copy are brand-neutral', () {
      expect(const VehicleData().scooterBtName, 'S1Pro-2408');
      const wifi = WifiSettings();
      expect(wifi.connectedSsid, 'HomeWifi_5G');
      expect(wifi.networks.map((n) => n.ssid), isNot(contains('OlaCharger_5G')));
      expect(wifi.networks.map((n) => n.ssid), isNot(contains('OlaService')));
      expect(wifi.networks.map((n) => n.ssid), contains('ServiceCenter'));
    });

    testWidgets('no Ola in the about or emergency copy', (tester) async {
      await pumpApp(tester);
      await openSettings(tester, 'about');
      expect(find.text('Open-source replacement dashboard for electric scooters'), findsOneWidget);
      expect(find.textContaining('Ola'), findsNothing);
      container.read(settingsScreenOpenProvider.notifier).close();
      v().setLocked(true);
      await settle(tester);
      await tester.tap(find.text('Emergency'));
      await settle(tester);
      expect(find.text('Roadside Support'), findsOneWidget);
      expect(find.textContaining('Ola'), findsNothing);
    });
  });

  group('reverse wordmark', () {
    testWidgets('REVERSE replaces READY in warning at 24px and the small R is gone', (tester) async {
      await pumpApp(tester);
      expect(k('reverse-indicator'), findsNothing);
      v().setVehicleState(VehicleState.ready);
      await settle(tester);
      expect(find.descendant(of: find.byType(StateWordmark), matching: find.text('READY')), findsOneWidget);
      v().activateReverse();
      await settle(tester);
      final word = tester.widget<Text>(find.descendant(of: find.byType(StateWordmark), matching: find.text('REVERSE')));
      expect(word.style!.color, DashColors.warning);
      expect(word.style!.fontSize, 24);
      expect(find.text('READY'), findsNothing);
      v().activateReverse();
      await settle(tester);
      expect(find.text('REVERSE'), findsNothing);
      expect(find.descendant(of: find.byType(StateWordmark), matching: find.text('READY')), findsOneWidget);
    });
  });

}
