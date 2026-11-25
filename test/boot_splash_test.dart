import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/constants.dart';
import 'package:opendash/main.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/boot/boot_screen.dart';
import 'package:opendash/state/qr_card.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/widgets/status_bar/status_bar.dart';

void main() {
  late ProviderContainer container;
  Finder k(String id) => find.byKey(ValueKey(id));

  Future<void> pumpBoot(WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenDashApp()));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    // Hold the handshake so the splash stays up.
    container.read(vehicleProvider.notifier).dropConnection();
  }

  BootLinePainter line(WidgetTester tester) => tester.widget<CustomPaint>(k('boot-line')).painter as BootLinePainter;
  double wordmarkOpacity(WidgetTester tester) =>
      tester.widget<Opacity>(find.ancestor(of: find.text(appName), matching: find.byType(Opacity)).first).opacity;

  testWidgets('a hairline draws out from the centre over the first 400ms, no arc, no status bar', (tester) async {
    await pumpBoot(tester);
    expect(find.byType(BootScreen), findsOneWidget);
    expect(k('boot-arc'), findsNothing);
    expect(find.byType(StatusBar), findsNothing);
    expect(line(tester).extent, lessThan(0.05));
    await tester.pump(const Duration(milliseconds: 200));
    final mid = line(tester).extent;
    expect(mid, greaterThan(0.1));
    expect(mid, lessThan(1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(line(tester).extent, closeTo(1, 0.01));
    expect(BootScreen.lineWidth, 400);
    expect(tester.getSize(k('boot-line')).width, 400);
  });

  testWidgets('the wordmark fades in after the line, larger than before, with the version under it', (tester) async {
    await pumpBoot(tester);
    await tester.pump(const Duration(milliseconds: 200));
    expect(wordmarkOpacity(tester), 0);
    await tester.pump(const Duration(milliseconds: 400));
    final mid = wordmarkOpacity(tester);
    expect(mid, greaterThan(0));
    expect(mid, lessThan(1));
    await tester.pump(const Duration(milliseconds: 500));
    expect(wordmarkOpacity(tester), 1);
    expect(tester.widget<Text>(find.text(appName)).style!.fontSize, 48);
    expect(find.descendant(of: k('boot-version'), matching: find.text('v$appVersion'), matchRoot: true), findsOneWidget);
    final word = tester.getRect(find.text(appName));
    final rule = tester.getRect(k('boot-line'));
    final connecting = tester.getRect(k('boot-connecting'));
    expect(word.bottom, lessThan(rule.top), reason: 'wordmark above the line');
    expect(connecting.top, greaterThan(rule.bottom), reason: 'connecting below the line');
    final canvas = tester.getRect(find.byType(BootScreen));
    expect((word.center.dx - canvas.center.dx).abs(), lessThan(1), reason: 'centred');
  });

  testWidgets('a bar keeps running along the track, and "Connecting" stays as it is', (tester) async {
    await pumpBoot(tester);
    await tester.pump(const Duration(milliseconds: 1000));
    String word() => tester.widget<Text>(k('boot-connecting')).data!;
    expect(word(), 'Connecting…');
    final seen = <({double from, double to})>[];
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 300));
      seen.add(line(tester).bar);
      expect(seen.last.to, greaterThanOrEqualTo(seen.last.from));
      expect(word(), 'Connecting…', reason: 'no dots counting after it');
    }
    expect(seen.map((b) => b.to).toSet().length, greaterThan(4), reason: 'it moves');
    expect(seen.where((b) => b.from < 0.1).length, greaterThan(1), reason: 'and sets off again: it has no end');
  });

  testWidgets('connection flashes the line as the splash hands over', (tester) async {
    await pumpBoot(tester);
    await tester.pump(const Duration(milliseconds: 1000));
    expect(line(tester).flash, 0);
    container.read(vehicleProvider.notifier).setConnected(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(container.read(screenStateProvider), isNot(ScreenState.booting));
    expect(line(tester).flash, greaterThan(0), reason: 'flash runs through the crossfade');
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(BootScreen), findsNothing);
  });

  testWidgets('timeout escalation still follows the line', (tester) async {
    await pumpBoot(tester);
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(k('boot-slow'), findsOneWidget);
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(k('boot-options'), findsOneWidget);
    expect(k('boot-companion'), findsOneWidget, reason: 'the way to update when the dashboard cannot');
    await tester.tap(k('boot-companion'));
    await tester.pump();
    expect(container.read(qrCardProvider)?.id, 'companion');
    expect(k('boot-slow'), findsNothing, reason: 'the options replace the slow note');
    final rule = tester.getRect(k('boot-line'));
    expect(tester.getRect(k('boot-stock')).top, greaterThan(rule.bottom));
    // No way on without the scooter: the screen stays, counting,
    // until the service answers.
    expect(k('boot-continue'), findsNothing);
    expect(k('boot-trunk'), findsNothing);
    expect(find.text('Still trying to connect · 0:30'), findsOneWidget);
    expect(find.text('Connecting…'), findsNothing, reason: 'said once, with the count');
    await tester.pump(const Duration(seconds: 15));
    expect(find.text('Still trying to connect · 0:45'), findsOneWidget);
    expect(k('boot-report'), findsOneWidget);
    expect(find.byType(BootScreen), findsOneWidget);
  });
}
