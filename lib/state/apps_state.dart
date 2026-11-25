import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/log_privacy.dart';
import '../models/app_catalog.dart';
import '../models/vehicle_data.dart';
import '../providers/mock_provider.dart';
import '../services/mock_platform_service.dart';
import '../services/platform_provider.dart';
import '../services/analytics_logger.dart';
import '../services/recovery_service.dart';
import 'dash_island.dart';
import 'passcode_gate.dart';
import 'prompt_surface.dart';
import 'riding_lockout.dart';
import 'safety_screen.dart';
import 'screen_state.dart';
import 'settings_state.dart';
import 'toast_state.dart';
import '../services/platform_service.dart';
import '../services/prefs_service.dart';

final appLauncherOpenProvider = NotifierProvider<AppLauncherOpen, bool>(AppLauncherOpen.new);

class AppLauncherOpen extends Notifier<bool> {
  @override
  bool build() {
    autoCloseOverlay(ref, close);
    return false;
  }

  void open() {
    final v = ref.read(vehicleProvider);
    if (ref.read(ridingLockoutProvider) || v.locked) return;
    closeAllOverlays(ref, self: appLauncherOpenProvider);
    state = true;
  }

  void close() => state = false;

  /// The swipe up from the dashboard's bottom edge. Refused as [open] is,
  /// riding or locked.
  void openBySwipe() {
    open();
    uiSwipe('apps-swipe-up', {'opened': state});
  }
}

final appManagerProvider =
    NotifierProvider<AppManagerNotifier, Map<String, AppStatus>>(AppManagerNotifier.new);

class AppManagerNotifier extends Notifier<Map<String, AppStatus>> {
  @override
  Map<String, AppStatus> build() {
    ref.onDispose(() => _recheck?.cancel());
    ref.listen(ridingLockoutProvider, (_, moving) => _returnIfMoving(moving));
    ref.listen(vehicleProvider.select(_criticalKinds), (prev, next) {
      final fresh = next.difference(prev ?? const {});
      if (fresh.isNotEmpty) _emergencyReturn(fresh);
    });
    ref.listen(safetyScreenProvider.select((s) => s.screen), (_, screen) {
      if (screen != null) _emergencyReturn({screen.name}, screen: true);
    }, fireImmediately: true);
    ref.listen(vehicleProvider.select((v) => v.locked), (_, locked) {
      if (locked) _lockReturn();
    });
    _refreshAll();
    return {for (final app in appCatalog) app.id: app.systemApp ? AppStatus.installed : AppStatus.notInstalled};
  }

  Future<void> _refreshAll() async {
    final platform = ref.read(platformServiceProvider);
    final updated = <String, AppStatus>{};
    for (final app in appCatalog) {
      if (app.comingSoon || app.systemApp) {
        updated[app.id] = app.systemApp ? AppStatus.installed : AppStatus.notInstalled;
        continue;
      }
      final installed = await tracedPlatformCall('isInstalled', () => platform.isInstalled(app.package), args: app.package, ok: (_) => true);
      // One question per catalog entry: the notifier can be gone before
      // the last answer is in.
      if (!ref.mounted) return;
      updated[app.id] = installed ? AppStatus.installed : AppStatus.notInstalled;
    }
    // A download keeps running when the Apps screen closes; reopening it must
    // not paint that app as "not installed" mid-download.
    for (final MapEntry(:key, :value) in state.entries) {
      if (value == AppStatus.queued || value == AppStatus.downloading || value == AppStatus.installing) updated[key] = value;
      if (value == AppStatus.ready) {
        if (updated[key] == AppStatus.installed) {
          _downloaded.remove(key);
          _notOffered.remove(key);
        } else if (_downloaded.containsKey(key)) {
          updated[key] = value;
        }
      }
      // A newer release found earlier is still newer.
      if (value == AppStatus.updateAvailable && updated[key] == AppStatus.installed) updated[key] = value;
    }
    state = updated;
    unawaited(_checkUpdates());
  }

  /// The processor types this head unit runs, most preferred first; empty
  /// where the platform does not say (the mock), which means the build that
  /// runs anywhere.
  List<String>? _abiList;
  Future<List<String>> _abis() async {
    final known = _abiList;
    if (known != null) return known;
    try {
      final abis = ref.read(platformServiceProvider).deviceInfo()['abis'] ?? '';
      return _abiList = [for (final a in abis.split(',')) if (a.isNotEmpty) a];
    } catch (_) {
      return const [];
    }
  }

  /// GitHub has had bad days: past this, it is treated as out of reach and
  /// the rider is told so, instead of a spinner that never ends.
  static const releaseAnswerWithin = Duration(seconds: 25);

  /// The newest release of [app] that carries its APK, or null when GitHub
  /// does not answer in time.
  Future<({String version, String asset})?> _newest(CatalogApp app, String asset) => ref
      .read(platformServiceProvider)
      .latestRelease(app.releaseUrl, asset: asset)
      .timeout(releaseAnswerWithin, onTimeout: () => null);

  int? _networkLoggedAtMicros;

  /// After a release lookup got no answer: what the head unit is connected
  /// to, which DNS servers it was given and where GitHub stops, in the log
  /// (`net.check`) without the rider having to run the check. Lookups away
  /// from Wi-Fi have failed on the name itself, and which servers
  /// had been asked was not recorded. At most once a minute.
  Future<void> _logNetwork() async {
    final now = AnalyticsLogger.instance.monoMicros;
    final last = _networkLoggedAtMicros;
    if (last != null && now - last < const Duration(minutes: 1).inMicroseconds) return;
    _networkLoggedAtMicros = now;
    try {
      final networks = await ref.read(platformServiceProvider).networkCheck();
      if (!ref.mounted) return;
      final v = ref.read(vehicleProvider);
      logEvent('net', 'check', {'auto': true, 'wifi': v.wifiConnected, 'signal': v.signalBars, 'networks': LogPrivacy.networks(networks)});
    } catch (e) {
      logEvent('net', 'check', {'auto': true, 'error': e.toString()});
    }
  }

  /// The newer release on offer for each app, by id.
  final Map<String, String> _newer = {};
  int? _updatesCheckedAtMicros;

  /// GitHub is asked at most this often: 60 unauthenticated requests an hour
  /// is its limit, and the answer does not change by the minute.
  static const updateCheckEvery = Duration(minutes: 30);
  static const retryCheckAfter = Duration(minutes: 5);

  /// Marks installed apps that have a newer release upstream. Asking costs
  /// one small request per installed app and downloads nothing, so it runs
  /// on whatever link the head unit has (it used to be Wi-Fi only, for no
  /// good reason). Nothing is updated until the rider
  /// taps Update. The first app GitHub does not answer for ends the round:
  /// on a link that cannot reach it, the rest would each wait out a timeout.
  Future<void> _checkUpdates() async {
    final now = AnalyticsLogger.instance.monoMicros;
    final last = _updatesCheckedAtMicros;
    if (last != null && now - last < updateCheckEvery.inMicroseconds) return;
    _updatesCheckedAtMicros = now;
    final platform = ref.read(platformServiceProvider);
    for (final app in appCatalog.where((a) => a.downloadable && a.pinned)) {
      if (!ref.mounted) return;
      if (state[app.id] != AppStatus.installed) continue;
      try {
        final latest = await _newest(app, app.assetFor(await _abis()));
        final installed = await platform.installedInfo(app.package);
        if (!ref.mounted) return;
        // No answer is not "nothing newer": ask again sooner, but not at
        // every return to the dashboard, which is when GitHub is least
        // likely to have changed its mind (its hourly limit, a dead link).
        if (latest == null) _updatesCheckedAtMicros = now - (updateCheckEvery - retryCheckAfter).inMicroseconds;
        final newer = latest != null && installed != null && !sameVersion(latest.version, installed.versionName);
        logEvent('apps', 'update_check', {
          'id': app.id,
          'latest': latest?.version,
          'installed': installed?.versionName,
          'available': newer,
          'wifi': ref.read(vehicleProvider).wifiConnected,
          'signal': ref.read(vehicleProvider).signalBars,
        });
        if (latest == null) break;
        if (!newer || state[app.id] != AppStatus.installed) continue;
        _newer[app.id] = latest.version;
        state = {...state, app.id: AppStatus.updateAvailable};
      } catch (e) {
        logEvent('apps', 'update_check', {'id': app.id, 'error': e.toString()});
      }
    }
  }

  /// A release tag against an installed version name: `v0.29.3` is 0.29.3,
  /// and a tag may carry more than the name does (`2026.11.11-39-android`).
  static bool sameVersion(String tag, String versionName) {
    if (versionName.isEmpty) return false;
    final t = _versionParts(tag.replaceFirst(RegExp(r'^[vV]\.?'), ''));
    final n = _versionParts(versionName);
    return t.numbers == n.numbers && t.pre == n.pre;
  }

  /// The numbers a version starts with, and its pre-release label if it has
  /// one. Any other label is the name of a build, not a version: Organic
  /// Maps tags `2026.11.11-39-android` and calls the app
  /// `2026.11.11-39-Web`, which was once offered as an update to itself. A pre-release label does count: an installed 4.0.0-beta2 is
  /// not the 4.0.0 release.
  static ({String numbers, String pre}) _versionParts(String v) {
    final numbers = RegExp(r'^[0-9]+(?:[.\-][0-9]+)*').stringMatch(v) ?? '';
    final pre = RegExp(r'(alpha|beta|rc|pre|dev)[.\-]?[0-9]*', caseSensitive: false).stringMatch(v.substring(numbers.length)) ?? '';
    return (numbers: numbers, pre: pre.toLowerCase());
  }

  /// The version [update] would fetch for [id], for the Apps screen.
  String? newerVersion(String id) => _newer[id];

  /// Fetches the newer release and hands it to Android's installer, once it
  /// is what an install has to be (the catalog's package, signed with the
  /// catalog's certificate), signed like the copy that is installed, and
  /// newer than it. Android checks the signer again itself.
  Future<void> update(CatalogApp app) async {
    final version = _newer[app.id];
    if (version == null || state[app.id] != AppStatus.updateAvailable) return;
    if (refuseUnlessStopped(ref, ref.read(vehicleProvider), 'app_update', 'Stop to update ${app.name}', vouched: noDataVouched(ref))) return;
    final platform = ref.read(platformServiceProvider);
    final toast = ref.read(toastProvider.notifier);
    void refuse(String reason, String message) {
      _jobs.remove(app.id);
      logEvent('apps', 'update_refused', {'id': app.id, 'version': version, 'reason': reason});
      state = {...state, app.id: AppStatus.updateAvailable};
      toast.show(message, type: ToastType.error);
    }

    final asset = app.assetFor(await _abis());
    final job = _jobs[app.id] = Object();
    bool cancelled() => _jobs[app.id] != job;
    state = {...state, app.id: AppStatus.queued};
    final path = await _inTurn(() async {
      if (cancelled()) return null;
      state = {...state, app.id: AppStatus.downloading};
      return tracedPlatformCall(
          'downloadFile', () => platform.downloadFile(app.releaseUrl, '${app.id}-update.apk', version: version, asset: asset),
          args: app.releaseUrl);
    });
    if (cancelled()) return;
    if (path == null) return refuse('download', '${app.name}: download failed');
    _jobs.remove(app.id);
    final refusal = await _refusal(app, path, version, 'update_verify');
    if (refusal != null) return refuse(refusal.$1, refusal.$2);
    final file = await platform.apkInfo(path);
    final installed = await platform.installedInfo(app.package);
    if (file == null || installed == null) return refuse('unreadable', "Couldn't check the ${app.name} update. Not installing");
    if (file.signer != installed.signer) {
      return refuse('signer', "The ${app.name} update isn't signed like the copy that is installed. Not installing");
    }
    if (file.versionCode <= installed.versionCode) {
      _newer.remove(app.id);
      state = {...state, app.id: AppStatus.installed};
      toast.show('${app.name} is already up to date');
      return;
    }
    await _installFrom(app, path, update: true);
  }

  Future<void> refresh() => _refreshAll();

  /// APKs already downloaded this session: a second tap (after the
  /// permission detour, or a cancelled installer) installs the same file
  /// instead of fetching 21 MB again (it was once downloaded three times).
  final Map<String, String> _downloaded = {};

  /// Waiting on Android's "Install unknown apps" switch for OpenDash.
  (CatalogApp, String)? _awaitingPermission;

  /// The system installer is up for these; the result is known on resume.
  final Set<String> _awaitingInstaller = {};

  Future<void> install(CatalogApp app) async {
    if (app.comingSoon) return;
    final current = state[app.id];
    if (current == AppStatus.queued || current == AppStatus.downloading || current == AppStatus.installing) return;
    final toast = ref.read(toastProvider.notifier);

    // Nothing reaches the
    // head unit's installer unless it is the catalog's package, signed with
    // the certificate the catalog names for it. Which release is the
    // newest is GitHub's to say; who signed it is not.
    if (!app.pinned) {
      logEvent('apps', 'install_refused', {'id': app.id, 'reason': 'unpinned'});
      toast.show('${app.name} is unverified: no signing key on record, not installing', type: ToastType.warning);
      return;
    }

    final had = _downloaded[app.id];
    if (had != null) {
      await _installFrom(app, had);
      return;
    }
    final job = _jobs[app.id] = Object();
    state = {...state, app.id: AppStatus.queued};
    final path = await _inTurn(() => _fetch(app, job));
    if (path == null) return;
    _jobs.remove(app.id);
    _downloaded[app.id] = path;
    await _installFrom(app, path, auto: true);
  }

  /// The download each app is queued for or busy with. [cancel] takes the
  /// entry away, and a download that finds its own entry gone stops where
  /// it is and says nothing: the tile already shows what the rider chose.
  final Map<String, Object> _jobs = {};

  /// Takes [app] out of the queue, or stops its download.
  void cancel(CatalogApp app) {
    final was = state[app.id];
    if (was != AppStatus.queued && was != AppStatus.downloading) return;
    _jobs.remove(app.id);
    final update = _newer.containsKey(app.id);
    logEvent('apps', 'download_cancelled', {'id': app.id, 'was': was!.name, 'update': update});
    state = {...state, app.id: update ? AppStatus.updateAvailable : AppStatus.notInstalled};
    if (was == AppStatus.downloading) {
      unawaited(ref.read(platformServiceProvider).cancelDownload(update ? '${app.id}-update.apk' : '${app.id}.apk'));
    }
  }

  /// Downloads run one at a time, in the order they were asked for: a
  /// catalog's worth tapped in a row would otherwise share the link and the
  /// head unit's storage all at once.
  Future<void> _downloads = Future.value();
  /// One download at a time, OpenDash's own update included.
  Future<T> inTurn<T>(Future<T> Function() job) => _inTurn(job);

  Future<T> _inTurn<T>(Future<T> Function() job) {
    final done = Completer<void>();
    final before = _downloads;
    _downloads = done.future;
    return before.then((_) => job()).whenComplete(done.complete);
  }

  /// The newest release of [app], downloaded and checked: the file's path,
  /// or null when there is nothing to install (the rider has been told).
  Future<String?> _fetch(CatalogApp app, Object job) async {
    final platform = ref.read(platformServiceProvider);
    final toast = ref.read(toastProvider.notifier);
    bool cancelled() => _jobs[app.id] != job;
    if (cancelled()) return null;
    {
      state = {...state, app.id: AppStatus.downloading};
      String? failed(String reason, String message) {
        _jobs.remove(app.id);
        final v = ref.read(vehicleProvider);
        logEvent('apps', 'install_refused', {'id': app.id, 'reason': reason, 'wifi': v.wifiConnected, 'signal': v.signalBars});
        if (reason == 'release') unawaited(_logNetwork());
        state = {...state, app.id: AppStatus.notInstalled};
        toast.show(message, type: ToastType.error);
        return null;
      }

      final asset = app.assetFor(await _abis());
      final latest = await tracedPlatformCall('latestRelease', () => _newest(app, asset), args: app.releaseUrl, ok: (r) => r != null);
      if (cancelled()) return null;
      if (latest == null) return failed('release', "Couldn't find ${app.name} to download. Check the connection");
      final path = await tracedPlatformCall(
          'downloadFile', () => platform.downloadFile(app.releaseUrl, '${app.id}.apk', version: latest.version, asset: asset),
          args: app.releaseUrl);
      if (cancelled()) return null;
      if (path == null) return failed('download', '${app.name}: download failed');
      final refusal = await _refusal(app, path, latest.version, 'install_verify');
      if (cancelled()) return null;
      if (refusal != null) return failed(refusal.$1, refusal.$2);
      return path;
    }
  }

  /// Downloaded, and Android's installer has not been opened for them yet:
  /// offered, one at a time, when the dashboard is next back in front.
  final Set<String> _notOffered = {};

  /// Why Android's installer may not take the screen right now, or null.
  /// It covers the whole display, so: not on the move, not over the lock
  /// screen, not over another app or another installer. One that opens by
  /// itself ([auto], a download that just finished) also waits for the
  /// scooter to be parked: stopped at a light is not the time.
  String? _installerHeld({required bool auto}) {
    final v = ref.read(vehicleProvider);
    if (ref.read(ridingLockoutProvider)) return 'riding';
    if (v.locked) return 'locked';
    if (_outside != null || _awaitingPermission != null || !ref.read(ownScreenVisibleProvider)) return 'busy';
    if (auto && v.vehicleState != VehicleState.parked && v.vehicleState != VehicleState.charging) return 'not_parked';
    return null;
  }

  /// The next downloaded app whose installer is still owed, if it may open.
  Future<void> _offerNext() async {
    for (final id in _notOffered.toList()) {
      final path = _downloaded[id];
      if (path == null || state[id] != AppStatus.ready) {
        _notOffered.remove(id);
        continue;
      }
      await _installFrom(appCatalog.firstWhere((a) => a.id == id), path, auto: true, quiet: true);
      return;
    }
  }

  /// Why the file at [path] may not be installed as [app], or null when it
  /// may: it has to be an APK, the catalog's package, and signed with the
  /// catalog's certificate. Logged as [event] either way.
  Future<(String, String)?> _refusal(CatalogApp app, String path, String version, String event) async {
    final file = await ref.read(platformServiceProvider).apkInfo(path);
    logEvent('apps', event, {
      'id': app.id,
      'version': version,
      'package': file?.package == app.package,
      'signer': file?.signer != null && file?.signer == app.signer,
    });
    if (file == null) return ('unreadable', "Couldn't check the ${app.name} download. Not installing");
    if (file.package != app.package) return ('package', "That download isn't ${app.name}. Not installing");
    if (file.signer == null || file.signer != app.signer) {
      return ('signer', "The ${app.name} download isn't signed by its developer's key. Not installing");
    }
    return null;
  }

  /// Hands [path] to Android's installer, if it may take the screen now
  /// ([_installerHeld]). True when the installer (or the permission page
  /// before it) was opened. Held, a first install stays on the tile as
  /// "Ready to install" and an update as "Update": the next tap uses the
  /// same file. It used to wait in a loop and open the installer the
  /// moment the scooter stopped, wherever that was.
  Future<bool> _installFrom(CatalogApp app, String path, {bool auto = false, bool update = false, bool quiet = false}) async {
    final platform = ref.read(platformServiceProvider);
    final toast = ref.read(toastProvider.notifier);
    final waiting = update ? AppStatus.updateAvailable : AppStatus.ready;
    final held = _installerHeld(auto: auto);
    if (held != null) {
      logEvent('apps', 'install_held', {'id': app.id, 'reason': held, 'auto': auto});
      state = {...state, app.id: waiting};
      if (auto && !update) _notOffered.add(app.id);
      // Behind another installer it is simply next: nothing to tell.
      if (!quiet && held != 'busy') {
        toast.show(auto
            ? '${app.name} is downloaded. ${update ? 'Tap Update' : 'Tap Install'} when parked'
            : 'Stop to install ${app.name}');
      }
      return false;
    }
    _notOffered.remove(app.id);
    state = {...state, app.id: AppStatus.installing};
    if (!await tracedPlatformCall('canInstallApks', platform.canInstallApks, ok: (_) => true)) {
      _awaitingPermission = (app, path);
      state = {...state, app.id: waiting};
      toast.show('Allow OpenDash to install apps, then come back');
      await tracedPlatformCall('openInstallPermissionSettings', platform.openInstallPermissionSettings);
      _outside = _systemFlow('system-install-permission', 'Install permission');
      return true;
    }
    final ok = await tracedPlatformCall('installApk', () => platform.installApk(path), args: path);
    if (!ok) {
      _downloaded.remove(app.id);
      state = {...state, app.id: update ? AppStatus.updateAvailable : AppStatus.notInstalled};
      toast.show('${app.name}: installation failed', type: ToastType.error);
      return false;
    }
    // On the head unit this only opens the system installer; the rider
    // still has to confirm. The answer comes on resume. The island's
    // "‹ OpenDash" is the way back if the installer or its "unknown apps"
    // detour strands the rider.
    _awaitingInstaller.add(app.id);
    _outside = _systemFlow('system-installer', 'Installer');
    // Where installing is instant (the mock). An update's package is
    // installed already: its answer is the version, read on the way back.
    if (!update && platform.isInstalled(app.package)) await onResume();
    return true;
  }

  Timer? _recheck;

  /// The dashboard is back in front: from the permission screen, the system
  /// installer, or anything else. Picks up where an install left off and
  /// re-reads what is installed, so the button doesn't stay on "Install"
  /// until the Apps screen is reopened.
  Future<void> onResume() async {
    final platform = ref.read(platformServiceProvider);
    final toast = ref.read(toastProvider.notifier);
    final outside = _outside;
    if (outside != null) {
      _outside = null;
      logEvent('apps', 'returned', {'id': outside.id});
      // On return from the stock dashboard, force-
      // stop HHMIC and re-attach HHMIS at once. Otherwise HHMIC keeps
      // the callback slot and the first 3 s of our own data goes to it;
      // the rider sees a frozen cluster while OpenDash reconnects.
      if (outside.id == CatalogApp.stockDashboardId) {
        unawaited(recoveryService.forceStopStockDashboard());
        ref.read(vehicleProvider.notifier).reattachNow();
      }
    }
    final musicWait = _awaitingMusicAccess;
    if (musicWait != null) {
      _awaitingMusicAccess = null;
      logEvent('apps', 'music_access', {'stage': 'answered', 'granted': platform.hasNotificationAccess()});
      await _openWithWayBack(musicWait.$1, musicWait.$2);
      return;
    }
    final overlayWait = _awaitingOverlay;
    if (overlayWait != null) {
      _awaitingOverlay = null;
      if (platform.canDrawOverlays()) {
        await _openWithWayBack(overlayWait.$1, overlayWait.$2);
        return;
      }
      toast.show('Not opening ${overlayWait.$1.name}: without the permission there is no way back', type: ToastType.warning);
    }
    final waiting = _awaitingPermission;
    if (waiting != null) {
      _awaitingPermission = null;
      if (platform.canInstallApks()) {
        await _installFrom(waiting.$1, waiting.$2);
        return;
      }
      toast.show("OpenDash isn't allowed to install apps", type: ToastType.warning);
    }
    for (final id in _awaitingInstaller.toList()) {
      final app = appCatalog.firstWhere((a) => a.id == id);
      final installed = await tracedPlatformCall('isInstalled', () => platform.isInstalled(app.package), args: app.package, ok: (_) => true);
      _awaitingInstaller.remove(id);
      // Not installed: backed out of, or still installing behind the
      // dashboard (setting off closes the installer's page, not the
      // install). The file is kept, so the tile offers it again, and what
      // is installed is read once more shortly.
      // Back from an update: whether it went in is read from the version
      // now installed. (GitHub used to be asked again for every app after
      // each installer; seven installs in a row made 34 such checks in
      // twelve minutes and ran into its hourly limit.)
      final newer = _newer[id];
      if (newer != null) {
        final now = await platform.installedInfo(app.package);
        final updated = now != null && sameVersion(newer, now.versionName);
        if (updated) _newer.remove(id);
        state = {...state, id: updated ? AppStatus.installed : AppStatus.updateAvailable};
        if (updated) toast.show('${app.name} updated');
        continue;
      }
      state = {
        ...state,
        id: installed
            ? AppStatus.installed
            : _downloaded.containsKey(id)
                ? AppStatus.ready
                : AppStatus.notInstalled,
      };
      if (installed) {
        _downloaded.remove(id);
        toast.show('${app.name} installed');
      } else {
        _recheck?.cancel();
        _recheck = Timer(const Duration(seconds: 20), () {
          if (ref.mounted) unawaited(_refreshAll());
        });
      }
    }
    await _refreshAll();
    await _offerNext();
  }


  /// One of Android's own pages (hotspot, notification access), behind the
  /// passcode like Android Settings and only at a standstill. It opens in
  /// our own task: its back arrow returns here, and the island's
  /// "‹ OpenDash" is over it where Android lets it show.
  void openSystemPage(String page, String name) {
    if (refuseUnlessStopped(ref, ref.read(vehicleProvider), 'system_page', 'Stop to open $name', vouched: noDataVouched(ref))) return;
    ref.read(passcodeGateProvider.notifier).request(
      purpose: 'Enter passcode to open $name',
      onSuccess: () async {
        final platform = ref.read(platformServiceProvider);
        final (method, open) = switch (page) {
          'hotspot' => ('openHotspotSettings', platform.openHotspotSettings),
          'usage_access' => ('openUsageAccessSettings', platform.openUsageAccessSettings),
          _ => ('openNotificationAccessSettings', platform.openNotificationAccessSettings),
        };
        final ok = await tracedPlatformCall(method, open);
        logEvent('apps', 'system_page', {'page': page, 'opened': ok});
        if (!ok) {
          ref.read(toastProvider.notifier).show('Could not open $name', type: ToastType.error);
          return;
        }
        _outside = _systemFlow('system-$page', name);
      },
    );
  }

  /// Android's Wi-Fi panel, from the status bar's Wi-Fi icon or Settings →
  /// Connectivity. No passcode: unlike Android Settings it offers only the
  /// network list, so it cannot change the home app or reset anything.
  Future<void> openWifiPanel(String from) async {
    if (refuseUnlessStopped(ref, ref.read(vehicleProvider), 'wifi_panel', 'Stop to choose a Wi-Fi network', vouched: noDataVouched(ref))) return;
    final ok = await tracedPlatformCall('openWifiPanel', ref.read(platformServiceProvider).openWifiPanel);
    if (!ref.mounted) return;
    logEvent('apps', 'system_page', {'page': 'wifi_panel', 'from': from, 'opened': ok});
    if (!ok) {
      ref.read(toastProvider.notifier).show('Could not open Wi-Fi', type: ToastType.error);
      return;
    }
    _outside = _systemFlow('system-wifi', 'Wi-Fi');
  }

  /// One of Android's permission pages, opened from the access prompt: in
  /// front like any system page, with the island's way back over it.
  Future<bool> openAccessPage(String id, String name, Future<bool> Function() open) async {
    final ok = await tracedPlatformCall('openAccessPage', open);
    logEvent('apps', 'system_page', {'page': 'access_$id', 'opened': ok});
    if (ok) _outside = _systemFlow('system-access-$id', name);
    return ok;
  }

  /// The app opened from Apps that is in front right now.
  CatalogApp? get _outside => ref.read(outsideAppProvider);
  set _outside(CatalogApp? app) {
    _lockReturned = false;
    ref.read(outsideAppProvider.notifier).set(app);
  }

  /// The lock already asked for the dashboard; an alarm raised by the same
  /// lock does not ask again.
  bool _lockReturned = false;

  /// One of Android's own screens in front (installer, a permission page,
  /// hotspot): no catalog entry, and the island over it is only the way back.
  static CatalogApp _systemFlow(String id, String name) => CatalogApp(
        id: id,
        name: name,
        package: '',
        description: '',
        releaseUrl: '',
        license: '',
        systemApp: true,
      );

  /// Waiting on the notification-access page before opening this one.
  (CatalogApp, Future<bool> Function())? _awaitingMusicAccess;
  bool _musicAsked = false;

  /// The access prompt has asked about projection music: the page is not
  /// opened by itself at the next projection launch as well.
  void musicAccessPutToRider() => _musicAsked = true;

  /// Waiting on "Display over other apps" before opening this one.
  (CatalogApp, Future<bool> Function())? _awaitingOverlay;

  Future<void> launch(CatalogApp app) async {
    if (app.comingSoon) {
      ref.read(toastProvider.notifier).show('Coming soon');
      return;
    }
    final platform = ref.read(platformServiceProvider);
    Future<bool> start() async {
      if (platform is MockPlatformService) {
        ref.read(mockAppProvider.notifier).show(app);
        ref.read(appLauncherOpenProvider.notifier).close();
        return true;
      }
      return tracedPlatformCall('launchApp', () => platform.launchApp(app.package), args: app.package);
    }

    if (app.passcode) {
      ref.read(passcodeGateProvider.notifier).request(
        purpose: 'Enter passcode to open ${app.name}',
        onSuccess: () => _openWithWayBack(app, start),
      );
      return;
    }
    await _openWithWayBack(app, start);
  }

  /// The stock dashboard opens through the recovery shell, not a launch
  /// intent. [restart] force-stops it first (Recovery panel).
  Future<void> openStock(CatalogApp stock, {bool restart = false}) => _openWithWayBack(
      stock, restart ? recoveryService.restartStockDashboard : recoveryService.launchStockDashboard);

  /// Recovery / service-mode launches do their own
  /// `platform.launchApp` so the install check / toast stays uniform;
  /// after a successful launch they call these helpers to register
  /// `_outside` and raise the return pill.
  Future<void> trackOutsideStock() async {
    final stock = appCatalog.firstWhere((a) => a.id == CatalogApp.stockDashboardId);
    _outside = stock;
    logEvent('apps', 'opened', {'id': stock.id, 'auto_return': !stock.projection, 'via': 'recovery'});
  }

  Future<void> trackOutsidePackage(String id, String name, String package) async {
    _outside = CatalogApp(
      id: id,
      name: name,
      package: package,
      description: '',
      releaseUrl: '',
      license: '',
      systemApp: true,
    );
    logEvent('apps', 'opened', {'id': id, 'auto_return': true, 'via': 'service_mode'});
  }

  /// The head unit has no Back or Home button: without the island over it,
  /// an app opened from here can only be left by a restart. So the
  /// permission comes first, then the app; the island follows by itself.
  Future<void> _openWithWayBack(CatalogApp app, Future<bool> Function() start) async {
    final platform = ref.read(platformServiceProvider);
    final toast = ref.read(toastProvider.notifier);
    // Projection is the one thing allowed on the move (resumeProjection).
    if (!app.projection &&
        refuseUnlessStopped(ref, ref.read(vehicleProvider), 'app_launch', 'Stop to open ${app.name}', vouched: noDataVouched(ref))) {
      return;
    }
    if (!await tracedPlatformCall('canDrawOverlays', platform.canDrawOverlays, ok: (_) => true)) {
      _awaitingOverlay = (app, start);
      toast.show('Allow OpenDash to display over other apps, so there is a way back from ${app.name}');
      await tracedPlatformCall('openOverlayPermissionSettings', platform.openOverlayPermissionSettings);
      return;
    }
    // Once, the first time a projection app is opened at a standstill: the
    // access that lets the dashboard show what the phone is playing. A
    // button in Settings alone is easy never to find. The app opens on the
    // way back whatever the rider chose.
    if (app.projection &&
        !_musicAsked &&
        !PrefsService.getBool(PrefsKeys.projectionMusicAsked, false) &&
        ref.read(vehicleProvider).provenStopped &&
        !platform.hasNotificationAccess()) {
      _musicAsked = true;
      PrefsService.setBool(PrefsKeys.projectionMusicAsked, true);
      if (await tracedPlatformCall('openNotificationAccessSettings', platform.openNotificationAccessSettings)) {
        _awaitingMusicAccess = (app, start);
        _outside = _systemFlow('system-notification_access', 'Music access');
        logEvent('apps', 'music_access', {'stage': 'asked', 'id': app.id});
        toast.show('Allow "OpenDash: music from CarPlay and Android Auto" to see ${app.name}\'s music on the dashboard, then come back');
        return;
      }
    }
    if (!await start()) {
      toast.show('Could not launch ${app.name}', type: ToastType.error);
      return;
    }
    _outside = app;
    ref.read(projectionResumeProvider.notifier).clear();
    logEvent('apps', 'opened', {'id': app.id, 'auto_return': !app.projection});
    // Coming back lands on the dashboard, not on the Apps screen the rider
    // left from.
    ref.read(appLauncherOpenProvider.notifier).close();
  }

  /// Accident and tamper have their own screens, which bring the dashboard
  /// back themselves.
  static Set<String> _criticalKinds(VehicleData v) => {
        for (final a in v.alerts)
          if (a.priority == AlertPriority.critical && a.kind != AlertKind.accidentDetected && a.kind != AlertKind.tamper)
            a.kind.name,
      };

  /// Android Auto and CarPlay stay up while riding, but a red alert (side
  /// stand down, fault, cutoff, overheating, critical battery) shows only
  /// on the dashboard. Once per newly raised alert, so a lasting fault does
  /// not keep pulling the rider out of navigation; the dashboard then
  /// offers the way back to the projection app.
  ///
  /// An emergency [screen] (accident, fall, alarm) takes the display from
  /// any app, not only projection, and from one this dashboard did not
  /// open (the system installer, a permission page).
  ///
  /// With the island up, a critical alert is shown there instead, and this
  /// runs only if the island does not confirm it drew it (thermal runaway
  /// always comes here).
  void _emergencyReturn(Set<String> kinds, {bool screen = false, bool islandFailed = false}) {
    final app = _outside;
    if (!screen && (app == null || !app.projection)) return;
    if (!screen &&
        !islandFailed &&
        ref.read(dashIslandProvider.notifier).hostCritical(kinds, (_) => _emergencyReturn(kinds, islandFailed: true))) {
      return;
    }
    logEvent('apps', 'emergency_return', {'id': app?.id, 'alerts': kinds.toList(), 'screen': screen});
    _offerWayBack(app);
    if (!_lockReturned) _bringBack();
  }

  /// A prompt the rider has to answer (the auto-park countdown) takes the
  /// screen from whatever is in front, phone projection included.
  void returnForPrompt(String prompt) {
    final app = _outside;
    logEvent('apps', 'prompt_return', {'id': app?.id, 'prompt': prompt});
    _offerWayBack(app);
    _bringBack();
  }

  /// The scooter locked with another app in front. The lock screen is
  /// OpenDash's own, so that app would otherwise stay usable on a locked
  /// scooter (seen behind CarPlay).
  void _lockReturn() {
    final app = _outside;
    // An alarm screen has already asked.
    if (app == null || ref.read(safetyScreenProvider).screen != null) return;
    logEvent('apps', 'lock_return', {'id': app.id});
    _lockReturned = true;
    _bringBack();
  }

  /// "‹ OpenDash" on the island. Leaving a projection app this way keeps
  /// the "Back to …" button on the dashboard, as an emergency return does.
  void returnFromIsland() {
    final app = _outside;
    _offerWayBack(app);
    _bringBack();
  }

  /// Leaves the dashboard's "← name" button for [app], the way back to it.
  /// It began as the way back to Android Auto and CarPlay after an alert;
  /// now any app opened from Apps gets one (the browser or maps left for a
  /// moment should be as easy to return to). Android's
  /// own pages and the stock dashboard do not: they are not places to
  /// return to.
  void _offerWayBack(CatalogApp? app) {
    if (app == null || app.id == CatalogApp.stockDashboardId || !appCatalog.contains(app)) return;
    ref.read(projectionResumeProvider.notifier).offer(app);
  }

  void _bringBack() {
    final platform = ref.read(platformServiceProvider);
    tracedPlatformCall('bringToFront', platform.bringToFront).catchError((Object _) => false);
    // The mock has no real app in front, only the mock-app sheet.
    if (platform is MockPlatformService) ref.read(mockAppProvider.notifier).close();
  }

  /// The dashboard's "Back to …" button: projection apps may reopen while
  /// riding (Apps itself is closed then).
  Future<void> resumeProjection() async {
    final app = ref.read(projectionResumeProvider);
    if (app == null) return;
    ref.read(projectionResumeProvider.notifier).clear();
    uiTap('resume-projection', {'id': app.id});
    await launch(app);
  }

  /// Moving off (or losing a trustworthy speed) with anything but phone
  /// projection in front brings the dashboard back: the speedometer and
  /// warnings must be visible on the move. Once per lockout: it follows the
  /// lockout engaging, and nothing can be opened again while it is on.
  ///
  /// The stock dashboard is the exception when the speed is only unknown.
  /// It takes HHMIS's one callback slot, so our data freezes the moment it
  /// opens and stays frozen; it is a dashboard itself, and pulling it back
  /// would undo what the rider just asked for.
  void _returnIfMoving(bool moving) {
    final app = _outside;
    if (!moving || app == null || app.projection) return;
    final reason = ref.read(vehicleProvider).speed > 0 ? 'moving' : 'unknown';
    if (reason == 'unknown' && app.id == CatalogApp.stockDashboardId) {
      logEvent('apps', 'auto_return_skipped', {'id': app.id, 'reason': 'stock_holds_feed'});
      return;
    }
    logEvent('apps', 'auto_return', {'id': app.id, 'reason': reason});
    _offerWayBack(app);
    _bringBack();
  }

}

final outsideAppProvider = NotifierProvider<OutsideApp, CatalogApp?>(OutsideApp.new);

/// The app opened from Apps that is in front, for the island.
class OutsideApp extends Notifier<CatalogApp?> {
  @override
  CatalogApp? build() => null;

  void set(CatalogApp? app) => state = app;
}

final projectionResumeProvider = NotifierProvider<ProjectionResume, CatalogApp?>(ProjectionResume.new);

/// The app the rider was taken out of, or left by the island's
/// "‹ OpenDash", until they go back to it, swipe the button away, or the
/// scooter is locked. For phone projection, which is for the ride, parking
/// ends it too; any other app is used parked, so parking leaves it.
class ProjectionResume extends Notifier<CatalogApp?> {
  @override
  CatalogApp? build() {
    ref.listen(vehicleProvider.select((v) => (v.locked, v.vehicleState == VehicleState.parked)), (_, now) {
      if (now.$1 || (now.$2 && state?.projection == true)) clear();
    });
    return null;
  }

  void offer(CatalogApp app) => state = app;
  void clear() => state = null;
}

final mockAppProvider = NotifierProvider<MockAppNotifier, CatalogApp?>(MockAppNotifier.new);

class MockAppNotifier extends Notifier<CatalogApp?> {
  @override
  CatalogApp? build() {
    ref.listen(vehicleProvider.select((v) => (v.isCharging, v.locked)), (_, _) => close());
    ref.listen(sessionProvider, (_, _) => close());
    return null;
  }

  void show(CatalogApp app) => state = app;
  void close() => state = null;
}
