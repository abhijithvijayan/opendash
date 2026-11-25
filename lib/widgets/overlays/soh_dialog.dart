import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../state/settings_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../screens/settings/widgets.dart';
import '../../theme/tokens.dart';

/// The schema only says whether the pack is healthy, so that is all we show.
/// Null = SOH not yet reported by the BMS.
String healthLabel(bool? good) => good == null ? '—' : (good ? 'Good' : 'Degraded');

Color healthColor(bool? good) =>
    good == null ? DashColors.ash : (good ? DashColors.eco : DashColors.warning);

const sohTips = [
  'Keep battery between 20-80% for daily use',
  'Charge to 100% once a month for calibration',
  'Avoid charging in extreme temperatures',
  'Store at 50-60% if not riding for weeks',
];

/// Battery health card over a dimmed backdrop.
class SohDialog extends ConsumerWidget {
  const SohDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(sohPopupOpenProvider)) return const SizedBox.shrink();
    final close = ref.read(sohPopupOpenProvider.notifier).close;
    final (good, description) = ref.watch(vehicleProvider.select(
        (v) => (v.batteryHealthKnown ? v.batteryHealthGood : null, v.batterySohDescription)));
    return Positioned.fill(
      key: const ValueKey('soh-popup'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: close,
        child: ColoredBox(
          color: DashColors.ink.withValues(alpha: DashScrim.backdrop),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: Container(
                width: 460,
                padding: const EdgeInsets.all(DashSpace.dialogPad),
                decoration: BoxDecoration(
                  color: DashColors.inkLift,
                  borderRadius: BorderRadius.circular(DashRadius.dialog),
                  border: Border.all(color: DashColors.slate, width: 1.5),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Battery Health', style: DashText.title(22)),
                    const SizedBox(height: 12),
                    Center(child: Text(healthLabel(good), key: const ValueKey('soh-value'), style: DashText.value(40, color: healthColor(good)))),
                    const SizedBox(height: 20),
                    Text('Best practices', style: DashText.caption(14)),
                    const SizedBox(height: 8),
                    for (final tip in sohTips)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('•  ', style: DashText.caption(15)),
                            Expanded(child: Text(tip, style: DashText.caption(15))),
                          ],
                        ),
                      ),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(description, key: const ValueKey('soh-description'), style: DashText.caption(15, color: DashColors.warning)),
                    ],
                    const SizedBox(height: 20),
                    Align(
                      alignment: Alignment.centerRight,
                      child: PrimaryButton('Got it', key: const ValueKey('soh-done'), onTap: close),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
