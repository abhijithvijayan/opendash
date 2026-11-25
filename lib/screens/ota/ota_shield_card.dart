import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/app_catalog.dart';
import '../../models/ota_shield.dart';
import '../../services/analytics_logger.dart';
import '../../services/trusted_clock.dart';
import '../../state/access_state.dart';
import '../../state/apps_state.dart';
import '../../state/ota_shield_state.dart';
import '../../theme/colors.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import '../settings/widgets.dart';
import 'firmware_card.dart';

CatalogApp get _shield => appCatalog.firstWhere((a) => a.id == CatalogApp.otaShieldId);

/// Settings → Updates → Firmware block: OTA Shield, a separate app that
/// keeps Ola's firmware updates off the scooter. OpenDash shows what it
/// reports, opens it, and where its service answers can ask it to activate
/// the block or lift its boot fail-safe. Turning the block off is done in
/// OTA Shield.
class OtaShieldCard extends ConsumerWidget {
  const OtaShieldCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(otaShieldInstalledProvider);
    final report = ref.watch(otaShieldProvider);
    final status = ref.watch(appManagerProvider.select((m) => m[CatalogApp.otaShieldId]));
    final busy = status == AppStatus.queued || status == AppStatus.downloading || status == AppStatus.installing;
    final service = report?.service;
    final activating = !(report?.running ?? false) && (service?.activating ?? false);

    final (headline, color) = !installed
        ? (busy ? 'Installing OTA Shield' : 'Not installed', DashColors.ash)
        : report == null
            ? ('Checking', DashColors.ash)
            : report.running
                ? ('Blocking firmware updates', DashColors.eco)
                : report.failsafe
                    ? ('Fail-safe on: cut off from Ola\'s cloud', DashColors.critical)
                    : activating
                        ? ('Activating', DashColors.bone)
                        : ('Not blocking', DashColors.warning);

    void open() {
      uiTap('shield-open', {'running': report?.running});
      ref.read(accessProvider.notifier).ask(
            title: 'Before OTA Shield opens',
            accesses: const [Access.overlay, Access.front],
            required: const {Access.overlay},
            scope: CatalogApp.otaShieldId,
            then: () => ref.read(appManagerProvider.notifier).launch(_shield),
          );
    }

    final canActivate = installed && report != null && service != null && !report.running && !activating;
    // OpenDash's own activation brings OTA Shield's reason; one that failed
    // elsewhere (at power-on, or in OTA Shield) only its step.
    final error = service?.activation == 'failed'
        ? service?.activationError
        : service?.step == 'FAILED'
            ? 'OTA Shield could not start its block. Open it to see why.'
            : null;

    return Container(
      key: const ValueKey('shield-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(DashSpace.cardPad),
      decoration: BoxDecoration(
        color: DashColors.inkLift,
        borderRadius: BorderRadius.circular(DashRadius.card),
        border: installed && report != null ? Border(left: BorderSide(color: color, width: 4)) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Firmware block', style: DashText.title(24)),
          const SizedBox(height: 6),
          Text(
            'By OTA Shield, a separate app from its own developer. It needs root on the head unit. OpenDash shows what it reports and can start it; turning it off is done in OTA Shield.',
            style: DashText.caption(16),
          ),
          const SizedBox(height: 14),
          Text(headline, key: const ValueKey('shield-status'), style: DashText.title(20, color: color)),
          const SizedBox(height: 4),
          if (!installed)
            Text(
              'Install it from Apps, open it and tap Activate. Its status then shows here.',
              style: DashText.caption(16),
            )
          else if (report != null && report.running) ...[
            KeyValueRow('Messages blocked', '${report.blocked ?? '-'}', key: const ValueKey('shield-blocked')),
            KeyValueRow('Updates held back', '${report.offerCount ?? '-'}', key: const ValueKey('shield-offers')),
            KeyValueRow('Last held back', _lastLine(report), key: const ValueKey('shield-last')),
            if (report.inBytes != null && report.outBytes != null)
              KeyValueRow('Cloud traffic let through', '${_size(report.inBytes!)} in · ${_size(report.outBytes!)} out',
                  key: const ValueKey('shield-traffic')),
          ] else if (report != null && report.failsafe)
            Text(
              'OTA Shield could not start its block, so it shut the scooter off from Ola\'s cloud to keep updates out. The Ola app and cloud features do not work until the block is activated.',
              key: const ValueKey('shield-failsafe-hint'),
              style: DashText.caption(16),
            )
          else if (activating)
            Text(_stepText(service?.currentStep), key: const ValueKey('shield-step'), style: DashText.caption(16))
          else if (report != null)
            Text(
              service == null
                  ? 'OTA Shield is installed but its blocker is not running, so Ola can send updates. Open it and activate the block.'
                  : 'OTA Shield is installed but its blocker is not running, so Ola can send updates.',
              key: const ValueKey('shield-off-hint'),
              style: DashText.caption(16),
            ),
          if (error != null && !(report?.running ?? false)) ...[
            const SizedBox(height: 8),
            Text(service?.activation == 'failed' ? 'Last try failed: $error' : error, key: const ValueKey('shield-error'), style: DashText.caption(16, color: DashColors.warning)),
          ],
          const SizedBox(height: 14),
          if (!installed)
            PrimaryButton(
              busy ? 'Open Apps' : 'Get OTA Shield',
              key: const ValueKey('shield-get'),
              onTap: () {
                uiTap('shield-get');
                ref.read(appLauncherOpenProvider.notifier).open();
              },
            )
          else if (canActivate)
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                PrimaryButton(
                  'Activate',
                  key: const ValueKey('shield-activate'),
                  onTap: () => ref.read(otaShieldProvider.notifier).activate(),
                ),
                if (report.failsafe)
                  TextButtonLink(
                    'Turn off fail-safe',
                    key: const ValueKey('shield-failsafe-off'),
                    onTap: () => ref.read(otaShieldProvider.notifier).disableFailsafe(),
                  ),
                TextButtonLink('Open OTA Shield', key: const ValueKey('shield-open'), onTap: open),
              ],
            )
          else
            PrimaryButton(
              report != null && !report.running && service == null ? 'Open OTA Shield to activate' : 'Open OTA Shield',
              key: const ValueKey('shield-open'),
              onTap: open,
            ),
        ],
      ),
    );
  }
}

/// OTA Shield's activation steps, in the words its own app uses.
String _stepText(String? step) => switch (step) {
      'PREPARING_DIR' => 'Preparing',
      'VERIFYING_CERTS' => 'Checking certificates',
      'MOUNTING_CERTS' => 'Installing certificates',
      'STARTING_DAEMON' => 'Starting its blocker',
      'ENABLING_FIREWALL' => 'Redirecting Ola\'s traffic',
      'VERIFYING_INTERCEPTION' => 'Checking the block',
      'VERIFYING_CCM' => 'Reconnecting to Ola\'s cloud',
      _ => 'Starting',
    };

String _size(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
    : bytes >= 1024
        ? '${(bytes / 1024).round()} KB'
        : '$bytes B';

/// "MCU 1.2 → 1.3 · 20 Nov 2026" for the newest offer held back; the date
/// only when the head unit's clock was set when it came.
String _lastLine(OtaShieldReport report) {
  final offer = report.offers.firstOrNull;
  if (offer == null) return 'None yet';
  final up = offer.upgrades.firstOrNull;
  final what = up == null
      ? 'An update'
      : [up.component, if (up.to.isNotEmpty) up.to].join(' ') + (offer.upgrades.length > 1 ? ' +${offer.upgrades.length - 1}' : '');
  final at = DateTime.fromMillisecondsSinceEpoch(offer.atMs);
  return [what, if (offer.atMs > 0 && TrustedClock.plausible(at)) ?firmwareDate(offer.atMs)].join(' · ');
}
