import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/build_info.dart';
import '../../providers/mock_provider.dart';
import '../../state/firmware_state.dart';
import '../../state/ota_shield_state.dart';
import '../../state/ota_state.dart';
import '../../state/qr_card.dart';
import '../../state/usage_ping.dart';
import '../../services/analytics_logger.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/ota/ota_progress_bar.dart';
import '../../widgets/overlays/alert_overlay.dart';
import '../../widgets/overlays/call_overlay.dart';
import '../settings/widgets.dart';
import 'firmware_card.dart';
import 'ota_shield_card.dart';
import '../../theme/tokens.dart';

/// Settings → Updates. Three cards: OpenDash itself, the firmware block
/// (OTA Shield, `OtaShieldCard`) and scooter firmware (real values from the
/// scooter, `FirmwareCard`). Calm, precise, always
/// recoverable.
class OtaScreen extends ConsumerWidget {
  const OtaScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(otaScreenOpenProvider);
    final shift = ref.watch(alertBannerShiftProvider) + ref.watch(callBarShiftProvider);
    return AnimatedPositioned(
      duration: DashMotion.normal,
      curve: Curves.easeOutCubic,
      left: open ? 0 : 1280,
      top: shift,
      width: 1280,
      height: 768 - shift,
      child: open ? const _Body() : const SizedBox.shrink(),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ackOpen = ref.watch(firmwareProvider.select((f) => f.ackOpen));
    final shield = ref.watch(otaShieldShownProvider);
    return ColoredBox(
      key: const ValueKey('ota-body'),
      color: DashColors.ink,
      child: Stack(
        children: [
          Positioned(
            left: 240,
            width: 800,
            top: DashSpace.overlayTop,
            bottom: 0,
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: DashSpace.bodyBottom),
              child: ackOpen
                  ? const FirmwareAckPage()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _OpenDashCard(),
                        const SizedBox(height: 16),
                        if (shield) ...const [OtaShieldCard(), SizedBox(height: 16)],
                        const FirmwareCard(),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// OpenDash's own updates, from its GitHub releases: what is installed,
/// whether a newer release exists, and the steps to it. Each step is the
/// rider's tap; Android's own confirmation screen is the last one.
class _OpenDashCard extends ConsumerWidget {
  const _OpenDashCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ota = ref.watch(otaProvider);
    final n = ref.read(otaProvider.notifier);
    final release = ota.offered ? ota.release : null;
    final status = release == null ? OtaStatus.upToDate : ota.status;
    return Container(
      key: const ValueKey('opendash-card'),
      padding: const EdgeInsets.all(DashSpace.cardPad),
      decoration: BoxDecoration(color: DashColors.inkLift, borderRadius: BorderRadius.circular(DashRadius.card)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('OpenDash', style: DashText.title(24)),
          const SizedBox(height: 6),
          Text('Installed: ${BuildInfo.label}', key: const ValueKey('opendash-installed'), style: DashText.caption(16)),
          const SizedBox(height: 14),
          AnimatedSwitcher(
            duration: DashMotion.fast,
            switchInCurve: Curves.linear,
            switchOutCurve: Curves.linear,
            transitionBuilder: DashMotion.fadeThrough,
            child: KeyedSubtree(
              key: ValueKey(status),
              child: switch (status) {
                OtaStatus.upToDate => _UpToDate(ota),
                OtaStatus.available => _Available(ota, release!),
                OtaStatus.downloading => _Downloading(ota, release!),
                OtaStatus.ready => _Ready(release!),
                OtaStatus.installing => _Installing(release!),
                OtaStatus.failed => _Failed(ota),
              },
            ),
          ),
          const SizedBox(height: 16),
          Text('Check for OpenDash updates', style: DashText.caption(14)),
          const SizedBox(height: 8),
          ChipRow<bool>(
            key: const ValueKey('ota-auto'),
            options: const [true, false],
            value: ota.auto,
            label: (auto) => auto ? 'Automatically' : 'Only when I ask',
            onSelected: (auto) {
              uiTap('ota-auto', {'auto': auto});
              n.setAuto(auto);
            },
          ),
          const SizedBox(height: 6),
          GestureDetector(
            key: const ValueKey('ota-companion'),
            behavior: HitTestBehavior.opaque,
            onTap: () => ref.read(qrCardProvider.notifier).companionApp(from: 'updates'),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                ota.auto
                    ? 'The OpenDash Companion app on your phone also sends new versions here by itself. Tap for the download.'
                    : 'With "Only when I ask", the OpenDash Companion app on your phone sends a new version only when you tell it to. Tap for the download.',
                style: DashText.caption(14),
              ),
            ),
          ),
          const SizedBox(height: 8),
          ToggleRow(
            key: const ValueKey('usage-ping'),
            label: 'Count this install',
            caption: 'Once a week: OpenDash version, scooter model, software and head unit hardware. No ID, nothing about you',
            value: ref.watch(usagePingProvider),
            onChanged: ref.read(usagePingProvider.notifier).set,
          ),
        ],
      ),
    );
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _megabytes(int bytes) => bytes <= 0 ? '' : '${(bytes / (1024 * 1024)).round()} MB';

/// "2026-11-16T10:00:00Z" -> "16 Nov 2026".
String _published(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  return d == null ? '' : '${d.day} ${_months[d.month - 1]} ${d.year}';
}

class _BigButton extends StatelessWidget {
  const _BigButton(this.label, {super.key, required this.onTap, this.background, this.foreground});
  final String label;
  final VoidCallback? onTap;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final background = this.background ?? DashColors.slate;
    final foreground = this.foreground ?? DashColors.bone;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled
          ? () {
              HapticFeedback.lightImpact();
              onTap!();
            }
          : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: Container(
          height: 56,
          width: double.infinity,
          decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(DashRadius.button)),
          child: Center(child: Text(label, style: DashText.value(19, color: foreground))),
        ),
      ),
    );
  }
}

class _UpToDate extends ConsumerWidget {
  const _UpToDate(this.ota);
  final OtaData ota;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final checked = firmwareDate(ota.checkedAtMs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (ota.unreachable)
          Text("Couldn't reach GitHub", key: const ValueKey('ota-unreachable'), style: DashText.title(20))
        else
          Text('OpenDash is up to date', key: const ValueKey('ota-up-to-date'), style: DashText.title(20)),
        const SizedBox(height: 4),
        Text(
          ota.unreachable
              ? "Check the scooter's internet connection"
              : checked == null
                  ? 'Not checked yet'
                  : 'Last checked $checked',
          style: DashText.caption(16),
        ),
        const SizedBox(height: 14),
        _BigButton(
          ota.checking ? 'Checking' : 'Check now',
          key: const ValueKey('ota-check'),
          onTap: ota.checking
              ? null
              : () {
                  uiTap('ota-check');
                  ref.read(otaProvider.notifier).check();
                },
        ),
        if (ota.unreachable) const _GetCompanion(),
      ],
    );
  }
}

class _ReleaseHeader extends StatelessWidget {
  const _ReleaseHeader(this.release);
  final OtaRelease release;

  @override
  Widget build(BuildContext context) {
    final facts = [_published(release.published), _megabytes(release.size)].where((s) => s.isNotEmpty).join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('OpenDash ${release.version}', style: DashText.title(22)),
        Text(['build ${release.build}', if (facts.isNotEmpty) facts].join(' · '), style: DashText.caption(16)),
      ],
    );
  }
}

class _Available extends ConsumerWidget {
  const _Available(this.ota, this.release);
  final OtaData ota;
  final OtaRelease release;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(accentProvider);
    final n = ref.read(otaProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReleaseHeader(release),
        if (release.notes.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          Text("What's new", style: DashText.caption(14)),
          const SizedBox(height: 6),
          Text(release.notes.trim(), key: const ValueKey('ota-notes'), style: DashText.caption(16, color: DashColors.bone)),
        ],
        if (release.url.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(release.url, style: DashText.caption(14)),
        ],
        const SizedBox(height: 16),
        _BigButton(
          'Download',
          key: const ValueKey('ota-download'),
          background: accent,
          foreground: DashColors.ink,
          onTap: () {
            uiTap('ota-download');
            n.startDownload();
          },
        ),
        const SizedBox(height: 4),
        Center(
          child: TextButtonLink(
            'Skip this version',
            key: const ValueKey('ota-skip'),
            onTap: () {
              uiTap('ota-skip');
              n.skip();
            },
          ),
        ),
      ],
    );
  }
}

class _Downloading extends ConsumerWidget {
  const _Downloading(this.ota, this.release);
  final OtaData ota;
  final OtaRelease release;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReleaseHeader(release),
        const SizedBox(height: 14),
        OtaProgressBar(progress: ota.progress, color: DashColors.normal, active: true),
        const SizedBox(height: 8),
        Text('Downloading · ${ota.progress}%', style: DashText.value(18)),
        const SizedBox(height: 8),
        Center(
          child: TextButtonLink(
            'Cancel',
            key: const ValueKey('ota-cancel'),
            onTap: () {
              uiTap('ota-cancel');
              ref.read(otaProvider.notifier).cancelDownload();
            },
          ),
        ),
      ],
    );
  }
}

class _Ready extends ConsumerWidget {
  const _Ready(this.release);
  final OtaRelease release;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Rebuilt as the scooter's state changes, so the reason is current.
    ref.watch(vehicleProvider.select((v) => (v.locked, v.provenStopped, v.vehicleState, v.hyperCharging, v.callActive)));
    final refusal = ref.read(otaProvider.notifier).installRefusal();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReleaseHeader(release),
        const SizedBox(height: 8),
        Text('Downloaded and checked. Ready to install.', key: const ValueKey('ota-ready'), style: DashText.caption(16, color: DashColors.bone)),
        const SizedBox(height: 4),
        Text(
          'OpenDash closes for a few seconds while Android installs it, then comes back by itself. Your settings are kept.',
          style: DashText.caption(16),
        ),
        if (refusal != null) ...[
          const SizedBox(height: 8),
          Text(OtaNotifier.refusalText(refusal), key: const ValueKey('ota-install-held'), style: DashText.caption(16, color: DashColors.warning)),
        ],
        const SizedBox(height: 14),
        _BigButton(
          'Install',
          key: const ValueKey('ota-install'),
          background: DashColors.eco,
          foreground: DashColors.ink,
          onTap: () {
            uiTap('ota-install');
            ref.read(otaProvider.notifier).startInstall();
          },
        ),
      ],
    );
  }
}

class _Installing extends StatelessWidget {
  const _Installing(this.release);
  final OtaRelease release;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ReleaseHeader(release),
        const SizedBox(height: 10),
        Text('Android will ask you to confirm', key: const ValueKey('ota-installing'), style: DashText.title(20, color: DashColors.warning)),
        const SizedBox(height: 4),
        Text('Confirm on Android\'s screen to install. OpenDash restarts when it is done.', style: DashText.caption(16)),
      ],
    );
  }
}

class _Failed extends ConsumerWidget {
  const _Failed(this.ota);
  final OtaData ota;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('The update was not installed', style: DashText.title(20, color: DashColors.critical)),
        const SizedBox(height: 4),
        Text(ota.error, key: const ValueKey('ota-error'), style: DashText.caption(16, color: DashColors.bone)),
        const SizedBox(height: 4),
        Text('The build that is running is untouched.', style: DashText.caption(16)),
        const SizedBox(height: 14),
        _BigButton(
          'Try again',
          key: const ValueKey('ota-retry'),
          onTap: () {
            uiTap('ota-retry');
            ref.read(otaProvider.notifier).retry();
          },
        ),
        const _GetCompanion(),
      ],
    );
  }
}

/// When GitHub can't be reached or the update failed: the phone app can
/// send the update over the scooter's own network instead.
class _GetCompanion extends ConsumerWidget {
  const _GetCompanion();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Center(
        child: TextButtonLink(
          'Send it from your phone instead',
          key: const ValueKey('ota-get-companion'),
          onTap: () {
            uiTap('ota-get-companion');
            ref.read(qrCardProvider.notifier).companionApp(from: 'update-failed');
          },
        ),
      ),
    );
  }
}
