import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../state/format_settings.dart';
import '../../state/riding_lockout.dart';
import '../../state/settings_state.dart';
import '../../state/theme_state.dart';
import '../../theme/colors.dart';
import '../../theme/dash_theme.dart';
import '../../theme/typography.dart';
import '../../util/format.dart';
import '../media/now_playing_bar.dart';
import '../../theme/tokens.dart';

class TripStrip extends ConsumerWidget {
  const TripStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final odo = ref.watch(vehicleProvider.select((v) => v.odometer));
    final trip = ref.watch(vehicleProvider.select((v) => v.tripMeter));
    final media = ref.watch(vehicleProvider.select((v) => v.mediaVisible));
    final riding = ref.watch(ridingLockoutProvider);
    final theme = ref.watch(uiThemeProvider);
    final useMiles = ref.watch(useMilesProvider);
    final unit = distanceUnit(useMiles);

    return SizedBox(
      height: 72,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(width: 72),
          _Reading(value: '${groupThousands(toDisplayDistance(odo, useMiles))} $unit', caption: 'odometer', theme: theme),
          const SizedBox(width: 56),
          _Reading(value: '${toDisplayDistanceD(trip, useMiles).toStringAsFixed(1)} $unit', caption: 'trip', theme: theme),
          if (!riding)
            GestureDetector(
              key: const ValueKey('trip-reset'),
              behavior: HitTestBehavior.opaque,
              onTap: ref.read(tripResetProvider.notifier).open,
              child: SizedBox(
                width: DashTouch.min,
                height: DashTouch.min,
                child: Icon(Icons.refresh_rounded, size: 22, color: DashColors.ash),
              ),
            ),
          const SizedBox(width: 24),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: AnimatedSwitcher(
                duration: DashMotion.normal,
                child: media ? const NowPlayingBar(key: ValueKey('media')) : const SizedBox.shrink(),
              ),
            ),
          ),
          const SizedBox(width: 72),
        ],
      ),
    );
  }
}

class _Reading extends StatelessWidget {
  const _Reading({required this.value, required this.caption, required this.theme});
  final String value;
  final String caption;
  final DashTheme theme;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(value, style: DashText.value(26, color: theme.bone)),
        const SizedBox(width: 10),
        Text(caption, style: DashText.caption(18, color: theme.ash)),
      ],
    );
  }
}
