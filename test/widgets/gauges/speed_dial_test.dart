import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/widgets/gauges/speed_dial.dart';

void main() {
  Future<void> pump(WidgetTester tester, {required bool stale}) => tester.pumpWidget(
        MaterialApp(
          home: Center(child: SpeedDial(speed: 42, accent: Colors.green, stale: stale)),
        ),
      );

  testWidgets('a stale reading shows a dash, not a frozen number', (tester) async {
    await pump(tester, stale: false);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('42'), findsOneWidget);
    await pump(tester, stale: true);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('—'), findsOneWidget);
    expect(find.text('42'), findsNothing);
  });

  testWidgets('reverse keeps its letter while it moves, with the speed small underneath', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Center(child: SpeedDial(speed: 3, accent: Colors.green, mark: DialMark.reverse)),
    ));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('R'), findsOneWidget);
    expect(find.text('3 km/h'), findsOneWidget);
  });

  testWidgets('a stale reading shows the dash over any letter', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Center(child: SpeedDial(speed: 0, accent: Colors.green, stale: true, mark: DialMark.park)),
    ));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('—'), findsOneWidget);
    expect(find.text('P'), findsNothing);
  });
}
