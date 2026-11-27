import 'package:fake_async/fake_async.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/state/widget_panel_state.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/alert_state.dart';
import 'package:opendash/state/format_settings.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/safety_watchdog.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:opendash/theme/dash_theme.dart';
import 'package:opendash/widgets/panel/trip_icons.dart';
import 'package:opendash/widgets/panel/widget_panel.dart';

void main() {
  void withApp(void Function(FakeAsync async, ProviderContainer c, VehicleNotifier v) body) {
    fakeAsync((async) {
      final c = ProviderContainer();
      for (final p in [
        sessionProvider, toastProvider, safetyWatchdogProvider, dismissedAlertsProvider, alertCycleProvider,
        ridingSettingsProvider,
      ]) {
        c.listen(p, (_, _) {});
      }
      final v = c.read(vehicleProvider.notifier);
      v.setConnected(true);
      v.setLocked(false);
      async.elapse(const Duration(seconds: 5));
      body(async, c, v);
      c.dispose();
    });
  }

  Set<AlertKind> visible(ProviderContainer c) => c.read(visibleAlertsProvider).map((a) => a.kind).toSet();

  group('state', () {
    test('efficiency colour bands: eco to 35, bone to 55, warning above', () {
      const t = DashTheme.dark;
      expect(efficiencyColor(20, t), t.eco);
      expect(efficiencyColor(35, t), t.eco);
      expect(efficiencyColor(36, t), t.bone);
      expect(efficiencyColor(55, t), t.bone);
      expect(efficiencyColor(56, t), t.warning);
    });

    test('demo ride settles efficiency on the mode figure and accrues energy', () {
      withApp((async, c, v) {
        v.setDemo(true);
        for (var i = 0; i < 300; i++) {
          v.demoTick(0.033);
        }
        final s = c.read(vehicleProvider);
        expect(s.driveMode, DriveMode.normal);
        expect(s.rideEfficiency, closeTo(VehicleNotifier.whPerKm[DriveMode.normal]!, 12));
        expect(s.energyUsed, greaterThan(0));
        v.setDemo(false);
      });
    });

    test('unit conversions', () {
      expect(toDisplayDistance(100, true), 62);
      expect(toDisplayDistance(100, false), 100);
      expect(toDisplayDistanceD(1.6, true), closeTo(0.99, 0.01));
      expect(distanceUnit(true), 'mi');
      expect(speedUnit(true), 'mph');
      expect(speedUnit(false), 'km/h');
      expect(toDisplayTemp(40, true), 104);
      expect(toDisplayTemp(50, true), 122);
      expect(toDisplayTemp(70, true), 158);
      expect(toDisplayTemp(85, true), 185);
      expect(toDisplayTemp(85, false), 85);
      expect(tempUnit(true), '°F');
    });

    // Start-refusal hints show for ~3 s every
    // time the condition fires, like stock. Previously silenced after
    // the first trigger via DismissedAlerts.oncePerSession.
    test('brake hint shows again on every press', () {
      withApp((async, c, v) {
        v.showBrakeHint();
        async.flushMicrotasks();
        expect(visible(c), contains(AlertKind.brakeToStart));
        async.elapse(const Duration(seconds: 6));
        expect(c.read(vehicleProvider).hintBrakeToStart, isFalse);
        v.showBrakeHint();
        async.flushMicrotasks();
        expect(c.read(vehicleProvider).hintBrakeToStart, isTrue);
        expect(visible(c), contains(AlertKind.brakeToStart),
            reason: 'fires again every time');
      });
    });

    // 2026-11-27, Gen 1 on 4.6.14: the scooter ignored the bypass and
    // refused three times with nothing on screen.
    test('the scooter refusing over the stand shows even while bypassed', () {
      withApp((async, c, v) {
        c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.sideStandCutOff, false);
        v.showStandHint();
        async.flushMicrotasks();
        expect(visible(c), contains(AlertKind.standToRide));
      });
    });

    test('cruise captures the speed at activation and clears when off', () {
      withApp((async, c, v) {
        v.setSpeed(45);
        v.setCruise(CruiseMode.standby);
        expect(c.read(vehicleProvider).cruiseSetSpeed, 0);
        v.setCruise(CruiseMode.active);
        expect(c.read(vehicleProvider).cruiseSetSpeed, 45);
        v.setSpeed(52);
        v.setCruise(CruiseMode.active);
        expect(c.read(vehicleProvider).cruiseSetSpeed, 45);
        v.setCruise(CruiseMode.off);
        expect(c.read(vehicleProvider).cruiseSetSpeed, 0);
      });
    });

    test('take-me-home counts down each second and turns off at zero', () {
      withApp((async, c, v) {
        v.setTakeMeHome(true);
        expect(c.read(vehicleProvider).takeMeHomeLightsRemaining, 45);
        async.elapse(const Duration(seconds: 1));
        expect(c.read(vehicleProvider).takeMeHomeLightsRemaining, 44);
        async.elapse(const Duration(seconds: 44));
        expect(c.read(vehicleProvider).takeMeHomeLights, isFalse);
        expect(c.read(vehicleProvider).takeMeHomeLightsRemaining, 0);
      });
    });

    test('reject with message ends the call and confirms; gated by rejectCallAllowed', () {
      withApp((async, c, v) {
        v.setRejectCallAllowed(true);
        v.simulateIncomingCall();
        v.rejectCallWithMessage();
        final s = c.read(vehicleProvider);
        expect(s.callIncoming, isFalse);
        expect(s.messageSentPopup, isTrue);
        expect(c.read(toastProvider)?.message, 'Message sent');
        async.elapse(const Duration(seconds: 3));
        expect(c.read(vehicleProvider).messageSentPopup, isFalse);

        v.setRejectCallAllowed(false);
        v.simulateIncomingCall();
        v.rejectCallWithMessage();
        expect(c.read(vehicleProvider).callIncoming, isTrue);
      });
    });

    test('nav mock carries trip totals and clears them with the route', () {
      withApp((async, c, v) {
        v.setNavActive(true);
        var s = c.read(vehicleProvider);
        expect(s.navTotalDistance, '7.6 km');
        expect(s.navTotalTime, '23 min');
        v.setNavActive(false);
        s = c.read(vehicleProvider);
        expect(s.navTotalDistance, isEmpty);
        expect(s.navTotalTime, isEmpty);
      });
    });

    test('album art flag follows the url; defaults carry the support number', () {
      withApp((async, c, v) {
        expect(c.read(vehicleProvider).hasAlbumArt, isFalse);
        v.setMediaPlaying(true);
        expect(c.read(vehicleProvider).hasAlbumArt, isTrue);
        v.setAlbumArt('');
        expect(c.read(vehicleProvider).hasAlbumArt, isFalse);
        expect(c.read(vehicleProvider).customerSupportNumber, '080-33113311');
        expect(c.read(vehicleProvider).rejectCallText, "Hey, I'm riding. I'll call you back later");
      });
    });
  });

  group('widgets', () {
    late ProviderContainer container;
    VehicleNotifier v() => container.read(vehicleProvider.notifier);
    Finder k(String id) => find.byKey(ValueKey(id));

    Future<void> pumpApp(WidgetTester tester) async {
      await tester.pumpWidget(const ProviderScope(child: OpenDashApp()));
      await tester.pump();
      container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 500));
      v().setLocked(false);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('this ride\'s Wh/km is on the trip page, not the battery page, and hides at zero', (tester) async {
      await pumpApp(tester);
      v().setEfficiency(30);
      await settle(tester);
      expect(k('efficiency'), findsNothing, reason: 'not on the battery page');
      container.read(widgetPageProvider.notifier).set(2);
      await settle(tester);
      expect(k('efficiency'), findsOneWidget);
      expect(find.descendant(of: k('efficiency'), matching: find.text('30')), findsOneWidget);
      expect(find.text('Wh/km this ride'), findsOneWidget);
      v().setEfficiency(0);
      await settle(tester);
      expect(k('efficiency'), findsNothing);
    });

    testWidgets('trip stats carry an energy-used row with a drawn bolt', (tester) async {
      await pumpApp(tester);
      await tester.fling(find.byType(PageView), const Offset(-120, 0), 800);
      await settle(tester);
      await tester.fling(find.byType(PageView), const Offset(-120, 0), 800);
      await settle(tester);
      expect(k('trip-energy'), findsOneWidget);
      expect(find.text('kWh used'), findsOneWidget);
      expect(find.byType(TripStatIcon), findsNWidgets(5));
    });

    testWidgets('nav bar shows trip totals only when set', (tester) async {
      await pumpApp(tester);
      v().setNavActive(true);
      await settle(tester);
      expect(find.text('7.6 km · 23 min'), findsOneWidget);
      v().setNavEta(false);
      await settle(tester);
      expect(k('nav-totals'), findsNothing);
      expect(k('nav-bar'), findsOneWidget);
    });

    testWidgets('cruise set speed replaces the wordmark while active', (tester) async {
      await pumpApp(tester);
      v().setSpeed(45);
      await settle(tester);
      expect(k('wordmark-READY'), findsNothing);
      v().setCruise(CruiseMode.active);
      await settle(tester);
      expect(find.text('CRUISE 45'), findsOneWidget);
      expect(k('wordmark-CRUISE'), findsOneWidget);
      v().setSpeed(50);
      await settle(tester);
      expect(find.text('CRUISE 45'), findsOneWidget);
      v().setCruise(CruiseMode.off);
      await settle(tester);
      expect(k('wordmark-CRUISE'), findsNothing);
    });

    testWidgets('take-me-home tell-tale carries a countdown numeral', (tester) async {
      await pumpApp(tester);
      v().setTakeMeHome(true);
      await settle(tester);
      expect(find.descendant(of: k('tt-takeMeHome-countdown'), matching: find.text('45s'), matchRoot: true), findsOneWidget);
      v().tickTakeMeHome();
      await settle(tester);
      // The mock's own clock may have ticked once more during the pump.
      expect(find.textContaining(RegExp(r'^4[34]s$')), findsOneWidget);
      v().setTakeMeHome(false);
      await settle(tester);
      expect(k('tt-takeMeHome-countdown'), findsNothing);
    });

    testWidgets('incoming call offers a message button when allowed', (tester) async {
      await pumpApp(tester);
      v().setRejectCallAllowed(true);
      v().simulateIncomingCall();
      await settle(tester);
      expect(k('call-message'), findsOneWidget);
      await tester.tap(k('call-message'));
      await settle(tester);
      expect(container.read(vehicleProvider).callIncoming, isFalse);
      expect(find.text('Message sent'), findsOneWidget);
      v().setRejectCallAllowed(false);
      v().simulateIncomingCall();
      await settle(tester);
      expect(k('call-reject'), findsOneWidget);
      expect(k('call-message'), findsNothing);
    });

    testWidgets('connectivity has no reject-call-message row: nothing sends the text', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      await tester.tap(k('section-connectivity'));
      await settle(tester);
      expect(k('reject-text'), findsNothing);
    });

    testWidgets('unit chips convert speed, range, distances and temperatures', (tester) async {
      await pumpApp(tester);
      v().setBatteryTemp(40);
      v().setSpeed(30);
      await settle(tester);
      expect(find.text('km/h'), findsOneWidget, reason: 'under the number; parked, the dial shows P with no unit');
      v().setSpeed(0);
      v().setVehicleState(VehicleState.parked);
      await settle(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      await tester.ensureVisible(k('temp-unit'));
      await settle(tester);
      await tester.tap(find.descendant(of: k('distance-unit'), matching: find.text('mi')));
      await tester.tap(find.descendant(of: k('temp-unit'), matching: find.text('°F')));
      await settle(tester);
      expect(container.read(useMilesProvider), isTrue);
      expect(container.read(useFahrenheitProvider), isTrue);
      container.read(settingsScreenOpenProvider.notifier).close();
      await settle(tester);
      v().setSpeed(100);
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('mph'), findsOneWidget);
      expect(find.text('62'), findsOneWidget);
      expect(find.textContaining(RegExp(r'\d mi$')), findsWidgets);
      expect(find.textContaining(RegExp(r'\d km$')), findsNothing);
      v().setLocked(true);
      await settle(tester);
      expect(find.text('mi range'), findsOneWidget);
    });

    testWidgets('now playing shows a letter tile with art and a note without', (tester) async {
      await pumpApp(tester);
      v().setMediaPlaying(true);
      await settle(tester);
      expect(find.descendant(of: k('np-letter'), matching: find.text('N'), matchRoot: true), findsOneWidget);
      expect(find.byIcon(Icons.music_note_rounded), findsNothing);
      v().setAlbumArt('');
      await settle(tester);
      expect(k('np-letter'), findsNothing);
      expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
    });

    testWidgets('emergency sheet lists the support number and toasts it on tap', (tester) async {
      await pumpApp(tester);
      v().setLocked(true);
      await settle(tester);
      await tester.tap(find.text('Emergency'));
      await settle(tester);
      expect(find.text('080-33113311'), findsOneWidget);
      expect(find.text(emergencyNumber), findsOneWidget);
      await tester.tap(k('support-number'));
      await settle(tester);
      expect(find.text('Roadside Support: 080-33113311'), findsOneWidget);
    });
  });
}
