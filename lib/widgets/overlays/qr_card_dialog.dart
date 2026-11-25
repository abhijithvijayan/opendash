import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr/qr.dart';

import '../../screens/settings/widgets.dart';
import '../../state/qr_card.dart';
import '../../theme/colors.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';

/// A web address as a QR code for the rider's phone (`qrCardProvider`):
/// Report Issue, the author and the repository. Drawn dark on white in both
/// themes: phone scanners read that best.
class QrCardDialog extends ConsumerWidget {
  const QrCardDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final card = ref.watch(qrCardProvider);
    if (card == null) return const SizedBox.shrink();
    final close = ref.read(qrCardProvider.notifier).close;
    return Positioned.fill(
      key: const ValueKey('qr-card'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: close,
        child: ColoredBox(
          color: DashColors.ink.withValues(alpha: DashScrim.backdrop),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: Container(
                width: 620,
                padding: const EdgeInsets.all(DashSpace.dialogPad),
                decoration: BoxDecoration(
                  color: DashColors.inkLift,
                  borderRadius: BorderRadius.circular(DashRadius.dialog),
                  border: Border.all(color: DashColors.slate, width: 1.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      key: const ValueKey('qr-card-code'),
                      width: 220,
                      height: 220,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: const Color(0xFFFFFFFF), borderRadius: BorderRadius.circular(DashRadius.card)),
                      child: CustomPaint(painter: QrPainter(card.url)),
                    ),
                    const SizedBox(width: 28),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(card.title, key: const ValueKey('qr-card-title'), style: DashText.title(24)),
                          const SizedBox(height: 10),
                          Text(
                            card.caption,
                            style: DashText.caption(16, color: DashColors.bone),
                          ),
                          const SizedBox(height: 10),
                          Text(card.shown, key: const ValueKey('qr-card-url'), style: DashText.caption(15)),
                          const SizedBox(height: 20),
                          PrimaryButton('Close', key: const ValueKey('qr-card-close'), onTap: close),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class QrPainter extends CustomPainter {
  QrPainter(this.data) : _image = QrImage(QrCode(payload: QrPayload.fromString(data), errorCorrectLevel: QrErrorCorrectLevel.low));

  final String data;
  final QrImage _image;

  int get modules => _image.moduleCount;

  bool isDark(int row, int col) => _image.isDark(row, col);

  @override
  void paint(Canvas canvas, Size size) {
    final n = _image.moduleCount;
    final cell = size.shortestSide / n;
    final paint = Paint()..color = const Color(0xFF000000);
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        if (_image.isDark(r, c)) canvas.drawRect(Rect.fromLTWH(c * cell, r * cell, cell + 0.5, cell + 0.5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(QrPainter old) => old.data != data;
}
