import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../screens/settings/widgets.dart';
import '../../services/analytics_logger.dart';
import '../../state/firmware_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../ota/ota_progress_bar.dart';

/// Shown while HOTA reports a firmware install in progress, whatever the
/// firmware mode: the scooter restarts by itself when it finishes. OpenDash
/// did not start the install and cannot stop it. Opaque and full-screen,
/// under the safety overlays only.
class FirmwareInstallOverlay extends ConsumerWidget {
  const FirmwareInstallOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installing = ref.watch(firmwareProvider.select((f) => f.installing));
    if (!installing) return const SizedBox.shrink();
    final progress = ref.watch(firmwareProvider.select((f) => f.installProgress));
    return Positioned.fill(
      child: ColoredBox(
        key: const ValueKey('fw-installing'),
        color: DashColors.ink,
        child: Center(
          child: SizedBox(
            width: 640,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Scooter firmware is installing.', style: DashText.title(34), textAlign: TextAlign.center),
                const SizedBox(height: 10),
                Text('Do not ride.', style: DashText.title(34, color: DashColors.warning), textAlign: TextAlign.center),
                const SizedBox(height: 36),
                OtaProgressBar(progress: progress, color: DashColors.warning, active: true),
                const SizedBox(height: 12),
                Text('$progress%', style: DashText.value(22)),
                const SizedBox(height: 24),
                Text(
                  'The scooter restarts by itself when the install finishes.',
                  style: DashText.caption(18),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Once, at the next park after the head unit's software has changed.
class FirmwareChangeDialog extends ConsumerWidget {
  const FirmwareChangeDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final change = ref.watch(firmwareChangeNoticeProvider);
    if (change == null) return const SizedBox.shrink();
    final n = ref.read(firmwareProvider.notifier);
    return Positioned.fill(
      key: const ValueKey('fw-changed'),
      child: ConfirmCard(
        width: 620,
        title: 'The scooter\'s software changed',
        body:
            'The scooter\'s software changed from ${change.from} to ${change.to}. OpenDash has not been checked against it. If anything looks wrong, use the stock dashboard and check for an OpenDash update.',
        primaryLabel: 'Keep using OpenDash',
        onPrimary: () {
          uiTap('fw-changed-keep');
          n.answerChange(stock: false);
        },
        secondaryLabel: 'Open the stock dashboard',
        onSecondary: () {
          uiTap('fw-changed-stock');
          n.answerChange(stock: true);
        },
      ),
    );
  }
}
