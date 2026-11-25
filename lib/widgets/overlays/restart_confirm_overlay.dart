import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../screens/settings/widgets.dart';
import '../../services/analytics_logger.dart';
import '../../state/scooter_restart.dart';
import '../../theme/colors.dart';

/// The consent step after the passcode. Restart only on the button; the
/// countdown only ever cancels.
class RestartConfirmOverlay extends ConsumerWidget {
  const RestartConfirmOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(scooterRestartProvider);
    if (pending == null) return const SizedBox.shrink();
    final n = ref.read(scooterRestartProvider.notifier);
    final body = pending.liveData
        ? 'The scooter switches off and comes back in about a minute.'
        : "No data from the scooter, so the dashboard can't check that it is parked and unplugged. "
            'Only restart if it is.';
    return Positioned.fill(
      key: const ValueKey('restart-confirm'),
      child: ConfirmCard(
        width: 460,
        title: 'Restart the scooter?',
        titleColor: DashColors.critical,
        body: '$body\n\nCancels in ${pending.secondsLeft} s.',
        primaryLabel: 'Restart',
        primaryColor: DashColors.critical,
        onPrimary: () {
          uiTap('restart-confirm-restart');
          n.confirm();
        },
        secondaryLabel: 'Cancel',
        onSecondary: () {
          uiTap('restart-confirm-cancel');
          n.cancel();
        },
      ),
    );
  }
}
