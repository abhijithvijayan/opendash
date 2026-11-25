import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../state/toast_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';

/// Pill just above the trip strip, in a lane no dashboard element uses.
/// Moves up when the nav bar is showing. Never blocks touch.
class ToastOverlay extends ConsumerWidget {
  const ToastOverlay({super.key});

  static const top = 636.0;
  static const topWithNav = 572.0;

  static IconData iconFor(ToastType type) => switch (type) {
        ToastType.info => Icons.info_outline_rounded,
        ToastType.success => Icons.check_circle_outline_rounded,
        ToastType.warning => Icons.warning_amber_rounded,
        ToastType.error => Icons.error_outline_rounded,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final toast = ref.watch(toastProvider);
    final navActive = ref.watch(vehicleProvider.select((v) => v.navActive));
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.topCenter,
          child: AnimatedPadding(
            duration: DashMotion.fast,
            padding: EdgeInsets.only(top: navActive ? topWithNav : top),
            child: AnimatedSwitcher(
              duration: DashMotion.fast,
              reverseDuration: DashMotion.fast,
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.5), end: Offset.zero).animate(anim),
                  child: child,
                ),
              ),
              child: toast == null
                  ? const SizedBox.shrink()
                  : ToastPill(key: ValueKey(toast.id), toast: toast),
            ),
          ),
        ),
      ),
    );
  }
}

class ToastPill extends StatelessWidget {
  const ToastPill({super.key, required this.toast});
  final ToastData toast;

  @override
  Widget build(BuildContext context) {
    final color = toast.type.color;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 600, minHeight: 52, maxHeight: 52),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(DashRadius.button),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: DashColors.inkLift.withValues(alpha: DashScrim.glass),
            border: Border.all(color: DashColors.slate, width: 1),
            borderRadius: BorderRadius.circular(DashRadius.button),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 4, height: 52, color: color),
              const SizedBox(width: 16),
              Icon(ToastOverlay.iconFor(toast.type), size: 20, color: color),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  toast.message,
                  style: DashText.caption(16, color: DashColors.bone),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 24),
            ],
          ),
        ),
      ),
    );
  }
}
