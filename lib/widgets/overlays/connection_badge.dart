import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../state/screen_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';

/// Shown while HHMIS is unreachable. The last known data stays on screen
/// behind it; this only says that it may be stale. Once connected the badge
/// is unmounted entirely so its blink stops ticking.
class ConnectionBadge extends ConsumerWidget {
  const ConnectionBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Asleep, the data is quiet on purpose and the screen is black.
    final connected = ref.watch(vehicleProvider.select((v) => v.scooterAsleep || (v.hhmisConnected && !v.hhmisStale)));
    final booted = ref.watch(sessionProvider.select((s) => s.booted));
    return IgnorePointer(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 22),
          child: AnimatedSwitcher(
            duration: DashMotion.normal,
            switchInCurve: DashMotion.valueCurve,
            switchOutCurve: DashMotion.valueCurve,
            child: connected
                ? const SizedBox.shrink()
                : Row(
                    key: const ValueKey('connection-badge'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _Blink(),
                      const SizedBox(width: 10),
                      Text(
                        booted ? 'Reconnecting…' : 'Connecting…',
                        style: DashText.caption(18, color: DashColors.ash),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _Blink extends StatefulWidget {
  const _Blink();

  @override
  State<_Blink> createState() => _BlinkState();
}

class _BlinkState extends State<_Blink> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: DashColors.warning.withValues(alpha: 0.3 + 0.7 * _c.value),
        ),
      ),
    );
  }
}
