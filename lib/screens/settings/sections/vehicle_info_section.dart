import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/vehicle_data.dart';
import '../../../providers/mock_provider.dart';
import '../../../services/analytics_logger.dart';
import '../../../state/scooter_restart.dart';
import '../../../state/settings_state.dart';
import '../../../theme/colors.dart';
import '../../../theme/typography.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/overlays/soh_dialog.dart';
import '../widgets.dart';

class VehicleInfoSection extends ConsumerWidget {
  const VehicleInfoSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(vehicleProvider);
    final canRestart = restartAvailable(v);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Firmware'),
        // A version with no source on this build has no row.
        for (final (k, value) in v.firmwareVersions)
          if (value.isNotEmpty) KeyValueRow(k, value),
        const SettingsDivider(),
        const SectionHeader('Vehicle'),
        if (v.vin.isNotEmpty) MaskedValueRow('VIN', v.vin, field: 'vin'),
        // Never filled on the head unit: Android 10 keeps the ICCID behind
        // READ_PRIVILEGED_PHONE_STATE and HHMIS has no key for it.
        if (v.iccid.isNotEmpty) MaskedValueRow('SIM Card (ICCID)', v.iccid, field: 'iccid'),
        if (v.serviceIndicator && VehicleData.serviceIndicatorVerified)
          SizedBox(
            key: const ValueKey('service-due-row'),
            height: DashTouch.min,
            child: Row(
              children: [
                SizedBox(width: 220, child: Text('Service', style: DashText.caption(20))),
                Text('Service due', style: DashText.value(20, color: DashColors.warning)),
              ],
            ),
          ),
        GestureDetector(
          key: const ValueKey('soh-row'),
          behavior: HitTestBehavior.opaque,
          onTap: ref.read(sohPopupOpenProvider.notifier).open,
          child: SizedBox(
            height: DashTouch.min,
            child: Row(
              children: [
                SizedBox(width: 220, child: Text('Battery SOH', style: DashText.caption(20))),
                Builder(builder: (_) {
                  final good = v.batteryHealthKnown ? v.batteryHealthGood : null;
                  return Text(healthLabel(good), key: const ValueKey('soh-status'), style: DashText.value(20, color: healthColor(good)));
                }),
                const SizedBox(width: 10),
                Icon(Icons.info_outline_rounded, size: 16, color: DashColors.ash),
              ],
            ),
          ),
        ),
        const SectionHeader('Restart'),
        Opacity(
          opacity: canRestart ? 1 : 0.4,
          child: PrimaryButton(
            'Restart scooter',
            key: const ValueKey('vehicle-restart'),
            icon: Icon(Icons.restart_alt_rounded, size: 22, color: DashColors.bone),
            onTap: () {
              uiTap('vehicle-restart');
              ref.read(scooterRestartProvider.notifier).request('settings');
            },
          ),
        ),
        const SizedBox(height: 8),
        Text('Parked and unplugged only. Asks for the passcode. Takes about a minute.', style: DashText.caption(15, color: DashColors.ash)),
      ],
    );
  }
}
