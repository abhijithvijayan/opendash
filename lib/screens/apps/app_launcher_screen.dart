import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/app_catalog.dart';
import '../../providers/mock_provider.dart';
import '../../state/access_state.dart';
import '../../state/apps_state.dart';
import '../../state/ota_shield_state.dart';
import '../../state/theme_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/overlays/alert_overlay.dart';
import '../../widgets/overlays/call_overlay.dart';
import '../../theme/tokens.dart';
import '../../screens/settings/widgets.dart';
import 'app_icons.dart';
import '../../widgets/controls/apps_swipe_zone.dart';
import '../../services/analytics_logger.dart';

class AppLauncherScreen extends ConsumerWidget {
  const AppLauncherScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(appLauncherOpenProvider);
    final shift = ref.watch(alertBannerShiftProvider) + ref.watch(callBarShiftProvider);
    // Rises from the bottom, like an app drawer: the dashboard's bottom edge
    // is where the swipe that opens it starts (`AppsSwipeZone`).
    return AnimatedPositioned(
      duration: DashMotion.normal,
      curve: Curves.easeOutCubic,
      left: 0,
      top: open ? shift : 768,
      width: 1280,
      height: 768 - shift,
      child: open ? const _Body() : const SizedBox.shrink(),
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body();

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  CatalogApp? _confirmApp;
  bool _stockDialog = false;

  /// Notification access, which is what puts a projection app's music on
  /// the dashboard. True until the platform says otherwise, so the hint
  /// never flashes up for a rider who has allowed it.

  void _launch(CatalogApp app) {
    uiTap('app-tile', {'id': app.id});
    if (app.id == CatalogApp.stockDashboardId) {
      logModalShow('stock_dashboard_dialog', reason: 'user');
      setState(() => _stockDialog = true);
      return;
    }
    // What the app needs is asked for before it opens, so its own setup
    // (pairing a phone to CarPlay) is not interrupted for a permission.
    _withAccess(app, 'Before ${app.name} opens', {Access.overlay}, () => ref.read(appManagerProvider.notifier).launch(app));
  }

  /// Everything [app] will want, [required] included, then [go].
  void _withAccess(CatalogApp app, String title, Set<Access> required, VoidCallback go) {
    ref.read(accessProvider.notifier).ask(
      title: title,
      accesses: [
        ...required,
        if (!required.contains(Access.overlay)) Access.overlay,
        if (app.projection) Access.music,
        Access.front,
      ],
      required: required,
      scope: app.id,
      then: () {
        if (mounted) go();
      },
    );
  }

  void _closeStockDialog([String button = 'cancel']) {
    uiModalButton('stock_dashboard', button);
    logModalDismiss('stock_dashboard_dialog', reason: 'user', extra: {'button': button});
    setState(() => _stockDialog = false);
  }

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) ref.read(appManagerProvider.notifier).refresh();
    });
    Future.microtask(() {
      if (mounted) ref.read(accessProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(uiThemeProvider);
    final statuses = ref.watch(appManagerProvider);
    final wifi = ref.watch(vehicleProvider.select((v) => v.wifiConnected));

    return GestureDetector(
      // A flick down puts the drawer away; taps on the tiles are not taken.
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > AppsSwipeZone.flick) {
          uiSwipe('apps-swipe-down');
          ref.read(appLauncherOpenProvider.notifier).close();
        }
      },
      child: ColoredBox(
      key: const ValueKey('apps-body'),
      color: theme.ink,
      child: Stack(
        children: [
          // Release downloads over mobile data have resolved and connected
          // and then never answered; Wi-Fi is what has worked.
          Positioned(
            left: DashSpace.gutter,
            right: DashSpace.gutter,
            top: DashSpace.overlayTop + 4,
            child: Center(
              child: Text(
                wifi
                    ? 'Install and update apps on Wi-Fi. Downloads often fail on mobile data.'
                    : 'Not on Wi-Fi. Connect to Wi-Fi to install or update apps: downloads often fail on mobile data.',
                key: const ValueKey('apps-wifi-hint'),
                style: DashText.caption(16, color: wifi ? theme.ash : DashColors.warning),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: DashSpace.overlayTop + 48,
            child: Center(
              child: Wrap(
                spacing: 24,
                runSpacing: 24,
                children: [
                  for (final app in appCatalog)
                    _AppCard(
                      key: ValueKey('app-${app.id}'),
                      app: app,
                      status: statuses[app.id] ?? AppStatus.notInstalled,
                      // Already downloaded and checked: nothing left to
                      // ask before the installer, which asks itself.
                      onInstall: app.comingSoon
                          ? null
                          : statuses[app.id] == AppStatus.ready
                              ? () => ref.read(appManagerProvider.notifier).install(app)
                              : () {
                                  uiTap('app-install', {'id': app.id});
                                  _withAccess(app, 'Before ${app.name} is installed', {Access.install}, () {
                                    logModalShow('install_confirm', reason: app.id);
                                    setState(() => _confirmApp = app);
                                  });
                                },
                      onLaunch: app.comingSoon ? null : () => _launch(app),
                      onCancel: () {
                        uiTap('app-cancel', {'id': app.id});
                        ref.read(appManagerProvider.notifier).cancel(app);
                      },
                      onUpdate: () {
                        uiTap('app-update', {'id': app.id});
                        _withAccess(app, 'Before ${app.name} is updated', {Access.install},
                            () => ref.read(appManagerProvider.notifier).update(app));
                      },
                      newerVersion: ref.read(appManagerProvider.notifier).newerVersion(app.id),
                    ),
                ],
              ),
            ),
          ),
          // Whatever access is off, in one place, for a rider who said
          // "not now" or switched one off since.
          if (ref.watch(accessProvider.select((v) => v.missing.length)) case final off when off > 0)
            Positioned(
              left: DashSpace.gutter,
              right: DashSpace.gutter,
              bottom: DashSpace.bodyBottom,
              child: Row(
                key: const ValueKey('apps-access'),
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    off == 1 ? 'One thing OpenDash needs from Android is off' : '$off things OpenDash needs from Android are off',
                    style: DashText.caption(18, color: theme.ash),
                  ),
                  const SizedBox(width: 20),
                  GestureDetector(
                    key: const ValueKey('apps-access-review'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      uiTap('apps-access');
                      ref.read(accessProvider.notifier).review();
                    },
                    child: Container(
                      height: DashTouch.min,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(DashRadius.button),
                        border: Border.all(color: theme.slate, width: 1.5),
                      ),
                      child: Text('Review', style: DashText.value(18)),
                    ),
                  ),
                ],
              ),
            ),
          if (_confirmApp != null)
            Positioned.fill(
              child: ConfirmCard(
                width: 420,
                title: 'Install ${_confirmApp!.name}?',
                body: 'The newest ${_confirmApp!.appName.isEmpty ? _confirmApp!.name : _confirmApp!.appName} release will be '
                    "downloaded from ${_confirmApp!.source} and checked against its developer's signing key "
                    'before it is installed.\n'
                    '${wifi ? '' : 'You are not on Wi-Fi: the download may fail on mobile data.\n'}'
                    '${_confirmApp!.license} license.',
                primaryLabel: 'Install',
                onPrimary: () {
                  final app = _confirmApp!;
                  logModalDismiss('install_confirm', reason: 'user', extra: {'button': 'install', 'id': app.id});
                  setState(() => _confirmApp = null);
                  ref.read(appManagerProvider.notifier).install(app);
                },
                secondaryLabel: 'Cancel',
                onSecondary: () {
                  logModalDismiss('install_confirm', reason: 'user', extra: {'button': 'cancel', 'id': _confirmApp!.id});
                  setState(() => _confirmApp = null);
                },
              ),
            ),
          if (_stockDialog)
            Positioned.fill(
              key: const ValueKey('stock-dashboard-dialog'),
              child: ConfirmCard(
                width: 520,
                title: 'Open stock dashboard',
                body: 'Launches the original Ola dashboard.\n\n'
                    'To return to OpenDash: tap "← OpenDash" at the top of the screen. '
                    'Restarting the scooter (stock Settings → Reboot Scooter) also '
                    'brings OpenDash back, button or no button.',
                primaryLabel: 'Open stock',
                onPrimary: () {
                  _closeStockDialog('open_stock');
                  ref.read(appManagerProvider.notifier).openStock(appCatalog.firstWhere((a) => a.id == CatalogApp.stockDashboardId));
                },
                secondaryLabel: 'Cancel',
                onSecondary: _closeStockDialog,
              ),
            ),
        ],
      ),
      ),
    );
  }
}

class _AppCard extends ConsumerStatefulWidget {
  const _AppCard({
    super.key,
    required this.app,
    required this.status,
    this.onInstall,
    this.onLaunch,
    this.onUpdate,
    this.onCancel,
    this.newerVersion,
  });

  final CatalogApp app;
  final AppStatus status;
  final VoidCallback? onInstall;
  final VoidCallback? onLaunch;
  final VoidCallback? onUpdate;

  /// Takes the app out of the download queue, or stops its download.
  final VoidCallback? onCancel;

  /// The release an Update would fetch, when there is one.
  final String? newerVersion;

  @override
  ConsumerState<_AppCard> createState() => _AppCardState();
}

class _AppCardState extends ConsumerState<_AppCard> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(uiThemeProvider);
    final app = widget.app;
    final status = widget.status;
    final isBusy = status == AppStatus.queued || status == AppStatus.downloading || status == AppStatus.installing;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: app.comingSoon || isBusy ? null : (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: app.comingSoon || isBusy
          ? null
          : () {
              HapticFeedback.lightImpact();
              // The card does what its one button would: open the app (an
              // update waiting does not stop that), or offer to install it.
              // Tapping the tile of an app that was not installed used to do
              // nothing.
              if (status.present) {
                widget.onLaunch?.call();
              } else {
                widget.onInstall?.call();
              }
            },
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: DashMotion.fast,
        child: AnimatedContainer(
          duration: DashMotion.fast,
          width: 220,
          height: 260,
          decoration: BoxDecoration(
            color: theme.inkLift,
            borderRadius: BorderRadius.circular(DashRadius.card),
            border: Border.all(
              color: _down ? theme.bone.withValues(alpha: 0.3) : theme.slate,
              width: 1.5,
            ),
          ),
          // Icon and name from the top, the button from the bottom, so both
          // line up along a row of tiles however many lines a tile has
          // between them.
          child: Column(
            children: [
              const SizedBox(height: 30),
              AppIcon(appId: app.id, color: app.comingSoon ? theme.ash : theme.bone, size: 56),
              const SizedBox(height: 12),
              Text(
                app.name,
                style: DashText.value(18, color: app.comingSoon ? theme.ash : theme.bone),
              ),
              // The app's own name, where the tile is named for what it does.
              if (app.appName.isNotEmpty && !app.comingSoon) ...[
                const SizedBox(height: 2),
                Text(app.appName, key: ValueKey('app-name-${app.id}'), style: DashText.caption(14, color: theme.ash)),
              ],
              const SizedBox(height: 4),
              _StatusLine(
                status: status,
                comingSoon: app.comingSoon,
                unverified: app.downloadable && !app.pinned && !status.present,
                newerVersion: widget.newerVersion,
                shield: app.id == CatalogApp.otaShieldId && status == AppStatus.installed ? ref.watch(otaShieldProvider)?.running : null,
              ),
              if (app.requiresPhone != null && !app.comingSoon) ...[
                const SizedBox(height: 2),
                Text(app.requiresPhone!, style: DashText.caption(13, color: theme.ash)),
              ],
              const Spacer(),
              SizedBox(
                height: 36,
                child: app.comingSoon
                    ? null
                    : status == AppStatus.queued || status == AppStatus.downloading
                        ? _ActionButton(status: status, onCancel: widget.onCancel)
                        : isBusy
                        ? Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: theme.ash),
                            ),
                          )
                        : _ActionButton(
                            status: status, onInstall: widget.onInstall, onLaunch: widget.onLaunch, onUpdate: widget.onUpdate),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.status, required this.comingSoon, required this.unverified, this.newerVersion, this.shield});
  final AppStatus status;
  final bool comingSoon;
  final String? newerVersion;

  /// OTA Shield's block, running or not, once its daemon has been asked.
  final bool? shield;

  /// No signing key on record: `AppManagerNotifier.install` refuses it.
  final bool unverified;

  @override
  Widget build(BuildContext context) {
    if (comingSoon) return Text('Coming soon', style: DashText.caption(14, color: DashColors.ash));
    if (unverified) return Text('Unverified', style: DashText.caption(14, color: DashColors.warning));
    if (shield case final running?) {
      return Text(running ? 'Blocking updates' : 'Not blocking',
          key: const ValueKey('shield-tile-status'), style: DashText.caption(14, color: running ? DashColors.eco : DashColors.warning));
    }
    final (label, color) = switch (status) {
      AppStatus.notInstalled => ('Not installed', DashColors.ash),
      AppStatus.queued => ('Queued', DashColors.ash),
      AppStatus.ready => ('Ready to install', DashColors.eco),
      AppStatus.downloading => ('Downloading…', DashColors.ash),
      AppStatus.installing => ('Installing…', DashColors.ash),
      AppStatus.installed => ('Installed', DashColors.eco),
      AppStatus.updateAvailable => (newerVersion == null ? 'Update available' : 'Update: $newerVersion', DashColors.warning),
    };
    return Text(label, style: DashText.caption(14, color: color));
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.status, this.onInstall, this.onLaunch, this.onUpdate, this.onCancel});
  final VoidCallback? onCancel;
  final AppStatus status;
  final VoidCallback? onInstall;
  final VoidCallback? onLaunch;
  final VoidCallback? onUpdate;

  @override
  Widget build(BuildContext context) {
    final (label, onTap) = switch (status) {
      AppStatus.notInstalled || AppStatus.ready => ('Install', onInstall),
      AppStatus.queued || AppStatus.downloading => ('Cancel', onCancel),
      AppStatus.updateAvailable => ('Update', onUpdate),
      AppStatus.installed => ('Launch', onLaunch),
      _ => (null, null),
    };
    if (label == null) return const SizedBox.shrink();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.lightImpact();
        onTap?.call();
      },
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(
          color: DashColors.slate,
          borderRadius: BorderRadius.circular(DashRadius.button),
        ),
        child: Center(
          widthFactor: 1,
          child: Text(
            label,
            style: DashText.value(15, color: status == AppStatus.installed ? DashColors.eco : DashColors.bone),
          ),
        ),
      ),
    );
  }
}
