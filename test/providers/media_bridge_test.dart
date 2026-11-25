import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:opendash/models/app_catalog.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/media_bridge.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/screens/settings/sections/display_section.dart';
import 'package:opendash/services/analytics_heartbeat.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/services/platform_service.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:opendash/widgets/overlays/call_overlay.dart';
import 'package:opendash/state/auto_brightness.dart';
import '../helpers/stock.dart';

class _Harness {
  _Harness({this.callActionOk = true}) {
    container = ProviderContainer(overrides: [
      vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), 
            events: events.stream,
            invoke: (method, args) async {
              calls.add('$method $args');
              return method == 'callAction' ? callActionOk : true;
            },
          )),
    ]);
    container.listen(toastProvider, (_, _) {});
  }

  final bool callActionOk;
  final events = StreamController<dynamic>();
  final calls = <String>[];
  late final ProviderContainer container;

  AidlVehicleNotifier get notifier => container.read(vehicleProvider.notifier) as AidlVehicleNotifier;
  VehicleData get state => container.read(vehicleProvider);

  /// ClientCmds as `cmd=value`, in send order.
  List<String> ints(Set<String> cmds) => [
        for (final c in calls)
          if (RegExp(r'^sendIntCmd \{cmd: (\w+), value: (-?\d+)\}$').firstMatch(c) case final m?)
            if (cmds.contains(m[1]!)) '${m[1]}=${m[2]}',
      ];

  void dispose() {
    container.dispose();
    events.close();
  }
}

class _BrightnessSpy extends VehicleNotifier {
  final sent = <(int, bool)>[];

  @override
  void setBrightness(int level, {bool persist = true}) => sent.add((level, persist));
}

List<Map<Object?, Object?>> _logged(String cat, String evt) =>
    [for (final e in AnalyticsLogger.instance.recent(cat, evt)) e['data']! as Map];

Map<String, Object?> _media({bool playing = true, String title = 'Song', int durationMs = 200000, int positionMs = 0}) => {
      '_media': {
        'connected': true,
        'playing': playing,
        'title': title,
        'artist': 'Artist',
        'durationMs': durationMs,
        'positionMs': positionMs,
      },
    };

Map<String, Object?> _call(int state, {bool outgoing = false, bool inBand = false, int id = 1, String number = '+911234567890'}) => {
      '_call': {'state': state, 'number': number, 'outgoing': outgoing, 'inBand': inBand, 'id': id},
    };

void main() {
  setUp(() => AnalyticsLogger.instance.resetForTest());

  group('volume scale', () {
    test('percent and STREAM_MUSIC index convert both ways', () {
      expect(volumeIndexFor(0, 15), 0);
      expect(volumeIndexFor(100, 15), 15);
      expect(volumeIndexFor(50, 15), 8);
      expect(volumeIndexFor(140, 15), 15);
      expect(volumePercentFor(15, 15), 100);
      expect(volumePercentFor(10, 15), 67);
      expect(volumePercentFor(40, 15), 100, reason: 'an index above the scale is full volume, not 40 %');
      expect(volumePercentFor(3, 0), 0);
      for (var i = 0; i <= 15; i++) {
        expect(volumeIndexFor(volumePercentFor(i, 15), 15), i);
      }
    });

    test('HHMIS volume is an index: 10 of 15 shows as 67 %, not 10 %', () {
      final h = _Harness();
      h.notifier.onEvent({'_connected': true, '_volume': 10});
      expect(h.state.volume, 67);
      expect(_logged('hhmis', 'volume').single, containsPair('index', 10));
      h.dispose();
    });

    test('the slider sends the index, once per step, and keeps its own percent on the echo', () async {
      final h = _Harness();
      h.notifier.setVolume(50, announce: false);
      h.notifier.setVolume(51, announce: false);
      h.notifier.setVolume(52, announce: false);
      await Future<void>.delayed(Duration.zero);
      expect(h.calls, ['setVolume 8'], reason: '50-52 % are all step 8; HHMIS persists every call');
      h.notifier.onEvent({'_volume': 8});
      expect(h.state.volume, 52, reason: 'the echo of our own step does not snap the slider to 53');
      h.notifier.setVolume(100, announce: false);
      await Future<void>.delayed(Duration.zero);
      expect(h.calls.last, 'setVolume 15');
      h.notifier.onEvent({'_volume': 3});
      expect(h.state.volume, 20, reason: 'a change from elsewhere moves the slider');
      h.notifier.setVolume(100, announce: false);
      await Future<void>.delayed(Duration.zero);
      expect(h.calls.where((c) => c == 'setVolume 15'), hasLength(2), reason: 'the stream moved, so 15 is sent again');
      h.dispose();
    });

    test('a level from the handlebar buttons is shown; the first report and our own echo are not', () async {
      final h = _Harness();
      var shown = 0;
      h.notifier.onExternalVolume = () => shown++;
      h.notifier.onEvent({'_connected': true, '_volume': 10});
      await Future<void>.delayed(Duration.zero);
      expect(shown, 0, reason: 'the level at bind is not a change');
      h.notifier.setVolume(50, announce: false);
      h.notifier.onEvent({'_volume': 8});
      h.notifier.onEvent({'_volume': 8});
      await Future<void>.delayed(Duration.zero);
      expect(shown, 0, reason: 'the echo of the slider, reported twice as HHMIS does');
      h.notifier.onEvent({'_volume': 9});
      await Future<void>.delayed(Duration.zero);
      expect(shown, 1);
      expect(h.state.volume, 60);
      h.dispose();
    });

    test('the head unit reports its own step count; a volume already read is rescaled', () async {
      final h = _Harness();
      h.notifier.onEvent({'_volume': 10});
      expect(h.state.volume, 67);
      h.notifier.onEvent({'_volumeMax': 25});
      expect(h.state.volume, 40);
      expect(_logged('media', 'volume_max').single, containsPair('max', 25));
      h.notifier.setVolume(100, announce: false);
      await Future<void>.delayed(Duration.zero);
      expect(h.calls.last, 'setVolume 25');
      h.dispose();
    });

    test('the heartbeat carries volume, rpm and the regen limit', () {
      final snap = AnalyticsHeartbeat.snapshot(const VehicleData(volume: 67, rpm: 1200, regenPowerLimitW: 900));
      expect(snap, containsPair('volume', 67));
      expect(snap, containsPair('rpm', 1200));
      expect(snap, containsPair('regen_limit_w', 900));
    });
  });

  group('media', () {
    test('applyMediaUpdate maps the session and clears on disconnect', () {
      var v = applyMediaUpdate(const VehicleData(), _media(positionMs: 61500)['_media']! as Map);
      expect(v.mediaPlaying, isTrue);
      expect(v.songTitle, 'Song');
      expect(v.songArtist, 'Artist');
      expect(v.mediaDuration, 200);
      expect(v.mediaPosition, 61);
      expect(v.albumArt, '');
      v = applyMediaUpdate(v, {'connected': true, 'playing': true, 'title': 'Next', 'artist': 'Artist', 'durationMs': 0, 'positionMs': -1});
      expect(v.mediaPosition, 0, reason: 'a new track without a position starts at zero');
      expect(v.mediaDuration, 0);
      v = applyMediaUpdate(v.copyWith(mediaPosition: 9), {'connected': true, 'playing': false, 'title': 'Next', 'artist': 'Artist', 'positionMs': -1});
      expect(v.mediaPosition, 9, reason: 'same track, no position: keep counting from where we were');
      v = applyMediaUpdate(v, {'connected': false});
      expect(v.mediaPlaying, isFalse);
      expect(v.songTitle, '');
      expect(v.mediaDuration, 0);
    });

    test('the bar follows the phone and HHMIS hears INT_BT_MEDIA_PLAYING on each change', () async {
      final h = _Harness();
      h.notifier.onEvent({'_bt': true});
      expect(h.state.mediaVisible, isFalse);
      h.notifier.onEvent(_media());
      expect(h.state.mediaVisible, isTrue);
      expect(h.state.songTitle, 'Song');
      h.notifier.onEvent(_media(positionMs: 5000));
      h.notifier.onEvent(_media(playing: false, positionMs: 6000));
      expect(h.state.mediaPlaying, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(h.ints({HhmisCmd.btMediaPlaying}), ['INT_BT_MEDIA_PLAYING=1', 'INT_BT_MEDIA_PLAYING=0'], reason: 'a position update is not a change');
      final states = _logged('media', 'state');
      expect(states.map((d) => d['playing']), [true, false]);
      expect(states.toString(), isNot(contains('Song')), reason: 'titles stay out of the log');
      h.dispose();
    });

    test('a media batch is not HHMIS data', () {
      final h = _Harness();
      h.notifier.onEvent(_media());
      expect(h.state.hhmisConnected, isFalse);
      expect(AnalyticsLogger.instance.recent('hhmis', 'batch'), isEmpty);
      h.dispose();
    });

    test('play and pause never guess; the switch cube uses the real state once there is one', () async {
      final h = _Harness();
      h.notifier.mediaPlay();
      expect(h.state.mediaPlaying, isFalse);
      h.notifier.onEvent(_media());
      h.notifier.onEvent({'INT_BT_MUSIC_COMMAND': 0});
      h.notifier.onEvent(_media(playing: false));
      h.notifier.onEvent({'INT_BT_MUSIC_COMMAND': 0});
      h.notifier.onEvent({'_media': {'connected': false}});
      h.notifier.onEvent({'INT_BT_MUSIC_COMMAND': 0});
      await Future<void>.delayed(Duration.zero);
      expect(h.calls.where((c) => c.startsWith('mediaKey')), [
        'mediaKey play',
        'mediaKey pause',
        'mediaKey play',
        'mediaKey playPause',
      ]);
      h.dispose();
    });

    test('the position ticks to the end of the track and never sends "next"', () async {
      final h = _Harness();
      h.notifier.onEvent(_media(durationMs: 3000, positionMs: 1000));
      for (var i = 0; i < 5; i++) {
        h.notifier.tickMedia();
      }
      expect(h.state.mediaPosition, 3);
      await Future<void>.delayed(Duration.zero);
      expect(h.calls.where((c) => c.startsWith('mediaKey')), isEmpty);
      h.dispose();
    });

    test('merge folds the media stream in and swallows its errors', () async {
      final vehicle = StreamController<dynamic>();
      final media = StreamController<dynamic>();
      final seen = <dynamic>[];
      final errors = <Object>[];
      final sub = MediaBridge.merge(vehicle.stream, media.stream).listen(seen.add, onError: errors.add);
      vehicle.add({'INT_VEHICLE_SPEED': 3});
      media.add({'_volumeMax': 15});
      media.addError(StateError('no plugin'));
      vehicle.addError(StateError('hhmis'));
      await Future<void>.delayed(Duration.zero);
      expect(seen, [{'INT_VEHICLE_SPEED': 3}, {'_volumeMax': 15}]);
      expect(errors, hasLength(1), reason: 'only a vehicle-channel error means HHMIS went away');
      expect(_logged('media', 'channel_error'), hasLength(1));
      await sub.cancel();
      await vehicle.close();
      await media.close();
    });
  });

  group('calls', () {
    test('callUpdateFor: stock values for ClientCmd 14 and 61', () {
      CallUpdate? step(Map<String, Object?> e, CallPhase phase, [int? id]) =>
          callUpdateFor(e['_call']! as Map, phase: phase, currentId: id);

      final ring = step(_call(HfpCall.incoming), CallPhase.none)!;
      expect((ring.phase, ring.activeStatus, ring.callStatus), (CallPhase.ringing, 1, 1));
      expect(step(_call(HfpCall.incoming, inBand: true), CallPhase.none)!.activeStatus, 0,
          reason: 'the phone rings in-band: HHMIS must not add its chime');
      final answered = step(_call(HfpCall.active), CallPhase.ringing, 1)!;
      expect((answered.phase, answered.activeStatus, answered.callStatus), (CallPhase.active, 2, 3));
      final dial = step(_call(HfpCall.dialing, outgoing: true), CallPhase.none)!;
      expect((dial.phase, dial.activeStatus, dial.callStatus), (CallPhase.dialing, 4, 2));
      expect(step(_call(HfpCall.alerting, outgoing: true), CallPhase.dialing, 1), isNull, reason: 'still dialling');
      final picked = step(_call(HfpCall.active, outgoing: true), CallPhase.dialing, 1)!;
      expect((picked.phase, picked.activeStatus, picked.callStatus), (CallPhase.active, 5, 2));
      final over = step(_call(HfpCall.terminated), CallPhase.active, 1)!;
      expect((over.phase, over.activeStatus, over.callStatus), (CallPhase.none, 6, 4));

      expect(step(_call(HfpCall.terminated), CallPhase.none), isNull, reason: 'a call we never saw start');
      expect(step(_call(HfpCall.waiting, id: 2), CallPhase.active, 1), isNull, reason: 'a second call does not replace the first');
      expect(step(_call(HfpCall.terminated, id: 2), CallPhase.active, 1), isNull);
      expect(step(_call(1), CallPhase.active, 1), isNull, reason: 'hold changes nothing');
      expect(step(_call(HfpCall.terminated, id: HfpCall.linkLost), CallPhase.active, 1)!.phase, CallPhase.none,
          reason: 'losing the HFP link ends whatever call was up');
    });

    test('incoming call: ring, answer from the screen, hang up', () {
      fakeAsync((async) {
        final h = _Harness();
        h.notifier.onEvent(_call(HfpCall.incoming));
        expect(h.state.callIncoming, isTrue);
        expect(h.state.callerLabel, '+911234567890');
        h.notifier.acceptCall();
        async.flushMicrotasks();
        expect(h.calls, contains('callAction accept'));
        expect(h.state.callActive, isFalse, reason: 'the stack says when it is answered, not the tap');
        h.notifier.onEvent(_call(HfpCall.active));
        expect(h.state.callActive, isTrue);
        expect(h.state.callIncoming, isFalse);
        async.elapse(const Duration(seconds: 3));
        expect(h.state.callDuration, 3);
        h.notifier.endCall();
        async.flushMicrotasks();
        expect(h.calls, contains('callAction end'));
        expect(h.state.callActive, isTrue);
        h.notifier.onEvent(_call(HfpCall.terminated));
        expect(h.state.callActive, isFalse);
        async.elapse(const Duration(seconds: 3));
        expect(h.state.callDuration, 0, reason: 'the timer stopped');
        expect(h.ints({HhmisCmd.btCallActiveStatus, HhmisCmd.callStatus}), ['INT_BT_CALL_ACTIVE_STATUS=1', 'CALL_STATUS=1', 'INT_BT_CALL_ACTIVE_STATUS=2', 'CALL_STATUS=3', 'INT_BT_CALL_ACTIVE_STATUS=6', 'CALL_STATUS=4']);
        expect(_logged('call', 'state').map((d) => '${d['from']}>${d['to']}'), ['none>ringing', 'ringing>active', 'active>none']);
        expect(_logged('call', 'state').toString(), isNot(contains('1234567890')), reason: 'numbers stay out of the log');
        h.dispose();
      });
    });

    test('a ringing call the caller gives up on just goes away', () {
      fakeAsync((async) {
        final h = _Harness();
        h.notifier.onEvent(_call(HfpCall.incoming));
        h.notifier.onEvent(_call(HfpCall.terminated));
        async.flushMicrotasks();
        expect(h.state.callIncoming, isFalse);
        expect(h.state.callActive, isFalse);
        expect(h.container.read(toastProvider), isNull);
        expect(h.ints({HhmisCmd.btCallActiveStatus}), ['INT_BT_CALL_ACTIVE_STATUS=1', 'INT_BT_CALL_ACTIVE_STATUS=6']);
        h.dispose();
      });
    });

    test('outgoing call shows as a call in progress and reports 4 then 5', () {
      fakeAsync((async) {
        final h = _Harness();
        h.notifier.onEvent(_call(HfpCall.dialing, outgoing: true));
        expect(h.state.callActive, isTrue);
        expect(h.state.callIncoming, isFalse);
        h.notifier.onEvent(_call(HfpCall.alerting, outgoing: true));
        h.notifier.onEvent(_call(HfpCall.active, outgoing: true));
        h.notifier.onEvent(_call(HfpCall.terminated, outgoing: true));
        async.flushMicrotasks();
        expect(h.ints({HhmisCmd.btCallActiveStatus, HhmisCmd.callStatus}), ['INT_BT_CALL_ACTIVE_STATUS=4', 'CALL_STATUS=2', 'INT_BT_CALL_ACTIVE_STATUS=5', 'CALL_STATUS=2', 'INT_BT_CALL_ACTIVE_STATUS=6', 'CALL_STATUS=4']);
        h.dispose();
      });
    });

    test('BOOL_BT_CALL_HANDLE_REQUEST: the switch cube answers, declines and hangs up', () {
      fakeAsync((async) {
        final h = _Harness();
        h.notifier.onEvent({'BOOL_BT_CALL_HANDLE_REQUEST': true});
        async.flushMicrotasks();
        expect(h.calls.where((c) => c.startsWith('callAction')), isEmpty, reason: 'no call, nothing to answer');
        h.notifier.onEvent(_call(HfpCall.incoming));
        h.notifier.onEvent({'BOOL_BT_CALL_HANDLE_REQUEST': true});
        h.notifier.onEvent(_call(HfpCall.active));
        h.notifier.onEvent({'BOOL_BT_CALL_HANDLE_REQUEST': true});
        h.notifier.onEvent({'BOOL_BT_CALL_HANDLE_REQUEST': false});
        h.notifier.onEvent(_call(HfpCall.terminated));
        h.notifier.onEvent(_call(HfpCall.incoming, id: 2));
        h.notifier.onEvent({'BOOL_BT_CALL_HANDLE_REQUEST': false});
        async.flushMicrotasks();
        expect(h.calls.where((c) => c.startsWith('callAction')), ['callAction accept', 'callAction end', 'callAction reject']);
        expect(AnalyticsLogger.instance.recent('hhmis', 'unknown_keys'), isEmpty);
        expect(_logged('call', 'handle_request'), hasLength(5));
        h.dispose();
      });
    });

    test('an action the stack refuses leaves the call up and says so', () {
      fakeAsync((async) {
        final h = _Harness(callActionOk: false);
        h.notifier.onEvent(_call(HfpCall.incoming));
        h.notifier.rejectCall();
        async.flushMicrotasks();
        expect(h.state.callIncoming, isTrue);
        expect(h.container.read(toastProvider)?.message, "Couldn't reject the call");
        expect(_logged('call', 'action').single, containsPair('ok', false));
        h.dispose();
      });
    });

    testWidgets('the call bar has no mute button where nothing can mute', (tester) async {
      final events = StreamController<dynamic>();
      addTearDown(events.close);
      final aidl = AidlVehicleNotifier(identity: stockIdentity(), events: events.stream, invoke: (_, _) async => true);
      await tester.pumpWidget(ProviderScope(
        overrides: [vehicleProvider.overrideWith(() => aidl)],
        child: const MaterialApp(home: Scaffold(body: Stack(children: [ActiveCallBar()]))),
      ));
      aidl.onEvent(_call(HfpCall.dialing, outgoing: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('active-call')), findsOneWidget);
      expect(find.byKey(const ValueKey('call-end')), findsOneWidget);
      expect(find.byKey(const ValueKey('call-mute')), findsNothing);
    });

    testWidgets('the mock keeps its mute button', (tester) async {
      await tester.pumpWidget(const ProviderScope(
        child: MaterialApp(home: Scaffold(body: Stack(children: [ActiveCallBar()]))),
      ));
      final c = ProviderScope.containerOf(tester.element(find.byType(ActiveCallBar)));
      c.read(vehicleProvider.notifier).setCallActive(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('call-mute')), findsOneWidget);
      c.read(vehicleProvider.notifier).setCallActive(false);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('brightness persist flag', () {
    test('the bridge carries persist, and the log shows it', () async {
      final h = _Harness();
      h.notifier.setBrightness(40, persist: false);
      h.notifier.setBrightness(41);
      await Future<void>.delayed(Duration.zero);
      expect(h.calls, ['setBrightness {value: 40, persist: false}', 'setBrightness {value: 41, persist: true}']);
      expect(_logged('hhmis', 'cmd_send').map((d) => (d['value'], d['persist'])), [(40, false), (41, true)]);
      h.dispose();
    });

    test('auto brightness steps do not persist; a preset does', () {
      final spy = _BrightnessSpy();
      final c = ProviderContainer(overrides: [vehicleProvider.overrideWith(() => spy)]);
      addTearDown(c.dispose);
      c.read(brightnessProvider);
      c.read(autoBrightnessProvider);
      c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoBrightness, true);
      spy.sent.clear();
      spy.setAmbient(10);
      spy.setAmbient(90);
      expect(spy.sent, isNotEmpty);
      expect(spy.sent.every((s) => !s.$2), isTrue, reason: 'ambient steps are not the rider\'s choice');
      spy.sent.clear();
      c.read(brightnessProvider.notifier).cyclePreset();
      expect(spy.sent.single.$2, isFalse, reason: 'a boost over auto is for this outing only');
      c.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.autoBrightness, false);
      spy.sent.clear();
      c.read(brightnessProvider.notifier).cyclePreset();
      expect(spy.sent.single.$2, isTrue, reason: 'with auto off the preset is the rider\'s setting');
    });

    testWidgets('dragging the slider sends persist=false; letting go sends persist=true once', (tester) async {
      final spy = _BrightnessSpy();
      tester.view.physicalSize = const Size(1280, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [vehicleProvider.overrideWith(() => spy)],
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: SizedBox(width: 1000, child: DisplaySection()))),
        ),
      ));
      await tester.pump();
      final slider = find.byType(Slider).first;
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      expect(spy.sent, isNotEmpty);
      expect(spy.sent.every((s) => !s.$2), isTrue, reason: 'still dragging');
      await gesture.up();
      await tester.pump();
      expect(spy.sent.where((s) => s.$2), hasLength(1));
      expect(spy.sent.last.$2, isTrue);
      final c = ProviderScope.containerOf(tester.element(slider));
      expect(spy.sent.last.$1, c.read(brightnessProvider));
    });
  });

  group('platform.call', () {
    test('a boolean answer is logged as result, apart from success', () async {
      expect(await tracedPlatformCall('canDrawOverlays', () async => false, ok: (_) => true), isFalse);
      expect(await tracedPlatformCall('canDrawOverlays', () async => true, ok: (_) => true), isTrue);
      await tracedPlatformCall<String?>('fileSha256', () async => 'abc');
      final calls = _logged('platform', 'call');
      expect((calls[0]['success'], calls[0]['result']), (true, false), reason: 'the query worked; the answer was no');
      expect((calls[1]['success'], calls[1]['result']), (true, true));
      expect(calls[2].containsKey('result'), isFalse, reason: 'only booleans: paths and hashes stay out');
    });

    test('bringToFront is traced', () {
      fakeAsync((async) {
        final platform = MockPlatformService();
        final c = ProviderContainer(overrides: [platformServiceProvider.overrideWithValue(platform)]);
        for (final p in [sessionProvider, toastProvider, appManagerProvider, mockAppProvider]) {
          c.listen(p, (_, _) {});
        }
        final v = c.read(vehicleProvider.notifier);
        v.setConnected(true);
        v.setLocked(false);
        v.setVehicleState(VehicleState.riding);
        v.setSpeed(30);
        c.read(appManagerProvider.notifier).launch(appCatalog.firstWhere((a) => a.id == 'android-auto'));
        async.flushMicrotasks();
        v.setSideStand(true);
        async.flushMicrotasks();
        expect(platform.broughtToFront, 1);
        final trace = _logged('platform', 'call').where((d) => d['method'] == 'bringToFront').single;
        expect((trace['success'], trace['result']), (true, true));
        c.dispose();
      });
    });
  });
}
