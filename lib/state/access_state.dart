import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vehicle_data.dart';
import '../providers/mock_provider.dart';
import '../services/analytics_logger.dart';
import '../services/mock_platform_service.dart';
import '../services/platform_provider.dart';
import '../services/platform_service.dart';
import '../services/prefs_service.dart';
import '../services/recovery_service.dart';
import 'apps_state.dart';
import 'prompt_surface.dart';
import 'riding_lockout.dart';
import 'toast_state.dart';

/// What OpenDash asks Android for, beyond what an install gives it.
enum Access {
  overlay(
    'Show over other apps',
    'The bar OpenDash keeps over another app: speed, alerts and the way back. Apps cannot be opened without it.',
  ),
  install('Install apps', 'Lets Apps install and update the apps you choose.'),
  music('Music from CarPlay and Android Auto', 'Shows what the phone is playing on the dashboard.'),
  front('Which app is in front', 'Offers the way back when an app opens a page of its own, such as a settings screen.'),
  home('Home app', 'OpenDash comes up by itself when the scooter starts.');

  const Access(this.label, this.why);

  final String label;
  final String why;
}

/// A list of accesses put to the rider, and what waits on the answer.
class AccessRequest {
  const AccessRequest({
    required this.title,
    required this.accesses,
    required this.required,
    required this.scope,
    this.then,
    this.startOff = const {},
  });
  final String title;

  /// Whose prompt this is: the app's id, for one put up before an app.
  final String scope;
  final List<Access> accesses;

  /// Optional ones the rider switched off before, in a prompt like this
  /// one: shown, but off, so the choice is remembered and can be changed.
  final Set<Access> startOff;

  /// Without these, [then] does not run.
  final Set<Access> required;
  final void Function()? then;
}

class AccessView {
  const AccessView({this.granted = const {}, this.request, this.busy = false, this.failed = const {}});

  /// Asked for in this prompt and still off: the command service did not
  /// grant them, and each gets the link to Android's own page.
  final Set<Access> failed;

  /// What Android has said; an access it has not answered for is absent.
  final Map<Access, bool> granted;
  final AccessRequest? request;
  final bool busy;

  bool has(Access a) => granted[a] ?? false;

  /// Known to be off.
  List<Access> get missing => [for (final a in Access.values) if (granted[a] == false) a];

  AccessView copyWith({Map<Access, bool>? granted, AccessRequest? Function()? request, bool? busy, Set<Access>? failed}) =>
      AccessView(
        granted: granted ?? this.granted,
        request: request != null ? request() : this.request,
        busy: busy ?? this.busy,
        failed: failed ?? this.failed,
      );
}

final accessProvider = NotifierProvider<AccessNotifier, AccessView>(AccessNotifier.new);

/// OpenDash's Android accesses in one place: what is granted, and one
/// prompt that lists what a flow needs before the flow starts, so the rider
/// is not sent back for a permission half way through setting up CarPlay.
/// It is put up once after an install (everything),
/// before an install or a launch from Apps (what that app needs), and from
/// Apps and Settings on request.
///
/// "Allow" first asks the head unit's command service to switch each one
/// on; what that does not grant gets a button to Android's own page. A
/// grant is believed only once Android reports it.
class AccessNotifier extends Notifier<AccessView> {
  /// Off for the test suite (`test/flutter_test_config.dart`): the platform
  /// reads answer "no" there, and every widget test would open on the
  /// set-up prompt. They used to stay unanswered, which hid it.
  static bool debugAskAfterUnlock = true;

  bool _homeAsked = false;

  @override
  AccessView build() {
    ref.listen(vehicleProvider.select((v) => (v.locked, v.vehicleState)), (_, _) => _afterUnlock());
    ref.listen(ridingLockoutProvider, (_, moving) {
      if (moving) _close('riding');
    });
    ref.listen(vehicleProvider.select((v) => v.locked), (_, locked) {
      if (locked) _close('locked');
    });
    // Back from one of Android's pages: what was granted there counts.
    ref.listen(ownScreenVisibleProvider, (_, shown) {
      if (shown && state.request != null) refresh().then((_) => _finishIfDone());
    });
    Future.microtask(() async {
      await refresh();
      _afterUnlock();
    });
    return const AccessView();
  }

  PlatformService get _platform => ref.read(platformServiceProvider);

  Future<void> refresh() async {
    final p = _platform;
    final next = <Access, bool>{};
    for (final (a, read) in <(Access, bool Function())>[
      (Access.overlay, p.canDrawOverlays),
      (Access.install, p.canInstallApks),
      (Access.music, p.hasNotificationAccess),
      (Access.front, p.hasUsageAccess),
      (Access.home, p.isDefaultHome),
    ]) {
      try {
        next[a] = read();
      } catch (_) {}
    }
    state = state.copyWith(granted: next);
  }

  static String _declinedKey(Access a) => '${PrefsKeys.accessDeclined}.${a.name}';

  /// Switched off, with Continue, in a prompt put up before an app: the
  /// rider saw what it is for there and said no. It is not a reason for
  /// that prompt again, and it shows there switched off.
  ///
  /// Only that counts. Once the rider switched everything off in
  /// the set-up prompt, then backed out of CarPlay's with "Not now"; both
  /// used to count as "no" for good, so CarPlay then installed without a
  /// word about its music access. The set-up and review prompts list
  /// everything at once, out of context, and "Not now" decides nothing.
  final Set<Access> _declinedNow = {};
  bool _declined(Access a) => _declinedNow.contains(a) || PrefsService.getBool(_declinedKey(a), false);
  void _setDeclined(Access a, bool on) {
    on ? _declinedNow.add(a) : _declinedNow.remove(a);
    on ? PrefsService.setBool(_declinedKey(a), true) : PrefsService.remove(_declinedKey(a));
  }

  /// Left off with "Not now" where the app could go ahead without them:
  /// not asked for again before that app until OpenDash next starts.
  ///
  /// Per app, not for all of them. Once the rider said "Not now"
  /// to the music access before Android Auto, and CarPlay then opened
  /// without a word about it: "Not now" to one app had answered for every
  /// other. It decides nothing beyond the prompt it was said in.
  final Set<(String, Access)> _later = {};

  /// Puts [accesses] to the rider if any is off, then runs [then]. An
  /// optional one that was turned down before is not asked for again here
  /// ([all] asks regardless: the rider came to review them). With nothing
  /// to ask, [then] runs at once. [scope] names whose prompt it is (an
  /// app's id), so "Not now" there holds for that app only.
  Future<void> ask({
    required String title,
    required List<Access> accesses,
    Set<Access> required = const {},
    void Function()? then,
    bool all = false,
    String? scope,
  }) async {
    await refresh();
    if (!ref.mounted) return;
    final who = scope ?? title;
    final open = [
      for (final a in accesses)
        if (state.granted[a] == false && (all || required.contains(a) || !(_declined(a) || _later.contains((who, a))))) a,
    ];
    if (open.isEmpty || ref.read(ridingLockoutProvider) || ref.read(vehicleProvider).locked) {
      if (required.every(state.has) || open.isEmpty) then?.call();
      return;
    }
    // The notification-access page used to open by itself at the first
    // projection launch; this prompt is that question now.
    if (open.contains(Access.music)) {
      PrefsService.setBool(PrefsKeys.projectionMusicAsked, true);
      ref.read(appManagerProvider.notifier).musicAccessPutToRider();
    }
    logEvent('access', 'ask', {
      'title': title,
      'scope': who,
      'open': [for (final a in open) a.name],
      'required': [for (final a in required) a.name],
    });
    _skipped = {};
    state = state.copyWith(
      request: () => AccessRequest(
        title: title,
        accesses: accesses,
        required: required,
        scope: who,
        then: then,
        startOff: {for (final a in accesses) if (state.granted[a] == false && !required.contains(a) && _declined(a)) a},
      ),
      failed: {},
    );
  }

  /// What the rider switched off in the prompt that is up.
  Set<Access> _skipped = {};

  /// Everything that is off, from Apps or Settings.
  Future<void> review() => ask(title: 'OpenDash access', accesses: Access.values, all: true);

  /// Once after an install, and after that whenever OpenDash finds it is
  /// no longer the home app (someone may have chosen the stock dashboard on
  /// purpose, so it asks; "Not now" holds until the next start).
  void _afterUnlock() {
    final v = ref.read(vehicleProvider);
    if (!debugAskAfterUnlock) return;
    if (v.locked || state.request != null || state.granted.isEmpty) return;
    if (v.vehicleState != VehicleState.parked && v.vehicleState != VehicleState.charging) return;
    if (ref.read(ridingLockoutProvider) || !ref.read(ownScreenVisibleProvider)) return;
    if (!PrefsService.getBool(PrefsKeys.accessWelcomed, false)) {
      PrefsService.setBool(PrefsKeys.accessWelcomed, true);
      _homeAsked = true;
      ask(title: 'Set up OpenDash', accesses: Access.values, all: true);
    } else if (!_homeAsked && state.granted[Access.home] == false) {
      _homeAsked = true;
      ask(title: 'OpenDash is not the home app', accesses: const [Access.home], all: true);
    }
  }

  /// "Continue": each access of the request that is off, and that the rider
  /// left switched on, is switched on through the command service, then
  /// read back. An optional one in [skip] is left off and not asked for
  /// again in a flow.
  Future<void> allow({Set<Access> skip = const {}}) async {
    final request = state.request;
    if (request == null || state.busy) return;
    _skipped = {for (final a in skip) if (!request.required.contains(a)) a};
    state = state.copyWith(busy: true);
    final p = _platform;
    final asked = <Access>{};
    for (final a in request.accesses) {
      if (state.has(a) || _skipped.contains(a)) continue;
      asked.add(a);
      final ok = p is MockPlatformService ? p.grant(a.name) : await recoveryService.grantAccess(a.name);
      logEvent('access', 'grant', {'access': a.name, 'sent': ok});
      if (!ref.mounted) return;
    }
    await refresh();
    if (!ref.mounted) return;
    state = state.copyWith(busy: false, failed: {for (final a in asked) if (!state.has(a)) a});
    logEvent('access', 'result', {
      for (final a in request.accesses) a.name: state.has(a),
      'skipped': [for (final a in _skipped) a.name],
    });
    _finishIfDone();
  }

  /// Android's own page for [a], for a grant the command service did not
  /// make. The island's "‹ OpenDash" is the way back.
  Future<void> openPage(Access a) async {
    final p = _platform;
    final open = switch (a) {
      Access.overlay => p.openOverlayPermissionSettings,
      Access.install => p.openInstallPermissionSettings,
      Access.music => p.openNotificationAccessSettings,
      Access.front => p.openUsageAccessSettings,
      Access.home => p.openHomeSettings,
    };
    logEvent('access', 'page', {'access': a.name});
    final ok = await ref.read(appManagerProvider.notifier).openAccessPage(a.name, a.label, open);
    if (!ok && ref.mounted) ref.read(toastProvider.notifier).show('Could not open that page', type: ToastType.error);
  }

  void _finishIfDone() {
    final request = state.request;
    if (request == null) return;
    if (request.accesses.every((a) => state.has(a) || _skipped.contains(a))) {
      for (final a in request.accesses) {
        if (state.has(a)) {
          _setDeclined(a, false);
        } else if (_skipped.contains(a) && request.then != null) {
          _setDeclined(a, true);
        }
      }
      state = state.copyWith(request: () => null, failed: {});
      // Nothing waited on it (the set-up or a review): say it went through.
      if (request.then == null) {
        ref.read(toastProvider.notifier).show(_skipped.isEmpty ? 'OpenDash has what it needs from Android' : 'Saved');
      }
      request.then?.call();
    }
  }

  /// "Continue" / "Not now": what is still off and optional is not asked
  /// for again in a flow. What waited goes ahead if it can.
  void done() {
    final request = state.request;
    if (request == null) return;
    final ok = request.required.every(state.has);
    if (ok && request.then != null) {
      _later.addAll([for (final a in request.accesses) if (!state.has(a)) (request.scope, a)]);
    }
    logEvent('access', 'done', {'title': request.title, 'ok': ok, 'off': [for (final a in request.accesses) if (!state.has(a)) a.name]});
    state = state.copyWith(request: () => null, failed: {});
    if (ok) {
      request.then?.call();
    } else {
      final first = request.required.firstWhere((a) => !state.has(a));
      ref.read(toastProvider.notifier).show('Not done: "${first.label}" is needed for that', type: ToastType.warning);
    }
  }

  void _close(String reason) {
    if (state.request == null) return;
    logEvent('access', 'closed', {'reason': reason});
    state = state.copyWith(request: () => null, busy: false);
  }
}
