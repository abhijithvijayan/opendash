import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/settings/widgets.dart';
import 'package:opendash/screens/settings/sections/riding_section.dart';
import 'package:opendash/screens/settings/sections/sound_section.dart';
import 'package:opendash/state/media_state.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/sound_settings.dart';

void main() {
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
    // The unlock raises the handlebar hint; let it expire before tapping.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(k('status-settings'));
    await settle(tester);
    expect(container.read(settingsScreenOpenProvider), isTrue);
  }

  testWidgets('gear hidden while riding; opens settings when parked; back closes', (tester) async {
    await pumpApp(tester);
    v().setSpeed(20);
    await tester.pump();
    expect(k('status-settings'), findsNothing);
    v().setSpeed(0);
    await tester.pump();
    await openSettings(tester);
    expect(find.text('Settings'), findsOneWidget);
    await tester.tap(k('toolbar-back'));
    await settle(tester);
    expect(container.read(settingsScreenOpenProvider), isFalse);
  });

  testWidgets('sidebar switches sections', (tester) async {
    await pumpApp(tester);
    await openSettings(tester);
    expect(find.text('Brightness'), findsOneWidget);
    await tester.tap(k('section-sound'));
    await settle(tester);
    expect(find.byType(SoundSection), findsOneWidget);
    expect(find.text('Brightness'), findsNothing);
    await tester.tap(k('preset-vintage'));
    await tester.pump();
    expect(container.read(soundSettingsProvider).preset, SoundPreset.vintage);
    await settle(tester);
    expect(find.text('Age'), findsOneWidget);
    await tester.tap(k('section-vehicleInfo'));
    await settle(tester);
    expect(find.text('MoveOS'), findsOneWidget);
    expect(find.text('•••• 2408'), findsOneWidget);
  });

  testWidgets('riding section: hill hold disclaimer then enable', (tester) async {
    await pumpApp(tester);
    await openSettings(tester);
    await tester.tap(k('section-riding'));
    await settle(tester);
    expect(find.byType(RidingSection), findsOneWidget);
    await tester.tap(find.descendant(of: k('riding-hillHold'), matching: find.text('Hill hold assist')), warnIfMissed: false);
    await settle(tester);
    expect(find.text('Hill Hold Assist'), findsNothing, reason: 'only the switch is the target, not the row');
    await tester.tap(find.descendant(of: k('riding-hillHold'), matching: find.byType(DashSwitch)), warnIfMissed: false);
    await settle(tester);
    expect(find.text('Hill Hold Assist'), findsOneWidget);
    await tester.tap(find.text('I understand'));
    await settle(tester);
    expect(container.read(ridingSettingsProvider).isOn(RidingFeature.hillHold), isTrue);
    expect(find.text('Hill Hold Assist'), findsNothing);
  });

  testWidgets('connectivity: manage devices opens the BT screen', (tester) async {
    await pumpApp(tester);
    await openSettings(tester);
    await tester.tap(k('section-connectivity'));
    await settle(tester);
    expect(find.text('HomeWifi_5G'), findsOneWidget);
    await tester.ensureVisible(k('manage-devices'));
    await settle(tester);
    await tester.tap(k('manage-devices'));
    await settle(tester);
    expect(container.read(btScreenOpenProvider), isTrue);
  });

  testWidgets('change passcode from the sidebar', (tester) async {
    await pumpApp(tester);
    await openSettings(tester);
    await tester.ensureVisible(k('section-passcode'));
      await tester.tap(k('section-passcode'));
    await settle(tester);
    expect(k('passcode-step-verify'), findsOneWidget);
    await tester.tap(k('toolbar-back'));
    await settle(tester);
    expect(container.read(changePasscodeOpenProvider), isFalse);
    expect(container.read(settingsScreenOpenProvider), isTrue);
  });

  testWidgets('trip reset icon, popup cancel and confirm', (tester) async {
    await pumpApp(tester);
    expect(k('trip-reset'), findsOneWidget);
    v().setSpeed(10);
    await tester.pump();
    expect(k('trip-reset'), findsNothing);
    v().setSpeed(0);
    await tester.pump();
    final before = container.read(vehicleProvider).tripMeter;
    await tester.tap(k('trip-reset'));
    await tester.pump();
    expect(find.text('Reset trip meter?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.text('Reset trip meter?'), findsNothing);
    expect(container.read(vehicleProvider).tripMeter, before);
    await tester.tap(k('trip-reset'));
    await tester.pump();
    await tester.tap(find.text('Reset'));
    await tester.pump();
    expect(container.read(vehicleProvider).tripMeter, 0);
    expect(find.text('Reset trip meter?'), findsNothing);
  });
}
