import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/constants.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/app_catalog.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/services/recovery_service.dart';
import 'package:opendash/services/wifican_codec.dart';
import 'package:opendash/screens/settings/widgets.dart';
import 'package:opendash/state/access_state.dart';
import 'package:opendash/state/apps_state.dart';

class _FakeRecoveryClient implements RecoveryClient {
  final executed = <String>[];
  @override
  Future<WifiCanResponse> execute(String command, Duration timeout) async {
    executed.add(command);
    return const WifiCanResponse(1, '');
  }

  @override
  Future<void> shutdown() async {}
}

void main() {
  late ProviderContainer container;
  late MockPlatformService platform;
  late _FakeRecoveryClient fakeRecovery;
  Finder k(String id) => find.byKey(ValueKey(id));

  setUp(() {
    fakeRecovery = _FakeRecoveryClient();
    recoveryService = RecoveryService(clientFactory: (_, _) => fakeRecovery);
  });

  tearDown(() {
    recoveryService = RecoveryService();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> openApps(WidgetTester tester) async {
    platform = MockPlatformService();
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
    container.read(appLauncherOpenProvider.notifier).open();
    await settle(tester);
  }

  Future<void> openStockDialog(WidgetTester tester) async {
    await tester.tap(k('app-stock-dashboard'));
    await settle(tester);
    expect(k('stock-dashboard-dialog'), findsOneWidget);
    // The dialog names both ways back before the rider leaves.
    expect(find.textContaining('tap "← OpenDash"'), findsOneWidget);
    expect(find.textContaining('stock Settings → Reboot Scooter) also brings OpenDash back'), findsOneWidget);
  }

  testWidgets('Apps says to use Wi-Fi, and warns when the scooter is not on it', (tester) async {
    await openApps(tester);
    String hint() => tester.widget<Text>(k('apps-wifi-hint')).data!;
    container.read(vehicleProvider.notifier).setWifi(true);
    await settle(tester);
    expect(hint(), 'Install and update apps on Wi-Fi. Downloads often fail on mobile data.');

    container.read(vehicleProvider.notifier).setWifi(false);
    await settle(tester);
    expect(hint(), startsWith('Not on Wi-Fi.'));
    await tester.tap(k('app-browser'));
    await settle(tester);
    expect(find.textContaining('downloaded from GitHub'), findsOneWidget);
    expect(find.textContaining('You are not on Wi-Fi'), findsOneWidget);
  });

  testWidgets('the install dialog says what is fetched and what it is checked against', (tester) async {
    await openApps(tester);
    final auto = appCatalog.firstWhere((a) => a.id == 'android-auto');
    await tester.tap(find.descendant(of: k('app-android-auto'), matching: find.text('Install')));
    await settle(tester);
    expect(find.textContaining('The newest ${auto.appName} release will be downloaded'), findsOneWidget);
    expect(find.textContaining("checked against its developer's signing key"), findsOneWidget);
    expect(find.text('Unverified'), findsNothing, reason: 'every catalog entry is pinned');
  });

  testWidgets('the stock dashboard tile is always installed and opens the dialog', (tester) async {
    await openApps(tester);
    expect(appCatalog.firstWhere((a) => a.id == 'stock-dashboard').package, stockDashboardPackage);
    expect(container.read(appManagerProvider)['stock-dashboard'], AppStatus.installed);
    expect(find.text('Stock Dashboard'), findsOneWidget);
    await openStockDialog(tester);
    expect(find.text('Open stock'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('Open stock sends am start via the RecoveryService', (tester) async {
    await openApps(tester);
    await openStockDialog(tester);
    await tester.tap(find.text('Open stock'));
    await settle(tester);
    expect(fakeRecovery.executed, ['am start -n com.olaelectric.hmiclient/.MainActivity']);
    // The old platform-service launch path is no longer used.
    expect(platform.launched, isEmpty);
    expect(platform.homeSettingsOpened, 0);
    expect(k('stock-dashboard-dialog'), findsNothing);
  });

  testWidgets('Cancel closes without launching stock', (tester) async {
    await openApps(tester);
    await openStockDialog(tester);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(fakeRecovery.executed, isEmpty);
    expect(platform.launched, isEmpty);
    expect(platform.homeSettingsOpened, 0);
    expect(k('stock-dashboard-dialog'), findsNothing);
  });

  testWidgets('the bare Android launcher is not in the Apps grid', (tester) async {
    await openApps(tester);
    expect(appCatalog.map((a) => a.package), isNot(contains('com.android.launcher3')));
  });

  testWidgets('tapping the tile of an app that is not installed offers to install it', (tester) async {
    await openApps(tester);
    // Above the button: the tile itself, not its Install pill.
    await tester.tapAt(tester.getTopLeft(k('app-android-auto')) + const Offset(110, 60));
    await settle(tester);
    expect(find.text('Install Android Auto?'), findsOneWidget,
        reason: 'tapping the tiles once did nothing');
  });

  testWidgets('a queued tile carries Cancel, and Cancel puts it back to Install', (tester) async {
    await openApps(tester);
    final n = container.read(appManagerProvider.notifier);
    n.install(appCatalog.firstWhere((a) => a.id == 'browser'));
    n.install(appCatalog.firstWhere((a) => a.id == 'maps'));
    await tester.pump();
    expect(find.descendant(of: k('app-maps'), matching: find.text('Queued')), findsOneWidget);
    await tester.tap(find.descendant(of: k('app-maps'), matching: find.text('Cancel')));
    await tester.pump();
    expect(find.descendant(of: k('app-maps'), matching: find.text('Install')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(container.read(appManagerProvider)['maps'], AppStatus.notInstalled);
    expect(platform.downloads, 1, reason: 'Maps was never fetched');
  });

  Finder toggle(String access) => find.descendant(of: k('access-row-$access'), matching: find.byType(DashSwitch));

  testWidgets('what an app needs is asked for before it opens, as switches that are already on; Continue, and it opens',
      (tester) async {
    await openApps(tester);
    platform
      ..setInstalled(appCatalog.firstWhere((a) => a.id == 'carplay').package)
      ..overlayAllowed = false
      ..notificationAccess = false;
    container.read(appManagerProvider.notifier).refresh();
    await settle(tester);
    await tester.tapAt(tester.getTopLeft(k('app-carplay')) + const Offset(110, 60));
    await settle(tester);
    expect(find.text('Before CarPlay opens'), findsOneWidget);
    expect(tester.widget<DashSwitch>(toggle('overlay')).value, isTrue);
    expect(tester.widget<DashSwitch>(toggle('music')).value, isTrue,
        reason: 'hollow circles did not say whether they were to be tapped');
    expect(find.textContaining('Needed for this.'), findsOneWidget, reason: 'only showing over other apps');
    expect(toggle('front'), findsNothing, reason: 'already allowed: a tick, not a switch');
    expect(find.text('Allowed'), findsOneWidget);
    expect(container.read(mockAppProvider), isNull, reason: 'not opened yet');
    await tester.tap(k('access-allow'));
    await settle(tester);
    expect(k('access-prompt'), findsNothing);
    expect(container.read(mockAppProvider)?.id, 'carplay');
    expect(platform.notificationAccess, isTrue);
  });

  testWidgets('an optional access can be switched off before Continue; what is needed cannot', (tester) async {
    await openApps(tester);
    platform
      ..setInstalled(appCatalog.firstWhere((a) => a.id == 'carplay').package)
      ..overlayAllowed = false
      ..notificationAccess = false;
    container.read(appManagerProvider.notifier).refresh();
    await settle(tester);
    await tester.tapAt(tester.getTopLeft(k('app-carplay')) + const Offset(110, 60));
    await settle(tester);
    await tester.tap(toggle('music'));
    await tester.tap(toggle('overlay'));
    await settle(tester);
    expect(tester.widget<DashSwitch>(toggle('music')).value, isFalse);
    expect(tester.widget<DashSwitch>(toggle('overlay')).value, isTrue, reason: 'CarPlay cannot open without it');
    await tester.tap(k('access-allow'));
    await settle(tester);
    expect(container.read(mockAppProvider)?.id, 'carplay');
    expect(platform.overlayAllowed, isTrue);
    expect(platform.notificationAccess, isFalse, reason: 'left off, as chosen');
  });

  testWidgets('what could not be switched on from here gets the link to Android\'s page, and only then', (tester) async {
    await openApps(tester);
    platform
      ..usageAccess = false
      ..grantsRefused = true;
    await container.read(accessProvider.notifier).refresh();
    await settle(tester);
    expect(find.text('One thing OpenDash needs from Android is off'), findsOneWidget);
    await tester.tap(k('apps-access-review'));
    await settle(tester);
    expect(find.text('OpenDash access'), findsOneWidget);
    expect(k('access-open-front'), findsNothing);
    await tester.tap(k('access-allow'));
    await settle(tester);
    expect(k('access-open-front'), findsOneWidget);
    await tester.tap(k('access-open-front'));
    await settle(tester);
    expect(platform.systemPages, contains('usage_access'));
  });
}
