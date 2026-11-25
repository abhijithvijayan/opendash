import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/analytics_logger.dart';
import '../../state/bt_settings.dart';
import '../../state/media_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/overlays/alert_overlay.dart';
import '../../widgets/overlays/call_overlay.dart';
import '../../widgets/status_bar/status_icons.dart';
import '../../theme/tokens.dart';
import '../settings/widgets.dart';

/// Stock's wording (HHMIC, the consent pop-up of "Sync Incoming Calls").
const phoneCallsConsentText = 'This will route call audio to the scooter’s speaker. By continuing, you agree to use this '
    'feature in compliance to your state laws, rules & regulations. Stay safe and avoid taking calls while riding.';

/// Bluetooth settings: power, the paired phones (connect, disconnect,
/// forget) and "phone calls on the dashboard". Pairing starts on the phone;
/// the code to confirm comes up in `PhonePairingOverlay`, whether or not
/// this screen is open. Slides in from the right under the overlay toolbar;
/// never reachable while riding.
class BtDevicesScreen extends ConsumerWidget {
  const BtDevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(btScreenOpenProvider);
    final shift = ref.watch(alertBannerShiftProvider) + ref.watch(callBarShiftProvider);
    return AnimatedPositioned(
      duration: DashMotion.normal,
      curve: Curves.easeOutCubic,
      left: open ? 0 : 1280,
      top: shift,
      width: 1280,
      height: 768 - shift,
      child: open ? const _Body() : const SizedBox.shrink(),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bt = ref.watch(btSettingsProvider);
    final n = ref.read(btSettingsProvider.notifier);
    final readOnly = bt.readOnly;
    final forget = bt.phone(bt.forgetAddress);

    return ColoredBox(
      key: const ValueKey('bt-body'),
      color: DashColors.ink,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(DashSpace.gutter, DashSpace.overlayTop, DashSpace.gutter, DashSpace.bodyBottom),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (readOnly != null) ...[
                  Text('$readOnly.', key: const ValueKey('bt-readonly'), style: DashText.caption(16, color: DashColors.warning)),
                  const SizedBox(height: 8),
                ],
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 500,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ToggleRow(
                              key: const ValueKey('bt-power'),
                              label: 'Bluetooth',
                              value: bt.on,
                              enabled: readOnly == null,
                              onChanged: n.setOn,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              !bt.on
                                  ? 'Phones cannot connect'
                                  : bt.visible
                                      ? (bt.name.isEmpty ? 'Visible to phones' : 'Visible as ${bt.name}')
                                      : 'Not visible to new phones',
                              key: const ValueKey('bt-visible'),
                              style: DashText.caption(18),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (bt.on && bt.visible) ...[
                              const SizedBox(height: 8),
                              Text(
                                'To pair, open Bluetooth on your phone and choose the scooter. '
                                'The pairing code will appear here.',
                                style: DashText.caption(16),
                              ),
                            ],
                            const SettingsDivider(),
                            ToggleRow(
                              key: const ValueKey('bt-calls'),
                              label: 'Phone calls on the dashboard',
                              caption: 'Receive incoming calls on your scooter',
                              value: bt.callsAllowed,
                              enabled: readOnly == null,
                              onChanged: n.setCallsAllowed,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 56),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Paired phones', style: DashText.caption(18)),
                            const SizedBox(height: 8),
                            if (bt.phones.isEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text('No paired phones',
                                    key: const ValueKey('bt-bonded-empty'), style: DashText.value(20, color: DashColors.ash)),
                              ),
                            Expanded(
                              child: SingleChildScrollView(
                                child: Column(
                                  children: [
                                    for (final phone in bt.phones) _PhoneRow(phone, actions: readOnly == null && bt.on),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (forget != null)
            Positioned.fill(
              child: ConfirmCard(
                key: const ValueKey('bt-forget-confirm'),
                title: 'Forget ${forget.label}?',
                body: 'It will no longer connect to the scooter. To use it again, pair it from the phone. '
                    'Remove the scooter from the phone’s Bluetooth list too.',
                primaryLabel: 'Forget',
                primaryColor: DashColors.warning,
                onPrimary: () {
                  uiTap('bt-forget-confirm');
                  n.confirmForget();
                },
                secondaryLabel: 'Cancel',
                onSecondary: n.cancelForget,
              ),
            ),
          if (bt.consentOpen)
            Positioned.fill(
              child: ConfirmCard(
                key: const ValueKey('bt-consent'),
                width: 560,
                title: 'Phone calls on the dashboard',
                body: phoneCallsConsentText,
                primaryLabel: 'Continue',
                onPrimary: () {
                  uiTap('bt-consent-continue');
                  n.acceptConsent();
                },
                secondaryLabel: 'Cancel',
                onSecondary: () {
                  uiTap('bt-consent-cancel');
                  n.declineConsent();
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _PhoneRow extends ConsumerWidget {
  const _PhoneRow(this.phone, {required this.actions});
  final BtPhone phone;
  final bool actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.read(btSettingsProvider.notifier);
    return SizedBox(
      key: ValueKey('bt-phone-${phone.address}'),
      height: 72,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: Center(child: BluetoothIcon(on: true, color: phone.connected ? DashColors.normal : DashColors.ash)),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(phone.label, style: DashText.value(20), maxLines: 1, overflow: TextOverflow.ellipsis),
                if (phone.connected) Text('Connected', style: DashText.caption(15, color: DashColors.eco)),
              ],
            ),
          ),
          if (actions) ...[
            const SizedBox(width: 12),
            _RowButton(
              key: ValueKey('bt-connect-${phone.address}'),
              label: phone.connected ? 'Disconnect' : 'Connect',
              onTap: () {
                uiTap(phone.connected ? 'bt-disconnect' : 'bt-connect');
                n.toggleConnection(phone.address);
              },
            ),
            const SizedBox(width: 10),
            _RowButton(
              key: ValueKey('bt-forget-${phone.address}'),
              label: 'Forget',
              quiet: true,
              onTap: () {
                uiTap('bt-forget');
                n.askForget(phone.address);
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _RowButton extends StatelessWidget {
  const _RowButton({super.key, required this.label, required this.onTap, this.quiet = false});
  final String label;
  final VoidCallback onTap;
  final bool quiet;

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
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: quiet
            ? null
            : BoxDecoration(
                border: Border.all(color: DashColors.ash, width: 1.5),
                borderRadius: BorderRadius.circular(DashRadius.button),
              ),
        child: Center(widthFactor: 1, child: Text(label, style: DashText.value(18, color: quiet ? DashColors.ash : DashColors.bone))),
      ),
    );
  }
}
