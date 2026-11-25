import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/app_catalog.dart';
import '../../../providers/mock_provider.dart';
import '../../../services/analytics_logger.dart';
import '../../../state/access_state.dart';
import '../../../state/apps_state.dart';
import '../../../state/riding_lockout.dart';
import '../../../state/media_state.dart';
import '../../../state/wifi_state.dart';
import '../../../theme/colors.dart';
import '../../../theme/typography.dart';
import '../../../widgets/status_bar/status_icons.dart';
import '../widgets.dart';
import '../../../theme/tokens.dart';

class ConnectivitySection extends ConsumerWidget {
  const ConnectivitySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bt = ref.watch(vehicleProvider.select((v) => v.btConnected));
    final device = ref.watch(vehicleProvider.select((v) => v.btDeviceName));
    final scooterName = ref.watch(vehicleProvider.select((v) => v.scooterBtName));
    final (wifiMac, ip, btMac) = ref.watch(vehicleProvider.select((v) => (v.wifiMac, v.ipAddress, v.btMac)));
    final n = ref.read(vehicleProvider.notifier);
    final live = useAidlVehicle;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Wi-Fi'),
        // An app on Android 10 can neither switch Wi-Fi
        // (blocked from target 29) nor read the scan list or SSID (location
        // permission), so the head unit shows the real link state and sends
        // the rider to Android Settings for the rest.
        if (live) const _LiveWifi() else const _MockWifi(),
        const SizedBox(height: 8),
        PrimaryButton(
          'Choose a Wi-Fi network',
          key: const ValueKey('wifi-panel'),
          onTap: () {
            uiTap('wifi-panel');
            ref.read(appManagerProvider.notifier).openWifiPanel('connectivity');
          },
        ),
        const SizedBox(height: 6),
        Text("Android's Wi-Fi list. Tapping the status bar's Wi-Fi icon opens it too.", style: DashText.caption(15, color: DashColors.ash)),
        const SizedBox(height: 12),
        if (wifiMac.isNotEmpty) KeyValueRow('Wi-Fi MAC', wifiMac),
        if (ip.isNotEmpty) KeyValueRow('IP Address', ip, key: const ValueKey('wifi-ip')),
        if (live) ...[
          const SizedBox(height: 8),
          const _AndroidSettingsButton(ValueKey('wifi-android-settings'), 'Everything else about Wi-Fi is in Android Settings.'),
          const _SystemPageButton(
            ValueKey('hotspot-settings'),
            page: 'hotspot',
            label: 'Hotspot',
            caption: "The scooter's own hotspot: switch it on or off and set its password. The arrow at the top of that page comes back here.",
          ),
          const _AccessButton(),
        ],
        const SettingsDivider(),
        const SectionHeader('Bluetooth'),
        // On the head unit this row only reports; the controls are on the
        // Bluetooth screen behind Manage Devices (HSSS, bt_settings.dart).
        if (live)
          _StatusRow(
            key: const ValueKey('bt-status'),
            label: 'Bluetooth',
            on: bt,
            text: bt ? (device.isEmpty ? 'Phone' : device) : 'No phone connected',
          )
        else ...[
          ToggleRow(key: const ValueKey('bt-toggle'), label: 'Bluetooth', value: bt, onChanged: n.setBtConnected),
          if (bt)
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  BluetoothIcon(on: true, color: DashColors.normal),
                  const SizedBox(width: 18),
                  Expanded(child: Text(device, style: DashText.value(20))),
                  _Badge('Connected', DashColors.eco),
                ],
              ),
            ),
        ],
        const SizedBox(height: 8),
        PrimaryButton(
          'Manage Devices',
          key: const ValueKey('manage-devices'),
          onTap: ref.read(btScreenOpenProvider.notifier).open,
        ),
        const SizedBox(height: 12),
        // The adapter address reads 02:00:00:00:00:00 for a non-system app,
        // so the head unit never fills it.
        if (btMac.isNotEmpty) KeyValueRow('BT MAC', btMac),
        if (scooterName.isNotEmpty) KeyValueRow('Scooter BT Name', scooterName, key: const ValueKey('bt-scooter-name')),
      ],
    );
  }
}

class _MockWifi extends ConsumerWidget {
  const _MockWifi();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wifi = ref.watch(wifiProvider);
    final w = ref.read(wifiProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ToggleRow(key: const ValueKey('wifi-toggle'), label: 'Wi-Fi', value: wifi.enabled, onChanged: w.setEnabled),
        AnimatedSize(
          duration: DashMotion.fast,
          curve: DashMotion.valueCurve,
          alignment: Alignment.topLeft,
          child: !wifi.enabled
              ? const SizedBox.shrink()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in wifi.networks)
                      _NetworkRow(
                        key: ValueKey('wifi-${entry.ssid}'),
                        entry: entry,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          if (entry.status == WifiNetwork.connected) {
                            ref.read(wifiDetailsOpenProvider.notifier).open();
                          } else {
                            w.connect(entry.ssid);
                          }
                        },
                      ),
                    const SizedBox(height: 8),
                    wifi.scanning
                        ? Row(
                            children: [
                              SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: DashColors.ash),
                              ),
                              const SizedBox(width: 12),
                              Text('Scanning…', key: const ValueKey('wifi-scanning'), style: DashText.caption(16, color: DashColors.bone)),
                            ],
                          )
                        : PrimaryButton('Scan for networks', key: const ValueKey('wifi-scan'), onTap: w.scan),
                    const SizedBox(height: 12),
                  ],
                ),
        ),
      ],
    );
  }
}

class _LiveWifi extends ConsumerWidget {
  const _LiveWifi();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(vehicleProvider.select((v) => v.wifiConnected));
    return _StatusRow(key: const ValueKey('wifi-status'), label: 'Wi-Fi', on: on, text: on ? 'Online' : 'Not connected');
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({super.key, required this.label, required this.on, required this.text});
  final String label;
  final bool on;
  final String text;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: DashTouch.min,
        child: Row(
          children: [
            SizedBox(width: 220, child: Text(label, style: DashText.caption(20))),
            Expanded(
              child: Text(text, style: DashText.value(20, color: on ? null : DashColors.ash), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (on) _Badge('Connected', DashColors.eco),
          ],
        ),
      );
}

/// Opens the catalog's Android Settings entry: passcode first, then the
/// return pill, like opening it from Apps.
class _AndroidSettingsButton extends ConsumerWidget {
  const _AndroidSettingsButton(Key key, this.caption) : super(key: key);
  final String caption;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PrimaryButton(
            'Open Android Settings',
            onTap: () {
              uiTap('open-android-settings', {'from': 'connectivity'});
              ref.read(appManagerProvider.notifier).launch(appCatalog.firstWhere((a) => a.id == CatalogApp.androidSettingsId));
            },
          ),
          const SizedBox(height: 6),
          Text(caption, style: DashText.caption(15, color: DashColors.ash)),
          const SizedBox(height: 12),
        ],
      );
}

class _SystemPageButton extends ConsumerWidget {
  const _SystemPageButton(Key key, {required this.page, required this.label, required this.caption}) : super(key: key);
  final String page;
  final String label;
  final String caption;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PrimaryButton(
            label,
            onTap: () {
              uiTap('open-system-page', {'page': page});
              ref.read(appManagerProvider.notifier).openSystemPage(page, label);
            },
          ),
          const SizedBox(height: 6),
          Text(caption, style: DashText.caption(15, color: DashColors.ash)),
          const SizedBox(height: 12),
        ],
      );
}

/// What OpenDash has been allowed by Android, and the prompt to allow the
/// rest: the same one the Apps screen shows before an app opens.
class _AccessButton extends ConsumerWidget {
  const _AccessButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(accessProvider);
    final off = view.missing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PrimaryButton(
          'OpenDash access',
          key: const ValueKey('access-review'),
          onTap: () {
            uiTap('access-review');
            if (ref.read(ridingLockoutProvider)) return;
            ref.read(accessProvider.notifier).review();
          },
        ),
        const SizedBox(height: 6),
        Text(
          off.isEmpty
              ? 'Everything OpenDash needs from Android is allowed: showing over other apps, installing apps, music from CarPlay and Android Auto, knowing which app is in front, and being the home app.'
              : 'Off: ${off.map((a) => a.label).join(', ')}. Tap to allow.',
          key: const ValueKey('access-status'),
          style: DashText.caption(15, color: off.isEmpty ? DashColors.ash : DashColors.warning),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _NetworkRow extends StatelessWidget {
  const _NetworkRow({super.key, required this.entry, required this.onTap});
  final WifiEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (entry.status) {
      WifiNetwork.connected => ('Connected', DashColors.eco),
      WifiNetwork.saved => ('Saved', DashColors.ash),
      WifiNetwork.secured => ('Secured', DashColors.ash),
      WifiNetwork.open => ('Open', DashColors.ash),
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: 64,
        child: Row(
          children: [
            Opacity(opacity: 0.4 + 0.2 * entry.signalStrength, child: const WifiIcon(on: true)),
            const SizedBox(width: 18),
            Expanded(child: Text(entry.ssid, style: DashText.value(20))),
            if (entry.isSecured) ...[
              Icon(Icons.lock_rounded, size: 14, color: DashColors.ash),
              const SizedBox(width: 12),
            ],
            _Badge(label, color),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 1.5),
          borderRadius: BorderRadius.circular(DashRadius.chip),
        ),
        child: Text(text, style: DashText.caption(13, color: color)),
      );
}
