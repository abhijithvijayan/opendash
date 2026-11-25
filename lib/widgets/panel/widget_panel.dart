import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/vehicle_data.dart';
import '../../providers/mock_provider.dart';
import '../../state/riding_lockout.dart';
import '../../state/battery_health_state.dart';
import '../../state/format_settings.dart';
import '../../state/range_readout.dart';
import '../../state/theme_state.dart';
import '../../state/widget_panel_state.dart';
import '../../theme/colors.dart';
import '../../theme/dash_theme.dart';
import '../../theme/typography.dart';
import '../gauges/battery_ring.dart';
import '../../theme/tokens.dart';
import 'performance_page.dart';
import 'trip_stats_page.dart';
import '../../services/analytics_logger.dart';

/// Swipeable pages where the battery ring used to be. Page 0 is the ring.
class WidgetPanel extends ConsumerStatefulWidget {
  const WidgetPanel({super.key});

  // 960, not 940: 20px of the panel's margin to the screen edge is given to
  // the centred speed dial, so its right-hand numerals ("100", "120") clear
  // the panel content with the same gap as the rest. The dial
  // itself stays centred.
  static const left = 960.0;
  static const top = 100.0;
  static const width = 300.0;
  static const height = 560.0;

  /// Band at the bottom kept for the page dots; pages centre above it.
  static const dotsReserve = 40.0;

  /// Every page's content starts this far in from the panel's left edge.
  static const contentInset = 40.0;

  @override
  ConsumerState<WidgetPanel> createState() => _WidgetPanelState();
}

class _WidgetPanelState extends ConsumerState<WidgetPanel> {
  final _controller = PageController();

  // Where and when a finger went down on the panel, for `ui.swipe_attempt`.
  Offset? _down;
  int _downMicros = 0;

  /// Every sideways drag on the panel, whether or not it turned the page:
  /// `ui.swipe` only records the ones that did. The pair shows how many
  /// tries a page turn takes, parked against riding (it felt harder on the
  /// move, with the same gesture code).
  void _logAttempt(Offset up, {required bool cancelled}) {
    final down = _down;
    _down = null;
    if (down == null) return;
    final dx = up.dx - down.dx;
    final dy = up.dy - down.dy;
    if (dx.abs() < 12 || dx.abs() < dy.abs()) return;
    final ms = (AnalyticsLogger.instance.monoMicros - _downMicros) / 1000;
    final width = context.size?.width ?? WidgetPanel.width;
    logEvent('ui', 'swipe_attempt', {
      'target': 'widget-panel',
      'from': ref.read(widgetPageProvider),
      'dx_fraction': (dx / width * 100).round() / 100,
      'ms': ms.round(),
      'px_per_s': ms <= 0 ? 0 : (dx.abs() / width * WidgetPanel.width / ms * 1000).round(),
      'cancelled': cancelled,
      'riding': ref.read(ridingLockoutProvider),
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(widgetPageProvider, (_, page) {
      if (!_controller.hasClients) return;
      if ((_controller.page ?? 0).round() != page) {
        _controller.animateToPage(
          page,
          duration: DashMotion.normal,
          curve: Curves.easeOut,
        );
      }
    });
    final page = ref.watch(widgetPageProvider);
    final navActive = ref.watch(vehicleProvider.select((v) => v.navActive));

    return ClipRect(
      child: SizedBox(
        width: WidgetPanel.width,
        height: WidgetPanel.height,
        child: Stack(
          children: [
            // Mouse drags are accepted too, so the panel swipes in Chrome
            // during development; the head unit itself is touch only.
            ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.stylus,
                },
                scrollbars: false,
              ),
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (e) {
                  _down = e.position;
                  _downMicros = AnalyticsLogger.instance.monoMicros;
                },
                onPointerUp: (e) => _logAttempt(e.position, cancelled: false),
                onPointerCancel: (e) => _logAttempt(e.position, cancelled: true),
                child: PageView(
                controller: _controller,
                // The panel is 300 design px wide, ~205 physical px on
                // the head unit after the DesignCanvas scale. A default
                // PageScrollPhysics flings need more runway than that,
                // so switching to dragStartBehavior.down means the
                // pointer-down position (not the first drag delta past
                // kTouchSlop) anchors the drag; the panel reacts after
                // 1-2 px of horizontal movement instead of ~18.
                dragStartBehavior: DragStartBehavior.down,
                onPageChanged: (page) {
                  uiSwipe('widget-panel', {'from': ref.read(widgetPageProvider), 'to': page});
                  ref.read(widgetPageProvider.notifier).set(page);
                },
                children: const [
                  BatteryPage(key: ValueKey('wp-0')),
                  PerformancePage(key: ValueKey('wp-1')),
                  TripStatsPage(key: ValueKey('wp-2')),
                ],
              ),
              ),
            ),
            // Centred under the pages' content, which sits 40 px in from the
            // panel's left edge: centred on the panel itself the dots were
            // 20 px left of the ring above them.
            Positioned(
              left: WidgetPanel.contentInset,
              right: 0,
              bottom: 0,
              child: AnimatedOpacity(
                opacity: navActive ? 0 : 1,
                duration: DashMotion.fast,
                child: PageDots(count: WidgetPage.count, active: page),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Temperature thresholds now live on VehicleData.thermalLimits, read from the
// scooter's own config frames. The readouts subtract
// VehicleData.thermalAdvance from the warn point so the amber matches the
// pre-derate banner.

/// eco while the ride is frugal, bone in the normal band, warning when the
/// scooter is drinking. Bands are approximate for the S1 Pro.
Color efficiencyColor(double whPerKm, [DashTheme t = DashTheme.dark]) =>
    whPerKm <= 35 ? t.eco : whPerKm <= 55 ? t.bone : t.warning;

/// ash below the caution threshold, warning above it, critical past danger.
Color tempColor(int value, {required int warn, required int danger}) {
  if (value > danger) return DashColors.critical;
  if (value > warn) return DashColors.warning;
  return DashColors.ash;
}

class PageDots extends ConsumerWidget {
  const PageDots({super.key, required this.count, required this.active});
  final int count;
  final int active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // On a ride, tiny dots and swipe-only navigation on a 236 dpi
    // touchscreen made switching the three widget pages 'hard'. Each dot
    // is now its own GestureDetector with a 36 px hit area (DashTouch.min
    // is 44 but the row would overflow the panel); taps jump directly.
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          // HitTestBehavior.deferToChild so the 36 px row doesn't eat
          // horizontal swipes meant for the PageView above (the bottom
          // of the panel is only ~205 physical px wide). Only the
          // visible dot swallows the tap.
          GestureDetector(
            key: ValueKey('dot-$i'),
            behavior: HitTestBehavior.deferToChild,
            onTap: () {
              uiTap('widget-dot', {'to': i, 'from': active});
              ref.read(widgetPageProvider.notifier).set(i);
            },
            child: SizedBox(
              width: 36,
              height: 36,
              child: Center(
                child: AnimatedContainer(
                  duration: DashMotion.fast,
                  curve: Curves.easeOut,
                  width: i == active ? 10 : 8,
                  height: i == active ? 10 : 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == active ? DashColors.bone : DashColors.ash.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The original battery ring and range, at their original coordinates.
class BatteryPage extends ConsumerWidget {
  const BatteryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(accentProvider);
    final theme = ref.watch(uiThemeProvider);
    final soc = ref.watch(vehicleProvider.select((v) => v.socKnown ? v.batterySoc : null));
    final range = ref.watch(rangeReadoutProvider);
    final tempKnown = ref.watch(vehicleProvider.select((v) => v.batteryTempKnown));
    final batteryTemp = ref.watch(vehicleProvider.select((v) => v.batteryTemp));
    final limits = ref.watch(vehicleProvider.select((v) => v.thermalLimits));
    final useMiles = ref.watch(useMilesProvider);
    final useF = ref.watch(useFahrenheitProvider);
    final tempTint = tempKnown
        ? tempColor(
            batteryTemp,
            warn: limits.cellWarn - VehicleData.thermalAdvance,
            danger: limits.cellError,
          )
        : DashColors.ash;
    // Ring and stats move as one group, centred above the dots.
    return Padding(
      padding: const EdgeInsets.only(left: WidgetPanel.contentInset, bottom: WidgetPanel.dotsReserve),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BatteryRing(soc: soc, accent: accent, theme: theme),
          const SizedBox(height: 24),
          SizedBox(
            width: 260,
            child: Column(
            children: [
              _RangeDisplay(range: range, useMiles: useMiles, theme: theme),
              // Only when it needs saying. The figure itself is on the
              // motor page, beside the motor's.
              if (tempTint != DashColors.ash) ...[
                const SizedBox(height: 16),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    key: const ValueKey('battery-hot'),
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text('Battery hot', style: DashText.value(20, color: tempTint)),
                      const SizedBox(width: 8),
                      Text('${toDisplayTemp(batteryTemp, useF)}°', style: DashText.caption(18, color: tempTint)),
                    ],
                  ),
                ),
              ],
            ],
          ),
          ),
        ],
      ),
    );
  }
}

/// Numeral that eases to its new value in 600ms, like the range display.
class AnimatedValue extends StatelessWidget {
  const AnimatedValue({
    super.key,
    required this.value,
    required this.style,
    this.decimals = 0,
  });
  final double value;
  final TextStyle style;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value),
      duration: DashMotion.value,
      curve: Curves.easeOutCubic,
      builder: (context, v, _) =>
          Text(v.toStringAsFixed(decimals), style: style),
    );
  }
}

/// Label above a value with its unit, the shared card shape for every page.
class DataCard extends StatelessWidget {
  const DataCard({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    this.decimals = 0,
    this.valueSize = 32,
    this.valueColor,
    this.leading,
    this.child,
    this.badge,
    this.badgeColor,
    this.labelColor,
    this.known = true,
    this.horizontal = false,
  });

  final String label;
  final double value;

  /// False while the vehicle has not reported [value]: shows '—'.
  final bool known;
  final String unit;
  final int decimals;
  final double valueSize;
  final Color? valueColor;
  final Widget? leading;
  final Widget? child;

  /// Short word after the unit, such as HOT, so a tinted value is not the
  /// only cue.
  final String? badge;
  final Color? badgeColor;

  /// Tints the label, for a card too narrow for a [badge] beside its value.
  final Color? labelColor;

  /// Label on the left, value on the right, on one line: for the temperature
  /// readouts, which stack as rows rather than being squeezed side by side.
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final labelWidget = Text(label, style: DashText.caption(16, color: labelColor));
    final valueRow = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 8)],
        if (known)
          AnimatedValue(
            value: value,
            decimals: decimals,
            style: DashText.value(valueSize, color: valueColor ?? DashColors.bone),
          )
        else
          Text('—', style: DashText.value(valueSize, color: DashColors.bone)),
        const SizedBox(width: 6),
        Text(unit, style: DashText.caption(17)),
        if (badge != null) ...[
          const SizedBox(width: 8),
          Text(badge!, style: DashText.value(13, color: badgeColor ?? DashColors.warning)),
        ],
      ],
    );
    if (horizontal) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: labelWidget),
          const SizedBox(width: 12),
          valueRow,
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Scale to fit so a wide label or a 3-digit value does not overflow a
        // narrow card; a no-op at full width.
        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: labelWidget),
        const SizedBox(height: 2),
        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: valueRow),
        if (child != null) ...[const SizedBox(height: 8), child!],
      ],
    );
  }
}

/// 12px bar on a slate track. [fraction] 0-1; [centerZero] fills from the
/// middle, right for positive and left for negative.
class DataBar extends StatelessWidget {
  const DataBar({
    super.key,
    required this.fraction,
    required this.color,
    this.width = 200,
    this.height = 12,
    this.centerZero = false,
    this.negativeColor,
  });

  final double fraction;
  final Color color;
  final double width;
  final double height;
  final bool centerZero;
  final Color? negativeColor;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: fraction.clamp(-1.0, 1.0)),
      duration: DashMotion.value,
      curve: Curves.easeOut,
      builder: (context, f, _) => CustomPaint(
        size: Size(width, height),
        painter: _BarPainter(
          f,
          color,
          centerZero,
          negativeColor ?? DashColors.regen,
        ),
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.f, this.color, this.centerZero, this.negativeColor);
  final double f;
  final Color color;
  final bool centerZero;
  final Color negativeColor;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, r),
      Paint()..color = DashColors.slate,
    );
    if (f.abs() < 0.005) {
      if (centerZero) {
        canvas.drawRect(
          Rect.fromLTWH(size.width / 2 - 1, 0, 2, size.height),
          Paint()..color = DashColors.ash,
        );
      }
      return;
    }
    final Rect rect;
    if (centerZero) {
      final mid = size.width / 2;
      final len = f.abs() * mid;
      rect = f > 0
          ? Rect.fromLTWH(mid, 0, len, size.height)
          : Rect.fromLTWH(mid - len, 0, len, size.height);
    } else {
      rect = Rect.fromLTWH(0, 0, f.clamp(0, 1) * size.width, size.height);
    }
    final c = f < 0 ? negativeColor : color;
    canvas.drawRect(
      rect.inflate(3),
      Paint()..color = c.withValues(alpha: 0.14),
    );
    canvas.drawRRect(RRect.fromRectAndRadius(rect, r), Paint()..color = c);
    if (centerZero) {
      canvas.drawRect(
        Rect.fromLTWH(size.width / 2 - 1, 0, 2, size.height),
        Paint()..color = DashColors.ash,
      );
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.f != f ||
      old.color != color ||
      old.centerZero != centerZero ||
      old.negativeColor != negativeColor;
}

/// One range figure and one caption. Which figure it is (the scooter's own
/// or the one learned from past rides) is not the rider's problem at a
/// glance; a tap shows the scooter's estimate and how much the learned one
/// rests on, for [peekFor].
class _RangeDisplay extends ConsumerStatefulWidget {
  const _RangeDisplay({required this.range, required this.useMiles, required this.theme});
  final RangeReadout range;
  final bool useMiles;
  final DashTheme theme;

  static const peekFor = Duration(seconds: 4);

  @override
  ConsumerState<_RangeDisplay> createState() => _RangeDisplayState();
}

class _RangeDisplayState extends ConsumerState<_RangeDisplay> {
  Timer? _peek;

  @override
  void dispose() {
    _peek?.cancel();
    super.dispose();
  }

  void _tap() {
    if (widget.range.kind != RangeKind.trueRange) return;
    uiTap('range-peek');
    _peek?.cancel();
    setState(() => _peek = Timer(_RangeDisplay.peekFor, () => setState(() => _peek = null)));
  }

  @override
  Widget build(BuildContext context) {
    final range = widget.range;
    final theme = widget.theme;
    final useMiles = widget.useMiles;
    final km = range.shownKm;
    final limp = range.kind == RangeKind.limp;
    final valueStyle = DashText.value(52, color: limp ? theme.warning : range.approx ? theme.ash : theme.bone);
    final peeking = _peek != null && range.kind == RangeKind.trueRange;
    final learned = ref.watch(trueRangeProvider);

    return GestureDetector(
      key: const ValueKey('range'),
      behavior: HitTestBehavior.opaque,
      onTap: _tap,
      child: Column(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              if (km == null)
                Text('—', key: const ValueKey('range-unknown'), style: valueStyle)
              else
                AnimatedValue(
                  key: ValueKey(limp ? 'range-limp' : 'range-value'),
                  value: toDisplayDistance(km, useMiles).toDouble(),
                  style: valueStyle,
                ),
              const SizedBox(width: 8),
              Text(distanceUnit(useMiles), style: DashText.caption(24, color: theme.ash)),
            ],
          ),
          Text(
            limp ? 'limp range' : 'range',
            key: const ValueKey('range-caption'),
            style: DashText.caption(18, color: limp ? theme.warning : theme.ash),
          ),
          // Drawn into the empty space under the caption without taking
          // any height, so the ring above neither jumps when it appears nor
          // sits off-centre while it is away (seen in Chrome).
          SizedBox(
            height: 0,
            child: OverflowBox(
              alignment: Alignment.topCenter,
              minHeight: 0,
              maxHeight: 64,
              child: !peeking
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.topCenter,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Scooter estimates ${toDisplayDistance(learned.stockRangeKm, useMiles)} ${distanceUnit(useMiles)}',
                              key: const ValueKey('range-peek'),
                              style: DashText.caption(16, color: theme.bone),
                            ),
                            Text(
                              'Learned from ${learned.ridesUsed} ${learned.ridesUsed == 1 ? 'ride' : 'rides'}',
                              style: DashText.caption(14, color: theme.ash),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
