import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_catalog.dart';
import '../services/analytics_logger.dart';
import '../services/recovery_service.dart';
import '../providers/mock_provider.dart';
import 'apps_state.dart';
import 'prompt_surface.dart';
import 'riding_lockout.dart';
import 'toast_state.dart';

final recoveryPanelProvider = NotifierProvider<RecoveryPanel, bool>(RecoveryPanel.new);

/// Settings → Developer → Recovery: the whitelisted `RecoveryService` shell
/// actions, for a head unit or stock dashboard that is stuck with no laptop
/// around. The state is whether the Restart stock dashboard confirm is up.
/// Nothing runs unless the scooter is proven stopped, or the rider came in
/// through "Continue without vehicle data" ([noDataVouched]).
class RecoveryPanel extends Notifier<bool> {
  @override
  bool build() {
    ref.listen(vehicleProvider.select((v) => (v.speed > 0, v.speedTrusted)), (_, _) {
      if (!state || _stopped) return;
      final v = ref.read(vehicleProvider);
      if (v.speed == 0) untrustedCancel(ref, v, 'recovery_restart_stock');
      _closePrompt(v.speed > 0 ? 'riding' : 'untrusted');
    });
    // Confirming closes the prompt before the stock dashboard is launched,
    // so the launch that takes the foreground never lands here.
    onOwnScreenLost(ref, () {
      if (!state) return;
      untrustedCancel(ref, ref.read(vehicleProvider), 'recovery_restart_stock', ownScreen: true);
      _closePrompt(noPromptSurfaceReason);
    });
    return false;
  }

  CatalogApp get _stock => appCatalog.firstWhere((a) => a.id == CatalogApp.stockDashboardId);

  bool get _stopped {
    final v = ref.read(vehicleProvider);
    return v.provenStopped || (v.speed == 0 && noDataVouched(ref));
  }

  bool _allowed(String action) {
    uiTap('recovery-$action');
    return !refuseUnlessStopped(ref, ref.read(vehicleProvider), 'recovery_$action', 'Stop to use recovery',
        vouched: noDataVouched(ref));
  }

  Future<void> _shell(String action, Future<bool> Function() run, {required String done, required String failed}) async {
    if (!_allowed(action)) return;
    final ok = await run();
    if (!ref.mounted) return;
    ref.read(toastProvider.notifier).show(ok ? done : failed, type: ok ? ToastType.success : ToastType.error);
  }

  Future<void> wakeDisplay() => _shell(
        'wake',
        recoveryService.wakeAndDisableScreensaver,
        done: 'Display woken, screensaver off',
        failed: "Couldn't wake the display",
      );

  Future<void> resetDensity() => _shell(
        'density',
        recoveryService.resetDisplayDensity,
        done: 'Display density reset',
        failed: "Couldn't reset the display density",
      );

  Future<void> stopStock() => _shell(
        'stop-stock',
        recoveryService.forceStopStockDashboard,
        done: 'Stock dashboard stopped',
        failed: "Couldn't stop the stock dashboard",
      );

  /// Through Apps, so the overlay permission, the return pill and the
  /// force-stop on the way back are the same as for a launch from there.
  Future<void> openStock() async {
    if (!_allowed('open-stock')) return;
    await ref.read(appManagerProvider.notifier).openStock(_stock);
  }

  void askRestartStock() {
    if (!_allowed('restart-stock') || state) return;
    logModalShow('recovery_restart_stock', reason: 'user');
    state = true;
  }

  void cancelRestartStock() => _closePrompt('user');

  Future<void> confirmRestartStock() async {
    if (!state) return;
    _closePrompt('restart');
    if (!_stopped) return;
    await ref.read(appManagerProvider.notifier).openStock(_stock, restart: true);
  }

  void _closePrompt(String reason) {
    if (!state) return;
    logModalDismiss('recovery_restart_stock', reason: reason);
    state = false;
  }
}
