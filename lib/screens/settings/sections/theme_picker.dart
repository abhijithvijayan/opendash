import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/theme_state.dart';
import '../../../theme/colors.dart';
import '../../../theme/dash_theme.dart';
import '../../../theme/typography.dart';
import '../../../theme/tokens.dart';

/// Three built-in theme cards with a miniature of the dial.
class ThemeCards extends ConsumerWidget {
  const ThemeCards({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(themeProvider);
    return Row(
      children: [
        for (final t in DashTheme.builtIn) ...[
          GestureDetector(
            key: ValueKey('theme-${t.name.toLowerCase()}'),
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.lightImpact();
              ref.read(themeProvider.notifier).setTheme(t);
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedContainer(
                  duration: DashMotion.fast,
                  width: 190,
                  height: 114,
                  decoration: BoxDecoration(
                    color: t.ink,
                    borderRadius: BorderRadius.circular(DashRadius.card),
                    border: Border.all(
                      color: current.name == t.name ? DashColors.bone : DashColors.slate,
                      width: current.name == t.name ? 2 : 1.5,
                    ),
                  ),
                  child: CustomPaint(painter: _PreviewPainter(t)),
                ),
                const SizedBox(height: 8),
                Text(t.name, style: DashText.caption(16, color: current.name == t.name ? DashColors.bone : DashColors.ash)),
              ],
            ),
          ),
          if (t != DashTheme.builtIn.last) const SizedBox(width: 14),
        ],
      ],
    );
  }
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.t);
  final DashTheme t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * 0.62);
    final rect = Rect.fromCircle(center: c, radius: size.height * 0.42);
    canvas.drawArc(rect, math.pi * 0.83, math.pi * 1.34, false, Paint()..color = t.slate..style = PaintingStyle.stroke..strokeWidth = 2);
    canvas.drawArc(rect, math.pi * 0.83, math.pi * 0.8, false, Paint()..color = t.bone..style = PaintingStyle.stroke..strokeWidth = 4..strokeCap = StrokeCap.round);
    final dots = [t.eco, t.normal, t.sport, t.hyper];
    for (var i = 0; i < dots.length; i++) {
      canvas.drawCircle(Offset(size.width * 0.5 + (i - 1.5) * 18, size.height * 0.84), 4, Paint()..color = dots[i]);
    }
  }

  @override
  bool shouldRepaint(_PreviewPainter old) => old.t != t;
}

/// Six mode circles; tapping one reveals the preset grid beneath.
class AccentPicker extends ConsumerStatefulWidget {
  const AccentPicker({super.key});

  @override
  ConsumerState<AccentPicker> createState() => _AccentPickerState();
}

class _AccentPickerState extends ConsumerState<AccentPicker> {
  String? _editing;

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (final mode in DashTheme.accentModes) ...[
              GestureDetector(
                key: ValueKey('accent-$mode'),
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _editing = _editing == mode ? null : mode);
                },
                child: Column(
                  children: [
                    AnimatedContainer(
                      duration: DashMotion.fast,
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.accentNamed(mode),
                        border: Border.all(color: _editing == mode ? DashColors.bone : Colors.transparent, width: 2),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(mode, style: DashText.mode(DashColors.ash, size: 9)),
                  ],
                ),
              ),
              const SizedBox(width: 22),
            ],
          ],
        ),
        AnimatedSize(
          duration: DashMotion.fast,
          curve: DashMotion.valueCurve,
          alignment: Alignment.topLeft,
          child: _editing == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Container(
                    key: const ValueKey('accent-popover'),
                    padding: const EdgeInsets.all(DashSpace.cardPad),
                    decoration: BoxDecoration(
                      color: DashColors.inkLift,
                      borderRadius: BorderRadius.circular(DashRadius.card),
                      border: Border.all(color: DashColors.slate, width: 1.5),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('$_editing accent', style: DashText.caption(14)),
                        const SizedBox(height: 12),
                        for (var row = 0; row < 2; row++)
                          Padding(
                            padding: EdgeInsets.only(bottom: row == 0 ? 12 : 0),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (var i = row * 4; i < row * 4 + 4; i++) ...[
                                  GestureDetector(
                                    key: ValueKey('preset-$i'),
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      HapticFeedback.lightImpact();
                                      ref.read(themeProvider.notifier).setAccent(_editing!, accentPresets[i]);
                                    },
                                    child: Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: accentPresets[i],
                                        border: Border.all(
                                          color: theme.accentNamed(_editing!) == accentPresets[i] ? DashColors.bone : Colors.transparent,
                                          width: 2,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (i % 4 != 3) const SizedBox(width: 16),
                                ],
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
