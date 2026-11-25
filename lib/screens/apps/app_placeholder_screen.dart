import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/apps_state.dart';
import '../../state/theme_state.dart';
import '../../theme/typography.dart';
import '../../widgets/overlays/nav_overlay.dart';
import '../../theme/tokens.dart';
import 'app_icons.dart';

/// Mock-mode stand-in for a running app. On device the real activity
/// takes over; in web/desktop dev this shows instead.
class AppPlaceholderScreen extends ConsumerWidget {
  const AppPlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final app = ref.watch(mockAppProvider);
    final theme = ref.watch(uiThemeProvider);
    if (app == null) return const SizedBox.shrink();
    return Positioned.fill(
      key: const ValueKey('app-placeholder'),
      child: ColoredBox(
        color: theme.ink,
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(appId: app.id, color: theme.bone, size: 96),
                  const SizedBox(height: 20),
                  Text(app.name, style: DashText.title(24, color: theme.bone)),
                  const SizedBox(height: 6),
                  Text(
                    'Running in the background. Press Home to return.',
                    style: DashText.caption(16, color: theme.ash),
                  ),
                ],
              ),
            ),
            const Positioned(left: 16, top: 16, child: NavOverlay()),
            Positioned(
              left: 0,
              right: 0,
              bottom: 40,
              child: Center(
                child: GestureDetector(
                  key: const ValueKey('app-return'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    ref.read(mockAppProvider.notifier).close();
                  },
                  child: Container(
                    width: 200,
                    height: 48,
                    decoration: BoxDecoration(color: theme.slate, borderRadius: BorderRadius.circular(DashRadius.card)),
                    child: Center(child: Text('Return to Dashboard', style: DashText.value(16, color: theme.bone))),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
