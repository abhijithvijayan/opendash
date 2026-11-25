import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../services/analytics_logger.dart';
import '../../state/firmware_state.dart';
import '../../theme/colors.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import '../settings/widgets.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "12 Nov 2026", or null when the clock could not be trusted at the time.
String? firmwareDate(int? ms) {
  if (ms == null) return null;
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// HOTA gives the size as text; a bare byte count is put into megabytes.
String firmwareSize(String raw) {
  final bytes = int.tryParse(raw.trim());
  if (bytes == null) return raw.trim();
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  return '${(bytes / (1024 * 1024)).round()} MB';
}

Widget _panel({Key? key, required Widget child, Color? edge}) => Container(
      key: key,
      width: double.infinity,
      padding: const EdgeInsets.all(DashSpace.cardPad),
      decoration: BoxDecoration(
        color: DashColors.inkLift,
        borderRadius: BorderRadius.circular(DashRadius.card),
        border: edge == null ? null : Border(left: BorderSide(color: edge, width: 4)),
      ),
      child: child,
    );

/// Settings → Updates → Scooter firmware: the rider's choice, what is in
/// force, and the way to the stock dashboard for a rider who wants an
/// update. Every value on it is read from the scooter.
class FirmwareCard extends ConsumerStatefulWidget {
  const FirmwareCard({super.key});

  @override
  ConsumerState<FirmwareCard> createState() => _FirmwareCardState();
}

class _FirmwareCardState extends ConsumerState<FirmwareCard> {
  bool _confirmRestore = false;

  @override
  Widget build(BuildContext context) {
    final fw = ref.watch(firmwareProvider);
    final n = ref.read(firmwareProvider.notifier);
    final autoDownload = ref.watch(vehicleProvider.select((v) => v.stockAutoDownload));
    final notice = fw.notice;
    final waiting = fw.noticeWaiting;
    final offered = notice == null || !waiting
        ? 'None'
        : [notice.version.isEmpty ? 'An update' : notice.version, ?firmwareDate(notice.atMs)].join(' · ');
    final change = fw.change;

    return _panel(
      key: const ValueKey('fw-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Scooter firmware', style: DashText.title(24)),
          const SizedBox(height: 6),
          Text(
            'From Ola. OpenDash never downloads or installs it.',
            style: DashText.caption(16),
          ),
          const SizedBox(height: 16),
          if (fw.restored) ...[
            Text(
              'Stock update settings are restored. OpenDash is no longer keeping firmware updates off. If OTA Shield is blocking them, turn its block off in OTA Shield too.',
              key: const ValueKey('fw-restored'),
              style: DashText.caption(18, color: DashColors.bone),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              'Keep firmware updates off again',
              key: const ValueKey('fw-manage'),
              onTap: () {
                uiTap('fw-manage');
                n.manageAgain();
              },
            ),
          ] else ...[
            ChipRow<FirmwareMode>(
              key: const ValueKey('fw-mode'),
              options: FirmwareMode.values,
              value: fw.mode,
              label: (m) => m == FirmwareMode.off ? 'Off' : 'Ask me',
              onSelected: (m) {
                uiTap('fw-mode', {'mode': m.name});
                n.setMode(m);
              },
            ),
            const SizedBox(height: 10),
            Text(
              fw.mode == FirmwareMode.off
                  ? 'Updates are not installed, and you are not asked.'
                  : 'You are told when Ola offers an update. Installing one happens in the stock dashboard.',
              style: DashText.caption(16),
            ),
          ],
          const SizedBox(height: 8),
          KeyValueRow('Updates', fw.restored ? 'Stock settings' : (fw.mode == FirmwareMode.off ? 'Off' : 'Ask me'),
              key: const ValueKey('fw-line-mode')),
          KeyValueRow(
            'Stock auto-download',
            switch (autoDownload) { null => 'Unknown', 0 => 'Off', _ => 'On' },
            key: const ValueKey('fw-line-autodl'),
          ),
          KeyValueRow('Last notice seen', offered, key: const ValueKey('fw-line-notice')),
          if (change != null && !change.headUnit)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Text(
                ['A controller\'s firmware version changed', ?firmwareDate(change.atMs)].join(' on '),
                key: const ValueKey('fw-ecu-changed'),
                style: DashText.caption(16),
              ),
            ),
          if (!fw.restored && fw.mode == FirmwareMode.ask) ...[
            const SizedBox(height: 12),
            if (waiting && notice != null) _Offer(notice: notice, onRead: n.readBeforeUpdating),
            if (waiting) const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: PrimaryButton(
                'Check now',
                key: const ValueKey('fw-check'),
                onTap: () {
                  uiTap('fw-check');
                  n.checkNow();
                },
              ),
            ),
          ],
          if (!fw.restored) ...[
            const SizedBox(height: 12),
            if (_confirmRestore)
              _panel(
                key: const ValueKey('fw-restore-confirm'),
                edge: DashColors.warning,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'The stock dashboard\'s auto-download goes back to how OpenDash found it, and OpenDash stops keeping firmware updates off. OTA Shield\'s block, if it is on, stays until you turn it off in OTA Shield.',
                      style: DashText.caption(16, color: DashColors.bone),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        PrimaryButton(
                          'Restore',
                          key: const ValueKey('fw-restore-yes'),
                          color: DashColors.warning,
                          onTap: () {
                            uiTap('fw-restore-yes');
                            setState(() => _confirmRestore = false);
                            n.restoreStock();
                          },
                        ),
                        const SizedBox(width: 12),
                        PrimaryButton(
                          'Cancel',
                          key: const ValueKey('fw-restore-no'),
                          onTap: () {
                            uiTap('fw-restore-no');
                            setState(() => _confirmRestore = false);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: PrimaryButton(
                  'Restore stock update settings',
                  key: const ValueKey('fw-restore'),
                  onTap: () {
                    uiTap('fw-restore');
                    setState(() => _confirmRestore = true);
                  },
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Offer extends StatelessWidget {
  const _Offer({required this.notice, required this.onRead});
  final FirmwareNotice notice;
  final VoidCallback onRead;

  @override
  Widget build(BuildContext context) {
    final size = firmwareSize(notice.size);
    final why = notice.buttonReason;
    return Container(
      key: const ValueKey('fw-offer'),
      width: double.infinity,
      padding: const EdgeInsets.all(DashSpace.cardPad),
      decoration: BoxDecoration(
        color: DashColors.ink,
        borderRadius: BorderRadius.circular(DashRadius.card),
        border: Border.all(color: DashColors.slate, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(notice.version.isEmpty ? 'Firmware update' : notice.version, style: DashText.title(22)),
          if (size.isNotEmpty) Text(size, style: DashText.caption(16)),
          if (notice.kind == 'download_done')
            Text('Downloaded, not installed', style: DashText.caption(16))
          else if (notice.kind == 'install_failed')
            Text('The last install failed', style: DashText.caption(16, color: DashColors.warning)),
          if (why != null) Text(why, style: DashText.caption(16)),
          if (notice.notes.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('What Ola says is new', style: DashText.caption(14)),
            const SizedBox(height: 6),
            for (final note in notice.notes)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('•  ', style: DashText.caption(16, color: DashColors.bone)),
                    Expanded(child: Text(note, style: DashText.caption(16, color: DashColors.bone))),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 14),
          PrimaryButton(
            'Read before updating',
            key: const ValueKey('fw-read'),
            onTap: () {
              uiTap('fw-read');
              onRead();
            },
          ),
        ],
      ),
    );
  }
}

/// The acknowledgement, shown after the passcode and before the stock
/// dashboard opens. The words are `FirmwareAck`'s.
class FirmwareAckPage extends ConsumerWidget {
  const FirmwareAckPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fw = ref.watch(firmwareProvider);
    final n = ref.read(firmwareProvider.notifier);
    final headUnit = ref.watch(vehicleProvider.select((v) => v.huVersion));
    final body = DashText.caption(17, color: DashColors.bone);
    return Column(
      key: const ValueKey('fw-ack'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(FirmwareAck.title(fw.notice?.version ?? ''), style: DashText.title(26)),
        const SizedBox(height: 14),
        Text(FirmwareAck.intro, style: body),
        const SizedBox(height: 14),
        Text(FirmwareAck.before, style: body),
        const SizedBox(height: 8),
        for (final (lead, rest) in FirmwareAck.points(headUnit.isEmpty ? 'unknown' : headUnit))
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: body),
                Expanded(
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: lead, style: body.copyWith(fontWeight: FontWeight.w700)),
                    TextSpan(text: rest, style: body),
                  ])),
                ),
              ],
            ),
          ),
        if (fw.ackBlocked) ...[
          const SizedBox(height: 6),
          _panel(
            key: const ValueKey('fw-ack-blocked'),
            edge: DashColors.warning,
            child: Text(FirmwareAck.blockOn, style: body),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            PrimaryButton(
              FirmwareAck.notNow,
              key: const ValueKey('fw-ack-not-now'),
              onTap: () {
                uiTap('fw-ack-not-now');
                n.notNow();
              },
            ),
            const SizedBox(width: 12),
            if (!fw.ackBlocked)
              PrimaryButton(
                FirmwareAck.open,
                key: const ValueKey('fw-ack-open'),
                color: DashColors.warning,
                onTap: () {
                  uiTap('fw-ack-open');
                  n.openStock();
                },
              ),
          ],
        ),
      ],
    );
  }
}
