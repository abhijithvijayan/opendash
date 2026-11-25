import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:opendash/screens/settings/sections/sound_section.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool live}) async {
    tester.view.physicalSize = const Size(1280, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Material(child: SingleChildScrollView(child: SoundSection(live: live))),
      ),
    ));
    await tester.pump();
  }

  testWidgets('the mock shows every control', (tester) async {
    await pump(tester, live: false);
    expect(find.text('Motor Volume'), findsOneWidget);
    expect(find.text('Chime Volume'), findsOneWidget);
    expect(find.text('Sound Volume'), findsOneWidget);
    expect(find.text('System Sound'), findsOneWidget);
    expect(find.byKey(const ValueKey('param-bolt-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('sound-reset')), findsOneWidget);
    expect(find.byKey(const ValueKey('sound-mood-note')), findsNothing);
  });

  testWidgets('on the scooter only what HHMIS carries is shown', (tester) async {
    await pump(tester, live: true);
    expect(find.byKey(const ValueKey('preset-bolt')), findsOneWidget);
    expect(find.byKey(const ValueKey('preset-eclipse')), findsOneWidget);
    expect(find.text('Motor Volume'), findsOneWidget);
    expect(find.text('Chime Volume'), findsOneWidget);
    expect(find.byKey(const ValueKey('sound-mood-note')), findsOneWidget);
    expect(find.text('Sound Volume'), findsNothing);
    expect(find.text('System Sound'), findsNothing);
    expect(find.byKey(const ValueKey('param-bolt-0')), findsNothing);
    expect(find.byKey(const ValueKey('sound-reset')), findsNothing);
  });
}
