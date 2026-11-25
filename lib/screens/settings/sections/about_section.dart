import 'package:material_ui/material_ui.dart';
import '../../../state/qr_card.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/build_info.dart';
import '../../../constants.dart';
import '../../../state/crash_recovery.dart';
import '../../../state/passcode_gate.dart';
import '../../../state/settings_state.dart';
import '../../../theme/colors.dart';
import '../../../theme/typography.dart';
import '../widgets.dart';

class AboutSection extends ConsumerStatefulWidget {
  const AboutSection({super.key});

  static const authorUrl = 'abhijithvijayan.in';

  @override
  ConsumerState<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends ConsumerState<AboutSection> {
  int _taps = 0;
  DateTime? _lastTap;

  /// Three taps within 600ms of each other open service mode.
  void _titleTap() {
    final now = DateTime.now();
    if (_lastTap != null && now.difference(_lastTap!) > const Duration(milliseconds: 600)) _taps = 0;
    _lastTap = now;
    _taps++;
    if (_taps >= 3) {
      _taps = 0;
      ref.read(passcodeGateProvider.notifier).request(
        purpose: 'Enter passcode for service mode',
        onSuccess: ref.read(serviceModeOpenProvider.notifier).open,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        children: [
          const SizedBox(height: 40),
          GestureDetector(
            key: const ValueKey('about-title'),
            behavior: HitTestBehavior.opaque,
            onTap: _titleTap,
            child: Text(appName, style: DashText.title(32)),
          ),
          const SizedBox(height: 6),
          Text('v${BuildInfo.label}', key: const ValueKey('about-version'), style: DashText.caption(16)),
          const SizedBox(height: 16),
          SizedBox(
            width: 400,
            child: Text(
              'Open-source replacement dashboard for electric scooters',
              style: DashText.caption(16),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: 520,
            child: Text(
              'Copyright © Abhijith Vijayan. Free software under the GNU GPL, version 3 or later, with no warranty.',
              key: const ValueKey('about-license'),
              style: DashText.caption(14, color: DashColors.ash),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 22),
          PrimaryButton(
            'Open Source Licenses',
            key: const ValueKey('about-licenses'),
            onTap: ref.read(licensesScreenOpenProvider.notifier).open,
          ),
          const SizedBox(height: 16),
          Text('Compatible apps', style: DashText.caption(15, color: DashColors.ash)),
          const SizedBox(height: 8),
          Text(
            'Android Auto via Open Headunit (AGPL-3.0)\n'
            'CarPlay via DiPlay (GPL-3.0)',
            style: DashText.caption(14, color: DashColors.ash),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 40),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Built by ', style: DashText.caption(15)),
              GestureDetector(
                key: const ValueKey('about-author'),
                behavior: HitTestBehavior.opaque,
                onTap: () => ref.read(qrCardProvider.notifier).show(
                  const QrCard(
                    id: 'author',
                    title: 'abhijithvijayan',
                    caption: 'Scan with your phone to visit the author\'s site.',
                    url: 'https://${AboutSection.authorUrl}',
                    shown: AboutSection.authorUrl,
                  ),
                  from: 'about',
                ),
                child: Text('abhijithvijayan', style: DashText.caption(15, color: DashColors.bone)),
              ),
              const SizedBox(width: 8),
              Icon(Icons.favorite_rounded, size: 16, color: DashColors.critical),
            ],
          ),
          const SizedBox(height: 8),
          GestureDetector(
            key: const ValueKey('about-repo'),
            behavior: HitTestBehavior.opaque,
            onTap: () => ref.read(qrCardProvider.notifier).show(
              const QrCard(
                id: 'repo',
                title: 'OpenDash on GitHub',
                caption: 'Scan with your phone to open the source code, releases and issues.',
                url: 'https://$repoUrl',
                shown: repoUrl,
              ),
              from: 'about',
            ),
            child: Text(repoUrl, style: DashText.caption(14)),
          ),
          const SizedBox(height: 14),
          GestureDetector(
            key: const ValueKey('about-report-bug'),
            behavior: HitTestBehavior.opaque,
            onTap: () => ref.read(qrCardProvider.notifier).reportIssue(from: 'about'),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  BugIcon(color: DashColors.bone),
                  const SizedBox(width: 8),
                  Text(ReportIssueButton.label, style: DashText.value(16)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small beetle glyph for the bug report link.
class BugIcon extends StatelessWidget {
  const BugIcon({super.key, required this.color, this.size = 16});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _BugPainter(color));
}

class _BugPainter extends CustomPainter {
  _BugPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stroke = Paint()
      ..color = color
      ..strokeWidth = w * 0.09
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final body = RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.28, h * 0.3, w * 0.44, h * 0.62), Radius.circular(w * 0.22));
    canvas.drawRRect(body, Paint()..color = color);
    canvas.drawCircle(Offset(w / 2, h * 0.22), w * 0.14, Paint()..color = color);
    canvas.drawLine(Offset(w / 2, h * 0.36), Offset(w / 2, h * 0.86), Paint()..color = DashColors.inkLift..strokeWidth = w * 0.07);
    for (final y in [0.42, 0.58, 0.74]) {
      canvas.drawLine(Offset(w * 0.28, h * y), Offset(w * 0.08, h * (y - 0.06)), stroke);
      canvas.drawLine(Offset(w * 0.72, h * y), Offset(w * 0.92, h * (y - 0.06)), stroke);
    }
  }

  @override
  bool shouldRepaint(_BugPainter old) => old.color != color;
}
