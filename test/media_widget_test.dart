import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/media_state.dart';
import 'package:opendash/widgets/indicators/telltale_strip.dart';
import 'package:opendash/widgets/media/now_playing_bar.dart';

void main() {
  late ProviderContainer container;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);

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

  Finder k(String id) => find.byKey(ValueKey(id));

  testWidgets('now playing bar needs BT and playing; controls drive the mock', (tester) async {
    await pumpApp(tester);
    expect(find.byType(NowPlayingBar), findsNothing);
    v().setMediaPlaying(true);
    await settle(tester);
    expect(find.byType(NowPlayingBar), findsOneWidget);
    expect(find.text('Nightcall'), findsWidgets);
    await tester.tap(k('np-next'));
    await tester.pump();
    expect(container.read(vehicleProvider).songTitle, 'Blinding Lights');
    await tester.tap(k('np-play'));
    await tester.pump();
    expect(container.read(vehicleProvider).mediaPlaying, isFalse);
    await settle(tester);
    expect(find.byType(NowPlayingBar), findsNothing);

    v().setMediaPlaying(true);
    v().setBtConnected(false);
    await settle(tester);
    expect(find.byType(NowPlayingBar), findsNothing, reason: 'BT gone hides the bar');
  });

  testWidgets('media controls remain while riding, volume does not', (tester) async {
    await pumpApp(tester);
    v().setMediaPlaying(true);
    v().setSpeed(30);
    await settle(tester);
    expect(k('np-play'), findsOneWidget);
    await tester.tap(k('np-next'));
    await tester.pump();
    expect(container.read(vehicleProvider).songTitle, 'Blinding Lights');
    await tester.tap(k('np-art'));
    await tester.pump();
    expect(container.read(volumeOverlayProvider), isFalse);
    v().setSpeed(0);
    await tester.pump();
    await tester.tap(k('np-art'));
    await tester.pump();
    expect(container.read(volumeOverlayProvider), isTrue);
    expect(find.text('50%'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(container.read(volumeOverlayProvider), isFalse);
  });

  testWidgets('incoming call: accept shows the call bar, reject clears', (tester) async {
    await pumpApp(tester);
    v().setSpeed(25);
    v().simulateIncomingCall();
    await settle(tester);
    expect(k('incoming-call'), findsOneWidget, reason: 'calls show while riding');
    expect(find.text('Rahul'), findsOneWidget);
    await tester.tap(k('call-accept'));
    await settle(tester);
    expect(k('incoming-call'), findsNothing);
    expect(k('active-call'), findsOneWidget);
    expect(find.descendant(of: k('active-call'), matching: find.text('00:00')), findsOneWidget);
    await tester.pump(const Duration(seconds: 65));
    await tester.pump();
    expect(find.descendant(of: k('active-call'), matching: find.text('01:05')), findsOneWidget);
    await tester.tap(k('call-mute'));
    await tester.pump();
    expect(container.read(vehicleProvider).callMuted, isTrue);
    await tester.tap(k('call-end'));
    await settle(tester);
    expect(k('active-call'), findsNothing);
    expect(container.read(vehicleProvider).callDuration, 0);

    v().setSpeed(0);
    v().simulateIncomingCall();
    await settle(tester);
    await tester.tap(k('call-reject'));
    await settle(tester);
    expect(k('incoming-call'), findsNothing);
    expect(k('active-call'), findsNothing);
  });

  testWidgets('call bar pushes the tell-tale strip down', (tester) async {
    await pumpApp(tester);
    AnimatedPositioned strip() => tester.widget<AnimatedPositioned>(
          find.ancestor(of: find.byType(TelltaleStrip), matching: find.byType(AnimatedPositioned)),
        );
    expect(strip().top, 72);
    v().setCallActive(true);
    await settle(tester);
    expect(strip().top, 128);
    v().endCall();
    await settle(tester);
    expect(strip().top, 72);
  });

  testWidgets('BT screen opens from the status bar, not while riding', (tester) async {
    await pumpApp(tester);
    v().setSpeed(20);
    await tester.pump();
    await tester.tap(k('status-bt'));
    await tester.pump();
    expect(container.read(btScreenOpenProvider), isFalse);
    v().setSpeed(0);
    await tester.pump();
    await tester.tap(k('status-bt'));
    await settle(tester);
    expect(container.read(btScreenOpenProvider), isTrue);
    expect(find.text('Paired phones'), findsOneWidget);
    expect(find.text('Galaxy S24'), findsOneWidget);
    v().setBtConnected(true);
    await settle(tester);
    expect(find.text('Disconnect'), findsOneWidget);
    await tester.tap(find.text('Disconnect'));
    await settle(tester);
    expect(container.read(vehicleProvider).btConnected, isFalse);
    expect(find.text('Bluetooth disconnected'), findsOneWidget);
    await tester.tap(k('toolbar-back'));
    await settle(tester);
    expect(container.read(btScreenOpenProvider), isFalse);
  });
}
