import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../state/apps_state.dart';
import '../../state/riding_lockout.dart';
import '../../state/theme_state.dart';
import '../../theme/tokens.dart';

/// The dashboard's bottom edge: an upward flick opens Apps, as the bottom
/// edge opens the app drawer on a phone. Only upward vertical drags are
/// taken, so taps on the trip strip underneath (its reset button) still
/// land. Apps refuses the swipe while riding or locked, as it refuses its
/// icon.
class AppsSwipeZone extends ConsumerWidget {
  const AppsSwipeZone({super.key});

  static const height = 28.0;

  /// Up, in logical pixels per second.
  static const flick = 200.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(uiThemeProvider);
    final hint = ref.watch(appsSwipeCountProvider) < AppsSwipeCount.hintUntil &&
        !ref.watch(ridingLockoutProvider) &&
        !ref.watch(vehicleProvider.select((v) => v.locked));
    return SizedBox(
      height: height,
      child: GestureDetector(
        key: const ValueKey('apps-swipe-zone'),
        behavior: HitTestBehavior.translucent,
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0) < -flick) {
            HapticFeedback.lightImpact();
            ref.read(appLauncherOpenProvider.notifier).openBySwipe();
          }
        },
        child: Align(
          alignment: Alignment.bottomCenter,
          child: AnimatedOpacity(
            duration: DashMotion.normal,
            opacity: hint ? 1 : 0,
            child: Container(
              key: const ValueKey('apps-swipe-grabber'),
              width: 72,
              height: 4,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(color: theme.slate, borderRadius: BorderRadius.circular(2)),
            ),
          ),
        ),
      ),
    );
  }
}
