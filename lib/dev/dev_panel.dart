import '../state/dash_island.dart';
import 'island_preview.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vehicle_data.dart';
import '../providers/battery_diagnostics_provider.dart';
import '../services/fault_catalog.dart';
import '../state/active_faults.dart';
import '../providers/mock_provider.dart';
import '../state/bt_settings.dart';
import '../state/control_panel.dart';
import '../state/boot_timeout.dart';
import '../state/crash_recovery.dart';
import '../state/error_state.dart';
import '../state/format_settings.dart';
import '../state/greeting_state.dart';
import '../state/passcode_gate.dart';
import '../state/riding_settings.dart';
import '../models/app_catalog.dart';
import '../services/mock_platform_service.dart';
import '../services/platform_provider.dart';
import '../state/access_state.dart';
import '../state/apps_state.dart';
import '../state/media_state.dart';
import '../state/firmware_state.dart';
import '../state/ota_state.dart';
import '../state/passcode_state.dart';
import '../state/screen_state.dart';
import '../state/settings_state.dart';
import '../state/theme_state.dart';
import '../state/toast_state.dart';
import '../state/wifi_state.dart';
import '../theme/dash_theme.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/debug/bookmark_gesture.dart';

const _dark = DashTheme.dark;

final devPanelOpenProvider = NotifierProvider<_OpenNotifier, bool>(_OpenNotifier.new);

class _OpenNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
}

/// Slide-in panel for driving the mock data. Development only.
class DevPanel extends ConsumerWidget {
  const DevPanel({super.key});

  static const width = 400.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(devPanelOpenProvider);
    return Stack(
      children: [
        Positioned(
          right: 0,
          bottom: 0,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => ref.read(devPanelOpenProvider.notifier).toggle(),
            child: SizedBox(
              width: 64,
              height: 64,
              child: Center(
                child: Icon(
                  open ? Icons.close_rounded : Icons.tune_rounded,
                  size: 22,
                  color: _dark.ash.withValues(alpha: open ? 0.9 : 0.3),
                ),
              ),
            ),
          ),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          right: open ? 0 : -width,
          top: 0,
          bottom: 64,
          width: width,
          // Unmounted while closed so the slider tree never rebuilds at 30Hz
          // behind the dashboard.
          child: open ? const _PanelBody() : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _PanelBody extends ConsumerStatefulWidget {
  const _PanelBody();

  @override
  ConsumerState<_PanelBody> createState() => _PanelBodyState();
}

class _PanelBodyState extends ConsumerState<_PanelBody> {
  final _faultCode = TextEditingController();

  @override
  void dispose() {
    _faultCode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(vehicleProvider);
    final n = ref.read(vehicleProvider.notifier);
    ref.watch(batteryDiagnosticsProvider);
    final demo = ref.watch(demoProvider);
    final screen = ref.watch(screenStateProvider);
    final session = ref.read(sessionProvider.notifier);
    final pass = ref.watch(passcodeProvider);

    return Material(
      color: const Color(0xF0101418),
      child: Theme(
        data: Theme.of(context).copyWith(
          sliderTheme: SliderThemeData(
            activeTrackColor: _dark.bone,
            inactiveTrackColor: _dark.slate,
            thumbColor: _dark.bone,
            overlayColor: Color(0x22ECEEF1),
            trackHeight: 3,
          ),
          switchTheme: SwitchThemeData(
            thumbColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.selected) ? _dark.ink : _dark.ash,
            ),
            trackColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.selected) ? _dark.bone : _dark.slate,
            ),
            trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
          ),
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 40),
          children: [
            Text('Mock data', style: DashText.title(24, color: _dark.bone)),
            const SizedBox(height: 4),
            Text('Drives the dashboard until the AIDL bridge lands.', style: DashText.caption(14, color: _dark.ash)),
            const SizedBox(height: 20),
            _Toggle(
              label: 'Demo ride',
              value: demo,
              onChanged: (on) => ref.read(demoProvider.notifier).set(on),
            ),
            // The mock cannot finish an install, so nothing else puts the
            // dashboard's way back to a projection app on screen.
            _Toggle(
              label: 'Back to CarPlay button',
              value: ref.watch(projectionResumeProvider) != null,
              onChanged: (on) {
                final resume = ref.read(projectionResumeProvider.notifier);
                on ? resume.offer(appCatalog.firstWhere((a) => a.id == 'carplay')) : resume.clear();
              },
            ),
            // The mock grants everything; this takes it all away again so the
            // access prompt has something to show.
            _Toggle(
              label: 'No Android access',
              value: ref.watch(accessProvider.select((v) => v.missing.isNotEmpty)),
              onChanged: (on) {
                final platform = ref.read(platformServiceProvider);
                if (platform is! MockPlatformService) return;
                platform
                  ..overlayAllowed = !on
                  ..installAllowed = !on
                  ..notificationAccess = !on
                  ..usageAccess = !on
                  ..defaultHome = !on;
                final access = ref.read(accessProvider.notifier);
                on ? access.review() : access.refresh();
              },
            ),
            _Toggle(
              label: 'Island preview',
              value: ref.watch(islandPreviewProvider) != null,
              onChanged: (on) => ref.read(islandPreviewProvider.notifier).set(on ? IslandPreview.backgrounds.first : null),
            ),
            if (ref.watch(islandPreviewProvider) != null)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final background in IslandPreview.backgrounds)
                    GestureDetector(
                      key: ValueKey('island-preview-$background'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => ref.read(islandPreviewProvider.notifier).set(background),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: ref.watch(islandPreviewProvider) == background ? _dark.bone : _dark.slate),
                        ),
                        child: Text(background, style: DashText.caption(14, color: _dark.bone)),
                      ),
                    ),
                ],
              ),
            Divider(color: _dark.slate, height: 32),
            Text('Vehicle state', style: DashText.caption(15, color: _dark.ash)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (label, state, go) in [
                  ('Boot', ScreenState.booting, session.reboot),
                  ('Lock', ScreenState.locked, () => n.setLocked(true)),
                  ('Parked', ScreenState.parked, () => n.setVehicleState(VehicleState.parked)),
                  ('Ready', ScreenState.ready, () => n.setVehicleState(VehicleState.ready)),
                  ('Riding', ScreenState.riding, () => n.setVehicleState(VehicleState.riding)),
                  ('Charging', ScreenState.charging, () => n.setCharging(true)),
                  ('Sleep', ScreenState.sleep, session.sleep),
                ])
                  _StateChip(
                    label: label,
                    active: screen == state,
                    onTap: () {
                      if (state != ScreenState.sleep) session.wake();
                      if (state != ScreenState.locked && state != ScreenState.booting) {
                        n.setLocked(false);
                      }
                      if (state != ScreenState.charging && v.isCharging) n.setCharging(false);
                      go();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    pass.lockedOut
                        ? 'Passcode locked out'
                        : 'Passcode attempts left: ${pass.attemptsRemaining}',
                    style: DashText.caption(15, color: _dark.bone),
                  ),
                ),
                _StateChip(
                  label: 'Reset lockout',
                  active: false,
                  onTap: ref.read(passcodeProvider.notifier).resetLockout,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _Toggle(
              label: 'HHMIS connected',
              value: v.hhmisConnected,
              onChanged: n.setConnected,
            ),
            Divider(color: _dark.slate, height: 32),
            _SliderRow(
              label: 'Speed',
              value: v.speed.toDouble(),
              max: 115,
              display: '${v.speed} km/h',
              onChanged: demo ? null : (x) => n.setSpeed(x.round()),
            ),
            _SliderRow(
              label: 'Battery',
              value: v.batterySoc.toDouble(),
              max: 100,
              display: '${v.batterySoc}%',
              onChanged: demo ? null : (x) => n.setBattery(x.round()),
            ),
            _SliderRow(
              label: 'Power',
              value: v.power,
              min: -4,
              max: 8.5,
              display: '${v.power.toStringAsFixed(1)} kW',
              onChanged: demo ? null : n.setPower,
            ),
            const SizedBox(height: 12),
            Text('Drive mode', style: DashText.caption(15, color: _dark.ash)),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final m in DriveMode.values) ...[
                  Expanded(
                    child: _ModeChip(
                      mode: m,
                      active: v.driveMode == m,
                      onTap: demo ? null : () => n.setDriveMode(m),
                    ),
                  ),
                  if (m != DriveMode.values.last) const SizedBox(width: 6),
                ],
              ],
            ),
            Divider(color: _dark.slate, height: 32),
            _Toggle(label: 'Turn left', value: v.turnLeft, onChanged: n.setTurnLeft),
            _Toggle(label: 'Turn right', value: v.turnRight, onChanged: n.setTurnRight),
            _Toggle(label: 'Low beam', value: v.lowBeam, onChanged: n.setLowBeam),
            _Toggle(label: 'High beam', value: v.highBeam, onChanged: n.setHighBeam),
            _Toggle(label: 'Side stand', value: v.sideStand, onChanged: n.setSideStand),
            // The two strips of `IdleLockWarning`, which only a real scooter
            // raises: here to look at them.
            ValueListenableBuilder<int?>(
              valueListenable: n.idleLockIn,
              builder: (context, left, _) =>
                  _Toggle(label: 'Lock countdown strip', value: left != null, onChanged: (on) => n.idleLockIn.value = on ? 8 : null),
            ),
            ValueListenableBuilder<bool>(
              valueListenable: n.standUpHint,
              builder: (context, shown, _) =>
                  _Toggle(label: 'Stand-up hint strip', value: shown, onChanged: (on) => n.standUpHint.value = on),
            ),
            _Toggle(
              label: 'Stand bypass',
              value: !ref.watch(ridingSettingsProvider.select((r) => r.isOn(RidingFeature.sideStandCutOff))),
              onChanged: (on) => ref.read(ridingSettingsProvider.notifier).forceFeature(RidingFeature.sideStandCutOff, !on),
            ),
            _Toggle(label: 'Custom mode set up', value: v.customRide.known, onChanged: n.setCustomRideSetUp),
            _Toggle(label: 'In custom mode', value: v.customRideActive, onChanged: n.setCustomRideActive),
            _Toggle(label: 'Charger plugged in', value: v.isCharging, onChanged: n.setCharging),
            _Toggle(label: 'Hypercharger', value: v.isHyperCharger, onChanged: n.setHyperCharger),
            _Toggle(label: 'Boost charger', value: v.isBoostCharger, onChanged: n.setBoostCharger),
            Text('Charger state${v.chargeStartTime.isEmpty ? '' : '  (started ${v.chargeStartTime})'}', style: DashText.caption(15, color: _dark.ash)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final cs in ChargingState.values)
                  if (cs != ChargingState.low)
                    _StateChip(label: cs.name, active: v.chargingState == cs, onTap: () => n.setChargerState(cs)),
              ],
            ),
            _SliderRow(
              label: 'Charge limit',
              value: v.chargeLimit.toDouble(),
              min: 50,
              max: 100,
              display: v.chargeLimit >= 100 ? 'none' : '${v.chargeLimit}%',
              onChanged: (x) => n.setChargeLimit(x.round()),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _StateChip(label: 'Disconnect charger', active: false, onTap: () => n.setCharging(false)),
                _StateChip(label: 'Fail lock', active: false, onTap: n.failLock),
                _StateChip(label: 'Fail unlock', active: false, onTap: n.failUnlock),
                _StateChip(label: 'Wi-Fi scan', active: false, onTap: ref.read(wifiProvider.notifier).scan),
                _StateChip(label: 'Wi-Fi fail', active: false, onTap: ref.read(wifiProvider.notifier).failConnection),
              ],
            ),
            const SizedBox(height: 6),
            _Toggle(label: 'Media playing', value: v.mediaPlaying, onChanged: n.setMediaPlaying),
            _Toggle(label: 'Navigation', value: v.navActive, onChanged: n.setNavActive),
            _Toggle(label: 'Limp mode', value: v.limpMode, onChanged: n.setLimpMode),
            _Toggle(label: 'Boot open', value: v.trunkOpen, onChanged: n.setTrunkOpen),
            Divider(color: _dark.slate, height: 32),
            _SliderRow(
              label: 'Ambient',
              value: v.ambientBrightness.toDouble(),
              max: 100,
              display: '${v.ambientBrightness}%',
              onChanged: (x) => n.setAmbient(x.round()),
            ),
            _Toggle(label: 'Light sensor works', value: v.ambientUsable, onChanged: n.setAmbientUsable),
            _SliderRow(
              label: 'Signal',
              value: v.signalBars.toDouble(),
              max: 4,
              display: '${v.signalBars} bars',
              onChanged: (x) => n.setSignalBars(x.round()),
            ),
            _Toggle(label: 'Wi-Fi', value: v.wifiConnected, onChanged: n.setWifi),
            _Toggle(label: 'GPS fix', value: v.gpsFix, onChanged: n.setGps),
            _Toggle(label: 'Notification', value: v.hasNotification, onChanged: n.setNotification),
            _Toggle(
              label: 'Left switch failure',
              value: ref.watch(leftSwitchFailureProvider),
              onChanged: ref.read(leftSwitchFailureProvider.notifier).set,
            ),
            Divider(color: _dark.slate, height: 32),
            Text('Alerts', style: DashText.title(18, color: _dark.bone)),
            const SizedBox(height: 8),
            _Toggle(label: 'Fault active', value: v.faultActive, onChanged: n.setFault),
            Row(
              children: [
                Expanded(child: Text('Fault code', style: DashText.caption(16, color: _dark.bone))),
                SizedBox(
                  width: 110,
                  height: 36,
                  child: TextField(
                    key: const ValueKey('dev-fault-code'),
                    controller: _faultCode,
                    onChanged: n.setFaultCode,
                    style: DashText.value(15, color: _dark.bone),
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'E042',
                      hintStyle: DashText.caption(15, color: _dark.ash),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: _dark.slate),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: _dark.bone),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            _Toggle(label: 'Deration', value: v.deratingActive, onChanged: n.setDerating),
            _Toggle(label: 'Brake worn', value: v.brakeWorn, onChanged: n.setBrakeWorn),
            _Toggle(label: 'Tamper detected', value: v.tamperDetected, onChanged: n.setTamper),
            _Toggle(label: 'Service due', value: v.serviceIndicator, onChanged: n.setServiceIndicator),
            _Toggle(label: 'Fall detected', value: v.fallDetected, onChanged: n.setFall),
            _Toggle(label: 'Accident detected', value: v.accidentDetected, onChanged: n.setAccident),
            _Toggle(label: 'Alarm state', value: v.alarmActive, onChanged: n.setAlarm),
            _Toggle(label: 'Thermal warning', value: v.thermalWarning, onChanged: n.setThermalWarning),
            _Toggle(label: 'Thermal runaway', value: v.thermalRunaway, onChanged: n.setThermalRunaway),
            _Toggle(label: 'Battery degraded', value: !v.batteryHealthGood, onChanged: (on) => n.setBatteryHealth(!on)),
            Divider(color: _dark.slate, height: 32),
            Text('Battery diagnostics', style: DashText.title(18, color: _dark.bone)),
            const SizedBox(height: 8),
            _Toggle(
              key: const ValueKey('dev-degraded-cells'),
              label: 'Degraded cells',
              value: ref.read(batteryDiagnosticsProvider.notifier).degradedCells,
              onChanged: ref.read(batteryDiagnosticsProvider.notifier).setDegradedCells,
            ),
            _Toggle(
              key: const ValueKey('dev-hot-pack'),
              label: 'Hot pack',
              value: ref.read(batteryDiagnosticsProvider.notifier).hotPack,
              onChanged: ref.read(batteryDiagnosticsProvider.notifier).setHotPack,
            ),
            _Toggle(
              key: const ValueKey('dev-balancing'),
              label: 'Balancing',
              value: ref.read(batteryDiagnosticsProvider.notifier).balancing,
              onChanged: ref.read(batteryDiagnosticsProvider.notifier).setBalancing,
            ),
            _Toggle(
              key: const ValueKey('dev-overvoltage'),
              label: 'Cell overvoltage',
              value: ref.read(batteryDiagnosticsProvider.notifier).overvoltage,
              onChanged: ref.read(batteryDiagnosticsProvider.notifier).setOvervoltage,
            ),
            _Toggle(
              key: const ValueKey('dev-faults'),
              label: 'Inject faults',
              value: ref.watch(activeFaultsProvider).isNotEmpty,
              onChanged: (on) =>
                  ref.read(activeFaultsProvider.notifier).set(on ? demoActiveFaults() : const []),
            ),
            _SliderRow(
              label: 'Motor temp',
              value: v.motorTemp.toDouble(),
              max: 180,
              display: '${v.motorTemp}°C',
              onChanged: demo ? null : (x) => n.setMotorTemp(x.round()),
            ),
            _SliderRow(
              label: 'Battery temp',
              value: v.batteryTemp.toDouble(),
              max: 75,
              display: '${v.batteryTemp}°C',
              onChanged: demo ? null : (x) => n.setBatteryTemp(x.round()),
            ),
            _SliderRow(
              label: 'BMS (PDU) temp',
              value: v.pduTemp.toDouble(),
              max: 120,
              display: '${v.pduTemp}°C',
              onChanged: demo ? null : (x) => n.setPduTemp(x.round()),
            ),
            _SliderRow(
              label: 'MCU temp',
              value: v.mcuTemp.toDouble(),
              max: 120,
              display: '${v.mcuTemp}°C',
              onChanged: demo ? null : (x) => n.setMcuTemp(x.round()),
            ),
            _SliderRow(
              label: 'Efficiency',
              value: v.rideEfficiency.clamp(0, 100).toDouble(),
              max: 100,
              display: '${v.rideEfficiency.round()} Wh/km',
              onChanged: demo ? null : n.setEfficiency,
            ),
            Row(
              children: [
                Expanded(child: Text('Regen energy', style: DashText.caption(16, color: _dark.bone))),
                Text('${v.regenEnergy.toStringAsFixed(2)} kWh', style: DashText.value(15, color: _dark.bone)),
              ],
            ),
            const SizedBox(height: 8),
            const SizedBox(height: 12),
            Text('Toasts', style: DashText.title(18, color: _dark.bone)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (label, msg, type) in [
                  ('Info', 'This is an info toast', ToastType.info),
                  ('Success', 'Action completed', ToastType.success),
                  ('Warning', 'Check your speed', ToastType.warning),
                  ('Error', 'Something went wrong', ToastType.error),
                ])
                  _StateChip(
                    label: '$label toast',
                    active: false,
                    onTap: () => ref.read(toastProvider.notifier).show(msg, type: type),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Tell-tales', style: DashText.title(18, color: _dark.bone)),
            const SizedBox(height: 8),
            Text('Cruise', style: DashText.caption(15, color: _dark.ash)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in CruiseMode.values)
                  _StateChip(
                    label: m.name,
                    active: v.cruiseMode == m,
                    onTap: () => n.setCruise(m),
                  ),
                _StateChip(label: 'Cruise set', active: v.cruiseMode == CruiseMode.active, onTap: () => n.setCruise(CruiseMode.active)),
              ],
            ),
            const SizedBox(height: 6),
            Text('Start hints', style: DashText.caption(15, color: _dark.ash)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _StateChip(label: 'Brake hint', active: v.hintBrakeToStart, onTap: n.showBrakeHint),
                _StateChip(label: 'Stand hint', active: v.hintStandToRide, onTap: n.showStandHint),
              ],
            ),
            const SizedBox(height: 6),
            _Toggle(label: 'Hill hold', value: v.hillHoldActive, onChanged: n.setHillHold),
            _Toggle(label: 'Adaptive Power Boost', value: v.apbActive, onChanged: n.setApb),
            _Toggle(label: 'Regen active', value: v.regenActive, onChanged: n.setRegenActive),
            _SliderRow(
              label: 'Regen mode',
              value: v.regenMode.index.toDouble(),
              max: 3,
              display: v.regenMode.label,
              onChanged: (x) => n.setRegenMode(RegenMode.values[x.round()]),
            ),
            _Toggle(
              label: v.takeMeHomeLights ? 'Take-me-home lights  ${v.takeMeHomeLightsRemaining}s' : 'Take-me-home lights',
              value: v.takeMeHomeLights,
              onChanged: n.setTakeMeHome,
            ),
            _Toggle(label: 'Position light', value: v.positionLight, onChanged: n.setPositionLight),
            _Toggle(label: 'Auto turn-off', value: v.autoTurnOff, onChanged: n.setAutoTurnOff),
            Divider(color: _dark.slate, height: 32),
            Text('Bluetooth / Media', style: DashText.title(18, color: _dark.bone)),
            const SizedBox(height: 8),
            _Toggle(label: 'BT connected', value: v.btConnected, onChanged: n.setBtConnected),
            Row(
              children: [
                Expanded(child: Text('Device', style: DashText.caption(16, color: _dark.bone))),
                Text(v.btDeviceName.isEmpty ? 'none' : v.btDeviceName, style: DashText.caption(15, color: _dark.ash)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _StateChip(label: 'Open BT screen', active: false,
                    onTap: ref.read(btScreenOpenProvider.notifier).open),
                _StateChip(label: 'Open Settings', active: false,
                    onTap: ref.read(settingsScreenOpenProvider.notifier).open),
                _StateChip(label: 'Prev track', active: false, onTap: n.mediaPrev),
                _StateChip(label: 'Next track', active: false, onTap: n.mediaNext),
              ],
            ),
            const SizedBox(height: 8),
            _SliderRow(
              label: 'Volume',
              value: v.volume.toDouble(),
              max: 100,
              display: '${v.volume}%',
              onChanged: (x) => n.setVolume(x.round(), announce: false),
            ),
            _Toggle(label: 'Music on speaker', value: v.musicOnSpeaker, onChanged: (_) => n.toggleMusicOnSpeaker()),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _StateChip(label: 'Incoming call', active: v.callIncoming, onTap: n.simulateIncomingCall),
                _StateChip(label: 'End call', active: false, onTap: n.endCall),
                _StateChip(label: 'Pair BT', active: v.btPairingCode.isNotEmpty, onTap: n.startPairing),
                _StateChip(
                    label: 'Phone pairing',
                    active: ref.watch(btSettingsProvider.select((b) => b.pairingOpen)),
                    onTap: ref.read(btSettingsProvider.notifier).simulatePairingRequest),
                _StateChip(
                    label: 'Pairing failed',
                    active: ref.watch(btSettingsProvider.select((b) => b.pairFailed)),
                    onTap: ref.read(btSettingsProvider.notifier).simulatePairFailed),
              ],
            ),
            const SizedBox(height: 6),
            _Toggle(label: 'Active call', value: v.callActive, onChanged: n.setCallActive),
            _Toggle(label: 'Reject with message', value: v.rejectCallAllowed, onChanged: n.setRejectCallAllowed),
            _Toggle(label: 'Mute', value: v.callMuted, onChanged: (_) => n.toggleCallMute()),
            Divider(color: _dark.slate, height: 32),
            Text('Addons', style: DashText.title(18, color: _dark.bone)),
            const SizedBox(height: 8),
            Text('Nav direction  (${v.distanceToTurn.isEmpty ? 'no nav' : v.distanceToTurn})', style: DashText.caption(15, color: _dark.ash)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (label, dir) in [
                  ('Turn left', 'Turn left onto Brigade Road'),
                  ('Turn right', 'Turn right onto MG Road'),
                  ('Continue', 'Continue straight for 2 km'),
                  ('Arrive', 'Arrive at destination'),
                ])
                  _StateChip(label: label, active: v.nextTurnDirection == dir, onTap: () => n.setNavDirection(dir)),
              ],
            ),
            const SizedBox(height: 6),
            _Toggle(label: 'Nav ETA', value: v.navTotalDistance.isNotEmpty, onChanged: n.setNavEta),
            const SizedBox(height: 10),
            Text('Theme', style: DashText.caption(15, color: _dark.ash)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in DashTheme.builtIn)
                  _StateChip(
                    label: t.name,
                    active: ref.watch(themeProvider).name == t.name,
                    onTap: () => ref.read(themeProvider.notifier).setTheme(t),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _StateChip(label: 'Open Apps', active: false, onTap: ref.read(appLauncherOpenProvider.notifier).open),
              ],
            ),
            _Toggle(
              label: 'Launch placeholder',
              value: ref.watch(mockAppProvider) != null,
              onChanged: (on) => on
                  ? ref.read(mockAppProvider.notifier).show(appCatalog.first)
                  : ref.read(mockAppProvider.notifier).close(),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _StateChip(label: 'Safe mode', active: false, onTap: ref.read(crashRecoveryProvider.notifier).enterSafeMode),
                _StateChip(label: 'Service mode', active: false, onTap: ref.read(serviceModeOpenProvider.notifier).open),
              ],
            ),
            Builder(builder: (context) {
              final r = ref.watch(ridingSettingsProvider);
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(r.speedLimitEnabled ? 'Speed limit ${r.speedLimit} km/h' : 'No speed limit', style: DashText.caption(14, color: _dark.ash)),
              );
            }),
            Divider(color: _dark.slate, height: 32),
            Text('Session', style: DashText.title(18, color: _dark.bone)),
            const SizedBox(height: 8),
            Text('Time format', style: DashText.caption(15, color: _dark.ash)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _StateChip(label: '12H', active: !ref.watch(use24HourProvider), onTap: () => ref.read(use24HourProvider.notifier).set(false)),
                _StateChip(label: '24H', active: ref.watch(use24HourProvider), onTap: () => ref.read(use24HourProvider.notifier).set(true)),
              ],
            ),
            const SizedBox(height: 8),
            Text('Units', style: DashText.caption(15, color: _dark.ash)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _StateChip(label: 'km', active: !ref.watch(useMilesProvider), onTap: () => ref.read(useMilesProvider.notifier).set(false)),
                _StateChip(label: 'mi', active: ref.watch(useMilesProvider), onTap: () => ref.read(useMilesProvider.notifier).set(true)),
                _StateChip(label: '°C', active: !ref.watch(useFahrenheitProvider), onTap: () => ref.read(useFahrenheitProvider.notifier).set(false)),
                _StateChip(label: '°F', active: ref.watch(useFahrenheitProvider), onTap: () => ref.read(useFahrenheitProvider.notifier).set(true)),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _StateChip(label: 'Locking sim', active: ref.watch(lockingProvider), onTap: () {
                  ref.read(controlPanelOpenProvider.notifier).open();
                  ref.read(lockingProvider.notifier).start();
                }),
                _StateChip(label: 'Add bookmark', active: false, onTap: ref.read(bookmarkProvider.notifier).add),
                _StateChip(label: 'Trigger error', active: ref.watch(appErrorProvider) != null, onTap: () {
                  ref.read(appErrorProvider.notifier).capture(() => throw StateError('Dev panel test error'));
                }),
                _StateChip(label: 'AIDL timeout', active: ref.watch(bootTimeoutProvider) != BootTimeout.waiting,
                    onTap: session.simulateAidlTimeout),
                _StateChip(label: 'Greeting', active: ref.watch(greetingProvider) != null, onTap: ref.read(greetingProvider.notifier).show),
                _StateChip(
                  label: 'Passcode gate',
                  active: ref.watch(passcodeGateProvider).open,
                  onTap: () => ref.read(passcodeGateProvider.notifier).request(
                        purpose: 'Enter passcode to continue',
                        onSuccess: () => ref.read(toastProvider.notifier).show('Passcode accepted'),
                      ),
                ),
              ],
            ),
            Divider(color: _dark.slate, height: 32),
            Text('Scooter firmware', style: DashText.title(18, color: _dark.bone)),
            const SizedBox(height: 4),
            Builder(builder: (context) {
              final fw = ref.watch(firmwareProvider);
              final f = ref.read(firmwareProvider.notifier);
              void notice(Map<String, Object?> m) => f.onNotice({'version': '4.7.1', 'size': '431000000', 'notes': _fwNotes, ...m});
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Mode ${fw.mode.name}  ·  autodl ${v.stockAutoDownload ?? 'unseen'}  ·  '
                    'notice ${fw.notice?.kind ?? 'none'}${fw.installing ? '  ·  installing ${fw.installProgress}%' : ''}',
                    style: DashText.caption(15, color: _dark.ash),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _StateChip(label: 'No notice', active: false, onTap: () => f.onNotice(const {'kind': 'up_to_date', 'status': 'System is up-to-date'})),
                      _StateChip(label: 'Available', active: false, onTap: () => notice({'kind': 'available', 'button': true, 'reason': 0})),
                      for (final (label, reason) in const [('Wi-Fi only', 1), ('No connection', 2), ('Needs Wi-Fi', 3), ('Low charge', 4)])
                        _StateChip(label: 'Avail: $label', active: false, onTap: () => notice({'kind': 'available', 'button': reason == 1, 'reason': reason})),
                      _StateChip(label: 'Download done', active: false, onTap: () => notice({'kind': 'download_done', 'button': true, 'reason': 0})),
                      _StateChip(label: 'Done: low charge', active: false, onTap: () => notice({'kind': 'download_done', 'button': false, 'reason': 1})),
                      _StateChip(label: 'Install 40%', active: false, onTap: () => f.onNotice(const {'kind': 'install_progress', 'state': 3, 'progress': 40})),
                      _StateChip(label: 'Install failed', active: false, onTap: () => notice({'kind': 'install_failed', 'state': 6})),
                      _StateChip(label: 'First boot after', active: false, onTap: () => f.onNotice(const {'kind': 'first_boot'})),
                      _StateChip(label: 'Autodl 1', active: v.stockAutoDownload == 1, onTap: () => n.setStockAutoDownload(1)),
                      _StateChip(label: 'Autodl 0', active: v.stockAutoDownload == 0, onTap: () => n.setStockAutoDownload(0)),
                      _StateChip(label: 'Autodl unseen', active: v.stockAutoDownload == null, onTap: () => n.setStockAutoDownload(null)),
                      _StateChip(label: 'Idle-lock warning', active: n.idleLockIn.value != null, onTap: () => n.idleLockIn.value = n.idleLockIn.value == null ? 8 : null),
                      _StateChip(label: 'ECU version change', active: false, onTap: () => f.onVersion('1', 'dev-${fw.hashCode}')),
                      _StateChip(label: 'Head-unit change', active: false, onTap: () => f.onVersion('3', 'dev-${fw.hashCode}')),
                    ],
                  ),
                ],
              );
            }),
            Divider(color: _dark.slate, height: 32),
            Text('OpenDash update (fake release source)', style: DashText.title(18, color: _dark.bone)),
            const SizedBox(height: 4),
            Builder(builder: (context) {
              final ota = ref.watch(otaProvider);
              final o = ref.read(otaProvider.notifier);
              final platform = ref.read(platformServiceProvider);
              if (platform is! MockPlatformService) return const SizedBox.shrink();
              void source({int status = 200, int? build, String sha = 'c0ffee', String? signer, bool download = true}) {
                platform
                  ..checkStatus = status
                  ..release = build == null ? null : MockPlatformService.fakeRelease(build: build)
                  ..downloadedSha = sha
                  ..downloadedSigner = signer ?? MockPlatformService.ownSigner
                  ..downloadFails = !download;
                o.check();
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Status: ${ota.status.name}${ota.status == OtaStatus.downloading ? '  ${ota.progress}%' : ''}'
                    '  ·  installed build ${platform.installedBuild}',
                    style: DashText.caption(15, color: _dark.ash),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _StateChip(label: 'Check: newer', active: false, onTap: () => source(build: platform.installedBuild + 20)),
                      _StateChip(label: 'Check: none newer', active: false, onTap: () => source(build: platform.installedBuild)),
                      _StateChip(label: 'Check: fails', active: false, onTap: () => source(status: 0, build: 1)),
                      _StateChip(label: 'Newer, download fails', active: false, onTap: () => source(build: platform.installedBuild + 21, download: false)),
                      _StateChip(label: 'Newer, bad checksum', active: false, onTap: () => source(build: platform.installedBuild + 22, sha: 'bad')),
                      _StateChip(label: 'Newer, wrong signer', active: false, onTap: () => source(build: platform.installedBuild + 23, signer: 'other')),
                      _StateChip(label: 'Installer refuses', active: platform.installError != null, onTap: () => platform.installError = platform.installError == null ? 'refused' : null),
                      _StateChip(label: 'Open Updates', active: false, onTap: ref.read(otaScreenOpenProvider.notifier).open),
                    ],
                  ),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.max,
    required this.display,
    required this.onChanged,
    this.min = 0,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: DashText.caption(15, color: _dark.ash)),
            Text(display, style: DashText.value(15, color: _dark.bone)),
          ],
        ),
        SizedBox(
          height: 36,
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({super.key, required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(label, style: DashText.caption(16, color: _dark.bone))),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

const _fwNotes = '{"releaseNotes": ["A sample release note", "Another line from the notice"]}';

class _StateChip extends StatelessWidget {
  const _StateChip({required this.label, required this.active, required this.onTap});
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: active ? _dark.bone.withValues(alpha: 0.14) : Colors.transparent,
          border: Border.all(color: active ? _dark.bone : _dark.slate, width: 1.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          widthFactor: 1,
          child: Text(label, style: DashText.caption(14, color: active ? _dark.bone : _dark.ash)),
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.mode, required this.active, required this.onTap});
  final DriveMode mode;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = DashColors.forMode(mode);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 40,
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.18) : Colors.transparent,
          border: Border.all(color: active ? color : _dark.slate, width: 1.5),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(mode.label, style: DashText.mode(active ? color : _dark.ash, size: 11)),
      ),
    );
  }
}
