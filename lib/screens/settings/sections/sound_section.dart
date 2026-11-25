import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/mock_provider.dart';
import '../../../state/sound_settings.dart';
import '../../../theme/colors.dart';
import '../../../theme/typography.dart';
import '../widgets.dart';
import '../../../theme/tokens.dart';

class SoundSection extends ConsumerWidget {
  const SoundSection({super.key, this.live});

  /// On the scooter only the controls HHMIS has a call for are shown: the
  /// preset (`INT_MODE_UPDATE`), Motor Volume and Chime Volume. The preset
  /// parameters and Sound Volume need the custom-sound transactions (server
  /// TX 21-24), and stock has no master mute; those stay mock-only. Defaults
  /// to [useAidlVehicle]; tests set it.
  final bool? live;

  static IconData iconFor(SoundPreset p) => switch (p) {
        SoundPreset.bolt => Icons.bolt_rounded,
        SoundPreset.vintage => Icons.speed_rounded,
        SoundPreset.eclipse => Icons.nightlight_round,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(soundSettingsProvider);
    final n = ref.read(soundSettingsProvider.notifier);
    final params = s.presetParams;
    final live = this.live ?? useAidlVehicle;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Engine sound'),
        Row(
          children: [
            for (final p in SoundPreset.values) ...[
              Expanded(
                child: SettingsCard(
                  key: ValueKey('preset-${p.name}'),
                  height: 128,
                  selected: s.preset == p,
                  background: s.preset == p ? DashColors.bone.withValues(alpha: 0.06) : DashColors.inkLift,
                  onTap: () => n.setPreset(p),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(iconFor(p), size: 28, color: s.preset == p ? DashColors.bone : DashColors.ash),
                      const Spacer(),
                      Text(p.label, style: DashText.value(20)),
                      const SizedBox(height: 4),
                      Text(p.tagline, style: DashText.caption(15)),
                    ],
                  ),
                ),
              ),
              if (p != SoundPreset.values.last) const SizedBox(width: 16),
            ],
          ],
        ),
        const SizedBox(height: 20),
        if (live)
          Text(
            'Also sets the chime style, and the mood the stock dashboard opens in.',
            key: const ValueKey('sound-mood-note'),
            style: DashText.caption(15),
          ),
        if (!live)
        AnimatedSwitcher(
          duration: DashMotion.fast,
          switchInCurve: DashMotion.valueCurve,
          switchOutCurve: DashMotion.valueCurve,
          child: Column(
            key: ValueKey(s.preset),
            children: [
              for (var i = 0; i < params.length; i++)
                SliderRow(
                  key: ValueKey('param-${s.preset.name}-$i'),
                  label: params[i].$1,
                  value: params[i].$2.toDouble(),
                  onChanged: (x) => n.setPresetParam(i, x.round()),
                ),
            ],
          ),
        ),
        const SettingsDivider(),
        const SectionHeader('Volume'),
        if (!live)
          SliderRow(label: 'Sound Volume', value: s.soundVolume.toDouble(), onChanged: (x) => n.setSoundVolume(x.round())),
        SliderRow(label: 'Motor Volume', value: s.motorVolume.toDouble(), onChanged: (x) => n.setMotorVolume(x.round())),
        SliderRow(
          label: 'Chime Volume',
          value: s.chimeVolume.toDouble(),
          min: SoundSettingsNotifier.chimeFloor.toDouble(),
          onChanged: (x) => n.setChimeVolume(x.round()),
        ),
        if (s.chimeVolume <= SoundSettingsNotifier.chimeFloor)
          Text(
            'System sounds cannot be set below ${SoundSettingsNotifier.chimeFloor}%',
            key: const ValueKey('chime-floor-note'),
            style: DashText.caption(15),
          ),
        if (!live) ...[
          ToggleRow(label: 'System Sound', value: s.systemSound, onChanged: n.setSystemSound, caption: 'Master mute for all sounds'),
          const SettingsDivider(),
          TextButtonLink('Reset to Defaults', key: const ValueKey('sound-reset'), onTap: n.reset),
        ],
      ],
    );
  }
}
