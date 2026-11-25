import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../models/app_catalog.dart';
import '../models/vehicle_data.dart';
import '../providers/vehicle_provider.dart';
import '../providers/mock_provider.dart';
import '../services/analytics_logger.dart';
import '../services/platform_provider.dart';
import '../theme/colors.dart';
import 'alert_state.dart';
import 'apps_state.dart';
import 'crash_recovery.dart';
import 'prompt_surface.dart';
import 'riding_lockout.dart';
import 'safety_screen.dart';
import 'safety_watchdog.dart';
import 'theme_state.dart';
import 'toast_state.dart';

/// Shown over the Diagnostics tab while riding. Diagnostics is the one
/// OpenDash screen allowed to stay open on the move (you open it stopped,
/// then ride — it never opens while moving); the full-screen tab covers the
/// dial, so the island floats the speedo on top, the same way it does over a
/// projection app. Not a real installed app — it only gives [_derive] an app
/// context so the island will render over our own screen.
const _diagnosticsRideApp = CatalogApp(
  id: 'diagnostics-ride',
  name: 'Diagnostics',
  package: '',
  description: '',
  releaseUrl: '',
  license: '',
);

/// The Kotlin side of the island (`DashIsland.kt`): it draws what it is
/// sent and reports what it showed.
abstract class IslandBridge {
  set onEvent(void Function(String method, Map<Object?, Object?> args)? handler);
  void set(Map<String, Object?> model);
  void hide(String reason);
  void ping();
}

class ChannelIslandBridge implements IslandBridge {
  static const _channel = MethodChannel('in.abhijithvijayan.opendash.island');

  @override
  set onEvent(void Function(String method, Map<Object?, Object?> args)? handler) {
    // No binding in a plain provider test.
    try {
      _channel.setMethodCallHandler(handler == null
          ? null
          : (call) async => handler(call.method, (call.arguments as Map?) ?? const {}));
    } catch (_) {}
  }

  @override
  void set(Map<String, Object?> model) => _send('set', model);

  @override
  void hide(String reason) => _send('hide', {'reason': reason});

  @override
  void ping() => _send('ping', null);

  void _send(String method, Object? args) {
    try {
      _channel.invokeMethod<void>(method, args).catchError((Object e) {
        logEvent('island', 'channel_error', {'method': method, 'error': e.toString()});
      });
    } catch (_) {}
  }
}

class NoIslandBridge implements IslandBridge {
  @override
  set onEvent(void Function(String method, Map<Object?, Object?> args)? handler) {}
  @override
  void set(Map<String, Object?> model) {}
  @override
  void hide(String reason) {}
  @override
  void ping() {}
}

final islandBridgeProvider = Provider<IslandBridge>(
    (_) => !kIsWeb && defaultTargetPlatform == TargetPlatform.android ? ChannelIslandBridge() : NoIslandBridge());

/// What the island draws, as sent to Kotlin. Two models with the same
/// content are equal whatever their sequence number.
class IslandModel {
  IslandModel(this.seq, this.content) : _key = jsonEncode(content);
  final int seq;
  final Map<String, Object?> content;
  final String _key;

  String get state => content['state']! as String;
  Map<String, Object?>? get attention => content['att'] as Map<String, Object?>?;
  bool get critical => attention?['priority'] == 'critical' && attention?['kind'] != 'toast';

  Map<String, Object?> toMap() => {...content, 'seq': seq};

  bool sameContent(IslandModel? other) => other != null && other._key == _key;
}

/// The mock build's island preview (`lib/dev/island_preview.dart`): the
/// stand-in background it is drawn over, or null when it is off. While it is
/// on, the island behaves as if CarPlay were in front.
final islandPreviewProvider = NotifierProvider<IslandPreviewMode, String?>(IslandPreviewMode.new);

class IslandPreviewMode extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? background) => state = background;
}

final dashIslandProvider = NotifierProvider<DashIsland, IslandModel?>(DashIsland.new);

/// Decides what the island over another app shows. Every rule is the
/// dashboard's own: this only picks from the providers that already hold
/// them, and every tap calls the method the dashboard's control calls.
class DashIsland extends Notifier<IslandModel?> {
  static const expandedFor = Duration(seconds: 8);
  static const expandedForMoving = Duration(seconds: 5);
  static const toastFor = Duration(seconds: 4);
  static const volumeFor = Duration(seconds: 2);
  static const confirmWithin = Duration(seconds: 1);
  static const keepAliveEvery = Duration(seconds: 1);

  late IslandBridge _bridge;
  int _seq = 0;
  int _shownSeq = -1;
  int _criticalSeq = -1;
  bool _expanded = false;
  String _hiddenReason = 'no_app';
  Timer? _collapse;
  Timer? _keepAlive;
  Timer? _toastTimer;
  Timer? _confirm;
  DashAlert? _transient;
  ToastData? _toast;
  int? _volume;
  Timer? _volumeTimer;
  Set<AlertKey> _seen = {};

  @override
  IslandModel? build() {
    _bridge = ref.read(islandBridgeProvider);
    _bridge.onEvent = _onEvent;
    ref.onDispose(() {
      _idleTimer?.cancel();
      _bridge.onEvent = null;
      for (final t in [_collapse, _keepAlive, _toastTimer, _volumeTimer, _confirm, _presenceEnd]) {
        t?.cancel();
      }
    });
    void on(ProviderListenable<Object?> p) => ref.listen<Object?>(p, (_, _) => _sync('data'));
    on(outsideAppProvider);
    on(islandPreviewProvider);
    on(ownScreenVisibleProvider);
    on(diagnosticsRidingProvider);
    on(vehicleProvider.select(_shown));
    on(ridingLockoutProvider);
    on(visibleAlertsProvider);
    on(safetyWatchdogProvider);
    on(safetyScreenProvider.select((s) => s.screen != null));
    on(shownThemeProvider);
    // Not appManagerProvider: it asks this notifier to host critical alerts,
    // and what is installed is read when the model is built.
    ref.listen(toastProvider, (_, toast) {
      if (toast == null || state == null) return;
      _toast = toast;
      _toastTimer?.cancel();
      _toastTimer = Timer(toastFor, () {
        _toast = null;
        _sync('timeout');
      });
      _sync('toast');
    });
    // The handlebar volume buttons: the dashboard's own popup is behind the app.
    ref.listen(vehicleProvider.select((v) => v.volume), (_, volume) {
      if (state == null) return;
      _volume = volume;
      _volumeTimer?.cancel();
      _volumeTimer = Timer(volumeFor, () {
        _volume = null;
        _sync('timeout');
      });
      _sync('volume');
    });
    _keepAlive = Timer.periodic(keepAliveEvery, (t) {
      if (state == null) return;
      _bridge.ping();
      if (t.tick.isEven) _readFront();
    });
    final first = _derive();
    if (first != null) _bridge.set(first.toMap());
    return first;
  }

  /// Only what the island draws: the vehicle data changes 30 times a second
  /// on a ride and 100 on the charger, almost never in one of these.
  static Object _shown(VehicleData v) => (
        (v.speed, v.batterySoc, v.range, v.speedTrusted),
        (v.locked, v.vehicleState, v.driveMode, v.isCharging),
        (v.turnLeft, v.turnRight, v.hazard, v.highBeam),
        (v.trunkOpen, v.trunkStateKnown, v.callIncoming, v.callerLabel),
        (v.hillHoldActive, v.cruiseMode, v.sideStand),
      );

  /// The package Android says is in front while the island is up: null
  /// until it has answered or without usage access, which the rider grants
  /// in Settings → Connectivity.
  String? _front;

  /// Asked every other second while the island is up. What is in front is
  /// not always the app that was opened: CarPlay's setup has gone into an
  /// Android settings page, and the island over it had no way back
  /// to CarPlay.
  Future<void> _readFront() async {
    String? front;
    try {
      front = ref.read(platformServiceProvider).foregroundPackage();
    } catch (_) {
      return;
    }
    if (!ref.mounted || state == null) return;
    final next = front == null || front.isEmpty ? null : front;
    if (next == _front) return;
    _front = next;
    _present();
    logEvent('island', 'front', {'app': ref.read(outsideAppProvider)?.id, 'same': !_elsewhere(ref.read(outsideAppProvider))});
    _sync('front');
  }

  /// Another app's screen is over [app]. Unknown counts as "possibly":
  /// without usage access the way back is always offered.
  bool _elsewhere(CatalogApp? app) {
    final front = _front;
    if (app == null || app.package.isEmpty) return false;
    return front == null || (front != app.package && front != ownPackage);
  }

  static const ownPackage = 'in.abhijithvijayan.opendash';

  /// How long after the last sign of the rider the scooter is still told
  /// it is in use while another app is in front.
  // TODO(island-presence): three minutes is a choice, not a measurement.
  static const presenceFor = Duration(minutes: 3);
  String? _presentFor;
  int _presentUntilMicros = 0;
  Timer? _presenceEnd;

  /// A sign that the rider is there: the app was just opened, the island or
  /// the app under it was touched, or the screen in front changed.
  ///
  /// The vehicle locks a parked scooter 61 s after the last touch it is
  /// told of, and the island only hears touches Android passes on. On its
  /// own settings pages it passes none: the scooter was seen to lock twice,
  /// a minute into Android Settings, while the rider was changing
  /// permissions there. So for [presenceFor] after each sign the island
  /// reports "in use" itself (`awake`). Left alone, the scooter still
  /// locks: about four minutes after the last sign instead of one.
  void _present() {
    final wasAwake = _awake;
    _lastSignMicros = AnalyticsLogger.instance.monoMicros;
    _presentUntilMicros = AnalyticsLogger.instance.monoMicros + presenceFor.inMicroseconds;
    _presenceEnd?.cancel();
    _presenceEnd = Timer(presenceFor, () => _sync('presence_end'));
    if (!wasAwake && state != null) _sync('presence');
  }

  bool get _awake => AnalyticsLogger.instance.monoMicros < _presentUntilMicros;

  /// Android keeps the touches on its own pages to itself: Android Settings,
  /// a page OpenDash sent the rider to, or a settings page an app opened.
  /// Only there is the scooter told "in use" for [presenceFor]. A projection
  /// app's touches are heard, so the vehicle's own minute applies there as
  /// it does on the dashboard (seen: parked with CarPlay in front for two
  /// minutes, nothing locked, and nothing said when it would).
  bool _silentPage(CatalogApp app) =>
      app.id == CatalogApp.androidSettingsId || app.id.startsWith('system-') || (_front != null && _elsewhere(app));

  int _lastSignMicros = 0;
  bool _lockApplied = false;
  bool _lockOverdue = false;
  bool? _loggedLight;
  int _lockAppliesSinceMicros = 0;
  Timer? _idleTimer;
  bool _idleWarned = false;

  /// Seconds until the vehicle locks the scooter for want of a touch, in
  /// the last [AidlVehicleNotifier.idleLockWarning] of them; null before
  /// that, and wherever that lock does not apply. Arms the timer that
  /// brings the island back here when the next second, or the start of the
  /// warning, is due.
  int? _lockIn(VehicleData v, CatalogApp app) {
    _idleTimer?.cancel();
    _idleTimer = null;
    // The stock dashboard reports its own touches; OpenDash's count for
    // nothing there.
    // Only with the side stand down, as in `_updateIdleLock`.
    final applies = !v.locked &&
        v.provenStopped &&
        v.sideStand &&
        v.vehicleState == VehicleState.parked &&
        !v.isCharging &&
        app.id != CatalogApp.stockDashboardId;
    final now = AnalyticsLogger.instance.monoMicros;
    // The lock is not due a minute after a touch made while riding: the
    // island once said "Locking in 10 s" at the stop, 51 s after
    // the last touch, and the scooter was still unlocked 43 s later. The
    // minute starts no earlier than the stop.
    // TODO(idle-lock-after-ride): as in AidlVehicleNotifier._updateIdleLock: one observation. With a projection app
    // in front the scooter once went two minutes without locking; why is not known.
    if (applies && !_lockApplied) _lockAppliesSinceMicros = now;
    _lockApplied = applies;
    if (!applies) return null;
    final sign = _silentPage(app) && _presentUntilMicros > _lastSignMicros ? _presentUntilMicros : _lastSignMicros;
    final from = sign > _lockAppliesSinceMicros ? sign : _lockAppliesSinceMicros;
    final leftMicros = from + AidlVehicleNotifier.idleLockAfter.inMicroseconds - now;
    final warnMicros = AidlVehicleNotifier.idleLockWarning.inMicroseconds;
    if (leftMicros > warnMicros) {
      _idleTimer = Timer(Duration(microseconds: leftMicros - warnMicros), () => _sync('idle'));
      return null;
    }
    // The lock is the scooter's and this is a guess at it. One that is
    // this late was wrong: "Locking" once stood for 40 s over a
    // scooter that stayed unlocked. It goes, until the next sign of the
    // rider starts a new minute.
    _lockOverdue = leftMicros < -AidlVehicleNotifier.idleLockOverdue.inMicroseconds;
    if (_lockOverdue) return null;
    final left = (leftMicros / 1000000).ceil().clamp(0, AidlVehicleNotifier.idleLockWarning.inSeconds);
    _idleTimer = Timer(
      left > 0 ? const Duration(seconds: 1) : AidlVehicleNotifier.idleLockOverdue + const Duration(seconds: 1),
      () => _sync('idle'),
    );
    return left;
  }

  void _sync(String cause) {
    final app = ref.read(outsideAppProvider);
    if (app?.id != _presentFor) {
      _presentFor = app?.id;
      if (app != null) {
        _lastSignMicros = AnalyticsLogger.instance.monoMicros;
        _presentUntilMicros = AnalyticsLogger.instance.monoMicros + presenceFor.inMicroseconds;
        _presenceEnd?.cancel();
        _presenceEnd = Timer(presenceFor, () => _sync('presence_end'));
      }
    }
    final was = state;
    final next = _derive();
    if (next == null) {
      if (was == null) return;
      state = null;
      _collapse?.cancel();
      ref.read(promptSurfaceVisibleProvider.notifier).islandShown(false);
      _bridge.hide(_hiddenReason);
      logEvent('island', 'state', {'from': was.state, 'to': 'hidden', 'cause': _hiddenReason});
      return;
    }
    if (next.sameContent(was)) return;
    final kind = next.attention?['kind'];
    if (next.critical && kind != was?.attention?['kind']) _criticalSeq = next.seq;
    if (kind != null && kind != was?.attention?['kind']) {
      logEvent('island', 'attention', {
        'kind': kind,
        'priority': next.attention!['priority'],
        'seq': next.seq,
        'moving': ref.read(ridingLockoutProvider),
      });
    }
    if (next.state != was?.state) {
      logEvent('island', 'state', {'from': was?.state ?? 'hidden', 'to': next.state, 'cause': was == null ? 'show' : cause});
    }
    state = next;
    _bridge.set(next.toMap());
  }

  /// What Kotlin would have sent, from the Chrome preview.
  void previewEvent(String method, Map<Object?, Object?> args) => _onEvent(method, args);

  IslandModel? _derive() {
    final preview = ref.read(islandPreviewProvider) != null;
    // The Diagnostics tab is allowed to ride, and it covers the dial; while a
    // ride session is on (latched across stop-and-go by diagnosticsRiding) the
    // island stands in for the speedo over our own screen, so it carries
    // `over_self` to tell the native side to draw it even in front.
    final diagRide = ref.read(diagnosticsRidingProvider);
    final app = ref.read(outsideAppProvider) ??
        (preview
            ? appCatalog.firstWhere((a) => a.id == 'carplay')
            : diagRide
                ? _diagnosticsRideApp
                : null);
    final v = ref.read(vehicleProvider);
    final others = [
      for (final a in ref.read(visibleAlertsProvider))
        if (a.priority != AlertPriority.critical) a,
    ];
    final active = {for (final a in others) a.key};
    final hidden = app == null
        ? 'no_app'
        // Our own screen hides the island, except the riding Diagnostics tab,
        // which is the whole point: show the speedo over it.
        : ref.read(ownScreenVisibleProvider) && !preview && !diagRide
            ? 'foreground'
            : v.locked
                ? 'locked'
                : ref.read(safetyScreenProvider).screen != null
                    ? 'safety_screen'
                    : null;
    if (hidden != null || app == null) {
      _idleTimer?.cancel();
      if (_idleWarned) _noteIdleWarning(null, ref.read(vehicleProvider));
      _hiddenReason = hidden ?? 'no_app';
      _front = null;
      _expanded = false;
      _transient = null;
      _toast = null;
      _volume = null;
      // Nothing that was up on the dashboard is announced again here.
      _seen = active;
      return null;
    }

    final theme = ref.read(shownThemeProvider);
    // The stock dashboard takes the data feed, and Android's own screens are
    // not a place to ride from: over those the island is only the way back.
    if (app.id == CatalogApp.stockDashboardId || app.id.startsWith('system-')) {
      final v = ref.read(vehicleProvider);
      final lockIn = _lockIn(v, app);
      _noteIdleWarning(lockIn, v);
      return IslandModel(++_seq, {
        'app': app.id,
        'state': 'collapsed',
        'pill': true,
        // It may be moved unless the scooter is known to be moving. Over
        // the stock dashboard OpenDash has no live data (stock holds the
        // feed), and "not known" used to count as moving, so it could not
        // be dragged there.
        'moving': v.speedTrusted && ref.read(ridingLockoutProvider),
        'awake': v.provenStopped && _awake && _silentPage(app),
        if (lockIn != null) 'sub': _lockRow(lockIn),
        'light': theme.isLight,
        'bone': theme.bone.toARGB32(),
        'ash': theme.ash.toARGB32(),
      });
    }

    // A warning stays on the island for as long as it is true, as it does
    // on the dashboard. It used to shrink to a coloured dot after six
    // seconds, which said nothing and did not feel right. The newest one
    // shows; when it clears, any other that still holds takes its place.
    _seen.retainAll(active);
    if (_transient != null && !active.contains(_transient!.key)) _transient = null;
    for (final a in others) {
      if (_seen.add(a.key)) _transient = a;
    }
    _transient ??= others.isEmpty ? null : others.first;

    final moving = ref.read(ridingLockoutProvider);
    var attention = _attention(v);
    // A warning or a note does not take the panel from a rider who has it
    // open, and does not keep it shut: the speed-limit warning once
    // closed the panel under a finger, and stood for six seconds
    // in the way of opening it. With the panel open it is the note in the
    // row. Only what needs an answer or is critical takes the island.
    final passive = attention != null &&
        attention['priority'] != 'critical' &&
        !const {'auto_park', 'auto_park_lock', 'call'}.contains(attention['kind']);
    final held = passive && _expanded ? attention : null;
    if (held != null) attention = null;
    if (attention != null) _expanded = false;
    // A toast never takes the panel away from a rider who is using it, and
    // only one that says something went wrong grows the island.
    final toast = attention?['kind'] == 'toast' ? null : _toast;
    final light = theme.isLight;
    // TODO(island-look): logging only. A dark island was seen by day and the log could not say
    // why; read island.look in the next log, and decide then whether the island should also weigh what is behind it.
    if (light != _loggedLight) {
      _loggedLight = light;
      logEvent('island', 'look', {'light': light, 'theme': theme.name});
    }
    Color onGlass(Color c) => light ? Color.lerp(c, const Color(0xFF000000), 0.22)! : c;
    final accent = onGlass(DashColors.accentFrom(v, theme));
    final live = v.speedTrusted;
    final parked = v.vehicleState == VehicleState.parked;

    final lockIn = _lockIn(v, app);
    _noteIdleWarning(lockIn, v);

    final content = <String, Object?>{
      'app': app.id,
      // Draw over OpenDash's own screen too (the Diagnostics tab covering the
      // dial), which the native side otherwise suppresses while in front.
      'over_self': diagRide,
      'state': attention != null ? 'attention' : _expanded ? 'expanded' : 'collapsed',
      'moving': moving,
      'light': light,
      'bone': theme.bone.toARGB32(),
      'ash': theme.ash.toARGB32(),
      'accent': accent.toARGB32(),
      'critical': theme.critical.toARGB32(),
      'warning': onGlass(theme.warning).toARGB32(),
      'beam': onGlass(theme.normal).toARGB32(),
      'speed': !live ? '––' : v.isCharging ? '${v.batterySoc}' : parked ? 'P' : '${v.speed}',
      'unit': !live || parked ? '' : v.isCharging ? '%' : 'km/h',
      // The drive mode, in words: the bar's colour alone did not say it.
      // Above the unit, where the row has room.
      'mode': !live || parked || v.isCharging ? '' : v.reverse ? 'REVERSE' : v.driveMode.label,
      // No figure before the scooter has sent one: a dashboard that had
      // just started showed "0%".
      'soc': live && v.socKnown && !v.isCharging ? v.batterySoc : null,
      'socColor': onGlass(v.batterySoc < 10 ? theme.critical : v.batterySoc <= 20 ? theme.warning : DashColors.accentFrom(v, theme)).toARGB32(),
      // The row itself only has room for a short word.
      'note': !live
          ? 'Data not live'
          : held != null
              ? '${held['title']}'
              : _expanded && toast != null
                  ? toast.message
                  : v.cruiseMode == CruiseMode.active
                  ? 'Cruise'
                  : v.isCharging
                      ? 'Charging'
                      : parked || _expanded
                          ? '${v.range} km'
                          : '',
      'noteStrong': !live || held != null || (_expanded && toast != null),
      'noteColor': (!live || held?['priority'] == 'warning'
              ? onGlass(theme.warning)
              : held != null || (_expanded && toast != null)
                  ? theme.bone
                  : theme.ash)
          .toARGB32(),
      // A message or the volume gets a line of its own under the row for
      // its few seconds: beside the battery it was cut off, and making the
      // island wide enough for it made it too wide.
      'sub': !live || _expanded || attention != null
          ? null
          : lockIn != null
              ? _lockRow(lockIn)
              : toast != null
              ? {'text': toast.message}
              : _volume != null
                  ? {'text': 'Volume', 'bar': _volume! / 100}
                  : v.hillHoldActive
                      ? {'text': 'Hill hold'}
                      : null,
      'left': live && (v.turnLeft || v.hazard),
      'right': live && (v.turnRight || v.hazard),
      // One tap when stopped, as on the dashboard's own boot button.
      'trunk': live && !moving && v.trunkStateKnown && !v.trunkOpen,
      'highBeam': live && v.highBeam,
      'trunkOpen': live && v.trunkOpen && v.trunkStateKnown,
      // Never lit now: a warning is shown in words while it holds.
      'dot': false,
      'awake': !moving && _awake && _silentPage(app),
      'att': attention,
      'controls': [
        {'id': 'hazard', 'label': 'Hazard', 'on': v.hazard, 'enabled': true},
        {'id': 'highBeam', 'label': 'High beam', 'on': v.highBeam, 'enabled': true},
        if (!moving) {'id': 'trunk', 'label': 'Open boot', 'on': false, 'enabled': v.trunkStateKnown && !v.trunkOpen},
      ],
      // The app itself comes first when another screen is over it. From
      // CarPlay's own setup the rider went into an Android settings page
      // and the island, still up, offered OpenDash and Android
      // Auto but no way back to CarPlay. With usage access that is known;
      // without it, a projection app's entry is always there.
      'apps': [
        if (!moving) ...[
          if (_front == null ? app.projection : _elsewhere(app)) {'id': app.id, 'label': app.name},
          for (final other in appCatalog)
            if (other.projection && other.id != app.id && (ref.read(appManagerProvider)[other.id]?.present ?? false))
              {'id': other.id, 'label': other.name},
        ],
      ],
    };
    return IslandModel(++_seq, content);
  }

  Map<String, Object?>? _attention(VehicleData v) {
    // TODO(island auto-park): never run on the scooter. Auto-lock was off on
    // the one ride logged (15 `safety.watchdog_suppressed`), so the countdown
    // in the island, "Keep riding" and the Locking… row are proven only by
    // the tests. Before relying on it: switch auto-lock on, drop the stand
    // while rolling behind CarPlay, and read `island.attention {kind:
    // auto_park}`, `ui.tap island-keep-riding` and `safety.watchdog_cancel`.
    final watchdog = ref.read(safetyWatchdogProvider);
    if (watchdog.armed) {
      return {
        'kind': 'auto_park',
        'priority': 'warning',
        'badge': '${watchdog.remainingSeconds}',
        'title': 'Parking in ${watchdog.remainingSeconds} s',
        'body': 'Stopped with the stand down',
        'action': 'Keep riding',
      };
    }
    if (watchdog.awaitingLock) {
      return {'kind': 'auto_park_lock', 'priority': 'warning', 'badge': '!', 'title': 'Locking…', 'body': 'Tap to open OpenDash'};
    }
    if (v.callIncoming) {
      return {
        'kind': 'call',
        'priority': 'info',
        'badge': 'i',
        'title': 'Incoming call',
        'body': v.callerLabel,
        'action': 'Accept',
        'action2': 'Reject',
      };
    }
    for (final a in ref.read(visibleAlertsProvider)) {
      if (a.priority == AlertPriority.critical) return _alert(a);
    }
    if (_transient != null) return _alert(_transient!);
    final toast = _toast;
    if (toast != null && !_expanded && (toast.type == ToastType.warning || toast.type == ToastType.error)) {
      return {
        'kind': 'toast',
        'priority': toast.type == ToastType.error ? 'critical' : 'warning',
        'badge': '!',
        'title': toast.message,
        'body': '',
      };
    }
    return null;
  }

  static Map<String, Object?> _alert(DashAlert a) => {
        'kind': a.kind.name,
        'priority': a.priority.name,
        'badge': a.priority == AlertPriority.info ? 'i' : '!',
        'title': a.title,
        'body': a.body,
      };

  /// A new critical alert came up with a projection app in front. True when
  /// the island takes it: [orElse] then runs only if Kotlin has not
  /// confirmed, within [confirmWithin], that it drew the alert.
  bool hostCritical(Set<String> kinds, void Function(String reason) orElse) {
    if (state == null || kinds.contains(AlertKind.thermalRunaway.name)) return false;
    _confirm?.cancel();
    _confirm = Timer(confirmWithin, () {
      final now = state;
      if (now == null) return;
      final shown = now.critical && kinds.contains(now.attention!['kind']) && _shownSeq >= _criticalSeq;
      final cleared = !ref
          .read(visibleAlertsProvider)
          .any((a) => a.priority == AlertPriority.critical && kinds.contains(a.kind.name));
      if (shown || cleared) return;
      logEvent('island', 'fallback_return', {'kinds': kinds.toList(), 'reason': 'timeout'});
      orElse('timeout');
    });
    return true;
  }

  /// "Locking in 8 s" under the row, with the time left as a bar, as the
  /// volume is shown. Any touch, on the island or under it, is a sign of
  /// the rider and takes it away.
  static Map<String, Object?> _lockRow(int seconds) => {
        'text': seconds > 0 ? 'Locking in $seconds s' : 'Locking',
        'bar': seconds / AidlVehicleNotifier.idleLockWarning.inSeconds,
        // A countdown, not a share: Kotlin wrote "0%" beside "Locking".
        'percent': false,
      };

  void _noteIdleWarning(int? lockIn, VehicleData v) {
    final showing = lockIn != null;
    if (showing == _idleWarned) return;
    _idleWarned = showing;
    logEvent('safety', 'idle_lock_warning', {
      'shown': showing,
      'where': 'island',
      if (showing) 'in_s': lockIn else 'outcome': v.locked ? 'locked' : _lockOverdue ? 'overdue' : 'awake',
    });
  }

  void _onEvent(String method, Map<Object?, Object?> args) {
    final model = state;
    switch (method) {
      case 'shown':
        final seq = (args['seq'] as int?) ?? -1;
        final wasConfirmed = _shownSeq >= _criticalSeq;
        _shownSeq = seq;
        if (model == null) return;
        if (ref.read(outsideAppProvider)?.projection ?? false) {
          ref.read(promptSurfaceVisibleProvider.notifier).islandShown(true);
        }
        if (model.critical && !wasConfirmed && seq >= _criticalSeq) {
          logEvent('island', 'confirmed', {'seq': seq, 'kind': model.attention!['kind']});
        }
      case 'hidden' || 'stale':
        if (method == 'stale' && args['on'] != true) return;
        ref.read(promptSurfaceVisibleProvider.notifier).islandShown(false);
      case 'touch':
        // A finger on the island that is not (yet) a tap: a drag, say.
        _present();
        _sync('touch');
      case 'outside':
        _present();
        if (_expanded) _setExpanded(false, 'outside');
        _sync('touch');
      case 'tap':
        _present();
        if (model != null && !ref.read(vehicleProvider).locked) {
          islandTapInHand = true;
          try {
            _tap(args['id'] as String? ?? '', model);
          } finally {
            islandTapInHand = false;
          }
        }
    }
  }

  /// A warning or a note: it may be set aside for the panel. Not what is
  /// critical or waits for an answer.
  static bool _passive(IslandModel model) {
    final kind = model.attention?['kind'];
    return kind != null && !model.critical && !const {'auto_park', 'auto_park_lock', 'call'}.contains(kind);
  }

  void _tap(String id, IslandModel model) {
    final vehicle = ref.read(vehicleProvider.notifier);
    final apps = ref.read(appManagerProvider.notifier);
    final kind = model.attention?['kind'];
    if (_expanded) _armCollapse();
    switch (id) {
      case 'row' when model.content['pill'] == true:
        uiTap('island-back', {'from': 'pill'});
        apps.returnFromIsland();
      // Nothing on the island can be trusted or used while the data is
      // not live, and OpenDash only mends its link to the scooter when it
      // is in front: the one useful tap is the way back.
      case 'row' when !ref.read(vehicleProvider).speedTrusted:
        uiTap('island-back', {'from': 'not_live'});
        apps.returnFromIsland();
      case 'row':
        if (_expanded) {
          _setExpanded(false, 'tap');
        } else if (model.attention == null || _passive(model)) {
          // The row above a warning opens the panel too: that is where the
          // rider's finger goes for it (seen in Chrome).
          uiTap('island-expand', {'from': ?kind});
          _setExpanded(true, 'tap');
        }
      case 'hazard':
        uiTap('island-hazard');
        vehicle.toggleHazard();
      case 'highBeam':
        uiTap('island-high-beam');
        vehicle.toggleHighBeam();
      case 'trunk':
        uiTap('island-trunk');
        vehicle.toggleTrunk();
      case 'back':
        uiTap('island-back');
        apps.returnFromIsland();
      case 'att' when kind == 'auto_park_lock':
        uiTap('island-back', {'from': kind});
        apps.returnFromIsland();
      // A tap on a warning or a note opens the panel, where it stays as
      // the note in the row. It never leaves the app: a brush against one
      // mid-ride once opened the dashboard.
      case 'att' when _passive(model):
        uiTap('island-expand', {'from': kind});
        _setExpanded(true, 'tap');
      case 'action' when kind == 'auto_park':
        uiTap('island-keep-riding');
        ref.read(safetyWatchdogProvider.notifier).cancel();
      case 'action' when kind == 'call':
        uiTap('island-call-accept');
        vehicle.acceptCall();
      case 'action2' when kind == 'call':
        uiTap('island-call-reject');
        vehicle.rejectCall();
      default:
        if (id.startsWith('app:') && !ref.read(ridingLockoutProvider)) {
          final current = ref.read(outsideAppProvider)?.id;
          final target = appCatalog.where((a) => a.id == id.substring(4) && (a.projection || a.id == current)).firstOrNull;
          if (target == null) return;
          uiTap('island-app', {'id': target.id});
          _expanded = false;
          apps.launch(target);
        }
    }
  }

  void _setExpanded(bool on, String cause) {
    _expanded = on;
    _collapse?.cancel();
    if (on) _armCollapse();
    _sync(cause);
  }

  void _armCollapse() {
    _collapse?.cancel();
    _collapse = Timer(ref.read(ridingLockoutProvider) ? expandedForMoving : expandedFor, () => _setExpanded(false, 'timeout'));
  }
}
