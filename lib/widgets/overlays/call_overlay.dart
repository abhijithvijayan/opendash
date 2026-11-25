import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../state/overlay_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../media/media_button.dart';
import '../status_bar/overlay_toolbar.dart';
import '../status_bar/status_bar.dart';
import '../../theme/tokens.dart';
import 'alert_overlay.dart';
import '../../services/analytics_logger.dart';

String formatCallDuration(int seconds) =>
    '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

/// Ringing phone. Sits above every alert and stays reachable while riding.
class IncomingCallOverlay extends ConsumerWidget {
  const IncomingCallOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final incoming = ref.watch(vehicleProvider.select((v) => v.callIncoming));
    final caller = ref.watch(vehicleProvider.select((v) => v.callerLabel));
    final canMessage = ref.watch(vehicleProvider.select((v) => v.rejectCallAllowed));
    final n = ref.read(vehicleProvider.notifier);
    return Align(
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: DashMotion.normal,
        reverseDuration: DashMotion.fast,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) => SlideTransition(
          position: Tween(begin: const Offset(0, -1), end: Offset.zero).animate(anim),
          child: FadeTransition(opacity: anim, child: child),
        ),
        child: !incoming
            ? const SizedBox.shrink()
            : Container(
                key: const ValueKey('incoming-call'),
                width: 1280,
                height: 200,
                decoration: BoxDecoration(
                  color: DashColors.inkLift.withValues(alpha: DashScrim.glass),
                  border: Border(bottom: BorderSide(color: DashColors.normal, width: 2)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 72),
                child: Row(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: DashColors.slate),
                      child: Icon(Icons.person_rounded, size: 36, color: DashColors.ash),
                    ),
                    const SizedBox(width: 28),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(caller, style: DashText.title(32), maxLines: 1, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 6),
                          Text('Incoming call', style: DashText.caption(18)),
                        ],
                      ),
                    ),
                    MediaButton(
                      key: const ValueKey('call-reject'),
                      icon: Icons.call_end_rounded,
                      size: 64,
                      iconSize: 32,
                      color: DashColors.bone,
                      background: DashColors.critical,
                      onTap: () {
                        uiModalButton('call', 'reject');
                        n.rejectCall();
                      },
                    ),
                    const SizedBox(width: 24),
                    if (canMessage) ...[
                      MediaButton(
                        key: const ValueKey('call-message'),
                        size: 64,
                        background: DashColors.slate,
                        onTap: () {
                          uiModalButton('call', 'reject_with_message');
                          n.rejectCallWithMessage();
                        },
                        child: Center(child: ChatBubbleIcon(size: 30, color: DashColors.ash)),
                      ),
                      const SizedBox(width: 24),
                    ],
                    MediaButton(
                      key: const ValueKey('call-accept'),
                      icon: Icons.call_rounded,
                      size: 64,
                      iconSize: 32,
                      color: DashColors.bone,
                      background: DashColors.eco,
                      onTap: () {
                        uiModalButton('call', 'accept');
                        n.acceptCall();
                      },
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// How far overlay bodies move down to clear the call bar, on top of
/// [alertBannerShiftProvider]: its height while a call is up, else zero.
final callBarShiftProvider = Provider<double>(
  (ref) => ref.watch(vehicleProvider.select((v) => v.callActive && !v.callIncoming)) ? ActiveCallBar.height : 0,
);

/// Compact bar under the status bar (or the overlay toolbar, when one
/// stands in for it) for the duration of a call. It drops under an alert
/// banner rather than sharing its band.
class ActiveCallBar extends ConsumerWidget {
  const ActiveCallBar({super.key});

  static const height = 56.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(vehicleProvider.select((v) => v.callActive && !v.callIncoming));
    final caller = ref.watch(vehicleProvider.select((v) => v.callerLabel));
    final duration = ref.watch(vehicleProvider.select((v) => v.callDuration));
    final muted = ref.watch(vehicleProvider.select((v) => v.callMuted));
    final n = ref.read(vehicleProvider.notifier);
    final toolbar = ref.watch(overlayToolbarVisibleProvider) && !ref.watch(statusBarPeekProvider);
    final bannerShift = ref.watch(alertBannerShiftProvider);

    return Positioned(
      left: 0,
      right: 0,
      top: (toolbar ? OverlayToolbar.height : StatusBar.height) + bannerShift,
      child: AnimatedSwitcher(
        duration: DashMotion.normal,
        switchInCurve: DashMotion.valueCurve,
        switchOutCurve: DashMotion.valueCurve,
        child: !active
            ? const SizedBox.shrink()
            : Container(
                key: const ValueKey('active-call'),
                height: height,
                color: DashColors.slate.withValues(alpha: 0.9),
                padding: const EdgeInsets.symmetric(horizontal: 72),
                child: Row(
                  children: [
                    Icon(Icons.call_rounded, size: 20, color: DashColors.eco),
                    const SizedBox(width: 12),
                    Text(caller, style: DashText.value(18)),
                    const SizedBox(width: 12),
                    Text(formatCallDuration(duration), style: DashText.caption(16)),
                    const Spacer(),
                    if (n.callMuteSupported) ...[
                      MediaButton(
                        key: const ValueKey('call-mute'),
                        icon: muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                        size: 36,
                        iconSize: 20,
                        color: muted ? DashColors.critical : DashColors.ash,
                        onTap: () {
                          uiModalButton('call', 'mute');
                          n.toggleCallMute();
                        },
                      ),
                      const SizedBox(width: 16),
                    ],
                    MediaButton(
                      key: const ValueKey('call-end'),
                      icon: Icons.call_end_rounded,
                      size: 36,
                      iconSize: 20,
                      color: DashColors.bone,
                      background: DashColors.critical,
                      onTap: () {
                        uiModalButton('call', 'end');
                        n.endCall();
                      },
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// Speech bubble with three dots: reject the call with a text.
class ChatBubbleIcon extends StatelessWidget {
  const ChatBubbleIcon({super.key, required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _ChatBubblePainter(color));
}

class _ChatBubblePainter extends CustomPainter {
  const _ChatBubblePainter(this.color);
  final Color color;

  @override
  void paint(Canvas c, Size s) {
    final w = s.width, h = s.height;
    final body = RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.08, h * 0.14, w * 0.84, h * 0.6), Radius.circular(w * 0.18));
    final tail = Path()
      ..moveTo(w * 0.3, h * 0.72)
      ..lineTo(w * 0.24, h * 0.92)
      ..lineTo(w * 0.48, h * 0.74)
      ..close();
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeJoin = StrokeJoin.round;
    c.drawRRect(body, stroke);
    c.drawPath(tail, Paint()..color = color);
    final dot = Paint()..color = color;
    for (final x in [0.32, 0.5, 0.68]) {
      c.drawCircle(Offset(w * x, h * 0.44), w * 0.05, dot);
    }
  }

  @override
  bool shouldRepaint(_ChatBubblePainter old) => old.color != color;
}
