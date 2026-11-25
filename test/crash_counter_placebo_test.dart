import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:opendash/state/alert_state.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/error_state.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(PrefsService.resetForTest);

  group('crash counter', () {
    Future<void> boot(Map<String, Object> stored) async {
      SharedPreferences.setMockInitialValues(stored);
      await PrefsService.init();
    }

    setUp(AnalyticsLogger.instance.resetForTest);

    test('survives the fresh container a retry builds, and reaches safe mode on the third', () async {
      await boot({});
      for (var run = 1; run <= CrashRecoveryNotifier.maxCrashes; run++) {
        final c = ProviderContainer();
        c.read(appErrorProvider.notifier).report(StateError('run $run'));
        expect(c.read(crashRecoveryProvider).consecutiveCrashes, run);
        expect(c.read(crashRecoveryProvider).safeMode, run == CrashRecoveryNotifier.maxCrashes);
        c.dispose();
      }
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('crashCount'), 3);
    });

    test('a start with three stored crashes opens in safe mode and says so in the log', () async {
      await boot({'crashCount': 3});
      final c = ProviderContainer();
      expect(c.read(crashRecoveryProvider).safeMode, isTrue);
      expect(c.read(crashRecoveryProvider).consecutiveCrashes, 3);
      final restored = AnalyticsLogger.instance.recent('recovery', 'crash_count_restored').single['data'] as Map;
      expect(restored, {'crashes': 3, 'safe_mode': true});
      c.dispose();
    });

    test('a stable boot and Retry both clear the stored count', () async {
      await boot({'crashCount': 2});
      var c = ProviderContainer();
      expect(c.read(crashRecoveryProvider).safeMode, isFalse);
      c.read(crashRecoveryProvider.notifier).markStableBoot();
      expect(c.read(crashRecoveryProvider).consecutiveCrashes, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('crashCount'), isFalse);
      c.dispose();

      await prefs.setInt('crashCount', 3);
      c = ProviderContainer();
      expect(c.read(crashRecoveryProvider).safeMode, isTrue);
      c.read(crashRecoveryProvider.notifier).retry();
      expect(c.read(crashRecoveryProvider).safeMode, isFalse);
      expect(prefs.containsKey('crashCount'), isFalse);
      c.dispose();
      c = ProviderContainer();
      expect(c.read(crashRecoveryProvider).consecutiveCrashes, 0);
      c.dispose();
    });

    test('nothing stored, nothing logged', () async {
      await boot({});
      final c = ProviderContainer();
      expect(c.read(crashRecoveryProvider).consecutiveCrashes, 0);
      expect(AnalyticsLogger.instance.recent('recovery', 'crash_count_restored'), isEmpty);
      c.dispose();
    });
  });

  group('removed placebo controls and dead code', () {
    late ProviderContainer container;
    Finder k(String key) => find.byKey(ValueKey(key));

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> pumpApp(WidgetTester tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [platformServiceProvider.overrideWithValue(MockPlatformService())],
        child: const OpenDashApp(),
      ));
      await tester.pump();
      container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      container.read(vehicleProvider.notifier).setLocked(false);
      await settle(tester);
    }

    test('service mode lists only real packages', () {
      expect(ServiceModeOpen.apps, [('HMFG App', 'com.ola.mfgapp'), ('UDS Test', 'com.olaelectric.udstestapp')]);
    });

    test('settings has no Access Controls section', () {
      expect(SettingsSection.values.map((s) => s.label), isNot(contains('Access Controls')));
    });

    test('the clock alone raises no alert: there is no time fence', () {
      expect(allAlerts(const VehicleData(), RidingSettings()), isEmpty);
    });

    testWidgets('a first start goes straight to the dashboard: no first-run flow', (tester) async {
      await pumpApp(tester);
      expect(k('ftux'), findsNothing);
      expect(find.text('Choose a 6-digit code to secure your scooter'), findsNothing);
      expect(k('status-clock').hitTestable(), findsOneWidget);
    });

    testWidgets('riding settings offer no duration for auto turn-off or take-me-home', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      await tester.tap(k('section-riding'));
      await settle(tester);
      expect(k('riding-autoTurnOff'), findsOneWidget, reason: 'the toggle the vehicle honours stays');
      await tester.scrollUntilVisible(k('riding-takeMeHome'), 200, scrollable: find.descendant(of: k('settings-body'), matching: find.byType(Scrollable)).first);
      expect(k('riding-takeMeHome'), findsOneWidget);
      expect(find.text('15 min'), findsNothing);
      expect(find.text('Timer'), findsNothing);
      expect(container.read(ridingSettingsProvider).toJson().keys, isNot(anyOf(contains('autoTurnOffMinutes'), contains('takeMeHomeSeconds'))));
    });
  });
}
