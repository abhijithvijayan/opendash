import 'dart:async';
import 'widgets/overlays/qr_card_dialog.dart';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'constants.dart';
import 'dev/dev_panel.dart';
import 'screens/bluetooth/bt_devices_screen.dart';
import 'screens/boot/boot_screen.dart';
import 'screens/diagnostics/diagnostics_screen.dart';
import 'screens/charging/charging_screen.dart';
import 'screens/dashboard/dashboard_screen.dart';
import 'screens/apps/app_launcher_screen.dart';
import 'screens/apps/app_placeholder_screen.dart';
import 'screens/locked/locked_screen.dart';
import 'screens/ota/ota_screen.dart';
import 'screens/safe_mode/safe_mode_screen.dart';
import 'screens/safety/safety_overlay.dart';
import 'screens/service/service_mode_screen.dart';
import 'screens/settings/licenses_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/sleep/sleep_screen.dart';
import 'state/riding_lockout.dart';
import 'services/frame_stats.dart';
import 'services/analytics_health.dart';
import 'services/analytics_heartbeat.dart';
import 'services/analytics_logger.dart';
import 'services/recovery_service.dart';
import 'services/analytics_transitions.dart';
import 'services/platform_provider.dart';
import 'services/prefs_service.dart';
import 'services/ride_tracker.dart';
import 'services/trusted_clock.dart';
import 'providers/battery_diagnostics_provider.dart';
import 'providers/mock_provider.dart';
import 'providers/vehicle_provider.dart';
import 'dev/island_preview.dart';
import 'state/bus_log_state.dart';
import 'state/dash_island.dart';
import 'state/usage_ping.dart';
import 'state/alert_state.dart';
import 'state/access_state.dart';
import 'state/apps_state.dart';
import 'state/crash_recovery.dart';
import 'state/energy_used_state.dart';
import 'state/error_state.dart';
import 'state/fault_history_state.dart';
import 'state/greeting_state.dart';
import 'state/media_state.dart';
import 'state/overlay_state.dart';
import 'state/theme_state.dart';
import 'state/safety_watchdog.dart';
import 'state/screen_state.dart';
import 'widgets/controls/control_panel.dart';
import 'theme/colors.dart';
import 'theme/typography.dart';
import 'widgets/overlays/unchecked_scooter_dialog.dart';
import 'widgets/overlays/alert_overlay.dart';
import 'widgets/overlays/auto_park_modal.dart';
import 'widgets/overlays/bt_pairing_overlay.dart';
import 'widgets/overlays/call_overlay.dart';
import 'widgets/overlays/connection_badge.dart';
import 'widgets/overlays/error_overlay.dart';
import 'widgets/overlays/idle_lock_warning.dart';
import 'widgets/overlays/firmware_overlays.dart';
import 'state/firmware_state.dart';
import 'state/ota_state.dart';
import 'services/build_info.dart';
import 'widgets/overlays/greeting_overlay.dart';
import 'widgets/overlays/access_prompt_overlay.dart';
import 'widgets/overlays/passcode_gate_overlay.dart';
import 'widgets/overlays/restart_confirm_overlay.dart';
import 'widgets/overlays/soh_dialog.dart';
import 'widgets/overlays/toast_overlay.dart';
import 'widgets/overlays/wifi_details_dialog.dart';
import 'widgets/overlays/trip_reset_dialog.dart';
import 'widgets/overlays/volume_overlay.dart';
import 'widgets/status_bar/overlay_toolbar.dart';
import 'widgets/status_bar/status_bar.dart';
import 'theme/tokens.dart';
import 'state/auto_brightness.dart';
import 'state/bt_settings.dart';
import 'widgets/overlays/phone_pairing_overlay.dart';

const designSize = Size(1280, 768);

AnalyticsHeartbeat? _heartbeat;
RideTracker? _rides;

/// The container [_start] most recently built (a crash retry builds a new
/// one), for the process-wide lifecycle listener.
ProviderContainer? _currentContainer;

/// True whenever OpenDash is the foreground activity. Flipped by the
/// `AppLifecycleListener` below. Boot-time force-stop checks this so it
/// doesn't kill stock HHMIC the user just intentionally launched.
bool _foreground = true;

AidlVehicleNotifier? _aidlVehicle() {
  final vehicle = _currentContainer?.read(vehicleProvider.notifier);
  return vehicle is AidlVehicleNotifier ? vehicle : null;
}

bool _fellBack = false;

/// More starts of a newly installed build than `UpdateRecord.MAX_STARTS`
/// with none reaching a stable dashboard.
Future<bool> _updateFellBack() async {
  try {
    final record = defaultPlatformService().updateRecord();
    final to = record['to'], starts = record['starts'];
    return to is int && to != 0 && to == record['installed'] && starts is int && starts > 3;
  } catch (_) {
    return false;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  bootMark('main_entered');
  // HHMIS has one callback slot. Once, right after an install,
  // stock HHMIC was still alive, took the slot a second after our bind and
  // got the passcode answer and the unlock, so the lock screen never heard.
  // The Kotlin bind lands ~2.5 s after this, so kill HHMIC first; the 20 s
  // timer in _start stays for an HHMIC that autostarts later at cold boot.
  // Only intervene with stock if OpenDash still
  // holds the HOME role. A rider who switched launchers shouldn't have
  // their choice fought.
  // For a trial of an update that does not start
  // (`OPENDASH_CRASH=dart scripts/deploy.sh`); never in a release.
  if (const String.fromEnvironment('OPENDASH_CRASH') == 'dart') {
    // The process ends, as a build whose Dart side cannot run would.
    exit(1);
  }
  if (useAidlVehicle) {
    unawaited(() async {
      // An update that has started too often without reaching a stable
      // dashboard: MainActivity has opened the stock dashboard as the way
      // out, and it is left alone.
      if (await _updateFellBack()) {
        _fellBack = true;
        logEvent('recovery', 'boot_force_stop', {'success': false, 'skipped': 'update_fallback'});
      } else if (defaultPlatformService().isDefaultHome()) {
        await recoveryService.forceStopStockDashboard();
      } else {
        logEvent('recovery', 'boot_force_stop', {'success': false, 'skipped': 'not_home'});
      }
    }());
  }
  await PrefsService.init();
  TrustedClock.init();
  await _startAnalytics();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  AppErrorNotifier.onRestart = _start;
  _start();
}

/// Opens the JSONL log in the app's external files dir and writes the
/// session header.
/// Nothing here may stop the dashboard from starting.
Future<void> _startAnalytics() async {
  final logger = AnalyticsLogger.instance;
  Directory? dir;
  var device = const <String, String>{};
  try {
    final platform = defaultPlatformService();
    final path = platform.externalFilesDir();
    if (path != null) dir = Directory(path);
    device = platform.deviceInfo();
    BuildInfo.number = int.tryParse(device['version_code'] ?? '');
    final firmwareBuild = int.tryParse(device['build_time_ms'] ?? '');
    final uptime = int.tryParse(device['elapsed_realtime_ms'] ?? '');
    if (firmwareBuild != null && firmwareBuild > 0 && uptime != null) {
      TrustedClock.configure(firmwareBuildMs: firmwareBuild, elapsedRealtimeMs: uptime);
    }
  } catch (e) {
    debugPrint('[analytics] platform lookup failed: $e');
  }
  await logger.init(enabled: PrefsService.getBool(PrefsKeys.analyticsEnabled, true), directory: dir);
  if (dir == null) debugPrint('[analytics] no external dir; events stay in memory');
  installAnalyticsBridge();
  logger.log('app', 'start', {
    'version': appVersion,
    'git_sha': BuildInfo.gitSha,
    'build': BuildInfo.number,
    'build_mode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
    'device_model': device['model'],
    'android_release': device['release'],
    'log_path': logger.currentFilePath,
    'mock_vehicle': !useAidlVehicle,
  });
  // Which head unit and which stock software: what every other line of a
  // log from someone else's scooter has to be read against.
  logger.log('survey', 'device', {
    for (final key in const ['manufacturer', 'model', 'board', 'hardware', 'abis', 'release', 'sdk', 'security_patch', 'build_id'])
      key: device[key],
    'firmware_built_ms': int.tryParse(device['build_time_ms'] ?? ''),
    'ram_mb': int.tryParse(device['ram_mb'] ?? ''),
    // The scooter's own density (installs before 0.3.5 forced 160); OpenDash
    // scales its 1280x768 canvas to the screen at any density.
    'screen_px': device['screen_px'],
    'density': int.tryParse(device['density'] ?? ''),
    'density_default': int.tryParse(device['density_default'] ?? ''),
    'stock_packages': (device['stock_packages'] ?? '').split(';').where((p) => p.isNotEmpty).toList(),
    'props': (device['system_props'] ?? '').split('\n').where((p) => p.isNotEmpty).toList(),
    'sensors': (device['sensors'] ?? '').split('\n').where((p) => p.isNotEmpty).toList(),
  }, const {'stock_packages', 'props', 'sensors'});
  // Kept alive for the whole process; there is no detach-and-rebuild.
  AppLifecycleListener(
    onStateChange: (state) => logger.log('app', 'lifecycle', {'state': state.name}),
    // The HHMIS slot watchdog runs only while we are in front; paused, the
    // stock dashboard may own the slot.
    onResume: () {
      _foreground = true;
      _aidlVehicle()?.onLifecycleResume();
      if (useAidlVehicle) _currentContainer?.read(batteryDiagnosticsProvider.notifier).onLifecycleResume();
      // Back from the system installer or the "Install unknown apps" screen.
      _currentContainer?.read(appManagerProvider.notifier).onResume();
    },
    onPause: () {
      _foreground = false;
      _aidlVehicle()?.onLifecyclePause();
      if (useAidlVehicle) _currentContainer?.read(batteryDiagnosticsProvider.notifier).onLifecyclePause();
    },
    onDetach: () {
      _heartbeat?.stop();
      _rides?.stop();
      logger.log('app', 'detach');
      logger.dispose();
    },
  );
  AnalyticsHealthSampler().start();
}

/// A fresh container every time, so a retry after a crash starts clean.
void _start() {
  ErrorWidget.builder = (_) => ColoredBox(color: DashColors.ink);
  final container = ProviderContainer();
  _currentContainer = container;
  installErrorHandlers(container);
  installAnalyticsTransitions(container);
  FrameStats(riding: () => container.read(ridingLockoutProvider)).start();
  // Kept alive from the start: it listens for an app going in front.
  container.read(dashIslandProvider);
  container.read(accessProvider);
  // The bus log is on by default; it keeps running unless turned off.
  if (useAidlVehicle) container.read(busLogProvider);
  _heartbeat?.stop();
  _heartbeat = AnalyticsHeartbeat(container)..start();
  _rides?.stop();
  _rides = RideTracker(container)..start();
  runApp(UncontrolledProviderScope(container: container, child: const OpenDashApp()));
  bootMark('runApp_called');
  WidgetsBinding.instance.addPostFrameCallback((_) {
    bootMark('first_frame');
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return;
    final dpr = view.devicePixelRatio;
    logEvent('ui', 'canvas_insets', {
      'physical_w': view.physicalSize.width.round(),
      'physical_h': view.physicalSize.height.round(),
      'dpr': dpr,
      'logical_w': (view.physicalSize.width / dpr).round(),
      'logical_h': (view.physicalSize.height / dpr).round(),
      'design_w': designSize.width.round(),
      'design_h': designSize.height.round(),
    });
  });
  // Stock HHMIC may have autostarted alongside us at cold boot. Kill it
  // after a grace window to free its ~635 MB RAM. Verified safe on the
  // scooter: HHMIC is not in HOHS's PROCESS_LIST so this never triggers the
  // SOM watchdog reboot.
  //
  // If the rider intentionally launched stock inside this 20 s grace window
  // (observed: a `launch_stock_dashboard` at +16 s followed
  // by this timer killing it at +20 s), we're backgrounded by then — skip
  // the kill so the user's choice wins.
  Timer(const Duration(seconds: 20), () async {
    if (_fellBack) return;
    if (!_foreground) {
      logEvent('recovery', 'boot_force_stop', {'success': false, 'skipped': 'backgrounded'});
      return;
    }
    // Also skip if OpenDash no longer owns HOME.
    if (!defaultPlatformService().isDefaultHome()) {
      logEvent('recovery', 'boot_force_stop', {'success': false, 'skipped': 'not_home'});
      return;
    }
    final ok = await recoveryService.forceStopStockDashboard();
    logEvent('recovery', 'boot_force_stop', {'success': ok});
  });
}

class OpenDashApp extends StatelessWidget {
  const OpenDashApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: DashColors.ink,
        fontFamily: DashText.family,
        colorScheme: ColorScheme.dark(
          primary: DashColors.bone,
          surface: DashColors.ink,
        ),
        useMaterial3: true,
      ),
      home: const DesignCanvas(),
    );
  }
}

/// The head unit is 1280x768 physical pixels at ~1.5 dpr, so Flutter's
/// logical size is not 1280x768. Everything is laid out on the design
/// canvas and scaled to whatever the window gives us.
int _lastBlockedTouchMicros = -1;

void _logBlockedTouch() {
  final now = AnalyticsLogger.instance.monoMicros;
  if (_lastBlockedTouchMicros >= 0 && now - _lastBlockedTouchMicros < 1000000) return;
  _lastBlockedTouchMicros = now;
  logEvent('ui', 'touch_blocked', {'reason': 'head_unit_power'});
}

class DesignCanvas extends ConsumerWidget {
  const DesignCanvas({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The VCU cuts the head-unit's 12 V rail some seconds after it flips
    // BOOL_HEAD_UNIT_POWER_FLAG to false. Stock HHMIC gates touches with
    // `IKanziView.setTouchDisabled(true)` in that grace window; we do the
    // same so a trailing tap doesn't fire a stale action.
    final touchDisabled = ref.watch(vehicleProvider.select((v) => v.touchDisabled));
    return ColoredBox(
      color: ref.watch(uiThemeProvider).ink,
      child: Center(
        child: FittedBox(
          child: SizedBox.fromSize(
            size: designSize,
            child: Listener(
              // Records touches the power-flag gate swallows, so a "the
              // keypad didn't respond" report can be told apart from taps
              // that never reached the app.
              onPointerDown: touchDisabled ? (_) => _logBlockedTouch() : null,
              child: IgnorePointer(
              ignoring: touchDisabled,
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) => ref.read(vehicleProvider.notifier).markTouched(),
                // A drag or hold is still a touch a second later (stock
                // counts every motion event).
                onPointerMove: (_) => ref.read(vehicleProvider.notifier).markTouched(),
                child: const Material(
                  type: MaterialType.transparency,
                  child: ClipRect(child: _Root()),
                ),
              ),
            ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full status bar on the dashboard; while an overlay is up it slides
/// away and the slim toolbar slides in. A pull-down peek brings the full
/// bar back over the toolbar for a moment.
class _Chrome extends ConsumerStatefulWidget {
  const _Chrome();

  @override
  ConsumerState<_Chrome> createState() => _ChromeState();
}

class _ChromeState extends ConsumerState<_Chrome> {
  /// Stays mounted through the slide-out so the strip leaves the way it came.
  bool _toolbarMounted = false;

  @override
  Widget build(BuildContext context) {
    final overlay = ref.watch(overlayToolbarVisibleProvider);
    final peek = ref.watch(statusBarPeekProvider);
    final collapsed = overlay && !peek;
    if (overlay) _toolbarMounted = true;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (peek)
          Positioned(
            left: 0,
            right: 0,
            top: StatusBar.height,
            bottom: 0,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => ref.read(statusBarPeekProvider.notifier).hide(),
            ),
          ),
        AnimatedPositioned(
          duration: DashMotion.fast,
          curve: Curves.easeOut,
          left: 0,
          right: 0,
          top: overlay ? 0 : -OverlayToolbar.backHit,
          height: OverlayToolbar.backHit,
          onEnd: () {
            if (!ref.read(overlayToolbarVisibleProvider) && mounted) setState(() => _toolbarMounted = false);
          },
          child: _toolbarMounted ? const RepaintBoundary(child: OverlayToolbar()) : const SizedBox.shrink(),
        ),
        AnimatedPositioned(
          duration: DashMotion.fast,
          curve: Curves.easeOut,
          left: 0,
          right: 0,
          top: collapsed ? -StatusBar.height : 0,
          height: StatusBar.height,
          // Opaque so a peek covers the toolbar instead of blending with it.
          // A tap on the peeking bar keeps it for another three seconds.
          child: GestureDetector(
            behavior: peek ? HitTestBehavior.opaque : HitTestBehavior.deferToChild,
            onTap: peek ? ref.read(statusBarPeekProvider.notifier).peek : null,
            child: RepaintBoundary(child: ColoredBox(color: ref.watch(uiThemeProvider).ink, child: const StatusBar())),
          ),
        ),
      ],
    );
  }
}

/// The dev panel drives the mock's setters; over live HHMIS data it would
/// fake a speed or clear the lock screen.
/// `OPENDASH_NO_DEV_PANEL` leaves it out of a build made to be filmed.
bool devPanelAllowed(VehicleNotifier vehicle) =>
    kDebugMode && !const bool.fromEnvironment('OPENDASH_NO_DEV_PANEL') && vehicle is! AidlVehicleNotifier;

class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(safetyWatchdogProvider);
    ref.watch(btWatcherProvider);
    // Alive from the root: a pairing request and the vehicle's calls setting
    // arrive whether or not the Bluetooth screen has ever been opened.
    ref.listen(btSettingsProvider, (_, _) {});
    ref.watch(autoThemeProvider);
    ref.watch(autoBrightnessProvider);
    ref.watch(greetingProvider);
    ref.listen(faultHistoryProvider, (_, _) {});
    // Firmware control runs from start-up: the mode is logged, the stock
    // auto-download setting is switched off, the block is read.
    ref.listen(firmwareProvider, (_, _) {});
    ref.listen(usagePingProvider, (_, _) {});
    // Its own update check, and what the companion phone app sends, run from
    // start-up, not from the first screen that shows the bell.
    ref.listen(otaProvider, (_, _) {});
    // A widget subscription keeps the alert list recomputing as the vehicle
    // changes. Without it the provider rebuilds lazily inside the next
    // build, and the cycle notifier's listener would then set state
    // mid-build, which Riverpod rejects.
    ref.listen(visibleAlertsProvider, (_, _) {});
    // gRPC used to start only when a battery widget first mounted, about
    // 13 s into a session; the CAN-only signals belong on the
    // dash from boot. Listen, not watch: it publishes every 500 ms.
    if (useAidlVehicle) ref.listen(batteryDiagnosticsProvider, (_, _) {});
    // "kWh used" is integrated while riding, whether or not its page is up.
    if (useAidlVehicle) ref.listen(energyUsedProvider, (_, _) {});
    final devPanel = devPanelAllowed(ref.read(vehicleProvider.notifier));
    if (ref.watch(crashRecoveryProvider.select((c) => c.safeMode))) {
      // Same order as the main stack below; safe mode has no alert banner.
      return Stack(
        fit: StackFit.expand,
        children: [
          const SafeModeScreen(),
          const ErrorOverlay(),
          // Installing an update from safe mode asks for these, as on the
          // Updates screen.
          const AccessPromptOverlay(),
          const PasscodeGateOverlay(),
          // Opened from the error and start-up screens, so above them; under
          // the firmware-install notice and every safety overlay.
          const QrCardDialog(),
          const FirmwareInstallOverlay(),
          const AutoParkModal(),
          const SafetyOverlay(),
          const ToastOverlay(),
          if (devPanel) const DevPanel(),
        ],
      );
    }
    final screen = ref.watch(screenStateProvider);
    // Remount once per theme switch so widgets that cache DashColors
    // tokens repaint with the new palette.
    final themeName = ref.watch(shownThemeProvider.select((t) => t.name));
    final showChrome = switch (screen) {
      ScreenState.booting || ScreenState.sleep => false,
      _ => true,
    };
    // Boot has no data, lock draws its own clock and battery, sleep is
    // black: none of them get the status bar or the toolbar.
    final showStatusBar = switch (screen) {
      ScreenState.parked || ScreenState.ready || ScreenState.riding || ScreenState.charging => true,
      _ => false,
    };

    return KeyedSubtree(
      key: ValueKey('theme-$themeName'),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedSwitcher(
            duration: DashMotion.normal,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(
                scale: Tween(begin: 0.97, end: 1.0).animate(anim),
                child: child,
              ),
            ),
            child: switch (screen) {
              ScreenState.booting => const BootScreen(key: ValueKey('boot')),
              ScreenState.sleep => const SleepScreen(key: ValueKey('sleep')),
              ScreenState.locked => const LockedScreen(key: ValueKey('locked')),
              ScreenState.charging => const ChargingScreen(
                key: ValueKey('charging'),
              ),
              ScreenState.parked || ScreenState.ready || ScreenState.riding =>
                const DashboardScreen(key: ValueKey('dashboard')),
            },
          ),
          if (screen == ScreenState.charging)
            const RepaintBoundary(child: ControlPanel(charging: true)),
          if (screen == ScreenState.parked ||
              screen == ScreenState.ready ||
              screen == ScreenState.riding)
            const RepaintBoundary(child: ControlPanel(charging: false)),
          if (showChrome) ...[
            const SettingsScreen(),
            const LicensesScreen(),
            const OtaScreen(),
            const AppLauncherScreen(),
            const DiagnosticsScreen(),
            const BtDevicesScreen(),
            if (showStatusBar) const _Chrome(),
            const AppPlaceholderScreen(),
            const ActiveCallBar(),
            const ConnectionBadge(),
            const GreetingOverlay(),
            const VolumeOverlay(),
            const TripResetDialog(),
            const SohDialog(),
            const WifiDetailsDialog(),
            const FirmwareChangeDialog(),
            const UncheckedScooterDialog(),
            const BtPairingOverlay(),
          ],
          // Stack order from here up, lowest first. test/overlay_order_test.dart
          // pins it.
          //   1. Service mode: an opaque technician screen; it covers the
          //      screens and dialogs above, never a prompt or a warning.
          //   2. Passcode gate, then the restart confirm it leads to, then a
          //      phone's pairing request: above every screen the rider can
          //      open (it shows whether or not the Bluetooth screen is up),
          //      optional like the rest, so the error screen covers it.
          //      Never drawn while riding.
          //      Then the idle-lock warning: a strip over whatever screen is
          //      open, under the error screen; it takes no touches.
          //   3. Error screen: opaque, covers every optional modal. Then the
          //      firmware-install notice ("Scooter firmware is installing. Do
          //      not ride."): opaque, over everything below it, the error
          //      screen included, and under every safety overlay.
          //   4. Safety: the auto-park countdown and the alert banner (side
          //      stand, faults, low battery). Nothing opaque may cover these,
          //      the error screen included. The banner is the higher of the
          //      two so the auto-park scrim does not dim it; the two never
          //      overlap (banner at the top, card in the centre).
          //   5. Incoming call: a 200 px strip over the banner's slot for as
          //      long as the phone rings. It was above every alert before
          //      this order was written down and its buttons sit where the
          //      banner would be, so it keeps that place.
          //   6. Emergency screens: accident ("Are you safe?"), fall, and
          //      the tamper alarm. Opaque and full-screen, above everything
          //      a rider can open or be shown, the passcode gate, the restart
          //      confirm, the error screen and a ringing call included: each
          //      is the one thing to deal with while it is up. Mounted on the
          //      sleep screen too (raising one wakes it). One at a time:
          //      accident, then fall, then alarm (safetyScreenProvider).
          //   7. Toast, so a recovery tap on the error screen (open trunk)
          //      still answers, and "Alert deactivated" is seen.
          //   8. Dev panel, mock provider only.
          const ServiceModeScreen(),
          if (showChrome) ...[
            const AccessPromptOverlay(),
            const PasscodeGateOverlay(),
            const RestartConfirmOverlay(),
            const PhonePairingOverlay(),
          ],
          if (showChrome) const IdleLockWarning(),
          const ErrorOverlay(),
          // Opened from the error and start-up screens, so above them; under
          // the firmware-install notice and every safety overlay.
          const QrCardDialog(),
          const FirmwareInstallOverlay(),
          if (showChrome) ...[
            const AutoParkModal(),
            const AlertOverlay(),
            const IncomingCallOverlay(),
          ],
          const SafetyOverlay(),
          const ToastOverlay(),
          if (devPanel) const IslandPreview(),
          if (devPanel) const DevPanel(),
        ],
      ),
    );
  }
}
