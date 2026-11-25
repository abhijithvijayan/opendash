import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../state/riding_lockout.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../status_bar/status_icons.dart';
import '../../theme/tokens.dart';

/// Six-digit code a phone shows during pairing. Hidden while riding: the
/// request stays pending until the scooter stops.
class BtPairingOverlay extends ConsumerWidget {
  const BtPairingOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final code = ref.watch(vehicleProvider.select((v) => v.btPairingCode));
    final riding = ref.watch(ridingLockoutProvider);
    if (code.isEmpty || riding) return const SizedBox.shrink();
    final n = ref.read(vehicleProvider.notifier);

    return Positioned.fill(
      key: const ValueKey('bt-pairing'),
      child: ColoredBox(
        color: DashColors.ink.withValues(alpha: DashScrim.backdrop),
        child: Center(
          child: Container(
            width: 400,
            height: 280,
            padding: const EdgeInsets.all(DashSpace.dialogPad),
            decoration: BoxDecoration(
              color: DashColors.inkLift,
              borderRadius: BorderRadius.circular(DashRadius.dialog),
              border: Border.all(color: DashColors.slate, width: 1.5),
            ),
            child: Column(
              children: [
                BluetoothIcon(on: true, size: 32),
                const SizedBox(height: 10),
                Text('Bluetooth Pairing Request', style: DashText.title(22), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text('Enter this code on your device:', style: DashText.caption(16), maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 8),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    code.split('').join(' '),
                    key: const ValueKey('bt-pairing-code'),
                    style: DashText.value(56).copyWith(letterSpacing: 2),
                    maxLines: 1,
                  ),
                ),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: _PairButton(
                        key: const ValueKey('bt-pairing-cancel'),
                        label: 'Cancel',
                        color: DashColors.slate,
                        textColor: DashColors.bone,
                        onTap: n.cancelPairing,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _PairButton(
                        key: const ValueKey('bt-pairing-confirm'),
                        label: 'Confirm',
                        color: DashColors.normal,
                        textColor: DashColors.ink,
                        onTap: n.confirmPairing,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PairButton extends StatelessWidget {
  const _PairButton({super.key, required this.label, required this.color, required this.textColor, required this.onTap});
  final String label;
  final Color color;
  final Color textColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        height: 48,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(DashRadius.button)),
        child: Center(child: Text(label, style: DashText.value(17, color: textColor))),
      ),
    );
  }
}
