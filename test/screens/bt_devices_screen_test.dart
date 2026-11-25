import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/bluetooth/bt_devices_screen.dart';
import 'package:opendash/screens/settings/widgets.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/bt_bridge.dart';
import 'package:opendash/state/bt_settings.dart';
import 'package:opendash/state/media_state.dart';
import 'package:opendash/theme/colors.dart';
import 'package:opendash/theme/dash_theme.dart';

class _BtOpen extends BtScreenOpen {
  @override
  bool build() => true;
}

/// A bridge that never binds HSSS and reports two paired phones.
class _DeadBridge extends BtBridge {
  final controller = StreamController<dynamic>(sync: true);
  final calls = <String>[];

  @override
  Stream<dynamic> events() => controller.stream;

  @override
  Future<Object?> invoke(String method, [Object? args]) async {
    calls.add(method);
    return true;
  }
}

void main() {
  late ProviderContainer container;
  Finder k(String id) => find.byKey(ValueKey(id));
  Finder sw(String id) => find.descendant(of: k(id), matching: find.byType(DashSwitch));

  setUp(() => AnalyticsLogger.instance.resetForTest());
  tearDown(() {
    DashColors.current = DashTheme.dark;
  });

  Future<void> pump(WidgetTester tester, {List<Object> overrides = const []}) async {
    tester.view.physicalSize = const Size(1280, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [btScreenOpenProvider.overrideWith(_BtOpen.new), ...overrides.cast()],
      child: const Directionality(textDirection: TextDirection.ltr, child: Stack(children: [BtDevicesScreen()])),
    ));
    container = ProviderScope.containerOf(tester.element(find.byType(BtDevicesScreen)));
    container.read(vehicleProvider.notifier).setLocked(false);
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('mock: power, visibility, the paired phones and the calls toggle', (tester) async {
    await pump(tester);
    expect(k('bt-readonly'), findsNothing);
    expect(find.textContaining('Visible as'), findsOneWidget);
    expect(find.text('Paired phones'), findsOneWidget);
    expect(find.text(VehicleNotifier.mockDeviceName), findsOneWidget);
    expect(find.text('Connect'), findsNWidgets(2));
    expect(find.text('Forget'), findsNWidgets(2));
    expect(find.text('Phone calls on the dashboard'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'fits the 1280x768 canvas');
  });

  testWidgets('Connect, then Disconnect, each one tap and one log line', (tester) async {
    await pump(tester);
    final phone = container.read(btSettingsProvider).phones.first;
    await tester.tap(k('bt-connect-${phone.address}'));
    await settle(tester);
    expect(container.read(vehicleProvider).btConnected, isTrue);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(AnalyticsLogger.instance.recent('ui', 'tap').last['data'], containsPair('target', 'bt-connect'));
    await tester.tap(k('bt-connect-${phone.address}'));
    await settle(tester);
    expect(container.read(vehicleProvider).btConnected, isFalse);
    expect(AnalyticsLogger.instance.recent('ui', 'tap').last['data'], containsPair('target', 'bt-disconnect'));
    expect(AnalyticsLogger.instance.recent('bt', 'connect'), hasLength(2));
  });

  testWidgets('Forget sits behind a confirmation', (tester) async {
    await pump(tester);
    final phone = container.read(btSettingsProvider).phones.first;
    await tester.tap(k('bt-forget-${phone.address}'));
    await settle(tester);
    expect(k('bt-forget-confirm'), findsOneWidget);
    expect(container.read(btSettingsProvider).phones, hasLength(2));
    await tester.tap(find.descendant(of: k('bt-forget-confirm'), matching: find.text('Cancel')));
    await settle(tester);
    expect(k('bt-forget-confirm'), findsNothing);
    expect(container.read(btSettingsProvider).phones, hasLength(2));

    await tester.tap(k('bt-forget-${phone.address}'));
    await settle(tester);
    await tester.tap(find.descendant(of: k('bt-forget-confirm'), matching: find.byType(PrimaryButton)));
    await settle(tester);
    expect(container.read(btSettingsProvider).phones, hasLength(1));
    expect(k('bt-phone-${phone.address}'), findsNothing);
    expect(AnalyticsLogger.instance.recent('bt', 'forget').single['data'], containsPair('ok', true));
  });

  testWidgets('the power toggle switches Bluetooth off: no phone actions, not visible', (tester) async {
    await pump(tester);
    await tester.tap(sw('bt-power'), warnIfMissed: false);
    await settle(tester);
    expect(container.read(btSettingsProvider).on, isFalse);
    expect(find.text('Phones cannot connect'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
    expect(AnalyticsLogger.instance.recent('bt', 'toggle').single['data'], containsPair('on', false));
  });

  testWidgets('calls: stock\'s consent text first, Cancel leaves it off, Continue switches it on', (tester) async {
    await pump(tester);
    await tester.tap(sw('bt-calls'), warnIfMissed: false);
    await settle(tester);
    expect(k('bt-consent'), findsOneWidget);
    expect(find.text(phoneCallsConsentText), findsOneWidget);
    await tester.tap(find.descendant(of: k('bt-consent'), matching: find.text('Cancel')));
    await settle(tester);
    expect(container.read(btSettingsProvider).callsAllowed, isFalse);

    await tester.tap(sw('bt-calls'), warnIfMissed: false);
    await settle(tester);
    await tester.tap(find.descendant(of: k('bt-consent'), matching: find.byType(PrimaryButton)));
    await settle(tester);
    expect(container.read(btSettingsProvider).callsAllowed, isTrue);
    expect(k('bt-consent'), findsNothing);
    expect(AnalyticsLogger.instance.recent('call', 'allowed').single['data'], containsPair('trigger', 'consent'));
  });

  testWidgets('a binder that never answers: the screen is read-only and says so', (tester) async {
    final bridge = _DeadBridge();
    await pump(tester, overrides: [
      btBridgeProvider.overrideWithValue(bridge),
      btSettingsProvider.overrideWith(HsssBtSettingsNotifier.new),
    ]);
    bridge.controller.add({'hsss': false});
    bridge.controller.add({
      'state': {
        'enabled': true,
        'scanMode': 23,
        'name': 'bluebird',
        'devices': [
          {'address': 'AA:BB:CC:DD:EE:01', 'name': 'Pixel 8', 'connected': true},
          {'address': 'AA:BB:CC:DD:EE:02', 'name': 'Work phone', 'connected': false},
        ],
      },
    });
    await settle(tester);
    expect(find.text('${HsssBtSettingsNotifier.notBound}.'), findsOneWidget);
    expect(find.text('Visible as bluebird'), findsOneWidget);
    expect(find.text('Pixel 8'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
    expect(find.text('Disconnect'), findsNothing);
    expect(find.text('Forget'), findsNothing);
    await tester.tap(sw('bt-power'), warnIfMissed: false);
    await tester.tap(sw('bt-calls'), warnIfMissed: false);
    await settle(tester);
    expect(bridge.calls, isEmpty);
    expect(container.read(btSettingsProvider).on, isTrue);
  });

  testWidgets('lays out in the Light theme too', (tester) async {
    DashColors.current = DashTheme.light;
    await pump(tester);
    container.read(btSettingsProvider.notifier).askForget(container.read(btSettingsProvider).phones.first.address);
    await settle(tester);
    expect(k('bt-forget-confirm'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final ink = tester.widget<ColoredBox>(k('bt-body')).color;
    expect(ink, DashTheme.light.ink);
  });
}
