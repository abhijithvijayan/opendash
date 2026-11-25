import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/widgets/controls/trunk_button.dart';
import 'package:opendash/widgets/status_bar/status_icons.dart';
import 'package:opendash/widgets/indicators/beam_icon.dart';
import 'package:opendash/widgets/indicators/mode_ladder.dart';
import 'package:opendash/widgets/gauges/battery_ring.dart';
import 'package:opendash/widgets/panel/widget_panel.dart';
import 'package:opendash/widgets/status_bar/status_bar.dart';
import 'package:opendash/widgets/status_bar/overlay_toolbar.dart';
import 'package:opendash/screens/locked/keypad.dart';
import 'package:opendash/screens/locked/locked_screen.dart';
import 'package:opendash/state/media_state.dart';
import 'package:opendash/state/ota_state.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/settings_state.dart';

void main() {
  late ProviderContainer container;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);
  Finder k(String id) => find.byKey(ValueKey(id));

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

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
    await settle(tester);
  }

  group('trunk button', () {
    testWidgets('sits on the dashboard while parked, toggles the boot and is big enough for gloves', (tester) async {
      await pumpApp(tester);
      expect(k('dash-trunk'), findsOneWidget);
      final size = tester.getSize(k('dash-trunk'));
      expect(size.width, greaterThanOrEqualTo(72));
      expect(size.height, greaterThanOrEqualTo(72));
      expect(find.descendant(of: k('dash-trunk'), matching: find.text('TRUNK')), findsOneWidget);
      expect(find.descendant(of: find.byType(StatusBar), matching: find.byType(TrunkOpenIcon)), findsNothing);
      await tester.tap(k('dash-trunk'));
      await settle(tester);
      expect(container.read(vehicleProvider).trunkOpen, isTrue);
      expect(tester.widget<TrunkButton>(find.byType(TrunkButton)).open, isTrue);
      expect(find.descendant(of: find.byType(StatusBar), matching: find.byType(TrunkOpenIcon)), findsOneWidget);
      await tester.tap(k('dash-trunk'));
      await settle(tester);
      expect(container.read(vehicleProvider).trunkOpen, isFalse);
      expect(find.descendant(of: find.byType(StatusBar), matching: find.byType(TrunkOpenIcon)), findsNothing);
    });

    testWidgets('stays while ready, goes while riding, and comes back on a stop', (tester) async {
      await pumpApp(tester);
      v().setVehicleState(VehicleState.ready);
      await settle(tester);
      expect(k('dash-trunk'), findsOneWidget);
      v().setSpeed(30);
      await settle(tester);
      expect(k('dash-trunk'), findsNothing);
      v().setSpeed(0);
      await settle(tester);
      expect(k('dash-trunk'), findsOneWidget);
    });

    // The rider once could not open the boot while charging. Stock
    // keeps its Park screen, trunk button included, on the charger.
    testWidgets('is on the charging screen, not on the lock screen', (tester) async {
      await pumpApp(tester);
      v().setCharging(true);
      await settle(tester);
      expect(k('dash-trunk'), findsOneWidget);
      v().setCharging(false);
      v().setLocked(true);
      await settle(tester);
      expect(k('dash-trunk'), findsNothing);
    });

    testWidgets('does nothing until the trunk state is known', (tester) async {
      await pumpApp(tester);
      v().setConnected(false);
      v().simulateBoot();
      await tester.pump();
      await tester.tap(k('dash-trunk'));
      await tester.pump();
      expect(container.read(vehicleProvider).trunkOpen, isFalse);
    });
  });

  group('mode ladder', () {
    Finder ladder() => find.descendant(of: find.byType(ModeLadder), matching: find.text('NORMAL'));

    testWidgets('is hidden while parked and appears with the motor', (tester) async {
      await pumpApp(tester);
      expect(container.read(vehicleProvider).vehicleState, VehicleState.parked);
      expect(ladder(), findsNothing);
      v().setVehicleState(VehicleState.ready);
      await settle(tester);
      expect(ladder(), findsOneWidget);
      v().setSpeed(30);
      await settle(tester);
      expect(ladder(), findsOneWidget);
      v().autoPark();
      await settle(tester);
      expect(ladder(), findsNothing);
    });

    testWidgets('fades rather than popping', (tester) async {
      await pumpApp(tester);
      v().setVehicleState(VehicleState.ready);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final fades = find.ancestor(of: find.byType(ModeLadder), matching: find.byType(FadeTransition));
      expect(fades, findsWidgets);
      final t = tester.widget<FadeTransition>(fades.first).opacity.value;
      expect(t, greaterThan(0));
      expect(t, lessThan(1));
    });
  });

  group('widget panel layout', () {
    Future<void> swipeLeft(WidgetTester tester) async {
      await tester.fling(find.byType(PageView), const Offset(-90, 0), 700);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
    }

    /// Top gap above [first] against the gap between [last] and the dots
    /// reserve, in the test window's scaled frame.
    void expectCentered(WidgetTester tester, Finder first, Finder last) {
      final panel = tester.getRect(find.byType(WidgetPanel));
      final scale = panel.height / WidgetPanel.height;
      final reserved = panel.bottom - WidgetPanel.dotsReserve * scale;
      final topGap = tester.getRect(first).top - panel.top;
      final bottomGap = reserved - tester.getRect(last).bottom;
      expect(topGap, greaterThan(0));
      expect(bottomGap, greaterThan(0));
      expect((topGap - bottomGap).abs(), lessThan(12 * scale), reason: 'top gap $topGap vs bottom gap $bottomGap');
      final dots = tester.getRect(find.byType(PageDots));
      expect((panel.bottom - dots.bottom).abs(), lessThan(2), reason: 'dots stay pinned to the bottom');
    }

    testWidgets('battery page centres the ring and its stats as one group', (tester) async {
      await pumpApp(tester);
      expectCentered(tester, find.byType(BatteryRing), k('range-caption'));
      final ring = tester.getRect(find.byType(BatteryRing));
      final range = tester.getRect(k('range-caption'));
      expect(range.top, greaterThan(ring.bottom), reason: 'stats follow the ring');
    });

    testWidgets('performance page is centred', (tester) async {
      await pumpApp(tester);
      await swipeLeft(tester);
      // Motor gauge label at the top, the last temp row (BMS) at the bottom.
      expectCentered(tester, find.text('Motor'), k('bms-temp'));
    });

    testWidgets('trip stats page is centred', (tester) async {
      await pumpApp(tester);
      await swipeLeft(tester);
      await swipeLeft(tester);
      expectCentered(tester, find.text('Today'), k('mode-bar-hyper'));
    });
  });

  group('overlay toolbar', () {
    // The design canvas is letterboxed inside the test window.
    Rect canvas(WidgetTester tester) => tester.getRect(
        find.byWidgetPredicate((w) => w is SizedBox && w.width == 1280 && w.height == 768).first);
    double scale(WidgetTester tester) => canvas(tester).height / 768;
    String title(WidgetTester tester) => tester.widget<Text>(k('toolbar-title')).data!;
    bool statusBarShown(WidgetTester tester) =>
        tester.getRect(find.byType(StatusBar)).top >= canvas(tester).top - 0.5;

    testWidgets('replaces the status bar while settings is open and the back arrow closes it', (tester) async {
      await pumpApp(tester);
      expect(k('overlay-toolbar'), findsNothing);
      expect(statusBarShown(tester), isTrue);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      expect(k('overlay-toolbar'), findsOneWidget);
      expect(title(tester), 'Settings');
      expect(statusBarShown(tester), isFalse, reason: 'the full bar slid up');
      final bar = tester.getRect(k('overlay-toolbar'));
      expect(bar.top, closeTo(canvas(tester).top, 0.5));
      expect(bar.height, closeTo(OverlayToolbar.height * scale(tester), 0.5));
      expect(tester.widget<Text>(k('toolbar-clock')).data, container.read(vehicleProvider).time);
      expect(tester.widget<Text>(k('toolbar-battery')).data, '${container.read(vehicleProvider).batterySoc}%');
      final back = tester.getSize(k('toolbar-back'));
      expect(back.width, greaterThanOrEqualTo(56 * scale(tester) - 0.5));
      expect(back.height, greaterThanOrEqualTo(56 * scale(tester) - 0.5));
      expect(tester.widget<Icon>(find.descendant(of: k('toolbar-back'), matching: find.byType(Icon))).size, 30,
          reason: 'the universal back arrow is the prominent one');
      await tester.tap(k('toolbar-back'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(container.read(settingsScreenOpenProvider), isFalse);
      final sliding = tester.getRect(k('overlay-toolbar'));
      expect(sliding.top, lessThan(canvas(tester).top), reason: 'sliding out, not gone');
      expect(sliding.bottom, greaterThan(canvas(tester).top), reason: 'still partly visible mid-slide');
      expect(title(tester), 'Settings', reason: 'keeps its title while it leaves');
      await settle(tester);
      expect(k('overlay-toolbar'), findsNothing);
      expect(statusBarShown(tester), isTrue);
    });

    testWidgets('names every overlay and backs out of children into settings', (tester) async {
      await pumpApp(tester);
      container.read(appLauncherOpenProvider.notifier).open();
      await settle(tester);
      expect(title(tester), 'Apps');
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      final children = <(bool Function(), void Function(), String)>[
        (() => container.read(btScreenOpenProvider), container.read(btScreenOpenProvider.notifier).open, 'Bluetooth Devices'),
        (() => container.read(diagnosticsOpenProvider), container.read(diagnosticsOpenProvider.notifier).open, 'Diagnostics'),
        (() => container.read(otaScreenOpenProvider), container.read(otaScreenOpenProvider.notifier).open, 'Updates'),
        (() => container.read(licensesScreenOpenProvider), container.read(licensesScreenOpenProvider.notifier).open, 'Licenses'),
      ];
      for (final (isOpen, open, t) in children) {
        open();
        await settle(tester);
        expect(title(tester), t);
        await tester.tap(k('toolbar-back'));
        await settle(tester);
        expect(isOpen(), isFalse, reason: '$t closed');
        expect(container.read(settingsScreenOpenProvider), isTrue, reason: 'settings underneath');
        expect(title(tester), 'Settings');
      }
    });

    testWidgets('overlays no longer carry their own back buttons or titles', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      final arrow = find.byIcon(Icons.arrow_back_rounded);
      expect(find.ancestor(of: arrow, matching: find.byType(OverlayToolbar)), findsOneWidget);
      // The change-passcode sub-view has no arrow of its own; the toolbar's
      // arrow steps back out of it.
      expect(find.descendant(of: k('settings-body'), matching: arrow), findsNothing);
      expect(arrow, findsOneWidget, reason: 'no settings header arrow');
      expect(find.text('Settings'), findsOneWidget, reason: 'only the toolbar title');
      container.read(btScreenOpenProvider.notifier).open();
      await settle(tester);
      expect(find.descendant(of: k('bt-body'), matching: arrow), findsNothing);
      expect(find.descendant(of: k('bt-body'), matching: find.text('Bluetooth Devices')), findsNothing);
      final body = tester.getRect(find.textContaining('Visible as'));
      expect(body.top, greaterThanOrEqualTo(OverlayToolbar.height * scale(tester) - 0.5), reason: 'content starts under the toolbar');
    });

    testWidgets('pull-down peeks the full status bar for three seconds', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      expect(statusBarShown(tester), isFalse);
      await tester.drag(k('overlay-toolbar'), const Offset(0, 80));
      await settle(tester);
      expect(statusBarShown(tester), isTrue);
      // The bar needs its own opaque backdrop, not the canvas's, or the
      // toolbar's title shows through it while it peeks.
      final backdrop = tester.widget<ColoredBox>(find.ancestor(of: find.byType(StatusBar), matching: find.byType(ColoredBox)).first);
      expect(backdrop.color.a, 1.0);
      expect(find.descendant(of: find.byWidget(backdrop), matching: find.byType(OverlayToolbar)), findsNothing,
          reason: 'the peeking bar covers the toolbar, not blends with it');
      await tester.pump(const Duration(seconds: 2));
      expect(statusBarShown(tester), isTrue);
      await tester.pump(const Duration(seconds: 1, milliseconds: 100));
      await settle(tester);
      expect(statusBarShown(tester), isFalse, reason: 'auto-hides');
      await tester.drag(k('overlay-toolbar'), const Offset(0, 80));
      await settle(tester);
      expect(statusBarShown(tester), isTrue);
      await tester.tapAt(Offset(canvas(tester).center.dx, canvas(tester).center.dy));
      await settle(tester);
      expect(statusBarShown(tester), isFalse, reason: 'a tap outside hides it');
      expect(container.read(settingsScreenOpenProvider), isTrue);
    });

    testWidgets('critical alerts still banner under the toolbar; warnings wait for the overlay to close', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      v().setBrakeWorn(true);
      await settle(tester);
      expect(k('alert-banner'), findsNothing, reason: 'warning queued');
      v().setLimpMode(true);
      await settle(tester);
      expect(k('alert-banner'), findsOneWidget);
      final banner = tester.getRect(k('alert-banner'));
      expect(banner.top, closeTo(tester.getRect(k('overlay-toolbar')).bottom, 1));
      expect(find.text('Limp mode'), findsOneWidget);
      expect(find.text('Brakes worn'), findsNothing);
      v().setLimpMode(false);
      container.read(settingsScreenOpenProvider.notifier).close();
      await settle(tester);
      expect(find.text('Brakes worn'), findsOneWidget, reason: 'warning shows once the overlay is gone');
    });

    testWidgets('no status bar or toolbar on boot, lock and sleep', (tester) async {
      await boot(tester);
      expect(find.byType(LockedScreen), findsOneWidget);
      expect(find.byType(StatusBar), findsNothing);
      expect(k('overlay-toolbar'), findsNothing);
      container.read(sessionProvider.notifier).simulateAidlTimeout();
      await settle(tester);
      expect(container.read(screenStateProvider), ScreenState.booting);
      expect(find.byType(StatusBar), findsNothing);
      v().setConnected(true);
      v().setLocked(false);
      await settle(tester);
      expect(find.byType(StatusBar), findsOneWidget);
      container.read(sessionProvider.notifier).sleep();
      await settle(tester);
      expect(find.byType(StatusBar), findsNothing);
      v().setCharging(true);
      container.read(sessionProvider.notifier).wake();
      await settle(tester);
      expect(container.read(screenStateProvider), ScreenState.charging);
      expect(find.byType(StatusBar), findsOneWidget);
    });

    testWidgets('lock screen keypad is centred in the full height', (tester) async {
      await boot(tester);
      final c = canvas(tester);
      final s = scale(tester);
      final dots = tester.getRect(find.byType(PinDots));
      final keypad = tester.getRect(find.byType(Keypad));
      expect(dots.top - c.top, lessThan(100 * s), reason: 'moved up into the freed band');
      expect(keypad.bottom, lessThanOrEqualTo(c.bottom));
      // The block sits a little low: the top 88px stay clear for an alert banner.
      final topGap = dots.top - c.top;
      final bottomGap = c.bottom - keypad.bottom;
      expect((topGap - bottomGap).abs(), lessThan(40 * s), reason: 'top gap $topGap vs bottom gap $bottomGap');
    });
  });

  group('overlay toolbar while riding', () {
    Rect canvas(WidgetTester tester) => tester.getRect(
        find.byWidgetPredicate((w) => w is SizedBox && w.width == 1280 && w.height == 768).first);

    testWidgets('riding closes a normal overlay and brings back the full status bar and its warnings', (tester) async {
      await pumpApp(tester);
      // Settings closes the moment the scooter moves. (Diagnostics is the one
      // exception — it rides, with the island over it; diagnostics_safe_mode_widget_test covers that.)
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      expect(k('overlay-toolbar'), findsOneWidget);
      v().setSpeed(30);
      await settle(tester);
      expect(container.read(settingsScreenOpenProvider), isFalse);
      final c = canvas(tester);
      final bar = tester.getRect(find.byType(StatusBar));
      expect(bar.top, closeTo(c.top, 0.5), reason: 'turn signals and beams are back');
      expect(k('overlay-toolbar'), findsNothing);
      v().setBrakeWorn(true);
      await settle(tester);
      expect(k('alert-banner'), findsOneWidget, reason: 'warnings show while riding');
      expect(tester.getRect(k('alert-banner')).top, closeTo(bar.bottom, 0.5));
      v().setSpeed(0);
      await settle(tester);
      expect(k('overlay-toolbar'), findsNothing, reason: 'stopping does not reopen it');
    });
  });

  group('lock screen alerts', () {
    testWidgets('a banner on the lock screen sits above the dots and keypad, not over them', (tester) async {
      await boot(tester);
      v().failUnlock();
      await settle(tester);
      expect(k('alert-banner'), findsOneWidget);
      final banner = tester.getRect(k('alert-banner'));
      final canvas = tester.getRect(
          find.byWidgetPredicate((w) => w is SizedBox && w.width == 1280 && w.height == 768).first);
      expect(banner.top, closeTo(canvas.top, 0.5), reason: 'no status bar to sit under');
      expect(banner.overlaps(tester.getRect(find.byType(PinDots))), isFalse);
      expect(banner.overlaps(tester.getRect(find.byType(Keypad))), isFalse);
      expect(banner.overlaps(tester.getRect(find.text('Emergency'))), isFalse);
    });
  });

  group('lights', () {
    testWidgets('control panel light button shows only with the headlamp lit', (tester) async {
      await pumpApp(tester);
      v().setPositionLight(true);
      await tester.tap(k('ctl-handle'));
      await settle(tester);
      expect(k('ctl-beam'), findsNothing, reason: 'the DRL switch never moved the lamp');
      expect(k('status-position-light'), findsOneWidget, reason: 'status bar shows the halo');
      expect(k('tt-positionLight'), findsNothing, reason: 'the status bar carries it, not the strip');
      v().setLowBeam(true);
      await settle(tester);
      expect(find.descendant(of: k('ctl-beam'), matching: find.text('LOW')), findsOneWidget);
    });

    testWidgets('control panel light button swaps low and high beam while riding', (tester) async {
      await pumpApp(tester);
      v().setSpeed(30);
      await settle(tester);
      await tester.tap(k('ctl-handle'));
      await settle(tester);
      expect(find.descendant(of: k('ctl-beam'), matching: find.text('LOW')), findsOneWidget);
      expect(k('status-position-light'), findsOneWidget, reason: 'the DRL stays on with a beam');
      BeamIcon bar(bool high) => tester.widget<BeamIcon>(
          find.descendant(of: find.byType(StatusBar), matching: find.byWidgetPredicate((w) => w is BeamIcon && w.high == high)));
      expect(bar(false).on, isTrue);
      expect(bar(true).on, isFalse);
      await tester.tap(k('ctl-beam'));
      await settle(tester);
      expect(container.read(vehicleProvider).highBeam, isTrue);
      expect(find.descendant(of: k('ctl-beam'), matching: find.text('HIGH')), findsOneWidget);
      expect(bar(true).on, isTrue);
      expect(bar(false).on, isFalse);
      await tester.tap(k('ctl-beam'));
      await settle(tester);
      expect(container.read(vehicleProvider).lowBeam, isTrue);
      expect(find.descendant(of: k('ctl-beam'), matching: find.text('LOW')), findsOneWidget);
    });

    testWidgets('position light indicator stays with a lit beam, and goes only with the DRL', (tester) async {
      await pumpApp(tester);
      v().setVehicleState(VehicleState.ready);
      await settle(tester);
      expect(k('status-position-light'), findsOneWidget);
      v().setHighBeam(true);
      await settle(tester);
      expect(k('status-position-light'), findsOneWidget);
      v().setHighBeam(false);
      v().setLowBeam(true);
      await settle(tester);
      expect(k('status-position-light'), findsOneWidget);
      v().setPositionLight(false);
      await settle(tester);
      expect(k('status-position-light'), findsNothing);
    });
  });
}
