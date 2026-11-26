import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import '../models/vehicle_data.dart';
import '../providers/mock_provider.dart';
import '../services/analytics_logger.dart';
import '../services/build_info.dart';
import '../services/platform_provider.dart';
import '../services/platform_service.dart';
import '../services/prefs_service.dart';
import '../services/trusted_clock.dart';
import 'access_state.dart';
import 'apps_state.dart';
import 'firmware_state.dart';
import 'passcode_gate.dart';
import 'prompt_surface.dart';
import 'riding_lockout.dart';
import 'settings_state.dart';
import 'toast_state.dart';

/// Where OpenDash's own update stands.
enum OtaStatus { upToDate, available, downloading, ready, installing, failed }

/// A release of OpenDash, as its `opendash-release.json` and the GitHub
/// release it came with describe it.
class OtaRelease {
  const OtaRelease({
    required this.version,
    required this.build,
    required this.sha256,
    required this.apkUrl,
    this.minBuild = 0,
    this.size = 0,
    this.notes = '',
    this.url = '',
    this.published = '',
  });

  final String version;
  final int build;
  final String sha256;
  final String apkUrl;
  final int minBuild;
  final int size;

  /// The release's own text, plain, capped where it was fetched.
  final String notes;
  final String url;
  final String published;

  Map<String, Object?> toJson() => {
        'version': version, 'build': build, 'sha256': sha256, 'apk_url': apkUrl,
        'min_build': minBuild, 'size': size, 'notes': notes, 'url': url, 'published': published,
      };

  static OtaRelease? fromJson(Object? m) {
    if (m is! Map) return null;
    final build = m['build'];
    final sha = m['sha256'];
    final apk = m['apk_url'];
    if (build is! int || sha is! String || sha.length < 6 || apk is! String || apk.isEmpty) return null;
    return OtaRelease(
      version: m['version'] is String ? m['version'] as String : '',
      build: build,
      sha256: sha.toLowerCase(),
      apkUrl: apk,
      minBuild: m['min_build'] is int ? m['min_build'] as int : 0,
      size: m['size'] is int ? m['size'] as int : 0,
      notes: m['notes'] is String ? m['notes'] as String : '',
      url: m['url'] is String ? m['url'] as String : '',
      published: m['published'] is String ? m['published'] as String : '',
    );
  }

  /// From the platform's answer to the release question.
  static OtaRelease? fromCheck(Map<String, Object?> answer) {
    Object? facts;
    try {
      facts = jsonDecode('${answer['release']}');
    } on FormatException {
      return null;
    }
    if (facts is! Map) return null;
    return fromJson({
      ...facts,
      'apk_url': answer['apk_url'],
      'size': answer['apk_size'],
      'notes': answer['notes'],
      'url': answer['url'],
      'published': answer['published'],
    });
  }
}

class OtaData {
  const OtaData({
    this.status = OtaStatus.upToDate,
    this.release,
    this.progress = 0,
    this.error = '',
    this.auto = true,
    this.checking = false,
    this.checkedAtMs,
    this.seenBuild = 0,
    this.skippedBuild = 0,
    this.pendingBuild = 0,
    this.unreachable = false,
  });

  final OtaStatus status;

  /// The newer release, from "available" on.
  final OtaRelease? release;

  /// Download progress, 0 to 100.
  final int progress;

  /// Why it failed, in the rider's words.
  final String error;

  /// Check by itself once a day, or only when asked.
  final bool auto;
  final bool checking;

  /// When GitHub last answered a check.
  final int? checkedAtMs;
  final int seenBuild;
  final int skippedBuild;

  /// The build an install was started for and that has not yet been seen
  /// running stably; 0 when none.
  final int pendingBuild;

  /// The last check, automatic or asked for, did not reach GitHub. Not
  /// "up to date": nothing is known. Cleared by the next one that does.
  final bool unreachable;

  String get versionName => release?.version ?? '';

  /// The bell and the dot on the Updates row: a release the rider has
  /// neither seen on the screen nor skipped. No popup, toast or sound.
  bool get bell =>
      (status == OtaStatus.available || status == OtaStatus.ready) &&
      release != null &&
      release!.build != seenBuild &&
      release!.build != skippedBuild;

  /// Shown as an update, i.e. not one the rider skipped.
  bool get offered => release != null && release!.build != skippedBuild;

  OtaData copyWith({
    OtaStatus? status,
    OtaRelease? Function()? release,
    int? progress,
    String? error,
    bool? auto,
    bool? checking,
    int? Function()? checkedAtMs,
    int? seenBuild,
    int? skippedBuild,
    int? pendingBuild,
    bool? unreachable,
  }) =>
      OtaData(
        status: status ?? this.status,
        release: release != null ? release() : this.release,
        progress: progress ?? this.progress,
        error: error ?? this.error,
        auto: auto ?? this.auto,
        checking: checking ?? this.checking,
        checkedAtMs: checkedAtMs != null ? checkedAtMs() : this.checkedAtMs,
        seenBuild: seenBuild ?? this.seenBuild,
        skippedBuild: skippedBuild ?? this.skippedBuild,
        pendingBuild: pendingBuild ?? this.pendingBuild,
        unreachable: unreachable ?? this.unreachable,
      );
}

final otaProvider = NotifierProvider<OtaNotifier, OtaData>(OtaNotifier.new);

/// OpenDash updating itself from its GitHub releases.
///
/// It finds a release (one anonymous request, at most once a day), and on
/// the rider's taps downloads it over Wi-Fi, checks it against the release's
/// checksum and OpenDash's own signing certificate, and hands it to
/// Android's installer, whose confirmation screen is the last word. It
/// never installs silently, never uninstalls, and never touches scooter
/// firmware (`firmware_state.dart`).
// TODO(self-update): never run end to end on the scooter.
// Run the self-update device test once a release is public.
class OtaNotifier extends Notifier<OtaData> {
  /// The automatic check waits this long after start, and for a clock that
  /// can be trusted: HTTPS fails on a clock that sits in 2024.
  static const bootDelay = Duration(minutes: 10);

  /// And is not repeated until this long after the last answered one.
  /// GitHub allows 60 unauthenticated requests an hour per address, shared
  /// with the Apps screen.
  static const checkEvery = Duration(hours: 20);

  /// How often a running dashboard looks again, so one that runs for days
  /// still finds a release (2026-11-25: 0.2.1 went unseen because the
  /// check ran once per start). [checkEvery], by the trusted clock, decides
  /// whether a look sends anything; a timer alone would not, since it stops
  /// while the head unit sleeps. A failed check is tried again at the next.
  static const autoEvery = Duration(hours: 1);

  /// After Wi-Fi joins, the next look comes this soon: on mobile data GitHub
  /// mostly never answers (2026-11-24: eleven timeouts in a day), so a short
  /// stop on Wi-Fi can be the only chance. Long enough for the link to settle.
  static const wifiSettle = Duration(seconds: 30);
  static const progressEvery = Duration(milliseconds: 500);

  /// After this long running, a newly installed build counts as started.
  static const confirmAfter = Duration(seconds: 10);
  static const answerEvery = Duration(seconds: 2);

  /// `PackageInstaller.STATUS_FAILURE_ABORTED`: the rider said no on
  /// Android's confirmation screen.
  static const installerAborted = 3;

  /// How often the folder the companion phone app writes to is looked at.
  static const incomingEvery = Duration(seconds: 30);

  Timer? _autoTimer;
  Timer? _progressTimer;
  Timer? _confirmTimer;
  Timer? _answerTimer;
  Timer? _incomingTimer;
  bool _incomingBusy = false;
  String? _path;
  int _installed = 0;
  String? _lastHeld;

  PlatformService get _platform => ref.read(platformServiceProvider);

  @override
  OtaData build() {
    ref.onDispose(() {
      _autoTimer?.cancel();
      _progressTimer?.cancel();
      _confirmTimer?.cancel();
      _answerTimer?.cancel();
      _incomingTimer?.cancel();
    });
    _installed = BuildInfo.number ?? 0;
    final auto = PrefsService.getBool(PrefsKeys.updateAuto, true);
    final checked = PrefsService.getInt(PrefsKeys.updateCheckedAt, 0);
    OtaRelease? found;
    try {
      found = OtaRelease.fromJson(jsonDecode(PrefsService.getString(PrefsKeys.updateFound, 'null')));
    } on FormatException {
      found = null;
    }
    if (auto) _autoTimer = Timer(bootDelay, () => check(auto: true));
    ref.listen(vehicleProvider.select((v) => v.wifiConnected), (was, now) {
      if (was == false && now && state.auto) {
        _autoTimer?.cancel();
        _autoTimer = Timer(wifiSettle, () => check(auto: true));
      }
    });
    // Back from Android's installer with the old build still running: it
    // was cancelled there, or it failed.
    ref.listen(ownScreenVisibleProvider, (_, shown) {
      if (shown && state.status == OtaStatus.installing) _installerAnswer();
      if (shown) checkIncoming();
    });
    Future.microtask(_afterStart);
    Future.microtask(() {
      if (!ref.mounted) return;
      _publish();
      checkIncoming();
    });
    _incomingTimer = Timer.periodic(incomingEvery, (_) => checkIncoming());
    return OtaData(
      auto: auto,
      checkedAtMs: checked == 0 ? null : checked,
      seenBuild: PrefsService.getInt(PrefsKeys.updateSeen, 0),
      skippedBuild: PrefsService.getInt(PrefsKeys.updateSkipped, 0),
      release: found,
      status: found == null ? OtaStatus.upToDate : OtaStatus.available,
    );
  }

  void _toast(String message, {bool warning = false}) =>
      ref.read(toastProvider.notifier).show(message, type: warning ? ToastType.warning : ToastType.info);

  /// Whether [r] is an update for the build that is installed.
  bool _newer(OtaRelease r) => r.build > _installed && r.minBuild <= _installed;

  // ---- at start: an update that was handed to the installer --------------

  Future<void> _afterStart() async {
    Map<String, Object?> record;
    try {
      record = _platform.updateRecord();
    } catch (_) {
      return;
    }
    if (!ref.mounted) return;
    final installed = record['installed'];
    if (installed is int && installed > 0) _installed = installed;
    // A release found earlier that this build already is, or has passed.
    final found = state.release;
    if (found != null && !_newer(found) && state.status == OtaStatus.available) _forget();
    final to = record['to'];
    if (to is! int || to == 0) return;
    final from = record['from'];
    final starts = record['starts'];
    if (record['fallback_log'] is String) {
      logEvent('selfupdate', 'fallback_stock', {'starts': starts});
    }
    if (_installed == to) {
      if (starts is int && starts > 1) logEvent('selfupdate', 'unconfirmed', {'starts': starts});
      state = state.copyWith(pendingBuild: to);
      _confirmTimer = Timer(confirmAfter, () async {
        logEvent('selfupdate', 'confirmed', {'from': from, 'to': to, 'starts': starts});
        await _platform.updateRecordClear();
        if (!ref.mounted) return;
        state = state.copyWith(pendingBuild: 0);
        _forget();
        _toast('Updated to OpenDash $appVersion');
      });
    } else {
      logEvent('selfupdate', 'install_result', {
        'status': record['status'] ?? 'not_replaced',
        'message': record['message'],
      });
      await _platform.updateRecordClear();
    }
  }

  void _forget() {
    PrefsService.remove(PrefsKeys.updateFound);
    state = state.copyWith(status: OtaStatus.upToDate, release: () => null, progress: 0, error: '');
  }

  // ---- finding a release -------------------------------------------------

  void setAuto(bool on) {
    if (on == state.auto) return;
    state = state.copyWith(auto: on);
    PrefsService.setBool(PrefsKeys.updateAuto, on);
    _publish();
    _autoTimer?.cancel();
    if (on) _autoTimer = Timer(bootDelay, () => check(auto: true));
  }

  /// One request. [auto]: the automatic check, which keeps to the
  /// twenty-hour rule, says nothing and looks again every [autoEvery];
  /// otherwise the rider's "Check now".
  Future<void> check({bool auto = false}) async {
    if (auto) {
      _autoTimer?.cancel();
      _autoTimer = Timer(autoEvery, () => check(auto: true));
    }
    if (state.checking) return;
    if (state.status == OtaStatus.downloading || state.status == OtaStatus.installing) return;
    final v = ref.read(vehicleProvider);
    String? held;
    // A locked scooter is not being ridden, though its data has gone quiet
    // and reads as "may be moving" (once logged as held: riding, locked).
    final parked = v.locked || (v.provenStopped && (v.vehicleState == VehicleState.parked || v.isCharging));
    if (!TrustedClock.trusted) {
      held = 'clock';
    } else if (!parked || (!v.locked && ref.read(ridingLockoutProvider))) {
      // A ride, the stop at a traffic light included (the automatic check
      // once went out ten minutes after start, in the middle of
      // a ride, while the scooter stood still for a moment).
      held = 'riding';
    } else if (auto) {
      final last = state.checkedAtMs;
      final now = TrustedClock.now().millisecondsSinceEpoch;
      if (last != null && now >= last && now - last < checkEvery.inMilliseconds) held = 'recent';
    }
    if (auto) {
      // Held for a ride or the clock: asked again sooner than the hour.
      if (held == 'riding' || held == 'clock') {
        _autoTimer?.cancel();
        _autoTimer = Timer(bootDelay, () => check(auto: true));
      }
      if (held != null && held == _lastHeld) return;
      _lastHeld = held;
    }
    if (held != null) {
      logEvent('selfupdate', 'check', {'ok': false, 'status': null, 'newer': false, 'auto': auto, 'held': held});
      if (!auto) _toast(held == 'clock' ? 'The clock is not set yet. Try again in a minute' : 'Stop before checking for updates', warning: true);
      return;
    }
    state = state.copyWith(checking: true);
    Map<String, Object?> answer;
    try {
      answer = await _platform.selfUpdateCheck(releasesRepo, etag: PrefsService.getString(PrefsKeys.updateEtag, ''));
    } catch (_) {
      answer = const {'status': 0};
    }
    if (!ref.mounted) return;
    final status = answer['status'] is int ? answer['status'] as int : 0;
    final answered = status == 200 || status == 304;
    var newer = state.status != OtaStatus.upToDate;
    if (status == 200) {
      final release = OtaRelease.fromCheck(answer);
      newer = release != null && _newer(release);
      if (answer['etag'] is String) PrefsService.setString(PrefsKeys.updateEtag, answer['etag'] as String);
      if (newer) {
        PrefsService.setString(PrefsKeys.updateFound, jsonEncode(release.toJson()));
        if (state.release?.build != release.build) {
          logEvent('selfupdate', 'available', {'version': release.version, 'build': release.build});
          _path = null;
          state = state.copyWith(status: OtaStatus.available, release: () => release, progress: 0, error: '');
        }
      } else if (state.status == OtaStatus.available) {
        _forget();
      }
    }
    logEvent('selfupdate', 'check', {'ok': answered, 'status': status, 'newer': newer, 'auto': auto});
    int? at = state.checkedAtMs;
    if (answered) {
      at = TrustedClock.now().millisecondsSinceEpoch;
      PrefsService.setInt(PrefsKeys.updateCheckedAt, at);
    }
    state = state.copyWith(checking: false, checkedAtMs: () => at, unreachable: !answered);
    if (!auto) {
      _toast(
        !answered
            ? 'Could not reach GitHub'
            : newer
                ? 'OpenDash ${state.versionName} is available'
                : 'OpenDash is up to date',
        warning: !answered,
      );
    }
  }

  /// The Updates screen is showing it: the bell goes out for this release.
  void markSeen() {
    final build = state.release?.build;
    if (build == null || build == state.seenBuild) return;
    state = state.copyWith(seenBuild: build);
    PrefsService.setInt(PrefsKeys.updateSeen, build);
  }

  /// "Skip this version": hidden until a newer one.
  void skip() {
    final build = state.release?.build;
    if (build == null || state.status != OtaStatus.available) return;
    state = state.copyWith(skippedBuild: build);
    PrefsService.setInt(PrefsKeys.updateSkipped, build);
    _publish();
  }

  // ---- updates the companion phone app sends ------------------------------

  /// OpenDash's answer for the companion app: send updates by itself only
  /// when OpenDash checks by itself. Never read back here.
  void _publish() {
    final json = jsonEncode({'v': 1, 'auto': state.auto, 'installed': _installed, 'skipped': state.skippedBuild});
    _platform.companionPublish(json).catchError((_) {});
  }

  /// Looks at what the companion app left: on start, on coming back to the
  /// front, and every [incomingEvery]. Trusts nothing it is handed: the same
  /// checks as a download of its own, on a private copy.
  Future<void> checkIncoming() async {
    if (!ref.mounted || _incomingBusy || state.checking) return;
    if (state.status == OtaStatus.downloading || state.status == OtaStatus.installing) return;
    _incomingBusy = true;
    try {
      await _takeIncoming();
    } finally {
      _incomingBusy = false;
    }
  }

  /// The release the companion left, and whether the rider sent it by hand
  /// (`manual`) rather than the phone by itself.
  static ({OtaRelease release, bool manual})? _incomingRelease(String json) {
    try {
      final m = jsonDecode(json);
      if (m is! Map) return null;
      final build = m['build'];
      final sha = m['sha256'];
      final apk = m['apk'];
      if (build is! int || sha is! String || sha.length < 6 || apk is! String || apk.isEmpty) return null;
      String text(String k) => m[k] is String ? m[k] as String : '';
      final notes = text('notes');
      return (
        release: OtaRelease(
          version: text('version').isEmpty ? '$build' : text('version'),
          build: build,
          sha256: sha.toLowerCase(),
          apkUrl: '',
          notes: notes.length > 8000 ? notes.substring(0, 8000) : notes,
          published: text('published'),
        ),
        manual: m['manual'] == true,
      );
    } on FormatException {
      return null;
    }
  }

  bool get _busy => state.status == OtaStatus.downloading || state.status == OtaStatus.installing;

  Future<void> _takeIncoming() async {
    String? json;
    try {
      json = await _platform.companionIncomingRelease();
    } catch (_) {
      return;
    }
    if (json == null || !ref.mounted) return;
    final sent = _incomingRelease(json);
    final release = sent?.release;
    Future<void> drop(String result) async {
      logEvent('selfupdate', 'incoming', {'result': result, 'build': release?.build});
      await _platform.companionIncomingClear();
    }

    if (sent == null || release == null) return drop('unreadable');
    if (release.build <= _installed) return drop('obsolete');
    // The phone sends a skipped build by itself only when it read OpenDash's
    // answer before the skip; the rider's skip stands.
    if (!sent.manual && release.build == state.skippedBuild) return drop('skipped');
    final current = state.release;
    // Already offered, or a newer one found here: nothing to copy.
    if (state.status == OtaStatus.ready && (current?.build ?? 0) >= release.build) return;
    if ((state.status == OtaStatus.available || state.status == OtaStatus.failed) &&
        current != null &&
        current.build > release.build) {
      return drop('older');
    }
    // Android refused this one in this run: copying it in again won't change that.
    if (state.status == OtaStatus.failed && current?.build == release.build) return;
    final path = await _platform.companionIncomingCopy(release.build);
    if (path == null || !ref.mounted) return;
    if (_busy) {
      await _platform.deleteFile(path);
      return;
    }
    final error = await _check(release, path);
    if (!ref.mounted) return;
    // An install may have started while the file was checked.
    if (_busy) {
      await _platform.deleteFile(path);
      return;
    }
    if (error != null) {
      logEvent('selfupdate', 'incoming', {'result': 'rejected', 'build': release.build, ...error.checks});
      await _platform.deleteFile(path);
      await _platform.companionIncomingClear();
      return;
    }
    final replaced = _path;
    _path = path;
    final unskip = state.skippedBuild == release.build;
    if (unskip) PrefsService.setInt(PrefsKeys.updateSkipped, 0);
    state = state.copyWith(
      status: OtaStatus.ready,
      release: () => release,
      progress: 100,
      error: '',
      skippedBuild: unskip ? 0 : null,
    );
    if (unskip) _publish();
    // An earlier build from the phone that this one replaces.
    if (replaced != null && replaced != path && replaced.contains('opendash-incoming')) await _platform.deleteFile(replaced);
    final toast = PrefsService.getInt(PrefsKeys.updateIncomingToasted, 0) != release.build && !ref.read(ridingLockoutProvider);
    logEvent('selfupdate', 'incoming', {'result': 'ready', 'build': release.build, 'toast': toast});
    if (toast) {
      PrefsService.setInt(PrefsKeys.updateIncomingToasted, release.build);
      _toast('OpenDash ${release.version} is ready to install. Sent from your phone');
    }
  }

  // ---- download and verify ----------------------------------------------

  /// On the rider's tap, on whatever link the head unit has: nothing here
  /// is Wi-Fi only (why the scooter's mobile data
  /// does not reach GitHub is a separate question). No resume: a cancelled
  /// or failed download starts again from nothing.
  Future<void> startDownload() async {
    final release = state.release;
    if (release == null || (state.status != OtaStatus.available && state.status != OtaStatus.failed)) return;
    state = state.copyWith(status: OtaStatus.downloading, progress: 0, error: '');
    final started = AnalyticsLogger.instance.monoMicros;
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(progressEvery, (_) {
      if (state.status != OtaStatus.downloading || release.size <= 0) return;
      final bytes = _platform.downloadProgress(PlatformService.selfUpdateFile);
      state = state.copyWith(progress: (bytes * 100 ~/ release.size).clamp(0, 99));
    });
    String? path;
    try {
      path = await ref.read(appManagerProvider.notifier).inTurn(() => _platform.selfUpdateDownload(release.apkUrl));
    } catch (_) {
      path = null;
    }
    _progressTimer?.cancel();
    if (!ref.mounted) return;
    final ms = (AnalyticsLogger.instance.monoMicros - started) ~/ 1000;
    // Cancelled while it ran: the screen is already back at "available".
    if (state.status != OtaStatus.downloading) {
      if (path != null) await _platform.deleteFile(path);
      return;
    }
    if (path == null) {
      logEvent('selfupdate', 'download', {'ok': false, 'bytes': 0, 'ms': ms, 'error': 'download'});
      state = state.copyWith(status: OtaStatus.failed, error: 'The download did not finish');
      return;
    }
    logEvent('selfupdate', 'download', {'ok': true, 'bytes': release.size, 'ms': ms, 'error': null});
    await _verify(release, path);
  }

  void cancelDownload() {
    if (state.status != OtaStatus.downloading) return;
    _progressTimer?.cancel();
    _platform.cancelDownload(PlatformService.selfUpdateFile);
    state = state.copyWith(status: OtaStatus.available, progress: 0);
  }

  /// The checksum the release gives, then what Android reads from the file:
  /// OpenDash's own package, the release's build (which must be newer than
  /// this one), and the certificate this build is signed with. One failure
  /// deletes the file.
  /// The checks every update file goes through, wherever it came from; null
  /// when it passes.
  Future<({String text, Map<String, bool> checks})?> _check(OtaRelease release, String path) async {
    final sum = await _platform.fileSha256(path);
    final info = await _platform.apkInfo(path);
    final own = await _platform.installedInfo(ownPackage);
    final sha = sum != null && sum.toLowerCase() == release.sha256;
    final pkg = info?.package == ownPackage;
    final build = info != null && info.versionCode == release.build && info.versionCode > _installed;
    final sig = info?.signer != null && own?.signer != null && info!.signer == own!.signer;
    final checks = {'sha': sha, 'pkg': pkg, 'build': build, 'sig': sig};
    if (sha && pkg && build && sig) return null;
    return (
      checks: checks,
      text: !sha
          ? 'The download does not match the release'
          : !pkg
              ? 'The file is not OpenDash'
              : !build
                  ? 'The file is not the version the release names'
                  : 'The file is not signed by OpenDash\'s key',
    );
  }

  Future<void> _verify(OtaRelease release, String path) async {
    final error = await _check(release, path);
    if (!ref.mounted) return;
    logEvent('selfupdate', 'verify', error?.checks ?? const {'sha': true, 'pkg': true, 'build': true, 'sig': true});
    if (error == null) {
      _path = path;
      state = state.copyWith(status: OtaStatus.ready, progress: 100);
      return;
    }
    await _platform.deleteFile(path);
    if (!ref.mounted) return;
    _path = null;
    state = state.copyWith(status: OtaStatus.failed, progress: 0, error: error.text);
  }

  // ---- install -----------------------------------------------------------

  /// Why "Install" may not go ahead now, or null: unlocked, in Park, proven
  /// stopped, no hyper or boost charge, no call, OpenDash's own screen in
  /// front.
  String? installRefusal() {
    final v = ref.read(vehicleProvider);
    if (v.locked) return 'locked';
    if (ref.read(ridingLockoutProvider)) return 'riding';
    if (!v.provenStopped) return v.speed > 0 ? 'moving' : (v.speedUntrustedReason ?? 'untrusted');
    if (v.vehicleState != VehicleState.parked) return 'not_parked';
    if (v.hyperCharging) return 'fast_charging';
    if (v.callActive) return 'call';
    if (!ref.read(ownScreenVisibleProvider)) return noPromptSurfaceReason;
    return null;
  }

  static String refusalText(String reason) => switch (reason) {
        'locked' => 'Unlock the scooter first',
        'not_parked' => 'Put the scooter in Park first',
        'moving' || 'riding' => 'Stop and park before installing',
        'fast_charging' => 'Wait for the fast charge to finish',
        'call' => 'Finish the call first',
        _ => 'Can\'t confirm the scooter is stopped',
      };

  /// "Install": the conditions, the passcode, the "Install apps" access,
  /// then Android's installer.
  void startInstall() {
    final release = state.release;
    final path = _path;
    if (state.status != OtaStatus.ready || release == null || path == null) return;
    final refusal = installRefusal();
    if (refusal != null) {
      logEvent('selfupdate', 'refused', {'reason': refusal});
      _toast(refusalText(refusal), warning: true);
      return;
    }
    ref.read(passcodeGateProvider.notifier).request(
          purpose: 'Enter passcode to install the update',
          onSuccess: () => ref.read(accessProvider.notifier).ask(
                title: 'Before OpenDash is updated',
                scope: 'opendash',
                accesses: const [Access.install],
                required: const {Access.install},
                then: () => _handOver(release, path),
              ),
        );
  }

  Future<void> _handOver(OtaRelease release, String path) async {
    // The scooter may have set off while the passcode was typed.
    final refusal = installRefusal();
    if (refusal != null) {
      logEvent('selfupdate', 'refused', {'reason': refusal});
      _toast(refusalText(refusal), warning: true);
      return;
    }
    logEvent('selfupdate', 'install_start', {'from': _installed, 'to': release.build});
    await AnalyticsLogger.instance.flush();
    state = state.copyWith(status: OtaStatus.installing, pendingBuild: release.build);
    final error = await _platform.selfUpdateInstall(path, release.build);
    if (!ref.mounted) return;
    if (error == null) {
      // Android's confirmation normally takes the screen, and coming back
      // from it is what reads the answer. If it never came up (the
      // installer failed first), nothing would: so the answer is also
      // looked for while this screen stays in front.
      _answerTimer?.cancel();
      _answerTimer = Timer.periodic(answerEvery, (_) {
        if (state.status != OtaStatus.installing) {
          _answerTimer?.cancel();
        } else if (ref.read(ownScreenVisibleProvider)) {
          _installerAnswer();
        }
      });
      return;
    }
    logEvent('selfupdate', 'install_result', {'status': 'refused', 'message': error});
    await _platform.updateRecordClear();
    if (!ref.mounted) return;
    state = state.copyWith(status: OtaStatus.failed, pendingBuild: 0, error: 'Android did not take the update');
  }

  /// The installer has answered and this build is still the one running.
  Future<void> _installerAnswer() async {
    final record = _platform.updateRecord();
    if (!ref.mounted || state.status != OtaStatus.installing) return;
    final status = record['status'];
    if (status == null) return;
    _answerTimer?.cancel();
    logEvent('selfupdate', 'install_result', {'status': status, 'message': record['message']});
    await _platform.updateRecordClear();
    if (!ref.mounted) return;
    final cancelled = status == installerAborted;
    state = state.copyWith(
      status: cancelled ? OtaStatus.ready : OtaStatus.failed,
      pendingBuild: 0,
      error: cancelled ? '' : 'Android could not install the update',
    );
    if (cancelled) _toast('Update not installed');
  }

  /// "Try again" after a failure: back to the release as it was found.
  void retry() {
    if (state.status != OtaStatus.failed) return;
    state = state.copyWith(status: OtaStatus.available, error: '', progress: 0);
  }
}

final otaScreenOpenProvider = NotifierProvider<OtaScreenOpen, bool>(OtaScreenOpen.new);

/// Same overlay rules as settings, except nothing closes the screen while
/// the update is with Android's installer.
class OtaScreenOpen extends Notifier<bool> {
  @override
  bool build() {
    autoCloseOverlay(ref, close);
    return false;
  }

  bool get _installing => ref.read(otaProvider).status == OtaStatus.installing;

  void open() {
    final v = ref.read(vehicleProvider);
    if (ref.read(ridingLockoutProvider) || v.locked) return;
    closeAllOverlays(ref, self: otaScreenOpenProvider, keepSettings: true);
    state = true;
    ref.read(firmwareProvider.notifier).screenOpened();
    ref.read(otaProvider.notifier).markSeen();
  }

  void close() {
    if (_installing) return;
    if (state) ref.read(firmwareProvider.notifier).screenClosed();
    state = false;
  }
}
