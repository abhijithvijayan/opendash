import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/widgets/indicators/trip_strip.dart';
import 'package:opendash/widgets/media/now_playing_bar.dart';
import 'helpers/stock.dart';

// Seen on a ride: a phone paired from the stock dashboard played music
// through the scooter, `_bt` never went true and the now-playing bar never
// showed.

List<Map<Object?, Object?>> _logged(String cat, String evt) =>
    [for (final e in AnalyticsLogger.instance.recent(cat, evt)) e['data']! as Map];

Map<String, Object?> _media({bool playing = true, String title = 'Song'}) => {
      '_media': {
        'connected': true,
        'playing': playing,
        'title': title,
        'artist': 'Artist',
        'durationMs': 200000,
        'positionMs': 0,
      },
    };

void main() {
  setUp(() => AnalyticsLogger.instance.resetForTest());

  AidlVehicleNotifier aidl() {
    final events = StreamController<dynamic>();
    addTearDown(events.close);
    return AidlVehicleNotifier(identity: stockIdentity(), events: events.stream, invoke: (_, _) async => true);
  }

  ProviderContainer containerFor(AidlVehicleNotifier n) {
    final c = ProviderContainer(overrides: [vehicleProvider.overrideWith(() => n)]);
    addTearDown(c.dispose);
    c.read(vehicleProvider);
    return c;
  }

  group('_bt with its source', () {
    test('bt_change carries the via SystemStatus sent just before', () {
      final n = aidl();
      final c = containerFor(n);
      n.onEvent({'_connected': true, '_bt': false});
      n.onEvent({'_btDevice': 'Pixel 8'});
      n.onEvent({'_btVia': 'acl'});
      n.onEvent({'_bt': true});
      expect(c.read(vehicleProvider).btConnected, isTrue);
      expect(c.read(vehicleProvider).btDeviceName, 'Pixel 8');
      n.onEvent({'_btDevice': ''});
      n.onEvent({'_btVia': 'acl_disconnected'});
      n.onEvent({'_bt': false});
      expect(c.read(vehicleProvider).btConnected, isFalse);
      expect(c.read(vehicleProvider).btDeviceName, '');
      expect(_logged('hhmis', 'bt_change').map((d) => '${d['from']}>${d['to']} ${d['via']}'), [
        'null>false null',
        'false>true acl',
        'true>false acl_disconnected',
      ]);
    });

    test('a replayed snapshot carries both keys in one batch', () {
      final n = aidl();
      final c = containerFor(n);
      n.onEvent({'_connected': true, '_bt': true, '_btVia': 'media', '_btDevice': 'Pixel 8', '_btBonded': ['Pixel 8', 'Work phone']});
      expect(c.read(vehicleProvider).btConnected, isTrue);
      expect(c.read(vehicleProvider).btBondedDevices, ['Pixel 8', 'Work phone']);
      expect(_logged('hhmis', 'bt_change').single, containsPair('via', 'media'));
      expect(_logged('hhmis', 'unknown_keys'), isEmpty);
    });

    test('a repeat of the same value logs nothing', () {
      final n = aidl();
      containerFor(n);
      n.onEvent({'_btVia': 'profile', '_bt': true});
      n.onEvent({'_btVia': 'acl', '_bt': true});
      expect(_logged('hhmis', 'bt_change'), hasLength(1));
    });
  });

  group('now playing does not depend on the Bluetooth flag', () {
    test('mediaVisible follows the session alone', () {
      expect(const VehicleData(mediaPlaying: true).mediaVisible, isTrue);
      expect(const VehicleData(btConnected: true).mediaVisible, isFalse);
    });

    test('a playing session shows with _bt still false, and goes when it stops', () {
      final n = aidl();
      final c = containerFor(n);
      n.onEvent({'_connected': true, '_bt': false});
      n.onEvent(_media());
      expect(c.read(vehicleProvider).btConnected, isFalse);
      expect(c.read(vehicleProvider).mediaVisible, isTrue);
      n.onEvent(_media(playing: false));
      expect(c.read(vehicleProvider).mediaVisible, isFalse);
      n.onEvent(_media());
      n.onEvent({
        '_media': {'connected': false},
      });
      expect(c.read(vehicleProvider).mediaVisible, isFalse);
      expect(c.read(vehicleProvider).songTitle, '');
    });

    testWidgets('the bar shows title and artist while riding with _bt false', (tester) async {
      tester.view.physicalSize = const Size(1280, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final n = aidl();
      await tester.pumpWidget(ProviderScope(
        overrides: [vehicleProvider.overrideWith(() => n)],
        child: const MaterialApp(
          home: Scaffold(body: Center(child: SizedBox(width: 1280, child: TripStrip()))),
        ),
      ));
      n.onEvent({'_connected': true, '_bt': false, 'INT_VEHICLE_SPEED': 42});
      await tester.pump();
      expect(find.byType(NowPlayingBar), findsNothing);
      n.onEvent(_media(title: 'Nightcall'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final c = ProviderScope.containerOf(tester.element(find.byType(TripStrip)));
      expect(c.read(vehicleProvider).speed, greaterThan(0));
      expect(find.byType(NowPlayingBar), findsOneWidget);
      expect(find.text('Nightcall'), findsOneWidget);
      expect(find.text('Artist'), findsOneWidget);
      expect(find.byKey(const ValueKey('np-play')), findsOneWidget);
      n.onEvent(_media(title: 'Nightcall', playing: false));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(NowPlayingBar), findsNothing);
    });
  });
}
