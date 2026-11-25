import 'dart:async';

import '../../state/qr_card.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/format_settings.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';
import '../../services/analytics_logger.dart';

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12, top: 12),
        child: Text(text.toUpperCase(), style: DashText.caption(18).copyWith(letterSpacing: 1.2)),
      );
}

class SettingsDivider extends StatelessWidget {
  const SettingsDivider({super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Divider(color: DashColors.slate, height: 1, thickness: 1),
      );
}

/// 52x30 pill toggle with haptics; replaces Material's Switch for a
/// consistent look across settings.
class DashSwitch extends StatelessWidget {
  const DashSwitch({super.key, required this.value, required this.onChanged, this.enabled = true});
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final active = enabled && onChanged != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: active
          ? () {
              HapticFeedback.lightImpact();
              onChanged!(!value);
            }
          : null,
      child: Opacity(
        opacity: active ? 1 : 0.4,
        child: AnimatedContainer(
          duration: DashMotion.fast,
          width: 52,
          height: 30,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: value ? DashColors.bone : DashColors.slate,
            borderRadius: BorderRadius.circular(DashRadius.button),
          ),
          child: AnimatedAlign(
            duration: DashMotion.fast,
            curve: Curves.easeOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: value ? DashColors.ink : DashColors.ash,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ToggleRow extends StatelessWidget {
  const ToggleRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.caption,
  });
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool enabled;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final active = enabled && onChanged != null;
    void changed(bool on) {
      uiToggle(label, on);
      onChanged!(on);
    }
    // Only the switch end of the row is the target. The whole row used to
    // be, and on a scooter a finger scrolling the list switched Motor
    // cut-off and Adaptive Power Boost on within 0.3 s.
    return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: DashTouch.min),
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: caption != null ? 10 : 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: DashText.caption(20, color: DashColors.bone)),
                    if (caption != null) ...[
                      const SizedBox(height: 4),
                      Text(caption!, style: DashText.caption(16), maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  ],
                ),
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: active
                  ? () {
                      HapticFeedback.lightImpact();
                      changed(!value);
                    }
                  : null,
              child: SizedBox(
                width: 84,
                height: DashTouch.min,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: IgnorePointer(
                    child: DashSwitch(value: value, onChanged: onChanged == null ? null : changed, enabled: enabled),
                  ),
                ),
              ),
            ),
          ],
        ),
    );
  }
}

class SliderRow extends StatelessWidget {
  const SliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
    this.min = 0,
    this.max = 100,
    this.display,
    this.divisions,
    this.step = 1,
  });

  /// What one tap on − or + moves the value by. The track gets close; the
  /// buttons land on the number (it once took 18 drags to set a limit of 60).
  final double step;
  final String label;
  final double value;
  final double min;
  final double max;
  final String? display;
  final int? divisions;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  Widget _stepButton(IconData icon, double by) {
    final next = (value + by).clamp(min, max).toDouble();
    final live = onChanged != null && next != value.clamp(min, max);
    return GestureDetector(
      key: ValueKey('slider-${by < 0 ? 'minus' : 'plus'}-$label'),
      behavior: HitTestBehavior.opaque,
      onTap: !live
          ? null
          : () {
              HapticFeedback.lightImpact();
              onChanged!(next);
              onChangeEnd?.call(next);
            },
      child: SizedBox(
        width: DashTouch.min,
        height: DashTouch.min,
        child: Center(
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: DashColors.slate, shape: BoxShape.circle),
            child: Icon(icon, size: 24, color: live ? DashColors.bone : DashColors.ash),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: DashText.caption(20, color: DashColors.bone)),
              Text(display ?? '${value.round()}', style: DashText.value(20)),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: DashTouch.min,
            child: Row(
              children: [
                _stepButton(Icons.remove_rounded, -step),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      activeTrackColor: DashColors.bone,
                      inactiveTrackColor: DashColors.slate,
                      thumbColor: DashColors.bone,
                      overlayColor: DashColors.bone.withValues(alpha: 0.13),
                      trackHeight: 6,
                      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 14),
                    ),
                    child: Slider(
                      value: value.clamp(min, max),
                      min: min,
                      max: max,
                      divisions: divisions,
                      // A touch on the track does not move the value; a drag
                      // moves it from where it is. On a scooter a speed
                      // limit went 58 to 105 on one touch beside the + button,
                      // and brightness 79 to 90 the same way.
                      allowedInteraction: SliderInteraction.slideOnly,
                      onChanged: onChanged,
                      onChangeEnd: onChangeEnd,
                    ),
                  ),
                ),
                _stepButton(Icons.add_rounded, step),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Dropdown stand-in: a row of chips, one active.
class ChipRow<T> extends StatelessWidget {
  const ChipRow({
    super.key,
    required this.options,
    required this.value,
    required this.label,
    required this.onSelected,
  });
  final List<T> options;
  final T value;
  final String Function(T) label;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final o in options)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.lightImpact();
              onSelected(o);
            },
            child: AnimatedContainer(
              duration: DashMotion.fast,
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                color: o == value ? DashColors.bone.withValues(alpha: 0.14) : Colors.transparent,
                border: Border.all(color: o == value ? DashColors.bone : DashColors.slate, width: 1.5),
                borderRadius: BorderRadius.circular(DashRadius.chip),
              ),
              child: Center(
                widthFactor: 1,
                child: Text(label(o), style: DashText.caption(18, color: o == value ? DashColors.bone : DashColors.ash)),
              ),
            ),
          ),
      ],
    );
  }
}

class SettingsCard extends StatelessWidget {
  const SettingsCard({
    super.key,
    required this.child,
    required this.selected,
    required this.onTap,
    this.width,
    this.height,
    this.background,
  });
  final Widget child;
  final bool selected;
  final VoidCallback onTap;
  final double? width;
  final double? height;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: AnimatedContainer(
        duration: DashMotion.fast,
        width: width,
        height: height,
        padding: const EdgeInsets.all(DashSpace.cardPad),
        decoration: BoxDecoration(
          color: background ?? DashColors.inkLift,
          borderRadius: BorderRadius.circular(DashRadius.card),
          border: Border.all(color: selected ? DashColors.bone : DashColors.slate, width: 1.5),
        ),
        child: child,
      ),
    );
  }
}

class KeyValueRow extends StatelessWidget {
  const KeyValueRow(this.label, this.value, {super.key});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: DashTouch.min,
        child: Row(
          children: [
            SizedBox(width: 220, child: Text(label, style: DashText.caption(20), maxLines: 1, overflow: TextOverflow.ellipsis)),
            Expanded(child: Text(value, style: DashText.value(20))),
          ],
        ),
      );
}

/// An identifier (VIN, ICCID) shown as its last four characters. A long
/// press shows the whole value for [revealFor], or hides it again.
class MaskedValueRow extends StatefulWidget {
  const MaskedValueRow(this.label, this.value, {super.key, required this.field});
  final String label;
  final String value;

  /// Names the row in the `ui.reveal` event; the value is never logged.
  final String field;

  static const revealFor = Duration(seconds: 10);

  static String mask(String v) => v.length <= 4 ? v : '•••• ${v.substring(v.length - 4)}';

  @override
  State<MaskedValueRow> createState() => _MaskedValueRowState();
}

class _MaskedValueRowState extends State<MaskedValueRow> {
  bool _revealed = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _toggle() {
    HapticFeedback.mediumImpact();
    _timer?.cancel();
    setState(() => _revealed = !_revealed);
    if (!_revealed) return;
    logEvent('ui', 'reveal', {'field': widget.field});
    _timer = Timer(MaskedValueRow.revealFor, () {
      if (mounted) setState(() => _revealed = false);
    });
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        key: ValueKey('masked-${widget.field}'),
        behavior: HitTestBehavior.opaque,
        onLongPress: _toggle,
        child: SizedBox(
          height: DashTouch.min,
          child: Row(
            children: [
              SizedBox(width: 220, child: Text(widget.label, style: DashText.caption(20), maxLines: 1, overflow: TextOverflow.ellipsis)),
              Text(_revealed ? widget.value : MaskedValueRow.mask(widget.value), style: DashText.value(20)),
              const SizedBox(width: 10),
              Icon(_revealed ? Icons.visibility_rounded : Icons.visibility_off_outlined, size: 16, color: DashColors.ash),
              if (!_revealed) ...[
                const SizedBox(width: 8),
                Text('Hold to show', style: DashText.caption(13, color: DashColors.ash)),
              ],
            ],
          ),
        ),
      );
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton(this.label, {super.key, required this.onTap, this.color, this.icon});
  final String label;
  final VoidCallback onTap;
  final Color? color;

  /// Leading glyph, for actions that should not read like the others.
  final Widget? icon;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: Container(
          height: DashTouch.min,
          padding: EdgeInsets.symmetric(horizontal: 28),
          decoration: BoxDecoration(color: DashColors.slate, borderRadius: BorderRadius.circular(DashRadius.button)),
          child: Center(
            widthFactor: 1,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[icon!, const SizedBox(width: 12)],
                Text(label, style: DashText.value(20, color: color ?? DashColors.bone)),
              ],
            ),
          ),
        ),
      );
}

class TextButtonLink extends StatelessWidget {
  const TextButtonLink(this.label, {super.key, required this.onTap, this.color});
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
          child: Text(label, style: DashText.value(20, color: color ?? DashColors.ash)),
        ),
      );
}

/// Centred card over a dimmed backdrop for disclaimers and confirmations.
class ConfirmCard extends StatelessWidget {
  const ConfirmCard({
    super.key,
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.onPrimary,
    this.titleColor,
    this.primaryColor,
    this.secondaryLabel,
    this.onSecondary,
    this.tertiaryLabel,
    this.onTertiary,
    this.width = 400,
  });
  final String title;
  final String body;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final Color? titleColor;
  final Color? primaryColor;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  /// A third, leftmost text action; when present it is the dismiss action
  /// (a backdrop tap) instead of the secondary one.
  final String? tertiaryLabel;
  final VoidCallback? onTertiary;
  final double width;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTertiary ?? onSecondary,
      child: ColoredBox(
        color: DashColors.ink.withValues(alpha: DashScrim.backdrop),
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: width,
              padding: const EdgeInsets.all(DashSpace.dialogPad),
              decoration: BoxDecoration(
                color: DashColors.inkLift,
                borderRadius: BorderRadius.circular(DashRadius.dialog),
                border: Border.all(color: DashColors.slate, width: 1.5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: DashText.title(22, color: titleColor ?? DashColors.bone)),
                  const SizedBox(height: 10),
                  Text(body, style: DashText.caption(16, color: DashColors.bone)),
                  const SizedBox(height: 24),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (tertiaryLabel != null) ...[
                            TextButtonLink(tertiaryLabel!, onTap: onTertiary ?? () {}),
                            const SizedBox(width: 8),
                          ],
                          if (secondaryLabel != null) ...[
                            TextButtonLink(secondaryLabel!, onTap: onSecondary ?? () {}),
                            const SizedBox(width: 8),
                          ],
                          PrimaryButton(primaryLabel, onTap: onPrimary, color: primaryColor ?? DashColors.bone),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String formatTime(TimeOfDay t, {bool use24Hour = true}) => formatTimeOfDay(t, use24Hour: use24Hour);

/// Half-hour steps with +/- controls; the head unit has no system picker.
class TimeStepField extends ConsumerWidget {
  const TimeStepField({super.key, required this.label, required this.value, required this.onChanged});
  final String label;
  final TimeOfDay value;
  final ValueChanged<TimeOfDay> onChanged;

  void _step(int minutes) {
    final total = (value.hour * 60 + value.minute + minutes + 1440) % 1440;
    onChanged(TimeOfDay(hour: total ~/ 60, minute: total % 60));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: DashText.caption(14)),
        const SizedBox(height: 6),
        Row(
          children: [
            StepButton(icon: Icons.remove_rounded, onTap: () => _step(-30)),
            SizedBox(
              width: 88,
              child: Text(formatTime(value, use24Hour: ref.watch(use24HourProvider)), style: DashText.value(22), textAlign: TextAlign.center),
            ),
            StepButton(icon: Icons.add_rounded, onTap: () => _step(30)),
          ],
        ),
      ],
    );
  }
}

class StepButton extends StatelessWidget {
  const StepButton({super.key, required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Container(
          width: DashTouch.min,
          height: DashTouch.min,
          decoration: BoxDecoration(shape: BoxShape.circle, color: DashColors.slate),
          child: Icon(icon, size: 26, color: DashColors.bone),
        ),
      );
}

/// Back control for sub-screens: a 36px arrow on a faint disc so it reads
/// as a button at a glance, inside the 56px touch floor. Disabled while an
/// operation must not be interrupted (an OTA install).
class BackArrow extends StatelessWidget {
  const BackArrow({
    super.key,
    required this.onTap,
    this.size = DashTouch.min,
    this.width,
    this.iconSize = 36,
    this.discSize,
    this.alignment = Alignment.center,
    this.color,
  });
  final VoidCallback? onTap;

  /// Hit area height; also the width unless [width] is given.
  final double size;
  final double? width;
  final double iconSize;

  /// Disc diameter; defaults to the hit area less a small inset.
  final double? discSize;

  /// Where the disc sits inside the hit area.
  final Alignment alignment;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled
          ? () {
              HapticFeedback.lightImpact();
              onTap!();
            }
          : null,
      child: SizedBox(
        width: width ?? size,
        height: size,
        child: Align(
          alignment: alignment,
          child: Container(
            width: discSize ?? size - 8,
            height: discSize ?? size - 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: DashColors.slate.withValues(alpha: enabled ? 0.6 : 0.3)),
            child: Icon(Icons.arrow_back_rounded, size: iconSize, color: color ?? (enabled ? DashColors.bone : DashColors.ash)),
          ),
        ),
      ),
    );
  }
}

/// "Report Issue", wherever it is offered: opens a QR code the rider scans
/// with a phone to file the issue (`QrCardDialog`). A web address in a
/// message is not something anyone can follow from a scooter.
class ReportIssueButton extends ConsumerWidget {
  const ReportIssueButton({super.key, required this.from});

  static const label = 'Report Issue';

  /// Where it was tapped, for the log.
  final String from;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PrimaryButton(
        label,
        onTap: () => ref.read(qrCardProvider.notifier).reportIssue(from: from),
      );
}
