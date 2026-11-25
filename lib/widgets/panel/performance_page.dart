import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/vehicle_data.dart';
import '../../providers/mock_provider.dart';
import '../../state/format_settings.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../gauges/power_bar.dart';
import 'rpm_gauge.dart';
import 'widget_panel.dart';

/// The S1 Pro's peak torque: the bar's end until this scooter reports more.
const torqueMax = 58.0;

/// The next ten above the highest torque seen, never under [torqueMax].
double torqueMaxFor(int peakNm) => peakNm <= torqueMax ? torqueMax : (peakNm / 10).ceil() * 10.0;

/// "3,600": real rpm with a thousands separator. HHMIS reports hundreds, so
/// the figure moves in steps of 100 and is not tweened through digits the
/// motor controller never sent.
String rpmText(int rpm) {
  final s = '$rpm';
  return s.length > 3 ? '${s.substring(0, s.length - 3)},${s.substring(s.length - 3)}' : s;
}

/// Signed fraction for the centre-zero power bar: +1 at full power, -1 at
/// full regen.
double powerFraction(double kw, {double maxPower = PowerBar.defaultMaxPower, double maxRegen = defaultMaxRegen}) => kw >= 0
    ? (kw / maxPower).clamp(0.0, 1.0).toDouble()
    : -(kw.abs() / maxRegen).clamp(0.0, 1.0).toDouble();

class PerformancePage extends ConsumerWidget {
  const PerformancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(accentProvider);
    final rpm = ref.watch(vehicleProvider.select((v) => v.rpm)) * VehicleData.rpmUnit;
    final power = ref.watch(vehicleProvider.select((v) => v.power));
    final torque = ref.watch(vehicleProvider.select((v) => v.torque));
    final maxPower = ref.watch(vehicleProvider.select(powerBarMaxFor));
    final maxRegen = ref.watch(vehicleProvider.select(regenBarMaxFor));
    final peaks = ref.watch(vehicleProvider.select((v) => v.peaks));
    // The scooter's own derate thresholds (live from its config frames). The
    // readout goes amber at our advance point (derate minus thermalAdvance,
    // matching the banner) and red at the Park error.
    final limits = ref.watch(vehicleProvider.select((v) => v.thermalLimits));
    const adv = VehicleData.thermalAdvance;
    final motorTemp = ref.watch(vehicleProvider.select((v) => v.motorTemp));
    final tempKnown = ref.watch(vehicleProvider.select((v) => v.motorTempKnown));
    final batteryTemp = ref.watch(vehicleProvider.select((v) => v.batteryTemp));
    final batteryTempKnown = ref.watch(vehicleProvider.select((v) => v.batteryTempKnown));
    final batteryTint = batteryTempKnown
        ? tempColor(batteryTemp, warn: limits.cellWarn - adv, danger: limits.cellError)
        : DashColors.ash;
    final pduTemp = ref.watch(vehicleProvider.select((v) => v.pduTemp));
    final pduTempKnown = ref.watch(vehicleProvider.select((v) => v.pduTempKnown));
    final pduTint =
        pduTempKnown ? tempColor(pduTemp, warn: limits.pduWarn - adv, danger: limits.pduError) : DashColors.ash;
    final mcuTemp = ref.watch(vehicleProvider.select((v) => v.mcuTemp));
    final mcuTempKnown = ref.watch(vehicleProvider.select((v) => v.mcuTempKnown));
    final mcuTint =
        mcuTempKnown ? tempColor(mcuTemp, warn: limits.mcuWarn - adv, danger: limits.mcuError) : DashColors.ash;
    final useF = ref.watch(useFahrenheitProvider);
    final tempTint =
        tempKnown ? tempColor(motorTemp, warn: limits.motorWarn - adv, danger: limits.motorError) : DashColors.ash;

    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 0, 40, WidgetPanel.dotsReserve),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Motor', style: DashText.caption(14)),
              const SizedBox(height: 6),
              Center(
                child: Column(
                  children: [
                    RpmGauge(rpm: rpm, accent: accent, max: rpmMaxFor(peaks.rpm * VehicleData.rpmUnit)),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(rpmText(rpm), key: const ValueKey('rpm-value'), style: DashText.value(32)),
                        const SizedBox(width: 6),
                        Text('rpm', style: DashText.caption(16)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DataCard(
            label: power < 0 ? 'Regen' : 'Power',
            value: power.abs(),
            unit: 'kW',
            decimals: 1,
            valueSize: 28,
            valueColor: power < 0 ? DashColors.bone : accent,
            child: DataBar(
              fraction: powerFraction(power, maxPower: maxPower, maxRegen: maxRegen),
              color: accent,
              centerZero: true,
            ),
          ),
          const SizedBox(height: 12),
          DataCard(
            label: 'Torque',
            value: torque,
            unit: 'Nm',
            valueSize: 28,
            child: DataBar(fraction: torque / torqueMaxFor(peaks.torque), color: accent),
          ),
          const SizedBox(height: 10),
          // Four temperatures as a 2x2 grid. The MCU (controller) leads — it
          // heats fastest and is the usual derate trigger. Each label turns to
          // "… hot" and red over the limit (no room for a separate badge).
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: DataCard(
                  key: const ValueKey('mcu-temp'),
                  label: mcuTint == DashColors.ash ? 'MCU temp' : 'MCU hot',
                  labelColor: mcuTint == DashColors.ash ? null : mcuTint,
                  value: toDisplayTemp(mcuTemp, useF).toDouble(),
                  known: mcuTempKnown,
                  unit: tempUnit(useF),
                  valueSize: 20,
                  valueColor: mcuTint == DashColors.ash ? null : mcuTint,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: DataCard(
                  key: const ValueKey('motor-temp'),
                  label: tempTint == DashColors.ash ? 'Motor temp' : 'Motor hot',
                  labelColor: tempTint == DashColors.ash ? null : tempTint,
                  value: toDisplayTemp(motorTemp, useF).toDouble(),
                  known: tempKnown,
                  unit: tempUnit(useF),
                  valueSize: 20,
                  valueColor: tempTint == DashColors.ash ? null : tempTint,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The BMS power electronics (PDU, CAN 0x1A8).
              Expanded(
                child: DataCard(
                  key: const ValueKey('bms-temp'),
                  label: pduTint == DashColors.ash ? 'BMS temp' : 'BMS hot',
                  labelColor: pduTint == DashColors.ash ? null : pduTint,
                  value: toDisplayTemp(pduTemp, useF).toDouble(),
                  known: pduTempKnown,
                  unit: tempUnit(useF),
                  valueSize: 20,
                  valueColor: pduTint == DashColors.ash ? null : pduTint,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: DataCard(
                  key: const ValueKey('battery-temp'),
                  label: batteryTint == DashColors.ash ? 'Battery temp' : 'Battery hot',
                  labelColor: batteryTint == DashColors.ash ? null : batteryTint,
                  value: toDisplayTemp(batteryTemp, useF).toDouble(),
                  known: batteryTempKnown,
                  unit: tempUnit(useF),
                  valueSize: 20,
                  valueColor: batteryTint == DashColors.ash ? null : batteryTint,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
