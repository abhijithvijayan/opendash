import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../state/riding_lockout.dart';
import '../../state/theme_state.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import '../status_bar/status_icons.dart';
import '../../services/analytics_logger.dart';

/// The S1 Pro has no boot release lever, so the dashboard carries one: a
/// pill in the lower left the rider can reach the moment they stop. Gone
/// while moving; the control panel keeps its own copy.
class DashboardTrunkButton extends ConsumerWidget {
  const DashboardTrunkButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final riding = ref.watch(ridingLockoutProvider);
    final known = ref.watch(vehicleProvider.select((v) => v.trunkStateKnown));
    final open = ref.watch(vehicleProvider.select((v) => v.trunkOpen && v.trunkStateKnown));
    return AnimatedSwitcher(
      duration: DashMotion.normal,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween(begin: const Offset(-0.2, 0), end: Offset.zero).animate(anim),
          child: child,
        ),
      ),
      child: riding
          ? const SizedBox.shrink(key: ValueKey('dash-trunk-off'))
          : TrunkButton(
              key: const ValueKey('dash-trunk'),
              open: open,
              enabled: known,
              onTap: () {
                uiTap('ctl-trunk', {'open': open});
                ref.read(vehicleProvider.notifier).toggleTrunk();
              },
            ),
    );
  }
}

class TrunkButton extends ConsumerStatefulWidget {
  const TrunkButton({super.key, required this.open, required this.enabled, required this.onTap});
  final bool open;
  final bool enabled;
  final VoidCallback onTap;

  static const width = 128.0;
  static const height = 96.0;

  @override
  ConsumerState<TrunkButton> createState() => _TrunkButtonState();
}

class _TrunkButtonState extends ConsumerState<TrunkButton> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(uiThemeProvider);
    final accent = widget.open ? theme.warning : theme.bone;
    final fill = widget.open
        ? theme.warning.withValues(alpha: _down ? 0.28 : 0.16)
        : theme.slate.withValues(alpha: _down ? 0.95 : 0.6);
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
          child: AnimatedScale(
            scale: _down ? 0.96 : 1,
            duration: DashMotion.fast,
            child: AnimatedContainer(
              duration: DashMotion.fast,
              width: TrunkButton.width,
              height: TrunkButton.height,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(DashRadius.button),
                border: Border.all(color: widget.open ? theme.warning : theme.slate, width: 1.5),
                boxShadow: widget.open ? [BoxShadow(color: theme.warning.withValues(alpha: 0.35), blurRadius: 14)] : null,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Transform.scale(scale: 1.35, child: TrunkOpenIcon(color: accent)),
                  const SizedBox(height: 14),
                  Text(widget.open ? 'OPEN' : 'TRUNK', style: DashText.mode(accent, size: 15)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
