import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../state/crash_recovery.dart';
import '../../state/error_state.dart';
import '../../providers/mock_provider.dart';
import '../status_bar/status_icons.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../screens/settings/widgets.dart';

/// Replaces the red error screen with escape hatches that get the rider
/// home: retry, report, safe mode, or the stock dashboard.
class ErrorOverlay extends ConsumerWidget {
  const ErrorOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = ref.watch(appErrorProvider);
    final minimized = ref.watch(errorMinimizedProvider);
    if (error == null || minimized) return const SizedBox.shrink();
    final n = ref.read(appErrorProvider.notifier);
    final recovery = ref.read(crashRecoveryProvider.notifier);
    // Don't offer the boot button while locked.
    final locked = ref.watch(vehicleProvider.select((v) => v.locked));

    return Positioned.fill(
      key: const ValueKey('error-overlay'),
      child: ColoredBox(
        color: DashColors.ink,
        child: Stack(
          children: [
            Center(
              child: SizedBox(
                width: 720,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline_rounded, size: 48, color: DashColors.warning),
                    const SizedBox(height: 16),
                    Text('Something went wrong', style: DashText.title(24, color: DashColors.warning)),
                    const SizedBox(height: 10),
                    Text(
                      error,
                      key: const ValueKey('error-summary'),
                      style: DashText.caption(14),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 36),
                    Wrap(
                      spacing: 16,
                      runSpacing: 16,
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.start,
                      children: [
                        PrimaryButton('Retry', key: const ValueKey('error-retry'), onTap: n.retry),
                        const ReportIssueButton(key: ValueKey('error-report'), from: 'error'),
                        PrimaryButton('Safe Mode', key: const ValueKey('error-safe-mode'), onTap: () {
                          n.dismiss();
                          recovery.enterSafeMode();
                        }),
                        PrimaryButton('Launch Stock Dashboard', key: const ValueKey('error-stock'), onTap: recovery.launchStockApp),
                        if (!locked)
                          PrimaryButton(
                            'Open Trunk',
                            key: const ValueKey('error-trunk'),
                            icon: TrunkOpenIcon(color: DashColors.bone),
                            onTap: ref.read(vehicleProvider.notifier).openTrunk,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Text('$appName v$appVersion', key: const ValueKey('error-version'), style: DashText.caption(13), textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}
