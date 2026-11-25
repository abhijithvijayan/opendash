import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vehicle_data.dart';
import '../providers/mock_provider.dart';
import '../services/analytics_logger.dart';
import '../services/platform_provider.dart';
import '../services/prefs_service.dart';
import '../services/trusted_clock.dart';
import 'crash_recovery.dart';
import '../models/app_catalog.dart';
import 'ota_state.dart';
import 'passcode_gate.dart';
import 'prompt_surface.dart';
import 'riding_lockout.dart';
import 'toast_state.dart';

/// What the rider chose for scooter firmware updates. In neither mode does
/// OpenDash download, install or acknowledge one; "ask" only tells the
/// rider that one is waiting and offers the way to the stock dashboard.
enum FirmwareMode { off, ask }

/// The acknowledgement the rider reads before the stock dashboard opens for
/// a firmware update.
abstract final class FirmwareAck {
  static String title(String version) => 'Scooter firmware update $version';

  static const intro =
      'This update comes from Ola, not from OpenDash. OpenDash does not install it. If you continue, the stock dashboard opens and you download and install the update there.';

  static const before = 'Before you continue:';

  /// Each point as (the bold lead, the rest).
  static List<(String, String)> points(String headUnit) => [
        (
          'The update replaces the scooter\'s own software.',
          ' That can include the vehicle service OpenDash talks to. OpenDash was built for the version on this scooter now ($headUnit). After the update it may show wrong values, or not work at all, until OpenDash itself is updated.',
        ),
        (
          'It may switch the home screen back to the stock dashboard, or remove OpenDash.',
          ' Ola\'s update is not expected to, but it is able to.',
        ),
        (
          'There may be no way back.',
          ' The scooter cannot be returned to the old firmware from here. If OpenDash stops working, the stock dashboard is what you will have.',
        ),
        (
          'The scooter restarts during the install',
          ' and can\'t be ridden until it finishes. Park it somewhere it can stay, with at least 30 % charge.',
        ),
        (
          'Firmware updates stay off in OpenDash afterwards.',
          ' Check Settings → Updates when the scooter is back.',
        ),
      ];

  static const notNow = 'Not now';
  static const open = 'Open the stock dashboard';

  static const blockOn =
      'OTA Shield is blocking firmware updates, so the stock dashboard can\'t download this. Turn its block off in OTA Shield, then come back.';
}

/// What an update callback said. Release notes are held in memory for the
/// hand-over screen only: never stored, never logged.
class FirmwareNotice {
  const FirmwareNotice({
    required this.kind,
    this.version = '',
    this.size = '',
    this.button,
    this.reason,
    this.state,
    this.progress,
    this.atMs,
    this.notes = const [],
  });

  /// `available`, `download_status`, `download_done`, `retry_failed`,
  /// `install_progress`, `install_failed`, `up_to_date`, `first_boot`.
  final String kind;
  final String version;
  final String size;

  /// Whether HOTA would let a dashboard start the download or install now.
  final bool? button;

  /// `DownloadReason` (for `available`) or `InstallationReason` (for
  /// `download_done`) ordinal: why the button is on or off.
  final int? reason;

  /// `OtaStates` ordinal.
  final int? state;
  final int? progress;

  /// When it arrived, if the clock could be trusted then.
  final int? atMs;
  final List<String> notes;

  /// An update exists that has not been installed.
  bool get waiting => switch (kind) {
        'available' || 'download_status' || 'download_done' || 'retry_failed' || 'install_failed' => true,
        _ => false,
      };

  Map<String, Object?> toJson() => {
        'kind': kind,
        'version': version,
        'size': size,
        'button': button,
        'reason': reason,
        'state': state,
        'at': atMs,
      };

  static FirmwareNotice? fromJson(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is! Map || m['kind'] is! String) return null;
      return FirmwareNotice(
        kind: m['kind'] as String,
        version: m['version'] is String ? m['version'] as String : '',
        size: m['size'] is String ? m['size'] as String : '',
        button: m['button'] is bool ? m['button'] as bool : null,
        reason: m['reason'] is int ? m['reason'] as int : null,
        state: m['state'] is int ? m['state'] as int : null,
        atMs: m['at'] is int ? m['at'] as int : null,
      );
    } on FormatException {
      return null;
    }
  }

  /// Why HOTA has the stock dashboard's button off, in the rider's words.
  String? get buttonReason => switch (kind) {
        'available' => switch (reason) {
            1 => 'Wi-Fi only',
            2 => 'No connection',
            3 => 'Needs Wi-Fi',
            4 => 'Charge too low to download',
            _ => null,
          },
        'download_done' => switch (reason) {
            1 => 'Charge too low to install',
            2 => 'The scooter is not in a state to install',
            _ => null,
          },
        _ => null,
      };
}

/// A firmware version that differs from the one stored at the last start.
class FirmwareChange {
  const FirmwareChange({required this.headUnit, this.from = '', this.to = '', this.atMs, this.answered = false});

  /// The head unit (hardware-info index 3) or MoveOS changed: the part
  /// OpenDash talks to. False: ECU versions only.
  final bool headUnit;
  final String from;
  final String to;
  final int? atMs;

  /// The rider has answered the one-time notice.
  final bool answered;

  Map<String, Object?> toJson() => {'head': headUnit, 'from': from, 'to': to, 'at': atMs, 'answered': answered};

  static FirmwareChange? fromJson(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      return FirmwareChange(
        headUnit: m['head'] == true,
        from: m['from'] is String ? m['from'] as String : '',
        to: m['to'] is String ? m['to'] as String : '',
        atMs: m['at'] is int ? m['at'] as int : null,
        answered: m['answered'] == true,
      );
    } on FormatException {
      return null;
    }
  }
}

class FirmwareState {
  const FirmwareState({
    this.mode = FirmwareMode.off,
    this.restored = false,
    this.autoDownloadFirst,
    this.notice,
    this.seenVersion = '',
    this.installing = false,
    this.installProgress = 0,
    this.change,
    this.ackOpen = false,
    this.ackBlocked = false,
    this.subscribed,
  });

  final FirmwareMode mode;

  /// "Restore stock update settings" was used: OpenDash leaves the stock
  /// auto-download setting alone and, from the next start, does not watch
  /// the update callbacks.
  final bool restored;

  /// The stock auto-download value first seen on this install.
  final int? autoDownloadFirst;

  /// The last update callback that says whether an update exists.
  final FirmwareNotice? notice;

  /// The version whose notice the rider has already seen on the screen.
  final String seenVersion;
  final bool installing;
  final int installProgress;
  final FirmwareChange? change;

  /// The acknowledgement is on screen (after the passcode).
  final bool ackOpen;

  /// "Open the stock dashboard" was refused because OTA Shield is blocking.
  final bool ackBlocked;
  final bool? subscribed;

  bool get noticeWaiting => notice?.waiting ?? false;

  /// The status-bar bell and the dot on the Updates row. Lit for a waiting
  /// notice in Ask me mode until the rider has seen that version.
  bool get bell => mode == FirmwareMode.ask && noticeWaiting && notice!.version != seenVersion;

  /// The one-time notice after a head-unit firmware change is owed.
  bool get changeNoticeOwed => change != null && change!.headUnit && !change!.answered;

  FirmwareState copyWith({
    FirmwareMode? mode,
    bool? restored,
    int? Function()? autoDownloadFirst,
    FirmwareNotice? Function()? notice,
    String? seenVersion,
    bool? installing,
    int? installProgress,
    FirmwareChange? Function()? change,
    bool? ackOpen,
    bool? ackBlocked,
    bool? Function()? subscribed,
  }) =>
      FirmwareState(
        mode: mode ?? this.mode,
        restored: restored ?? this.restored,
        autoDownloadFirst: autoDownloadFirst != null ? autoDownloadFirst() : this.autoDownloadFirst,
        notice: notice != null ? notice() : this.notice,
        seenVersion: seenVersion ?? this.seenVersion,
        installing: installing ?? this.installing,
        installProgress: installProgress ?? this.installProgress,
        change: change != null ? change() : this.change,
        ackOpen: ackOpen ?? this.ackOpen,
        ackBlocked: ackBlocked ?? this.ackBlocked,
        subscribed: subscribed != null ? subscribed() : this.subscribed,
      );
}

final firmwareProvider = NotifierProvider<FirmwareNotifier, FirmwareState>(FirmwareNotifier.new);

/// The status-bar bell: firmware news, or (mock build only) the simulated
/// OpenDash update. On the scooter the vehicle notifier ignores
/// `setNotification`, so nothing simulated can light it.
final bellProvider = Provider<bool>((ref) {
  final firmware = ref.watch(firmwareProvider.select((f) => f.bell));
  final own = ref.watch(otaProvider.select((o) => o.bell));
  return firmware || own || ref.watch(vehicleProvider.select((v) => v.hasNotification));
});

/// Scooter firmware control: the soft layer (the stock auto-download
/// setting). The hard block is OTA Shield's, a separate app
/// (`ota_shield_state.dart`).
///
/// OpenDash never consents to a firmware download or install: there is no
/// call here, in the vehicle notifier or in the Kotlin client that does
/// (`test/firmware_never_sent_test.dart`). What this does:
///  - switches the stock dashboard's auto-download setting off once, and
///    remembers what it found so the undo can put it back;
///  - watches HOTA's update callbacks and records what they say;
///  - notices when a firmware version has changed.
// TODO(firmware-control): "Ask me", "Check now" and the stock-dashboard hand-over have not been tried on the
// scooter. Off mode is confirmed.
class FirmwareNotifier extends Notifier<FirmwareState> {
  /// An install that has said nothing for this long is taken as over: the
  /// notice must not outlive it and keep the dashboard covered.
  static const installStale = Duration(minutes: 10);

  /// A changed version is reported once it has held this long. The HBC's
  /// version (index 4) has changed and changed again within five seconds
  /// of an unlock, and a three-second wait reported each as a firmware
  /// change: a controller that is waking up can answer with
  /// something else first.
  static const versionSettle = Duration(seconds: 30);

  /// Values remembered per version, so one that flips between answers it
  /// has given before is never a change.
  static const versionsRemembered = 6;

  /// Hardware-info indices compared across starts: BCM, BMS, BLE, head
  /// unit, HBC, MCU and the three bootloaders. The MoveOS string is
  /// compared under [moveOsKey].
  static const versionIds = {0, 1, 2, 3, 4, 5, 20, 21, 22};
  static const headUnitId = 3;
  static const moveOsKey = 'moveos';

  bool _autoDownloadSent = false;

  /// Fixed at start: a restore stops the watching from the next start.
  bool _watching = true;
  Timer? _installTimer;
  Timer? _versionTimer;
  Map<String, String>? _stored;
  final Map<String, List<String>> _seen = {};
  bool _firstRun = false;
  bool _firstRunLogged = false;
  final _changed = <String, (String, String)>{};
  String? _lastNoticeLog;

  @override
  FirmwareState build() {
    ref.onDispose(() {
      _installTimer?.cancel();
      _versionTimer?.cancel();
    });
    final mode = PrefsService.getString(PrefsKeys.fwMode, 'off') == 'ask' ? FirmwareMode.ask : FirmwareMode.off;
    final first = PrefsService.getInt(PrefsKeys.fwStockAutoDownloadFirst, -1);
    final last = PrefsService.getString(PrefsKeys.fwLastNotice, '');
    logEvent('fw', 'mode', {'mode': mode.name, 'source': 'boot'});
    _loadVersions();
    final change = PrefsService.getString(PrefsKeys.fwChange, '');
    ref.listen(vehicleProvider.select((v) => (v.stockAutoDownload, v.locked)), (prev, next) {
      if (prev?.$1 != next.$1 && next.$1 != null) _autoDownloadSeen(next.$1!);
      _maybeSwitchAutoDownloadOff();
    });
    // What the removed firmware-block reading left behind.
    PrefsService.remove(PrefsKeys.fwBlockLast);
    PrefsService.remove(PrefsKeys.fwBlockRemovedUnseen);
    final restored = PrefsService.getBool(PrefsKeys.fwRestored, false);
    _watching = !restored;
    final vehicle = ref.read(vehicleProvider.notifier);
    vehicle.onFirmwareNotice = onNotice;
    vehicle.onFirmwareVersion = onVersion;
    vehicle.onHhmisAttached = onHhmisAttached;
    // What arrived before this notifier existed.
    Future.microtask(() {
      final v = ref.read(vehicleProvider);
      if (v.stockAutoDownload != null) _autoDownloadSeen(v.stockAutoDownload!);
      _maybeSwitchAutoDownloadOff();
      if (v.hhmisBacked && v.hhmisConnected) onHhmisAttached();
      onVersion(moveOsKey, v.hhmisBacked ? v.moveOsVersion : '');
    });
    return FirmwareState(
      mode: mode,
      restored: restored,
      autoDownloadFirst: first < 0 ? null : first,
      notice: last.isEmpty ? null : FirmwareNotice.fromJson(last),
      seenVersion: PrefsService.getString(PrefsKeys.fwNoticeSeen, ''),
      change: change.isEmpty ? null : FirmwareChange.fromJson(change),
    );
  }

  int? get _nowMs => TrustedClock.trusted ? TrustedClock.now().millisecondsSinceEpoch : null;

  // ---- mode -------------------------------------------------------------

  void setMode(FirmwareMode mode) {
    if (mode == state.mode) return;
    state = state.copyWith(mode: mode, ackOpen: false, ackBlocked: false);
    PrefsService.setString(PrefsKeys.fwMode, mode.name);
    logEvent('fw', 'mode', {'mode': mode.name, 'source': 'rider'});
    // A notice that was already waiting is on the screen the rider is
    // looking at: it does not light the bell behind them.
    markSeen();
  }

  // ---- the stock auto-download setting ----------------------------------

  void _autoDownloadSeen(int value) {
    var first = state.autoDownloadFirst;
    if (first == null) {
      first = value;
      state = state.copyWith(autoDownloadFirst: () => value);
      PrefsService.setInt(PrefsKeys.fwStockAutoDownloadFirst, value);
    }
    logEvent('fw', 'autodl', {'value': value, 'source': 'vehicle', 'first_seen': first});
  }

  /// ClientCmd 53 = 0, once per process, only after a value has been seen,
  /// only unlocked, and never once the rider has restored stock settings.
  void _maybeSwitchAutoDownloadOff() {
    if (_autoDownloadSent || state.restored) return;
    final v = ref.read(vehicleProvider);
    final value = v.stockAutoDownload;
    if (value == null || value == 0 || v.locked) return;
    _autoDownloadSent = true;
    ref.read(vehicleProvider.notifier).sendStockAutoDownload(0).then((ok) {
      logEvent('fw', 'autodl', {'value': 0, 'source': 'sent', 'first_seen': state.autoDownloadFirst, 'ok': ok});
    });
  }

  /// The undo of the soft layer: the stock auto-download setting goes back
  /// to what was first found (on, when nothing was), and from the next
  /// start OpenDash does not watch the update callbacks. OTA Shield's block
  /// is OTA Shield's to turn off.
  Future<void> restoreStock() async {
    final value = state.autoDownloadFirst ?? 1;
    _autoDownloadSent = true;
    state = state.copyWith(restored: true, ackOpen: false, ackBlocked: false);
    PrefsService.setBool(PrefsKeys.fwRestored, true);
    final ok = await ref.read(vehicleProvider.notifier).sendStockAutoDownload(value);
    logEvent('fw', 'autodl', {'value': value, 'source': 'sent', 'first_seen': state.autoDownloadFirst, 'ok': ok, 'restore': true});
    if (!ok) _toast('Scooter not connected. Stock auto-download was not changed');
  }

  /// Takes firmware control back after a restore.
  void manageAgain() {
    if (!state.restored) return;
    state = state.copyWith(restored: false);
    PrefsService.setBool(PrefsKeys.fwRestored, false);
    logEvent('fw', 'mode', {'mode': state.mode.name, 'source': 'rider', 'managed': true});
    _autoDownloadSent = false;
    _watching = true;
    _maybeSwitchAutoDownloadOff();
    onHhmisAttached();
  }

  // ---- the update callbacks ---------------------------------------------

  /// HHMIS has just taken our vehicle callback (a bind, or a reattach after
  /// the stock dashboard held the slot): put the update callbacks back too.
  void onHhmisAttached() {
    if (!_watching) return;
    ref.read(vehicleProvider.notifier).subscribeFirmware().then((ok) {
      state = state.copyWith(subscribed: () => ok);
      logEvent('fw', 'subscribed', {'ok': ok});
    });
  }

  /// One decoded update callback (`OtaDecoder` in the Kotlin client; the
  /// dev panel sends the same maps). Watching only: nothing is answered.
  void onNotice(Map<Object?, Object?> raw) {
    final kind = raw['kind'];
    if (kind is! String) return;
    final version = raw['version'] is String ? raw['version'] as String : '';
    final state_ = raw['state'] is int ? raw['state'] as int : null;
    final reason = raw['reason'] is int ? raw['reason'] as int : null;
    final button = raw['button'] is bool ? raw['button'] as bool : null;
    final progress = raw['progress'] is int
        ? raw['progress'] as int
        : (raw['dlProgress'] is int ? raw['dlProgress'] as int : null);
    _logNotice(kind, state_, reason, button, version, progress, raw['dlState']);

    switch (kind) {
      case 'install_progress':
        _installTimer?.cancel();
        _installTimer = Timer(installStale, _installOver);
        state = state.copyWith(installing: true, installProgress: (progress ?? 0).clamp(0, 100));
        return;
      case 'first_boot':
        _installOver();
        return;
      case 'install_failed' || 'up_to_date':
        _installOver();
    }
    final notice = FirmwareNotice(
      kind: kind,
      version: version,
      size: raw['size'] is String ? raw['size'] as String : '',
      button: button,
      reason: reason,
      state: state_,
      progress: progress,
      atMs: _sameUpdate(kind, version) ? state.notice?.atMs ?? _nowMs : _nowMs,
      notes: parseReleaseNotes(raw['notes']),
    );
    state = state.copyWith(notice: () => notice);
    PrefsService.setString(PrefsKeys.fwLastNotice, jsonEncode(notice.toJson()));
  }

  /// HOTA repeats `onUpdateAvailable` on every charge, state and network
  /// change: the date shown is when this version was first offered.
  bool _sameUpdate(String kind, String version) {
    final old = state.notice;
    return old != null && old.waiting && old.version == version && kind != 'up_to_date';
  }

  void _installOver() {
    _installTimer?.cancel();
    _installTimer = null;
    if (state.installing) state = state.copyWith(installing: false);
  }

  /// One line per distinct notice; download and install progress in steps
  /// of ten so a long transfer does not fill the log.
  void _logNotice(String kind, int? state_, int? reason, bool? button, String version, int? progress, Object? dlState) {
    final step = progress == null ? null : progress ~/ 10 * 10;
    final key = '$kind|$state_|$reason|$button|$version|$step|$dlState';
    if (key == _lastNoticeLog) return;
    _lastNoticeLog = key;
    logEvent('fw', 'notice', {
      'kind': kind,
      'state': state_,
      'reason': reason,
      'button': button,
      'version': version,
      'progress': ?step,
      if (dlState is int) 'dl_state': dlState,
    });
  }

  /// HOTA hands the notes over as the cloud sent them: a JSON object with a
  /// `releaseNotes` list (stock `OTAInfoManager.performReleaseNotesParsing`),
  /// or plain text.
  static List<String> parseReleaseNotes(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return const [];
    const cap = 12;
    String clip(String s) => s.length > 240 ? '${s.substring(0, 240)}…' : s;
    try {
      final decoded = jsonDecode(raw);
      final list = decoded is Map ? decoded['releaseNotes'] : decoded;
      if (list is List) {
        return [
          for (final item in list.take(cap))
            if (item is String && item.trim().isNotEmpty)
              clip(item.trim())
            else if (item is Map)
              clip(item.values.whereType<String>().where((s) => s.trim().isNotEmpty).join(': ')),
        ].where((s) => s.isNotEmpty).toList();
      }
    } on FormatException {
      // Plain text.
    }
    return [for (final line in raw.split('\n').take(cap)) if (line.trim().isNotEmpty) clip(line.trim())];
  }

  /// The Updates screen opened: what it shows is read again, and what lit
  /// the bell counts as seen.
  void screenOpened() => markSeen();

  /// The screen closed: the acknowledgement does not wait behind a closed
  /// screen.
  void screenClosed() => state = state.copyWith(ackOpen: false, ackBlocked: false);

  /// The bell goes out for this version, and stays out.
  void markSeen() {
    final version = state.notice?.version ?? '';
    if (state.noticeWaiting && version != state.seenVersion) {
      state = state.copyWith(seenVersion: version);
      PrefsService.setString(PrefsKeys.fwNoticeSeen, version);
    }
  }

  // ---- the hand-over ----------------------------------------------------

  /// Why the hand-over cannot start now, or null. Unlocked, in PARK, proven
  /// stopped, not riding.
  String? handoverRefusal() {
    final v = ref.read(vehicleProvider);
    if (state.mode != FirmwareMode.ask) return 'mode_off';
    if (!state.noticeWaiting) return 'no_notice';
    if (v.locked) return 'locked';
    if (ref.read(ridingLockoutProvider)) return 'riding';
    if (!v.provenStopped) return v.speed > 0 ? 'moving' : (v.speedUntrustedReason ?? 'untrusted');
    if (v.vehicleState != VehicleState.parked) return 'not_parked';
    if (!ref.read(ownScreenVisibleProvider)) return noPromptSurfaceReason;
    return null;
  }

  static String refusalText(String reason) => switch (reason) {
        'locked' => 'Unlock the scooter first',
        'not_parked' => 'Put the scooter in Park first',
        'moving' || 'riding' => 'Stop and park first',
        'mode_off' || 'no_notice' => 'No firmware update is waiting',
        _ => 'Can\'t confirm the scooter is stopped',
      };

  /// "Read before updating": the conditions, then the passcode, then the
  /// acknowledgement.
  void readBeforeUpdating() {
    final refusal = handoverRefusal();
    if (refusal != null) {
      logEvent('fw', 'handover', {'step': 'refused', 'reason': refusal});
      _toast(refusalText(refusal));
      return;
    }
    ref.read(passcodeGateProvider.notifier).request(
          purpose: 'Enter passcode to read about this update',
          onSuccess: () {
            state = state.copyWith(ackOpen: true, ackBlocked: false);
            logEvent('fw', 'handover', {'step': 'shown'});
          },
        );
  }

  void notNow() {
    if (!state.ackOpen) return;
    state = state.copyWith(ackOpen: false, ackBlocked: false);
    logEvent('fw', 'handover', {'step': 'dismissed'});
  }

  /// "Open the stock dashboard". OpenDash sends no acknowledgement and no
  /// download call: the stock dashboard does both when it connects, and the
  /// rider taps "download" there.
  Future<void> openStock() async {
    if (!state.ackOpen) return;
    logEvent('fw', 'handover', {'step': 'acknowledged'});
    final refusal = handoverRefusal();
    if (refusal != null) {
      logEvent('fw', 'handover', {'step': 'refused', 'reason': refusal});
      state = state.copyWith(ackOpen: false);
      _toast(refusalText(refusal));
      return;
    }
    // Asked fresh: the block may have gone on or off since the screen opened.
    final platform = ref.read(platformServiceProvider);
    if (platform.isInstalled(otaShieldPackage) && (await platform.otaShieldStatus()).keepsUpdatesOut) {
      if (!ref.mounted) return;
      logEvent('fw', 'handover', {'step': 'refused', 'reason': 'ota_shield_on'});
      state = state.copyWith(ackBlocked: true);
      return;
    }
    state = state.copyWith(ackOpen: false);
    logEvent('fw', 'handover', {'step': 'opened'});
    await ref.read(crashRecoveryProvider.notifier).launchStockApp();
  }

  /// "Check now": asks HOTA once whether an update is waiting. Ask me only.
  Future<void> checkNow() async {
    if (state.mode != FirmwareMode.ask || state.restored) return;
    final v = ref.read(vehicleProvider);
    if (refuseUnlessStopped(ref, v, 'fw_check', 'Stop before checking for updates')) return;
    final ok = await ref.read(vehicleProvider.notifier).checkFirmwareUpdate();
    _toast(ok ? 'Asked the scooter. A waiting update shows here' : 'Scooter not connected', warning: !ok);
  }

  // ---- after a firmware change ------------------------------------------

  void _loadVersions() {
    final raw = PrefsService.getString(PrefsKeys.fwVersions, '');
    _stored = null;
    _seen.clear();
    _firstRun = raw.isEmpty;
    if (raw.isEmpty) return;
    try {
      final m = jsonDecode(raw);
      if (m is Map) _stored = {for (final e in m.entries) if (e.value is String) '${e.key}': e.value as String};
    } on FormatException {
      _firstRun = true;
    }
    final seenRaw = PrefsService.getString(PrefsKeys.fwVersionsSeen, '');
    if (seenRaw.isEmpty) {
      // A build from before values were remembered: an ECU-only change it
      // recorded may have been a flicker, and cannot be told from one now.
      final old = FirmwareChange.fromJson(PrefsService.getString(PrefsKeys.fwChange, '{}'));
      if (old != null && !old.headUnit) PrefsService.remove(PrefsKeys.fwChange);
    } else {
      try {
        final m = jsonDecode(seenRaw);
        if (m is Map) {
          for (final e in m.entries) {
            if (e.value is List) _seen['${e.key}'] = [for (final v in e.value as List) if (v is String) v];
          }
        }
      } on FormatException {
        // Rebuilt from what is stored, below.
      }
    }
    _stored?.forEach((k, v) => _seen.putIfAbsent(k, () => [v]));
  }

  /// A hardware-info value (by index) or the MoveOS string, as it arrives
  /// after each start. Stored; compared with what the last start stored.
  /// "0.0.0.0" is a controller that has not reported yet, not a version:
  /// once `L- 0.0.0.0 R- 2.2.4.1` became `L- 2.2.4.1 R- 2.2.4.1`
  /// two hours after a fresh install and was taken for a change of
  /// software.
  static final _unreported = RegExp(r'(^|[^\d.])0(\.0)+($|[^\d.])');

  void onVersion(String key, String value) {
    if (value.isEmpty || _unreported.hasMatch(value)) return;
    final stored = _stored ??= {};
    final before = stored[key];
    if (before == value) return;
    stored[key] = value;
    final seen = _seen.putIfAbsent(key, () => []);
    final known = seen.contains(value);
    if (!known) {
      seen.add(value);
      if (seen.length > versionsRemembered) seen.removeAt(0);
    }
    if (before != null && !_firstRun) {
      final from = _changed[key]?.$1 ?? before;
      // Back where it was, or an answer it has given before: not a change.
      if (value == from || known) {
        _changed.remove(key);
      } else {
        _changed[key] = (from, value);
      }
    }
    _versionTimer?.cancel();
    _versionTimer = Timer(versionSettle, _versionsSettled);
  }

  void _versionsSettled() {
    _versionTimer = null;
    PrefsService.setString(PrefsKeys.fwVersions, jsonEncode(_stored));
    PrefsService.setString(PrefsKeys.fwVersionsSeen, jsonEncode(_seen));
    if (_firstRun) {
      // The first run after an install has nothing to compare with.
      if (!_firstRunLogged) logEvent('fw', 'version_changed', {'which': const <String>[], 'first_run': true});
      _firstRunLogged = true;
      _firstRun = false;
      return;
    }
    if (_changed.isEmpty) return;
    final which = _changed.keys.toList()..sort();
    logEvent('fw', 'version_changed', {
      'which': which,
      'first_run': false,
      'changes': {for (final k in which) k: [_changed[k]!.$1, _changed[k]!.$2]},
    });
    final head = _changed['$headUnitId'] ?? _changed[moveOsKey];
    final change = FirmwareChange(
      headUnit: head != null,
      from: head?.$1 ?? '',
      to: head?.$2 ?? '',
      atMs: _nowMs,
    );
    _changed.clear();
    // An ECU-only change must not un-owe a head-unit notice still waiting.
    if (!change.headUnit && state.changeNoticeOwed) return;
    state = state.copyWith(change: () => change);
    PrefsService.setString(PrefsKeys.fwChange, jsonEncode(change.toJson()));
  }

  /// The rider answered the one-time notice. [stock]: "Open the stock
  /// dashboard"; otherwise "Keep using OpenDash".
  Future<void> answerChange({required bool stock}) async {
    final c = state.change;
    if (c == null || c.answered) return;
    final answered = FirmwareChange(headUnit: c.headUnit, from: c.from, to: c.to, atMs: c.atMs, answered: true);
    state = state.copyWith(change: () => answered);
    PrefsService.setString(PrefsKeys.fwChange, jsonEncode(answered.toJson()));
    logEvent('fw', 'version_notice', {'answer': stock ? 'stock' : 'keep'});
    if (stock) await ref.read(crashRecoveryProvider.notifier).launchStockApp();
  }

  void _toast(String message, {bool warning = true}) =>
      ref.read(toastProvider.notifier).show(message, type: warning ? ToastType.warning : ToastType.info);
}

/// The one-time notice after a head-unit firmware change shows at the next
/// park, unlocked, on OpenDash's own screen.
final firmwareChangeNoticeProvider = Provider<FirmwareChange?>((ref) {
  final change = ref.watch(firmwareProvider.select((f) => f.changeNoticeOwed ? f.change : null));
  if (change == null) return null;
  final ok = ref.watch(vehicleProvider.select(
      (v) => !v.locked && v.provenStopped && v.vehicleState == VehicleState.parked));
  if (!ok || ref.watch(ridingLockoutProvider) || !ref.watch(ownScreenVisibleProvider)) return null;
  return change;
});
