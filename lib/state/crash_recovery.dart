import '../services/recovery_service.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import '../providers/mock_provider.dart';
import '../services/platform_provider.dart';
import '../services/analytics_logger.dart';
import '../services/platform_service.dart';
import '../services/prefs_service.dart';
import 'apps_state.dart';
import 'control_panel.dart';
import 'media_state.dart';
import 'ota_state.dart';
import 'passcode_gate.dart';
import 'riding_lockout.dart';
import 'settings_state.dart';
import 'toast_state.dart';
import 'wifi_state.dart';

class CrashRecoveryState {
  const CrashRecoveryState({this.consecutiveCrashes = 0, this.safeMode = false, this.lastCrash});
  final int consecutiveCrashes;
  final bool safeMode;
  final DateTime? lastCrash;

  CrashRecoveryState copyWith({int? consecutiveCrashes, bool? safeMode, DateTime? Function()? lastCrash}) =>
      CrashRecoveryState(
        consecutiveCrashes: consecutiveCrashes ?? this.consecutiveCrashes,
        safeMode: safeMode ?? this.safeMode,
        lastCrash: lastCrash != null ? lastCrash() : this.lastCrash,
      );
}

final crashRecoveryProvider =
    NotifierProvider<CrashRecoveryNotifier, CrashRecoveryState>(CrashRecoveryNotifier.new);

/// Safe mode after [maxCrashes] unhandled errors with no stable boot in
/// between. The count is persisted, so it survives the fresh container a
/// Retry builds and a restart of the process; a boot that stays connected
/// for [stableAfter] clears it. Only errors that reach the Dart handlers
/// (error_state.dart) are counted: a native crash or a kill is not.
class CrashRecoveryNotifier extends Notifier<CrashRecoveryState> {
  static const maxCrashes = 3;
  static const stableAfter = Duration(seconds: 10);
  static const stockPackage = stockDashboardPackage;
  Timer? _stable;

  @override
  CrashRecoveryState build() {
    ref.onDispose(() => _stable?.cancel());
    ref.listen(vehicleProvider.select((v) => v.hhmisConnected), (_, connected) {
      _stable?.cancel();
      if (connected) _stable = Timer(stableAfter, markStableBoot);
    });
    final n = PrefsService.getInt(PrefsKeys.crashCount, 0);
    if (n > 0) logEvent('recovery', 'crash_count_restored', {'crashes': n, 'safe_mode': n >= maxCrashes});
    return CrashRecoveryState(consecutiveCrashes: n, safeMode: n >= maxCrashes);
  }

  void recordCrash() {
    final n = state.consecutiveCrashes + 1;
    PrefsService.setInt(PrefsKeys.crashCount, n);
    state = state.copyWith(
      consecutiveCrashes: n,
      lastCrash: () => DateTime.now(),
      safeMode: n >= maxCrashes,
    );
  }

  void markStableBoot() {
    _stable = null;
    if (state.consecutiveCrashes == 0) return;
    PrefsService.remove(PrefsKeys.crashCount);
    state = state.copyWith(consecutiveCrashes: 0);
  }

  void enterSafeMode() => state = state.copyWith(safeMode: true);

  /// "Retry": leave safe mode and let the normal boot run. Safe mode may
  /// have been entered from any screen, so every overlay is closed first.
  void retry() {
    resetOverlays();
    PrefsService.remove(PrefsKeys.crashCount);
    state = state.copyWith(safeMode: false, consecutiveCrashes: 0);
  }

  void resetOverlays() {
    ref.read(settingsScreenOpenProvider.notifier).close();
    ref.read(licensesScreenOpenProvider.notifier).close();
    ref.read(sohPopupOpenProvider.notifier).close();
    ref.read(chargeLimitPopupProvider.notifier).close();
    ref.read(tripResetProvider.notifier).cancel();
    ref.read(appLauncherOpenProvider.notifier).close();
    ref.read(mockAppProvider.notifier).close();
    ref.read(btScreenOpenProvider.notifier).close();
    ref.read(volumeOverlayProvider.notifier).dismiss();
    ref.read(otaScreenOpenProvider.notifier).close();
    ref.read(wifiDetailsOpenProvider.notifier).close();
    ref.read(passcodeGateProvider.notifier).cancel();
    ref.read(controlPanelOpenProvider.notifier).close();
    ref.read(diagnosticsOpenProvider.notifier).close();
    ref.read(serviceModeOpenProvider.notifier).close();
  }

  /// The stock dashboard opens through the apps-grid
  /// shell so the rider gets the return pill and OpenDash tracks the
  /// outside app. The install-check happens first (so a missing stock
  /// toasts "Stock dashboard not installed"); only a successful launch
  /// enters the apps-grid shell.
  Future<void> launchStockApp() async {
    final ok = await launchPackage(ref, stockPackage, missing: 'Stock dashboard not installed');
    if (ok) {
      RecoveryService.stockLaunches++;
      await ref.read(appManagerProvider.notifier).trackOutsideStock();
    }
  }

  /// Hands the choice to Android's home chooser rather than switching
  /// launchers silently; coming back to OpenDash is scripts/deploy.sh.
  Future<void> setStockAsDefaultHome() async {
    final ok = await _platformCall('openHomeSettings', () => ref.read(platformServiceProvider).openHomeSettings());
    if (!ok) ref.read(toastProvider.notifier).show('Home settings not available', type: ToastType.warning);
  }

}

Future<bool> launchPackage(Ref ref, String package, {required String missing}) async {
  final ok = await _platformCall('launchApp', () => ref.read(platformServiceProvider).launchApp(package), args: package);
  if (!ok) ref.read(toastProvider.notifier).show(missing, type: ToastType.warning);
  return ok;
}

/// A channel without a handler (web, tests) is the same as a refusal.
Future<bool> _platformCall(String method, Future<bool> Function() call, {Object? args}) async {
  try {
    return await tracedPlatformCall(method, call, args: args);
  } catch (e) {
    debugPrint('[platform] $e');
    return false;
  }
}

final serviceModeOpenProvider = NotifierProvider<ServiceModeOpen, bool>(ServiceModeOpen.new);

/// Technician overlay. Closes the moment the scooter moves, or its speed
/// can no longer be trusted.
class ServiceModeOpen extends Notifier<bool> {
  static const apps = [
    ('HMFG App', 'com.ola.mfgapp'),
    ('UDS Test', 'com.olaelectric.udstestapp'),
  ];

  @override
  bool build() {
    onRidingLockout(ref, () => state = false);
    return false;
  }

  void open() {
    if (ref.read(ridingLockoutProvider)) return;
    state = true;
  }

  void close() => state = false;

  /// Launch the service-mode app, then register
  /// _outside with the apps manager so the return pill lets the
  /// technician back out. The install-check / toast stay in
  /// launchPackage.
  Future<void> launch(String package) async {
    final label = apps.firstWhere(
      (p) => p.$2 == package,
      orElse: () => (package, package),
    ).$1;
    final ok = await launchPackage(ref, package, missing: 'Could not launch $package');
    if (ok) {
      await ref.read(appManagerProvider.notifier)
          .trackOutsidePackage('service-$package', label, package);
    }
  }
}

final diagnosticsOpenProvider = NotifierProvider<DiagnosticsOpen, bool>(DiagnosticsOpen.new);

/// The one overlay that rides. You open it stopped — it refuses to open while
/// moving — and it then stays up through the ride, so you can diagnose on the
/// move and switch its inner tabs. It used to cover the speedometer with
/// nothing in its place (the dial was once hidden for 10 s at 22 km/h);
/// now the dash island floats the speed and mode over it while riding
/// (`dash_island.dart`). Settings stays mounted underneath, so the
/// back arrow returns where the rider came from; it still closes on lock and
/// on a session change, just not on starting to move.
class DiagnosticsOpen extends Notifier<bool> {
  @override
  bool build() {
    autoCloseOverlay(ref, close, onRiding: false);
    return false;
  }

  void open() {
    if (ref.read(ridingLockoutProvider) || ref.read(vehicleProvider).locked) return;
    closeAllOverlays(ref, self: diagnosticsOpenProvider, keepSettings: true);
    state = true;
  }

  void close() => state = false;
}

/// True during a "ride with Diagnostics open" session. Latched when the
/// scooter first moves with the tab open, held across brief stops, and
/// released when the tab closes or the scooter has been settled stopped for
/// [hold]. While it is true the dash island shows the speedo over the tab
/// (`dash_island.dart`) and the overlay toolbar stays hidden, so neither
/// flickers on stop-and-go.
final diagnosticsRidingProvider = NotifierProvider<DiagnosticsRiding, bool>(DiagnosticsRiding.new);

class DiagnosticsRiding extends Notifier<bool> {
  static const hold = Duration(seconds: 4);
  Timer? _release;

  @override
  bool build() {
    ref.onDispose(() => _release?.cancel());
    ref.listen(diagnosticsOpenProvider, (_, open) {
      if (!open) {
        _release?.cancel();
        _release = null;
        if (state) state = false;
      }
    });
    ref.listen(ridingLockoutProvider, (_, lockout) => _update(lockout));
    return false;
  }

  void _update(bool lockout) {
    if (!ref.read(diagnosticsOpenProvider)) return;
    if (lockout) {
      _release?.cancel();
      _release = null;
      if (!state) state = true;
    } else if (state) {
      // Settled, not just a stop-and-go pause: release after the hold.
      _release ??= Timer(hold, () {
        _release = null;
        if (!ref.read(ridingLockoutProvider) && ref.read(diagnosticsOpenProvider)) state = false;
      });
    }
  }
}
