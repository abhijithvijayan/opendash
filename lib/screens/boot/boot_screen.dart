import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/qr_card.dart';
import '../../constants.dart';
import '../../providers/mock_provider.dart';
import '../../state/boot_timeout.dart';
import '../../state/crash_recovery.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../settings/widgets.dart';
import '../../theme/tokens.dart';

/// Ignition on. A track draws out from the centre, the wordmark fades in
/// above it, and a bar runs along the track, over and over, while the
/// vehicle service connects: the usual "working, no telling how long"
/// loader. (It was a hairline that slowly brightened and dimmed, with dots
/// counting after "connecting"; it did not read as a loader, and the word
/// should stay still: the ellipsis is part of the word now, not an
/// animation.) No gauges here; those
/// belong to the dashboard. Owns the full 768px.
class BootScreen extends ConsumerStatefulWidget {
  const BootScreen({super.key});

  static const lineWidth = 400.0;

  /// Line draw, then wordmark fade: two halves of one reveal.
  static const reveal = Duration(milliseconds: 800);

  @override
  ConsumerState<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends ConsumerState<BootScreen> with TickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(vsync: this, duration: BootScreen.reveal)..forward();
  late final AnimationController _run = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();
  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );

  @override
  void dispose() {
    _reveal.dispose();
    _run.dispose();
    _flash.dispose();
    super.dispose();
  }

  double get _lineExtent => Curves.easeOutCubic.transform((_reveal.value * 2).clamp(0.0, 1.0));
  double get _wordmarkOpacity => Curves.easeOut.transform(((_reveal.value - 0.5) * 2).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final timeout = ref.watch(bootTimeoutProvider);
    final recovery = ref.read(crashRecoveryProvider.notifier);
    // The splash crossfades out as soon as the service answers; the flash
    // runs through that fade.
    ref.listen(vehicleProvider.select((v) => v.hhmisConnected), (_, connected) {
      if (connected) _flash.forward(from: 0);
    });

    return ColoredBox(
      color: DashColors.ink,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _reveal,
              builder: (context, child) => Opacity(opacity: _wordmarkOpacity, child: child),
              child: Column(
                children: [
                  Text(appName, style: DashText.title(48)),
                  const SizedBox(height: 8),
                  Text(
                    'v$appVersion',
                    key: const ValueKey('boot-version'),
                    style: DashText.caption(15, color: DashColors.ash.withValues(alpha: 0.5)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 36),
            AnimatedBuilder(
              animation: Listenable.merge([_reveal, _run, _flash]),
              builder: (context, _) => CustomPaint(
                key: const ValueKey('boot-line'),
                size: const Size(BootScreen.lineWidth, 4),
                painter: BootLinePainter(
                  extent: _lineExtent,
                  run: _run.value,
                  flash: _flash.isAnimating || _flash.value > 0 ? 1 - Curves.easeOut.transform(_flash.value) : 0,
                  color: DashColors.slate,
                  flashColor: DashColors.bone,
                ),
              ),
            ),
            const SizedBox(height: 28),
            AnimatedBuilder(
              animation: _reveal,
              builder: (context, child) => Opacity(opacity: _wordmarkOpacity, child: child),
              // At the options stage the counted "Still trying to connect" says it.
              child: timeout == BootTimeout.options
                  ? const SizedBox.shrink()
                  : Text('Connecting…', key: const ValueKey('boot-connecting'), style: DashText.caption(16)),
            ),
            AnimatedSize(
              duration: DashMotion.normal,
              curve: Curves.easeOut,
              child: switch (timeout) {
                BootTimeout.waiting => const SizedBox(height: 0, width: double.infinity),
                BootTimeout.slow => Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'Taking longer than usual…',
                      key: const ValueKey('boot-slow'),
                      style: DashText.caption(15, color: DashColors.warning),
                    ),
                  ),
                BootTimeout.options => Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      key: const ValueKey('boot-options'),
                      children: [
                        Text("The vehicle service isn't answering", style: DashText.caption(15, color: DashColors.warning)),
                        const SizedBox(height: 6),
                        // It never stops trying, and the dashboard opens by
                        // itself the moment the scooter answers.
                        const _StillTrying(),
                        const SizedBox(height: 6),
                        // OpenDash can't install an update without the
                        // vehicle data that says the scooter is parked.
                        GestureDetector(
                          key: const ValueKey('boot-companion'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => ref.read(qrCardProvider.notifier).companionApp(from: 'boot'),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text('To update OpenDash, use the OpenDash Companion app on your phone. Tap for the download.',
                                style: DashText.caption(14, color: DashColors.bone)),
                          ),
                        ),
                        const SizedBox(height: 20),
                        // No "Continue without vehicle data": it led to a
                        // lock screen that could not unlock, with no way
                        // back here. No "Open
                        // Trunk": it cannot work without the service.
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.start,
                          children: [
                            PrimaryButton('Launch Stock Dashboard',
                                key: const ValueKey('boot-stock'), onTap: recovery.launchStockApp),
                            const ReportIssueButton(key: ValueKey('boot-report'), from: 'boot'),
                          ],
                        ),
                      ],
                    ),
                  ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// "Still trying to connect · 0:45": the wait counted on screen, so a long
/// one reads as work going on and not as a stopped screen.
class _StillTrying extends StatefulWidget {
  const _StillTrying();

  @override
  State<_StillTrying> createState() => _StillTryingState();
}

class _StillTryingState extends State<_StillTrying> {
  int _seconds = BootTimeoutNotifier.optionsAfter.inSeconds;
  late final Timer _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() => _seconds++));

  @override
  void initState() {
    super.initState();
    _tick;
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
        'Still trying to connect · ${_seconds ~/ 60}:${(_seconds % 60).toString().padLeft(2, '0')}',
        key: const ValueKey('boot-still-trying'),
        style: DashText.caption(15),
      );
}

/// The loader: a track growing from the centre to [extent] of the width,
/// and on it a bar that sets off from the left, stretches, and is gathered
/// in at the right, once per [run] (0-1, repeating): the head runs ahead in
/// the first three quarters, the tail catches up in the last two thirds.
/// [flash] (0-1) lifts the whole track to [flashColor] for the hand-over.
class BootLinePainter extends CustomPainter {
  BootLinePainter({
    required this.extent,
    required this.run,
    required this.flash,
    required this.color,
    required this.flashColor,
  });
  final double extent;
  final double run;
  final double flash;
  final Color color;
  final Color flashColor;

  static const _head = Interval(0, 0.75, curve: Curves.fastOutSlowIn);
  static const _tail = Interval(0.333, 1, curve: Curves.fastOutSlowIn);

  /// Where the bar is, as fractions of the track.
  ({double from, double to}) get bar => (from: _tail.transform(run), to: _head.transform(run));

  @override
  void paint(Canvas canvas, Size size) {
    if (extent <= 0) return;
    final half = size.width / 2 * extent.clamp(0.0, 1.0);
    final y = size.height / 2;
    final left = size.width / 2 - half;
    final width = half * 2;
    final track = Paint()
      ..color = Color.lerp(color.withValues(alpha: 0.5), flashColor, flash)!
      ..strokeWidth = size.height
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(left, y), Offset(left + width, y), track);
    final b = bar;
    if (flash == 0 && b.to > b.from) {
      canvas.drawLine(
        Offset(left + width * b.from, y),
        Offset(left + width * b.to, y),
        Paint()
          ..color = flashColor
          ..strokeWidth = size.height
          ..strokeCap = StrokeCap.round,
      );
    }
    if (flash > 0) {
      canvas.drawLine(
        Offset(left, y),
        Offset(left + width, y),
        Paint()
          ..color = flashColor.withValues(alpha: 0.35 * flash)
          ..strokeWidth = size.height + 3 * flash
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(BootLinePainter old) =>
      old.extent != extent || old.run != run || old.flash != flash || old.color != color || old.flashColor != flashColor;
}
