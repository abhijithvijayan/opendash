import 'package:flutter/widgets.dart' show Offset;

import 'timeline.dart';

/// The vertical cut: the launch video's footage, shorter and cropped closer.
final reelTimeline = <Scene>[
  sceneById('intro').recut(
    6 * beat,
    kind: SceneKind.titleCard,
    kicker: 'Introducing',
    title: 'OpenDash',
    subtitle: 'A new dashboard for Ola scooters with a touchscreen',
    dashOpacity: 1,
    fadeFromBlack: true,
    zoom: 1.15,
  ),
  sceneById('claims').recut(5 * beat, wordAt: [0.15, 1.15, 2.15]),
  sceneById('modes').recut(
    7 * beat,
    title: 'Every mode, its own look',
    subtitle: 'Eco, Normal, Sport and Hyper each change the whole screen',
    zoom: 1.35,
    focus: const Offset(560, 400),
  ),
  sceneById('reverse-cruise').recut(7 * beat, subtitle: 'Drawn right on the dial', zoom: 1.5, focus: const Offset(640, 400)),
  sceneById('themes').recut(5 * beat, title: 'Light by day, dark by night', subtitle: 'Switches by itself, with auto brightness', zoom: 1.2),
  sceneById('range').recut(5 * beat, subtitle: 'A range learned from your own rides', zoom: 1.5, focus: const Offset(960, 360)),
  sceneById('diagnostics').recut(5 * beat, title: 'Live diagnostics', subtitle: 'Every cell and temperature, on the scooter itself', zoom: 1.0),
  sceneById('charging').recut(4 * beat, title: 'Charging, in full', subtitle: 'Power, energy, time to full'),
  sceneById('apps').recut(
    4 * beat,
    subtitle: 'Unofficial, through third-party apps*',
    footnote: '* Apps download over Wi-Fi only, for now',
  ),
  sceneById('island').recut(
    4 * beat,
    subtitle: 'Speed and warnings stay on screen over CarPlay and Android Auto',
    footnote: 'Other apps close back to the dash while you ride',
    zoom: 1.4,
    focus: const Offset(640, 260),
  ),
  sceneById('safe-mode').recut(3 * beat, subtitle: 'If it ever keeps crashing, a way back to stock', zoom: 1.3),
  const Scene('end', 9 * beat, kind: SceneKind.endCard, dashOpacity: 0, fadeToBlack: true),
];
