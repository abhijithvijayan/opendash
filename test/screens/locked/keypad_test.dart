import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/screens/locked/keypad.dart';
import 'package:opendash/services/analytics_logger.dart';

void main() {
  setUp(AnalyticsLogger.instance.resetForTest);
  tearDown(AnalyticsLogger.instance.resetForTest);

  late List<int> digits;

  Future<void> pumpKeypad(WidgetTester tester) async {
    digits = [];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: Keypad(onDigit: digits.add, onDelete: () {}))),
    ));
  }

  Offset at(WidgetTester tester, String label) =>
      tester.getCenter(find.descendant(of: find.byType(Keypad), matching: find.text(label)));

  Future<void> tapAt(WidgetTester tester, String label, Duration t, {int pointer = 1}) async {
    final g = await tester.createGesture(pointer: pointer);
    await g.down(at(tester, label), timeStamp: t);
    await g.up(timeStamp: t + const Duration(milliseconds: 1));
    await tester.pump();
  }

  List<Map<Object?, Object?>> drops() =>
      [for (final e in AnalyticsLogger.instance.recent('ui', 'keypad_debounce_drop')) e['data']! as Map<Object?, Object?>];

  // Seen on a scooter: one press landed as two digits 1 ms apart.
  testWidgets('a second press 1 ms after the first is dropped and logged', (tester) async {
    await pumpKeypad(tester);
    await tapAt(tester, '1', const Duration(milliseconds: 100));
    await tapAt(tester, '2', const Duration(milliseconds: 101), pointer: 2);
    expect(digits, [1]);
    expect(drops(), [
      {'reason': 'debounce', 'gap_us': 1000},
    ]);
  });

  testWidgets('presses further apart than the debounce all count', (tester) async {
    await pumpKeypad(tester);
    await tapAt(tester, '1', const Duration(milliseconds: 100));
    await tapAt(tester, '1', const Duration(milliseconds: 160), pointer: 2);
    await tapAt(tester, '2', const Duration(milliseconds: 220), pointer: 3);
    expect(digits, [1, 1, 2]);
    expect(drops(), isEmpty);
  });

  testWidgets('a tap while another finger is down on a different key is dropped', (tester) async {
    await pumpKeypad(tester);
    final a = await tester.createGesture(pointer: 1);
    final b = await tester.createGesture(pointer: 2);
    await a.down(at(tester, '4'), timeStamp: const Duration(milliseconds: 100));
    await b.down(at(tester, '5'), timeStamp: const Duration(milliseconds: 300));
    await tester.pump();
    await a.up(timeStamp: const Duration(milliseconds: 400));
    await tester.pump();
    await b.up(timeStamp: const Duration(milliseconds: 450));
    await tester.pump();
    expect(digits, [5]);
    expect(drops(), [
      {'reason': 'multi_touch'},
    ]);
  });

  // From a rider: "I often had to press twice even after seeing
  // the button glow". A key lights on finger-down and enters on a
  // completed tap; these are the presses in between.
  group('a press that lit a key and entered nothing is logged', () {
    List<Map<Object?, Object?>> lost() =>
        [for (final e in AnalyticsLogger.instance.recent('ui', 'keypad_no_digit')) e['data']! as Map<Object?, Object?>];

    testWidgets('an ordinary tap enters its digit and logs nothing', (tester) async {
      await pumpKeypad(tester);
      await tapAt(tester, '7', const Duration(milliseconds: 100));
      await tester.pump();
      expect(digits, [7]);
      expect(lost(), isEmpty);
    });

    testWidgets('a finger that slides off: how it ended, how long, how far, never which key', (tester) async {
      await pumpKeypad(tester);
      final g = await tester.createGesture();
      await g.down(at(tester, '8'), timeStamp: const Duration(milliseconds: 100));
      await tester.pump();
      await g.moveBy(const Offset(0, 90), timeStamp: const Duration(milliseconds: 180));
      await g.up(timeStamp: const Duration(milliseconds: 260));
      await tester.pump();
      expect(digits, isEmpty);
      final e = lost().single;
      expect(e['key'], 'digit');
      expect(e['end'], 'up');
      expect(e['held_ms'], 160);
      expect(e['moved_px'], 90);
      expect(e.values.contains(8), isFalse);
      expect(e.containsKey('x'), isFalse);
    });

    // Seen in a log: three of fifteen presses on the gate, held 53 to 93 ms
    // and moved 13 to 37 px, lit the key and entered nothing.
    testWidgets('a quick press that slides a little still enters its digit', (tester) async {
      await pumpKeypad(tester);
      for (final (i, dx) in [13.0, 23.0, 37.0].indexed) {
        final g = await tester.createGesture(pointer: 10 + i);
        final t = Duration(milliseconds: 100 + i * 400);
        await g.down(at(tester, '6'), timeStamp: t);
        await g.moveBy(Offset(dx, 0), timeStamp: t + const Duration(milliseconds: 30));
        await g.up(timeStamp: t + const Duration(milliseconds: 70));
        await tester.pump();
      }
      expect(digits, [6, 6, 6]);
      expect(lost(), isEmpty);
    });

    testWidgets('a press the system takes away', (tester) async {
      await pumpKeypad(tester);
      final g = await tester.createGesture();
      await g.down(at(tester, '3'), timeStamp: const Duration(milliseconds: 100));
      await tester.pump();
      await g.cancel(timeStamp: const Duration(milliseconds: 150));
      await tester.pump();
      expect(digits, isEmpty);
      expect(lost().single['end'], 'cancel');
    });

    testWidgets('the keypad going away under a finger', (tester) async {
      await pumpKeypad(tester);
      final g = await tester.createGesture();
      await g.down(at(tester, '5'), timeStamp: const Duration(milliseconds: 100));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      expect(lost().single['end'], 'keypad_gone');
      await g.up();
    });

    testWidgets('a tap the debounce drops is not counted twice', (tester) async {
      await pumpKeypad(tester);
      await tapAt(tester, '1', const Duration(milliseconds: 100));
      await tapAt(tester, '2', const Duration(milliseconds: 101), pointer: 2);
      await tester.pump();
      expect(drops(), hasLength(1));
      expect(lost(), isEmpty);
    });
  });
}
