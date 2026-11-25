import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/vehicle_data.dart';
import '../../providers/mock_provider.dart';
import '../../services/analytics_logger.dart';
import '../../state/alert_state.dart';
import '../../state/scooter_restart.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../status_bar/status_bar.dart';
import '../../theme/tokens.dart';
import '../../state/overlay_state.dart';
import '../../state/screen_state.dart';
import '../status_bar/overlay_toolbar.dart';

/// Banner under whichever strip is showing (status bar, overlay toolbar,
/// or nothing on the lock screen) for the current alert. Critical alerts
/// stay until the condition clears; warnings can be dismissed; info alerts
/// time out. With several active, a counter shows and the banner cycles.
/// An alert with an action (restart for faults 72 / 75, retry for a failed
/// handlebar unlock) carries its button.
/// The strip above it is never covered, so the turn arrows stay visible.
/// How far full-screen sub-screens and the control panel move down so the
/// banner never covers their headers: the banner height while any alert
/// is visible, otherwise zero.
final alertBannerShiftProvider = Provider<double>(
  (ref) => ref.watch(visibleAlertsProvider.select((a) => a.isNotEmpty)) ? AlertOverlay.height : 0,
);

class AlertOverlay extends ConsumerWidget {
  const AlertOverlay({super.key});

  static const top = StatusBar.height;
  static const height = 88.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(visibleAlertsProvider);
    final index = ref.watch(alertCycleProvider);
    final alert = alerts.isEmpty ? null : alerts[index.clamp(0, alerts.length - 1)];
    final overlay = ref.watch(overlayToolbarVisibleProvider) && !ref.watch(statusBarPeekProvider);
    final bare = ref.watch(screenStateProvider.select((s) => s == ScreenState.locked));
    return Positioned(
      left: 0,
      right: 0,
      top: overlay ? OverlayToolbar.height : bare ? 0 : top,
      child: AnimatedSwitcher(
        duration: DashMotion.normal,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) => SlideTransition(
          position: Tween(begin: const Offset(0, -1), end: Offset.zero).animate(anim),
          child: FadeTransition(opacity: anim, child: child),
        ),
        child: alert == null
            ? const SizedBox.shrink()
            : _Banner(
                key: ValueKey(alert.kind),
                alert: alert,
                position: index + 1,
                count: alerts.length,
              ),
      ),
    );
  }
}

class _Banner extends ConsumerStatefulWidget {
  const _Banner({super.key, required this.alert, required this.position, required this.count});
  final DashAlert alert;
  final int position;
  final int count;

  @override
  ConsumerState<_Banner> createState() => _BannerState();
}

class _BannerState extends ConsumerState<_Banner> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void initState() {
    super.initState();
    if (widget.alert.priority == AlertPriority.critical) _pulse.repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  // Restart goes through the same passcode-and-confirm flow as Settings.
  void _act(AlertAction action) {
    uiTap('alert-action', {'action': action.name, 'kind': widget.alert.kind.name});
    switch (action) {
      case AlertAction.restartScooter:
        ref.read(scooterRestartProvider.notifier).request('alert_banner');
      case AlertAction.retryUnlock:
        ref.read(vehicleProvider.notifier).retryUnlock();
    }
  }

  @override
  Widget build(BuildContext context) {
    final priority = widget.alert.priority;
    final action = widget.alert.action;
    final critical = priority == AlertPriority.critical;
    final color = switch (priority) {
      AlertPriority.critical => DashColors.critical,
      AlertPriority.warning => DashColors.warning,
      AlertPriority.info => DashColors.bone,
    };
    final cycle = ref.read(alertCycleProvider.notifier);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: widget.count > 1
          ? (d) => (d.primaryVelocity ?? 0) < 0 ? cycle.next() : cycle.previous()
          : null,
      // Only the bottom border pulses: a full-width animated shadow would
      // mean a mask blur every frame on the head unit's GPU.
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          final a = critical ? 0.4 + 0.6 * _pulse.value : 1.0;
          return Container(
            key: const ValueKey('alert-banner'),
            width: 1280,
            height: AlertOverlay.height,
            decoration: BoxDecoration(
              color: DashColors.ink.withValues(alpha: DashScrim.glass),
              border: Border(bottom: BorderSide(color: color.withValues(alpha: a), width: 3)),
            ),
            child: child,
          );
        },
        child: Row(
          children: [
            Container(width: 10, color: color),
            const SizedBox(width: 36),
            Icon(
              switch (priority) {
                AlertPriority.critical => Icons.warning_rounded,
                AlertPriority.warning => Icons.error_outline_rounded,
                AlertPriority.info => Icons.info_outline_rounded,
              },
              color: color,
              size: 40,
            ),
            const SizedBox(width: 28),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.alert.title, style: DashText.title(28, color: color), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    widget.alert.body,
                    style: DashText.caption(18, color: DashColors.bone),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (widget.count > 1) ...[
              Text('${widget.position} of ${widget.count}', key: const ValueKey('alert-counter'), style: DashText.caption(18)),
              const SizedBox(width: 28),
            ],
            if (action != null) ...[
              GestureDetector(
                key: const ValueKey('alert-action'),
                behavior: HitTestBehavior.opaque,
                onTap: () => _act(action),
                child: Container(
                  height: DashTouch.min,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(DashTouch.min / 2),
                    border: Border.all(color: color, width: 1.5),
                  ),
                  child: Text(action.label, style: DashText.value(20, color: color)),
                ),
              ),
              if (priority != AlertPriority.warning) const SizedBox(width: 16),
            ],
            if (priority == AlertPriority.warning)
              GestureDetector(
                key: const ValueKey('alert-dismiss'),
                behavior: HitTestBehavior.opaque,
                onTap: () => ref.read(dismissedAlertsProvider.notifier).dismissAlert(widget.alert),
                child: SizedBox(
                  width: 72,
                  height: AlertOverlay.height,
                  child: Center(child: Icon(Icons.close_rounded, size: 28, color: DashColors.ash)),
                ),
              )
            else
              const SizedBox(width: 48),
          ],
        ),
      ),
    );
  }
}
