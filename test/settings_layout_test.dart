import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/settings/sections/riding_section.dart';
import 'package:opendash/screens/settings/widgets.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/theme/tokens.dart';
import 'package:opendash/widgets/panel/widget_panel.dart';

void main() {
  late ProviderContainer container;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);
  Finder k(String id) => find.byKey(ValueKey(id));

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenDashApp()));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    v().setLocked(false);
    await settle(tester);
  }

  Future<void> pumpWidget(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(home: Scaffold(body: SizedBox(width: 600, child: child))),
    ));
    await tester.pump();
  }

  double sizeOf(WidgetTester tester, Finder f) => tester.widget<Text>(f).style!.fontSize!;

  group('settings text sizes', () {
    testWidgets('headers, rows, captions and values grew by two', (tester) async {
      await pumpWidget(
        tester,
        Column(
          children: [
            const SectionHeader('Head'),
            ToggleRow(label: 'Toggle', caption: 'Caption', value: true, onChanged: (_) {}),
            KeyValueRow('Key', 'Value'),
            SliderRow(label: 'Slide', value: 5, display: '5 u', onChanged: (_) {}),
            ChipRow<int>(options: const [1, 2], value: 1, label: (i) => 'chip$i', onSelected: (_) {}),
            PrimaryButton('Go', onTap: () {}),
            TextButtonLink('Link', onTap: () {}),
          ],
        ),
      );
      expect(sizeOf(tester, find.text('HEAD')), 18);
      expect(sizeOf(tester, find.text('Toggle')), 20);
      expect(sizeOf(tester, find.text('Caption')), 16);
      expect(sizeOf(tester, find.text('Key')), 20);
      expect(sizeOf(tester, find.text('Value')), 20);
      expect(sizeOf(tester, find.text('Slide')), 20);
      expect(sizeOf(tester, find.text('5 u')), 20);
      expect(sizeOf(tester, find.text('chip1')), 18);
      expect(sizeOf(tester, find.text('Go')), 20);
      expect(sizeOf(tester, find.text('Link')), 20);
    });

    testWidgets('data card label and unit grew too', (tester) async {
      await pumpWidget(tester, const DataCard(label: 'Torque', value: 12, unit: 'Nm'));
      expect(sizeOf(tester, find.text('Torque')), 16);
      expect(sizeOf(tester, find.text('Nm')), 17);
    });
  });

  group('back arrow', () {
    testWidgets('is a 36px icon on a circle inside a 56px target', (tester) async {
      await pumpWidget(tester, BackArrow(key: const ValueKey('ba'), onTap: () {}));
      final size = tester.getSize(k('ba'));
      expect(size.width, greaterThanOrEqualTo(DashTouch.min));
      expect(size.height, greaterThanOrEqualTo(DashTouch.min));
      expect(tester.widget<Icon>(find.descendant(of: k('ba'), matching: find.byIcon(Icons.arrow_back_rounded))).size, 36);
      final circle = find.descendant(
        of: k('ba'),
        matching: find.byWidgetPredicate((w) => w is Container && (w.decoration as BoxDecoration?)?.shape == BoxShape.circle),
      );
      expect(circle, findsOneWidget);
    });

    testWidgets('the change passcode screen uses it', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      await tester.ensureVisible(k('section-passcode'));
      await tester.tap(k('section-passcode'));
      await settle(tester);
      expect(k('passcode-back'), findsNothing, reason: 'the toolbar arrow is the only one');
      expect(find.descendant(of: k('toolbar-back'), matching: find.byType(BackArrow), matchRoot: true), findsOneWidget);
      await tester.tap(k('toolbar-back'));
      await settle(tester);
      expect(container.read(changePasscodeOpenProvider), isFalse);
      expect(container.read(settingsScreenOpenProvider), isTrue, reason: 'back leaves the sub-screen, not settings');
    });
  });

  group('riding section groups', () {
    testWidgets('features sit under four headers in the spec order', (tester) async {
      await pumpApp(tester);
      container.read(settingsScreenOpenProvider.notifier).open();
      await settle(tester);
      await tester.tap(k('section-riding'));
      await settle(tester);
      expect(find.byType(RidingSection), findsOneWidget);
      final texts = find
          .descendant(of: find.byType(RidingSection), matching: find.byType(Text), skipOffstage: false)
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .whereType<String>()
          .toList();
      int at(String t) {
        final i = texts.indexOf(t);
        expect(i, greaterThanOrEqualTo(0), reason: '$t present');
        return i;
      }

      expect(at('Speed limit warning'), lessThan(at('BRAKING & STABILITY')));
      expect(at('BRAKING & STABILITY'), lessThan(at('Regenerative braking')));
      expect(at('Hill hold assist'), lessThan(at('SAFETY')));
      expect(at('SAFETY'), lessThan(at('Fall detection')));
      expect(at('Motor cut-off'), lessThan(at('LIGHTS')));
      // Side-stand sensor toggle is hidden (cmd 67 polarity unknown).
      expect(texts.contains('Side stand sensor'), isFalse);
      expect(at('LIGHTS'), lessThan(at('Smart headlight')));
      expect(at('Take-me-home lights'), lessThan(at('CONVENIENCE')));
      expect(at('CONVENIENCE'), lessThan(at('Proximity unlock')));
      expect(at('Proximity unlock'), lessThan(at('True Range')));
      // Tow/tamper detection carries its alarm sound chips; they stay with it.
      expect(at('Tow/tamper detection'), lessThan(at('Motor cut-off')));
      for (final f in RidingFeature.values) {
        // sideStandCutOff toggle is hidden (cmd 67 polarity unknown).
        if (f == RidingFeature.sideStandCutOff) {
          expect(find.byKey(ValueKey('riding-${f.name}'), skipOffstage: false), findsNothing, reason: f.name);
          continue;
        }
        expect(find.byKey(ValueKey('riding-${f.name}'), skipOffstage: false), findsOneWidget, reason: f.name);
      }
    });
  });
}
