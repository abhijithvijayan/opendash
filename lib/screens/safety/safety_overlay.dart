import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/safety_screen.dart';
import '../../theme/colors.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import 'accident_screen.dart';
import 'alarm_screen.dart';
import 'fall_screen.dart';

/// The accident, fall and alarm screens: opaque, above every other overlay
/// (see the stack order in `main.dart`).
class SafetyOverlay extends ConsumerWidget {
  const SafetyOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screen = ref.watch(safetyScreenProvider.select((s) => s.screen));
    return switch (screen) {
      null => const SizedBox.shrink(),
      SafetyScreen.accident => const AccidentScreen(key: ValueKey('safety-accident')),
      SafetyScreen.fall => const FallScreen(key: ValueKey('safety-fall')),
      SafetyScreen.alarm => const AlarmScreen(key: ValueKey('safety-alarm')),
    };
  }
}

/// The shared layout: a red frame that breathes, the headline at the left
/// gutter, the actions along the bottom at glove size.
class SafetyScaffold extends StatefulWidget {
  const SafetyScaffold({
    super.key,
    required this.kicker,
    required this.title,
    required this.lines,
    this.note,
    this.actions = const [],
  });

  final String kicker;
  final String title;
  final List<String> lines;
  final String? note;
  final List<Widget> actions;

  @override
  State<SafetyScaffold> createState() => _SafetyScaffoldState();
}

class _SafetyScaffoldState extends State<SafetyScaffold> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final critical = DashColors.critical;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ColoredBox(
          color: DashColors.ink,
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: FadeTransition(
                  opacity: Tween(begin: 0.35, end: 1.0).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: critical, width: 8),
                      gradient: RadialGradient(
                        center: const Alignment(-0.9, -0.8),
                        radius: 1.3,
                        colors: [critical.withValues(alpha: 0.22), critical.withValues(alpha: 0)],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(DashSpace.gutter, 96, DashSpace.gutter, 64),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.kicker, style: DashText.value(24, color: critical).copyWith(letterSpacing: 3)),
                    const SizedBox(height: 20),
                    Text(widget.title, style: DashText.title(84, color: DashColors.bone).copyWith(height: 1.05)),
                    const SizedBox(height: 28),
                    for (final line in widget.lines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(line, style: DashText.caption(30, color: DashColors.bone)),
                      ),
                    if (widget.note != null) ...[
                      const SizedBox(height: 12),
                      Text(widget.note!, style: DashText.caption(22, color: DashColors.ash)),
                    ],
                    const Spacer(),
                    if (widget.actions.isNotEmpty)
                      Row(
                        children: [
                          for (final (i, action) in widget.actions.indexed) ...[
                            if (i > 0) const SizedBox(width: 24),
                            Expanded(child: action),
                          ],
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A [DashTouch.critical]-tall action. [filled] is the one to reach for.
class SafetyButton extends StatelessWidget {
  const SafetyButton(this.label, {super.key, required this.onTap, this.filled = false, this.enabled = true});

  final String label;
  final VoidCallback onTap;
  final bool filled;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final fill = filled ? DashColors.critical : DashColors.slate;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled
          ? () {
              HapticFeedback.heavyImpact().catchError((_) {});
              onTap();
            }
          : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: Container(
          height: DashTouch.critical,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(DashRadius.card)),
          child: Text(label, style: DashText.value(32, color: filled ? DashColors.ink : DashColors.bone)),
        ),
      ),
    );
  }
}
