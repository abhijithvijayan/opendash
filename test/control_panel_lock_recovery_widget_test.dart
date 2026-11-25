import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/constants.dart';
import 'package:opendash/screens/settings/sections/about_section.dart';
import 'package:opendash/main.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/boot/boot_screen.dart';
import 'package:opendash/state/control_panel.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/error_state.dart';
import 'package:opendash/state/format_settings.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/theme/colors.dart';
import 'package:opendash/widgets/controls/control_panel.dart';
import 'package:opendash/widgets/media/now_playing_bar.dart';
import 'package:opendash/widgets/panel/widget_panel.dart';

void main() {
  // The lock button is hidden on the scooter for now; these keep it working for when it returns.
  setUp(() => ControlPanel.showLock = true);
  tearDown(() => ControlPanel.showLock = false);

  late ProviderContainer container;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);
  Finder k(String id) => find.byKey(ValueKey(id));

  Future<void> boot(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [platformServiceProvider.overrideWithValue(MockPlatformService())],
      child: const OpenDashApp(),
    ));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await boot(tester);
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

  Future<void> swipeLeft(WidgetTester tester) async {
    await tester.fling(find.byType(PageView), const Offset(-120, 0), 800);
    await settle(tester);
  }

  group('control panel', () {
    testWidgets('edge swipe opens, swipe back closes, chevron turns, handle still taps', (tester) async {
      await pumpApp(tester);
      expect(container.read(controlPanelOpenProvider), isFalse);
      await tester.fling(k('ctl-edge'), const Offset(-120, 0), 900);
      await settle(tester);
      expect(container.read(controlPanelOpenProvider), isTrue);
      expect(tester.widget<AnimatedRotation>(k('ctl-chevron')).turns, 0.5);
      await tester.fling(k('ctl-surface'), const Offset(140, 0), 900);
      await settle(tester);
      expect(container.read(controlPanelOpenProvider), isFalse);
      expect(tester.widget<AnimatedRotation>(k('ctl-chevron')).turns, 0);
      await tester.tap(k('ctl-handle'));
      await settle(tester);
      expect(container.read(controlPanelOpenProvider), isTrue);
    });

    testWidgets('labels, group dividers and an opaque surface; no indicator or reverse buttons', (tester) async {
      await pumpApp(tester);
      v().setLowBeam(true);
      await tester.tap(k('ctl-handle'));
      await settle(tester);
      for (final id in ['left', 'right', 'reverse']) {
        expect(k('ctl-$id'), findsNothing, reason: id);
      }
      for (final label in ['HAZ', 'LOW', 'SET', 'LOCK']) {
        expect(find.descendant(of: k('ctl-surface'), matching: find.text(label)), findsOneWidget, reason: label);
      }
      expect(k('ctl-divider'), findsNWidgets(1));
      final surface = tester.widget<Container>(k('ctl-surface'));
      expect((surface.decoration as BoxDecoration).color!.a, 1.0);
      for (final id in ['hazard', 'beam', 'brightness', 'settings', 'lock']) {
        expect(tester.widget<ControlButton>(k('ctl-$id')).size, greaterThanOrEqualTo(44), reason: id);
      }
    });

    testWidgets('charging panel shows brightness, settings and lock only', (tester) async {
      await pumpApp(tester);
      v().setCharging(true);
      await settle(tester);
      await tester.tap(k('ctl-handle'));
      await settle(tester);
      for (final id in ['brightness', 'settings', 'lock']) {
        expect(k('ctl-$id'), findsOneWidget, reason: id);
      }
      for (final id in ['left', 'right', 'hazard', 'beam', 'reverse']) {
        expect(k('ctl-$id'), findsNothing, reason: id);
      }
    });

    testWidgets('confirming the lock runs the progress ring before locking', (tester) async {
      await pumpApp(tester);
      await tester.tap(k('ctl-handle'));
      await settle(tester);
      await tester.tap(k('ctl-lock'));
      await tester.pump();
      await tester.tap(k('ctl-lock'));
      await tester.pump();
      expect(container.read(lockingProvider), isTrue);
      expect(k('lock-progress'), findsOneWidget);
      expect(tester.widget<ControlButton>(k('ctl-lock')).enabled, isFalse);
      await tester.pump(const Duration(milliseconds: 800));
      final painter = tester.widget<CustomPaint>(k('lock-progress')).painter as LockProgressPainter;
      expect(painter.progress, greaterThan(0));
      expect(painter.progress, lessThan(1));
      await tester.pump(const Duration(milliseconds: 800));
      await settle(tester);
      expect(container.read(vehicleProvider).locked, isTrue);
    });
  });

  group('lock screen', () {
    testWidgets('brightness button cycles presets; version and keypad sizes', (tester) async {
      await boot(tester);
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      expect(k('lock-brightness'), findsOneWidget);
      expect(tester.widget<ControlButton>(k('lock-brightness')).size, greaterThanOrEqualTo(44));
      expect(container.read(brightnessProvider), 80);
      await tester.tap(k('lock-brightness'));
      await settle(tester);
      expect(container.read(brightnessProvider), 100);
      expect(find.text('Brightness: High'), findsOneWidget);
      expect(find.descendant(of: k('lock-version'), matching: find.text('v$appVersion'), matchRoot: true), findsOneWidget);
      expect(tester.getSize(find.text('5').first).shortestSide, lessThanOrEqualTo(96));
    });

    testWidgets('date order follows the setting', (tester) async {
      await boot(tester);
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      final now = DateTime.now();
      expect(find.text(formatDate(now)), findsOneWidget);
      container.read(dateOrderProvider.notifier).set(DateOrder.monthDay);
      await settle(tester);
      expect(find.text(formatDate(now, order: DateOrder.monthDay)), findsOneWidget);
    });
  });

  testWidgets('media progress bar and times tick with playback', (tester) async {
    await pumpApp(tester);
    v().setMediaPlaying(true);
    await settle(tester);
    expect(k('np-progress'), findsOneWidget);
    expect(find.descendant(of: k('np-elapsed'), matching: find.text('0:00'), matchRoot: true), findsOneWidget);
    expect(find.descendant(of: k('np-total'), matching: find.text('4:18'), matchRoot: true), findsOneWidget);
    v().tickMedia();
    await settle(tester);
    final position = container.read(vehicleProvider).mediaPosition;
    expect(position, greaterThanOrEqualTo(1));
    expect(find.descendant(of: k('np-elapsed'), matching: find.text(formatSeconds(position)), matchRoot: true), findsOneWidget);
    expect(tester.widget<MediaProgressBar>(k('np-progress')).fraction, closeTo(position / 258, 1e-9));
  });

  testWidgets('bluetooth pairing overlay shows the code, hides while riding, confirm clears', (tester) async {
    await pumpApp(tester);
    v().startPairing();
    await settle(tester);
    expect(k('bt-pairing'), findsOneWidget);
    expect(find.descendant(of: k('bt-pairing-code'), matching: find.text('4 8 2 9 1 7'), matchRoot: true), findsOneWidget);
    v().setSpeed(30);
    await settle(tester);
    expect(k('bt-pairing'), findsNothing, reason: 'hidden while riding');
    v().setSpeed(0);
    await settle(tester);
    expect(k('bt-pairing'), findsOneWidget);
    await tester.tap(k('bt-pairing-confirm'));
    await settle(tester);
    expect(k('bt-pairing'), findsNothing);
    expect(find.text('Pairing confirmed'), findsOneWidget);
    v().startPairing();
    await settle(tester);
    await tester.tap(k('bt-pairing-cancel'));
    await settle(tester);
    expect(find.text('Pairing cancelled'), findsOneWidget);
  });

  group('settings', () {
    testWidgets('time format chips switch the status bar clock', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      // The formats sit under the theme now, below the fold.
      await tester.ensureVisible(find.text('12-hour'));
      await settle(tester);
      await tester.tap(find.text('12-hour'));
      await settle(tester);
      expect(container.read(use24HourProvider), isFalse);
      expect(container.read(vehicleProvider).time, matches(RegExp(r'[AP]M$')));
      expect(find.descendant(of: k('status-clock'), matching: find.textContaining(RegExp(r'[AP]M'))), findsOneWidget);
      await tester.tap(find.text('24-hour'));
      await settle(tester);
      expect(container.read(vehicleProvider).time, matches(RegExp(r'^\d{2}:\d{2}$')));
    });

    testWidgets('about shows the version; Report Issue opens the QR code', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      await tester.tap(k('section-about'));
      await settle(tester);
      expect(find.descendant(of: k('about-version'), matching: find.text('v$appVersion'), matchRoot: true), findsOneWidget);
      await tester.ensureVisible(k('about-report-bug'));
      await tester.tap(k('about-report-bug'));
      await settle(tester);
      expect(k('qr-card-code'), findsOneWidget);
      expect(find.text(issuesUrl), findsOneWidget);
      await tester.tap(k('qr-card-close'));
      await settle(tester);
      expect(k('qr-card'), findsNothing);
      await tester.tap(k('about-repo'));
      await settle(tester);
      expect(find.descendant(of: k('qr-card-url'), matching: find.text(repoUrl), matchRoot: true), findsOneWidget);
      await tester.tap(k('qr-card-close'));
      await settle(tester);
      await tester.tap(k('about-author'));
      await settle(tester);
      expect(find.descendant(of: k('qr-card-url'), matching: find.text(AboutSection.authorUrl), matchRoot: true), findsOneWidget);
      await tester.tap(k('qr-card-close'));
      await settle(tester);
    });

    testWidgets('long-pressing the clock toasts the version', (tester) async {
      await pumpApp(tester);
      await tester.longPress(k('status-clock'));
      await settle(tester);
      expect(find.text('$appName v$appVersion'), findsOneWidget);
    });
  });

  group('error recovery', () {
    testWidgets('error overlay offers retry, safe mode, the stock dashboard and Report Issue', (tester) async {
      await pumpApp(tester);
      container.read(appErrorProvider.notifier).report(StateError('Dev panel test error'));
      await settle(tester);
      expect(k('error-overlay'), findsOneWidget);
      expect(find.descendant(of: k('error-summary'), matching: find.text('Dev panel test error'), matchRoot: true), findsOneWidget);
      expect(find.descendant(of: k('error-version'), matching: find.text('$appName v$appVersion'), matchRoot: true), findsOneWidget);
      await tester.tap(k('error-report'));
      await settle(tester);
      expect(k('qr-card-code'), findsOneWidget, reason: 'drawn above the error screen');
      await tester.tap(k('qr-card-close'));
      await settle(tester);
      await tester.tap(k('error-stock'));
      await settle(tester);
      expect(find.text('Stock dashboard not installed'), findsOneWidget);
      await tester.tap(k('error-retry'));
      await settle(tester);
      expect(k('error-overlay'), findsNothing);

      container.read(appErrorProvider.notifier).report(Exception('again'));
      await settle(tester);
      await tester.tap(k('error-safe-mode'));
      await settle(tester);
      expect(k('error-overlay'), findsNothing);
      expect(k('safe-mode'), findsOneWidget);
      expect(find.descendant(of: k('safe-version'), matching: find.text('v$appVersion'), matchRoot: true), findsOneWidget);
      await tester.tap(k('safe-stock'));
      await settle(tester);
      expect(find.text('Stock dashboard not installed'), findsOneWidget);
      expect(find.text('Stock Dashboard'), findsOneWidget);
    });

    testWidgets('boot timeout warns at 15s, offers options at 30s, continue flags no data', (tester) async {
      await pumpApp(tester);
      container.read(sessionProvider.notifier).simulateAidlTimeout();
      await settle(tester);
      expect(find.byType(BootScreen), findsOneWidget);
      expect(k('boot-line'), findsOneWidget);
      expect(find.descendant(of: k('boot-version'), matching: find.text('v$appVersion'), matchRoot: true), findsOneWidget);
      expect(find.text('Connecting…'), findsOneWidget);
      expect(k('boot-slow'), findsNothing);
      await tester.pump(const Duration(seconds: 15));
      await settle(tester);
      expect(k('boot-slow'), findsOneWidget);
      await tester.pump(const Duration(seconds: 15));
      await settle(tester);
      expect(k('boot-options'), findsOneWidget);
      // Report Issue opens the QR code; nothing leads on without the
      // scooter; the screen goes by itself when the service answers.
      await tester.tap(k('boot-report'));
      await settle(tester);
      expect(k('qr-card-code'), findsOneWidget);
      await tester.tap(k('qr-card-close'));
      await settle(tester);
      expect(k('boot-continue'), findsNothing);
      expect(find.byType(BootScreen), findsOneWidget);
      v().setConnected(true);
      await settle(tester);
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      expect(find.byType(BootScreen), findsNothing);
    });

    testWidgets('service mode launches a listed package or toasts', (tester) async {
      await pumpApp(tester);
      container.read(serviceModeOpenProvider.notifier).open();
      await settle(tester);
      await tester.tap(k('service-com.ola.mfgapp'));
      await settle(tester);
      expect(find.text('Could not launch com.ola.mfgapp'), findsOneWidget);
    });
  });

  group('widget panel', () {
    testWidgets('three clipped pages: battery temp, motor temp, regen; bars are 12px', (tester) async {
      await pumpApp(tester);
      expect(find.ancestor(of: find.byType(PageView), matching: find.byType(ClipRect)), findsWidgets);
      expect(k('dot-2'), findsOneWidget);
      expect(k('dot-3'), findsNothing);

      // The battery page says nothing about temperature until it is hot.
      expect(k('battery-hot'), findsNothing);
      Text hot() => tester.widget<Text>(find.descendant(of: k('battery-hot'), matching: find.text('Battery hot')));
      v().setBatteryTemp(56); // cell warn 55
      await settle(tester);
      expect(hot().style!.color, DashColors.warning);
      v().setBatteryTemp(63); // cell error 62
      await settle(tester);
      expect(hot().style!.color, DashColors.critical);
      v().setBatteryTemp(33);
      await settle(tester);
      expect(k('battery-hot'), findsNothing);

      await swipeLeft(tester);
      DataCard motor() => tester.widget<DataCard>(k('motor-temp'));
      expect(motor().valueColor, isNull);
      expect(find.descendant(of: k('battery-temp'), matching: find.text('33')), findsOneWidget,
          reason: 'the battery figure sits beside the motor\'s');
      v().setMotorTemp(148); // motor winding warn 147
      await settle(tester);
      expect(motor().valueColor, DashColors.warning);
      v().setMotorTemp(166); // motor winding error 165
      await settle(tester);
      expect(motor().valueColor, DashColors.critical);
      final column = tester.widget<Column>(find.ancestor(of: k('motor-temp'), matching: find.byType(Column)).first);
      expect(column.mainAxisAlignment, MainAxisAlignment.center);
      final bar = tester.widget<DataBar>(find.byType(DataBar).first);
      expect(bar.height, 12);
      expect(tester.getSize(find.byType(DataBar).first).height, 12);

      await swipeLeft(tester);
      expect(k('trip-regen'), findsOneWidget);
      expect(find.text('kWh regen'), findsOneWidget);
    });
  });

  testWidgets('boot splash: loader, version and the word Connecting', (tester) async {
    await boot(tester);
    expect(k('boot-line'), findsOneWidget);
    expect(find.descendant(of: k('boot-version'), matching: find.text('v$appVersion'), matchRoot: true), findsOneWidget);
    expect(tester.widget<Text>(k('boot-connecting')).data, 'Connecting…');
    await tester.pump(const Duration(milliseconds: 600));
    final painter = tester.widget<CustomPaint>(k('boot-line')).painter as BootLinePainter;
    expect(painter.extent, greaterThan(0));
  });
}
