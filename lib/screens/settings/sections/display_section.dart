import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/mock_provider.dart';
import '../../../state/format_settings.dart';
import '../../../state/settings_state.dart';
import '../../../theme/colors.dart';
import '../../../theme/typography.dart';
import '../widgets.dart';
import '../../../theme/tokens.dart';
import 'theme_picker.dart';
import '../../../state/auto_brightness.dart';

class DisplaySection extends ConsumerWidget {
  const DisplaySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brightness = ref.watch(brightnessProvider);
    final auto = ref.watch(autoDarkModeProvider);
    final use24 = ref.watch(use24HourProvider);
    final dateOrder = ref.watch(dateOrderProvider);
    final useMiles = ref.watch(useMilesProvider);
    final useF = ref.watch(useFahrenheitProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Screen'),
        SliderRow(
          label: 'Brightness',
          value: brightness.toDouble(),
          display: '$brightness%',
          onChanged: (x) => ref.read(brightnessProvider.notifier).set(x.round(), persist: false),
          onChangeEnd: (x) {
            ref.read(brightnessProvider.notifier).set(x.round());
            ref.read(autoBrightnessProvider.notifier).learn(x.round());
          },
        ),
        const SettingsDivider(),
        const SectionHeader('Theme'),
        const ThemeCards(),
        const SizedBox(height: 24),
        const SectionHeader('Custom accents'),
        const AccentPicker(),
        const SizedBox(height: 24),
        const SectionHeader('Auto theme'),
        Text('Your light theme by day, your dark theme at night', style: DashText.caption(14)),
        const SizedBox(height: 8),
        ChipRow<AutoThemeMode>(
          key: const ValueKey('auto-theme-mode'),
          options: AutoThemeMode.values,
          value: auto.mode,
          label: (m) => m.label,
          onSelected: ref.read(autoDarkModeProvider.notifier).setMode,
        ),
        // The choice stays the rider's; this only says what the sensor is
        // doing on this scooter.
        if (auto.mode == AutoThemeMode.ambientSensor && !ref.watch(vehicleProvider.select((v) => v.ambientUsable)))
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 4),
            child: Text(
              "This scooter's light sensor hasn't shown usable readings yet. Time-based follows the clock instead.",
              key: const ValueKey('auto-theme-sensor-note'),
              style: DashText.caption(14, color: DashColors.warning),
            ),
          ),
        AnimatedSize(
          duration: DashMotion.fast,
          curve: DashMotion.valueCurve,
          alignment: Alignment.topLeft,
          child: auto.mode != AutoThemeMode.timeBased
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Row(
                    children: [
                      TimeStepField(
                        label: 'Dark after',
                        value: auto.darkAfter,
                        onChanged: ref.read(autoDarkModeProvider.notifier).setDarkAfter,
                      ),
                      const SizedBox(width: 24),
                      TimeStepField(
                        label: 'Light after',
                        value: auto.lightAfter,
                        onChanged: ref.read(autoDarkModeProvider.notifier).setLightAfter,
                      ),
                    ],
                  ),
                ),
        ),
        // Set once and left alone, so they sit under the theme, which the
        // rider comes here to change.
        const SettingsDivider(),
        const SectionHeader('Formats'),
        Text('Time format', style: DashText.caption(16)),
        const SizedBox(height: 8),
        ChipRow<bool>(
          key: const ValueKey('time-format'),
          options: const [false, true],
          value: use24,
          label: (v) => v ? '24-hour' : '12-hour',
          onSelected: ref.read(use24HourProvider.notifier).set,
        ),
        const SizedBox(height: 16),
        Text('Lock screen date', style: DashText.caption(16)),
        const SizedBox(height: 8),
        ChipRow<DateOrder>(
          key: const ValueKey('date-format'),
          options: DateOrder.values,
          value: dateOrder,
          label: (o) => o.label,
          onSelected: ref.read(dateOrderProvider.notifier).set,
        ),
        const SizedBox(height: 16),
        Text('Distance', style: DashText.caption(16)),
        const SizedBox(height: 8),
        ChipRow<bool>(
          key: const ValueKey('distance-unit'),
          options: const [false, true],
          value: useMiles,
          label: distanceUnit,
          onSelected: ref.read(useMilesProvider.notifier).set,
        ),
        const SizedBox(height: 16),
        Text('Temperature', style: DashText.caption(16)),
        const SizedBox(height: 8),
        ChipRow<bool>(
          key: const ValueKey('temp-unit'),
          options: const [false, true],
          value: useF,
          label: tempUnit,
          onSelected: ref.read(useFahrenheitProvider.notifier).set,
        ),
      ],
    );
  }
}
