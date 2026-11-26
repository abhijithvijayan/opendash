import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/constants.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/dashboard/dashboard_screen.dart';
import 'package:opendash/screens/locked/keypad.dart';
import 'package:opendash/screens/locked/locked_screen.dart';
import 'package:opendash/state/control_panel.dart';
import 'package:opendash/state/error_state.dart';
import 'package:opendash/state/greeting_state.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/widget_panel_state.dart';
import 'package:opendash/widgets/controls/control_panel.dart';
import 'package:opendash/widgets/gauges/power_bar.dart';
import 'package:opendash/widgets/gauges/speed_dial.dart';
import 'package:opendash/widgets/indicators/mode_ladder.dart';
import 'package:opendash/widgets/indicators/telltale_strip.dart';
import 'package:opendash/widgets/indicators/trip_strip.dart';
import 'package:opendash/widgets/indicators/turn_arrow.dart';
import 'package:opendash/widgets/overlays/alert_overlay.dart';
import 'package:opendash/widgets/status_bar/status_bar.dart';

void main() {
  late ProviderContainer container;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);
  Finder k(String id) => find.byKey(ValueKey(id));

  Future<void> boot(WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenDashApp()));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await boot(tester);
    v().setLocked(false);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }


  group('rename', () {
    testWidgets('OpenDash on the boot splash, about, safe mode and the long-press toast', (tester) async {
      await boot(tester);
      v().setLocked(false);
      await settle(tester);
      expect(find.text(appName), findsNothing, reason: 'boot splash gone');
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      await tester.tap(k('section-about'));
      await settle(tester);
      expect(find.descendant(of: k('about-title'), matching: find.text('OpenDash'), matchRoot: true), findsOneWidget);
      expect(find.text('Open-source replacement dashboard for electric scooters'), findsOneWidget);
      expect(find.text('ola-dash'), findsNothing);
      container.read(settingsScreenOpenProvider.notifier).close();
      await settle(tester);
      await tester.longPress(k('status-clock'));
      await settle(tester);
      expect(find.text('$appName v$appVersion'), findsOneWidget);
    });
  });

  group('alert banner', () {
    testWidgets('sits under the status bar and leaves the turn arrows visible', (tester) async {
      await pumpApp(tester);
      v().setTurnLeft(true);
      v().setLimpMode(true);
      await settle(tester);
      final banner = tester.getRect(k('alert-banner'));
      final bar = tester.getRect(find.byType(StatusBar));
      expect(banner.top, closeTo(bar.bottom, 0.5), reason: 'banner starts where the status bar ends');
      expect(tester.widget<Positioned>(find.ancestor(of: find.byType(AnimatedSwitcher), matching: find.byType(Positioned)).first).top, isNot(0));
      final arrow = tester.getRect(find.descendant(of: find.byType(StatusBar), matching: find.byType(TurnArrow)).first);
      expect(arrow.overlaps(banner), isFalse);
      expect(find.byType(BoxShadow), findsNothing, reason: 'no animated blur on the banner');
      expect(find.byKey(const ValueKey('telltale-strip-position')), findsOneWidget);
      final strip = tester.widget<AnimatedPositioned>(k('telltale-strip-position'));
      expect(strip.top, 72 + AlertOverlay.height, reason: 'tell-tales move under the banner');
    });

    testWidgets('settings slides down under a banner so its back arrow stays reachable', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      v().setFault(true);
      await settle(tester);
      expect(tester.getRect(k('toolbar-back')).overlaps(tester.getRect(k('alert-banner'))), isFalse);
      await tester.tap(k('toolbar-back'));
      await settle(tester);
      expect(container.read(settingsScreenOpenProvider), isFalse);
    });

    testWidgets('critical alert pinned on screen while warnings exist', (tester) async {
      await pumpApp(tester);
      v().setBrakeWorn(true);
      v().setDerating(true);
      v().setLimpMode(true);
      await settle(tester);
      expect(find.text('Limp mode'), findsOneWidget);
      await tester.pump(const Duration(seconds: 11));
      await settle(tester);
      expect(find.text('Limp mode'), findsOneWidget, reason: 'did not rotate away');
      expect(find.text('1 of 3'), findsOneWidget);
    });
  });

  group('lock screen gating', () {
    testWidgets('no settings, apps, Bluetooth or bell taps and no control panel while locked', (tester) async {
      await pumpApp(tester);
      v().setLocked(true);
      await settle(tester);
      expect(find.byType(StatusBar), findsNothing, reason: 'the lock screen owns the full height');
      expect(k('status-settings'), findsNothing);
      expect(k('status-apps'), findsNothing);
      expect(find.byType(ControlPanel), findsNothing);
      await tester.fling(find.byType(LockedScreen), const Offset(-200, 0), 900);
      await settle(tester);
      expect(container.read(controlPanelOpenProvider), isFalse);
      v().setLocked(false);
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      expect(k('status-settings'), findsOneWidget);
      expect(find.byType(ControlPanel), findsOneWidget);
    });

    testWidgets('the lock screen offers no Forgot PIN hint; there is no reset receiver to point at', (tester) async {
      await pumpApp(tester);
      v().setLocked(true);
      await settle(tester);
      expect(k('forgot-pin'), findsNothing);
      expect(find.text('Forgot PIN?'), findsNothing);
      expect(find.textContaining('RESET_PIN'), findsNothing);
    });

    testWidgets('lock screen shows six PIN dots', (tester) async {
      await pumpApp(tester);
      v().setLocked(true);
      await settle(tester);
      expect(find.descendant(of: find.byType(PinDots), matching: find.byType(AnimatedContainer)), findsNWidgets(6));
    });
  });

  group('overlays while riding', () {
    testWidgets('settings and licenses close when the scooter moves; the error becomes a chip', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      container.read(licensesScreenOpenProvider.notifier).open();
      await settle(tester);
      expect(k('licenses-body'), findsOneWidget);
      v().setSpeed(25);
      await settle(tester);
      expect(k('licenses-body'), findsNothing);
      expect(k('settings-body'), findsNothing);
      v().setSpeed(0);
      await settle(tester);
      container.read(appErrorProvider.notifier).capture(() => throw StateError('Dev panel test error'));
      await settle(tester);
      expect(k('error-overlay'), findsOneWidget);
      v().setSpeed(25);
      await settle(tester);
      expect(k('error-overlay'), findsNothing);
      expect(k('status-error'), findsOneWidget);
      expect(find.byType(SpeedDial), findsOneWidget, reason: 'speedometer stays visible');
      await tester.tap(k('status-error'));
      await settle(tester);
      expect(k('error-overlay'), findsOneWidget);
      container.read(appErrorProvider.notifier).dismiss();
      await settle(tester);
      expect(k('status-error'), findsNothing);
    });
  });

  group('performance structure', () {
    testWidgets('connection badge unmounts when connected and repaint boundaries wrap the gauges', (tester) async {
      await pumpApp(tester);
      expect(k('connection-badge'), findsNothing);
      v().setConnected(false);
      await settle(tester);
      expect(k('connection-badge'), findsOneWidget);
      v().setConnected(true);
      v().setVehicleState(VehicleState.ready);
      await settle(tester);
      expect(k('connection-badge'), findsNothing);
      for (final type in [SpeedDial, PowerBar, StatusBar, TripStrip, ModeLadder, TelltaleStrip, ControlPanel]) {
        expect(find.ancestor(of: find.byType(type), matching: find.byType(RepaintBoundary)), findsWidgets, reason: '$type');
      }
    });

    testWidgets('sub-screens are not in the tree while closed', (tester) async {
      await pumpApp(tester);
      for (final id in ['settings', 'diag', 'ota', 'apps', 'licenses', 'bt']) {
        expect(k('$id-body'), findsNothing, reason: id);
      }
      expect(k('toolbar-back'), findsNothing);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      expect(k('settings-body'), findsOneWidget);
      await tester.tap(k('toolbar-back'));
      await settle(tester);
      expect(k('settings-body'), findsNothing);
      expect(k('toolbar-back'), findsNothing);
    });
  });

  group('dashboard cues', () {
    testWidgets('PARKED, READY and nothing while moving', (tester) async {
      await pumpApp(tester);
      expect(k('wordmark-PARKED'), findsOneWidget);
      v().setVehicleState(VehicleState.ready);
      await settle(tester);
      expect(k('wordmark-READY'), findsOneWidget);
      expect(k('wordmark-PARKED'), findsNothing);
      v().setSpeed(30);
      await settle(tester);
      expect(find.byKey(const ValueKey('wordmark-READY')), findsNothing);
      expect(find.byType(StateWordmark), findsOneWidget);
      v().setSpeed(0);
      await settle(tester);
      expect(k('wordmark-READY'), findsOneWidget);
    });

    testWidgets('REGEN caption and HOT badges', (tester) async {
      await pumpApp(tester);
      expect(k('regen-caption'), findsNothing);
      v().setPower(-2.5);
      await settle(tester);
      expect(k('regen-caption'), findsOneWidget);
      v().setPower(1.5);
      await settle(tester);
      expect(k('regen-caption'), findsNothing);
      expect(k('battery-hot'), findsNothing);
      v().setBatteryTemp(56); // cell warn is 55 (was 40)
      await settle(tester);
      expect(k('battery-hot'), findsOneWidget);
      container.read(widgetPageProvider.notifier).set(1);
      await settle(tester);
      v().setMotorTemp(150); // motor winding warn is 147 (was 70)
      await settle(tester);
      expect(find.descendant(of: k('motor-temp'), matching: find.text('Motor hot')), findsOneWidget);
    });

    testWidgets('tapping a tell-tale names it; the stand bypass has its own symbol', (tester) async {
      await pumpApp(tester);
      v().setRegenActive(true);
      v().setRegenMode(RegenMode.city);
      await settle(tester);
      await tester.tap(k('tt-regen'));
      await settle(tester);
      expect(find.textContaining('Regenerative braking — City (strong)'), findsOneWidget);
      container.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.sideStandCutOff, false);
      await settle(tester);
      expect(k('tt-standBypass'), findsOneWidget);
      await tester.tap(k('tt-standBypass'));
      await settle(tester);
      expect(find.text('Side stand sensor bypassed'), findsOneWidget);
    });

    testWidgets('charge limit edit has a 44px target', (tester) async {
      await pumpApp(tester);
      v().setCharging(true);
      v().setHyperCharger(true);
      await settle(tester);
      expect(tester.getSize(k('charge-limit-edit')).height, greaterThanOrEqualTo(44));
    });
  });

  group('greeting', () {
    testWidgets('shows after the first unlock and fades out', (tester) async {
      await boot(tester);
      v().setLocked(false);
      await settle(tester);
      expect(k('greeting'), findsOneWidget);
      expect(container.read(greetingProvider), endsWith(', Owner'));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 600));
      expect(k('greeting'), findsNothing);
      v().setLocked(true);
      await settle(tester);
      v().setLocked(false);
      await settle(tester);
      expect(k('greeting'), findsNothing, reason: 'first unlock only');
    });
  });

  group('calls and pairing', () {
    testWidgets('an incoming call replaces the pairing card and its buttons are on top', (tester) async {
      await pumpApp(tester);
      v().startPairing();
      await settle(tester);
      expect(k('bt-pairing'), findsOneWidget);
      v().simulateIncomingCall();
      await settle(tester);
      expect(k('bt-pairing'), findsNothing);
      await tester.tap(k('call-accept'));
      await settle(tester);
      expect(container.read(vehicleProvider).callActive, isTrue);
    });
  });
}
