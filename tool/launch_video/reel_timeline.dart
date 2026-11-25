import 'timeline.dart';

/// The vertical cut: the launch video's footage, shorter, each scene's words written for a phone.
final reelTimeline = <Scene>[
  sceneById('intro').recut(
    6 * beat,
    kind: SceneKind.titleCard,
    kicker: 'Introducing',
    title: 'OpenDash',
    subtitle: 'A new dashboard for Ola scooters with a touchscreen',
    dashOpacity: 1,
    fadeFromBlack: true,
  ),
  sceneById('claims').recut(5 * beat, wordAt: [0.15, 1.15, 2.15]),
  sceneById('modes').recut(
    7 * beat,
    title: 'Every mode, its own look',
    subtitle: 'Eco, Normal, Sport and Hyper, each its own colour',
  ),
  sceneById('reverse-cruise').recut(7 * beat, subtitle: 'Drawn right on the dial'),
  sceneById('themes').recut(5 * beat, title: 'Light by day, dark by night', subtitle: 'Switches by itself, with auto brightness'),
  sceneById('range').recut(5 * beat, subtitle: 'A range learned from your own rides'),
  sceneById('diagnostics').recut(5 * beat, title: 'Live diagnostics', subtitle: 'Every cell and temperature, on the scooter itself'),
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
  ),
  sceneById('safe-mode').recut(3 * beat, subtitle: 'If it ever keeps crashing, a way back to stock'),
  const Scene('end', 9 * beat, kind: SceneKind.endCard, dashOpacity: 0, fadeToBlack: true),
];
