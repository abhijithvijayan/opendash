import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/safe_mode/safe_mode_screen.dart';
import 'package:opendash/services/trusted_clock.dart';

void main() {
  final firmwareBuilt = DateTime(2024, 3, 1);

  setUp(TrustedClock.resetForTest);
  tearDown(TrustedClock.resetForTest);

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const ProviderScope(
      child: Directionality(textDirection: TextDirection.ltr, child: SafeModeScreen()),
    ));
  }

  testWidgets('a clock still at the firmware build date shows --:--, not a time', (tester) async {
    TrustedClock.configure(firmwareBuildMs: firmwareBuilt.millisecondsSinceEpoch, elapsedRealtimeMs: 0);
    TrustedClock.wall = () => firmwareBuilt.add(const Duration(hours: 9, minutes: 41));
    await pump(tester);
    expect(find.text(VehicleNotifier.unknownClock), findsOneWidget);
    expect(find.textContaining('9:41'), findsNothing);
  });

  testWidgets('a believable clock shows the time, and the time once it becomes believable', (tester) async {
    TrustedClock.configure(firmwareBuildMs: firmwareBuilt.millisecondsSinceEpoch, elapsedRealtimeMs: 0);
    var now = firmwareBuilt.add(const Duration(hours: 9, minutes: 41));
    TrustedClock.wall = () => now;
    await pump(tester);
    expect(find.text(VehicleNotifier.unknownClock), findsOneWidget);
    now = DateTime(2026, 11, 24, 10, 24);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(VehicleNotifier.unknownClock), findsNothing);
    expect(find.textContaining('10:24'), findsOneWidget);
  });
}
