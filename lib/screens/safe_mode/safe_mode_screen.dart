import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../providers/mock_provider.dart';
import '../../services/trusted_clock.dart';
import '../../state/crash_recovery.dart';
import '../../state/ota_state.dart';
import '../../state/qr_card.dart';
import '../../state/format_settings.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../settings/widgets.dart';
import '../../widgets/status_bar/status_icons.dart';

/// Minimal fallback when normal initialisation keeps failing. The clock
/// comes from the system, not the vehicle service, so it works without
/// HHMIS.
class SafeModeScreen extends ConsumerStatefulWidget {
  const SafeModeScreen({super.key});

  @override
  ConsumerState<SafeModeScreen> createState() => _SafeModeScreenState();
}

class _SafeModeScreenState extends ConsumerState<SafeModeScreen> {
  late Timer _clock;
  DateTime _now = TrustedClock.wall();

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => setState(() => _now = TrustedClock.wall()));
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final soc = ref.watch(vehicleProvider.select((v) => v.socKnown ? v.batterySoc : null));
    // Don't offer the boot button while locked.
    final locked = ref.watch(vehicleProvider.select((v) => v.locked));
    final n = ref.read(crashRecoveryProvider.notifier);
    final pendingUpdate = ref.watch(otaProvider.select((o) => o.pendingBuild));
    // The head unit boots at the firmware build date until the network sets it.
    final time = TrustedClock.trusted
        ? formatClock(_now.hour, _now.minute, use24Hour: ref.watch(use24HourProvider))
        : VehicleNotifier.unknownClock;

    return ColoredBox(
      color: DashColors.ink,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(appName, style: DashText.mode(DashColors.bone, size: 40)),
            const SizedBox(height: 4),
            Text('v$appVersion', key: const ValueKey('safe-version'), style: DashText.caption(16)),
            const SizedBox(height: 8),
            Text('Safe Mode', key: const ValueKey('safe-mode'), style: DashText.title(22, color: DashColors.warning)),
            if (pendingUpdate != 0) ...[
              const SizedBox(height: 8),
              Text(
                'This started after an update of OpenDash (build $pendingUpdate). If it keeps happening, use the stock dashboard and install an older build.',
                key: const ValueKey('safe-update'),
                style: DashText.caption(16, color: DashColors.bone),
                textAlign: TextAlign.center,
              ),
            ],
            const SizedBox(height: 36),
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(time, style: DashText.value(44)),
                const SizedBox(width: 40),
                Text(soc == null ? '—' : '$soc%', style: DashText.value(44)),
                const SizedBox(width: 8),
                Text('battery', style: DashText.caption(16)),
              ],
            ),
            const SizedBox(height: 40),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PrimaryButton('Retry', key: const ValueKey('safe-retry'), onTap: n.retry),
                const SizedBox(width: 16),
                PrimaryButton('Stock Dashboard', key: const ValueKey('safe-stock'), onTap: n.launchStockApp),
              ],
            ),
            if (!locked) const _SafeUpdate(),
            if (!locked) ...[
              const SizedBox(height: 16),
              PrimaryButton(
                'Open Trunk',
                key: const ValueKey('safe-trunk'),
                icon: TrunkOpenIcon(color: DashColors.bone),
                onTap: ref.read(vehicleProvider.notifier).openTrunk,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A broken build can be replaced from here: check, download and install go
/// through the same steps as on the Updates screen (parked, passcode,
/// Android's confirmation), and an update sent from the companion phone app
/// shows up as ready.
class _SafeUpdate extends ConsumerWidget {
  const _SafeUpdate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ota = ref.watch(otaProvider);
    final n = ref.read(otaProvider.notifier);
    final v = ota.versionName;
    final Widget child = switch (ota.status) {
      OtaStatus.ready => PrimaryButton('Install OpenDash $v', key: const ValueKey('safe-update-install'), onTap: n.startInstall),
      OtaStatus.available => PrimaryButton('Download OpenDash $v', key: const ValueKey('safe-update-download'), onTap: n.startDownload),
      OtaStatus.downloading => Text('Downloading OpenDash $v · ${ota.progress}%', style: DashText.caption(16, color: DashColors.bone)),
      OtaStatus.installing => Text("Waiting for Android's installer", style: DashText.caption(16, color: DashColors.bone)),
      OtaStatus.upToDate || OtaStatus.failed => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (ota.status == OtaStatus.failed && ota.error.isNotEmpty) ...[
              Text(ota.error, style: DashText.caption(15, color: DashColors.warning)),
              const SizedBox(height: 8),
            ],
            PrimaryButton(ota.checking ? 'Checking…' : 'Check for updates',
                key: const ValueKey('safe-update-check'), onTap: () => ota.checking ? null : n.check()),
          ],
        ),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        child,
        GestureDetector(
          key: const ValueKey('safe-companion'),
          behavior: HitTestBehavior.opaque,
          onTap: () => ref.read(qrCardProvider.notifier).companionApp(from: 'safe_mode'),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            child: Text('Or update from your phone with the OpenDash Companion app', style: DashText.caption(14)),
          ),
        ),
      ]),
    );
  }
}
