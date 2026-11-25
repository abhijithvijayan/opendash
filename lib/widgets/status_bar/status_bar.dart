import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../models/battery_health.dart';
import '../../models/vehicle_data.dart';
import '../../providers/mock_provider.dart';
import '../../state/battery_health_state.dart';
import '../../state/riding_settings.dart';
import '../../state/control_panel.dart';
import '../../state/crash_recovery.dart';
import '../../state/error_state.dart';
import '../../state/media_state.dart';
import '../../state/firmware_state.dart';
import '../../state/ota_state.dart';
import '../../state/riding_lockout.dart';
import '../../state/screen_state.dart';
import '../../state/apps_state.dart';
import '../../state/settings_state.dart';
import '../../state/theme_state.dart';
import '../../screens/diagnostics/diagnostics_screen.dart';
import '../../state/toast_state.dart';
import '../../theme/colors.dart';
import '../../theme/dash_theme.dart';
import '../../theme/typography.dart';
import '../indicators/beam_icon.dart';
import '../indicators/telltale_icons.dart';
import '../indicators/turn_arrow.dart';
import '../../theme/tokens.dart';
import 'status_icons.dart';
import '../debug/bookmark_gesture.dart';
import '../../services/analytics_logger.dart';

/// 72px strip across the top of every screen. Tell-tales on the left, clock
/// in the centre, connectivity on the right.
class StatusBar extends ConsumerWidget {
  const StatusBar({super.key});

  static const height = 72.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final turnLeft = ref.watch(vehicleProvider.select((v) => v.turnLeft));
    final turnRight = ref.watch(vehicleProvider.select((v) => v.turnRight));
    final hazard = ref.watch(vehicleProvider.select((v) => v.hazard));
    final highBeam = ref.watch(vehicleProvider.select((v) => v.highBeam));
    final lowBeam = ref.watch(vehicleProvider.select((v) => v.lowBeam));
    final beamAuto = ref.watch(
      vehicleProvider.select((v) => v.smartHeadlight == SmartHeadlight.auto && (v.highBeam || v.lowBeam)),
    );
    final positionLight = ref.watch(vehicleProvider.select((v) => v.positionLight));
    final sideStand = ref.watch(vehicleProvider.select((v) => v.sideStand));
    final trunkOpen = ref.watch(
      vehicleProvider.select((v) => v.trunkOpen && v.trunkStateKnown),
    );
    final time = ref.watch(vehicleProvider.select((v) => v.time));
    final bars = ref.watch(vehicleProvider.select((v) => v.signalBars));
    final wifi = ref.watch(vehicleProvider.select((v) => v.wifiConnected));
    final bt = ref.watch(vehicleProvider.select((v) => v.btConnected));
    final btDot = ref.watch(vehicleProvider.select((v) => !v.btConnected
        ? null
        : v.callActive
            ? DashColors.normal
            : v.mediaPlaying
                ? DashColors.eco
                : null));
    final riding = ref.watch(ridingLockoutProvider);
    final locked = ref.watch(vehicleProvider.select((v) => v.locked));
    // Settings, apps, Bluetooth and the OTA bell need the scooter unlocked
    // and stopped; the rest of the strip is read-only.
    final interactive = !riding && !locked;
    final errorMinimized = ref.watch(errorMinimizedProvider);
    final badge = ref.watch(bellProvider);
    final theme = ref.watch(uiThemeProvider);
    final batteryTemp = ref.watch(vehicleProvider.select((v) => v.batteryTemp));
    final serviceDue = ref.watch(vehicleProvider.select((v) => v.serviceIndicator && VehicleData.serviceIndicatorVerified));
    final gps = ref.watch(vehicleProvider.select((v) => v.gpsFix));
    final cellWarning = ref.watch(cellWarningProvider);
    final trueRangeOn = ref.watch(
      ridingSettingsProvider.select((s) => s.isOn(RidingFeature.predictedRange)),
    );
    final leftSwitchFailed = ref.watch(leftSwitchFailureProvider);
    final noData = ref.watch(sessionProvider.select((s) => s.noData)) &&
        !ref.watch(vehicleProvider.select((v) => v.hhmisConnected));

    return SizedBox(
      height: height,
      child: Stack(
        children: [
          Positioned(left: 40, top: 16, child: TurnArrow(on: turnLeft || hazard, left: true, hazard: hazard)),
          Positioned(right: 40, top: 16, child: TurnArrow(on: turnRight || hazard, left: false, hazard: hazard)),
          Positioned(
            left: 128,
            top: 22,
            child: Row(
              children: [
                BeamIcon(high: false, on: lowBeam && !highBeam),
                const SizedBox(width: 18),
                BeamIcon(high: true, on: highBeam),
                if (beamAuto) ...[
                  const SizedBox(width: 8),
                  Text(
                    'AUTO',
                    key: const ValueKey('status-beam-auto'),
                    style: DashText.caption(15, color: highBeam ? DashColors.normal : DashColors.eco)
                        .copyWith(letterSpacing: 0.8),
                  ),
                ],
                // The DRL stays lit with either beam on the scooter, so its
                // telltale stays too.
                if (positionLight) ...[
                  const SizedBox(width: 18),
                  TelltaleIcon(
                    key: const ValueKey('status-position-light'),
                    glyph: TelltaleGlyph.positionLight,
                    color: theme.eco,
                    background: theme.ink,
                  ),
                ],
                if (sideStand) ...[
                  const SizedBox(width: 26),
                  _Chip('side stand'),
                ],
                if (trunkOpen) ...[
                  const SizedBox(width: 22),
                  Padding(padding: EdgeInsets.only(top: 3), child: TrunkOpenIcon()),
                ],
                if (leftSwitchFailed) ...[
                  const SizedBox(width: 22),
                  _Chip('left switch', icon: Icons.bolt_rounded),
                ],
                if (noData) ...[
                  const SizedBox(width: 22),
                  _Chip('No data', key: const ValueKey('status-no-data'), icon: Icons.link_off_rounded),
                ],
                if (errorMinimized) ...[
                  const SizedBox(width: 22),
                  GestureDetector(
                    key: const ValueKey('status-error'),
                    behavior: HitTestBehavior.opaque,
                    onTap: ref.read(errorMinimizedProvider.notifier).expand,
                    child: _Chip('Error — tap to view', icon: Icons.error_outline_rounded),
                  ),
                ],
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: height,
            child: Center(
              child: GestureDetector(
                key: const ValueKey('status-clock'),
                behavior: HitTestBehavior.opaque,
                // Triple-tap drops a `user.bookmark` into the analytics log.
                onTap: ref.read(bookmarkProvider.notifier).tap,
                onLongPress: () => ref.read(toastProvider.notifier).show('$appName v$appVersion'),
                child: SizedBox(
                  height: DashTouch.min,
                  child: Center(
                    widthFactor: 1,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(time, style: DashText.clock.copyWith(color: theme.bone)),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            right: 112,
            top: (height - DashTouch.min) / 2,
            child: Row(
              children: [
                const SizedBox(height: DashTouch.min),
                if (interactive) ...[
                  GestureDetector(
                    key: const ValueKey('status-apps'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      uiTap('status-apps');
                      ref.read(appLauncherOpenProvider.notifier).open();
                    },
                    child: SizedBox(
                      width: DashTouch.min,
                      height: DashTouch.min,
                      child: Center(child: AppsIcon(size: 24)),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                if (interactive)
                  GestureDetector(
                    key: const ValueKey('status-settings'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      uiTap('status-settings');
                      ref.read(settingsScreenOpenProvider.notifier).open();
                    },
                    child: SizedBox(
                      width: DashTouch.min,
                      height: DashTouch.min,
                      child: Center(child: GearIcon(color: DashColors.ash, size: 24)),
                    ),
                  ),
                if (interactive) const SizedBox(width: 10),
                SignalIcon(bars: bars),
                const SizedBox(width: 20),
                // Tap: Android's Wi-Fi panel, to pick a network as on stock.
                // Long-press: Settings → Connectivity.
                GestureDetector(
                  key: const ValueKey('status-wifi'),
                  behavior: HitTestBehavior.opaque,
                  onTap: interactive
                      ? () {
                          uiTap('status-wifi');
                          ref.read(appManagerProvider.notifier).openWifiPanel('status_bar');
                        }
                      : null,
                  onLongPress: interactive
                      ? () {
                          uiLongPress('status-wifi');
                          ref.read(settingsScreenOpenProvider.notifier).open();
                          if (ref.read(settingsScreenOpenProvider)) {
                            ref.read(settingsSectionProvider.notifier).set(SettingsSection.connectivity);
                          }
                        }
                      : null,
                  child: SizedBox(width: DashTouch.min, height: DashTouch.min, child: Center(child: WifiIcon(on: wifi))),
                ),
                const SizedBox(width: 7),
                GestureDetector(
                  key: const ValueKey('status-bt'),
                  behavior: HitTestBehavior.opaque,
                  onTap: interactive ? ref.read(btScreenOpenProvider.notifier).open : null,
                  onLongPress: interactive ? ref.read(btScreenOpenProvider.notifier).open : null,
                  child: SizedBox(
                    width: DashTouch.min,
                    height: DashTouch.min,
                    child: Center(child: BluetoothIcon(on: bt, dot: btDot)),
                  ),
                ),
                const SizedBox(width: 7),
                // Nothing reports a GPS fix on the head
                // unit (location permission), so no icon rather than a
                // constant "no fix".
                if (!useAidlVehicle) GpsIcon(on: gps),
                SizedBox(width: useAidlVehicle ? 3 : 10),
                if (batteryTemp > 40) ...[
                  SizedBox(
                    key: const ValueKey('status-temp'),
                    width: 24,
                    child: Center(child: ThermometerIcon(color: batteryTemp > 50 ? theme.critical : theme.warning)),
                  ),
                  const SizedBox(width: 6),
                ],
                if (serviceDue) ...[
                  SizedBox(
                    key: const ValueKey('status-service'),
                    width: 24,
                    child: Center(child: WrenchIcon(color: theme.warning)),
                  ),
                  const SizedBox(width: 6),
                ],
                if (trueRangeOn && cellWarning != null && cellWarning.severity != CellWarningSeverity.advisory)
                  _CellWarningButton(warning: cellWarning, theme: theme),
                GestureDetector(
                  key: const ValueKey('status-bell'),
                  behavior: HitTestBehavior.opaque,
                  onTap: badge && interactive ? ref.read(otaScreenOpenProvider.notifier).open : null,
                  child: SizedBox(
                    width: DashTouch.min,
                    height: DashTouch.min,
                    child: Center(child: BellIcon(badge: badge)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Weak cell", spelled out: as a 16 px battery glyph with a mark in it,
/// beside the bell, a rider could not tell what it was. It is
/// there while a cell is giving way under load and for a few seconds
/// after, not for a pack that merely rests uneven. A tap says which cell
/// and by how much, with the way to the battery page.
class _CellWarningButton extends ConsumerWidget {
  const _CellWarningButton({required this.warning, required this.theme});
  final CellWarning warning;
  final DashTheme theme;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = theme.warning;
    return GestureDetector(
      key: const ValueKey('status-cell-warning'),
      behavior: HitTestBehavior.opaque,
      onTap: () {
        uiTap('status-cell-warning', {'cell': warning.weakCellIndex});
        ref.read(toastProvider.notifier).show(warning.message, type: ToastType.warning, duration: const Duration(seconds: 6));
        // Parked, the battery page shows every cell; on the move the
        // message is all there is room and attention for.
        if (!ref.read(ridingLockoutProvider) && !ref.read(vehicleProvider).locked) {
          ref.read(diagTabProvider.notifier).set(DiagTab.battery);
          ref.read(diagnosticsOpenProvider.notifier).open();
        }
      },
      child: SizedBox(
        height: DashTouch.min,
        child: Center(
          child: Container(
            height: 28,
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(DashRadius.chip),
              border: Border.all(color: color, width: 1.2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CellWarningIcon(color: color),
                const SizedBox(width: 6),
                Text('Weak cell', style: DashText.caption(14, color: color)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label, {super.key, this.icon});
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: DashColors.warning, width: 1.5),
        borderRadius: BorderRadius.circular(DashRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: DashColors.warning),
            const SizedBox(width: 4),
          ],
          Text(label, style: DashText.caption(15, color: DashColors.warning)),
        ],
      ),
    );
  }
}
