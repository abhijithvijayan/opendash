import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/locked/keypad.dart';
import 'package:opendash/screens/settings/settings_screen.dart';
import 'package:opendash/screens/settings/widgets.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/theme/tokens.dart';
import 'package:opendash/widgets/controls/control_panel.dart';
import 'package:opendash/widgets/indicators/mode_ladder.dart';
import 'package:opendash/widgets/overlays/nav_bar.dart';

void main() {
  late ProviderContainer container;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);
  Finder k(String id) => find.byKey(ValueKey(id));

  Future<void> boot(WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenDashApp()));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await boot(tester);
    v().setLocked(false);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  void expectAtLeast(Size size, double min, String what) {
    expect(size.width, greaterThanOrEqualTo(min), reason: '$what width');
    expect(size.height, greaterThanOrEqualTo(min), reason: '$what height');
  }

  testWidgets('keypad keys are 112px, dots 24px, and the keypad stays inside the canvas', (tester) async {
    await boot(tester);
    expect(Keypad.keySize, greaterThanOrEqualTo(112));
    for (final d in ['1', '5', '0']) {
      final key = find.ancestor(of: find.text(d), matching: find.byType(AnimatedContainer)).first;
      expectAtLeast(tester.getSize(key), 112, 'key $d');
    }
    final delete = find.ancestor(of: find.byIcon(Icons.backspace_outlined), matching: find.byType(AnimatedContainer)).first;
    expectAtLeast(tester.getSize(delete), DashTouch.critical, 'delete');
    // getRect is in the test window's scaled frame; compare positions relatively.
    final keypad = tester.getRect(find.byType(Keypad));
    expect(keypad.bottom, lessThanOrEqualTo(tester.getRect(find.byType(OpenDashApp)).bottom));
    expectAtLeast(tester.getSize(k('lock-brightness')), DashTouch.min, 'lock brightness');
    expect(tester.getSize(find.byType(PinDots)).width, greaterThanOrEqualTo(6 * 24 + 5 * 36 - 1));
  });

  testWidgets('status bar tappable icons have 56px hit areas and the clock does not cover the strip', (tester) async {
    await pumpApp(tester);
    for (final id in ['status-apps', 'status-settings', 'status-wifi', 'status-bt', 'status-bell']) {
      expectAtLeast(tester.getSize(k(id)), DashTouch.min, id);
    }
    expect(tester.getSize(k('status-clock')).height, greaterThanOrEqualTo(DashTouch.min));
    expect(tester.getSize(k('status-clock')).width, lessThan(400), reason: 'the clock hit area stays around the text');
    expect(tester.getRect(k('status-apps')).overlaps(tester.getRect(k('status-settings'))), isFalse);
  });

  testWidgets('control panel buttons are 68px, 56px compact, and all fit the band', (tester) async {
    await pumpApp(tester);
    v().setLowBeam(true);
    await tester.tap(k('ctl-handle'));
    await settle(tester);
    final ids = ['hazard', 'beam', 'brightness', 'settings', 'restart'];
    final surface = tester.getRect(k('ctl-surface'));
    for (final id in ids) {
      expect(tester.widget<ControlButton>(k('ctl-$id')).size, greaterThanOrEqualTo(68), reason: id);
      final r = tester.getRect(k('ctl-$id'));
      expect(tester.getSize(k('ctl-$id')).width, greaterThanOrEqualTo(68), reason: '$id width');
      expect(r.top, greaterThanOrEqualTo(surface.top), reason: '$id inside the panel');
      expect(r.bottom, lessThanOrEqualTo(surface.bottom), reason: '$id inside the panel');
    }
    expect(tester.getRect(k('ctl-hazard')).overlaps(tester.getRect(k('ctl-beam'))), isFalse);
    expect(tester.getRect(k('ctl-hazard')).top, tester.getRect(k('ctl-beam')).top, reason: 'hazard and beam share a row');
    expect(tester.getSize(k('ctl-handle')).width, greaterThanOrEqualTo(DashTouch.min));

    v().setBrakeWorn(true);
    await settle(tester);
    expect(k('alert-banner'), findsOneWidget);
    for (final id in ids) {
      final size = tester.widget<ControlButton>(k('ctl-$id')).size;
      expect(size, greaterThanOrEqualTo(56), reason: '$id compact');
      expect(size, lessThan(68), reason: '$id drops to compact under a banner');
    }
    v().setBrakeWorn(false);
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mode ladder rows are 64px tall', (tester) async {
    await pumpApp(tester);
    v().setVehicleState(VehicleState.ready);
    await settle(tester);
    for (final label in ['HYPER', 'SPORT', 'NORMAL', 'ECO']) {
      final row = find.ancestor(
        of: find.descendant(of: find.byType(ModeLadder), matching: find.text(label)),
        matching: find.byType(SizedBox),
      ).first;
      expect(tester.getSize(row).height, greaterThanOrEqualTo(64), reason: label);
    }
  });

  testWidgets('settings rows, toggles, chips, sidebar tabs and buttons meet the 56px floor', (tester) async {
    await pumpApp(tester);
    container.read(settingsScreenOpenProvider.notifier).open();
    await settle(tester);
    expect(tester.getSize(k('toolbar-back')).height, greaterThanOrEqualTo(DashTouch.min));
    expect(tester.getSize(k('section-profile')).height, greaterThanOrEqualTo(52));
    await tester.tap(k('section-profile'));
    await settle(tester);
    expect(tester.getSize(find.byType(KeyValueRow).first).height, greaterThanOrEqualTo(DashTouch.min));
    expect(tester.getSize(k('profile-edit-registration')).height, greaterThanOrEqualTo(DashTouch.min));
    expect(tester.getSize(find.byType(PrimaryButton).first).height, greaterThanOrEqualTo(DashTouch.min));
    await tester.tap(k('section-connectivity'));
    await settle(tester);
    expect(tester.getSize(find.byType(ToggleRow).first).height, greaterThanOrEqualTo(DashTouch.min));
    await tester.tap(k('section-display'));
    await settle(tester);
    final chip = find.descendant(of: k('time-format'), matching: find.byType(AnimatedContainer)).first;
    expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nav close, trip reset and alert dismiss are easy to hit', (tester) async {
    await pumpApp(tester);
    expectAtLeast(tester.getSize(k('trip-reset')), DashTouch.min, 'trip reset');
    v().setNavActive(true);
    await settle(tester);
    expectAtLeast(tester.getSize(k('nav-close')), DashTouch.min, 'nav close');
    expect(find.byType(NavBar), findsOneWidget);
    v().setBrakeWorn(true);
    await settle(tester);
    expect(tester.getSize(k('alert-dismiss')).width, greaterThanOrEqualTo(72));
    expect(tester.widget<Icon>(find.descendant(of: k('alert-dismiss'), matching: find.byType(Icon))).size, 28);
  });

  testWidgets('emergency sheet rows and close button are tall enough', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Emergency'));
    await settle(tester);
    expect(tester.getSize(k('support-number')).height, greaterThanOrEqualTo(DashTouch.min));
    final close = find.ancestor(of: find.text('Close'), matching: find.byType(Container)).first;
    expect(tester.getSize(close).height, greaterThanOrEqualTo(60));
  });
}
