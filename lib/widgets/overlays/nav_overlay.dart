import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../state/format_settings.dart';
import '../../state/theme_state.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';

/// Speed and battery pill that floats over full-screen apps.
class NavOverlay extends ConsumerWidget {
  const NavOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speed = ref.watch(vehicleProvider.select((v) => v.speed));
    final soc = ref.watch(vehicleProvider.select((v) => v.socKnown ? v.batterySoc : null));
    final theme = ref.watch(uiThemeProvider);
    final useMiles = ref.watch(useMilesProvider);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: DashMotion.fast,
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      child: Container(
        key: const ValueKey('nav-overlay'),
        height: 44,
        constraints: const BoxConstraints(minWidth: 140),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: theme.ink.withValues(alpha: DashScrim.backdrop),
          borderRadius: BorderRadius.circular(DashRadius.button),
          border: Border.all(color: theme.slate, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('${toDisplayDistance(speed, useMiles)}', style: DashText.value(20, color: theme.bone)),
            const SizedBox(width: 4),
            Text(speedUnit(useMiles), style: DashText.caption(14, color: theme.ash)),
            const SizedBox(width: 16),
            Icon(Icons.battery_full_rounded, size: 16, color: theme.ash),
            const SizedBox(width: 4),
            Text(soc == null ? '—' : '$soc%', key: const ValueKey('nav-battery'), style: DashText.value(16, color: theme.bone)),
          ],
        ),
      ),
    );
  }
}
