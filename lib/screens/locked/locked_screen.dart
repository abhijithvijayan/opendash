import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../models/vehicle_data.dart';
import '../../providers/mock_provider.dart';
import '../../services/analytics_logger.dart';
import '../../state/crash_recovery.dart';
import '../../state/format_settings.dart';
import '../../state/passcode_state.dart';
import '../../state/range_readout.dart';
import '../../state/settings_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';
import '../../widgets/controls/control_panel.dart';
import '../charging/charging_screen.dart';
import 'emergency_sheet.dart';
import 'keypad.dart';
import '../../services/trusted_clock.dart';

export '../../state/format_settings.dart' show formatDate;

/// "4 min 05 s", or "45 s" under a minute.
String formatLockoutCountdown(Duration d) {
  final s = d.inSeconds;
  return s < 60 ? '$s s' : '${s ~/ 60} min ${(s % 60).toString().padLeft(2, '0')} s';
}

String formatCountdown(Duration d) {
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Passcode entry. Clock and battery on the left, PIN dots and keypad on
/// the right. Owns the full 768px: no status bar above it, so the top 88px
/// stay clear for an alert banner (unlock failed, battery low).
class LockedScreen extends ConsumerStatefulWidget {
  const LockedScreen({super.key, this.now});
  final DateTime? now;

  @override
  ConsumerState<LockedScreen> createState() => _LockedScreenState();
}

class _LockedScreenState extends ConsumerState<LockedScreen> {
  bool _emergency = false;
  Timer? _countdown;

  @override
  void dispose() {
    _countdown?.cancel();
    super.dispose();
  }

  void _syncCountdown(bool lockedOut) {
    if (lockedOut && _countdown == null) {
      _countdown = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    } else if (!lockedOut && _countdown != null) {
      _countdown!.cancel();
      _countdown = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final time = ref.watch(vehicleProvider.select((v) => v.time));
    // SOC 100 %, 180 km were shown before HHMIS
    // answered. '—' until the first real values arrive, after Continue
    // without vehicle data, and while the data is stale.
    final soc = ref.watch(vehicleProvider.select((v) => v.socKnown ? v.batterySoc : null));
    // Same figure as the home battery page. No "Stock: N km" sub-line
    // here: the charging line sits 6 px under this row.
    final range = ref.watch(rangeReadoutProvider);
    final rangeKm = range.shownKm;
    final limp = range.kind == RangeKind.limp;
    final useMiles = ref.watch(useMilesProvider);
    // Stock's passcode screen carries one charging line (the status-bar
    // text, "CHARGING" / "NOT CHARGING" / ...); a locked scooter on the
    // charger is the common case. At boot HHMIS reports only LOCK/PASSCODE
    // and no charge status, so INT_CHARGE_MODE is what says it is plugged
    // in (seen on a scooter: locked, 12 A into the pack, no line shown).
    final charge = ref.watch(vehicleProvider.select(
        (v) => v.isCharging || v.chargerCharging ? (chargeLabel(v), v.chargingState) : null));
    final pass = ref.watch(passcodeProvider);
    final notifier = ref.read(passcodeProvider.notifier);
    final dateOrder = ref.watch(dateOrderProvider);
    _syncCountdown(pass.lockedOut);

    final dotColor = switch (pass.lastResult) {
      PasscodeResult.success => DashColors.eco,
      PasscodeResult.failure => DashColors.critical,
      _ => DashColors.parked,
    };

    return Stack(
      children: [
        Positioned(
          left: 96,
          top: 130,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 640,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(time, style: DashText.speed.copyWith(fontSize: 150, letterSpacing: -4)),
                ),
              ),
              const SizedBox(height: 10),
              // No date while the clock is unknown (the time reads --:--).
              Text(widget.now == null && !TrustedClock.trusted ? '' : formatDate(widget.now ?? TrustedClock.wall(), order: dateOrder),
                  style: DashText.caption(26)),
            ],
          ),
        ),
        Positioned(
          left: 96,
          top: 520,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(soc == null ? '—' : '$soc', key: const ValueKey('lock-soc'), style: DashText.value(44)),
              Text('%', style: DashText.caption(22)),
              const SizedBox(width: 24),
              Text(
                rangeKm == null ? '—' : '${toDisplayDistance(rangeKm, useMiles)}',
                key: const ValueKey('lock-range'),
                style: DashText.value(44, color: limp ? DashColors.critical : range.approx ? DashColors.ash : DashColors.bone),
              ),
              const SizedBox(width: 6),
              Text(
                '${distanceUnit(useMiles)} ${limp ? 'limp' : 'range'}',
                key: const ValueKey('lock-range-caption'),
                style: DashText.caption(22, color: limp ? DashColors.critical : DashColors.ash),
              ),
            ],
          ),
        ),
        if (charge != null)
          Positioned(
            key: const ValueKey('lock-charge-status'),
            left: 96,
            top: 578,
            child: Row(
              children: [
                Icon(
                  Icons.bolt_rounded,
                  size: 22,
                  color: charge.$2 == ChargingState.notCharging ? DashColors.warning : DashColors.charging,
                ),
                const SizedBox(width: 6),
                Text(
                  charge.$1,
                  style: DashText.caption(
                    20,
                    color: charge.$2 == ChargingState.notCharging ? DashColors.warning : DashColors.charging,
                  ),
                ),
              ],
            ),
          ),
        Positioned(
          left: 96,
          top: 620,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _emergency = true),
                child: Container(
                  height: 56,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: BoxDecoration(
                    border: Border.all(color: DashColors.critical.withValues(alpha: 0.8), width: 1.5),
                    borderRadius: BorderRadius.circular(DashRadius.button),
                  ),
                  alignment: Alignment.center,
                  child: Text('Emergency', style: DashText.value(20, color: DashColors.critical)),
                ),
              ),
              const _StockWayOut(),
            ],
          ),
        ),
        Positioned(
          left: 960 - 200,
          width: 400,
          top: 90,
          height: 40,
          child: Center(
            child: pass.lockedOut
                ? FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'Too many attempts. Try again in ${formatLockoutCountdown(pass.lockoutRemaining(DateTime.now()))}.',
                      style: DashText.value(22, color: DashColors.critical),
                    ),
                  )
                : PinDots(
                    filled: pass.enteredDigits.length,
                    shakeTrigger: pass.failures,
                    color: dotColor,
                  ),
          ),
        ),
        const Positioned(left: 960 - 200, width: 400, top: 52, height: 28, child: _NotConnectedNote()),
        Positioned(
          left: 960 - 200,
          width: 400,
          top: 132,
          height: 26,
          child: _WrongPinHint(
            failures: pass.failures,
            attemptsLeft: pass.attemptsRemaining,
            lockedOut: pass.lockedOut,
          ),
        ),
        Positioned(
          left: 960 - Keypad.width / 2,
          top: 160,
          child: Keypad(
            enabled: !pass.lockedOut && pass.lastResult != PasscodeResult.success,
            onDigit: notifier.enterDigit,
            onDelete: notifier.deleteDigit,
          ),
        ),
        Positioned(
          left: 1168,
          top: 662,
          child: ControlButton(
            key: const ValueKey('lock-brightness'),
            size: DashTouch.min,
            active: false,
            activeColor: DashColors.warning,
            onTap: ref.read(brightnessProvider.notifier).cyclePreset,
            child: SunIcon(color: DashColors.ash, size: 28),
          ),
        ),
        Positioned(
          left: 24,
          bottom: 16,
          child: Text(
            'v$appVersion',
            key: const ValueKey('lock-version'),
            style: DashText.caption(12, color: DashColors.ash.withValues(alpha: 0.3)),
          ),
        ),
        if (_emergency)
          Positioned.fill(
            child: EmergencySheet(onClose: () => setState(() => _emergency = false)),
          ),
      ],
    );
  }
}

/// "Wrong passcode" under the dots for a moment after each failure, with
/// the remaining attempts once they run low.
class _WrongPinHint extends StatefulWidget {
  const _WrongPinHint({required this.failures, required this.attemptsLeft, required this.lockedOut});
  final int failures;
  final int attemptsLeft;
  final bool lockedOut;

  static const showFor = Duration(milliseconds: 1500);

  @override
  State<_WrongPinHint> createState() => _WrongPinHintState();
}

class _WrongPinHintState extends State<_WrongPinHint> {
  Timer? _timer;
  bool _visible = false;

  @override
  void didUpdateWidget(_WrongPinHint old) {
    super.didUpdateWidget(old);
    if (widget.failures != old.failures && widget.failures > 0 && !widget.lockedOut) {
      _timer?.cancel();
      _visible = true;
      _timer = Timer(_WrongPinHint.showFor, () {
        _timer = null;
        if (mounted) setState(() => _visible = false);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.attemptsLeft;
    final text = n <= 3 ? 'Wrong passcode ($n ${n == 1 ? 'attempt' : 'attempts'} left)' : 'Wrong passcode';
    return AnimatedOpacity(
      opacity: _visible && !widget.lockedOut ? 1 : 0,
      duration: DashMotion.fast,
      child: Text(
        text,
        key: const ValueKey('wrong-pin-hint'),
        style: DashText.caption(15, color: DashColors.critical),
        textAlign: TextAlign.center,
      ),
    );
  }
}

/// "Stock Dashboard" beside Emergency, only while OpenDash cannot unlock
/// the scooter: the vehicle service is not connected, or the last passcode
/// got no answer. A rider once stood at this screen for the
/// length of an outage with the right passcode and no way anywhere else.
/// It is not there in normal use, so the scooter's finder is offered
/// nothing more than Emergency; and it is not inside the Emergency sheet,
/// which is the finder's.
class _StockWayOut extends ConsumerWidget {
  const _StockWayOut();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(vehicleProvider.select((v) => v.hhmisConnected));
    return ValueListenableBuilder<bool>(
      valueListenable: ref.read(vehicleProvider.notifier).passcodeUnanswered,
      builder: (context, unanswered, _) {
        if (connected && !unanswered) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                key: const ValueKey('lock-stock'),
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  uiTap('lock-stock', {'connected': connected, 'unanswered': unanswered});
                  ref.read(crashRecoveryProvider.notifier).launchStockApp();
                },
                child: Container(
                  height: 56,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: BoxDecoration(
                    border: Border.all(color: DashColors.slate, width: 1.5),
                    borderRadius: BorderRadius.circular(DashRadius.button),
                  ),
                  alignment: Alignment.center,
                  child: Text('Stock Dashboard', style: DashText.value(20)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Above the dots while the vehicle service is not connected: a passcode
/// cannot be checked then, and the screen should say so before six digits
/// are typed into it.
class _NotConnectedNote extends ConsumerWidget {
  const _NotConnectedNote();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(vehicleProvider.select((v) => v.hhmisConnected))) return const SizedBox.shrink();
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          "Can't reach the scooter. Still trying…",
          key: const ValueKey('lock-not-connected'),
          style: DashText.caption(18, color: DashColors.warning),
        ),
      ),
    );
  }
}
