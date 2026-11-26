import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/theme/dash_theme.dart';

import 'timeline.dart';

Scene _thumb(String id, DashTheme theme, DriveMode mode, int speed, {String title = 'NEW\nDASH'}) => Scene(
      id,
      1.5,
      kind: SceneKind.thumbnail,
      title: title,
      subtitle: 'for Ola S1 scooters',
      footnote: 'FREE & OPEN SOURCE',
      enter: (d) async {
        d.theme(theme);
        await d.ride(mode: mode);
      },
      tick: (d, t) {
        d.drive(speed.toDouble(), speed / 12);
        d.clearToast();
      },
    );

/// Stills for the video's thumbnail, one per look.
final thumbnails = <Scene>[
  _thumb('thumb-sport', DashTheme.dark, DriveMode.sport, 72),
  _thumb('thumb-hyper', DashTheme.dark, DriveMode.hyper, 78),
  _thumb('thumb-neon', DashTheme.neonPulse, DriveMode.sport, 64),
  _thumb('thumb-normal', DashTheme.dark, DriveMode.normal, 56),
];
