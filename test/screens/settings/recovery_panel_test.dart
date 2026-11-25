import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/bus_log_state.dart';
import 'package:opendash/screens/settings/widgets.dart';
import 'package:opendash/main.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/settings/sections/developer_section.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/services/recovery_service.dart';
import 'package:opendash/services/wifican_codec.dart';
import 'package:opendash/state/connection_check.dart';
import 'package:opendash/state/recovery_panel.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/toast_state.dart';

class _Shell implements RecoveryClient {
  final executed = <String>[];
  bool ok = true;

  @override
  Future<WifiCanResponse> execute(String command, Duration timeout) async {
    executed.add(command);
    return WifiCanResponse(ok ? 1 : 2, ok ? '' : 'refused');
  }

  @override
  Future<void> shutdown() async {}
}

const _forceStop = 'am force-stop com.olaelectric.hmiclient';
const _start = 'am start -n com.olaelectric.hmiclient/.MainActivity';
const _wake = ['input keyevent KEYCODE_WAKEUP', 'settings put secure screensaver_enabled 0'];
const _buttons = ['wake', 'restart-stock', 'density', 'stop-stock', 'open-stock'];

void main() {
  late ProviderContainer container;
  late MockPlatformService platform;
  late _Shell shell;
  Finder k(String id) => find.byKey(ValueKey(id));

  setUp(() {
    AnalyticsLogger.instance.resetForTest();
    shell = _Shell();
    platform = MockPlatformService();
    recoveryService = RecoveryService(clientFactory: (_, _) => shell);
  });

  tearDown(() {
    recoveryService = RecoveryService();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// The whole app, parked, on Settings → Developer.
  Future<void> openDeveloper(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [platformServiceProvider.overrideWithValue(platform)],
      child: const OpenDashApp(),
    ));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    container.read(vehicleProvider.notifier).setLocked(false);
    await tester.pump(const Duration(seconds: 5));
    await settle(tester);
    container.read(settingsScreenOpenProvider.notifier).open();
    container.read(settingsSectionProvider.notifier).set(SettingsSection.developer);
    await settle(tester);
    // Whatever the app sent on the way here is not this test's business.
    shell.executed.clear();
  }

  Future<void> tapButton(WidgetTester tester, String id) async {
    await tester.ensureVisible(k('recovery-$id'));
    await settle(tester);
    await tester.tap(k('recovery-$id'));
    await settle(tester);
  }

  String? toast() => container.read(toastProvider)?.message;

  testWidgets('Recovery sits under the analytics controls with one card per action and the restart link', (tester) async {
    await openDeveloper(tester);
    expect(find.text('RECOVERY'), findsOneWidget);
    expect(tester.getTopLeft(find.text('RECOVERY')).dy, greaterThan(tester.getTopLeft(k('analytics-new-capture')).dy));
    for (final id in _buttons) {
      expect(k('recovery-card-$id'), findsOneWidget);
      expect(k('recovery-$id'), findsOneWidget);
    }
    expect(k('recovery-restart-scooter'), findsOneWidget);
  });

  testWidgets('the bus log switch sits under the raw recording, on by default and turns off', (tester) async {
    await openDeveloper(tester);
    await tester.ensureVisible(k('bus-log-toggle'));
    await settle(tester);
    expect(find.text('Bus log'), findsOneWidget);
    expect(tester.getTopLeft(k('bus-log-toggle')).dy, greaterThan(tester.getTopLeft(k('raw-recording')).dy));
    expect(container.read(busLogProvider).enabled, isTrue, reason: 'on from the first boot');
    await tester.tap(find.descendant(of: k('bus-log-toggle'), matching: find.byType(DashSwitch)));
    await settle(tester);
    expect(container.read(busLogProvider).enabled, isFalse);
  });

  testWidgets('Wake, Reset and Stop send their commands and toast the result', (tester) async {
    await openDeveloper(tester);
    await tapButton(tester, 'wake');
    expect(shell.executed, _wake);
    expect(toast(), 'Display woken, screensaver off');
    expect(container.read(toastProvider)!.type, ToastType.success);

    shell.executed.clear();
    await tapButton(tester, 'density');
    expect(shell.executed, ['wm density reset']);
    expect(toast(), 'Display density reset');

    shell.executed.clear();
    await tapButton(tester, 'stop-stock');
    expect(shell.executed, [_forceStop]);
    expect(toast(), 'Stock dashboard stopped');
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('a refused command toasts the failure', (tester) async {
    await openDeveloper(tester);
    shell.ok = false;
    await tapButton(tester, 'wake');
    expect(shell.executed, [_wake.first], reason: 'stops at the first refused command');
    expect(toast(), "Couldn't wake the display");
    expect(container.read(toastProvider)!.type, ToastType.error);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('Restart stock dashboard asks first; Cancel sends nothing', (tester) async {
    await openDeveloper(tester);
    await tapButton(tester, 'restart-stock');
    expect(k('recovery-restart-stock-confirm'), findsOneWidget);
    expect(find.textContaining('Reboot Scooter'), findsWidgets);
    expect(shell.executed, isEmpty);

    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(k('recovery-restart-stock-confirm'), findsNothing);
    expect(shell.executed, isEmpty);
  });

  testWidgets('confirming calls the service: force-stop, start, then the return pill', (tester) async {
    await openDeveloper(tester);
    await tapButton(tester, 'restart-stock');
    await tester.tap(find.text('Restart stock'));
    await settle(tester);
    expect(k('recovery-restart-stock-confirm'), findsNothing);
    expect(shell.executed, [_forceStop, _start]);
    expect(container.read(outsideAppProvider)?.id, 'stock-dashboard', reason: 'the island is the way back');
    final opened = AnalyticsLogger.instance.recent('apps', 'opened').single['data']! as Map<Object?, Object?>;
    expect(opened['id'], 'stock-dashboard');
    final action = AnalyticsLogger.instance.recent('recovery', 'action').last['data']! as Map<Object?, Object?>;
    expect(action['name'], 'restart_stock_dashboard');
  });

  testWidgets('a restart that fails says so and raises no way back', (tester) async {
    await openDeveloper(tester);
    shell.ok = false;
    await tapButton(tester, 'restart-stock');
    await tester.tap(find.text('Restart stock'));
    await settle(tester);
    expect(shell.executed, [_forceStop]);
    expect(container.read(outsideAppProvider), isNull);
    expect(toast(), 'Could not launch Stock Dashboard');
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('Open stock dashboard launches through Apps, with the way back', (tester) async {
    await openDeveloper(tester);
    await tapButton(tester, 'open-stock');
    expect(shell.executed, [_start]);
    expect(container.read(outsideAppProvider)?.id, 'stock-dashboard');
  });

  testWidgets('Restart scooter links to the existing flow: passcode gate, no shell reboot', (tester) async {
    await openDeveloper(tester);
    await tester.ensureVisible(k('recovery-restart-scooter'));
    await settle(tester);
    await tester.tap(k('recovery-restart-scooter'));
    await settle(tester);
    final asked = AnalyticsLogger.instance.recent('recovery', 'restart_requested').single['data']! as Map<Object?, Object?>;
    expect(asked['from'], 'recovery');
    expect(shell.executed, isEmpty);
  });

  group('while riding', () {
    Future<void> pumpSection(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [platformServiceProvider.overrideWithValue(platform)],
        child: const MaterialApp(home: Scaffold(body: SizedBox(width: 840, child: DeveloperSection()))),
      ));
      container = ProviderScope.containerOf(tester.element(find.byType(DeveloperSection)));
      container.listen(recoveryPanelProvider, (_, _) {});
      container.read(vehicleProvider.notifier).setLocked(false);
      await tester.pump();
    }

    testWidgets('every action is disabled and sends nothing', (tester) async {
      await pumpSection(tester);
      container.read(vehicleProvider.notifier).setSpeed(20);
      await tester.pump();
      expect(find.text('Not available while riding.'), findsOneWidget);
      for (final id in _buttons) {
        await tester.tap(k('recovery-$id'), warnIfMissed: false);
        await tester.pump();
      }
      await tester.tap(k('recovery-restart-scooter'));
      await tester.pump();
      expect(shell.executed, isEmpty);
      expect(container.read(recoveryPanelProvider), isFalse);
      expect(AnalyticsLogger.instance.recent('recovery'), isEmpty);
      expect(container.read(outsideAppProvider), isNull);
      // The taps never reached the panel: the buttons themselves are off.
      final taps = [for (final e in AnalyticsLogger.instance.recent('ui', 'tap')) (e['data']! as Map)['target']];
      expect(taps.where((t) => '$t'.startsWith('recovery-')), ['recovery-restart-scooter']);
    });

    testWidgets('the notifier refuses too, whatever the button looks like', (tester) async {
      await pumpSection(tester);
      container.read(vehicleProvider.notifier).setSpeed(20);
      await tester.pump();
      final panel = container.read(recoveryPanelProvider.notifier);
      await panel.wakeDisplay();
      await panel.resetDensity();
      await panel.stopStock();
      await panel.openStock();
      panel.askRestartStock();
      expect(container.read(recoveryPanelProvider), isFalse);
      expect(shell.executed, isEmpty);
    });

    testWidgets('moving off closes the confirm, and a late confirm sends nothing', (tester) async {
      await pumpSection(tester);
      final panel = container.read(recoveryPanelProvider.notifier);
      panel.askRestartStock();
      expect(container.read(recoveryPanelProvider), isTrue);
      container.read(vehicleProvider.notifier).setSpeed(12);
      await tester.pump();
      expect(container.read(recoveryPanelProvider), isFalse);
      await panel.confirmRestartStock();
      expect(shell.executed, isEmpty);
    });

    testWidgets('parked again, the cards work', (tester) async {
      await pumpSection(tester);
      container.read(vehicleProvider.notifier).setSpeed(20);
      await tester.pump();
      container.read(vehicleProvider.notifier).setSpeed(0);
      await tester.pump();
      await tester.tap(k('recovery-wake'));
      await tester.pump();
      await tester.pump();
      expect(shell.executed, _wake);
      await tester.pump(const Duration(seconds: 4));
    });
  });

  testWidgets('Check connection says, per network and host, how far GitHub was reached, and logs it', (tester) async {
    await openDeveloper(tester);
    await tester.ensureVisible(k('connection-check'));
    await settle(tester);
    await tester.tap(k('connection-check'));
    await settle(tester);
    expect(find.textContaining('Wi-Fi (in use): internet confirmed by Android · DNS 192.168.1.1 · IPv4 yes, IPv6 no, MTU 1500'), findsOneWidget);
    expect(find.textContaining('1.1.1.1 (used for OpenDash downloads): answers 120ms · system-wide Private DNS would be reachable'),
        findsOneWidget);
    expect(find.textContaining('api.github.com: reached (HTTP 200)'), findsOneWidget);
    expect(find.textContaining('github.com: connected, then no answer over HTTPS 8003ms'), findsOneWidget);
    expect(find.textContaining('release-assets.githubusercontent.com: name not found (DNS)'), findsOneWidget);
    final logged = AnalyticsLogger.instance.recent('net', 'check').single['data'] as Map;
    expect((logged['networks'] as List).single['transport'], 'wifi');
    expect(logged.keys, containsAll(['wifi', 'signal']));
  });

  testWidgets('with no network up the check says so', (tester) async {
    platform.networks = [];
    await openDeveloper(tester);
    await tester.ensureVisible(k('connection-check'));
    await settle(tester);
    await tester.tap(k('connection-check'));
    await settle(tester);
    expect(find.textContaining('No network'), findsOneWidget);
  });

  testWidgets('a check that finishes after Settings was closed is still logged, and nothing breaks', (tester) async {
    final slow = _SlowCheckPlatform();
    platform = slow;
    await openDeveloper(tester);
    await tester.ensureVisible(k('connection-check'));
    await settle(tester);
    await tester.tap(k('connection-check'));
    await settle(tester);
    container.read(settingsScreenOpenProvider.notifier).close();
    await settle(tester);
    slow.answer.complete(MockPlatformService().networks);
    await settle(tester);
    expect(tester.takeException(), isNull,
        reason: 'the answer once arrived at a closed page and OpenDash showed its error screen');
    expect(AnalyticsLogger.instance.recent('net', 'check'), hasLength(1));
    expect(container.read(connectionCheckProvider).lines, isNotNull);
  });
}

class _SlowCheckPlatform extends MockPlatformService {
  final answer = Completer<List<Map<String, Object?>>>();

  @override
  Future<List<Map<String, Object?>>> networkCheck() => answer.future;
}
