import 'package:fake_async/fake_async.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/settings/widgets.dart';
import 'package:opendash/state/alert_state.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/media_state.dart';
import 'package:opendash/state/ota_state.dart';
import 'package:opendash/state/profile_state.dart';
import 'package:opendash/state/safety_watchdog.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:opendash/theme/colors.dart';
import 'package:opendash/widgets/indicators/mode_ladder.dart';
import 'package:opendash/widgets/indicators/turn_arrow.dart';
import 'package:opendash/widgets/status_bar/status_bar.dart';

void main() {
  void withApp(void Function(FakeAsync async, ProviderContainer c, VehicleNotifier v) body) {
    fakeAsync((async) {
      final c = ProviderContainer();
      for (final p in [
        sessionProvider, toastProvider, safetyWatchdogProvider, dismissedAlertsProvider, alertCycleProvider,
        settingsScreenOpenProvider, appLauncherOpenProvider, diagnosticsOpenProvider, btScreenOpenProvider,
        otaScreenOpenProvider, licensesScreenOpenProvider,
      ]) {
        c.listen(p, (_, _) {});
      }
      final v = c.read(vehicleProvider.notifier);
      v.setConnected(true);
      v.setLocked(false);
      async.elapse(const Duration(seconds: 5));
      body(async, c, v);
      c.dispose();
    });
  }

  Set<AlertKind> visible(ProviderContainer c) => c.read(visibleAlertsProvider).map((a) => a.kind).toSet();

  group('state', () {
    test('opening a top-level screen closes every other sub-screen', () {
      withApp((async, c, v) {
        c.read(settingsScreenOpenProvider.notifier).open();
        c.read(appLauncherOpenProvider.notifier).open();
        expect(c.read(appLauncherOpenProvider), isTrue);
        expect(c.read(settingsScreenOpenProvider), isFalse);
        c.read(settingsScreenOpenProvider.notifier).open();
        expect(c.read(settingsScreenOpenProvider), isTrue);
        expect(c.read(appLauncherOpenProvider), isFalse);
      });
    });

    test('children keep settings underneath but replace each other', () {
      withApp((async, c, v) {
        c.read(settingsScreenOpenProvider.notifier).open();
        c.read(diagnosticsOpenProvider.notifier).open();
        c.read(otaScreenOpenProvider.notifier).open();
        expect(c.read(diagnosticsOpenProvider), isFalse);
        expect(c.read(otaScreenOpenProvider), isTrue);
        expect(c.read(settingsScreenOpenProvider), isTrue, reason: 'settings is the parent');
        c.read(btScreenOpenProvider.notifier).open();
        expect(c.read(otaScreenOpenProvider), isFalse);
        expect(c.read(btScreenOpenProvider), isTrue);
        c.read(licensesScreenOpenProvider.notifier).open();
        expect(c.read(btScreenOpenProvider), isFalse);
        expect(c.read(licensesScreenOpenProvider), isTrue);
        c.read(appLauncherOpenProvider.notifier).open();
        expect(c.read(licensesScreenOpenProvider), isFalse);
        expect(c.read(settingsScreenOpenProvider), isFalse);
        final open = [
          settingsScreenOpenProvider, appLauncherOpenProvider, diagnosticsOpenProvider,
          btScreenOpenProvider, otaScreenOpenProvider, licensesScreenOpenProvider,
        ].where((p) => c.read(p)).length;
        expect(open, 1, reason: 'never more than one sub-screen');
      });
    });

    test('registration number defaults to KL', () {
      final c = ProviderContainer();
      expect(c.read(profileProvider).registrationNumber, 'KL 01 AB 1234');
      c.dispose();
    });

    // Shows for ~3 s every time, not once per session.
    test('mode in park hint fires again on each attempt', () {
      withApp((async, c, v) {
        v.setVehicleState(VehicleState.parked);
        v.selectDriveMode(DriveMode.sport);
        async.flushMicrotasks();
        expect(c.read(vehicleProvider).hintModeInPark, isTrue);
        expect(visible(c), contains(AlertKind.driveModeInPark));
        async.elapse(const Duration(seconds: 6));
        expect(c.read(vehicleProvider).hintModeInPark, isFalse);
        v.selectDriveMode(DriveMode.eco);
        async.flushMicrotasks();
        expect(c.read(vehicleProvider).hintModeInPark, isTrue);
        expect(visible(c), contains(AlertKind.driveModeInPark),
            reason: 'fires again on every attempt');
      });
    });

    test('nav mock fills the totals and nothing else for time', () {
      withApp((async, c, v) {
        v.setNavActive(true);
        final s = c.read(vehicleProvider);
        expect(s.navTotalDistance, '7.6 km');
        expect(s.navTotalTime, '23 min');
        v.setNavActive(false);
        v.setNavDirection('Turn left onto Brigade Road');
        expect(c.read(vehicleProvider).navTotalTime, '23 min');
      });
    });

    test('battery health is a flag with a description, not a percentage', () {
      withApp((async, c, v) {
        expect(c.read(vehicleProvider).batteryHealthGood, isTrue);
        expect(c.read(vehicleProvider).batterySohDescription, isEmpty);
        v.setBatteryHealth(false);
        expect(c.read(vehicleProvider).batteryHealthGood, isFalse);
        expect(c.read(vehicleProvider).batterySohDescription, isNotEmpty);
      });
    });

    test('firmware, identity and network values live on VehicleData', () {
      const v = VehicleData();
      expect(v.firmwareVersions.map((e) => e.$1), ['MoveOS', 'Vehicle Software', 'Vehicle Data Protocol', 'Dashboard', 'Body Control Module', 'Battery Management', 'Motor Controller', 'Hub Controller', 'Head Unit', 'Bluetooth']);
      expect(v.moveOsVersion, '4.6.0');
      expect(v.vin, 'OLA•••••••2408');
      expect(v.wifiMac, 'AA:BB:CC:DD:EE:FF');
      expect(v.copyWith(moveOsVersion: '5.0.0').firmwareVersions.first, ('MoveOS', '5.0.0'));
    });
  });

  group('widgets', () {
    late ProviderContainer container;
    VehicleNotifier v() => container.read(vehicleProvider.notifier);
    Finder k(String id) => find.byKey(ValueKey(id));

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

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('hazard after a solo indicator blinks both arrows in phase', (tester) async {
      var left = true, right = false;
      late StateSetter set;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            set = setState;
            return Directionality(
              textDirection: TextDirection.ltr,
              child: Row(children: [
                TurnArrow(key: const ValueKey('l'), on: left, left: true, hazard: left && right),
                TurnArrow(key: const ValueKey('r'), on: right, left: false, hazard: left && right),
              ]),
            );
          },
        ),
      );
      bool lit(String id) => (tester.widget<CustomPaint>(find.descendant(of: k(id), matching: find.byType(CustomPaint))).painter as dynamic).lit as bool;

      await tester.pump(const Duration(milliseconds: 300));
      set(() => left = false);
      await tester.pump();
      set(() {
        left = true;
        right = true;
      });
      await tester.pump();
      for (final dt in [100, 200, 200, 200]) {
        await tester.pump(Duration(milliseconds: dt));
        expect(lit('l'), lit('r'), reason: 'arrows disagree at +$dt ms');
      }
      await tester.pump(const Duration(milliseconds: 200));
      expect(lit('l'), isTrue, reason: 'fresh cycle starts lit');
      // Right stays on and hazard joins it: the running arrow restarts too.
      set(() => left = false);
      await tester.pump(const Duration(milliseconds: 450));
      set(() => left = true);
      await tester.pump();
      for (final dt in [100, 200, 200, 200]) {
        await tester.pump(Duration(milliseconds: dt));
        expect(lit('l'), lit('r'), reason: 'arrows disagree after joining at +$dt ms');
      }
      set(() {
        left = false;
        right = false;
      });
      await tester.pump();
    });

    testWidgets('status bar has no drive-mode chip; the ladder and accent carry the mode', (tester) async {
      await pumpApp(tester);
      for (final state in [VehicleState.ready, VehicleState.riding, VehicleState.parked]) {
        v().setVehicleState(state);
        await settle(tester);
        expect(k('status-mode'), findsNothing, reason: state.name);
        for (final mode in DriveMode.values) {
          expect(find.descendant(of: find.byType(StatusBar), matching: find.text(mode.label)), findsNothing);
        }
      }
      v().selectDriveMode(DriveMode.sport);
      await settle(tester);
      expect(find.text('Mode change applies when riding'), findsWidgets, reason: 'toast and the once-per-session hint');
      v().setVehicleState(VehicleState.ready);
      await settle(tester);
      expect(find.descendant(of: find.byType(ModeLadder), matching: find.text('SPORT')), findsOneWidget);
      expect(container.read(accentProvider), DashColors.sport);
    });

    testWidgets('status bar icons swap sub-screens instead of stacking them', (tester) async {
      await pumpApp(tester);
      await tester.tap(k('status-settings'));
      await settle(tester);
      expect(container.read(settingsScreenOpenProvider), isTrue);
      // The status bar is collapsed behind the toolbar; a pull-down peeks it.
      await tester.drag(k('overlay-toolbar'), const Offset(0, 80));
      await settle(tester);
      await tester.tap(k('status-apps'));
      await settle(tester);
      expect(container.read(appLauncherOpenProvider), isTrue);
      expect(container.read(settingsScreenOpenProvider), isFalse);
      await tester.drag(k('overlay-toolbar'), const Offset(0, 80));
      await settle(tester);
      await tester.tap(k('status-settings'));
      await settle(tester);
      expect(container.read(settingsScreenOpenProvider), isTrue);
      expect(container.read(appLauncherOpenProvider), isFalse);
    });

    testWidgets('nav bar shows the totals once with no separate eta', (tester) async {
      await pumpApp(tester);
      v().setNavActive(true);
      await settle(tester);
      expect(find.text('400 m'), findsOneWidget);
      expect(find.text('7.6 km · 23 min'), findsOneWidget);
      expect(find.text('23 min'), findsNothing);
      expect(find.text('14 min'), findsNothing);
    });

    testWidgets('vehicle info reads health, firmware and identity from vehicle data', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      await tester.tap(k('section-vehicleInfo'));
      await settle(tester);
      final data = container.read(vehicleProvider);
      for (final (label, value) in data.firmwareVersions) {
        expect(find.text(label), findsOneWidget);
        expect(find.text(value), findsWidgets);
      }
      // Identifiers show their last four until held.
      expect(find.text(MaskedValueRow.mask(data.vin)), findsOneWidget);
      expect(find.text(MaskedValueRow.mask(data.iccid)), findsOneWidget);
      expect(find.text(data.vin), findsNothing);
      expect(find.textContaining('96%'), findsNothing);
      // BMS reports the SOH shortly after bind; pre-data
      // the row shows '—'. Simulate the key arriving.
      v().setBatteryHealth(true);
      await settle(tester);
      final status = tester.widget<Text>(k('soh-status'));
      expect(status.data, 'Good');
      expect(status.style!.color, DashColors.eco);
      v().setBatteryHealth(false);
      await settle(tester);
      expect(tester.widget<Text>(k('soh-status')).data, 'Degraded');
      expect(tester.widget<Text>(k('soh-status')).style!.color, DashColors.warning);
      await tester.ensureVisible(k('soh-row'));
      await tester.tap(k('soh-row'));
      await settle(tester);
      expect(find.descendant(of: k('soh-value'), matching: find.text('Degraded'), matchRoot: true), findsOneWidget);
      expect(k('soh-description'), findsOneWidget);
      expect(find.descendant(of: k('soh-popup'), matching: find.textContaining(RegExp(r'^\d+%$'))), findsNothing);
    });

    testWidgets('connectivity shows the network identity from vehicle data', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      await tester.tap(k('section-connectivity'));
      await settle(tester);
      final data = container.read(vehicleProvider);
      expect(find.text(data.wifiMac), findsOneWidget);
      expect(find.text(data.ipAddress), findsOneWidget);
      expect(find.text(data.btMac), findsOneWidget);
    });
  });
}
