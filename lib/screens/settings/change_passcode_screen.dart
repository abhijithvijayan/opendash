import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/settings_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../locked/keypad.dart';
import '../../theme/tokens.dart';

/// Three-step passcode change inside the settings content area.
class ChangePasscodeScreen extends ConsumerWidget {
  const ChangePasscodeScreen({super.key});

  static const width = 960.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(changePasscodeOpenProvider);
    final s = ref.watch(changePasscodeProvider);
    final n = ref.read(changePasscodeProvider.notifier);

    final header = switch (s.step) {
      PasscodeStep.verify => 'Enter current passcode',
      PasscodeStep.create => 'Enter new passcode',
      PasscodeStep.confirm => 'Confirm new passcode',
    };
    final dotColor = switch (s.lastResult) {
      ChangePasscodeResult.success => DashColors.eco,
      ChangePasscodeResult.failure || ChangePasscodeResult.mismatch => DashColors.critical,
      null => DashColors.bone,
    };
    final hint = switch (s.lastResult) {
      ChangePasscodeResult.mismatch => "Passcodes don't match",
      ChangePasscodeResult.failure => 'Wrong passcode',
      _ => '',
    };

    return AnimatedPositioned(
      duration: DashMotion.normal,
      curve: Curves.easeOutCubic,
      left: open ? 0 : width,
      top: 0,
      bottom: 0,
      width: width,
      child: ColoredBox(
        color: DashColors.ink,
        child: Stack(
          children: [
            Positioned(
              left: DashSpace.gutter,
              top: 16,
              child: Text('Change passcode', style: DashText.title(24)),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 96,
              child: Column(
                children: [
                  Text(header, key: ValueKey('passcode-step-${s.step.name}'), style: DashText.value(22)),
                  const SizedBox(height: 22),
                  PinDots(filled: s.enteredDigits.length, shakeTrigger: s.failures, color: dotColor),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 22,
                    child: Text(hint, style: DashText.caption(16, color: DashColors.critical)),
                  ),
                ],
              ),
            ),
            Positioned(
              left: width / 2 - Keypad.width / 2,
              top: 184,
              child: Transform.scale(
                scale: 0.8,
                alignment: Alignment.topCenter,
                child: Keypad(
                  enabled: s.lastResult != ChangePasscodeResult.success,
                  onDigit: n.enterDigit,
                  onDelete: n.deleteDigit,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
