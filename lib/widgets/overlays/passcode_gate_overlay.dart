import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../screens/locked/keypad.dart';
import '../../screens/locked/locked_screen.dart' show formatCountdown;
import '../../state/passcode_gate.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';

/// The lock-screen keypad over a dimmed backdrop, for actions that need the
/// rider's passcode before they go ahead.
class PasscodeGateOverlay extends ConsumerStatefulWidget {
  const PasscodeGateOverlay({super.key});

  @override
  ConsumerState<PasscodeGateOverlay> createState() => _PasscodeGateOverlayState();
}

class _PasscodeGateOverlayState extends ConsumerState<PasscodeGateOverlay> {
  Timer? _countdown;

  @override
  void dispose() {
    _countdown?.cancel();
    super.dispose();
  }

  void _syncCountdown(bool lockedOut) {
    if (lockedOut && _countdown == null) {
      _countdown = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    } else if (!lockedOut && _countdown != null) {
      _countdown!.cancel();
      _countdown = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final gate = ref.watch(passcodeGateProvider);
    _syncCountdown(gate.open && gate.lockedOut);
    if (!gate.open) return const SizedBox.shrink();
    final n = ref.read(passcodeGateProvider.notifier);

    final hint = gate.lockedOut
        ? 'Try again in ${formatCountdown(gate.lockoutRemaining(DateTime.now()))}'
        : gate.failed
            ? 'Wrong passcode'
            : 'Enter your passcode';
    final hintColor = gate.lockedOut || gate.failed ? DashColors.critical : DashColors.ash;

    return Positioned.fill(
      key: const ValueKey('passcode-gate'),
      child: ColoredBox(
        color: DashColors.ink.withValues(alpha: DashScrim.backdrop),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(gate.purpose, key: const ValueKey('gate-purpose'), style: DashText.title(24), textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(hint, key: const ValueKey('gate-hint'), style: DashText.caption(16, color: hintColor)),
              const SizedBox(height: 16),
              PinDots(
                filled: gate.enteredDigits.length,
                shakeTrigger: gate.failures,
                color: gate.failed ? DashColors.critical : DashColors.parked,
              ),
              const SizedBox(height: 12),
              Transform.scale(
                scale: 0.85,
                alignment: Alignment.topCenter,
                child: Keypad(enabled: !gate.lockedOut, onDigit: n.enterDigit, onDelete: n.deleteDigit),
              ),
              GestureDetector(
                key: const ValueKey('gate-cancel'),
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.lightImpact();
                  n.cancel();
                },
                child: SizedBox(
                  height: 44,
                  width: 160,
                  child: Center(child: Text('Cancel', style: DashText.value(18, color: DashColors.ash))),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
