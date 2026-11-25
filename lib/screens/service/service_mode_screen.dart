import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/crash_recovery.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';
import '../../widgets/overlays/alert_overlay.dart';

/// Technician overlay reached by triple-tapping the About title.
class ServiceModeScreen extends ConsumerWidget {
  const ServiceModeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(serviceModeOpenProvider);
    if (!open) return const SizedBox.shrink();
    final n = ref.read(serviceModeOpenProvider.notifier);
    // The alert banner draws over this screen; keep the title clear of it.
    final shift = ref.watch(alertBannerShiftProvider);
    return Positioned.fill(
      key: const ValueKey('service-mode'),
      child: Container(
        decoration: BoxDecoration(
          color: DashColors.ink,
          border: Border(
            top: BorderSide(color: DashColors.warning, width: 2),
            bottom: BorderSide(color: DashColors.warning, width: 2),
          ),
        ),
        padding: EdgeInsets.fromLTRB(240, DashSpace.headerTop + shift, 240, DashSpace.bodyBottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Service Mode', style: DashText.title(32, color: DashColors.warning)),
            const SizedBox(height: 4),
            Text('For authorized technicians only', style: DashText.caption(16)),
            const SizedBox(height: 32),
            for (final (label, package) in ServiceModeOpen.apps)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: GestureDetector(
                  key: ValueKey('service-$package'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticFeedback.lightImpact();
                    n.launch(package);
                  },
                  child: Container(
                    height: 64,
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    decoration: BoxDecoration(color: DashColors.slate, borderRadius: BorderRadius.circular(DashRadius.card)),
                    child: Row(
                      children: [
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(label, style: DashText.value(19)),
                            Text(package, style: DashText.caption(13)),
                          ],
                        ),
                        const Spacer(),
                        Icon(Icons.launch_rounded, size: 22, color: DashColors.ash),
                      ],
                    ),
                  ),
                ),
              ),
            const Spacer(),
            Center(
              child: GestureDetector(
                key: const ValueKey('service-exit'),
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.lightImpact();
                  n.close();
                },
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  decoration: BoxDecoration(
                    border: Border.all(color: DashColors.critical, width: 1.5),
                    borderRadius: BorderRadius.circular(DashRadius.button),
                  ),
                  child: Center(widthFactor: 1, child: Text('Exit Service Mode', style: DashText.value(18, color: DashColors.critical))),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
