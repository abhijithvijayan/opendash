import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:opendash/models/app_catalog.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/locked/locked_screen.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/state/passcode_state.dart';
import 'package:opendash/models/vehicle_data.dart';

/// A rider's notes on a first ride and what the log showed behind them.
void main() {
  const kotlin = 'android/app/src/main/kotlin/in/abhijithvijayan/opendash';

  test('"Mode selected" is only for a scooter that is parked', () {
    bool hint(VehicleData v) => v.alerts.any((a) => a.kind == AlertKind.driveModeInPark);
    expect(hint(const VehicleData(hintModeInPark: true, vehicleState: VehicleState.parked)), isTrue);
    expect(hint(const VehicleData(hintModeInPark: true, vehicleState: VehicleState.ready)), isFalse);
    expect(hint(const VehicleData(hintModeInPark: true, vehicleState: VehicleState.riding, speed: 12)), isFalse,
        reason: 'it came up 3 s late, under way, when Settings closed');
  });

  group('one dashboard at a time', () {
    final activity = File('$kotlin/MainActivity.kt').readAsStringSync();
    final island = File('$kotlin/DashIsland.kt').readAsStringSync();

    test('a new instance retires the one before it, before it builds its own engine', () {
      final create = activity.substring(activity.indexOf('override fun onCreate'), activity.indexOf('override fun configureFlutterEngine'));
      expect(create.indexOf('older!!.retire()'), greaterThan(0));
      expect(create.indexOf('older!!.retire()'), lessThan(create.indexOf('super.onCreate(savedInstanceState)')));
      expect(activity, contains('finishAndRemoveTask()'));
    });

    // Seen on a scooter: the retired instance let go of HHMIS, HHMIS had no
    // other client, and it was 44 s before the scooter answered again.
    test('retiring does not let go of the scooter; the connection passes to the newest channel', () {
      final retire = activity.substring(activity.indexOf('private fun retire()'), activity.indexOf('private fun releaseBridges()'));
      expect(retire.contains('releaseBridges()'), isFalse);
      final channel = File('$kotlin/VehicleChannel.kt').readAsStringSync();
      expect(channel, contains('private object Link'));
      expect(channel, contains('Link.service ?: HhmisService('));
      final dispose = channel.substring(channel.indexOf('fun dispose()'), channel.indexOf('internal fun publish('));
      expect(dispose.indexOf('if (Link.live !== this) return'), greaterThan(0));
      expect(dispose.indexOf('if (Link.live !== this) return'), lessThan(dispose.indexOf('service.stop()')));
    });

    test('a retired instance does not tear down what its successor attached', () {
      final destroy = activity.substring(activity.indexOf('override fun onDestroy'));
      final guarded = destroy.substring(destroy.indexOf('if (!retired) {'), destroy.indexOf('} else {'));
      expect(guarded, contains('Analytics.detach()'));
      expect(guarded, contains('DashIsland.detach()'));
      expect(RegExp(r'DashIsland\.detach\(\)').allMatches(destroy), hasLength(1));
      expect(RegExp(r'Analytics\.detach\(\)').allMatches(destroy), hasLength(1));
    });

    test('the island listens to the newest engine only', () {
      final attach = island.substring(island.indexOf('fun attach('), island.indexOf('fun detach('));
      expect(attach.indexOf('channel?.setMethodCallHandler(null)'), greaterThan(0));
      expect(attach.indexOf('channel?.setMethodCallHandler(null)'), lessThan(attach.indexOf('channel = MethodChannel(')));
    });
  });

  test('a countdown row is drawn without a percentage', () {
    final island = File('$kotlin/DashIsland.kt').readAsStringSync();
    expect(island, contains('sub["percent"] == false'));
  });

  group('a passcode digit that did not count says why', () {
    setUp(AnalyticsLogger.instance.resetForTest);

    test('digits wiped by something other than the rider are logged, with how many', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final p = c.read(passcodeProvider.notifier);
      p.clear('screen_off');
      expect(AnalyticsLogger.instance.recent('safety', 'passcode_cleared'), isEmpty, reason: 'nothing was entered');
      p.enterDigit(1);
      p.enterDigit(2);
      p.clear('screen_off');
      expect(AnalyticsLogger.instance.recent('safety', 'passcode_cleared').single['data'], {'reason': 'screen_off', 'digits': 2});
    });

    test('a digit entered while six are waiting for the scooter is logged, never its value', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final p = c.read(passcodeProvider.notifier);
      for (var i = 0; i < 6; i++) {
        p.enterDigit(9);
      }
      AnalyticsLogger.instance.resetForTest();
      p.enterDigit(9);
      final ignored = AnalyticsLogger.instance.recent('ui', 'keypad_ignored');
      if (ignored.isNotEmpty) {
        expect(ignored.single['data'], {'screen': 'lock', 'reason': anyOf('waiting_for_answer', 'already_unlocking', 'locked_out')});
      }
      expect('${AnalyticsLogger.instance.recent('ui', 'keypad_ignored')}'.contains('9'), isFalse);
    });
  });

  test('a controller that has not reported its version is not a version', () {
    final source = File('lib/state/firmware_state.dart').readAsStringSync();
    final pattern = RegExp(RegExp(r"_unreported = RegExp\(r'([^']+)'\)").firstMatch(source)!.group(1)!);
    for (final unreported in ['L- 0.0.0.0 R- 2.2.4.1', '0.0.0.0', '0.0', 'BMS 0.0.0']) {
      expect(pattern.hasMatch(unreported), isTrue, reason: unreported);
    }
    for (final real in ['L- 2.2.4.1 R- 2.2.4.1', '4.0.4', '10.0.2', '2.0.0.1', '1.0', '4.66.0.4']) {
      expect(pattern.hasMatch(real), isFalse, reason: real);
    }
  });

  test('every app has a name short enough for the dashboard\'s way back to it', () {
    for (final app in appCatalog) {
      expect(app.chipName.length, lessThanOrEqualTo(CatalogApp.chipNameMax), reason: app.name);
      expect(app.chipName, isNotEmpty);
    }
    expect(appCatalog.firstWhere((a) => a.id == CatalogApp.androidSettingsId).chipName, 'Settings');
  });

  // A rider stood at the lock screen through an outage with the right
  // passcode and no way anywhere else.
  group('the lock screen offers the stock dashboard only when it cannot unlock', () {
    Future<ProviderContainer> pump(WidgetTester tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(home: Scaffold(body: SizedBox(width: 1280, height: 768, child: LockedScreen()))),
      ));
      await tester.pump();
      return c;
    }

    testWidgets('not in normal use: the finder of a locked scooter sees Emergency and nothing more', (tester) async {
      tester.view.physicalSize = const Size(1280, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = await pump(tester);
      c.read(vehicleProvider.notifier).setConnected(true);
      await tester.pump();
      expect(find.text('Emergency'), findsOneWidget);
      expect(find.byKey(const ValueKey('lock-stock')), findsNothing);
      expect(find.byKey(const ValueKey('lock-not-connected')), findsNothing);
    });

    testWidgets('there, with the reason, while the vehicle service is not connected', (tester) async {
      tester.view.physicalSize = const Size(1280, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = await pump(tester);
      c.read(vehicleProvider.notifier).setConnected(false);
      await tester.pump();
      expect(find.byKey(const ValueKey('lock-stock')), findsOneWidget);
      expect(find.text("Can't reach the scooter. Still trying…"), findsOneWidget);
      c.read(vehicleProvider.notifier).setConnected(true);
      await tester.pump();
      expect(find.byKey(const ValueKey('lock-stock')), findsNothing);
    });

    testWidgets('there after a passcode that got no answer, and gone after one that did', (tester) async {
      tester.view.physicalSize = const Size(1280, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = await pump(tester);
      final n = c.read(vehicleProvider.notifier)..setConnected(true);
      n.passcodeUnanswered.value = true;
      await tester.pump();
      expect(find.byKey(const ValueKey('lock-stock')), findsOneWidget);
      n.passcodeUnanswered.value = false;
      await tester.pump();
      expect(find.byKey(const ValueKey('lock-stock')), findsNothing);
    });
  });
}
