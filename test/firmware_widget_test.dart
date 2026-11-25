import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/screens/ota/ota_screen.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/state/firmware_state.dart';
import 'package:opendash/state/ota_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/widgets/overlays/firmware_overlays.dart';
import 'helpers/stock.dart';

void main() {
  late ProviderContainer container;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);
  FirmwareNotifier fw() => container.read(firmwareProvider.notifier);
  Finder k(String id) => find.byKey(ValueKey(id));

  setUp(AnalyticsLogger.instance.resetForTest);

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
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> openUpdates(WidgetTester tester) async {
    container.read(settingsScreenOpenProvider.notifier).open();
    await settle(tester);
    await tester.ensureVisible(k('section-updates'));
    await tester.tap(k('section-updates'));
    await settle(tester);
  }

  String line(WidgetTester tester, String key) => tester
      .widgetList<Text>(find.descendant(of: k(key), matching: find.byType(Text)))
      .map((t) => t.data)
      .join(' | ');

  const available = {
    'kind': 'available', 'button': true, 'reason': 0, 'version': '4.7.1', 'size': '431000000',
    'notes': '{"releaseNotes": ["note one"]}',
  };

  testWidgets('the Scooter firmware card shows the three status lines, and no firmware block of its own', (tester) async {
    await pumpApp(tester);
    await openUpdates(tester);
    expect(k('fw-card'), findsOneWidget);
    expect(line(tester, 'fw-line-mode'), 'Updates | Off');
    expect(line(tester, 'fw-line-autodl'), 'Stock auto-download | Unknown');
    expect(k('fw-line-block'), findsNothing);
    expect(line(tester, 'fw-line-notice'), 'Last notice seen | None');

    v().setStockAutoDownload(1);
    await settle(tester);
    expect(line(tester, 'fw-line-autodl'), anyOf('Stock auto-download | On', 'Stock auto-download | Off'));
  });

  testWidgets('Off: an offered version is one quiet line, with no offer card and no bell', (tester) async {
    await pumpApp(tester);
    fw().onNotice(available);
    await settle(tester);
    expect(container.read(bellProvider), isFalse);
    await openUpdates(tester);
    expect(line(tester, 'fw-line-notice'), startsWith('Last notice seen | 4.7.1'));
    expect(k('fw-offer'), findsNothing);
    expect(k('fw-read'), findsNothing);
    expect(k('fw-check'), findsNothing);
    expect(find.text('note one'), findsNothing);
  });

  testWidgets('Ask me: offer, passcode, the acknowledgement, "Not now"', (tester) async {
    await pumpApp(tester);
    await openUpdates(tester);
    await tester.ensureVisible(find.text('Ask me'));
    await tester.tap(find.text('Ask me'));
    await settle(tester);
    expect(container.read(firmwareProvider).mode, FirmwareMode.ask);
    fw().onNotice(available);
    await settle(tester);
    expect(k('fw-offer'), findsOneWidget);
    expect(find.text('411 MB'), findsOneWidget);
    expect(find.text('note one'), findsOneWidget);
    expect(k('fw-check'), findsOneWidget);
    await tester.ensureVisible(k('fw-read'));
    await tester.tap(k('fw-read'));
    await settle(tester);
    expect(k('passcode-gate'), findsOneWidget);
    expect(k('fw-ack'), findsNothing);
    for (final d in '123456'.split('')) {
      await tester.tap(find.descendant(of: k('passcode-gate'), matching: find.text(d)));
      await tester.pump();
    }
    await settle(tester);
    expect(k('fw-ack'), findsOneWidget);
    expect(find.text(FirmwareAck.title('4.7.1')), findsOneWidget);
    expect(find.text(FirmwareAck.intro), findsOneWidget);
    expect(k('fw-ack-open'), findsOneWidget);
    for (final key in ['fw-ack-open', 'fw-ack-not-now']) {
      await tester.ensureVisible(k(key));
      expect(tester.getSize(k(key)).height, greaterThanOrEqualTo(56));
    }
    await tester.tap(k('fw-ack-not-now'));
    await settle(tester);
    expect(k('fw-ack'), findsNothing);
    expect(k('fw-card'), findsOneWidget);
  });

  testWidgets('the acknowledgement closes with the screen', (tester) async {
    await pumpApp(tester);
    fw().setMode(FirmwareMode.ask);
    fw().onNotice(available);
    await openUpdates(tester);
    fw().readBeforeUpdating();
    await settle(tester);
    for (final d in '123456'.split('')) {
      await tester.tap(find.descendant(of: k('passcode-gate'), matching: find.text(d)));
      await tester.pump();
    }
    await settle(tester);
    expect(container.read(firmwareProvider).ackOpen, isTrue);
    v().setLocked(true);
    await settle(tester);
    expect(container.read(otaScreenOpenProvider), isFalse);
    expect(container.read(firmwareProvider).ackOpen, isFalse);
  });

  testWidgets('restore asks first, then points to OTA Shield', (tester) async {
    await pumpApp(tester);
    await openUpdates(tester);
    await tester.ensureVisible(k('fw-restore'));
    await tester.tap(k('fw-restore'));
    await settle(tester);
    expect(container.read(firmwareProvider).restored, isFalse);
    await tester.ensureVisible(k('fw-restore-yes'));
    await tester.tap(k('fw-restore-yes'));
    await settle(tester);
    expect(container.read(firmwareProvider).restored, isTrue);
    expect(k('fw-restored'), findsOneWidget);
    expect(find.textContaining('firmware-updates.sh'), findsNothing);
    expect(find.textContaining('turn its block off in OTA Shield'), findsOneWidget);
    expect(container.read(vehicleProvider).stockAutoDownload, 1, reason: 'none was seen, so on');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the install notice covers the dashboard, in both modes and both themes', (tester) async {
    await pumpApp(tester);
    expect(k('fw-installing'), findsNothing);
    fw().onNotice(const {'kind': 'install_progress', 'state': 3, 'progress': 37});
    await settle(tester);
    expect(k('fw-installing'), findsOneWidget);
    expect(find.text('Scooter firmware is installing.'), findsOneWidget);
    expect(find.text('Do not ride.'), findsOneWidget);
    expect(find.text('37%'), findsOneWidget);
    fw().setMode(FirmwareMode.ask);
    await settle(tester);
    expect(k('fw-installing'), findsOneWidget);
    fw().onNotice(const {'kind': 'first_boot'});
    await settle(tester);
    expect(k('fw-installing'), findsNothing);
    expect(find.byType(FirmwareInstallOverlay), findsOneWidget);
  });

  testWidgets('after a head-unit change the notice shows once, parked and unlocked, with both ways on', (tester) async {
    await pumpApp(tester);
    fw().onVersion('3', 'hu-1');
    await tester.pump(FirmwareNotifier.versionSettle + const Duration(seconds: 1));
    expect(k('fw-changed'), findsNothing, reason: 'the first run only stores');
    fw().onVersion('3', 'hu-2');
    await tester.pump(FirmwareNotifier.versionSettle + const Duration(seconds: 1));
    await settle(tester);
    expect(k('fw-changed'), findsOneWidget);
    expect(find.textContaining('changed from hu-1 to hu-2'), findsOneWidget);
    expect(find.text('Open the stock dashboard'), findsOneWidget);
    await tester.tap(find.text('Keep using OpenDash'));
    await settle(tester);
    expect(k('fw-changed'), findsNothing);
    expect(AnalyticsLogger.instance.recent('fw', 'version_notice').single['data'], {'answer': 'keep'});
  });

  testWidgets('on the scooter: real values on both cards, nothing simulated or invented', (tester) async {
    final events = StreamController<dynamic>();
    addTearDown(events.close);
    tester.view.physicalSize = const Size(1280, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: events.stream, invoke: (_, _) async => true)),
        platformServiceProvider.overrideWithValue(MockPlatformService()),
      ],
      child: const Directionality(textDirection: TextDirection.ltr, child: Stack(children: [OtaScreen()])),
    ));
    container = ProviderScope.containerOf(tester.element(find.byType(OtaScreen)));
    final n = container.read(vehicleProvider.notifier) as AidlVehicleNotifier;
    n.onEvent({'_connected': true, '_unlocked': true, 'INT_VEHICLE_STATE': 3, 'INT_VEHICLE_SPEED': 0, 'AUTODOWNLOAD_UPDATE': 0});
    await tester.pump(const Duration(seconds: 20));
    container.read(otaScreenOpenProvider.notifier).open();
    await settle(tester);
    expect(container.read(otaScreenOpenProvider), isTrue);
    expect(k('opendash-installed'), findsOneWidget);
    expect(find.text('OpenDash is up to date'), findsOneWidget);
    expect(k('ota-check'), findsOneWidget);
    expect(line(tester, 'fw-line-autodl'), 'Stock auto-download | Off');
    for (final gone in ['MoveOS', 'Last updated', 'Restart Now', 'Contact your service center', 'Auto-download updates', 'may stop working']) {
      expect(find.textContaining(gone), findsNothing, reason: gone);
    }
    container.read(otaScreenOpenProvider.notifier).close();
    await tester.pump(const Duration(seconds: 20));
  });
}
