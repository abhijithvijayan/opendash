import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/vehicle_data.dart';
import '../../providers/mock_provider.dart';
import '../../state/crash_recovery.dart';
import '../../state/fault_history_state.dart';
import '../../state/overlay_state.dart';
import '../../state/passcode_gate.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/overlays/alert_overlay.dart';
import '../../widgets/overlays/call_overlay.dart';
import '../../widgets/status_bar/overlay_toolbar.dart';
import '../../widgets/status_bar/status_bar.dart';
import '../settings/widgets.dart';
import '../../theme/tokens.dart';
import 'battery_tab.dart';
import 'connections_tab.dart';
import '../../services/analytics_logger.dart';
import '../../services/fault_catalog.dart';
import '../../services/uds_dtc.dart';
import '../../state/active_faults.dart';
import '../../state/dtc_state.dart';

enum DiagTab {
  battery('Battery'),
  liveData('Live Data'),
  faultCodes('Fault codes'),
  connections('Connections');

  const DiagTab(this.label);
  final String label;
}

final diagTabProvider = NotifierProvider<DiagTabNotifier, DiagTab>(DiagTabNotifier.new);

class DiagTabNotifier extends Notifier<DiagTab> {
  @override
  DiagTab build() => DiagTab.battery;
  void set(DiagTab t) => state = t;
}

/// Battery deep-dive, live readouts and fault codes. Closes on the riding
/// lockout like every other overlay.
class DiagnosticsScreen extends ConsumerWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(diagnosticsOpenProvider);
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
    final tab = ref.watch(diagTabProvider);
    // While riding the full status bar is back, so the body drops under it
    // and carries its own back arrow: the toolbar is not there to close it.
    final toolbar = ref.watch(overlayToolbarVisibleProvider);
    final inset = toolbar ? 0.0 : StatusBar.height - OverlayToolbar.height;
    return ColoredBox(
      key: const ValueKey('diag-body'),
      color: DashColors.ink,
      child: Stack(
        children: [
          Positioned(
            left: 72,
            top: DashSpace.overlayTop + inset,
            child: Row(
              children: [
                if (!toolbar) ...[
                  BackArrow(key: const ValueKey('diag-back'), onTap: ref.read(diagnosticsOpenProvider.notifier).close),
                  const SizedBox(width: 16),
                ],
                for (final t in DiagTab.values) ...[
                  _Tab(
                    key: ValueKey('diag-tab-${t.name}'),
                    label: t.label,
                    active: tab == t,
                    onTap: () {
                      uiTap('diag-tab', {'tab': t.name});
                      ref.read(diagTabProvider.notifier).set(t);
                    },
                  ),
                  const SizedBox(width: 32),
                ],
              ],
            ),
          ),
          // Technicians look here, not for the About easter egg. The tab
          // row's right end is free; the bottom band is the battery tab's.
          if (toolbar)
            Positioned(
            right: DashSpace.gutter,
            top: DashSpace.overlayTop + inset,
            child: GestureDetector(
              key: const ValueKey('diag-service-mode'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                uiTap('diag-service-mode');
                ref.read(passcodeGateProvider.notifier).request(
                  purpose: 'Enter passcode for service mode',
                  onSuccess: ref.read(serviceModeOpenProvider.notifier).open,
                );
              },
              child: SizedBox(
                height: DashTouch.min,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.build_rounded, size: 18, color: DashColors.ash),
                    const SizedBox(width: 10),
                    Text('Service Mode', style: DashText.caption(15, color: DashColors.ash)),
                  ],
                ),
              ),
            ),
          ),
          // Keyed: the Service Mode entry above leaves this list when a ride
          // starts, and without a key the page was built again in its place,
          // back at the top of its scroll.
          Positioned(
            key: const ValueKey('diag-page'),
            left: DashSpace.gutter,
            right: DashSpace.gutter,
            top: DashSpace.overlayTop + 56 + inset,
            bottom: DashSpace.bodyBottom,
            child: AnimatedSwitcher(
              duration: DashMotion.fast,
              switchInCurve: Curves.linear,
              switchOutCurve: Curves.linear,
              transitionBuilder: DashMotion.fadeThrough,
              child: switch (tab) {
                DiagTab.battery => const BatteryTab(key: ValueKey('battery')),
                DiagTab.liveData => const _LiveData(key: ValueKey('live')),
                DiagTab.faultCodes => const _FaultCodes(key: ValueKey('faults')),
                DiagTab.connections => const ConnectionsTab(key: ValueKey('connections')),
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({super.key, required this.label, required this.active, required this.onTap});
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: SizedBox(
          height: DashTouch.min,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(label, style: DashText.value(18, color: active ? DashColors.bone : DashColors.ash)),
              ),
              AnimatedContainer(
                duration: DashMotion.fast,
                height: 2,
                width: active ? 48 : 0,
                color: DashColors.bone,
              ),
            ],
          ),
        ),
      );
}

class _Readout {
  const _Readout(this.label, this.unit, this.read, {this.boolean = false, this.decimals = 0});
  final String label;
  final String unit;
  final Object Function(VehicleData v) read;
  final bool boolean;
  final int decimals;
}

/// Readouts in scannable groups; the flat grid of seventeen was not.
final readoutGroups = <(String, List<_Readout>)>[
  ('Powertrain', [
    _Readout('Speed', 'km/h', (v) => v.speed),
    _Readout('RPM', 'rpm', (v) => v.rpm * VehicleData.rpmUnit),
    _Readout('Power', 'kW', (v) => v.power, decimals: 1),
    _Readout('Torque', 'Nm', (v) => v.torque),
  ]),
  ('Battery', [
    _Readout('Battery SoC', '%', (v) => v.socKnown ? v.batterySoc : '—'),
    _Readout('Battery Temp', '°C', (v) => v.batteryTempKnown ? v.batteryTemp : '—'),
    _Readout('Regen Energy', 'kWh', (v) => v.regenEnergy, decimals: 2),
    _Readout('Range', 'km', (v) => v.rangeKnown ? v.range : '—'),
  ]),
  ('Vehicle', [
    _Readout('Drive Mode', '', (v) => v.driveMode.label),
    _Readout('Vehicle State', '', (v) => v.vehicleState.name),
    _Readout('Lock State', '', (v) => v.lockState),
    _Readout('Motor Temp', '°C', (v) => v.motorTempKnown ? v.motorTemp : '—'),
    _Readout('Incline', '°', (v) => v.inclinationDegrees ?? '—'),
  ]),
  ('Indicators', [
    _Readout('Turn Left', '', (v) => v.turnLeft, boolean: true),
    _Readout('Turn Right', '', (v) => v.turnRight, boolean: true),
    _Readout('High Beam', '', (v) => v.highBeam, boolean: true),
    _Readout('Side Stand', '', (v) => v.sideStand, boolean: true),
    _Readout('Trunk Open', '', (v) => v.trunkOpen, boolean: true),
  ]),
  // Live rider inputs off CAN (0x113/0x15B): a stuck throttle or a brake that
  // never registers shows here. '—' until the frames arrive.
  ('Rider inputs', [
    _Readout('Throttle', 'V', (v) => v.liveInputs?.throttleV ?? '—', decimals: 2),
    _Readout('MCU Voltage', 'V', (v) => v.liveInputs?.mcuVoltage ?? '—', decimals: 1),
    _Readout('Front Brake', '', (v) => v.liveInputs?.frontBrake ?? '—', boolean: true),
    _Readout('Rear Brake', '', (v) => v.liveInputs?.rearBrake ?? '—', boolean: true),
  ]),
  // Motor-electrical telemetry (0x223/0x224).
  ('Motor electrical', [
    _Readout('Motor Current', 'A', (v) => v.liveInputs?.motorCurrent ?? '—'),
    _Readout('MCU DC Current', 'A', (v) => v.liveInputs?.mcuDcCurrent ?? '—', decimals: 1),
    _Readout('Motor Freq.', 'Hz', (v) => v.liveInputs?.motorFrequency ?? '—'),
  ]),
  // Handlebar switch clusters (0x6AC left / 0x6AD right): press a button and
  // watch it register — the way to spot a dead switch cluster.
  ('Handlebar switches', [
    _Readout('Beam', '', (v) => v.liveInputs?.beam ?? '—', boolean: true),
    _Readout('Left Ind.', '', (v) => v.liveInputs?.leftIndicator ?? '—', boolean: true),
    _Readout('Right Ind.', '', (v) => v.liveInputs?.rightIndicator ?? '—', boolean: true),
    _Readout('Horn', '', (v) => v.liveInputs?.horn ?? '—', boolean: true),
    _Readout('Cruise', '', (v) => v.liveInputs?.cruise ?? '—', boolean: true),
    _Readout('Mode Btn', '', (v) => v.liveInputs?.driveModeBtn ?? '—', boolean: true),
  ]),
];

class _LiveData extends ConsumerWidget {
  const _LiveData({super.key});

  static const columns = 4;
  static const spacing = 12.0;
  static const cardHeight = 78.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(vehicleProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return SingleChildScrollView(
          physics: const ClampingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (title, items) in readoutGroups) ...[
                SectionHeader(title),
                Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (final r in items)
                      SizedBox(
                        width: w,
                        height: cardHeight,
                        child: _ReadoutCard(key: ValueKey('diag-${r.label}'), readout: r, data: v),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ReadoutCard extends StatelessWidget {
  const _ReadoutCard({super.key, required this.readout, required this.data});
  final _Readout readout;
  final VehicleData data;

  @override
  Widget build(BuildContext context) {
    final raw = readout.read(data);
    Widget value;
    if (readout.boolean && raw is bool) {
      value = Text(raw ? 'ON' : 'OFF', style: DashText.value(28, color: raw ? DashColors.eco : DashColors.ash));
    } else if (raw is num) {
      // The value as it is, not eased toward it: this page is for reading
      // what the scooter says now.
      value = Text(raw.toStringAsFixed(readout.decimals), style: DashText.value(28));
    } else {
      value = Text('$raw', style: DashText.value(22));
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(color: DashColors.inkLift, borderRadius: BorderRadius.circular(DashRadius.card)),
      child: Stack(
        children: [
          Positioned(left: 0, top: 0, child: Text(readout.label, style: DashText.caption(13))),
          Positioned(right: 0, top: 0, child: Text(readout.unit, style: DashText.caption(13))),
          Align(alignment: Alignment.bottomCenter, child: value),
        ],
      ),
    );
  }
}

Color faultColor(FaultSeverity s) => switch (s) {
      FaultSeverity.critical || FaultSeverity.error => DashColors.critical,
      FaultSeverity.warning => DashColors.warning,
      FaultSeverity.info => DashColors.ash,
    };

String faultSeverityLabel(FaultSeverity s) => switch (s) {
      FaultSeverity.critical => 'Critical',
      FaultSeverity.error => 'Error',
      FaultSeverity.warning => 'Warning',
      FaultSeverity.info => 'Info',
    };

class _FaultCodes extends ConsumerWidget {
  const _FaultCodes({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(vehicleProvider.select((v) => v.faultActive));
    final code = ref.watch(vehicleProvider.select((v) => v.faultCode));
    final history = ref.watch(faultHistoryProvider);
    final faults = ref.watch(activeFaultsProvider);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 72,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(color: DashColors.inkLift, borderRadius: BorderRadius.circular(DashRadius.card)),
            child: Row(
              children: active
                  ? [
                      Icon(Icons.error_rounded, size: 26, color: DashColors.critical),
                      const SizedBox(width: 14),
                      // No invented code when the vehicle gave none.
                      Text(code.isEmpty ? 'Fault' : code, key: const ValueKey('diag-active-fault'), style: DashText.value(20)),
                      const SizedBox(width: 12),
                      Text(code.isEmpty ? 'Active' : FaultHistoryNotifier.titleFor(code), style: DashText.caption(15)),
                      const Spacer(),
                      _Badge('Active', DashColors.critical),
                    ]
                  : [
                      Icon(Icons.check_circle_rounded, size: 26, color: DashColors.eco),
                      const SizedBox(width: 14),
                      Text('No active faults', style: DashText.value(18)),
                    ],
            ),
          ),
          const SizedBox(height: 16),
          _EcuFaultRead(),
          if (faults.isNotEmpty) ...[
            const SizedBox(height: 16),
            SectionHeader('Live status bits · CAN (${faults.length})'),
            for (final f in faults)
              SizedBox(
                key: ValueKey('diag-canfault-${f.def.frame}-${f.def.bit}'),
                height: 46,
                child: Row(
                  children: [
                    Container(width: 4, height: 26, color: faultColor(f.severity)),
                    const SizedBox(width: 12),
                    SizedBox(width: 72, child: Text(f.component, style: DashText.caption(13, color: DashColors.ash))),
                    Expanded(child: Text(f.title, style: DashText.caption(15, color: DashColors.bone))),
                    _Badge(faultSeverityLabel(f.severity), faultColor(f.severity)),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 24),
          Text(
            'Read only. The list is what this dashboard has seen, not the vehicle\'s own fault memory.',
            style: DashText.caption(13, color: DashColors.ash),
          ),
          const SizedBox(height: 16),
          const SectionHeader('History'),
          if (history.isEmpty)
            Text(
              'No faults seen since OpenDash was installed.',
              key: const ValueKey('diag-fault-history-empty'),
              style: DashText.caption(15),
            ),
          for (final r in history)
            SizedBox(
              key: ValueKey('diag-fault-${r.raisedAt}'),
              height: 64,
              child: Row(
                children: [
                  SizedBox(width: 72, child: Text(r.code.isEmpty ? '—' : r.code, style: DashText.value(16))),
                  Expanded(child: Text(r.title, style: DashText.caption(14, color: DashColors.bone))),
                  Text(_faultDate(r.raisedAt), style: DashText.caption(14)),
                  const SizedBox(width: 20),
                  r.cleared ? _Badge('Cleared', DashColors.eco) : _Badge('Active', DashColors.critical),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

String _faultDate(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// The authoritative fault read — queries each ECU over UDS on demand and
/// lists its real trouble codes (active vs stored), like Ola's own app.
class _EcuFaultRead extends ConsumerWidget {
  const _EcuFaultRead();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dtc = ref.watch(dtcReadProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SectionHeader('ECU faults'),
            const Spacer(),
            GestureDetector(
              key: const ValueKey('diag-read-faults'),
              onTap: dtc.loading ? null : () => ref.read(dtcReadProvider.notifier).read(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(color: DashColors.inkLift, borderRadius: BorderRadius.circular(DashRadius.card)),
                child: Text(dtc.loading ? 'Reading…' : 'Read live', style: DashText.value(15, color: DashColors.bone)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (dtc.error != null)
          Text('Read failed: ${dtc.error}', style: DashText.caption(14, color: DashColors.critical)),
        for (final ecu in DtcEcu.values)
          if (dtc.results[ecu] case final r?) ...[
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 2),
              child: Row(
                children: [
                  Text(ecu.name.toUpperCase(), style: DashText.caption(13, color: DashColors.ash)),
                  const SizedBox(width: 10),
                  if (!r.responded)
                    Text('no response — power on to read', style: DashText.caption(13, color: DashColors.ash))
                  else if (r.dtcs.isEmpty)
                    Text('clean', style: DashText.caption(13, color: DashColors.eco)),
                ],
              ),
            ),
            for (final d in r.dtcs)
              SizedBox(
                height: 40,
                child: Row(
                  children: [
                    SizedBox(width: 76, child: Text(d.code, style: DashText.value(15))),
                    Expanded(child: Text(d.description, style: DashText.caption(14, color: DashColors.bone))),
                    _Badge(d.active ? 'Active' : 'Stored', d.active ? DashColors.critical : DashColors.ash),
                  ],
                ),
              ),
          ],
      ],
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
        decoration: BoxDecoration(border: Border.all(color: color, width: 1.5), borderRadius: BorderRadius.circular(DashRadius.chip)),
        child: Text(text, style: DashText.caption(13, color: color)),
      );
}
