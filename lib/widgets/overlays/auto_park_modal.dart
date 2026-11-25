import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../screens/settings/widgets.dart';
import '../../state/safety_watchdog.dart';
import '../../theme/colors.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import '../../services/analytics_logger.dart';

/// Three states, driven by [SafetyWatchdogState.awaitingLock] +
/// [VehicleData.pendingLock] / [VehicleData.lockFailedAtMicros]:
///   * countdown: watchdog is armed; Keep riding visible, Lock_Now not sent.
///   * Locking…: watchdog fired, waiting for the vehicle echo. No buttons.
///   * Lock failed: the vehicle refused or didn't answer. Retry / Keep
///     riding; this state latches until the rider responds.
class AutoParkModal extends ConsumerStatefulWidget {
  const AutoParkModal({super.key});

  @override
  ConsumerState<AutoParkModal> createState() => _AutoParkModalState();
}

class _AutoParkModalState extends ConsumerState<AutoParkModal> {
  static void _buzz() => HapticFeedback.heavyImpact().catchError((_) {});

  @override
  void initState() {
    super.initState();
    if (ref.read(safetyWatchdogProvider).armed) _buzz();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(safetyWatchdogProvider.select((s) => s.armed), (_, armed) {
      if (armed) _buzz();
    });
    final watchdog = ref.watch(safetyWatchdogProvider);
    final pendingLock = ref.watch(vehicleProvider.select((v) => v.pendingLock != null));
    final lockFailed = ref.watch(vehicleProvider.select((v) => v.lockFailedAtMicros != null));

    if (!watchdog.armed && !watchdog.awaitingLock) return const SizedBox.shrink();

    final Widget body;
    if (watchdog.armed) {
      body = _countdown(watchdog.remainingSeconds);
    } else if (watchdog.awaitingLock && lockFailed) {
      body = _failed();
    } else if (watchdog.awaitingLock && pendingLock) {
      body = _locking();
    } else {
      // awaitingLock set but neither pending nor failed yet (fire → send
      // round-trip): show Locking… as the safer transition state.
      body = _locking();
    }

    return Positioned.fill(
      key: const ValueKey('auto-park-modal'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ColoredBox(
          color: DashColors.ink.withValues(alpha: DashScrim.backdrop),
          child: Center(
            child: Container(
              width: 520,
              padding: const EdgeInsets.all(DashSpace.dialogPad),
              decoration: BoxDecoration(
                color: DashColors.inkLift,
                borderRadius: BorderRadius.circular(DashRadius.card),
                border: Border.all(color: DashColors.critical, width: 1.5),
              ),
              child: body,
            ),
          ),
        ),
      ),
    );
  }

  Widget _countdown(int remaining) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Side stand is down', style: DashText.title(26, color: DashColors.bone)),
          const SizedBox(height: 12),
          Text(
            'Auto-locking in $remaining…',
            key: const ValueKey('auto-park-countdown'),
            style: DashText.value(40, color: DashColors.critical),
          ),
          const SizedBox(height: 24),
          Align(
            alignment: Alignment.centerRight,
            child: PrimaryButton(
              'Keep riding',
              key: const ValueKey('auto-park-keep-riding'),
              onTap: () {
                uiModalButton('auto_park', 'keep_riding');
                ref.read(safetyWatchdogProvider.notifier).cancel();
              },
            ),
          ),
        ],
      );

  Widget _locking() => Column(
        key: const ValueKey('auto-park-locking'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Locking…', style: DashText.title(26, color: DashColors.bone)),
          const SizedBox(height: 12),
          Text('Waiting for the scooter to confirm',
              style: DashText.caption(16, color: DashColors.bone)),
        ],
      );

  Widget _failed() => Column(
        key: const ValueKey('auto-park-failed'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Lock failed', style: DashText.title(26, color: DashColors.critical)),
          const SizedBox(height: 12),
          Text("The scooter didn't confirm the lock. Retry, or keep riding.",
              style: DashText.caption(16, color: DashColors.bone)),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              PrimaryButton(
                'Retry',
                key: const ValueKey('auto-park-retry'),
                onTap: () => ref.read(safetyWatchdogProvider.notifier).retryLock(),
              ),
              const SizedBox(width: 12),
              PrimaryButton(
                'Keep riding',
                key: const ValueKey('auto-park-keep-riding'),
                onTap: () => ref.read(safetyWatchdogProvider.notifier).keepRiding(),
              ),
            ],
          ),
        ],
      );
}
