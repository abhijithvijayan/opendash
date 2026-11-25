import '../../widgets/controls/trunk_button.dart';
import '../dashboard/dashboard_screen.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/charge_session.dart';
import '../../models/vehicle_data.dart';
import '../../providers/mock_provider.dart';
import '../../state/charge_energy_state.dart';
import '../../state/format_settings.dart';
import '../../state/settings_state.dart';
import '../../state/theme_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/gauges/battery_ring.dart';
import '../settings/widgets.dart';
import '../../theme/tokens.dart';
import '../../services/trusted_clock.dart';

class ChargingScreen extends ConsumerStatefulWidget {
  const ChargingScreen({super.key});

  @override
  ConsumerState<ChargingScreen> createState() => _ChargingScreenState();
}

class _ChargingScreenState extends ConsumerState<ChargingScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat(reverse: true);

  bool _historyOpen = false;

  /// Slower breathing while the charger handshakes; none while it's stalled.
  void _syncBreathing(ChargingState cs) {
    final period = cs == ChargingState.initializing ? 3500 : 2400;
    if (_breathe.duration?.inMilliseconds != period) {
      _breathe.duration = Duration(milliseconds: period);
      if (cs != ChargingState.notCharging) _breathe.repeat(reverse: true);
    }
    if (cs == ChargingState.notCharging && _breathe.isAnimating) _breathe.stop();
    if (cs != ChargingState.notCharging && !_breathe.isAnimating) _breathe.repeat(reverse: true);
  }

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(vehicleProvider);
    final energy = ref.watch(chargeEnergyProvider);
    final useMiles = ref.watch(useMilesProvider);
    final useF = ref.watch(useFahrenheitProvider);
    final use24 = ref.watch(use24HourProvider);
    // Rebuilt at least every minute: the vehicle clock is part of `v`.
    final now = TrustedClock.wall();
    final done = v.chargingComplete;
    final cs = v.chargingState;
    // A fast charger that is connected but
    // idle shows as initializing and has no times (stock
    // `setFcChargeIdleStatus` blanks them).
    final stalled = cs == ChargingState.initializing || cs == ChargingState.notCharging || v.fcChargeIdle;
    final accent = DashColors.charging;
    _syncBreathing(cs);
    final label = chargeLabel(v);

    return Stack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 72,
          child: ChargeStatusBar(fraction: v.socKnown ? v.batterySoc / 100 : 0, complete: done),
        ),
        Positioned(
          left: 640 - 230,
          top: 110,
          child: BatteryRing(
            soc: v.socKnown ? v.batterySoc : null,
            accent: accent,
            diameter: 460,
            stroke: 14,
            theme: ref.watch(uiThemeProvider),
            glowAnimation: _breathe,
            glowOf: () => done || cs == ChargingState.notCharging ? 1.0 : 0.7 + 0.9 * Curves.easeInOut.transform(_breathe.value),
            valueStyle: DashText.speed.copyWith(fontSize: 150, letterSpacing: -4),
            unitStyle: DashText.socUnit.copyWith(fontSize: 40),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 584,
          child: Column(
            children: [
              Text(
                label,
                key: const ValueKey('charge-label'),
                style: DashText.mode(cs == ChargingState.notCharging ? DashColors.warning : accent, size: 24),
                textAlign: TextAlign.center,
              ),
              if (cs == ChargingState.notCharging) ...[
                const SizedBox(height: 6),
                Text('Check charger connection', style: DashText.caption(16), textAlign: TextAlign.center),
              ],
              if (energy.balancingActive && !stalled) ...[
                const SizedBox(height: 6),
                Text(
                  'Cell balancing in progress',
                  key: const ValueKey('charge-balancing'),
                  style: DashText.caption(14, color: DashColors.ash),
                  textAlign: TextAlign.center,
                ),
              ],
              // The one thing the rider plugged in to find out sits with
              // the status, under the ring, not in a column of equals.
              if (!done) ...[
                const SizedBox(height: 14),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Past 80% HHMIS sends 0 minutes; the slot has nothing left to say.
                    if (v.batterySoc < 80) ...[
                      _Stat(
                        key: const ValueKey('charge-to-80'),
                        value: stalled ? '—' : chargeEta(chargeMinutesTo80(v), now, use24Hour: use24),
                        caption: v.isHyperCharger ? '80% at (hyper)' : v.isBoostCharger ? '80% at (boost)' : '80% at',
                        size: 32,
                        centered: true,
                      ),
                      const SizedBox(width: 56),
                    ],
                    _Stat(
                      key: const ValueKey('charge-to-full'),
                      value: stalled ? '—' : chargeEta(chargeMinutesToFull(v), now, use24Hour: use24),
                      caption: '100% at',
                      size: 32,
                      centered: true,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        Positioned(
          left: 80,
          top: 196,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Stat(
                key: const ValueKey('charge-power'),
                value: stalled ? '—' : '${energy.chargingPowerKw.toStringAsFixed(2)} kW',
                caption: 'charging power',
              ),
              const SizedBox(height: 30),
              _Stat(
                key: const ValueKey('charge-energy'),
                value: '${energy.currentKwh.toStringAsFixed(2)} kWh',
                caption: 'energy used',
                size: 26,
              ),
              const SizedBox(height: 16),
              _Stat(
                value: v.batteryTempKnown ? '${toDisplayTemp(v.batteryTemp, useF)}°' : '—',
                caption: 'battery temp',
                size: 26,
              ),
              const SizedBox(height: 16),
              _Stat(value: v.chargeStartTime.isEmpty ? '—' : v.chargeStartTime, caption: 'charge started', size: 26),
            ],
          ),
        ),
        // Stock keeps its Park screen, trunk button included, while
        // charging; the same button in the same place as on the dashboard.
        const Positioned(
          left: 72,
          top: DashboardScreen.trunkTop,
          child: RepaintBoundary(child: DashboardTrunkButton()),
        ),
        Positioned(
          right: 80,
          top: 180,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final (mode, km) in [
                (DriveMode.eco, v.rangeEco),
                (DriveMode.normal, v.rangeNormal),
                (DriveMode.sport, v.rangeSport),
                (DriveMode.hyper, v.rangeHyper),
              ])
                // A mode this scooter does not have comes with no range.
                if (km > 0 || mode == DriveMode.eco) ...[
                _ModeRange(
                  label: mode.label,
                  color: DashColors.forMode(mode),
                  km: toDisplayDistance(km, useMiles),
                  unit: distanceUnit(useMiles),
                ),
                const SizedBox(height: 22),
              ],
              // The rider's own mode (MoveOS 5), with its own range.
              if ((v.customRide.enabled == true || v.customRideActive) && (v.customRide.rangeKm ?? 0) > 0) ...[
                _ModeRange(
                  key: const ValueKey('custom-range'),
                  label: v.customRide.label.toUpperCase(),
                  color: ref.watch(uiThemeProvider).custom,
                  km: toDisplayDistance(v.customRide.rangeKm!, useMiles),
                  unit: distanceUnit(useMiles),
                ),
                const SizedBox(height: 22),
              ],
              _ChargeHistory(
                history: energy.history,
                open: _historyOpen,
                onToggle: () => setState(() => _historyOpen = !_historyOpen),
              ),
              const SizedBox(height: 8),
              // Stock arms the limit on a hyper or boost
              // charger only; on a home charger it would promise a stop
              // nothing enforces.
              if (v.hyperCharging) Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Charge limit: ', style: DashText.caption(16)),
                  Text(v.chargeLimit >= 100 ? 'none' : '${v.chargeLimit}%', key: const ValueKey('charge-limit'), style: DashText.value(18)),
                  const SizedBox(width: 12),
                  GestureDetector(
                    key: const ValueKey('charge-limit-edit'),
                    behavior: HitTestBehavior.opaque,
                    onTap: ref.read(chargeLimitPopupProvider.notifier).open,
                    child: SizedBox(
                      height: DashTouch.min,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text('edit', style: DashText.caption(18, color: DashColors.ash)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (v.hyperCharging && ref.watch(chargeLimitPopupProvider)) ...[
          Positioned.fill(
            child: GestureDetector(
              key: const ValueKey('charge-limit-backdrop'),
              behavior: HitTestBehavior.opaque,
              onTap: ref.read(chargeLimitPopupProvider.notifier).close,
            ),
          ),
          Positioned(
            right: 80,
            top: 440,
            child: _ChargeLimitPopup(limit: v.chargeLimit),
          ),
        ],
      ],
    );
  }
}

/// 4px strip under the status bar: slate track, charging fill, mint pulse
/// once full.
class ChargeStatusBar extends StatefulWidget {
  const ChargeStatusBar({super.key, required this.fraction, required this.complete});
  final double fraction;
  final bool complete;

  @override
  State<ChargeStatusBar> createState() => _ChargeStatusBarState();
}

class _ChargeStatusBarState extends State<ChargeStatusBar> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));

  @override
  void initState() {
    super.initState();
    if (widget.complete) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(ChargeStatusBar old) {
    super.didUpdateWidget(old);
    if (widget.complete && !old.complete) _pulse.repeat(reverse: true);
    if (!widget.complete && old.complete) _pulse.stop();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: widget.complete ? 1 : widget.fraction.clamp(0, 1)),
      duration: DashMotion.value,
      curve: Curves.easeOut,
      builder: (context, f, _) => AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) => SizedBox(
          height: 4,
          child: Stack(
            children: [
              Positioned.fill(child: ColoredBox(color: DashColors.slate)),
              FractionallySizedBox(
                widthFactor: f,
                child: ColoredBox(
                  color: widget.complete
                      ? DashColors.eco.withValues(alpha: 0.7 + 0.3 * _pulse.value)
                      : DashColors.charging,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChargeLimitPopup extends ConsumerWidget {
  const _ChargeLimitPopup({required this.limit});
  final int limit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      key: const ValueKey('charge-limit-popup'),
      width: 300,
      padding: const EdgeInsets.all(DashSpace.cardPad),
      decoration: BoxDecoration(
        color: DashColors.inkLift,
        borderRadius: BorderRadius.circular(DashRadius.card),
        border: Border.all(color: DashColors.slate, width: 1.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$limit%', style: DashText.value(28)),
          SliderRow(
            label: 'Charge limit',
            value: limit.toDouble(),
            min: 50,
            max: 100,
            divisions: 10,
            step: 5,
            display: '',
            onChanged: (x) => ref.read(vehicleProvider.notifier).setChargeLimit(x.round()),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButtonLink('Done', key: const ValueKey('charge-limit-done'), color: DashColors.bone,
                onTap: ref.read(chargeLimitPopupProvider.notifier).close),
          ),
        ],
      ),
    );
  }
}

/// One status line, shared by this screen and the lock screen. Mirrors
/// stock HHMIC `setStatusBarStatus`: the status-bar substate first (slow,
/// not charging, complete), then the charger kind; `sna` is plain charging.
String chargeLabel(VehicleData v) => switch (v.chargingState) {
      ChargingState.initializing => 'Initializing charger…',
      ChargingState.notCharging => 'Not charging',
      ChargingState.complete => v.safeToUnplug ? 'Charged. Safe to unplug' : 'Charged',
      // "Charged" is the vehicle's call (charge status 2 or status-bar
      // substate 1), never SOC against a limit of ours: outside
      // hypercharging nothing is known to stop at the limit.
      _ when v.fcChargeIdle => 'Initializing charger…',
      _ when v.chargeSubstate == ChargeSubstate.chargingSlowly => 'Charging slowly',
      _ => v.isHyperCharger || v.chargeMode == 4 ? 'Hypercharging' : v.isBoostCharger ? 'Boost charging' : 'Charging',
    };

/// Hyper and boost chargers report their own, faster, times.
int chargeMinutesTo80(VehicleData v) {
  if (v.isHyperCharger && v.hyperMinutesTo80 > 0) return v.hyperMinutesTo80;
  if (v.isBoostCharger && v.boostMinutesTo80 > 0) return v.boostMinutesTo80;
  return v.minutesTo80;
}

int chargeMinutesToFull(VehicleData v) =>
    v.isHyperCharger && v.hyperMinutesToFull > 0 ? v.hyperMinutesToFull : v.minutesToFull;

/// HHMIS sends minutes remaining; like stock HHMIC's
/// `convertTimeToFullCharge` the rider sees the clock time it lands on.
/// Printing the minutes as HH:MM read as a time near midnight ("00:45").
/// 0 is HHMIS's idle value, shown as stock's "--:--" equivalent.
String chargeEta(int minutes, DateTime now, {required bool use24Hour}) {
  // A finish time needs a clock that can be right.
  if (minutes <= 0 || !TrustedClock.trusted) return '—';
  final t = now.add(Duration(minutes: minutes));
  return formatClock(t.hour, t.minute, use24Hour: use24Hour);
}

class _Stat extends StatelessWidget {
  const _Stat({super.key, required this.value, required this.caption, this.size = 48, this.centered = false});
  final String value;
  final String caption;
  final double size;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        Text(value, style: DashText.value(size)),
        const SizedBox(height: 2),
        Text(caption, style: DashText.caption(size >= 48 ? 18 : 16)),
      ],
    );
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "Nov 08", the way the stock history list dates sessions.
String chargeHistoryDate(int timestamp) {
  final d = DateTime.fromMillisecondsSinceEpoch(timestamp);
  return '${_months[d.month - 1]} ${d.day.toString().padLeft(2, '0')}';
}

/// Tap to fold out the last five sessions: date, SOC range, energy, time.
class _ChargeHistory extends StatelessWidget {
  const _ChargeHistory({required this.history, required this.open, required this.onToggle});
  final List<ChargeSessionSummary> history;
  final bool open;
  final VoidCallback onToggle;

  static const shown = 5;

  @override
  Widget build(BuildContext context) {
    final rows = history.take(shown).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        GestureDetector(
          key: const ValueKey('charge-history-toggle'),
          behavior: HitTestBehavior.opaque,
          onTap: onToggle,
          child: SizedBox(
            height: DashTouch.min,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Charge history', style: DashText.caption(16)),
                const SizedBox(width: 6),
                Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18, color: DashColors.ash),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: DashMotion.fast,
          curve: DashMotion.valueCurve,
          alignment: Alignment.topRight,
          child: !open
              ? const SizedBox.shrink()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (rows.isEmpty) Text('No sessions yet', style: DashText.caption(14, color: DashColors.ash)),
                    for (var i = 0; i < rows.length; i++)
                      Padding(
                        key: ValueKey('charge-history-row-$i'),
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(width: 64, child: Text(chargeHistoryDate(rows[i].timestamp), style: DashText.caption(14, color: DashColors.ash))),
                            SizedBox(width: 78, child: Text('${rows[i].startSoc}→${rows[i].endSoc}%', style: DashText.caption(14, color: DashColors.bone))),
                            SizedBox(width: 86, child: Text('${rows[i].energyKwh.toStringAsFixed(2)} kWh', style: DashText.caption(14, color: DashColors.bone))),
                            SizedBox(width: 58, child: Text('${rows[i].durationMinutes} min', style: DashText.caption(14, color: DashColors.bone), textAlign: TextAlign.right)),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _ModeRange extends StatelessWidget {
  const _ModeRange({super.key, required this.label, required this.color, required this.km, required this.unit});
  final String label;
  final Color color;
  final int km;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(label, style: DashText.mode(color, size: 15)),
        const SizedBox(width: 18),
        SizedBox(
          width: 72,
          child: Text('$km', style: DashText.value(36), textAlign: TextAlign.right),
        ),
        const SizedBox(width: 6),
        Text(unit, style: DashText.caption(18)),
      ],
    );
  }
}
