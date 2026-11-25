import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/analytics_logger.dart';
import '../../state/bt_settings.dart';
import '../../state/riding_lockout.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../status_bar/status_icons.dart';
import '../../theme/tokens.dart';

/// A phone asking to pair: its name and the code to compare, with Pair and
/// Cancel; or stock's "Device pairing failed". Over every screen the rider
/// can open, the Bluetooth screen included or not. Never while riding: the
/// notifier rejects the request the moment the lockout engages, and this
/// draws nothing meanwhile.
///
/// Not `BtPairingOverlay`, which is the phone app's BLE key pairing that
/// HHMIS relays.
class PhonePairingOverlay extends ConsumerWidget {
  const PhonePairingOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (open, code, name, failed) =
        ref.watch(btSettingsProvider.select((b) => (b.pairingOpen, b.pairingCode, b.pairingName, b.pairFailed)));
    final riding = ref.watch(ridingLockoutProvider);
    if (riding || (!open && !failed)) return const SizedBox.shrink();
    final n = ref.read(btSettingsProvider.notifier);

    return Positioned.fill(
      key: const ValueKey('phone-pairing'),
      child: ColoredBox(
        color: DashColors.ink.withValues(alpha: DashScrim.backdrop),
        child: Center(
          child: Container(
            width: 520,
            padding: const EdgeInsets.all(DashSpace.dialogPad),
            decoration: BoxDecoration(
              color: DashColors.inkLift,
              borderRadius: BorderRadius.circular(DashRadius.dialog),
              border: Border.all(color: DashColors.slate, width: 1.5),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: open
                  ? [
                      BluetoothIcon(on: true, size: 32),
                      const SizedBox(height: 10),
                      Text('Bluetooth Pairing Request', style: DashText.title(22), maxLines: 1),
                      const SizedBox(height: 6),
                      Text(
                        name.isEmpty ? 'Pair with this phone?' : 'Pair with $name',
                        key: const ValueKey('phone-pairing-name'),
                        style: DashText.value(20),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        code.isEmpty
                            ? 'Confirm the pairing on the phone as well'
                            : 'Make sure the pairing code shown on the phone matches the one below',
                        style: DashText.caption(16),
                        textAlign: TextAlign.center,
                      ),
                      if (code.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            code.split('').join(' '),
                            key: const ValueKey('phone-pairing-code'),
                            style: DashText.value(56).copyWith(letterSpacing: 2),
                            maxLines: 1,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: _Button(
                              key: const ValueKey('phone-pairing-cancel'),
                              label: 'Cancel',
                              color: DashColors.slate,
                              textColor: DashColors.bone,
                              onTap: () {
                                uiTap('phone-pairing-cancel');
                                n.rejectPairing();
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _Button(
                              key: const ValueKey('phone-pairing-pair'),
                              label: 'Pair',
                              color: DashColors.normal,
                              textColor: DashColors.ink,
                              onTap: () {
                                uiTap('phone-pairing-pair');
                                n.acceptPairing();
                              },
                            ),
                          ),
                        ],
                      ),
                    ]
                  : [
                      Text('Device pairing failed',
                          key: const ValueKey('phone-pairing-failed'), style: DashText.title(22, color: DashColors.warning)),
                      const SizedBox(height: 10),
                      Text('Start the pairing again from the phone.', style: DashText.caption(16), textAlign: TextAlign.center),
                      const SizedBox(height: 24),
                      _Button(
                        key: const ValueKey('phone-pairing-failed-ok'),
                        label: 'OK',
                        color: DashColors.slate,
                        textColor: DashColors.bone,
                        onTap: () {
                          uiTap('phone-pairing-failed-ok');
                          n.dismissPairFailed();
                        },
                      ),
                    ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({super.key, required this.label, required this.color, required this.textColor, required this.onTap});
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
        height: DashTouch.min,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(DashRadius.button)),
        child: Center(child: Text(label, style: DashText.value(18, color: textColor))),
      ),
    );
  }
}
