import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/dev/island_preview.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/services/trusted_clock.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/state/access_state.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/settings_state.dart';

import 'director.dart';
import 'fonts.dart';
import 'frame.dart';
import 'reel_timeline.dart';
import 'timeline.dart';

const frameStep = Duration(microseconds: 1000000 ~/ 60);

/// Every frame, for the encoder. Without it: three stills per scene.
const full = bool.fromEnvironment('OPENDASH_VIDEO_FULL');
/// The vertical cut for Shorts and Reels instead of the landscape video.
const reel = bool.fromEnvironment('OPENDASH_VIDEO_REEL');
const out = reel ? 'build/launch_video/reel' : 'build/launch_video';
final scenes = reel ? reelTimeline : timeline;

/// OpenDash Companion's filmed install (its tool/promo/render_test.dart).
const companionFilm = String.fromEnvironment('OPENDASH_COMPANION_FILM', defaultValue: '../opendash-companion/build/promo');

void main() {
  testWidgets('render the launch video', timeout: Timeout.none, (tester) async {
    expect(const bool.fromEnvironment('OPENDASH_NO_DEV_PANEL'), isTrue, reason: 'run through build.sh');
    await loadVideoFonts();
    tester.view.physicalSize = reel ? reelSize : videoSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final start = DateTime(2026, 11, 24, 10, 24);
    var filmed = 0;
    TrustedClock.wall = () => start.add(frameStep * filmed);
    addTearDown(TrustedClock.resetForTest);
    AccessNotifier.debugAskAfterUnlock = false;
    addTearDown(() => AccessNotifier.debugAskAfterUnlock = true);

    // The test binding reports Android, which would pick the real channel.
    final platform = MockPlatformService();
    for (final a in Access.values) {
      platform.grant(a.name);
    }
    final key = GlobalKey();
    final lengths = sceneFrames(scenes);
    final state = ValueNotifier(FrameState(scenes.first, 0, lengths.first));
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: _frame(
        state,
        ProviderScope(
          overrides: [platformServiceProvider.overrideWithValue(platform)],
          child: const Stack(
            fit: StackFit.expand,
            children: [
              OpenDashApp(),
              // The app mounts this only beside the dev panel.
              Directionality(textDirection: TextDirection.ltr, child: IslandPreview(label: false)),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    final d = Director(tester, container);
    await tester.pump(const Duration(seconds: 2));
    await d.settle();
    container.read(autoDarkModeProvider.notifier).setEnabled(false);
    container.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.predictedRange, true);
    await tester.runAsync(container.read(accessProvider.notifier).refresh);
    d.vehicle.setLocked(false);
    await d.settle();
    d.vehicle.setVehicleState(VehicleState.ready);
    // Past the greeting.
    await d.settle(6000);

    final dir = Directory(full ? '$out/frames' : '$out/stills');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    final film = Directory('$companionFilm/frames');
    final filmFrames = film.existsSync() ? (film.listSync().whereType<File>().map((f) => f.path).toList()..sort()) : <String>[];
    final taps = filmFrames.isEmpty
        ? const <Map<String, Object?>>[]
        : (jsonDecode(File('$companionFilm/taps.json').readAsStringSync())['taps'] as List).cast<Map<String, Object?>>();
    if (scenes.any((s) => s.kind == SceneKind.phone)) {
      expect(filmFrames, isNotEmpty, reason: 'film the install first: flutter test tool/promo/render_test.dart in opendash-companion');
    }
    ui.Image? shown;
    for (var i = 0; i < scenes.length; i++) {
      final scene = scenes[i];
      final frames = lengths[i];
      await scene.enter?.call(d);
      for (var f = 0; f < frames; f++) {
        await scene.tick?.call(d, f / 60);
        if (scene.kind == SceneKind.phone) {
          final at = math.min((f * scene.phoneSpeed).floor(), filmFrames.length - 1);
          final bytes = File(filmFrames[at]).readAsBytesSync();
          final image = await tester.runAsync(() async => (await (await ui.instantiateImageCodec(bytes)).getNextFrame()).image);
          Offset? tap;
          var age = 0.0;
          for (final t in taps) {
            final tf = (t['frame']! as num).toInt();
            if (tf <= at && at - tf < 30) {
              tap = Offset((t['x']! as num).toDouble(), (t['y']! as num).toDouble());
              age = (at - tf) / 30;
            }
          }
          final old = shown;
          shown = image;
          state.value = FrameState(scene, f, frames, phone: image, tap: tap, tapAge: age);
          await tester.pump(frameStep);
          old?.dispose();
        } else {
          state.value = FrameState(scene, f, frames);
          await tester.pump(frameStep);
        }
        if (full) {
          await captureFrame(tester, key, File('${dir.path}/${filmed.toString().padLeft(5, '0')}.png'));
        } else if (f == 0 || f == frames ~/ 2 || f == frames - 1) {
          final at = f == 0 ? 'a' : f == frames - 1 ? 'c' : 'b';
          await captureFrame(tester, key, File('${dir.path}/${(i + 1).toString().padLeft(2, '0')}-${scene.id}-$at.png'));
        }
        filmed++;
      }
    }
    expect(filmed, totalFrames(scenes));
    // ignore: avoid_print
    print('filmed $filmed frames, ${(filmed / 60).toStringAsFixed(1)} s');
  });
}

Widget _frame(ValueNotifier<FrameState> state, Widget dash) =>
    reel ? ReelFrame(state: state, dash: dash) : VideoFrame(state: state, dash: dash);
