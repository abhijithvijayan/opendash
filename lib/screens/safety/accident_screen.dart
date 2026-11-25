import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/vehicle_data.dart';
import '../../services/analytics_logger.dart';
import '../../state/safety_screen.dart';
import 'safety_overlay.dart';

/// Stock `TamperFallScreens/AccidentDetectedPopup` (TamperFallStatus 3):
/// its heading, its two lines and its two buttons, whose labels are baked
/// into textures (`SafeButton`, `AccidentDetected_getHelp`). The emergency
/// number is ours: "Get help" here reaches the vehicle only, not the cloud
/// alert stock raises alongside it.
class AccidentScreen extends ConsumerWidget {
  const AccidentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(safetyScreenProvider.select((s) => s.busy));
    final n = ref.read(safetyScreenProvider.notifier);
    return SafetyScaffold(
      kicker: 'ACCIDENT DETECTED',
      title: 'Are you safe?',
      lines: const ['Looks like you had an accident.', 'Let us know if you are safe or need any help.'],
      note: 'Call $emergencyNumber if you need emergency services',
      actions: [
        SafetyButton(
          "I'm safe",
          key: const ValueKey('safety-accident-safe'),
          enabled: !busy,
          onTap: () {
            uiModalButton('safety_accident', 'safe');
            n.reply(safe: true);
          },
        ),
        SafetyButton(
          'Get help',
          key: const ValueKey('safety-accident-help'),
          filled: true,
          enabled: !busy,
          onTap: () {
            uiModalButton('safety_accident', 'help');
            n.reply(safe: false);
          },
        ),
      ],
    );
  }
}
