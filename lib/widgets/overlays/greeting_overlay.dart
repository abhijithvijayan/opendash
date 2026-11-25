import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/greeting_state.dart';
import '../../state/theme_state.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';

/// Welcome line above the trip strip. Fades in, holds, fades out; never
/// takes touches.
class GreetingOverlay extends ConsumerWidget {
  const GreetingOverlay({super.key});

  static const top = 620.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = ref.watch(greetingProvider);
    final theme = ref.watch(uiThemeProvider);
    return Positioned(
      left: 0,
      right: 0,
      top: top,
      child: IgnorePointer(
        child: AnimatedSwitcher(
          duration: DashMotion.normal,
          reverseDuration: DashMotion.slow,
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: text == null
              ? const SizedBox.shrink()
              : Text(
                  text,
                  key: const ValueKey('greeting'),
                  style: DashText.title(24, color: theme.bone),
                  textAlign: TextAlign.center,
                ),
        ),
      ),
    );
  }
}
