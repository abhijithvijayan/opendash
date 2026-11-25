import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/analytics_logger.dart';
import '../../state/safety_screen.dart';
import 'safety_overlay.dart';

/// Stock `TamperFallScreens/AlarmState` (vehicle state ALARM) and
/// `TamperDetectedPopup` (TamperFallStatus 1): the same two lines and the
/// same Unlock button on both, so one screen here. Stock offers nothing to
/// silence the alarm; HHMIS stops the chime itself when ALARM ends.
class AlarmScreen extends ConsumerWidget {
  const AlarmScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(safetyScreenProvider.select((s) => s.busy));
    return SafetyScaffold(
      kicker: 'ALARM',
      title: 'Tamper detected',
      lines: const ['Unlock scooter to deactivate the alert'],
      actions: [
        const SizedBox.shrink(),
        SafetyButton(
          busy ? 'Unlocking…' : 'Unlock scooter',
          key: const ValueKey('safety-alarm-unlock'),
          filled: true,
          enabled: !busy,
          onTap: () {
            uiModalButton('safety_alarm', 'unlock');
            ref.read(safetyScreenProvider.notifier).unlock();
          },
        ),
      ],
    );
  }
}
