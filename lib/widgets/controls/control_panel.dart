import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/vehicle_data.dart';
import '../../providers/mock_provider.dart';
import '../../state/control_panel.dart';
import '../../state/riding_lockout.dart';
import '../../state/riding_settings.dart';
import '../../state/scooter_restart.dart';
import '../../state/settings_state.dart';
import '../../state/theme_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../gauges/arc_paint.dart';
import '../indicators/beam_icon.dart';
import '../overlays/alert_overlay.dart';
import '../status_bar/status_icons.dart';
import '../../theme/tokens.dart';
import '../../services/analytics_logger.dart';
import '../../state/auto_brightness.dart';
import '../../state/scooter_capabilities.dart';

/// Touch stand-in for the left handlebar switch cluster. Slides in from the
/// right edge between the status bar and the trip strip; a swipe from the
/// edge opens it, a swipe back closes it, and the handle still taps.
class ControlPanel extends ConsumerWidget {
  const ControlPanel({super.key, required this.charging});

  /// Charging mode shows only brightness and settings (and lock, when shown).
  final bool charging;

  static const width = 224.0;
  static const handleHit = 56.0;
  static const top = 72.0;
  static const height = 624.0;
  static const edgeZone = 60.0;
  static const buttonSize = DashTouch.primary;
  static const compactButtonSize = DashTouch.min;
  static const columnGap = 16.0;
  static const swipeVelocity = 200.0;

  /// The lock button. Hidden for now: locking from the panel does not work
  /// on the scooter yet.
  // TODO(panel-lock): show it again once locking from the panel works on the scooter.
  @visibleForTesting
  static bool showLock = false;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(controlPanelOpenProvider);
    final riding = ref.watch(ridingLockoutProvider);
    final highBeam = ref.watch(vehicleProvider.select((v) => v.highBeam));
    final lowBeam = ref.watch(vehicleProvider.select((v) => v.lowBeam));
    final headlamp = highBeam || lowBeam;
    final smartHeadlight = ref.watch(vehicleProvider.select((v) => v.smartHeadlight));
    // The VCU is holding the lamp: a tap pauses it rather than fights it.
    final beamAuto = headlamp && smartHeadlight == SmartHeadlight.auto;
    final brightness = ref.watch(brightnessProvider);
    final autoBrightness = ref.watch(ridingSettingsProvider.select((s) => s.isOn(RidingFeature.autoBrightness))) &&
        ref.watch(autoBrightnessProvider.select((a) => a.boost == null));
    final armed = ref.watch(lockConfirmProvider);
    final locking = ref.watch(lockingProvider);
    final canRestart = ref.watch(vehicleProvider.select(restartAvailable));
    final hazard = ref.watch(vehicleProvider.select((v) => v.hazard));
    final hazardAvailable = ref.watch(scooterCapabilitiesProvider.select((c) => c.hazard));
    final n = ref.read(vehicleProvider.notifier);
    final panel = ref.read(controlPanelOpenProvider.notifier);
    // An alert banner takes the top of the panel's band, so the panel moves
    // under it and drops to 56px buttons without captions so every button
    // stays reachable.
    final shift = ref.watch(alertBannerShiftProvider);
    final compact = shift > 0;
    final size = compact ? compactButtonSize : buttonSize;

    final groups = <List<Widget>>[
      if (!charging) ...[
        [
          // The scooter says when it has no hazard function
          // (BOOL_HAZARD_LIGHT_FEATURE_AVAILABLE); unknown counts as present.
          if (hazardAvailable) ControlButton(
            key: const ValueKey('ctl-hazard'),
            size: size,
            active: hazard,
            activeColor: DashColors.warning,
            caption: compact ? null : 'HAZ',
            onTap: () {
              uiTap('ctl-hazard');
              n.toggleHazard();
            },
            child: const Icon(Icons.warning_amber_rounded, size: 42),
          ),
          // High beam only, while the headlamp is lit. The DRL switch it
          // also was before riding never moved the lamp (on Gen 1 and on
          // MoveOS 5), and the indicators are the handlebar's.
          if (headlamp)
            ControlButton(
              key: const ValueKey('ctl-beam'),
              size: size,
              active: true,
              activeColor: highBeam ? DashColors.normal : DashColors.eco,
              caption: compact ? null : (beamAuto ? 'AUTO' : highBeam ? 'HIGH' : 'LOW'),
              captionColor: beamAuto ? DashColors.bone : null,
              onTap: () {
                uiTap('ctl-beam', {'smart': smartHeadlight.name});
                n.toggleHighBeam();
              },
              onLongPress: smartHeadlight == SmartHeadlight.paused
                  ? () {
                      uiLongPress('ctl-beam');
                      n.resumeSmartHeadlight();
                    }
                  : null,
              child: BeamIcon(high: highBeam, on: true, color: DashColors.ink),
            ),
        ],
      ],
      [
        // Lit from medium up, so a glance tells low from the rest.
        ControlButton(
          key: const ValueKey('ctl-brightness'),
          size: size,
          active: brightness >= 60,
          activeColor: DashColors.warning,
          caption: compact ? null : autoBrightness ? 'AUTO' : brightnessLabel(brightness).toUpperCase(),
          onTap: () {
            uiTap('ctl-brightness');
            ref.read(brightnessProvider.notifier).cyclePreset();
          },
          onLongPress: riding
              ? null
              : () {
                  uiLongPress('ctl-brightness');
                  ref.read(settingsSectionProvider.notifier).set(SettingsSection.display);
                  ref.read(settingsScreenOpenProvider.notifier).open();
                },
          child: SunIcon(color: brightness >= 60 ? DashColors.ink : DashColors.ash, size: 30),
        ),
        // The dashboard pill is the trunk control; the panel's slot goes to
        // settings, which is otherwise hidden behind the toolbar.
        if (!riding) ...[
          ControlButton(
            key: const ValueKey('ctl-settings'),
            size: size,
            active: false,
            activeColor: DashColors.bone,
            caption: compact ? null : 'SET',
            onTap: () {
              uiTap('ctl-settings');
              panel.close();
              ref.read(settingsScreenOpenProvider.notifier).open();
            },
            child: GearIcon(color: DashColors.ash, size: 30),
          ),
          if (showLock)
          ControlButton(
            key: const ValueKey('ctl-lock'),
            size: size,
            active: false,
            activeColor: DashColors.critical,
            armed: armed,
            enabled: !locking,
            caption: compact ? null : (armed ? 'LOCK?' : 'LOCK'),
            captionColor: armed || locking ? DashColors.critical : null,
            onTap: () {
              uiTap('ctl-lock', {'armed': armed});
              ref.read(lockConfirmProvider.notifier).tap();
            },
            child: LockGlyph(armed: armed, locking: locking, ringSize: size - 14),
          ),
          // Behind the passcode: a mis-tap here would reboot the head unit.
          ControlButton(
            key: const ValueKey('ctl-restart'),
            size: size,
            active: false,
            activeColor: DashColors.bone,
            enabled: canRestart,
            caption: compact ? null : 'RESTART',
            onTap: () {
              uiTap('ctl-restart');
              panel.close();
              ref.read(scooterRestartProvider.notifier).request('control_panel');
            },
            child: Icon(Icons.restart_alt_rounded, size: 30, color: canRestart ? DashColors.ash : DashColors.slate),
          ),
        ],
      ],
    ];
    // Two buttons per row: a single column of 72px keys with captions would
    // not fit the band.
    final children = <Widget>[];
    for (final group in groups) {
      if (group.isEmpty) continue;
      if (children.isNotEmpty) children.add(const _GroupDivider());
      for (var i = 0; i < group.length; i += 2) {
        if (i > 0) children.add(SizedBox(height: compact ? 8 : 12));
        children.add(Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            group[i],
            if (i + 1 < group.length) ...[const SizedBox(width: columnGap), group[i + 1]],
          ],
        ));
      }
    }

    return Stack(
      children: [
        if (open)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: panel.close,
              onHorizontalDragEnd: (d) {
                if (d.primaryVelocity != null && d.primaryVelocity! > swipeVelocity) panel.close();
              },
              child: ColoredBox(key: const ValueKey('ctl-scrim'), color: DashColors.ink.withValues(alpha: 0.15)),
            ),
          ),
        AnimatedPositioned(
          duration: DashMotion.normal,
          curve: Curves.easeOutCubic,
          right: open ? 0 : -width,
          top: top,
          height: height,
          width: width + handleHit,
          // The band shift is deliberately not animated: the buttons
          // resize instantly, so the surface must too.
          child: Padding(
            padding: EdgeInsets.only(top: shift),
            child: Row(
            children: [
              _Handle(key: const ValueKey('ctl-handle'), open: open, onTap: panel.toggle),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragEnd: (d) {
                  if (d.primaryVelocity != null && d.primaryVelocity! > swipeVelocity) panel.close();
                },
                child: Container(
                  key: const ValueKey('ctl-surface'),
                  width: width,
                  height: height - shift,
                  decoration: BoxDecoration(
                    color: DashColors.inkLift,
                    border: Border(left: BorderSide(color: DashColors.slate, width: 1.5)),
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: children),
                ),
              ),
            ],
            ),
          ),
        ),
        if (!open)
          Positioned(
            key: const ValueKey('ctl-edge'),
            right: 0,
            top: top + shift,
            width: edgeZone,
            height: height - shift,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragEnd: (d) {
                if (d.primaryVelocity != null && d.primaryVelocity! < -swipeVelocity) panel.open();
              },
            ),
          ),
      ],
    );
  }
}

class _GroupDivider extends StatelessWidget {
  const _GroupDivider();

  @override
  Widget build(BuildContext context) => Padding(
        key: const ValueKey('ctl-divider'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Container(width: ControlPanel.buttonSize * 2 + ControlPanel.columnGap, height: 1, color: DashColors.slate),
      );
}

class _Handle extends StatefulWidget {
  const _Handle({super.key, required this.open, required this.onTap});
  final bool open;
  final VoidCallback onTap;

  @override
  State<_Handle> createState() => _HandleState();
}

class _HandleState extends State<_Handle> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final color = _down ? DashColors.ash : DashColors.slate;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      child: SizedBox(
        width: ControlPanel.handleHit,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedRotation(
                key: const ValueKey('ctl-chevron'),
                turns: widget.open ? 0.5 : 0,
                duration: DashMotion.normal,
                curve: Curves.easeOutCubic,
                child: ChevronIcon(color: DashColors.ash),
              ),
              const SizedBox(height: 8),
              AnimatedContainer(
                duration: DashMotion.fast,
                width: 6,
                height: 72,
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small "‹" pointing left; rotated by the handle when the panel is open.
class ChevronIcon extends StatelessWidget {
  const ChevronIcon({super.key, required this.color, this.size = 12});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _ChevronPainter(color));
}

class _ChevronPainter extends CustomPainter {
  _ChevronPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.7, h * 0.1)
        ..lineTo(w * 0.3, h / 2)
        ..lineTo(w * 0.7, h * 0.9),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_ChevronPainter old) => old.color != color;
}

/// Lock icon that becomes a spinning glyph with a progress ring while the
/// lock command is in flight.
class LockGlyph extends StatelessWidget {
  const LockGlyph({super.key, required this.armed, required this.locking, this.ringSize = 58});
  final bool armed;
  final bool locking;

  /// Ring diameter; sized to the button it sits in.
  final double ringSize;

  @override
  Widget build(BuildContext context) {
    final color = armed || locking ? DashColors.critical : DashColors.ash;
    return SizedBox(
      width: ringSize,
      height: ringSize,
      child: TweenAnimationBuilder<double>(
        key: ValueKey(locking),
        tween: Tween(begin: 0, end: locking ? 1 : 0),
        duration: locking ? LockingNotifier.duration : Duration.zero,
        curve: Curves.easeInOut,
        builder: (context, t, _) => CustomPaint(
          key: const ValueKey('lock-progress'),
          painter: LockProgressPainter(locking ? t : 0, DashColors.ash.withValues(alpha: 0.35), DashColors.critical),
          child: Center(
            child: Transform.rotate(
              angle: locking ? t * 2 * math.pi : 0,
              child: Icon(
                locking
                    ? Icons.sync_rounded
                    : armed
                        ? Icons.lock_rounded
                        : Icons.lock_outline_rounded,
                size: ringSize * 0.6,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 270° arc, thin track, filled to [progress].
class LockProgressPainter extends CustomPainter {
  LockProgressPainter(this.progress, this.track, this.fill);
  final double progress;
  final Color track;
  final Color fill;

  static const sweepDeg = 270.0;
  static const startDeg = 135.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: size.width / 2 - 2);
    canvas.drawArc(
      rect,
      deg(startDeg),
      deg(sweepDeg),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = track,
    );
    drawGlowArc(canvas, rect, deg(startDeg), deg(sweepDeg * progress.clamp(0, 1)), fill, 3);
  }

  @override
  bool shouldRepaint(LockProgressPainter old) => old.progress != progress || old.fill != fill || old.track != track;
}

class ControlButton extends StatefulWidget {
  const ControlButton({
    super.key,
    required this.child,
    required this.active,
    required this.activeColor,
    required this.onTap,
    this.size = ControlPanel.buttonSize,
    this.enabled = true,
    this.armed = false,
    this.caption,
    this.captionColor,
    this.onLongPress,
  });

  final Widget child;
  final bool active;
  final Color activeColor;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double size;
  final bool enabled;

  /// Lock confirmation state: red pulsing border.
  final bool armed;

  /// Short label under the circle, for gloved-hand identification.
  final String? caption;
  final Color? captionColor;

  @override
  State<ControlButton> createState() => _ControlButtonState();
}

class _ControlButtonState extends State<ControlButton> with SingleTickerProviderStateMixin {
  bool _down = false;
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );

  @override
  void initState() {
    super.initState();
    if (widget.armed) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(ControlButton old) {
    super.didUpdateWidget(old);
    if (widget.armed && !old.armed) _pulse.repeat(reverse: true);
    if (!widget.armed && old.armed) _pulse.stop();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    final bg = active
        ? (_down ? Color.lerp(widget.activeColor, DashColors.ink, 0.2)! : widget.activeColor)
        : DashColors.slate.withValues(alpha: _down ? 0.95 : 0.6);

    return AnimatedOpacity(
      opacity: widget.enabled ? 1 : 0.35,
      duration: DashMotion.fast,
      child: IgnorePointer(
        ignoring: !widget.enabled,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _set(true),
          onTapUp: (_) => _set(false),
          onTapCancel: () => _set(false),
          onTap: () {
            HapticFeedback.lightImpact();
            widget.onTap();
          },
          onLongPress: widget.onLongPress,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                scale: _down ? 0.92 : 1,
                duration: DashMotion.fast,
                child: AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, child) => AnimatedContainer(
                    duration: DashMotion.fast,
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: bg,
                      border: widget.armed
                          ? Border.all(
                              color: DashColors.critical.withValues(alpha: 0.4 + 0.6 * _pulse.value),
                              width: 2.5,
                            )
                          : null,
                      boxShadow: active
                          ? [BoxShadow(color: widget.activeColor.withValues(alpha: 0.45), blurRadius: 14)]
                          : null,
                    ),
                    child: child,
                  ),
                  child: Center(
                    child: IconTheme(
                      data: IconThemeData(color: active ? DashColors.ink : DashColors.ash),
                      child: widget.child,
                    ),
                  ),
                ),
              ),
              if (widget.caption != null) ...[
                const SizedBox(height: 4),
                Text(
                  widget.caption!,
                  style: DashText.caption(14, color: widget.captionColor ?? DashColors.ash).copyWith(letterSpacing: 0.8),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Sun glyph for the brightness quick-adjust.
class SunIcon extends StatelessWidget {
  const SunIcon({super.key, required this.color, this.size = 30});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _SunPainter(color));
}

class _SunPainter extends CustomPainter {
  _SunPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width * 0.2;
    canvas.drawCircle(c, r, Paint()..color = color);
    final ray = Paint()
      ..color = color
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      final dx = math.cos(a), dy = math.sin(a);
      canvas.drawLine(
        Offset(c.dx + dx * r * 1.7, c.dy + dy * r * 1.7),
        Offset(c.dx + dx * r * 2.4, c.dy + dy * r * 2.4),
        ray,
      );
    }
  }

  @override
  bool shouldRepaint(_SunPainter old) => old.color != color;
}
