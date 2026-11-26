import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/theme/colors.dart';
import 'package:opendash/state/range_readout.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/battery_health.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/battery_diagnostics_provider.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/battery_health_state.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/ota_state.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/theme/tokens.dart';
import 'package:opendash/widgets/status_bar/overlay_toolbar.dart';
import 'package:opendash/widgets/status_bar/status_bar.dart';

void main() {
  late ProviderContainer container;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);
  Finder k(String id) => find.byKey(ValueKey(id));

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenDashApp()));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    v().setLocked(false);
    await settle(tester);
  }

  Future<void> openSettings(WidgetTester tester) async {
    await pumpApp(tester);
    container.read(settingsScreenOpenProvider.notifier).open();
    await settle(tester);
  }

  Rect canvas(WidgetTester tester) =>
      tester.getRect(find.byWidgetPredicate((w) => w is SizedBox && w.width == 1280 && w.height == 768).first);
  double scale(WidgetTester tester) => canvas(tester).height / 768;
  double designTop(WidgetTester tester, Finder f) => (tester.getRect(f).top - canvas(tester).top) / scale(tester);
  bool statusBarShown(WidgetTester tester) => tester.getRect(find.byType(StatusBar)).top >= canvas(tester).top - 0.5;

  void setTrueRange(bool on) => container.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.predictedRange, on);

  group('fade-through switchers', () {
    testWidgets('settings section switch never shows both sections at once', (tester) async {
      await openSettings(tester);
      final switcher = find.ancestor(of: k('section-display'), matching: find.byType(AnimatedSwitcher));
      expect(switcher, findsNothing, reason: 'sidebar items are outside the switcher');
      final body = find.ancestor(
        of: find.byKey(const ValueKey(SettingsSection.display)),
        matching: find.byType(AnimatedSwitcher),
      );
      expect(tester.widget<AnimatedSwitcher>(body).transitionBuilder, DashMotion.fadeThrough);

      await tester.tap(k('section-sound'));
      Iterable<double> opacities() => tester
          .widgetList<FadeTransition>(find.descendant(
            of: body,
            matching: find.byWidgetPredicate((w) => w is FadeTransition && w.child is SingleChildScrollView),
          ))
          .map((f) => f.opacity.value);
      await tester.pump();
      var elapsed = 0;
      for (final step in [5, 25, 25, 25, 25, 25, 15]) {
        await tester.pump(Duration(milliseconds: step));
        elapsed += step;
        final visible = opacities().where((o) => o > 0.01).length;
        expect(visible, lessThanOrEqualTo(1), reason: 'at ${elapsed}ms both panels were visible: ${opacities().toList()}');
      }
      expect(opacities().length, 2, reason: 'both entries are still mounted at 145ms');
      await settle(tester);
      expect(find.byKey(const ValueKey(SettingsSection.sound)), findsOneWidget);
      expect(find.byKey(const ValueKey(SettingsSection.display)), findsNothing);
    });

    testWidgets('diagnostics tabs and OTA states use the same builder', (tester) async {
      await openSettings(tester);
      container.read(diagnosticsOpenProvider.notifier).open();
      await settle(tester);
      final diag = find.ancestor(of: k('diag-battery'), matching: find.byType(AnimatedSwitcher));
      expect(tester.widget<AnimatedSwitcher>(diag.first).transitionBuilder, DashMotion.fadeThrough);
      container.read(diagnosticsOpenProvider.notifier).close();
      container.read(otaScreenOpenProvider.notifier).open();
      await settle(tester);
      final ota = find.descendant(of: k('ota-body'), matching: find.byType(AnimatedSwitcher));
      expect(tester.widget<AnimatedSwitcher>(ota.first).transitionBuilder, DashMotion.fadeThrough);
    });
  });

  group('true range toggle', () {
    testWidgets('shows only the stock range when the feature is off', (tester) async {
      await pumpApp(tester);
      expect(container.read(rangeReadoutProvider).kind, RangeKind.trueRange);
      expect(find.text('range'), findsOneWidget, reason: 'one caption, whichever figure it is');
      setTrueRange(false);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('range'), findsOneWidget);
      expect(find.text('${container.read(vehicleProvider).range}'), findsOneWidget);
      // The scooter's own figure is already what is shown: nothing to peek at.
      await tester.tap(k('range'));
      await settle(tester);
      expect(k('range-peek'), findsNothing);
    });

    testWidgets('mid confidence rounds and dims the learned range; a tap shows the scooter\'s estimate', (tester) async {
      await pumpApp(tester);
      // Odometer values are km, not metres.
      RideSegment slow(int i) => RideSegment(
            startSoc: 90,
            endSoc: 80,
            startOdometer: i * 5,
            endOdometer: i * 5 + 5,
            driveMode: 2,
            avgTempC: 30,
            timestamp: i,
          );
      container.read(batteryHealthProvider.notifier).seedSegments([for (var i = 0; i < 4; i++) slow(i)]);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 700));
      final tr = container.read(trueRangeProvider);
      expect(tr.confidencePercent, 40);
      expect(tr.trueRangeKm, lessThan(tr.stockRangeKm * 0.9));
      expect(find.text('range'), findsOneWidget);
      expect(find.text('~'), findsNothing);
      expect(find.textContaining('Stock'), findsNothing);
      final shown = (tr.trueRangeKm / 5).round() * 5;
      expect(tester.widget<Text>(find.descendant(of: k('range-value'), matching: find.byType(Text))).data, '$shown');
      expect(tester.widget<Text>(find.descendant(of: k('range-value'), matching: find.byType(Text))).style!.color, DashColors.ash);

      await tester.tap(k('range'));
      await settle(tester);
      expect(tester.widget<Text>(k('range-peek')).data, 'Scooter estimates ${tr.stockRangeKm} km');
      expect(find.text('Learned from ${tr.ridesUsed} rides'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await settle(tester);
      expect(k('range-peek'), findsNothing, reason: 'the peek goes by itself');

      container.read(batteryHealthProvider.notifier).seedSegments([for (var i = 0; i < 8; i++) slow(i)]);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 700));
      final exact = container.read(trueRangeProvider).trueRangeKm;
      expect(tester.widget<Text>(find.descendant(of: k('range-value'), matching: find.byType(Text))).data, '$exact',
          reason: 'high confidence shows the figure as it is');
      expect(tester.widget<Text>(find.descendant(of: k('range-value'), matching: find.byType(Text))).style!.color, DashColors.bone);

      setTrueRange(false);
      await settle(tester);
      expect(find.text('range'), findsOneWidget);
    });

    testWidgets('cell warning icon hides when the feature is off, data keeps flowing', (tester) async {
      await pumpApp(tester);
      container.read(batteryDiagnosticsProvider.notifier).setDegradedCells(true);
      for (var i = 0; i < 5; i++) {
        await tester.pump(BatteryHealthNotifier.sampleInterval);
      }
      await settle(tester);
      expect(container.read(cellWarningProvider), isNotNull);
      expect(k('status-cell-warning'), findsNothing, reason: 'a pack that rests uneven is not a status-bar warning');
      // Under hard load the weak cell gives way: now it is.
      v().setVehicleState(VehicleState.riding);
      v().setSpeed(40);
      v().setPower(8);
      for (var i = 0; i < 3; i++) {
        await tester.pump(BatteryHealthNotifier.sampleInterval);
      }
      await settle(tester);
      expect(k('status-cell-warning'), findsOneWidget);
      expect(find.text('Weak cell'), findsOneWidget, reason: 'spelled out, not a bare glyph');
      setTrueRange(false);
      await settle(tester);
      expect(k('status-cell-warning'), findsNothing);
      expect(container.read(cellWarningProvider), isNotNull, reason: 'the monitor keeps running');
      setTrueRange(true);
      await settle(tester);
      expect(k('status-cell-warning'), findsOneWidget);
    });
  });

  group('toolbar, call bar and peek fixes', () {
    testWidgets('overlay toolbar back closes the passcode screen first', (tester) async {
      await openSettings(tester);
      await tester.ensureVisible(k('section-passcode'));
      await tester.tap(k('section-passcode'));
      await settle(tester);
      expect(container.read(changePasscodeOpenProvider), isTrue);
      expect(k('passcode-back'), findsNothing);
      await tester.tap(k('toolbar-back'));
      await settle(tester);
      expect(container.read(changePasscodeOpenProvider), isFalse);
      expect(container.read(settingsScreenOpenProvider), isTrue);
      await tester.tap(k('toolbar-back'));
      await settle(tester);
      expect(container.read(settingsScreenOpenProvider), isFalse);
    });

    testWidgets('active call bar sits under the toolbar and shifts overlay content down', (tester) async {
      await openSettings(tester);
      expect(designTop(tester, k('settings-body')), closeTo(0, 1));
      v().simulateIncomingCall();
      v().acceptCall();
      await settle(tester);
      expect(designTop(tester, k('active-call')), closeTo(OverlayToolbar.height, 1));
      expect(designTop(tester, k('settings-body')), closeTo(56, 1));
      v().setLimpMode(true);
      await settle(tester);
      expect(designTop(tester, k('alert-banner')), closeTo(OverlayToolbar.height, 1));
      expect(designTop(tester, k('active-call')), closeTo(OverlayToolbar.height + 88, 1), reason: 'under the banner');
      expect(designTop(tester, k('settings-body')), closeTo(88 + 56, 1));
      v().setLimpMode(false);
      container.read(settingsScreenOpenProvider.notifier).close();
      await settle(tester);
      expect(designTop(tester, k('active-call')), closeTo(StatusBar.height, 1));
      v().endCall();
      await settle(tester);
      expect(k('active-call'), findsNothing);
    });

    testWidgets('status bar peek restarts its timer on tap', (tester) async {
      await openSettings(tester);
      await tester.drag(k('overlay-toolbar'), const Offset(0, 80));
      await settle(tester);
      expect(statusBarShown(tester), isTrue);
      await tester.pump(const Duration(seconds: 2));
      final c = canvas(tester);
      await tester.tapAt(Offset(c.left + 400 * scale(tester), c.top + 36 * scale(tester)));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(statusBarShown(tester), isTrue, reason: 'the tap bought another three seconds');
      expect(container.read(settingsScreenOpenProvider), isTrue);
      await tester.pump(const Duration(seconds: 1, milliseconds: 200));
      await settle(tester);
      expect(statusBarShown(tester), isFalse);
    });

    testWidgets('alert banner drops below the peeking status bar', (tester) async {
      await openSettings(tester);
      v().setLimpMode(true);
      await settle(tester);
      expect(designTop(tester, k('alert-banner')), closeTo(OverlayToolbar.height, 1));
      await tester.drag(k('overlay-toolbar'), const Offset(0, 80));
      await settle(tester);
      expect(statusBarShown(tester), isTrue);
      expect(designTop(tester, k('alert-banner')), closeTo(StatusBar.height, 1));
      await tester.pump(const Duration(seconds: 3, milliseconds: 200));
      await settle(tester);
      expect(statusBarShown(tester), isFalse);
      expect(designTop(tester, k('alert-banner')), closeTo(OverlayToolbar.height, 1));
    });

    testWidgets('display section opens on the brightness controls', (tester) async {
      await openSettings(tester);
      container.read(settingsSectionProvider.notifier).set(SettingsSection.display);
      await settle(tester);
      final brightness = tester.getRect(find.text('Brightness'));
      final theme = tester.getRect(find.text('THEME'));
      expect(brightness.top, lessThan(theme.top));
      expect(designTop(tester, find.text('Auto brightness')), lessThan(200));
    });

    testWidgets('auto brightness swaps the one slider for a day and a night level', (tester) async {
      await openSettings(tester);
      container.read(settingsSectionProvider.notifier).set(SettingsSection.display);
      await settle(tester);
      expect(find.text('Brightness'), findsOneWidget, reason: 'auto off: the plain slider');
      expect(find.text('Day brightness'), findsNothing);
      container.read(vehicleProvider.notifier).setAmbientUsable(false);
      container.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoBrightness, true);
      await settle(tester);
      expect(find.text('Brightness'), findsNothing);
      expect(find.text('Day brightness'), findsOneWidget);
      expect(find.text('Night brightness'), findsOneWidget);

      container.read(vehicleProvider.notifier).setAmbientUsable(true);
      await settle(tester);
      expect(find.text('Day brightness'), findsNothing, reason: 'a working light sensor sets the level instead');
      expect(find.byKey(const ValueKey('auto-brightness-note')), findsOneWidget);
    });
  });
}
