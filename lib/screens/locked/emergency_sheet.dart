import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/vehicle_data.dart' show emergencyNumber;
import '../../providers/mock_provider.dart';
import '../../state/profile_state.dart';
import '../../state/toast_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';

/// Owner contact card for whoever finds the locked scooter. Values come from
/// settings later; these are placeholders.
class EmergencySheet extends ConsumerWidget {
  const EmergencySheet({super.key, required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final support = ref.watch(vehicleProvider.select((v) => v.customerSupportNumber));
    // The head unit shows the scooter owner's real name or no owner row;
    // the contact and blood-type placeholders pointed at a setting that does
    // not exist.
    final live = useAidlVehicle;
    final owner = live ? ref.watch(profileProvider.select((p) => p.name)) : 'Owner';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onClose,
      child: ColoredBox(
        color: DashColors.ink.withValues(alpha: DashScrim.backdrop),
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: 520,
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
                  Text('Emergency', style: DashText.title(32, color: DashColors.critical)),
                  const SizedBox(height: 6),
                  Text('If you found this scooter, contact the owner.', style: DashText.caption(17)),
                  const SizedBox(height: 28),
                  if (owner.isNotEmpty) _Field(key: const ValueKey('emergency-owner'), label: 'Owner', value: owner),
                  if (!live) ...const [
                    _Field(label: 'Emergency contact', value: 'Add in settings'),
                    _Field(label: 'Blood type', value: 'Add in settings'),
                  ],
                  const _Field(label: 'Emergency number', value: emergencyNumber),
                  _Field(
                    key: const ValueKey('support-number'),
                    label: 'Roadside Support',
                    value: support,
                    onTap: () {
                      HapticFeedback.lightImpact();
                      ref.read(toastProvider.notifier).show('Roadside Support: $support');
                    },
                  ),
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: onClose,
                      child: Container(
                        height: 60,
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        decoration: BoxDecoration(
                          border: Border.all(color: DashColors.bone, width: 1.5),
                          borderRadius: BorderRadius.circular(DashRadius.button),
                        ),
                        child: Center(widthFactor: 1, child: Text('Close', style: DashText.value(20))),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({super.key, required this.label, required this.value, this.onTap});
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: DashTouch.min,
        child: Row(
          children: [
            SizedBox(width: 200, child: Text(label, style: DashText.caption(18))),
            Expanded(child: Text(value, style: DashText.value(24, color: onTap == null ? null : DashColors.normal))),
          ],
        ),
      ),
    );
  }
}
