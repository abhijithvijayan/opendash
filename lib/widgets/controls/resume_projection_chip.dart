import 'trunk_button.dart';
import '../../services/analytics_logger.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/apps_state.dart';
import '../../theme/colors.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';

/// After a red alert pulled the rider out of Android Auto / CarPlay: one tap
/// back to navigation. Shown above the trunk button (which is hidden while
/// riding). A sideways swipe dismisses it.
class ResumeProjectionChip extends ConsumerWidget {
  const ResumeProjectionChip({super.key, required this.name});
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Dismissible(
        // A sideways swipe puts it away: the rider may be done with the app.
        key: ValueKey('resume-projection-swipe-$name'),
        onDismissed: (_) {
          uiSwipe('resume-projection-dismiss');
          ref.read(projectionResumeProvider.notifier).clear();
        },
        child: GestureDetector(
        key: const ValueKey('resume-projection'),
        behavior: HitTestBehavior.opaque,
        onTap: () => ref.read(appManagerProvider.notifier).resumeProjection(),
        child: Container(
          // As wide as the boot button under it, so the two read as one
          // column: "Back to CarPlay" spelled out was half as wide again.
          height: 60,
          width: TrunkButton.width,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: DashColors.inkLift,
            borderRadius: BorderRadius.circular(DashRadius.button),
            border: Border.all(color: DashColors.slate, width: 1.5),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.arrow_back_rounded, size: 22, color: DashColors.bone),
                const SizedBox(width: 8),
                Text(name, style: DashText.value(20)),
              ],
            ),
          ),
        ),
        ),
      );
}
