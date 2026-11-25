import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/mock_provider.dart';
import '../../../services/analytics_logger.dart';
import '../../../state/raw_recording_state.dart';
import '../../../state/bus_log_state.dart';
import '../../../state/analytics_settings.dart';
import '../../../state/connection_check.dart';
import '../../../state/recovery_panel.dart';
import '../../../state/riding_lockout.dart';
import '../../../state/scooter_restart.dart';
import '../../../state/toast_state.dart';
import '../../../theme/colors.dart';
import '../../../theme/tokens.dart';
import '../../../theme/typography.dart';
import '../../../widgets/debug/bookmark_gesture.dart';
import '../widgets.dart';

/// Owner-facing switch for the on-device analytics log plus the capture
/// control for bug reports: enable logging, start a new capture, reproduce,
/// `adb pull`, send the file.
class DeveloperSection extends ConsumerWidget {
  const DeveloperSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(analyticsEnabledProvider);
    final path = AnalyticsLogger.instance.currentFilePath;
    final toast = ref.read(toastProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Analytics'),
        ToggleRow(
          key: const ValueKey('analytics-toggle'),
          label: 'Analytics logging',
          caption: 'Writes session events to a file on the head unit. Nothing leaves the scooter.',
          value: enabled,
          onChanged: ref.read(analyticsEnabledProvider.notifier).set,
        ),
        const SizedBox(height: 12),
        Text('Log file', style: DashText.caption(16, color: DashColors.ash)),
        const SizedBox(height: 4),
        SelectableText(
          path ?? 'Not writing to disk on this platform',
          key: const ValueKey('analytics-path'),
          style: DashText.caption(16, color: DashColors.bone),
        ),
        if (path != null) ...[
          const SizedBox(height: 8),
          Text('Pull with:  adb pull $path', style: DashText.caption(14, color: DashColors.ash)),
        ],
        // TODO: "Last pull: X minutes ago" once pulls are tracked.
        const SizedBox(height: 24),
        Row(
          children: [
            PrimaryButton(
              'Start new capture',
              key: const ValueKey('analytics-new-capture'),
              onTap: () {
                uiTap('analytics-new-capture');
                AnalyticsLogger.instance.startCapture();
                toast.show('New capture started');
              },
            ),
            const SizedBox(width: 16),
            PrimaryButton(
              'Add bookmark',
              key: const ValueKey('analytics-bookmark'),
              // No colour: [PrimaryButton.color] is the label's, and slate on
              // the button's slate made this one a blank pill (seen in
              // Chrome, where nobody could tell what the button was).
              onTap: ref.read(bookmarkProvider.notifier).add,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Start a new capture right before reproducing a problem, then pull the file: it isolates the reproduction from earlier noise.',
          style: DashText.caption(15, color: DashColors.ash),
        ),
        const SizedBox(height: 6),
        Text(
          'Add bookmark marks this moment in the log, so it is easy to find afterwards. Tapping the clock three times does the same from the dashboard.',
          style: DashText.caption(15, color: DashColors.ash),
        ),
        const SizedBox(height: 24),
        const _RawRecordingPanel(),
        const SizedBox(height: 24),
        const _BusLogPanel(),
        const SizedBox(height: 12),
        const _ConnectionCheck(),
        const _RecoveryPanel(),
      ],
    );
  }
}

/// Whether GitHub can be reached from here, and if not, where it stops.
class _ConnectionCheck extends ConsumerWidget {
  const _ConnectionCheck();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(vehicleProvider.select((v) => (v.wifiConnected, v.signalBars)));
    final check = ref.watch(connectionCheckProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Connection'),
        Text(
          'Wi-Fi ${v.$1 ? 'connected' : 'not connected'} · mobile signal ${v.$2} of 4. '
          'The check asks each network for GitHub, where apps are downloaded from, and for four other addresses to compare, and says where each stops. Takes up to 20 seconds; it carries on if you leave this page.',
          style: DashText.caption(15, color: DashColors.ash),
        ),
        const SizedBox(height: 12),
        Opacity(
          opacity: check.running ? 0.4 : 1,
          child: PrimaryButton(
            check.running ? 'Checking…' : 'Check connection',
            key: const ValueKey('connection-check'),
            onTap: () {
              uiTap('connection-check');
              ref.read(connectionCheckProvider.notifier).run();
            },
          ),
        ),
        if (check.lines != null) ...[
          const SizedBox(height: 12),
          for (final (i, line) in check.lines!.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(line, key: ValueKey('connection-line-$i'), style: DashText.caption(15, color: DashColors.bone)),
            ),
        ],
        const SizedBox(height: 12),
      ],
    );
  }
}

class _RecoveryPanel extends ConsumerWidget {
  const _RecoveryPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final riding = ref.watch(ridingLockoutProvider);
    final panel = ref.read(recoveryPanelProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Recovery'),
        Text(
          riding
              ? 'Not available while riding.'
              : 'Fixes for a stuck display or stock dashboard, run on the head unit itself. Nothing here changes the vehicle.',
          key: const ValueKey('recovery-note'),
          style: DashText.caption(15, color: riding ? DashColors.warning : DashColors.ash),
        ),
        const SizedBox(height: 12),
        _RecoveryCard(
          id: 'wake',
          title: 'Wake display',
          caption: 'Wakes the screen and turns the screensaver off until the next restart.',
          action: 'Wake',
          enabled: !riding,
          onTap: panel.wakeDisplay,
        ),
        _RecoveryCard(
          id: 'restart-stock',
          title: 'Restart stock dashboard',
          caption: 'Stops the Ola dashboard and starts it again, for when it comes up white or frozen.',
          action: 'Restart',
          enabled: !riding,
          onTap: panel.askRestartStock,
        ),
        _RecoveryCard(
          id: 'density',
          title: 'Reset display density',
          caption: 'Removes a density override set over adb. The screen redraws.',
          action: 'Reset',
          enabled: !riding,
          onTap: panel.resetDensity,
        ),
        _RecoveryCard(
          id: 'stop-stock',
          title: 'Stop stock dashboard',
          caption: 'Force-stops the Ola dashboard if it is still running behind OpenDash.',
          action: 'Stop',
          enabled: !riding,
          onTap: panel.stopStock,
        ),
        _RecoveryCard(
          id: 'open-stock',
          title: 'Open stock dashboard',
          caption: 'Come back with "← OpenDash" at the top of the screen, or stock Settings → Reboot Scooter.',
          action: 'Open',
          enabled: !riding,
          onTap: panel.openStock,
        ),
        const SizedBox(height: 4),
        const SizedBox(height: 8),
        // A button, as in Vehicle Info: as a line of text it did not look
        // like something to press.
        Opacity(
          opacity: riding ? 0.4 : 1,
          child: PrimaryButton(
            'Restart scooter',
            key: const ValueKey('recovery-restart-scooter'),
            icon: Icon(Icons.restart_alt_rounded, size: 22, color: DashColors.bone),
            onTap: () {
              uiTap('recovery-restart-scooter');
              if (riding) return;
              ref.read(scooterRestartProvider.notifier).request('recovery');
            },
          ),
        ),
      ],
    );
  }
}

class _RecoveryCard extends StatelessWidget {
  const _RecoveryCard({
    required this.id,
    required this.title,
    required this.caption,
    required this.action,
    required this.enabled,
    required this.onTap,
  });
  final String id;
  final String title;
  final String caption;
  final String action;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Container(
            key: ValueKey('recovery-card-$id'),
            padding: const EdgeInsets.all(DashSpace.cardPad),
            decoration: BoxDecoration(
              color: DashColors.inkLift,
              borderRadius: BorderRadius.circular(DashRadius.card),
              border: Border.all(color: DashColors.slate, width: 1.5),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: DashText.caption(20, color: DashColors.bone)),
                      const SizedBox(height: 4),
                      Text(caption, style: DashText.caption(16)),
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                IgnorePointer(
                  ignoring: !enabled,
                  child: PrimaryButton(action, key: ValueKey('recovery-$id'), onTap: onTap),
                ),
              ],
            ),
          ),
        ),
      );
}

/// "Bus log": the whole bus whenever OpenDash is in front, with the minute
/// around each command, fault, ride and charge kept in full (`BusLog`).
class _BusLogPanel extends ConsumerWidget {
  const _BusLogPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = ref.watch(busLogProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ToggleRow(
          key: const ValueKey('bus-log-toggle'),
          label: 'Bus log',
          caption: 'Keeps every change on the scooter\'s bus, and the minute around each command, fault, ride and charge, '
              'in files beside the log, for testing on a scooter OpenDash has not been checked on. They may hold the '
              'scooter\'s identifiers: share them only with someone you trust.',
          value: b.enabled,
          onChanged: (on) {
            uiTap('bus-log-toggle', {'on': on});
            ref.read(busLogProvider.notifier).setEnabled(on);
          },
        ),
        if (b.active) ...[
          const SizedBox(height: 6),
          Text(
            '${b.frames} frames read, ${b.changed} written, ${b.bursts} bursts',
            key: const ValueKey('bus-log-status'),
            style: DashText.caption(15, color: DashColors.ash),
          ),
        ],
        if (b.path != null) ...[
          const SizedBox(height: 6),
          SelectableText(b.path!, key: const ValueKey('bus-log-path'), style: DashText.caption(14, color: DashColors.bone)),
        ],
      ],
    );
  }
}

/// "Record raw data": five minutes of everything the scooter sends, for
/// working out a scooter OpenDash has not been checked on.
class _RawRecordingPanel extends ConsumerWidget {
  const _RawRecordingPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(rawRecordingProvider);
    final n = ref.read(rawRecordingProvider.notifier);
    final toast = ref.read(toastProvider.notifier);
    final minutes = RawRecordingNotifier.length.inMinutes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Raw recording'),
        PrimaryButton(
          r.active ? 'Stop recording (${r.secondsLeft} s left)' : 'Record raw data ($minutes min)',
          key: const ValueKey('raw-recording'),
          onTap: () {
            uiTap('raw-recording', {'active': r.active});
            if (r.active) {
              n.stop();
              toast.show('Recording saved');
            } else {
              n.start();
              toast.show('Recording for $minutes minutes');
            }
          },
        ),
        const SizedBox(height: 12),
        Text(
          r.active
              ? '${r.frames} frames, ${r.batches} updates so far. Ride, use each mode, brake: it keeps recording while you do.'
              : 'Writes everything the scooter sends for $minutes minutes into a file of its own, to work out a scooter OpenDash has not been checked on. It may hold the scooter\'s identifiers: share it only with someone you trust.',
          key: const ValueKey('raw-recording-caption'),
          style: DashText.caption(15, color: DashColors.ash),
        ),
        if (r.path != null) ...[
          const SizedBox(height: 6),
          SelectableText(r.path!, key: const ValueKey('raw-recording-path'), style: DashText.caption(14, color: DashColors.bone)),
        ],
      ],
    );
  }
}
