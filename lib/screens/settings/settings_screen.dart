import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/apps_state.dart';
import '../../state/crash_recovery.dart';
import '../../state/firmware_state.dart';
import '../../state/ota_state.dart';
import '../../state/recovery_panel.dart';
import '../../state/riding_settings.dart';
import '../../state/settings_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/overlays/alert_overlay.dart';
import '../../widgets/overlays/call_overlay.dart';
import '../../theme/tokens.dart';
import 'change_passcode_screen.dart';
import 'sections/about_section.dart';
import 'sections/connectivity_section.dart';
import 'sections/developer_section.dart';
import 'sections/display_section.dart';
import 'sections/profile_section.dart';
import 'sections/riding_section.dart';
import 'sections/sound_section.dart';
import 'sections/vehicle_info_section.dart';
import 'widgets.dart';
import '../../widgets/status_bar/status_icons.dart';
import '../../services/analytics_logger.dart';

/// Full-screen settings overlay: sidebar on the left, scrolling content on
/// the right. Slides in from the right under the overlay toolbar, which
/// carries the title and the back arrow.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static const sidebarWidth = 320.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(settingsScreenOpenProvider);
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
    final section = ref.watch(settingsSectionProvider);
    final prompt = ref.watch(ridingSettingsProvider.select((s) => s.hillHoldPrompt));
    final standPrompt = ref.watch(ridingSettingsProvider.select((s) => s.standBypassPrompt));
    final vacationPrompt = ref.watch(ridingSettingsProvider.select((s) => s.vacationPrompt));
    final changeOpen = ref.watch(changePasscodeOpenProvider);
    final riding = ref.read(ridingSettingsProvider.notifier);
    final updateAvailable = ref.watch(otaProvider.select((o) => o.bell));
    final firmwareNews = ref.watch(firmwareProvider.select((f) => f.bell));

    return ColoredBox(
      key: const ValueKey('settings-body'),
      color: DashColors.ink,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: DashSpace.overlayTop,
            bottom: 0,
            width: SettingsScreen.sidebarWidth,
            // Scrolls so the list never overflows when an alert banner
            // shortens the screen.
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: Column(
                children: [
                  for (final s in SettingsSection.values)
                    _SidebarItem(
                      key: ValueKey('section-${s.name}'),
                      label: s.label,
                      active: s == section && !changeOpen,
                      onTap: () {
                        uiTap('settings-nav', {'section': s.name});
                        ref.read(changePasscodeOpenProvider.notifier).close();
                        ref.read(settingsSectionProvider.notifier).set(s);
                      },
                    ),
                  _SidebarItem(
                    key: const ValueKey('section-diagnostics'),
                    label: 'Diagnostics',
                    icon: Icons.monitor_heart_outlined,
                    active: false,
                    onTap: () {
                      uiTap('settings-nav', {'section': 'diagnostics'});
                      ref.read(diagnosticsOpenProvider.notifier).open();
                    },
                  ),
                  _SidebarItem(
                    key: const ValueKey('section-updates'),
                    label: 'Updates',
                    icon: Icons.system_update_alt_rounded,
                    active: false,
                    badge: updateAvailable || firmwareNews,
                    onTap: () {
                      uiTap('settings-nav', {'section': 'updates'});
                      ref.read(otaScreenOpenProvider.notifier).open();
                    },
                  ),
                  _SidebarItem(
                    key: const ValueKey('section-apps'),
                    label: 'Apps',
                    glyph: (c) => AppsIcon(color: c),
                    active: false,
                    onTap: () {
                      uiTap('settings-nav', {'section': 'apps'});
                      ref.read(appLauncherOpenProvider.notifier).open();
                    },
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(DashSpace.gutter, 6, 24, 6),
                    child: Divider(color: DashColors.slate, height: 1, thickness: 1),
                  ),
                  _SidebarItem(
                    key: const ValueKey('section-passcode'),
                    label: 'Change Passcode',
                    icon: Icons.lock_outline_rounded,
                    active: changeOpen,
                    onTap: () {
                      uiTap('settings-nav', {'section': 'passcode'});
                      ref.read(changePasscodeOpenProvider.notifier).open();
                    },
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: SettingsScreen.sidebarWidth,
            top: DashSpace.overlayTop,
            bottom: 24,
            child: VerticalDivider(color: DashColors.slate, width: 1, thickness: 1),
          ),
          Positioned(
            left: SettingsScreen.sidebarWidth,
            top: DashSpace.overlayTop,
            right: 0,
            bottom: 0,
            child: ClipRect(
              child: Stack(
                children: [
                  AnimatedSwitcher(
                    duration: DashMotion.fast,
                    switchInCurve: Curves.linear,
                    switchOutCurve: Curves.linear,
                    transitionBuilder: DashMotion.fadeThrough,
                    child: SingleChildScrollView(
                      key: ValueKey(section),
                      padding: const EdgeInsets.fromLTRB(48, 16, 72, 48),
                      child: switch (section) {
                        SettingsSection.display => const DisplaySection(),
                        SettingsSection.profile => const ProfileSection(),
                        SettingsSection.sound => const SoundSection(),
                        SettingsSection.riding => const RidingSection(),
                        SettingsSection.connectivity => const ConnectivitySection(),
                        SettingsSection.vehicleInfo => const VehicleInfoSection(),
                        SettingsSection.about => const AboutSection(),
                        SettingsSection.developer => const DeveloperSection(),
                      },
                    ),
                  ),
                  const ChangePasscodeScreen(),
                ],
              ),
            ),
          ),
          if (prompt)
            Positioned.fill(
              child: ConfirmCard(
                title: 'Hill Hold Assist',
                titleColor: DashColors.warning,
                body: 'Hill hold may not prevent rollback on steep grades. Always use the brakes.',
                primaryLabel: 'I understand',
                onPrimary: riding.acknowledgeHillHold,
                secondaryLabel: 'Cancel',
                onSecondary: riding.dismissHillHoldPrompt,
              ),
            ),
          if (standPrompt)
            Positioned.fill(
              child: ConfirmCard(
                key: const ValueKey('stand-bypass-prompt'),
                title: 'Disable side stand sensor?',
                titleColor: DashColors.warning,
                body: 'Disabling the side stand sensor means the scooter will not auto-park when the stand is deployed. You must park manually. Continue?',
                primaryLabel: 'Disable',
                primaryColor: DashColors.warning,
                onPrimary: riding.confirmStandBypass,
                secondaryLabel: 'Cancel',
                onSecondary: riding.dismissStandBypassPrompt,
              ),
            ),
          if (ref.watch(recoveryPanelProvider))
            Positioned.fill(
              child: ConfirmCard(
                key: const ValueKey('recovery-restart-stock-confirm'),
                width: 520,
                title: 'Restart stock dashboard?',
                body: 'Stops the original Ola dashboard, starts it again and leaves it in front.\n\n'
                    'To return to OpenDash: tap "← OpenDash" at the top of the screen. '
                    'If it is not there, open stock Settings → Reboot Scooter.',
                primaryLabel: 'Restart stock',
                onPrimary: ref.read(recoveryPanelProvider.notifier).confirmRestartStock,
                secondaryLabel: 'Cancel',
                onSecondary: ref.read(recoveryPanelProvider.notifier).cancelRestartStock,
              ),
            ),
          if (vacationPrompt)
            Positioned.fill(
              child: ConfirmCard(
                key: const ValueKey('vacation-prompt'),
                title: 'Enter vacation mode?',
                titleColor: DashColors.warning,
                body: 'The scooter powers down for long-term storage to save the battery. Hazard lights are switched off.',
                primaryLabel: 'Enter vacation mode',
                primaryColor: DashColors.warning,
                onPrimary: riding.confirmVacation,
                secondaryLabel: 'Cancel',
                onSecondary: riding.dismissVacationPrompt,
              ),
            ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    this.icon,
    this.glyph,
    this.badge = false,
  });
  final String label;
  final bool active;
  final VoidCallback onTap;
  final IconData? icon;

  /// Drawn alternative to [icon], given the current label colour.
  final Widget Function(Color color)? glyph;
  final bool badge;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: SizedBox(
        height: DashTouch.min,
        child: Row(
          children: [
            AnimatedContainer(
              duration: DashMotion.fast,
              width: 4,
              height: active ? 36 : 0,
              margin: const EdgeInsets.only(left: 56),
              decoration: BoxDecoration(color: DashColors.bone, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 20),
            if (glyph != null) ...[
              SizedBox(width: 22, child: Center(child: glyph!(active ? DashColors.bone : DashColors.ash))),
              const SizedBox(width: 10),
            ] else if (icon != null) ...[
              Icon(icon, size: 22, color: active ? DashColors.bone : DashColors.ash),
              const SizedBox(width: 10),
            ],
            Flexible(
              child: AnimatedDefaultTextStyle(
                duration: DashMotion.fast,
                style: DashText.value(20, color: active ? DashColors.bone : DashColors.ash),
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
            if (badge) ...[
              const SizedBox(width: 10),
              Container(
                key: const ValueKey('updates-badge'),
                width: 6,
                height: 6,
                decoration: BoxDecoration(shape: BoxShape.circle, color: DashColors.eco),
              ),
            ],
            const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }
}
