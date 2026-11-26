import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/vehicle_data.dart';
import '../../../providers/mock_provider.dart';
import '../../../state/format_settings.dart';
import '../../../state/riding_settings.dart';
import '../widgets.dart';
import '../../../theme/colors.dart';
import '../../../theme/tokens.dart';
import '../../../theme/typography.dart';
import '../../../state/scooter_capabilities.dart';

class RidingSection extends ConsumerWidget {
  const RidingSection({super.key});

  /// Sixteen toggles in one list were hard to scan. A feature the scooter
  /// reports as not available drops out of its group.
  static const groups = [
    ('Braking & Stability', [RidingFeature.adaptivePowerBoost, RidingFeature.hillHold]),
    // sideStandCutOff hidden: ClientCmd 67 polarity unknown; the
    // auto-lock sub-toggle is rendered below the Safety group instead.
    ('Safety', [RidingFeature.fallDetection, RidingFeature.tamper, RidingFeature.motorCutOff]),
    ('Lights', [RidingFeature.smartHeadlight, RidingFeature.smartDrl, RidingFeature.autoHeadlight, RidingFeature.takeMeHome]),
    // Auto brightness is in Display, next to the brightness levels it sets.
    ('Convenience', [RidingFeature.proximityUnlock, RidingFeature.autoTurnOff, RidingFeature.vacationMode, RidingFeature.predictedRange]),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(ridingSettingsProvider);
    final useMiles = ref.watch(useMilesProvider);
    final n = ref.read(ridingSettingsProvider.notifier);
    final scooter = ref.watch(scooterCapabilitiesProvider);

    Widget sub(RidingFeature f, Widget child) => AnimatedSize(
          duration: DashMotion.fast,
          curve: DashMotion.valueCurve,
          alignment: Alignment.topLeft,
          child: s.isOn(f)
              ? Padding(padding: const EdgeInsets.only(left: 16, bottom: 8), child: child)
              : const SizedBox.shrink(),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const CustomRideCard(),
        const SectionHeader('Speed limit'),
        ToggleRow(
          key: const ValueKey('riding-speedLimit'),
          label: 'Speed limit warning',
          value: s.speedLimitEnabled,
          onChanged: n.setSpeedLimitEnabled,
        ),
        AnimatedSize(
          duration: DashMotion.fast,
          curve: DashMotion.valueCurve,
          alignment: Alignment.topLeft,
          child: !s.speedLimitEnabled
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 8),
                  child: SliderRow(
                    label: 'Speed limit',
                    value: s.speedLimit.toDouble(),
                    min: 30,
                    max: 120,
                    divisions: 90,
                    display: '${toDisplayDistance(s.speedLimit, useMiles)} ${speedUnit(useMiles)}',
                    onChanged: (x) => n.setSpeedLimit(x.round(), commit: false),
                    onChangeEnd: (x) => n.setSpeedLimit(x.round()),
                  ),
                ),
        ),
        for (final (header, features) in RidingSection.groups) ...[
          SectionHeader(header, key: ValueKey('riding-group-${features.first.name}')),
          // REGEN_SETTINGS_UPDATE carries a mode, not a level; Off is a mode
          // of its own, so there is no separate regen on/off toggle.
          if (header == 'Braking & Stability' && scooter.regenModes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Regenerative braking', style: DashText.caption(20, color: DashColors.bone)),
                  const SizedBox(height: 8),
                  ChipRow<RegenMode>(
                    key: const ValueKey('riding-regenMode'),
                    options: RegenMode.values,
                    value: s.regenMode,
                    label: (m) => m.label,
                    onSelected: n.setRegenMode,
                  ),
                ],
              ),
            ),
          for (final f in features.where(scooter.feature)) ...[
            ToggleRow(
              key: ValueKey('riding-${f.name}'),
              label: f.label,
              caption: f.caption,
              value: s.isOn(f),
              onChanged: (on) => n.setFeature(f, on),
            ),
            if (f == RidingFeature.tamper)
              sub(
                f,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Sensitivity', style: DashText.caption(20, color: DashColors.bone)),
                    const SizedBox(height: 8),
                    ChipRow<DetectionSensitivity>(
                      key: const ValueKey('riding-sensitivity'),
                      options: DetectionSensitivity.values,
                      value: s.detectionSensitivity,
                      label: (d) => d.label,
                      onSelected: n.setDetectionSensitivity,
                    ),
                  ],
                ),
              ),
          ],
          if (header == 'Safety') ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Alarm sound', style: DashText.caption(20, color: DashColors.bone)),
                  const SizedBox(height: 8),
                  ChipRow<AlarmSound>(
                    key: const ValueKey('riding-alarmSound'),
                    options: AlarmSound.values,
                    value: s.alarmSound,
                    label: (a) => a.label,
                    onSelected: n.setAlarmSound,
                  ),
                ],
              ),
            ),
            // Auto-lock on side-stand drop is hidden for the public beta:
            // the tested firmware did not act on its Lock_Now
            // (`RidingSettings.autoLockEnabled`).
          ],
        ],
      ],
    );
  }
}

/// The rider's own ride mode (MoveOS 5), shown as the scooter reports it.
/// It is set from the stock dashboard or the phone app; OpenDash does not
/// change it. Nothing shows on a scooter that never sends it.
class CustomRideCard extends ConsumerWidget {
  const CustomRideCard({super.key});

  /// The scooter's own number: what each level is called in stock is an
  /// image in its Kanzi file, not text OpenDash can read.
  static String level(int? i) => i == null ? '—' : 'Level $i';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(vehicleProvider.select((v) => v.customRide));
    final active = ref.watch(vehicleProvider.select((v) => v.customRideActive));
    final useMiles = ref.watch(useMilesProvider);
    if (!c.known) return const SizedBox.shrink();
    String km(int? v) => v == null ? '—' : '${toDisplayDistance(v, useMiles)} ${distanceUnit(useMiles)}';
    final state = active
        ? 'In use now'
        : c.enabled == true
            ? 'On the handlebar switch'
            : 'Switched off';
    return Column(
      key: const ValueKey('custom-ride-card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader('Custom ride mode · ${c.label}'),
        KeyValueRow('Status', c.isDefault == true ? '$state · starts in it' : state),
        KeyValueRow('Top speed', c.topSpeedKmh == null ? '—' : '${toDisplayDistance(c.topSpeedKmh!, useMiles)} ${speedUnit(useMiles)}'),
        KeyValueRow('Power', c.powerPercent == null ? '—' : '${c.powerPercent} %'),
        KeyValueRow('Throttle response', level(c.throttle)),
        KeyValueRow('Regen', level(c.regen)),
        KeyValueRow('Range', km(c.rangeKm)),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: Text('Change it from the stock dashboard or the Ola app.', style: DashText.caption(15)),
        ),
        const SettingsDivider(),
      ],
    );
  }
}
