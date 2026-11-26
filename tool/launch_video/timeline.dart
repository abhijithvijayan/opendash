import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart' show Offset;

import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/screens/diagnostics/diagnostics_screen.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/control_panel.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/dash_island.dart';
import 'package:opendash/state/widget_panel_state.dart';
import 'package:opendash/state/theme_state.dart';
import 'package:opendash/theme/dash_theme.dart';

import 'director.dart';

enum SceneKind { titleCard, claims, dashWithCaption, endCard, phone }

class Scene {
  const Scene(
    this.id,
    this.seconds, {
    this.kind = SceneKind.dashWithCaption,
    this.title = '',
    this.subtitle,
    this.footnote,
    this.kicker,
    this.titleSize = 150,
    this.words = const [],
    this.wordAt = const [],
    this.dashOpacity = 1,
    this.fadeFromBlack = false,
    this.fadeToBlack = false,
    this.enter,
    this.tick,
    this.zoom = 1,
    this.focus = const Offset(640, 384),
    this.phoneSpeed = 1,
  });

  final String id;
  final double seconds;
  final SceneKind kind;
  final String title;
  final String? subtitle;

  /// A small third line under the caption.
  final String? footnote;
  final String? kicker;
  final double titleSize;
  final List<String> words;

  /// Seconds into the scene at which each of [words] lands.
  final List<double> wordAt;
  final double dashOpacity;
  final bool fadeFromBlack;
  final bool fadeToBlack;

  /// Runs before the scene's first frame; nothing it pumps is filmed.
  final Future<void> Function(Director d)? enter;

  /// Once per frame, [t] seconds into the scene.
  final FutureOr<void> Function(Director d, double t)? tick;

  /// The reel's crop: how much larger than full width the dash is drawn,
  /// and which point of the 1280x768 dash sits in the middle.
  final double zoom;
  final Offset focus;

  /// A phone scene plays OpenDash Companion's filmed install this many times faster.
  final double phoneSpeed;

  /// The same footage at another length: its motion runs faster or slower to fit.
  Scene recut(
    double seconds, {
    SceneKind? kind,
    String? title,
    String? subtitle,
    String? footnote,
    String? kicker,
    double? zoom,
    Offset? focus,
    double? dashOpacity,
    bool? fadeFromBlack,
    List<double>? wordAt,
    double? phoneSpeed,
  }) {
    final warp = this.seconds / seconds;
    final t = tick;
    return Scene(
      id,
      seconds,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      footnote: footnote,
      kicker: kicker ?? this.kicker,
      titleSize: titleSize,
      words: words,
      wordAt: wordAt ?? [for (final w in this.wordAt) w / warp],
      dashOpacity: dashOpacity ?? this.dashOpacity,
      fadeFromBlack: fadeFromBlack ?? this.fadeFromBlack,
      fadeToBlack: fadeToBlack,
      enter: enter,
      tick: t == null ? null : (d, s) => t(d, s * warp),
      zoom: zoom ?? this.zoom,
      focus: focus ?? this.focus,
      phoneSpeed: phoneSpeed ?? this.phoneSpeed,
    );
  }
}

Scene sceneById(String id) => timeline.firstWhere((s) => s.id == id);

/// One beat of the music (93.96 bpm, from beats.py). Every scene is a whole
/// number of beats long, so every cut lands on one.
const beat = 60 / 93.96;

/// Frames per scene, rounded on the running total so the cuts do not drift
/// off the beat.
List<int> sceneFrames(List<Scene> scenes) {
  final frames = <int>[];
  var end = 0.0, filmed = 0;
  for (final s in scenes) {
    end += s.seconds;
    frames.add((end * 60).round() - filmed);
    filmed += frames.last;
  }
  return frames;
}

int totalFrames(List<Scene> scenes) => sceneFrames(scenes).fold(0, (n, f) => n + f);

double _ease(double x) => x <= 0 ? 0 : x >= 1 ? 1 : x * x * (3 - 2 * x);

/// A ride that never holds still: a base speed with a slow swell on it.
double _cruising(double t, double base, [double swell = 4]) => base + swell * math.sin(t * 1.3) + 1.5 * math.sin(t * 3.1);

const _modes = [DriveMode.eco, DriveMode.normal, DriveMode.sport, DriveMode.hyper];

final timeline = <Scene>[
  Scene(
    'intro',
    8 * beat,
    kind: SceneKind.titleCard,
    kicker: 'Introducing',
    title: 'OpenDash',
    subtitle: 'A new dashboard for Ola electric scooters with a touchscreen',
    dashOpacity: 0.07,
    fadeFromBlack: true,
    enter: (d) async {
      d.theme(DashTheme.dark);
      await d.ride();
    },
    tick: (d, t) {
      final sweep = math.sin(math.pi * _ease(t / 4.2));
      d.drive(76 * sweep, 5.5 * sweep);
    },
  ),
  Scene(
    'claims',
    10 * beat,
    kind: SceneKind.claims,
    words: const ['Open source.', 'Free.', 'Built from scratch.'],
    wordAt: const [1 * beat, 4 * beat, 7 * beat],
    dashOpacity: 0.09,
    enter: (d) => d.ride(),
    tick: (d, t) => d.drive(_cruising(t, 30 + 22 * _ease(t / 5)), 2.4 + math.sin(t)),
  ),
  Scene(
    'modes',
    12 * beat,
    title: 'Every mode has its own look',
    subtitle: 'Eco, Normal, Sport and Hyper change the whole dashboard',
    enter: (d) => d.ride(mode: DriveMode.eco),
    tick: (d, t) {
      final mode = _modes[(t / (3 * beat)).floor().clamp(0, 3)];
      if (d.data.driveMode != mode) d.vehicle.setDriveMode(mode);
      d.drive(_cruising(t, 30 + 5.2 * t), 1.5 + 0.6 * t);
    },
  ),
  Scene(
    'reverse-cruise',
    12 * beat,
    title: 'Reverse. Cruise. Hill hold.',
    subtitle: 'Each state is drawn on the dial, not hidden in a corner',
    enter: (d) async {
      d.theme(DashTheme.light);
      await d.ride();
      d.vehicle.activateReverse();
      await d.settle();
    },
    tick: (d, t) {
      if (t < 2.6) {
        d.drive(4 * math.sin(math.pi * _ease(t / 2.4)), 0.3);
      } else if (t < 3.0) {
        if (d.data.reverse) {
          d.drive(0, 0);
          d.vehicle.activateReverse();
          d.vehicle.setHillHold(true);
        }
      } else if (t < 4.0) {
        d.drive(0, 0);
      } else {
        if (d.data.hillHoldActive) d.vehicle.setHillHold(false);
        final v = 45 * _ease((t - 4.0) / 1.6);
        if (t > 5.8 && d.data.cruiseMode != CruiseMode.active) {
          d.drive(45, 1.8);
          d.vehicle.setCruise(CruiseMode.active);
        } else if (t <= 5.8) {
          d.drive(v, 3.2 * (1 - _ease((t - 4.6) / 1.2)) + 1.8);
        } else {
          d.drive(45, 1.8 + 0.2 * math.sin(t * 2));
        }
      }
    },
  ),
  Scene(
    'themes',
    10 * beat,
    title: 'Light by day, dark by night',
    subtitle: 'Switches by itself, with automatic brightness',
    enter: (d) async {
      d.theme(DashTheme.light);
      await d.ride();
    },
    tick: (d, t) {
      if (t >= 5 * beat && d.light) d.theme(DashTheme.dark);
      d.drive(_cruising(t, 52), 2.2 + 0.6 * math.sin(t * 1.7));
    },
  ),
  Scene(
    'theme-gallery',
    12 * beat,
    title: 'Nine themes',
    subtitle: 'Darks and lights to pick from in Settings',
    words: [for (final t in DashTheme.builtIn) t.name],
    wordAt: [for (var i = 0; i < DashTheme.builtIn.length; i++) i * 12 * beat / DashTheme.builtIn.length],
    enter: (d) async {
      d.theme(DashTheme.builtIn.first);
      await d.ride(mode: DriveMode.sport);
    },
    tick: (d, t) {
      final i = (t / (12 * beat / DashTheme.builtIn.length)).floor().clamp(0, DashTheme.builtIn.length - 1);
      final want = DashTheme.builtIn[i];
      if (d.container.read(shownThemeProvider).name != want.name) d.theme(want);
      d.clearToast();
      d.drive(_cruising(t, 48), 2.6 + 0.6 * math.sin(t * 1.5));
    },
  ),
  Scene(
    'range',
    10 * beat,
    title: 'True Range',
    subtitle: 'Learned from your own rides. Tap it to compare with the scooter\'s own figure',
    enter: (d) async {
      d.theme(DashTheme.dark);
      await d.ride(mode: DriveMode.normal, soc: 76);
    },
    tick: (d, t) async {
      d.drive(_cruising(t, 46), 2.0 + 0.5 * math.sin(t * 1.4));
      if (t >= 1.6 && d.once('range-tap')) await d.tapKey('range');
    },
  ),
  Scene(
    'diagnostics',
    10 * beat,
    title: 'Live diagnostics and battery health',
    subtitle: 'Every cell, every temperature and the measured capacity, on the scooter\'s own screen',
    enter: (d) => d.diagnostics(DiagTab.battery),
  ),
  Scene(
    'fault-codes',
    6 * beat,
    title: 'Trouble codes',
    subtitle: 'Read from all three controllers. Never cleared',
    enter: (d) => d.diagnostics(DiagTab.faultCodes),
  ),
  Scene(
    'charging',
    8 * beat,
    title: 'Charging, in full',
    subtitle: 'Charging power, session energy, time to full, history',
    enter: (d) async {
      await d.parked();
      d.vehicle.setBattery(54);
      d.vehicle.setCharging(true);
      await d.settle(1500);
    },
    tick: (d, t) {
      final soc = 54 + (t / 1.5).floor();
      if (d.data.batterySoc != soc) d.vehicle.setBattery(soc);
    },
  ),
  Scene(
    'apps',
    6 * beat,
    title: 'CarPlay and Android Auto',
    subtitle: 'Unofficial, through third-party apps you install from the launcher*',
    footnote: '* Apps download over Wi-Fi only, for now',
    enter: (d) async {
      await d.parked();
      d.container.read(appLauncherOpenProvider.notifier).open();
      await d.settle(1200);
    },
  ),
  Scene(
    'island',
    8 * beat,
    title: 'The dash island',
    subtitle: 'Your speed and warnings stay on screen over CarPlay and Android Auto',
    footnote: 'Any other app closes back to the dashboard while you ride, for safety',
    enter: (d) async {
      await d.ride();
      d.container.read(islandPreviewProvider.notifier).set('dark map');
      await d.settle(1200);
    },
    tick: (d, t) {
      d.drive(_cruising(t, 38), 1.9);
      if (t > 2.4 && !d.data.turnRight) d.vehicle.setTurnRight(true);
    },
  ),
  Scene(
    'control-panel',
    5 * beat,
    title: 'Quick controls',
    subtitle: 'Hazards, headlights, lock and restart, one swipe away',
    enter: (d) async {
      await d.parked();
      d.container.read(controlPanelOpenProvider.notifier).open();
      await d.settle();
    },
  ),
  Scene(
    'performance',
    5 * beat,
    title: 'Performance page',
    subtitle: 'Power, torque, rpm and temperatures as you ride',
    enter: (d) async {
      await d.ride(mode: DriveMode.sport);
      d.container.read(widgetPageProvider.notifier).set(1);
      await d.settle();
    },
    tick: (d, t) => d.drive(_cruising(t, 40 + 12 * t, 3), 3 + 1.2 * t),
  ),
  Scene(
    'lock',
    5 * beat,
    title: 'Lock screen and passcode',
    subtitle: 'With a lockout after wrong tries and an emergency sheet',
    enter: (d) async {
      await d.parked();
      d.vehicle.setLocked(true);
      await d.settle(1200);
    },
  ),
  Scene(
    'safe-mode',
    5 * beat,
    title: 'Safe mode',
    subtitle: 'If it ever keeps crashing, it starts plain, with a way back to the stock dashboard',
    enter: (d) async {
      await d.parked();
      d.container.read(crashRecoveryProvider.notifier).enterSafeMode();
      await d.settle(1200);
    },
  ),
  const Scene(
    'install',
    25 * beat,
    kind: SceneKind.phone,
    title: 'Install from your phone',
    subtitle: 'With OpenDash Companion. No computer, no command line',
    footnote: 'The first time, it sets up access for you. Some MoveOS 4 builds still need a computer',
    words: ['Get OpenDash Companion on an Android phone', 'Connect to your scooter over Wi-Fi', 'Tap Install OpenDash', 'It checks the signature and sets everything up'],
    wordAt: [0, 0.8, 5.6, 7.2],
  ),
  const Scene(
    'privacy',
    7 * beat,
    kind: SceneKind.titleCard,
    title: 'Private by design.',
    titleSize: 92,
    subtitle: 'No personal data collected. Your scooter\'s firmware stays your decision.',
    dashOpacity: 0,
  ),
  const Scene('end', 13 * beat, kind: SceneKind.endCard, dashOpacity: 0, fadeToBlack: true),
];
