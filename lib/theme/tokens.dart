import 'package:flutter/widgets.dart';

/// Layout constants shared by every full-screen layout and overlay.
abstract final class DashSpace {
  /// Side margins on full-screen layouts.
  static const gutter = 72.0;

  /// Top offset for sub-screen headers (back arrow + title).
  static const headerTop = 84.0;

  /// Top offset for sub-screen body content.
  static const bodyTop = 160.0;

  /// Top offset for overlay bodies: under the 56px toolbar plus a margin.
  static const overlayTop = 72.0;

  /// Bottom margin for scrollable content.
  static const bodyBottom = 32.0;

  /// Padding inside cards and popups.
  static const cardPad = 20.0;

  /// Padding inside dialogs and overlays.
  static const dialogPad = 32.0;
}

/// Touch target floors for the head unit's capacitive panel: vibration and
/// gloves make anything smaller miss.
abstract final class DashTouch {
  /// Secondary actions, list rows, icon buttons.
  static const min = 56.0;

  /// Primary actions: control panel buttons, mode ladder rows.
  static const primary = 72.0;

  /// Critical controls: keypad keys, lock, emergency.
  static const critical = 96.0;
}

/// Corner radii. Three shapes only: chip, card, dialog, plus the pill.
abstract final class DashRadius {
  /// Cards, popups, tiles.
  static const card = 12.0;

  /// Pill buttons (emergency, primary, toast).
  static const button = 28.0;

  /// Small chips and badges.
  static const chip = 6.0;

  /// Large dialogs and overlays.
  static const dialog = 16.0;
}

/// Animation timings. Loops with their own meaning (turn blink, breathing
/// glows) keep their own durations.
abstract final class DashMotion {
  /// Press feedback, toggles, micro fades.
  static const fast = Duration(milliseconds: 150);

  /// Overlays and slides.
  static const normal = Duration(milliseconds: 250);

  /// Theme easing, accent lerp, screen crossfade.
  static const slow = Duration(milliseconds: 500);

  /// Numeric readouts (SoC, range, trip, stats).
  static const value = Duration(milliseconds: 600);

  /// Live gauges (speed, power, rpm): readability beats theatre.
  static const gauge = Duration(milliseconds: 180);

  /// Default curve for slides and overlays.
  static const curve = Curves.easeOutCubic;

  /// Curve for value animations and switchers.
  static const valueCurve = Curves.easeOut;

  /// Switcher transition for text-heavy panels: the outgoing child is
  /// fully gone before the incoming one starts, so lines never overlap.
  /// The switcher's own curves must be linear; an eased curve pushes both
  /// children past the halfway mark at once and they blend again.
  static Widget fadeThrough(Widget child, Animation<double> animation) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: const Interval(0.5, 1.0, curve: Curves.easeOut)),
        child: child,
      );
}

/// Backdrop alphas.
abstract final class DashScrim {
  /// Blocking scrims the rider taps through to dismiss.
  static const backdrop = 0.7;

  /// Glass-like persistent surfaces (toast, volume, nav bar, banners).
  static const glass = 0.95;
}
