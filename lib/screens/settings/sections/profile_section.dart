import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/mock_provider.dart';
import '../../../state/profile_state.dart';
import '../../../theme/colors.dart';
import '../../../theme/typography.dart';
import '../widgets.dart';
import '../../../theme/tokens.dart';

class ProfileSection extends ConsumerWidget {
  const ProfileSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(profileProvider);
    final n = ref.read(profileProvider.notifier);
    if (useAidlVehicle) return _LiveProfile(p);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Column(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(shape: BoxShape.circle, color: DashColors.slate),
                child: Icon(Icons.person_rounded, size: 36, color: DashColors.ash),
              ),
              const SizedBox(height: 12),
              _EditableRow(label: 'Name', value: p.name, onEdit: n.requestEdit, centered: true),
              if (p.isPrimary) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    border: Border.all(color: DashColors.eco, width: 1.5),
                    borderRadius: BorderRadius.circular(DashRadius.chip),
                  ),
                  child: Text('Owner', style: DashText.caption(13, color: DashColors.eco)),
                ),
              ],
            ],
          ),
        ),
        const SettingsDivider(),
        const SectionHeader('Vehicle'),
        _EditableRow(label: 'Scooter name', value: p.scooterName, onEdit: n.requestEdit),
        _EditableRow(label: 'Registration', value: p.registrationNumber, onEdit: n.requestEdit),
        KeyValueRow('Model', p.vehicleModel),
        KeyValueRow('Purchased', p.purchaseDate),
        const SettingsDivider(),
        const SectionHeader('Riders'),
        SizedBox(
          height: DashTouch.min,
          child: Row(
            children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: DashColors.eco)),
              const SizedBox(width: 12),
              Text('${p.name} (you)', style: DashText.value(20)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        PrimaryButton('Add rider', key: const ValueKey('profile-add-rider'), onTap: n.addRider),
      ],
    );
  }
}

/// The head unit's profile: what HHMIS sent, nothing editable (the names
/// are set in the Ola app) and no invented riders.
class _LiveProfile extends StatelessWidget {
  const _LiveProfile(this.p);
  final UserProfile p;

  @override
  Widget build(BuildContext context) => Column(
        key: const ValueKey('profile-live'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Column(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: DashColors.slate),
                  child: Icon(Icons.person_rounded, size: 36, color: DashColors.ash),
                ),
                const SizedBox(height: 12),
                if (p.name.isNotEmpty) Text(p.name, key: const ValueKey('profile-name'), style: DashText.value(24)),
              ],
            ),
          ),
          const SettingsDivider(),
          const SectionHeader('Vehicle'),
          if (p.scooterName.isNotEmpty) KeyValueRow('Scooter name', p.scooterName),
          if (p.vehicleModel.isNotEmpty) KeyValueRow('Model', p.vehicleModel),
          const SizedBox(height: 8),
          Text('Names are set in the Ola app.', style: DashText.caption(15, color: DashColors.ash)),
        ],
      );
}

/// Shows a value with a pencil; editing itself waits for Phase 2.
class _EditableRow extends StatelessWidget {
  const _EditableRow({required this.label, required this.value, required this.onEdit, this.centered = false});
  final String label;
  final String value;
  final VoidCallback onEdit;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final valueText = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: DashText.value(centered ? 24 : 18)),
        const SizedBox(width: 8),
        Icon(Icons.edit_rounded, size: 16, color: DashColors.ash),
      ],
    );
    return GestureDetector(
      key: ValueKey('profile-edit-${label.toLowerCase().replaceAll(' ', '-')}'),
      behavior: HitTestBehavior.opaque,
      onTap: onEdit,
      child: centered
          ? Padding(padding: const EdgeInsets.only(bottom: 10), child: valueText)
          : SizedBox(
              height: DashTouch.min,
              child: Row(
                children: [
                  SizedBox(width: 220, child: Text(label, style: DashText.caption(20))),
                  valueText,
                ],
              ),
            ),
    );
  }
}
