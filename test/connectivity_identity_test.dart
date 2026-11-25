import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:opendash/constants.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/battery_diagnostics_provider.dart';
import 'package:opendash/providers/hhmis_mapping.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/screens/diagnostics/diagnostics_screen.dart';
import 'package:opendash/screens/locked/emergency_sheet.dart';
import 'package:opendash/screens/settings/sections/connectivity_section.dart';
import 'package:opendash/screens/settings/sections/profile_section.dart';
import 'package:opendash/screens/settings/sections/vehicle_info_section.dart';
import 'package:opendash/screens/settings/widgets.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/fault_history_state.dart';
import 'package:opendash/state/media_state.dart';
import 'package:opendash/state/passcode_gate.dart';
import 'package:opendash/state/profile_state.dart';
import 'package:opendash/widgets/status_bar/status_bar.dart';
import 'package:opendash/widgets/status_bar/status_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'helpers/stock.dart';

class _BtOpen extends BtScreenOpen {
  @override
  bool build() => true;
}

class _DiagOpen extends DiagnosticsOpen {
  @override
  bool build() => true;
}

class _FaultTab extends DiagTabNotifier {
  @override
  DiagTab build() => DiagTab.faultCodes;
}

void main() {
  late StreamController<dynamic> events;
  late ProviderContainer container;
  Finder k(String id) => find.byKey(ValueKey(id));

  setUp(() {
    AnalyticsLogger.instance.resetForTest();
    events = StreamController<dynamic>();
  });
  tearDown(() {
    debugUseAidlVehicle = null;
    events.close();
  });

  List<Object> liveOverrides() => [
        vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: events.stream, invoke: (_, _) async => true)),
        batteryDiagnosticsProvider.overrideWith(BatteryDiagnosticsNotifier.new),
        platformServiceProvider.overrideWithValue(MockPlatformService()),
        btScreenOpenProvider.overrideWith(_BtOpen.new),
        diagnosticsOpenProvider.overrideWith(_DiagOpen.new),
        diagTabProvider.overrideWith(_FaultTab.new),
      ];

  /// One screen on the 1280x768 canvas; [live] renders the head unit's
  /// variant against an AidlVehicleNotifier fed through [events].
  Future<void> pump(WidgetTester tester, Widget child, {required bool live, bool stack = false}) async {
    debugUseAidlVehicle = live;
    tester.view.physicalSize = const Size(1280, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        if (live)
          ...liveOverrides().cast()
        else ...[
          btScreenOpenProvider.overrideWith(_BtOpen.new),
          diagnosticsOpenProvider.overrideWith(_DiagOpen.new),
          diagTabProvider.overrideWith(_FaultTab.new),
        ],
      ],
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: stack ? Stack(children: [child]) : SingleChildScrollView(child: child),
      ),
    ));
    container = ProviderScope.containerOf(tester.element(find.byWidget(child)));
    await tester.pump();
  }

  Future<void> send(WidgetTester tester, Map<String, Object?> batch) async {
    (container.read(vehicleProvider.notifier) as AidlVehicleNotifier).onEvent(batch);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('bridge keys', () {
    VehicleData apply(Map<String, Object?> d, [VehicleData v = const VehicleData(signalBars: 0, ipAddress: '', btDeviceName: '')]) =>
        applyHhmisUpdate(v, d);

    test('signal level, IP, Bluetooth identity and versions map to their fields', () {
      expect(apply({'_signal': 3}).signalBars, 3);
      expect(apply({'_signal': 9}).signalBars, 4);
      expect(apply({'_signal': 'x'}).signalBars, 0);
      expect(apply({'_ip': '192.168.4.20'}).ipAddress, '192.168.4.20');
      expect(apply({'_ip': ''}, const VehicleData(ipAddress: '10.0.0.2')).ipAddress, '');
      expect(apply({'_btName': 'bluebird'}).scooterBtName, 'bluebird');
      expect(apply({'_btName': ''}, const VehicleData(scooterBtName: 'kept')).scooterBtName, 'kept');
      expect(apply({'_btDevice': 'Pixel 8'}).btDeviceName, 'Pixel 8');
      expect(apply({'_btBonded': ['Pixel 8', 7, 'iPhone']}).btBondedDevices, ['Pixel 8', 'iPhone']);
      final v = apply({'_moveOs': '4.6.14', '_vsw': '4.6.0.1', '_vdp': '2.3.1'});
      expect((v.moveOsVersion, v.vswVersion, v.vdpVersion), ('4.6.14', '4.6.0.1', '2.3.1'));
    });

    test('STR_PROFILE_USER_NAME maps to the profile name and is not reported unknown', () {
      final unknown = <String>[];
      final v = applyHhmisUpdate(const VehicleData(), {'STR_PROFILE_USER_NAME': 'Asha'}, onUnknown: unknown.add);
      expect(v.profileUserName, 'Asha');
      expect(unknown, isEmpty);
    });

    test('the HHMIS notifier starts with the dashboard version and ignores the mock link setters', () {
      final c = ProviderContainer(overrides: [
        vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: events.stream, invoke: (_, _) async => true)),
      ]);
      addTearDown(c.dispose);
      final n = c.read(vehicleProvider.notifier);
      expect(c.read(vehicleProvider).hmiVersion, appVersion);
      (n as AidlVehicleNotifier).onEvent({'_wifi': true, '_bt': true, '_btDevice': 'Pixel 8', '_signal': 2});
      n.setWifi(false);
      n.setBtConnected(false);
      n.disconnectBt();
      n.setSignalBars(4);
      n.setGps(true);
      final v = c.read(vehicleProvider);
      expect((v.wifiConnected, v.btConnected, v.btDeviceName, v.signalBars, v.gpsFix), (true, true, 'Pixel 8', 2, false));
      n.onEvent({'_bt': false});
      n.setBtConnected(true);
      expect(c.read(vehicleProvider).btConnected, isFalse, reason: 'the mock toggle invented a connected phone');
    });
  });

  group('Connectivity section', () {
    testWidgets('mock: the demo Wi-Fi list and both switches are there', (tester) async {
      await pump(tester, const ConnectivitySection(), live: false);
      expect(k('wifi-toggle'), findsOneWidget);
      expect(k('wifi-HomeWifi_5G'), findsOneWidget);
      expect(k('wifi-scan'), findsOneWidget);
      expect(k('bt-toggle'), findsOneWidget);
      expect(k('wifi-android-settings'), findsNothing);
      expect(find.text('BT MAC'), findsOneWidget);
    });

    testWidgets('head unit: no mock networks or switches; real link state, IP and names', (tester) async {
      await pump(tester, const ConnectivitySection(), live: true);
      expect(k('wifi-toggle'), findsNothing);
      expect(k('wifi-HomeWifi_5G'), findsNothing);
      expect(k('wifi-scan'), findsNothing);
      expect(k('bt-toggle'), findsNothing);
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text('No phone connected'), findsOneWidget);
      expect(find.text('IP Address'), findsNothing, reason: 'blank rows are hidden');
      expect(find.text('BT MAC'), findsNothing);
      expect(find.text('Scooter BT Name'), findsNothing);

      await send(tester, {'_wifi': true, '_ip': '192.168.4.20', '_btDevice': 'Pixel 8', '_bt': true, '_btName': 'bluebird'});
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('192.168.4.20'), findsOneWidget);
      expect(find.descendant(of: k('bt-status'), matching: find.text('Pixel 8')), findsOneWidget);
      expect(find.descendant(of: k('bt-scooter-name'), matching: find.text('bluebird')), findsOneWidget);
      expect(find.text('BT MAC'), findsNothing, reason: 'not readable by a non-system app');
    });

    testWidgets('head unit: Android Settings opens behind the passcode gate', (tester) async {
      await pump(tester, const ConnectivitySection(), live: true);
      await send(tester, {'_connected': true});
      await tester.tap(find.descendant(of: k('wifi-android-settings'), matching: find.text('Open Android Settings')));
      await tester.pump();
      expect(container.read(passcodeGateProvider).open, isTrue);
      expect(AnalyticsLogger.instance.recent('ui', 'tap').last['data'], containsPair('target', 'open-android-settings'));
    });
  });


  group('fault history', () {
    test('mock is seeded; a new fault goes on top and clears with the latch', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(faultHistoryProvider), FaultHistoryNotifier.mockSeed);
      c.read(vehicleProvider.notifier)
        ..setFaultCode('E7')
        ..setFault(true);
      var h = c.read(faultHistoryProvider);
      expect(h.length, 4);
      expect((h.first.code, h.first.cleared), ('E7', false));
      c.read(vehicleProvider.notifier).setFault(false);
      h = c.read(faultHistoryProvider);
      expect(h.first.cleared, isTrue);
      expect(h.length, 4);
    });

    test('head unit: empty at first, built from vehicle commands, persisted', () async {
      SharedPreferences.setMockInitialValues({});
      await PrefsService.init();
      addTearDown(PrefsService.resetForTest);
      debugUseAidlVehicle = true;
      ProviderContainer make() => ProviderContainer(overrides: [
            vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: const Stream.empty(), invoke: (_, _) async => true)),
          ]);
      final c = make();
      expect(c.read(faultHistoryProvider), isEmpty);
      final n = c.read(vehicleProvider.notifier) as AidlVehicleNotifier;
      n.onEvent({'INT_VEHICLE_COMMAND': 93});
      var h = c.read(faultHistoryProvider);
      expect(h.single.code, 'C93');
      expect(h.single.title, FaultHistoryNotifier.titleFor('C93'));
      expect(h.single.title, isNot('Fault'), reason: 'ordinal 93 has stock text');
      expect(h.single.cleared, isFalse);
      n.onEvent({'INT_VEHICLE_COMMAND': 93});
      expect(c.read(faultHistoryProvider).length, 1, reason: 'the same latched fault is one record');
      expect(AnalyticsLogger.instance.recent('state', 'fault_recorded').single['data'], containsPair('code', 'C93'));
      n.onEvent({'INT_VEHICLE_COMMAND': 98});
      expect(c.read(faultHistoryProvider).single.cleared, isTrue);
      c.dispose();

      final again = make();
      addTearDown(again.dispose);
      h = again.read(faultHistoryProvider);
      expect((h.single.code, h.single.cleared), ('C93', true));
    });

    test('head unit: a fault left open by the last run loads as ended; the list is capped', () async {
      SharedPreferences.setMockInitialValues({
        FaultHistoryNotifier.prefsKey: '[{"code":"C162","title":"x","at":1000,"cleared":null},{"bad":1}]',
      });
      await PrefsService.init();
      addTearDown(PrefsService.resetForTest);
      debugUseAidlVehicle = true;
      final c = ProviderContainer(overrides: [
        vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), events: const Stream.empty(), invoke: (_, _) async => true)),
      ]);
      addTearDown(c.dispose);
      expect(c.read(faultHistoryProvider).single.cleared, isTrue);
      final n = c.read(vehicleProvider.notifier) as AidlVehicleNotifier;
      for (var i = 0; i < FaultHistoryNotifier.maxRecords + 5; i++) {
        n.onEvent({'INT_VEHICLE_COMMAND': i.isEven ? 93 : 162});
      }
      expect(c.read(faultHistoryProvider).length, FaultHistoryNotifier.maxRecords);
    });

    testWidgets('head unit: Diagnostics shows no invented faults and no E000', (tester) async {
      await pump(tester, const DiagnosticsScreen(), live: true, stack: true);
      expect(k('diag-fault-history-empty'), findsOneWidget);
      for (final r in FaultHistoryNotifier.mockSeed) {
        expect(find.text(r.code), findsNothing);
        expect(find.text(r.title), findsNothing);
      }
      await send(tester, {'INT_VEHICLE_COMMAND': 93});
      expect(k('diag-fault-history-empty'), findsNothing);
      expect(find.descendant(of: k('diag-active-fault'), matching: find.text('C93'), matchRoot: true), findsOneWidget);
      expect(find.text('E000'), findsNothing);
      expect(find.text('C93'), findsNWidgets(2), reason: 'the active card and its history row');
    });

    testWidgets('mock: Diagnostics lists the seeded history', (tester) async {
      await pump(tester, const DiagnosticsScreen(), live: false, stack: true);
      for (final r in FaultHistoryNotifier.mockSeed) {
        expect(find.text(r.code), findsOneWidget);
      }
      container.read(vehicleProvider.notifier).setFault(true);
      await tester.pump();
      expect(find.text('E000'), findsNothing);
      expect(find.descendant(of: k('diag-active-fault'), matching: find.text('Fault'), matchRoot: true), findsOneWidget);
    });
  });

  group('profile and emergency card', () {
    testWidgets('mock profile keeps its demo rows', (tester) async {
      await pump(tester, const ProfileSection(), live: false);
      expect(find.text('KL 01 AB 1234'), findsOneWidget);
      expect(k('profile-add-rider'), findsOneWidget);
    });

    testWidgets('head unit profile: only what HHMIS sent', (tester) async {
      await pump(tester, const ProfileSection(), live: true);
      expect(k('profile-live'), findsOneWidget);
      expect(find.text('KL 01 AB 1234'), findsNothing);
      expect(find.text('Registration'), findsNothing);
      expect(find.text('Purchased'), findsNothing);
      expect(find.text('Owner'), findsNothing);
      expect(find.textContaining('(you)'), findsNothing);
      expect(k('profile-add-rider'), findsNothing);
      expect(k('profile-name'), findsNothing);
      expect(find.text('Scooter name'), findsNothing);
      expect(container.read(profileProvider).name, '');

      await send(tester, {'STR_PROFILE_USER_NAME': 'Asha', 'STR_PROFILE_SCOOTER_NAME': 'bluebird'});
      expect(find.descendant(of: k('profile-name'), matching: find.text('Asha'), matchRoot: true), findsOneWidget);
      expect(find.text('bluebird'), findsOneWidget);
      expect(k('profile-edit-scooter-name'), findsNothing, reason: 'names are set in the Ola app');
    });

    testWidgets('head unit emergency card: no placeholder owner or contacts', (tester) async {
      await pump(tester, EmergencySheet(onClose: () {}), live: true, stack: true);
      expect(find.text('Add in settings'), findsNothing);
      expect(find.text('Emergency contact'), findsNothing);
      expect(find.text('Blood type'), findsNothing);
      expect(k('emergency-owner'), findsNothing);
      expect(find.text('Emergency number'), findsOneWidget);
      await send(tester, {'STR_PROFILE_USER_NAME': 'Asha'});
      expect(find.descendant(of: k('emergency-owner'), matching: find.text('Asha')), findsOneWidget);
    });

    testWidgets('mock emergency card is unchanged', (tester) async {
      await pump(tester, EmergencySheet(onClose: () {}), live: false, stack: true);
      expect(find.text('Add in settings'), findsNWidgets(2));
      expect(k('emergency-owner'), findsOneWidget);
    });
  });

  group('Vehicle Info identity rows', () {
    testWidgets('head unit: rows without a source are hidden; Dashboard is the app version', (tester) async {
      await pump(tester, const VehicleInfoSection(), live: true);
      expect(find.text('Dashboard'), findsOneWidget);
      expect(find.text(appVersion), findsOneWidget);
      for (final label in ['MoveOS', 'Vehicle Software', 'Vehicle Data Protocol', 'Body Control Module', 'VIN', 'SIM Card (ICCID)']) {
        expect(find.text(label), findsNothing, reason: label);
      }
      await send(tester, {'_moveOs': '4.6.14', '_vdp': '2.3.1', '_hwInfo_6': 'MA3LRDE43P0001234'});
      expect(find.text('MoveOS'), findsOneWidget);
      expect(find.text('4.6.14'), findsOneWidget);
      expect(find.text('Vehicle Data Protocol'), findsOneWidget);
      expect(find.text('Vehicle Software'), findsNothing);
      expect(find.text('SIM Card (ICCID)'), findsNothing, reason: 'the ICCID is not readable on Android 10');
      expect(find.text('•••• 1234'), findsOneWidget);
      expect(find.text('MA3LRDE43P0001234'), findsNothing);
    });

    testWidgets('VIN and ICCID show the last four; a long press reveals, logs the field only, and re-masks', (tester) async {
      await pump(tester, const VehicleInfoSection(), live: false);
      final data = container.read(vehicleProvider);
      expect(find.text(MaskedValueRow.mask(data.vin)), findsOneWidget);
      expect(find.text(MaskedValueRow.mask(data.iccid)), findsOneWidget);
      expect(find.text(data.vin), findsNothing);

      await tester.longPress(k('masked-vin'));
      await tester.pump();
      expect(find.text(data.vin), findsOneWidget);
      expect(find.text(data.iccid), findsNothing, reason: 'each row reveals on its own');
      final reveal = AnalyticsLogger.instance.recent('ui', 'reveal').single;
      expect(reveal['data'], {'field': 'vin'});
      expect('$reveal'.contains(data.vin), isFalse);

      await tester.pump(MaskedValueRow.revealFor);
      await tester.pump();
      expect(find.text(data.vin), findsNothing);
      expect(find.text(MaskedValueRow.mask(data.vin)), findsOneWidget);

      await tester.ensureVisible(k('masked-iccid'));
      await tester.pump();
      await tester.longPress(k('masked-iccid'));
      await tester.pump();
      expect(find.text(data.iccid), findsOneWidget);
      await tester.ensureVisible(k('masked-iccid'));
      await tester.pump();
      await tester.longPress(k('masked-iccid'));
      await tester.pump();
      expect(find.text(data.iccid), findsNothing, reason: 'a second hold hides it again');
      expect(AnalyticsLogger.instance.recent('ui', 'reveal').length, 2);
    });

    test('mask keeps the last four', () {
      expect(MaskedValueRow.mask('MA3LRDE43P0001234'), '•••• 1234');
      expect(MaskedValueRow.mask('1234'), '1234');
      expect(MaskedValueRow.mask(''), '');
    });
  });

  group('status bar', () {
    testWidgets('head unit: signal bars follow the modem, no GPS icon', (tester) async {
      await pump(tester, const StatusBar(), live: true, stack: true);
      expect(find.byType(GpsIcon), findsNothing);
      expect(tester.widget<SignalIcon>(find.byType(SignalIcon)).bars, 0);
      await send(tester, {'_signal': 3});
      expect(tester.widget<SignalIcon>(find.byType(SignalIcon)).bars, 3);
    });

    testWidgets('mock keeps the GPS icon', (tester) async {
      await pump(tester, const StatusBar(), live: false, stack: true);
      expect(find.byType(GpsIcon), findsOneWidget);
    });
  });
}
