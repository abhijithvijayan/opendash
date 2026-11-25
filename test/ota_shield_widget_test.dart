import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/app_catalog.dart';
import 'package:opendash/models/ota_shield.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/passcode_gate.dart';
import 'package:opendash/state/ota_state.dart';
import 'package:opendash/state/settings_state.dart';

/// OTA Shield on Settings → Updates and on its Apps tile, against the mock
/// platform's stand-in for its daemon.
void main() {
  late ProviderContainer container;
  late MockPlatformService platform;
  Finder k(String id) => find.byKey(ValueKey(id));
  final shield = appCatalog.firstWhere((a) => a.id == CatalogApp.otaShieldId);

  setUp(() => AnalyticsLogger.instance.resetForTest());

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpApp(WidgetTester tester, {bool installed = false, OtaShieldReport? report}) async {
    platform = MockPlatformService();
    if (installed) platform.setInstalled(shield.package);
    if (report != null) platform.otaShield = report;
    await tester.pumpWidget(ProviderScope(
      overrides: [platformServiceProvider.overrideWithValue(platform)],
      child: const OpenDashApp(),
    ));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    container.read(vehicleProvider.notifier).setLocked(false);
    await settle(tester);
  }

  Future<void> openUpdates(WidgetTester tester) async {
    container.read(settingsScreenOpenProvider.notifier).open();
    await settle(tester);
    await tester.ensureVisible(k('section-updates'));
    await tester.tap(k('section-updates'));
    await settle(tester);
    await tester.ensureVisible(k('shield-card'));
    await settle(tester);
  }

  String status(WidgetTester tester) => tester.widget<Text>(k('shield-status')).data!;

  testWidgets('not installed: the card says so and takes the rider to Apps', (tester) async {
    await pumpApp(tester);
    await openUpdates(tester);
    expect(status(tester), 'Not installed');
    expect(k('shield-blocked'), findsNothing);
    await tester.tap(k('shield-get'));
    await settle(tester);
    expect(container.read(appLauncherOpenProvider), isTrue);
    expect(container.read(otaScreenOpenProvider), isFalse);
    expect(k('app-${CatalogApp.otaShieldId}'), findsOneWidget);
  });

  testWidgets('installed with its blocker stopped: not blocking, on the card and the tile', (tester) async {
    await pumpApp(tester, installed: true);
    await openUpdates(tester);
    expect(status(tester), 'Not blocking');
    expect(k('shield-off-hint'), findsOneWidget);
    expect(find.text('Open OTA Shield to activate'), findsOneWidget);

    container.read(appLauncherOpenProvider.notifier).open();
    await settle(tester);
    expect(tester.widget<Text>(k('shield-tile-status')).data, 'Not blocking');
  });

  testWidgets('running: what it has held back, and a start seen without a tap', (tester) async {
    await pumpApp(tester, installed: true);
    await openUpdates(tester);
    expect(status(tester), 'Not blocking');

    final at = DateTime.now().subtract(const Duration(days: 2));
    platform.otaShield = OtaShieldReport(running: true, blocked: 12, offerCount: 3, offers: [
      OtaShieldOffer(atMs: at.millisecondsSinceEpoch, reminder: false, upgrades: const [
        OtaShieldUpgrade(component: 'MCU', from: '1.2', to: '1.3', bytes: 1000),
        OtaShieldUpgrade(component: 'BMS', from: '2.0', to: '2.1', bytes: 1000),
      ]),
    ]);
    await tester.pump(const Duration(seconds: 11));
    await settle(tester);
    expect(status(tester), 'Blocking firmware updates');
    expect(find.descendant(of: k('shield-blocked'), matching: find.text('12')), findsOneWidget);
    expect(find.descendant(of: k('shield-offers'), matching: find.text('3')), findsOneWidget);
    expect(find.descendant(of: k('shield-last'), matching: find.textContaining('MCU 1.3 +1')), findsOneWidget);
    expect(find.text('Open OTA Shield'), findsOneWidget);
    final logged = AnalyticsLogger.instance.recent('ota_shield', 'status');
    expect(logged.last['data'], allOf(containsPair('running', true), containsPair('blocked', 12)));
  });

  testWidgets('opening it goes through the passcode, never straight to the app', (tester) async {
    await pumpApp(tester, installed: true, report: const OtaShieldReport(running: true, blocked: 0, offerCount: 0));
    await openUpdates(tester);
    expect(find.descendant(of: k('shield-last'), matching: find.text('None yet')), findsOneWidget);
    await tester.tap(k('shield-open'));
    await settle(tester);
    expect(platform.launched, isEmpty);
  });

  void passcode() {
    for (final d in [1, 2, 3, 4, 5, 6]) {
      container.read(passcodeGateProvider.notifier).enterDigit(d);
    }
  }

  testWidgets('an OTA Shield without its service: no Activate, open it instead', (tester) async {
    await pumpApp(tester, installed: true);
    await openUpdates(tester);
    expect(k('shield-activate'), findsNothing);
    expect(find.text('Open OTA Shield to activate'), findsOneWidget);
  });

  testWidgets('Activate goes through the passcode, then asks OTA Shield and shows its steps', (tester) async {
    await pumpApp(tester,
        installed: true, report: const OtaShieldReport(running: false, service: OtaShieldService(activated: false, failsafe: false, step: 'IDLE')));
    await openUpdates(tester);
    expect(status(tester), 'Not blocking');
    await tester.tap(k('shield-activate'));
    await settle(tester);
    expect(container.read(passcodeGateProvider).open, isTrue);
    expect(platform.otaShieldCalls, isEmpty);

    platform.otaShield = const OtaShieldReport(
        running: false,
        service: OtaShieldService(activated: false, failsafe: false, step: 'STARTING_DAEMON', activation: 'running', activationStep: 'STARTING_DAEMON'));
    passcode();
    await settle(tester);
    expect(platform.otaShieldCalls, ['activate']);
    expect(status(tester), 'Activating');
    expect(tester.widget<Text>(k('shield-step')).data, 'Starting its blocker');
    expect(k('shield-activate'), findsNothing);

    platform.otaShield = const OtaShieldReport(
        running: true, blocked: 0, offerCount: 0, inBytes: 2048, outBytes: 3 * 1024 * 1024,
        service: OtaShieldService(activated: true, failsafe: false, step: 'ACTIVATED', activation: 'done'));
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(status(tester), 'Blocking firmware updates');
    expect(find.descendant(of: k('shield-traffic'), matching: find.text('2 KB in · 3.0 MB out')), findsOneWidget);
    expect(AnalyticsLogger.instance.recent('ota_shield', 'activate').single['data'], containsPair('asked', true));
  });

  testWidgets('a failed activation says why and offers Activate again', (tester) async {
    await pumpApp(tester,
        installed: true,
        report: const OtaShieldReport(
            running: false,
            service: OtaShieldService(activated: false, failsafe: false, step: 'FAILED', activation: 'failed', activationError: 'Root shell unavailable')));
    await openUpdates(tester);
    expect(status(tester), 'Not blocking');
    expect(tester.widget<Text>(k('shield-error')).data, contains('Root shell unavailable'));
    expect(k('shield-activate'), findsOneWidget);
    final logged = AnalyticsLogger.instance.recent('ota_shield', 'status').last['data'] as Map;
    expect(logged.values, isNot(contains('Root shell unavailable')));
  });

  testWidgets('fail-safe on: said plainly, counts as keeping updates out, and can be lifted behind the passcode', (tester) async {
    await pumpApp(tester,
        installed: true, report: const OtaShieldReport(running: false, service: OtaShieldService(activated: true, failsafe: true, step: 'IDLE')));
    await openUpdates(tester);
    expect(status(tester), contains('Fail-safe on'));
    expect(k('shield-failsafe-hint'), findsOneWidget);
    expect(platform.otaShield.keepsUpdatesOut, isTrue);
    await tester.tap(k('shield-failsafe-off'));
    await settle(tester);
    expect(platform.otaShieldCalls, isEmpty);
    passcode();
    await settle(tester);
    expect(platform.otaShieldCalls, ['disableFailsafe']);
  });

  test('a report drops what it does not know and treats no answer as not running', () {
    expect(OtaShieldReport.fromMap(null).running, isFalse);
    expect(OtaShieldReport.fromMap({'running': false, 'blocked': 4}).blocked, isNull);
    final r = OtaShieldReport.fromMap({
      'running': true,
      'blocked': 2,
      'offerCount': 1,
      'offers': [
        {'at': 5, 'reminder': true, 'upgrades': [{'component': 'MCU', 'from': 'a', 'to': 'b', 'size': 9}, 'junk']},
        'junk',
      ],
    });
    expect(r.offers.single.upgrades.single.to, 'b');
    expect(r.offers.single.reminder, isTrue);
    expect(r.service, isNull);

    final off = OtaShieldReport.fromMap({
      'running': false,
      'service': {'activated': true, 'failsafe': true, 'step': 'MOUNTING_CERTS', 'activation': null},
    });
    expect(off.running, isFalse);
    expect(off.failsafe, isTrue);
    expect(off.service!.activating, isTrue, reason: 'an activation started in OTA Shield itself');
    expect(off.service!.currentStep, 'MOUNTING_CERTS');
  });
}
