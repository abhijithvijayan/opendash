import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_catalog.dart';
import '../models/ota_shield.dart';
import '../services/analytics_logger.dart';
import '../services/platform_provider.dart';
import 'apps_state.dart';
import 'ota_state.dart';
import 'passcode_gate.dart';
import 'toast_state.dart';

/// Whether OTA Shield is installed, from the Apps screen's own record.
final otaShieldInstalledProvider =
    Provider<bool>((ref) => ref.watch(appManagerProvider.select((m) => m[CatalogApp.otaShieldId]?.present ?? false)));

/// Whether OTA Shield is shown at all, on Apps and Settings → Updates
/// ([CatalogApp.hiddenUnlessInstalled]).
final otaShieldShownProvider = Provider<bool>((ref) => appCatalog
    .firstWhere((a) => a.id == CatalogApp.otaShieldId)
    .shownWith(ref.watch(appManagerProvider.select((m) => m[CatalogApp.otaShieldId]))));

/// What OTA Shield's daemon reports, asked while a screen that shows it is
/// open (Settings → Updates, the Apps screen) and not otherwise. Null until
/// the first answer, and while OTA Shield is not installed.
///
/// OTA Shield is a separate app with a root daemon. OpenDash reads it, and
/// through its service may ask it to activate the block or to lift an
/// engaged boot fail-safe, both behind the passcode. Turning the block off
/// and its boot setting stay in OTA Shield's own app.
final otaShieldProvider = NotifierProvider.autoDispose<OtaShieldNotifier, OtaShieldReport?>(OtaShieldNotifier.new);

class OtaShieldNotifier extends Notifier<OtaShieldReport?> {
  /// Often enough that coming back from activating it in OTA Shield shows
  /// the change without a tap; one loopback connection each time.
  static const every = Duration(seconds: 10);

  /// While an activation OpenDash started runs, so its steps show.
  static const activatingEvery = Duration(seconds: 1);

  Timer? _timer;
  Timer? _soon;
  Object? _logged;

  @override
  OtaShieldReport? build() {
    ref.onDispose(() {
      _timer?.cancel();
      _soon?.cancel();
    });
    ref.listen(otaShieldInstalledProvider, (_, installed) {
      if (installed) {
        unawaited(refresh());
      } else {
        state = null;
      }
    });
    _timer = Timer.periodic(every, (_) => refresh());
    Future.microtask(refresh);
    return null;
  }

  Future<void> refresh() async {
    if (!ref.mounted || !ref.read(otaShieldInstalledProvider)) return;
    final report = await ref.read(platformServiceProvider).otaShieldStatus();
    if (!ref.mounted) return;
    state = report;
    ref.read(otaShieldAlertProvider.notifier).seenReport(report);
    final s = report.service;
    final key = (report.running, report.blocked, report.offerCount, s?.activated, s?.failsafe, s?.step, s?.activation, s?.activationStep);
    if (key != _logged) {
      _logged = key;
      logEvent('ota_shield', 'status', {
        'running': report.running,
        'blocked': report.blocked,
        'offers': report.offerCount,
        'service': s != null,
        if (s != null) ...{
          'activated': s.activated,
          'failsafe': s.failsafe,
          'step': s.step,
          'activation': s.activation,
          'activation_step': s.activationStep,
        },
      });
    }
    _soon?.cancel();
    if (s?.activation == 'running') _soon = Timer(activatingEvery, refresh);
  }

  /// "Activate": OTA Shield's own activation, started through its service.
  void activate() => _behindPasscode('activate', 'Enter passcode to activate OTA Shield', () async {
        final ok = await ref.read(platformServiceProvider).otaShieldActivate();
        logEvent('ota_shield', 'activate', {'asked': ok});
        if (!ok) _toast('OTA Shield did not answer. Open it to activate');
      });

  /// "Turn off fail-safe": lifts the firewall OTA Shield put up when it could
  /// not start at boot. Ola's cloud, and its updates, can reach the scooter
  /// again until the block is activated.
  void disableFailsafe() => _behindPasscode('disable_failsafe', 'Enter passcode to turn off the fail-safe', () async {
        final ok = await ref.read(platformServiceProvider).otaShieldDisableFailsafe();
        logEvent('ota_shield', 'disable_failsafe', {'done': ok});
        if (!ok) _toast('OTA Shield could not turn off its fail-safe');
      });

  void _behindPasscode(String action, String purpose, Future<void> Function() run) {
    if (state?.service == null) return;
    uiTap('shield-$action');
    ref.read(passcodeGateProvider.notifier).request(
          purpose: purpose,
          onSuccess: () async {
            await run();
            await refresh();
          },
        );
  }

  void _toast(String text) {
    if (ref.mounted) ref.read(toastProvider.notifier).show(text, type: ToastType.warning);
  }
}

class OtaShieldAlert {
  const OtaShieldAlert({this.problem, this.seen});

  /// [OtaShieldReport.problem] at the last look; null when there is none.
  final String? problem;

  /// The problem already shown on the Updates screen.
  final String? seen;

  /// The bell and the dot on the Updates row: a problem not yet seen. No
  /// popup, toast or sound.
  bool get bell => problem != null && problem != seen;
}

/// Watches OTA Shield in the background so that a block the rider switched
/// on and that is not up lights the bell. A look every [every] from [grace]
/// after start (OTA Shield takes a while to start its block at power-on),
/// the port only while it answers; the Settings card's looks count too.
final otaShieldAlertProvider = NotifierProvider<OtaShieldAlertNotifier, OtaShieldAlert>(OtaShieldAlertNotifier.new);

class OtaShieldAlertNotifier extends Notifier<OtaShieldAlert> {
  static const grace = Duration(minutes: 3);
  static const every = Duration(minutes: 5);

  Timer? _first;
  Timer? _timer;

  @override
  OtaShieldAlert build() {
    ref.onDispose(() {
      _first?.cancel();
      _timer?.cancel();
    });
    ref.listen(otaScreenOpenProvider, (_, open) {
      if (open) _markSeen();
    });
    _first = Timer(grace, () {
      unawaited(_look());
      _timer = Timer.periodic(every, (_) => _look());
    });
    return const OtaShieldAlert();
  }

  Future<void> _look() async {
    // Asked of Android, not the Apps screen's record, which is only filled
    // once something has opened it.
    final platform = ref.read(platformServiceProvider);
    if (!platform.isInstalled(otaShieldPackage)) {
      seenReport(null);
      return;
    }
    final report = await platform.otaShieldStatus(serviceWhenRunning: false);
    if (ref.mounted) seenReport(report);
  }

  /// A fresh report, from here or from the Settings card.
  void seenReport(OtaShieldReport? report) {
    final problem = report?.problem;
    if (problem == state.problem) return;
    logEvent('ota_shield', 'alert', {'problem': problem});
    state = problem == null
        ? const OtaShieldAlert()
        : OtaShieldAlert(problem: problem, seen: ref.read(otaScreenOpenProvider) ? problem : state.seen);
  }

  void _markSeen() {
    if (state.bell) state = OtaShieldAlert(problem: state.problem, seen: state.problem);
  }
}
