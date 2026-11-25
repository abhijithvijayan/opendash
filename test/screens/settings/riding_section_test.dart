import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/diagnostics/diagnostics_screen.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/settings_state.dart';

/// The mock with a way to feed it what HHMIS would report.
class _Vehicle extends VehicleNotifier {
  final features = <(RidingFeature, bool)>[];
  var vacationEntered = 0;

  void put(VehicleData Function(VehicleData v) change) => state = change(state);

  @override
  void setFeature(RidingFeature feature, bool on) => features.add((feature, on));

  @override
  void enterVacationMode() => vacationEntered++;
}

void main() {
  late ProviderContainer container;
  _Vehicle v() => container.read(vehicleProvider.notifier) as _Vehicle;
  Finder k(String id) => find.byKey(ValueKey(id), skipOffstage: false);

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [vehicleProvider.overrideWith(_Vehicle.new)],
      child: const OpenDashApp(),
    ));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    v().setLocked(false);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> openRiding(WidgetTester tester) async {
    await pumpApp(tester);
    container.read(settingsScreenOpenProvider.notifier).open();
    container.read(settingsSectionProvider.notifier).set(SettingsSection.riding);
    await settle(tester);
  }

  testWidgets('a feature the scooter reports as not available drops out; unknown ones stay', (tester) async {
    await openRiding(tester);
    for (final id in ['adaptivePowerBoost', 'tamper', 'motorCutOff', 'smartHeadlight', 'proximityUnlock', 'hillHold']) {
      expect(k('riding-$id'), findsOneWidget, reason: '$id before HHMIS has said anything');
    }
    // What a Gen 1 scooter on 4.6.14 reports.
    v().put((d) => d.copyWith(featureAvailable: const {
          'adaptivePowerBoost': false,
          'tamper': false,
          'motorCutOff': false,
          'smartHeadlight': false,
          'proximityUnlock': false,
          'hillHold': true,
          'fallDetection': true,
          'smartDrl': true,
          'takeMeHome': true,
        }));
    await settle(tester);
    for (final id in ['adaptivePowerBoost', 'tamper', 'motorCutOff', 'proximityUnlock']) {
      expect(k('riding-$id'), findsNothing, reason: id);
    }
    expect(k('riding-smartHeadlight'), findsOneWidget, reason: 'the VCU acts on it whatever the flag says');
    for (final id in ['hillHold', 'fallDetection', 'smartDrl', 'takeMeHome', 'autoHeadlight', 'vacationMode']) {
      expect(k('riding-$id'), findsOneWidget, reason: id);
    }
    expect(k('riding-sensitivity'), findsNothing, reason: 'rides with tow/tamper');
    expect(k('riding-alarmSound'), findsOneWidget);
    expect(k('riding-autoLock'), findsNothing, reason: 'hidden for the public beta');
    expect(k('riding-regenMode'), findsOneWidget);

    v().put((d) => d.copyWith(featureAvailable: {...d.featureAvailable, 'regen': false}));
    await settle(tester);
    expect(k('riding-regenMode'), findsNothing, reason: 'no regen tech pack: stock holds Default');
  });

  testWidgets('alarm sound is a two-way picker; sensitivity sits under tow/tamper', (tester) async {
    await openRiding(tester);
    expect(find.text('Alert 1', skipOffstage: false), findsOneWidget);
    expect(find.text('Alert 2', skipOffstage: false), findsOneWidget);
    expect(find.text('Silent', skipOffstage: false), findsNothing);
    expect(k('riding-sensitivity'), findsOneWidget);
    await tester.ensureVisible(find.text('Alert 2', skipOffstage: false));
    await settle(tester);
    await tester.tap(find.text('Alert 2'));
    await settle(tester);
    expect(container.read(ridingSettingsProvider).alarmSound, AlarmSound.alert2);
    await tester.pump(RidingSettingsNotifier.alarmPreview);
  });

  testWidgets('vacation mode asks first: cancel sends nothing, confirm enters', (tester) async {
    await openRiding(tester);
    final n = container.read(ridingSettingsProvider.notifier);
    n.setFeature(RidingFeature.vacationMode, true);
    await settle(tester);
    expect(k('vacation-prompt'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(k('vacation-prompt'), findsNothing);
    expect(v().vacationEntered, 0);
    expect(container.read(ridingSettingsProvider).isOn(RidingFeature.vacationMode), isFalse);

    n.setFeature(RidingFeature.vacationMode, true);
    await settle(tester);
    await tester.tap(find.text('Enter vacation mode'));
    await settle(tester);
    expect(k('vacation-prompt'), findsNothing);
    expect(v().vacationEntered, 1);
    expect(v().features, isEmpty, reason: 'the notifier runs the sequence, not the plain toggle');
    expect(container.read(ridingSettingsProvider).isOn(RidingFeature.vacationMode), isTrue);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('diagnostics: pack min / max on the battery tab, incline in live data', (tester) async {
    await pumpApp(tester);
    container.read(settingsScreenOpenProvider.notifier).open();
    container.read(diagnosticsOpenProvider.notifier).open();
    await settle(tester);
    Text valueOf(String id) => tester.widget<Text>(find.descendant(of: k(id), matching: find.byType(Text, skipOffstage: false)).last);
    expect(valueOf('diag-pack-min').data, '—');
    expect(valueOf('diag-pack-max').data, '—');
    v().put((d) => d.copyWith(batteryMinTemp: () => 27.5, batteryMaxTemp: () => 31.0, inclinationDegrees: () => -1));
    await settle(tester);
    expect(valueOf('diag-pack-min').data, '27.5 °C');
    expect(valueOf('diag-pack-max').data, '31.0 °C');

    container.read(diagTabProvider.notifier).set(DiagTab.liveData);
    await settle(tester);
    expect(k('diag-Incline'), findsOneWidget);
    expect(find.descendant(of: k('diag-Incline'), matching: find.text('-1', skipOffstage: false)), findsOneWidget);
  });

  testWidgets('the speed limit lands on a number: − and + move it by one, and a touch on the track moves nothing', (tester) async {
    await openRiding(tester);
    container.read(ridingSettingsProvider.notifier).setSpeedLimitEnabled(true);
    container.read(ridingSettingsProvider.notifier).setSpeedLimit(60);
    await settle(tester);
    await tester.ensureVisible(k('slider-plus-Speed limit'));
    await settle(tester);
    await tester.tap(k('slider-plus-Speed limit'));
    await settle(tester);
    expect(container.read(ridingSettingsProvider).speedLimit, 61);
    await tester.tap(k('slider-minus-Speed limit'));
    await settle(tester);
    await tester.tap(k('slider-minus-Speed limit'));
    await settle(tester);
    expect(container.read(ridingSettingsProvider).speedLimit, 59);

    final track = find.byWidgetPredicate((w) => w is Slider && w.max == 120);
    await tester.tapAt(tester.getTopRight(track) + const Offset(-40, 28));
    await settle(tester);
    expect(container.read(ridingSettingsProvider).speedLimit, 59,
        reason: 'one touch beside the + button took the limit from 58 to 105');
  });
}
