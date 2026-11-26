import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/build_info.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/firmware_state.dart';
import 'package:opendash/state/ota_state.dart';
import 'package:opendash/state/qr_card.dart';
import 'package:opendash/state/settings_state.dart';

/// The OpenDash card on Settings → Updates, against the mock platform's
/// fake release source (installed build 100, a release of build 120).
void main() {
  late ProviderContainer container;
  late MockPlatformService platform;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);
  OtaNotifier ota() => container.read(otaProvider.notifier);
  Finder k(String id) => find.byKey(ValueKey(id));

  setUp(() => BuildInfo.number = 100);
  tearDown(() => BuildInfo.number = null);

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpApp(WidgetTester tester, {List<Object> overrides = const []}) async {
    platform = MockPlatformService();
    await tester.pumpWidget(ProviderScope(
      overrides: [platformServiceProvider.overrideWithValue(platform), ...overrides.cast()],
      child: const OpenDashApp(),
    ));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    v().setLocked(false);
    v().setWifi(true);
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

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.ensureVisible(k(key));
    await tester.pump();
    await tester.tap(k(key));
    await settle(tester);
  }

  testWidgets('opens from Settings, up to date, with the installed build and both cards', (tester) async {
    await pumpApp(tester);
    await openUpdates(tester);
    expect(container.read(otaScreenOpenProvider), isTrue);
    expect(container.read(settingsScreenOpenProvider), isTrue, reason: 'settings stays underneath');
    expect(find.text('OpenDash is up to date'), findsOneWidget);
    expect(find.text('Not checked yet'), findsOneWidget);
    expect(find.textContaining('build 100'), findsOneWidget);
    expect(find.text('Scooter firmware'), findsOneWidget);
    for (final gone in ['MoveOS', 'Last updated', 'Restart Now', 'Simulated']) {
      expect(find.textContaining(gone), findsNothing, reason: gone);
    }
    await tester.tap(k('toolbar-back'));
    await settle(tester);
    expect(container.read(otaScreenOpenProvider), isFalse);
  });

  testWidgets('"Check now" finds the release: notes, a dot on the Updates row, and the bell until it is seen', (tester) async {
    await pumpApp(tester);
    await tester.tap(k('status-bell'));
    await settle(tester);
    expect(container.read(otaScreenOpenProvider), isFalse, reason: 'nothing to show');
    ota().check();
    await settle(tester);
    expect(container.read(bellProvider), isTrue);
    container.read(settingsScreenOpenProvider.notifier).open();
    await settle(tester);
    expect(k('updates-badge'), findsOneWidget);
    container.read(settingsScreenOpenProvider.notifier).close();
    await settle(tester);
    await tester.tap(k('status-bell'));
    await settle(tester);
    expect(container.read(otaScreenOpenProvider), isTrue);
    expect(find.text('OpenDash 0.2.0'), findsOneWidget);
    expect(find.textContaining('build 120'), findsOneWidget);
    expect(find.textContaining('23 MB'), findsOneWidget);
    expect(k('ota-notes'), findsOneWidget);
    expect(container.read(bellProvider), isFalse, reason: 'seen');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('on the scooter too, the Updates row has the dot until the release is seen', (tester) async {
    await pumpApp(tester, overrides: [vehicleProvider.overrideWith(_ScooterData.new)]);
    expect(v().state.hhmisBacked, isTrue);
    ota().check();
    await settle(tester);
    expect(container.read(otaProvider).status, OtaStatus.available);
    container.read(settingsScreenOpenProvider.notifier).open();
    await settle(tester);
    expect(k('updates-badge'), findsOneWidget);
    await tester.ensureVisible(k('section-updates'));
    await tester.tap(k('section-updates'));
    await settle(tester);
    container.read(otaScreenOpenProvider.notifier).close();
    container.read(settingsScreenOpenProvider.notifier).open();
    await settle(tester);
    expect(k('updates-badge'), findsNothing, reason: 'seen');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('download, ready, and the passcode before Android', (tester) async {
    await pumpApp(tester);
    ota().check();
    await settle(tester);
    await openUpdates(tester);
    v().setWifi(false);
    await settle(tester);
    expect(find.textContaining('Wi-Fi'), findsNothing, reason: 'nothing is Wi-Fi only');
    await tap(tester, 'ota-download');
    expect(container.read(otaProvider).status, OtaStatus.downloading);
    expect(k('ota-cancel'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
    expect(k('ota-ready'), findsOneWidget);
    expect(k('ota-install-held'), findsNothing);
    expect(tester.getSize(k('ota-install')).height, greaterThanOrEqualTo(56));

    await tap(tester, 'ota-install');
    expect(k('passcode-gate'), findsOneWidget, reason: 'install needs the passcode');
    expect(platform.selfInstalls, isEmpty);
    for (final d in '123456'.split('')) {
      await tester.tap(find.descendant(of: k('passcode-gate'), matching: find.text(d)));
      await tester.pump();
    }
    await settle(tester);
    expect(platform.selfInstalls.single.$2, 120);
    expect(k('ota-installing'), findsOneWidget);
    expect(find.text('Android will ask you to confirm'), findsOneWidget);
    await tester.tap(k('toolbar-back'), warnIfMissed: false);
    await settle(tester);
    expect(container.read(otaScreenOpenProvider), isTrue, reason: 'back is blocked while Android has it');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('"ready" says why it cannot install yet', (tester) async {
    await pumpApp(tester);
    ota().check();
    await settle(tester);
    ota().startDownload();
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
    await openUpdates(tester);
    expect(k('ota-install-held'), findsNothing);
    v().setCallActive(true);
    await settle(tester);
    expect(tester.widget<Text>(k('ota-install-held')).data, 'Finish the call first');
    await tap(tester, 'ota-install');
    expect(k('passcode-gate'), findsNothing);
    v().setCallActive(false);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a file that fails the check: a plain reason, the running build untouched, try again', (tester) async {
    await pumpApp(tester);
    platform.downloadedSigner = 'someone-else';
    ota().check();
    await settle(tester);
    ota().startDownload();
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
    await openUpdates(tester);
    expect(find.text('The update was not installed'), findsOneWidget);
    expect(find.descendant(of: k('opendash-card'), matching: find.textContaining('not signed by OpenDash')), findsOneWidget);
    expect(find.text('The build that is running is untouched.'), findsOneWidget);
    expect(k('ota-install'), findsNothing);
    await tap(tester, 'ota-retry');
    expect(k('ota-download'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('"Skip this version" hides it; the setting switches the automatic check', (tester) async {
    await pumpApp(tester);
    ota().check();
    await settle(tester);
    await openUpdates(tester);
    await tap(tester, 'ota-skip');
    expect(find.text('OpenDash is up to date'), findsOneWidget);
    expect(container.read(bellProvider), isFalse);
    await tester.ensureVisible(find.text('Only when I ask'));
    await tester.tap(find.text('Only when I ask'));
    await settle(tester);
    expect(container.read(otaProvider).auto, isFalse);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('safe mode names an update that has not yet started cleanly', (tester) async {
    await pumpApp(tester);
    expect(k('safe-update'), findsNothing);
    platform
      ..installedBuild = 120
      ..record = {'from': 100, 'to': 120, 'starts': 2};
    container.invalidate(otaProvider);
    container.read(otaProvider);
    await settle(tester);
    container.read(crashRecoveryProvider.notifier).enterSafeMode();
    await settle(tester);
    expect(k('safe-update'), findsOneWidget);
    expect(find.textContaining('build 120'), findsWidgets);
    await tester.pump(const Duration(seconds: 12));
  });
  testWidgets('a check that cannot reach GitHub does not say up to date, and offers the companion app', (tester) async {
    await pumpApp(tester);
    platform.checkStatus = 0;
    ota().check(auto: true);
    await settle(tester);
    await openUpdates(tester);
    expect(find.text('OpenDash is up to date'), findsNothing);
    expect(find.text("Couldn't reach GitHub"), findsOneWidget);
    expect(find.text("Check the scooter's internet connection"), findsOneWidget);
    expect(find.text('Not checked yet'), findsNothing, reason: 'it was checked; GitHub did not answer');
    expect(k('ota-check'), findsOneWidget, reason: 'it can be tried again');
    await tap(tester, 'ota-get-companion');
    expect(container.read(qrCardProvider)?.id, 'companion');
    container.read(qrCardProvider.notifier).close();
    await settle(tester);
    // GitHub answers again: the card says what it found.
    platform.checkStatus = 200;
    ota().check();
    await settle(tester);
    expect(find.text("Couldn't reach GitHub"), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an update that failed also offers the companion app', (tester) async {
    await pumpApp(tester);
    platform.downloadedSigner = 'someone-else';
    ota().check();
    await settle(tester);
    ota().startDownload();
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
    await openUpdates(tester);
    expect(find.text('The update was not installed'), findsOneWidget);
    await tap(tester, 'ota-get-companion');
    expect(container.read(qrCardProvider)?.id, 'companion');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Updates offers the companion app as a QR code', (tester) async {
    await pumpApp(tester);
    await openUpdates(tester);
    await tap(tester, 'ota-companion');
    expect(container.read(qrCardProvider)?.id, 'companion');
  });
}

/// The mock's data marked as coming from the scooter's own service.
class _ScooterData extends VehicleNotifier {
  @override
  VehicleData build() => super.build().copyWith(hhmisBacked: true);

}
