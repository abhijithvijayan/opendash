import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/app_catalog.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/dash_island.dart';
import 'package:opendash/state/passcode_gate.dart';
import 'package:opendash/state/prompt_surface.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/safety_screen.dart';
import 'package:opendash/state/safety_watchdog.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/toast_state.dart';

/// The mock is never "HHMIS-backed", so its speed is always trusted; this
/// one can be told the feed went away.
class _Vehicle extends VehicleNotifier {
  void debugUntrusted() => state = state.copyWith(hhmisBacked: true, hhmisConnected: false);
  void debugVolume(int level) => state = state.copyWith(volume: level);
  void debugCall() => state = state.copyWith(callIncoming: true);
}

class _Bridge implements IslandBridge {
  final sets = <Map<String, Object?>>[];
  final hides = <String>[];
  int pings = 0;
  void Function(String method, Map<Object?, Object?> args)? _handler;

  @override
  set onEvent(void Function(String method, Map<Object?, Object?> args)? handler) => _handler = handler;
  @override
  void set(Map<String, Object?> model) => sets.add(model);
  @override
  void hide(String reason) => hides.add(reason);
  @override
  void ping() => pings++;

  void emit(String method, [Map<Object?, Object?> args = const {}]) => _handler?.call(method, args);

  /// Kotlin confirming it drew the newest model.
  void confirm() => emit('shown', {'seq': sets.last['seq']});
}

List<Map<Object?, Object?>> _logged(String cat, String evt) =>
    [for (final e in AnalyticsLogger.instance.recent(cat, evt)) e['data']! as Map];

void main() {
  setUp(AnalyticsLogger.instance.resetForTest);

  final auto = appCatalog.firstWhere((a) => a.id == 'android-auto');

  void island(
    void Function(FakeAsync async, ProviderContainer c, _Bridge b, MockPlatformService platform, _Vehicle v) body,
  ) {
    fakeAsync((async) {
      final bridge = _Bridge();
      final platform = MockPlatformService()..setInstalled(auto.package);
      final c = ProviderContainer(overrides: [
        platformServiceProvider.overrideWithValue(platform),
        islandBridgeProvider.overrideWithValue(bridge),
        vehicleProvider.overrideWith(_Vehicle.new),
      ]);
      for (final p in [sessionProvider, toastProvider, appManagerProvider, mockAppProvider, safetyScreenProvider, safetyWatchdogProvider, dashIslandProvider]) {
        c.listen(p, (_, _) {});
      }
      final v = (c.read(vehicleProvider.notifier) as _Vehicle)
        ..setConnected(true)
        ..setLocked(false);
      body(async, c, bridge, platform, v);
      c.dispose();
    });
  }

  /// Opens [app] and puts OpenDash behind it, as the activity lifecycle does.
  void open(FakeAsync async, ProviderContainer c, CatalogApp app) {
    c.read(appManagerProvider.notifier).launch(app);
    async.flushMicrotasks();
    c.read(promptSurfaceVisibleProvider.notifier).screenShown(false);
    async.flushMicrotasks();
  }

  void ride(VehicleNotifier v, [int speed = 30]) {
    v.setVehicleState(VehicleState.riding);
    v.setSpeed(speed);
  }

  group('when it shows', () {
    test('it shows over an app once OpenDash is behind it, and not the pill', () {
      island((async, c, b, platform, v) {
        ride(v, 47);
        c.read(appManagerProvider.notifier).launch(auto);
        async.flushMicrotasks();
        expect(b.sets, isEmpty, reason: 'OpenDash is still in front');
        c.read(promptSurfaceVisibleProvider.notifier).screenShown(false);
        expect(b.sets.last['state'], 'collapsed');
        expect(b.sets.last['speed'], '47');
        expect(b.sets.last['app'], auto.id);
      });
    });

    test('it rides over the open Diagnostics tab: the speedo on top, hidden again when stopped', () {
      island((async, c, b, platform, v) {
        c.listen(diagnosticsOpenProvider, (_, _) {});
        // Opened stopped; on our own screen the island stays hidden.
        c.read(diagnosticsOpenProvider.notifier).open();
        expect(c.read(diagnosticsOpenProvider), isTrue);
        async.flushMicrotasks();
        expect(b.sets, isEmpty, reason: 'stopped on our own screen, nothing to show');
        // Start riding: the island appears over the tab with the speedo, and
        // carries over_self so the native side draws it in front.
        ride(v, 42);
        async.flushMicrotasks();
        expect(b.sets.last['app'], 'diagnostics-ride');
        expect(b.sets.last['over_self'], isTrue);
        expect(b.sets.last['speed'], '42');
        expect(b.sets.last['moving'], isTrue);
        // Briefly stop: latched, so the speedo stays (no stop-and-go flicker),
        // reading 0 rather than vanishing.
        v.setSpeed(0);
        v.setVehicleState(VehicleState.ready);
        async.flushMicrotasks();
        expect(b.sets.last['app'], 'diagnostics-ride', reason: 'latched: no flicker on a stop');
        expect(b.sets.last['speed'], '0');
        // Closing the tab drops the latch and hides the island.
        c.read(diagnosticsOpenProvider.notifier).close();
        async.flushMicrotasks();
        expect(b.hides.last, 'no_app', reason: 'tab closed, island hidden');
      });
    });

    test('over the stock dashboard it is only the way back: there is no data to show', () {
      island((async, c, b, platform, v) {
        ride(v, 40);
        c.read(appManagerProvider.notifier).trackOutsideStock();
        async.flushMicrotasks();
        c.read(promptSurfaceVisibleProvider.notifier).screenShown(false);
        expect(b.sets.last['pill'], isTrue);
        expect(b.sets.last.containsKey('speed'), isFalse);
        b.confirm();
        expect(c.read(promptSurfaceVisibleProvider), isFalse);
        b.emit('tap', {'id': 'row'});
        async.flushMicrotasks();
        expect(platform.broughtToFront, 1);
      });
    });

    test('opening an app from Apps closes Apps, so coming back lands on the dashboard', () {
      island((async, c, b, platform, v) {
        c.listen(appLauncherOpenProvider, (_, _) {});
        c.read(appLauncherOpenProvider.notifier).open();
        expect(c.read(appLauncherOpenProvider), isTrue);
        open(async, c, auto);
        expect(c.read(appLauncherOpenProvider), isFalse);
      });
    });

    test('it goes when OpenDash comes back to the front', () {
      island((async, c, b, platform, v) {
        open(async, c, auto);
        c.read(promptSurfaceVisibleProvider.notifier).screenShown(true);
        expect(c.read(dashIslandProvider), isNull);
        expect(b.hides.last, 'foreground');
      });
    });

    test('it goes for an emergency screen', () {
      island((async, c, b, platform, v) {
        ride(v);
        open(async, c, auto);
        v.setAccident(true);
        async.elapse(const Duration(seconds: 2));
        expect(c.read(dashIslandProvider), isNull);
        expect(b.hides.last, 'safety_screen');
        expect(platform.broughtToFront, 1);
      });
    });
  });

  group('lock', () {
    test('locking behind an app removes the island and brings the lock screen forward', () {
      island((async, c, b, platform, v) {
        open(async, c, auto);
        b.confirm();
        v.setLocked(true);
        async.flushMicrotasks();
        expect(c.read(dashIslandProvider), isNull);
        expect(b.hides.last, 'locked');
        expect(_logged('apps', 'lock_return').single, {'id': auto.id});
        expect(platform.broughtToFront, 1);
        expect(c.read(promptSurfaceVisibleProvider), isFalse);
      });
    });

    test('no model is sent and no tap is taken while locked', () {
      island((async, c, b, platform, v) {
        open(async, c, auto);
        v.setLocked(true);
        async.flushMicrotasks();
        final sent = b.sets.length;
        v.setSpeed(12);
        v.setHighBeam(true);
        b.emit('tap', {'id': 'hazard'});
        b.emit('tap', {'id': 'trunk'});
        async.flushMicrotasks();
        expect(b.sets.length, sent);
        expect(c.read(vehicleProvider).hazard, isFalse);
      });
    });
  });

  group('collapsed content', () {
    test('parked shows P and the range', () {
      island((async, c, b, platform, v) {
        v.setVehicleState(VehicleState.parked);
        open(async, c, auto);
        expect(b.sets.last['speed'], 'P');
        expect(b.sets.last['note'], '${c.read(vehicleProvider).range} km');
      });
    });

    // From a rider: "we don't know what mode the scooter is in".
    test('the drive mode is on the row in words while under way, and not when parked', () {
      island((async, c, b, platform, v) {
        ride(v, 40);
        open(async, c, auto);
        v.setDriveMode(DriveMode.sport);
        async.flushMicrotasks();
        expect(b.sets.last['mode'], 'SPORT');
        v.setDriveMode(DriveMode.eco);
        async.flushMicrotasks();
        expect(b.sets.last['mode'], 'ECO');
        v.setSpeed(0);
        v.setVehicleState(VehicleState.parked);
        async.flushMicrotasks();
        expect(b.sets.last['mode'], '');
      });
    });

    test('untrusted data is dashes and a notice, never a number', () {
      island((async, c, b, platform, v) {
        ride(v, 40);
        open(async, c, auto);
        v.debugUntrusted();
        async.flushMicrotasks();
        expect(c.read(vehicleProvider).speedTrusted, isFalse);
        final m = b.sets.last;
        expect(m['speed'], '––');
        expect(m['soc'], isNull);
        expect(m['note'], 'Data not live');
        expect(m['left'], isFalse);
      });
    });

    // "Data not live" on the island and nothing to do about it from
    // there. OpenDash mends its link only when in front.
    test('with the data not live, a tap on the island is the way back, not the panel', () {
      island((async, c, b, platform, v) {
        ride(v, 40);
        open(async, c, auto);
        b.confirm();
        v.debugUntrusted();
        async.flushMicrotasks();
        b.emit('tap', {'id': 'row'});
        async.flushMicrotasks();
        expect(platform.broughtToFront, 1);
        expect(b.sets.any((m) => m['state'] == 'expanded'), isFalse);
      });
    });

    test('a field the island does not draw sends nothing', () {
      island((async, c, b, platform, v) {
        ride(v);
        open(async, c, auto);
        final sent = b.sets.length;
        for (var i = 0; i < 100; i++) {
          v.setMotorTemp(40 + i % 20);
        }
        async.flushMicrotasks();
        expect(b.sets.length, sent);
        v.setSpeed(31);
        expect(b.sets.length, sent + 1);
      });
    });

    test('a keep-alive goes out every second while it is up', () {
      island((async, c, b, platform, v) {
        open(async, c, auto);
        async.elapse(const Duration(seconds: 3));
        expect(b.pings, 3);
      });
    });
  });

  group('expanded', () {
    test('stopped, the boot button is on the collapsed island; a tap on the row opens the controls', () {
      island((async, c, b, platform, v) {
        v.setVehicleState(VehicleState.parked);
        open(async, c, auto);
        expect(b.sets.last['trunk'], isTrue);
        b.emit('tap', {'id': 'row'});
        final m = b.sets.last;
        expect(m['state'], 'expanded');
        expect([for (final x in m['controls']! as List) (x as Map)['id']], ['hazard', 'highBeam', 'trunk']);
        async.elapse(DashIsland.expandedFor);
        expect(b.sets.last['state'], 'collapsed');
      });
    });

    test('stopped, the projection app in use is the first shortcut: the way back from a page it opened', () {
      island((async, c, b, platform, v) {
        v.setVehicleState(VehicleState.parked);
        open(async, c, auto);
        b.emit('tap', {'id': 'row'});
        final shortcuts = [for (final x in b.sets.last['apps']! as List) (x as Map)['id']];
        expect(shortcuts.first, auto.id,
            reason: 'from a settings page CarPlay had opened, the island offered no way back to CarPlay');
        AnalyticsLogger.instance.resetForTest();
        b.emit('tap', {'id': 'app:${auto.id}'});
        async.flushMicrotasks();
        expect(AnalyticsLogger.instance.recent('ui', 'tap').map((e) => (e['data']! as Map)['target']), contains('island-app'));
        expect(c.read(outsideAppProvider)?.id, auto.id);
      });
    });

    test('with usage access the way back to the app is offered only while another screen is over it', () {
      island((async, c, b, platform, v) {
        v.setVehicleState(VehicleState.parked);
        List<Object?> shortcuts() => [for (final x in b.sets.last['apps']! as List) (x as Map)['id']];
        platform.frontPackage = auto.package;
        open(async, c, auto);
        async.elapse(const Duration(seconds: 2));
        b.emit('tap', {'id': 'row'});
        expect(shortcuts(), isNot(contains(auto.id)), reason: 'Android Auto itself is in front');
        platform.frontPackage = 'com.android.settings';
        async.elapse(const Duration(seconds: 2));
        expect(shortcuts().first, auto.id, reason: 'a settings page it opened is in front');
        expect(AnalyticsLogger.instance.recent('island', 'front').last['data'], containsPair('same', false));
        platform.frontPackage = auto.package;
        async.elapse(const Duration(seconds: 2));
        expect(shortcuts(), isNot(contains(auto.id)));
      });
    });

    test('on a page whose touches Android keeps, the scooter is told it is in use for three minutes after each sign of the rider', () {
      island((async, c, b, platform, v) {
        AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
        addTearDown(() => AnalyticsLogger.instance.monoOverride = null);
        v.setVehicleState(VehicleState.parked);
        platform.frontPackage = auto.package;
        open(async, c, auto);
        async.elapse(const Duration(seconds: 2));
        expect(b.sets.last['awake'], isFalse, reason: 'the app itself is in front: its touches are heard');
        // A settings page it opened: Android passes on no touches there.
        platform.frontPackage = 'com.android.settings';
        async.elapse(const Duration(seconds: 2));
        expect(b.sets.last['awake'], isTrue,
            reason: 'locked a minute into Android Settings, whose touches the island never hears');
        async.elapse(DashIsland.presenceFor);
        expect(b.sets.last['awake'], isFalse, reason: 'left alone: the vehicle locks 61 s from here');
        b.emit('outside', {});
        expect(b.sets.last['awake'], isTrue, reason: 'a sign of the rider');
      });
    });

    // Parked with CarPlay in front after a ride, two
    // minutes without a touch, nothing locked and nothing said when it would.
    test('a projection app is not kept awake; the island counts down to the lock and a touch clears it', () {
      island((async, c, b, platform, v) {
        AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
        addTearDown(() => AnalyticsLogger.instance.monoOverride = null);
        v.setVehicleState(VehicleState.parked);
        v.setSideStand(true);
        platform.frontPackage = auto.package;
        open(async, c, auto);
        const after = AidlVehicleNotifier.idleLockAfter;
        const warn = AidlVehicleNotifier.idleLockWarning;
        Map<Object?, Object?>? sub() => b.sets.last['sub'] as Map<Object?, Object?>?;
        // Let the "which app is in front" reading settle, then one touch
        // to count from.
        async.elapse(const Duration(seconds: 5));
        b.emit('outside', {});

        async.elapse(after - warn - const Duration(seconds: 2));
        expect(b.sets.last['awake'], isFalse);
        expect(sub(), isNull);
        async.elapse(const Duration(seconds: 3));
        expect(sub()!['text'], startsWith('Locking in '));
        expect(sub()!['bar'], inInclusiveRange(0.8, 1.0));
        final first = sub()!['text'];
        async.elapse(const Duration(seconds: 5));
        expect(sub()!['text'], isNot(first), reason: 'it counts down');
        expect(AnalyticsLogger.instance.recent('safety', 'idle_lock_warning').single['data'], containsPair('where', 'island'));

        b.emit('outside', {});
        expect(sub(), isNull, reason: 'a touch under the island');
        async.elapse(after - warn - const Duration(seconds: 2));
        expect(sub(), isNull, reason: 'the minute starts again');
        async.elapse(warn + const Duration(seconds: 3));
        expect(sub()!['text'], 'Locking');
        b.emit('touch', {});
        expect(sub(), isNull, reason: 'a finger on the island itself');
      });
    });

    // Seen on a scooter: "Locking in 10 s" the moment the scooter stopped
    // with CarPlay in front, 51 s after the last touch; it was still
    // unlocked 43 s later.
    test('coming to a stop starts the minute: no warning for a touch made while riding', () {
      island((async, c, b, platform, v) {
        AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
        addTearDown(() => AnalyticsLogger.instance.monoOverride = null);
        const after = AidlVehicleNotifier.idleLockAfter;
        const warn = AidlVehicleNotifier.idleLockWarning;
        ride(v);
        platform.frontPackage = auto.package;
        open(async, c, auto);
        b.emit('outside', {});
        async.elapse(const Duration(seconds: 51));
        v.setSpeed(0);
        v.setVehicleState(VehicleState.parked);
        v.setSideStand(true);
        async.elapse(const Duration(seconds: 20));
        bool warned() => b.sets.any((m) => m['sub'] is Map && '${(m['sub'] as Map)['text']}'.startsWith('Locking'));
        expect(warned(), isFalse, reason: 'twenty seconds after the stop');
        async.elapse(after - warn - const Duration(seconds: 15));
        expect(warned(), isTrue, reason: 'a minute after the stop, less the warning');
      });
    });

    // "Locking" stood on the island for 40 s over a scooter that
    // stayed unlocked, with "0%" beside it.
    test('a lock that does not come takes the row down, and the row carries no percent', () {
      island((async, c, b, platform, v) {
        AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
        addTearDown(() => AnalyticsLogger.instance.monoOverride = null);
        v.setVehicleState(VehicleState.parked);
        v.setSideStand(true);
        platform.frontPackage = auto.package;
        open(async, c, auto);
        async.elapse(const Duration(seconds: 5));
        b.emit('outside', {});
        Map<Object?, Object?>? sub() => b.sets.last['sub'] as Map<Object?, Object?>?;
        async.elapse(AidlVehicleNotifier.idleLockAfter + const Duration(seconds: 2));
        expect(sub()!['text'], 'Locking');
        expect(sub()!['percent'], isFalse);
        async.elapse(AidlVehicleNotifier.idleLockOverdue + const Duration(seconds: 2));
        expect(sub(), isNull, reason: 'the guess was wrong');
        expect(AnalyticsLogger.instance.recent('safety', 'idle_lock_warning').last['data'], containsPair('outcome', 'overdue'));
        async.elapse(const Duration(minutes: 2));
        expect(sub(), isNull, reason: 'and it does not come back by itself');
        b.emit('outside', {});
        async.elapse(AidlVehicleNotifier.idleLockAfter - const Duration(seconds: 5));
        expect(sub()!['text'], startsWith('Locking in '), reason: 'a new touch starts a new minute');
      });
    });

    // The island's boot button over Android Settings,
    // pressed 24 times, refused each time ("background") with nothing said.
    test('a tap on the island is carried out over a page where the island is not a prompt surface', () {
      island((async, c, b, platform, v) {
        v.setVehicleState(VehicleState.parked);
        platform.frontPackage = auto.package;
        open(async, c, auto);
        // Not confirmed as showing: the state the island is in over a
        // system page, where it is never counted as a prompt surface.
        expect(c.read(promptSurfaceVisibleProvider), isFalse);
        expect(b.sets, isNotEmpty);
        AnalyticsLogger.instance.resetForTest();
        b.emit('tap', {'id': 'trunk'});
        async.flushMicrotasks();
        expect(AnalyticsLogger.instance.recent('safety', 'untrusted_refused'), isEmpty);
        expect(islandTapInHand, isFalse, reason: 'only for the length of the tap');
      });
    });

    test('no charge figure before the scooter has sent one', () {
      island((async, c, b, platform, v) {
        ride(v);
        platform.frontPackage = auto.package;
        open(async, c, auto);
        expect(b.sets.last['soc'], v.state.socKnown ? isNotNull : isNull);
      });
    });

    test('no countdown while moving, while charging, or over the stock dashboard', () {
      island((async, c, b, platform, v) {
        AnalyticsLogger.instance.monoOverride = () => async.elapsed.inMicroseconds;
        addTearDown(() => AnalyticsLogger.instance.monoOverride = null);
        ride(v);
        platform.frontPackage = auto.package;
        open(async, c, auto);
        async.elapse(AidlVehicleNotifier.idleLockAfter + const Duration(seconds: 5));
        expect(b.sets.any((m) => m['sub'] is Map && '${(m['sub'] as Map)['text']}'.startsWith('Locking')), isFalse);
      });
    });

    test('moving: no boot, no apps, and it closes after five seconds', () {
      island((async, c, b, platform, v) {
        ride(v);
        open(async, c, auto);
        b.emit('tap', {'id': 'row'});
        final m = b.sets.last;
        expect(m['trunk'], isFalse);
        expect([for (final x in m['controls']! as List) (x as Map)['id']], ['hazard', 'highBeam']);
        expect(m['apps'], isEmpty);
        async.elapse(DashIsland.expandedForMoving - const Duration(milliseconds: 1));
        expect(b.sets.last['state'], 'expanded');
        async.elapse(const Duration(milliseconds: 1));
        expect(b.sets.last['state'], 'collapsed');
      });
    });

    test('a touch on the app underneath closes it', () {
      island((async, c, b, platform, v) {
        open(async, c, auto);
        b.emit('tap', {'id': 'row'});
        b.emit('outside');
        expect(b.sets.last['state'], 'collapsed');
      });
    });

    test('hazard goes through the dashboard\'s own control', () {
      island((async, c, b, platform, v) {
        open(async, c, auto);
        b.emit('tap', {'id': 'row'});
        b.emit('tap', {'id': 'hazard'});
        expect(c.read(vehicleProvider).hazard, isTrue);
        expect(b.sets.last['left'], isTrue);
      });
    });

    test('back brings the dashboard forward and keeps the way back to the app', () {
      island((async, c, b, platform, v) {
        ride(v);
        open(async, c, auto);
        b.emit('tap', {'id': 'back'});
        async.flushMicrotasks();
        expect(platform.broughtToFront, 1);
        expect(c.read(projectionResumeProvider), auto);
      });
    });

    test('a control\'s own toast does not take the panel away', () {
      island((async, c, b, platform, v) {
        open(async, c, auto);
        b.emit('tap', {'id': 'row'});
        c.read(toastProvider.notifier).show('High beam on');
        expect(b.sets.last['state'], 'expanded');
        expect(b.sets.last['note'], 'High beam on');
      });
    });
  });

  group('critical alerts over a projection app', () {
    void standDown(VehicleNotifier v) {
      v.setVehicleState(VehicleState.ready);
      v.setSideStand(true);
    }

    test('confirmed by Kotlin within a second: it stays in the island', () {
      island((async, c, b, platform, v) {
        open(async, c, auto);
        standDown(v);
        async.elapse(const Duration(milliseconds: 50));
        final m = b.sets.last;
        expect(m['state'], 'attention');
        expect((m['att']! as Map)['kind'], 'sideStand');
        expect((m['att']! as Map)['priority'], 'critical');
        b.confirm();
        async.elapse(const Duration(seconds: 2));
        expect(platform.broughtToFront, 0);
        expect(_logged('apps', 'emergency_return'), isEmpty);
        expect(_logged('island', 'confirmed'), hasLength(1));
      });
    });

    test('not confirmed: the dashboard comes forward, with the way back offered', () {
      island((async, c, b, platform, v) {
        open(async, c, auto);
        standDown(v);
        async.elapse(DashIsland.confirmWithin);
        expect(_logged('island', 'fallback_return'), hasLength(1));
        expect(_logged('apps', 'emergency_return'), hasLength(1));
        expect(platform.broughtToFront, 1);
        expect(c.read(projectionResumeProvider), auto);
      });
    });

    test('a confirmation for an older model does not count', () {
      island((async, c, b, platform, v) {
        open(async, c, auto);
        final before = b.sets.last['seq'];
        standDown(v);
        b.emit('shown', {'seq': before});
        async.elapse(DashIsland.confirmWithin);
        expect(platform.broughtToFront, 1);
      });
    });

    test('an alert that clears inside the second does not return', () {
      island((async, c, b, platform, v) {
        open(async, c, auto);
        standDown(v);
        v.setSideStand(false);
        async.elapse(DashIsland.confirmWithin);
        expect(platform.broughtToFront, 0);
      });
    });

    test('thermal runaway always brings the dashboard forward', () {
      island((async, c, b, platform, v) {
        ride(v);
        open(async, c, auto);
        b.confirm();
        v.setThermalRunaway(true);
        async.flushMicrotasks();
        expect(platform.broughtToFront, 1);
        expect(_logged('island', 'fallback_return'), isEmpty);
      });
    });
  });

  group('prompt surface', () {
    test('a confirmed island over projection is a surface; the own-screen provider is not fooled', () {
      island((async, c, b, platform, v) {
        open(async, c, auto);
        expect(c.read(promptSurfaceVisibleProvider), isFalse, reason: 'not confirmed yet');
        b.confirm();
        expect(c.read(promptSurfaceVisibleProvider), isTrue);
        expect(c.read(ownScreenVisibleProvider), isFalse);
        b.emit('hidden', {'reason': 'system'});
        expect(c.read(promptSurfaceVisibleProvider), isFalse);
        b.confirm();
        b.emit('stale', {'on': true});
        expect(c.read(promptSurfaceVisibleProvider), isFalse);
      });
    });

    test('a prompt that needs the whole screen still cancels with the island up', () {
      island((async, c, b, platform, v) {
        c.listen(passcodeGateProvider, (_, _) {});
        c.read(passcodeGateProvider.notifier).request(purpose: 'test', onSuccess: () {});
        expect(c.read(passcodeGateProvider).open, isTrue);
        final surface = c.read(promptSurfaceVisibleProvider.notifier);
        surface.islandShown(true);
        surface.screenShown(false);
        expect(c.read(promptSurfaceVisibleProvider), isTrue);
        expect(c.read(passcodeGateProvider).open, isFalse);
        expect(_logged('safety', 'untrusted_cancel').last['reason'], 'background');
      });
    });

    test('over an app that is not projection it is never a surface', () {
      island((async, c, b, platform, v) {
        c.read(appManagerProvider.notifier).trackOutsidePackage('files', 'Files', 'com.example.files');
        async.flushMicrotasks();
        c.read(promptSurfaceVisibleProvider.notifier).screenShown(false);
        expect(b.sets, isNotEmpty);
        b.confirm();
        expect(c.read(promptSurfaceVisibleProvider), isFalse);
      });
    });

    test('auto-park counts down in the island and Keep riding answers it', () {
      island((async, c, b, platform, v) {
        c.read(ridingSettingsProvider.notifier).setAutoLockEnabled(true);
        open(async, c, auto);
        b.confirm();
        v.setVehicleState(VehicleState.ready);
        v.setSpeed(20);
        v.setSideStand(true);
        v.setSpeed(0);
        async.flushMicrotasks();
        expect(c.read(safetyWatchdogProvider).armed, isTrue);
        expect(_logged('apps', 'prompt_return'), isEmpty);
        final att = b.sets.last['att']! as Map;
        expect(att['kind'], 'auto_park');
        expect(att['action'], 'Keep riding');
        async.elapse(const Duration(seconds: 1));
        expect((b.sets.last['att']! as Map)['badge'], '4');
        b.emit('tap', {'id': 'action'});
        expect(c.read(safetyWatchdogProvider).armed, isFalse);
        expect(_logged('safety', 'watchdog_cancel').last['reason'], 'user');
        async.elapse(const Duration(seconds: 10));
        expect(c.read(vehicleProvider).locked, isFalse);
      });
    });

    test('auto-park cancels when the island is lost mid-countdown', () {
      island((async, c, b, platform, v) {
        c.read(ridingSettingsProvider.notifier).setAutoLockEnabled(true);
        open(async, c, auto);
        b.confirm();
        v.setVehicleState(VehicleState.ready);
        v.setSpeed(20);
        v.setSideStand(true);
        v.setSpeed(0);
        async.elapse(const Duration(seconds: 2));
        b.emit('hidden', {'reason': 'system'});
        expect(c.read(safetyWatchdogProvider).armed, isFalse);
        expect(_logged('safety', 'watchdog_cancel').last['reason'], 'background');
      });
    });

    test('auto-park without a confirmed island asks for the dashboard, as before', () {
      island((async, c, b, platform, v) {
        c.read(ridingSettingsProvider.notifier).setAutoLockEnabled(true);
        open(async, c, auto);
        v.setVehicleState(VehicleState.ready);
        v.setSpeed(20);
        v.setSideStand(true);
        v.setSpeed(0);
        async.flushMicrotasks();
        expect(c.read(safetyWatchdogProvider).armed, isFalse);
        expect(_logged('apps', 'prompt_return'), hasLength(1));
      });
    });
  });

  group('messages', () {
    test('an ordinary toast is a line on the island and does not grow it', () {
      island((async, c, b, platform, v) {
        ride(v);
        open(async, c, auto);
        c.read(toastProvider.notifier).show('Bluetooth connected');
        expect(b.sets.last['state'], 'collapsed');
        expect((b.sets.last['sub']! as Map)['text'], 'Bluetooth connected', reason: 'a line under the row, not the space beside the battery');
        async.elapse(DashIsland.toastFor);
        expect(b.sets.last['sub'], isNull);
      });
    });

    test('a refusal grows it, and a tap opens the panel with it as the note, without leaving the app', () {
      island((async, c, b, platform, v) {
        ride(v);
        open(async, c, auto);
        c.read(toastProvider.notifier).show('Stop to open the boot', type: ToastType.warning);
        expect(b.sets.last['state'], 'attention');
        expect((b.sets.last['att']! as Map)['badge'], '!');
        b.emit('tap', {'id': 'att'});
        async.flushMicrotasks();
        expect(b.sets.last['state'], 'expanded');
        expect(b.sets.last['att'], isNull);
        expect(platform.broughtToFront, 0);
      });
    });

    test('a tap on a critical alert does nothing', () {
      island((async, c, b, platform, v) {
        open(async, c, auto);
        v.setVehicleState(VehicleState.ready);
        v.setSideStand(true);
        async.elapse(const Duration(milliseconds: 50));
        b.confirm();
        b.emit('tap', {'id': 'att'});
        async.flushMicrotasks();
        expect(b.sets.last['state'], 'attention');
        expect(platform.broughtToFront, 0);
      });
    });

    test('the handlebar volume buttons show the level for two seconds', () {
      island((async, c, b, platform, v) {
        ride(v);
        open(async, c, auto);
        v.debugVolume(70);
        expect(b.sets.last['sub'], {'text': 'Volume', 'bar': 0.7});
        expect(b.sets.last['state'], 'collapsed');
        async.elapse(DashIsland.volumeFor);
        expect(b.sets.last['sub'], isNull);
      });
    });

    test('an incoming call shows over a projection app too', () {
      island((async, c, b, platform, v) {
        open(async, c, auto);
        v.debugCall();
        final att = b.sets.last['att']! as Map;
        expect(att['kind'], 'call');
        expect(att['action'], 'Accept');
        expect(att['action2'], 'Reject');
      });
    });
  });

  group('Android pages opened from Settings', () {
    test('the hotspot page asks for the passcode first, and is refused on the move', () {
      island((async, c, b, platform, v) {
        c.listen(passcodeGateProvider, (_, _) {});
        final apps = c.read(appManagerProvider.notifier);
        ride(v);
        apps.openSystemPage('hotspot', 'Hotspot');
        expect(c.read(passcodeGateProvider).open, isFalse);
        v.setSpeed(0);
        v.setVehicleState(VehicleState.parked);
        apps.openSystemPage('hotspot', 'Hotspot');
        expect(c.read(passcodeGateProvider).open, isTrue);
        expect(platform.systemPages, isEmpty, reason: 'nothing opens before the passcode');
      });
    });
  });

  group('music access', () {
    test('asked once, the first time a projection app is opened; the app opens on the way back', () {
      island((async, c, b, platform, v) {
        platform.notificationAccess = false;
        final apps = c.read(appManagerProvider.notifier);
        apps.launch(auto);
        async.flushMicrotasks();
        expect(platform.systemPages, ['notification_access']);
        expect(platform.launched, isEmpty);
        expect(c.read(outsideAppProvider)?.id, 'system-notification_access');
        apps.onResume();
        async.flushMicrotasks();
        expect(c.read(outsideAppProvider), auto, reason: 'opened whether or not access was given');
        apps.onResume();
        async.flushMicrotasks();
        apps.launch(auto);
        async.flushMicrotasks();
        expect(platform.systemPages, hasLength(1), reason: 'not asked again');
      });
    });

    test('not asked on the move', () {
      island((async, c, b, platform, v) {
        platform.notificationAccess = false;
        ride(v);
        c.read(appManagerProvider.notifier).launch(auto);
        async.flushMicrotasks();
        expect(platform.systemPages, isEmpty);
        expect(c.read(outsideAppProvider), auto);
      });
    });
  });

  group('Chrome preview', () {
    test('with the preview on, the island is built as if CarPlay were in front; off, it is gone', () {
      island((async, c, b, platform, v) {
        ride(v, 37);
        expect(c.read(dashIslandProvider), isNull);
        c.read(islandPreviewProvider.notifier).set('light map');
        final m = c.read(dashIslandProvider)!;
        expect(m.content['app'], 'carplay');
        expect(m.content['speed'], '37');
        c.read(dashIslandProvider.notifier).previewEvent('tap', {'id': 'row'});
        expect(c.read(dashIslandProvider)!.state, 'expanded');
        c.read(islandPreviewProvider.notifier).set(null);
        expect(c.read(dashIslandProvider), isNull);
      });
    });

    test('the preview never counts as a prompt surface', () {
      island((async, c, b, platform, v) {
        c.read(islandPreviewProvider.notifier).set('dark map');
        c.read(dashIslandProvider.notifier).previewEvent('shown', {'seq': c.read(dashIslandProvider)!.seq});
        c.read(promptSurfaceVisibleProvider.notifier).screenShown(false);
        expect(c.read(promptSurfaceVisibleProvider), isFalse);
      });
    });
  });

  group('warnings', () {
    // The speed-limit warning closed the panel under
    // the rider's finger, then stood six seconds in the way of opening it.
    test('a warning does not take an open panel: it is the note in the row', () {
      island((async, c, b, platform, v) {
        ride(v);
        open(async, c, auto);
        b.emit('tap', {'id': 'row'});
        async.flushMicrotasks();
        expect(b.sets.last['state'], 'expanded');
        v.setTrunkOpen(true);
        async.elapse(const Duration(milliseconds: 50));
        final m = b.sets.last;
        expect(m['state'], 'expanded');
        expect(m['att'], isNull);
        expect(m['note'], isNot(''));
        expect(m['noteStrong'], isTrue);
      });
    });

    test('a tap on a warning opens the panel instead of waiting it out', () {
      island((async, c, b, platform, v) {
        ride(v);
        open(async, c, auto);
        v.setTrunkOpen(true);
        async.elapse(const Duration(milliseconds: 50));
        expect(b.sets.last['state'], 'attention');
        b.emit('tap', {'id': 'att'});
        async.flushMicrotasks();
        expect(b.sets.last['state'], 'expanded');
        expect(platform.broughtToFront, 0);
      });
    });

    test('the row above a warning opens the panel too', () {
      island((async, c, b, platform, v) {
        ride(v);
        open(async, c, auto);
        v.setTrunkOpen(true);
        async.elapse(const Duration(milliseconds: 50));
        expect(b.sets.last['state'], 'attention');
        b.emit('tap', {'id': 'row'});
        async.flushMicrotasks();
        expect(b.sets.last['state'], 'expanded');
      });
    });

    test('a critical alert still takes the island from an open panel', () {
      island((async, c, b, platform, v) {
        open(async, c, auto);
        v.setVehicleState(VehicleState.ready);
        b.emit('tap', {'id': 'row'});
        async.flushMicrotasks();
        v.setSideStand(true);
        async.elapse(const Duration(milliseconds: 50));
        expect(b.sets.last['state'], 'attention');
        expect((b.sets.last['att']! as Map)['priority'], 'critical');
      });
    });

    // From a rider: it shrank to a coloured dot after six seconds.
    test('a warning stays, in words, for as long as it is true; never a dot', () {
      island((async, c, b, platform, v) {
        ride(v);
        open(async, c, auto);
        v.setTrunkOpen(true);
        async.elapse(const Duration(milliseconds: 50));
        expect((b.sets.last['att']! as Map)['kind'], 'trunkOpen');
        async.elapse(const Duration(seconds: 30));
        expect(b.sets.last['state'], 'attention');
        expect((b.sets.last['att']! as Map)['kind'], 'trunkOpen');
        expect(b.sets.every((m) => m['dot'] != true), isTrue);
        v.setTrunkOpen(false);
        async.elapse(const Duration(milliseconds: 50));
        expect(b.sets.last['state'], 'collapsed');
        expect(b.sets.last['att'], isNull);
      });
    });

    test('the panel over a standing warning closes back to the warning', () {
      island((async, c, b, platform, v) {
        ride(v);
        open(async, c, auto);
        v.setTrunkOpen(true);
        async.elapse(const Duration(milliseconds: 50));
        b.emit('tap', {'id': 'att'});
        async.flushMicrotasks();
        expect(b.sets.last['state'], 'expanded');
        expect(b.sets.last['noteStrong'], isTrue);
        async.elapse(const Duration(seconds: 10));
        expect(b.sets.last['state'], 'attention', reason: 'the panel closes by itself on the move; the warning is still true');
      });
    });
  });
}
