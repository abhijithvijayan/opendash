import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/locked/keypad.dart';
import 'package:opendash/state/control_panel.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/theme_state.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:opendash/theme/colors.dart';
import 'package:opendash/theme/dash_theme.dart';
import 'package:opendash/theme/tokens.dart';
import 'package:opendash/theme/typography.dart';
import 'package:opendash/widgets/overlays/toast_overlay.dart';
import 'package:opendash/widgets/status_bar/status_bar.dart';
import 'package:opendash/widgets/status_bar/status_icons.dart';
import 'package:opendash/widgets/panel/trip_icons.dart';

void main() {
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

  group('tokens', () {
    test('values match the design spec', () {
      expect(DashSpace.gutter, 72);
      expect(DashSpace.headerTop, 84);
      expect(DashSpace.bodyTop, 160);
      expect(DashSpace.bodyBottom, 32);
      expect(DashSpace.cardPad, 20);
      expect(DashSpace.dialogPad, 32);
      expect(DashRadius.card, 12);
      expect(DashRadius.button, 28);
      expect(DashRadius.chip, 6);
      expect(DashRadius.dialog, 16);
      expect(DashMotion.fast, const Duration(milliseconds: 150));
      expect(DashMotion.normal, const Duration(milliseconds: 250));
      expect(DashMotion.slow, const Duration(milliseconds: 500));
      expect(DashMotion.value, const Duration(milliseconds: 600));
      expect(DashMotion.curve, Curves.easeOutCubic);
      expect(DashMotion.valueCurve, Curves.easeOut);
      expect(DashScrim.backdrop, 0.7);
      expect(DashScrim.glass, 0.95);
    });

    test('no stray radii, press durations or scrim alphas remain in the widget layer', () {
      final radii = <String>[];
      final durations = <String>[];
      final scrims = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart') || f.path.contains('/dev/') || f.path.contains('/theme/')) continue;
        final src = f.readAsStringSync();
        for (final m in RegExp(r'BorderRadius\.circular\((6|8|10|12|14|15|16|22|24|26|28)\)').allMatches(src)) {
          radii.add('${f.path}: ${m.group(0)}');
        }
        if (f.path.contains('/screens/') || f.path.contains('/widgets/')) {
          for (final m in RegExp(r'Duration\(milliseconds: (80|100|120|140|150|160|180|250|280)\)').allMatches(src)) {
            durations.add('${f.path}: ${m.group(0)}');
          }
        }
        for (final m in RegExp(r'ink(Lift)?\.withValues\(alpha: 0\.(7|82|85|88|95|96|97)\)').allMatches(src)) {
          scrims.add('${f.path}: ${m.group(0)}');
        }
      }
      expect(radii, isEmpty);
      expect(durations, isEmpty);
      expect(scrims, isEmpty);
    });

    test('hot text styles share one variation list across accesses', () {
      expect(identical(DashText.speed.fontVariations, DashText.speed.fontVariations), isTrue);
      expect(identical(DashText.clock.fontVariations, DashText.clock.fontVariations), isTrue);
      expect(DashText.speed.color, DashColors.bone);
      expect(DashText.socUnit.color, DashColors.ash);
    });

    test('brightness presets have names', () {
      expect(brightnessLabel(30), 'Low');
      expect(brightnessLabel(60), 'Medium');
      expect(brightnessLabel(100), 'High');
      expect(brightnessLabel(45), '45%');
    });
  });

  group('state', () {
    void withApp(void Function(FakeAsync async, ProviderContainer c, VehicleNotifier v) body) {
      fakeAsync((async) {
        final c = ProviderContainer();
        for (final p in [sessionProvider, toastProvider, lockingProvider, settingsScreenOpenProvider, crashRecoveryProvider]) {
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

    test('locking cancels when the scooter moves during the countdown', () {
      withApp((async, c, v) {
        c.read(lockingProvider.notifier).start();
        expect(c.read(lockingProvider), isTrue);
        async.elapse(const Duration(milliseconds: 800));
        v.setSpeed(9);
        expect(c.read(lockingProvider), isFalse);
        expect(c.read(toastProvider)?.message, 'Locking cancelled — scooter is moving');
        async.elapse(const Duration(seconds: 2));
        expect(c.read(vehicleProvider).locked, isFalse, reason: 'the lock never lands');
      });
    });

    test('safe-mode retry closes every overlay', () {
      withApp((async, c, v) {
        c.listen(diagnosticsOpenProvider, (_, _) {});
        c.listen(licensesScreenOpenProvider, (_, _) {});
        c.read(settingsScreenOpenProvider.notifier).open();
        c.read(diagnosticsOpenProvider.notifier).open();
        c.read(licensesScreenOpenProvider.notifier).open();
        c.read(crashRecoveryProvider.notifier).enterSafeMode();
        expect(c.read(crashRecoveryProvider).safeMode, isTrue);
        c.read(crashRecoveryProvider.notifier).retry();
        expect(c.read(crashRecoveryProvider).safeMode, isFalse);
        expect(c.read(settingsScreenOpenProvider), isFalse);
        expect(c.read(diagnosticsOpenProvider), isFalse);
        expect(c.read(licensesScreenOpenProvider), isFalse);
      });
    });

    test('accent provider only rebuilds for the fields that move the accent', () {
      withApp((async, c, v) {
        var builds = 0;
        c.listen(accentProvider, (_, _) => builds++);
        final before = builds;
        v.setSpeed(0);
        v.setBattery(55);
        v.setPower(2.0);
        v.setMotorTemp(60);
        expect(builds, before, reason: 'speed, battery, power and temperature do not touch the accent');
        v.setVehicleState(VehicleState.ready);
        v.setDriveMode(DriveMode.sport);
        expect(c.read(accentProvider), DashTheme.light.sport);
        expect(
          DashColors.accentOf(isCharging: true, locked: false, vehicleState: VehicleState.ready, driveMode: DriveMode.eco, theme: DashTheme.dark),
          DashTheme.dark.charging,
        );
      });
    });
  });

  group('widgets', () {
    testWidgets('toast lane sits between the dial and the trip strip, and above the nav bar', (tester) async {
      await pumpApp(tester);
      container.read(toastProvider.notifier).show('Hello');
      await settle(tester);
      final toast = tester.getRect(find.byType(ToastPill));
      final trip = tester.getRect(find.byKey(const ValueKey('trip-strip')).evaluate().isEmpty ? find.text('odometer') : find.byKey(const ValueKey('trip-strip')));
      final bar = tester.getRect(find.byType(StatusBar));
      expect(toast.top, greaterThan(bar.bottom));
      expect(toast.bottom, lessThan(trip.top));
      expect(ToastOverlay.top + 52, lessThanOrEqualTo(696));
      v().setNavActive(true);
      container.read(toastProvider.notifier).show('Hello again');
      await settle(tester);
      final navBar = tester.getRect(k('nav-bar'));
      final toast2 = tester.getRect(find.byType(ToastPill));
      expect(toast2.bottom, lessThanOrEqualTo(navBar.top + 0.5));
    });

    testWidgets('wrong PIN shows a hint with the remaining attempts', (tester) async {
      await pumpApp(tester);
      v().setLocked(true);
      await settle(tester);
      Finder key(String d) => find.descendant(of: find.byType(Keypad), matching: find.text(d));
      Future<void> wrong() async {
        for (var i = 0; i < 6; i++) {
          await tester.tap(key('9'));
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 200));
      }

      await wrong();
      expect(find.text('Wrong passcode'), findsOneWidget);
      expect(tester.widget<AnimatedOpacity>(find.ancestor(of: k('wrong-pin-hint'), matching: find.byType(AnimatedOpacity))).opacity, 1);
      await tester.pump(const Duration(milliseconds: 1600));
      expect(tester.widget<AnimatedOpacity>(find.ancestor(of: k('wrong-pin-hint'), matching: find.byType(AnimatedOpacity))).opacity, 0);
      await tester.pump(const Duration(milliseconds: 600));
      await wrong();
      expect(find.text('Wrong passcode (3 attempts left)'), findsOneWidget);
    });

    testWidgets('brightness cycle names the level', (tester) async {
      await pumpApp(tester);
      container.read(brightnessProvider.notifier).cyclePreset();
      await settle(tester);
      expect(find.text('Brightness: High'), findsOneWidget);
    });

    testWidgets('charge-limit popup closes on an outside tap', (tester) async {
      await pumpApp(tester);
      v().setCharging(true);
      v().setHyperCharger(true);
      await settle(tester);
      await tester.tap(k('charge-limit-edit'));
      await settle(tester);
      expect(k('charge-limit-popup'), findsOneWidget);
      await tester.tapAt(const Offset(100, 300));
      await settle(tester);
      expect(k('charge-limit-popup'), findsNothing);
    });

    testWidgets('control panel hides settings and lock while riding', (tester) async {
      await pumpApp(tester);
      container.read(controlPanelOpenProvider.notifier).open();
      await settle(tester);
      expect(k('ctl-settings'), findsOneWidget);
      expect(k('ctl-lock'), findsNothing, reason: 'hidden until locking from the panel works');
      expect(k('ctl-reverse'), findsNothing, reason: 'reverse is the handlebar switch alone');
      v().setSpeed(30);
      v().setLowBeam(true);
      await settle(tester);
      container.read(controlPanelOpenProvider.notifier).open();
      await settle(tester);
      expect(k('ctl-left'), findsNothing);
      expect(k('ctl-right'), findsNothing);
      expect(k('ctl-hazard'), findsOneWidget);
      expect(k('ctl-beam'), findsOneWidget);
      expect(k('ctl-brightness'), findsOneWidget);
      expect(k('ctl-settings'), findsNothing);
      expect(k('ctl-lock'), findsNothing);
      expect(k('ctl-reverse'), findsNothing);
    });

    testWidgets('dev panel toggle is only mounted in debug builds', (tester) async {
      await pumpApp(tester);
      expect(find.byIcon(Icons.tune_rounded), kDebugMode ? findsOneWidget : findsNothing);
    });

    testWidgets('keypad keys keep a border and a tinted face on the Light theme', (tester) async {
      await pumpApp(tester);
      container.read(themeProvider.notifier).setTheme(DashTheme.light);
      await tester.pump(const Duration(milliseconds: 600));
      v().setLocked(true);
      await settle(tester);
      final box = tester.widget<AnimatedContainer>(find.descendant(of: find.byType(Keypad), matching: find.byType(AnimatedContainer)).first);
      final deco = box.decoration as BoxDecoration;
      expect(deco.border, isNotNull);
      expect(deco.color, isNot(DashTheme.light.inkLift), reason: 'face is tinted, not pure white');
      expect(deco.color!.computeLuminance(), lessThan(DashTheme.light.inkLift.computeLuminance()));
    });

    testWidgets('dashboard glyphs are drawn, not Material icons', (tester) async {
      await pumpApp(tester);
      expect(find.descendant(of: find.byType(StatusBar), matching: find.byType(GearIcon)), findsOneWidget);
      expect(find.byIcon(Icons.settings_rounded), findsNothing);
      expect(find.byType(AppsIcon), findsWidgets);
      await tester.fling(find.byType(PageView), const Offset(-120, 0), 800);
      await settle(tester);
      await tester.fling(find.byType(PageView), const Offset(-120, 0), 800);
      await settle(tester);
      expect(find.byType(TripStatIcon), findsNWidgets(5));
      expect(find.byIcon(Icons.route_rounded), findsNothing);
    });
  });
}
