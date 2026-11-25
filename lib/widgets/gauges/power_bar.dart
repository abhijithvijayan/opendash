import 'package:flutter/widgets.dart';

import '../../models/vehicle_data.dart';
import '../../providers/hhmis_mapping.dart';
import '../../theme/dash_theme.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';

/// Until the battery has reported a regen limit.
const defaultMaxRegen = 4.0;

/// Fill fraction: power out against the BMS discharge ceiling, regen
/// against the most the battery has ever accepted.
double powerBarFraction(double power, {required double maxPower, double maxRegen = defaultMaxRegen}) =>
    power > 0 ? (power / maxPower).clamp(0.0, 1.0) : (-power / maxRegen).clamp(0.0, 1.0);

/// The bar's ceiling in kW: the BMS discharge limit when it reports one,
/// so a hot or low pack visibly shrinks what is on offer. The limit is in
/// pack watts and `power` is on stock's display scale, so the limit takes
/// the same factor and the fill stays power-over-limit.
/// Without a limit right now (no CAN stream yet), the highest it has
/// reported; before any, the S1 Pro's 8.5 kW.
double powerBarMaxFor(VehicleData v) => v.dischargePowerLimitW > 0
    ? v.dischargePowerLimitW / 1000 * HhmisPower.displayScale
    : v.peaks.dischargeLimitW > 0
        ? v.peaks.dischargeLimitW / 1000 * HhmisPower.displayScale
        : PowerBar.defaultMaxPower;

/// The regen side's ceiling in shown kW: the highest regen limit the
/// battery has reported. The limit of the moment would empty the scale
/// whenever a full or cold battery refuses regen.
double regenBarMaxFor(VehicleData v) =>
    v.peaks.regenLimitW > 0 ? v.peaks.regenLimitW / 1000 * HhmisPower.displayScale : defaultMaxRegen;

/// Centre-zero bar: accent to the right for power out, bone to the left for
/// regen. A REGEN caption appears under the bar while recovering energy, so
/// the state does not rest on the fill colour alone.
class PowerBar extends StatelessWidget {
  const PowerBar({
    super.key,
    required this.power,
    required this.accent,
    this.width = 220,
    this.theme = DashTheme.dark,
    this.maxPower = defaultMaxPower,
    this.maxRegen = defaultMaxRegen,
  });

  static const defaultMaxPower = 8.5;

  final double power;
  final Color accent;
  final double width;
  final DashTheme theme;
  final double maxPower;
  final double maxRegen;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: power),
      duration: DashMotion.gauge,
      curve: Curves.easeOut,
      builder: (context, p, _) {
        final regen = p < 0;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 92,
                  child: Text(
                    regen ? 'regen' : 'power',
                    style: DashText.caption(18, color: theme.ash),
                    textAlign: TextAlign.right,
                  ),
                ),
                const SizedBox(width: 16),
                CustomPaint(size: Size(width, 6), painter: _BarPainter(p, accent, theme, maxPower, maxRegen)),
                const SizedBox(width: 16),
                SizedBox(
                  width: 92,
                  child: Text(
                    '${p.abs().toStringAsFixed(1)} kW',
                    style: DashText.value(22, color: regen ? theme.bone : accent),
                  ),
                ),
              ],
            ),
            SizedBox(
              height: 18,
              child: AnimatedSwitcher(
                duration: DashMotion.fast,
                switchInCurve: DashMotion.valueCurve,
                switchOutCurve: DashMotion.valueCurve,
                child: regen
                    ? Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('REGEN', key: const ValueKey('regen-caption'), style: DashText.mode(theme.bone, size: 13)),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.power, this.accent, this.theme, this.maxPower, this.maxRegen);
  final double power;
  final Color accent;
  final DashTheme theme;
  final double maxPower;
  final double maxRegen;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.width / 2;
    final track = Paint()..color = theme.slate;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(0, size.height / 2 - 1, size.width, 2), const Radius.circular(1)),
      track,
    );
    canvas.drawRect(Rect.fromLTWH(mid - 1, 0, 2, size.height), Paint()..color = theme.ash);

    if (power.abs() < 0.05) return;
    final frac = powerBarFraction(power, maxPower: maxPower, maxRegen: maxRegen);
    final len = frac * mid;
    final color = power > 0 ? accent : theme.bone;
    final rect = power > 0
        ? Rect.fromLTWH(mid, 0, len, size.height)
        : Rect.fromLTWH(mid - len, 0, len, size.height);
    canvas.drawRect(rect.inflate(4), Paint()..color = color.withValues(alpha: 0.12));
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.power != power || old.accent != accent || old.theme != theme || old.maxPower != maxPower || old.maxRegen != maxRegen;
}
