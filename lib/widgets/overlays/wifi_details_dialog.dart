import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../screens/settings/widgets.dart';
import '../../state/wifi_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';

/// Details of the connected network, with disconnect.
class WifiDetailsDialog extends ConsumerWidget {
  const WifiDetailsDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(wifiDetailsOpenProvider);
    final wifi = ref.watch(wifiProvider);
    final entry = wifi.connected;
    if (!open || entry == null) return const SizedBox.shrink();
    final close = ref.read(wifiDetailsOpenProvider.notifier).close;
    final (ip, mac) = ref.watch(vehicleProvider.select((v) => (v.ipAddress, v.wifiMac)));
    return Positioned.fill(
      key: const ValueKey('wifi-details'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: close,
        child: ColoredBox(
          color: DashColors.ink.withValues(alpha: DashScrim.backdrop),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: Container(
                width: 480,
                padding: const EdgeInsets.all(DashSpace.dialogPad),
                decoration: BoxDecoration(
                  color: DashColors.inkLift,
                  borderRadius: BorderRadius.circular(DashRadius.dialog),
                  border: Border.all(color: DashColors.slate, width: 1.5),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(entry.ssid, style: DashText.title(20))),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(border: Border.all(color: DashColors.eco, width: 1.5), borderRadius: BorderRadius.circular(DashRadius.chip)),
                          child: Text('Connected', style: DashText.caption(13, color: DashColors.eco)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    KeyValueRow('Signal strength', entry.signalLabel),
                    KeyValueRow('IP address', ip),
                    KeyValueRow('MAC address', mac),
                    KeyValueRow('Security', entry.security),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButtonLink('Disconnect', key: const ValueKey('wifi-disconnect'), color: DashColors.critical, onTap: () {
                          ref.read(wifiProvider.notifier).disconnect();
                          close();
                        }),
                        const SizedBox(width: 8),
                        PrimaryButton('Done', onTap: close),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
