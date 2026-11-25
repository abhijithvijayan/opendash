import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/hhmis_mapping.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/models/ota_shield.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:opendash/state/firmware_state.dart';
import 'package:opendash/state/passcode_gate.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/stock.dart';

List<Map<String, Object?>> _log(String evt) =>
    [for (final e in AnalyticsLogger.instance.recent('fw', evt)) (e['data'] as Map).cast<String, Object?>()];

void main() {
  setUp(() async {
    AnalyticsLogger.instance.resetForTest();
    SharedPreferences.setMockInitialValues({});
    await PrefsService.init();
  });
  tearDown(() {
    PrefsService.resetForTest();
    debugUseAidlVehicle = null;
  });

  ProviderContainer mock() {
    final c = ProviderContainer(overrides: [platformServiceProvider.overrideWithValue(MockPlatformService())]);
    addTearDown(c.dispose);
    c.read(vehicleProvider.notifier).setLocked(false);
    c.listen(firmwareProvider, (_, _) {});
    return c;
  }

  const available = {'kind': 'available', 'button': true, 'reason': 0, 'version': '4.7.1', 'size': '431000000', 'notes': '{"releaseNotes": ["note one", "note two"]}'};

  group('the stock auto-download setting', () {
    test('ServerCmd 144 is mapped, not ignored, and null until seen', () {
      expect(ignoredHhmisKeys, isNot(contains('AUTODOWNLOAD_UPDATE')));
      expect(const VehicleData().stockAutoDownload, isNull);
      expect(applyHhmisUpdate(const VehicleData(), {'AUTODOWNLOAD_UPDATE': 1}).stockAutoDownload, 1);
      expect(applyHhmisUpdate(const VehicleData(), {'AUTODOWNLOAD_UPDATE': 0}).stockAutoDownload, 0);
    });

    /// A bridge container; returns the commands that reached the channel.
    (ProviderContainer, AidlVehicleNotifier, List<(String, Object?)>) bridge(FakeAsync async) {
      final events = StreamController<dynamic>();
      final calls = <(String, Object?)>[];
      final c = ProviderContainer(overrides: [
        vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), 
              events: events.stream,
              invoke: (m, a) async {
                calls.add((m, a));
                return true;
              },
            )),
      ]);
      addTearDown(() {
        c.dispose();
        events.close();
      });
      final n = c.read(vehicleProvider.notifier) as AidlVehicleNotifier;
      c.listen(firmwareProvider, (_, _) {});
      async.flushMicrotasks();
      return (c, n, calls);
    }

    List<Object?> sent53(List<(String, Object?)> calls) => [
          for (final (m, a) in calls)
            if (m == 'sendIntCmd' && a is Map && a['cmd'] == HhmisCmd.autoDownloadUpdate) a['value'],
        ];

    test('nothing is sent before a value has been seen', () {
      fakeAsync((async) {
        final (c, n, calls) = bridge(async);
        n.onEvent({'_connected': true, '_unlocked': true, 'INT_VEHICLE_SPEED': 0});
        async.elapse(const Duration(seconds: 30));
        expect(sent53(calls), isEmpty);
        expect(c.read(firmwareProvider).autoDownloadFirst, isNull);
      });
    });

    test('a 1 is switched to 0 once, after unlock, and the first value is kept', () {
      fakeAsync((async) {
        final (c, n, calls) = bridge(async);
        n.onEvent({'_connected': true, 'AUTODOWNLOAD_UPDATE': 1});
        async.elapse(const Duration(seconds: 5));
        expect(c.read(vehicleProvider).locked, isTrue);
        expect(sent53(calls), isEmpty, reason: 'not while locked');
        n.onEvent({'_unlocked': true});
        async.elapse(const Duration(seconds: 1));
        expect(sent53(calls), [0]);
        expect(_log('autodl').first, {'value': 1, 'source': 'vehicle', 'first_seen': 1});
        expect(_log('autodl').last, containsPair('source', 'sent'));

        // The vehicle replays the stored 0, then (say the stock dashboard
        // was used) a 1 again: once per process means no second send.
        n.onEvent({'AUTODOWNLOAD_UPDATE': 0});
        n.onEvent({'AUTODOWNLOAD_UPDATE': 1});
        async.elapse(const Duration(seconds: 5));
        expect(sent53(calls), [0]);
        expect(c.read(firmwareProvider).autoDownloadFirst, 1, reason: 'never overwritten');
        expect(PrefsService.getInt(PrefsKeys.fwStockAutoDownloadFirst, -1), 1);
      });
    });

    test('a 0 is left alone', () {
      fakeAsync((async) {
        final (c, n, calls) = bridge(async);
        n.onEvent({'_connected': true, '_unlocked': true, 'AUTODOWNLOAD_UPDATE': 0});
        async.elapse(const Duration(seconds: 5));
        expect(sent53(calls), isEmpty);
        expect(c.read(firmwareProvider).autoDownloadFirst, 0);
      });
    });

    test('restore sends the first-seen value and stops the switching-off', () {
      fakeAsync((async) {
        final (c, n, calls) = bridge(async);
        n.onEvent({'_connected': true, '_unlocked': true, 'AUTODOWNLOAD_UPDATE': 1});
        async.elapse(const Duration(seconds: 1));
        expect(sent53(calls), [0]);
        n.onEvent({'AUTODOWNLOAD_UPDATE': 0});
        c.read(firmwareProvider.notifier).restoreStock();
        async.elapse(const Duration(seconds: 1));
        expect(sent53(calls), [0, 1]);
        expect(c.read(firmwareProvider).restored, isTrue);
        expect(_log('autodl').last, containsPair('restore', true));
        n.onEvent({'AUTODOWNLOAD_UPDATE': 1});
        async.elapse(const Duration(seconds: 5));
        expect(sent53(calls), [0, 1], reason: 'never in the restored state');
      });
    });

    test('restored at start: no send, no subscription; with none seen the restore value is 1', () {
      SharedPreferences.setMockInitialValues({PrefsKeys.fwRestored: true});
      fakeAsync((async) {
        PrefsService.init();
        async.flushMicrotasks();
        final (c, n, calls) = bridge(async);
        n.onEvent({'_connected': true, '_unlocked': true, 'AUTODOWNLOAD_UPDATE': 1});
        async.elapse(const Duration(seconds: 5));
        expect(sent53(calls), isEmpty);
        expect(calls.where((x) => x.$1 == 'subscribeFirmware'), isEmpty);
        expect(_log('subscribed'), isEmpty);
      });
      SharedPreferences.setMockInitialValues({});
      fakeAsync((async) {
        PrefsService.init();
        async.flushMicrotasks();
        final (c, n, calls) = bridge(async);
        n.onEvent({'_connected': true, '_unlocked': true});
        c.read(firmwareProvider.notifier).restoreStock();
        async.elapse(const Duration(seconds: 1));
        expect(sent53(calls), [1]);
      });
    });

    test('the update callbacks are subscribed on every bind and reattach', () {
      fakeAsync((async) {
        final (c, n, calls) = bridge(async);
        n.onEvent({'_connected': true});
        async.elapse(const Duration(seconds: 1));
        expect(calls.where((x) => x.$1 == 'subscribeFirmware'), hasLength(1));
        expect(_log('subscribed').single, {'ok': true});
        n.onEvent({'_connected': false});
        n.onEvent({'_connected': true});
        async.elapse(const Duration(seconds: 1));
        expect(calls.where((x) => x.$1 == 'subscribeFirmware'), hasLength(2));
      });
    });

    test('a callback reaches the firmware state and its notes reach no log line', () {
      fakeAsync((async) {
        final (c, n, _) = bridge(async);
        n.onEvent({'_connected': true, '_fw': {...available, 'notes': 'SECRET-NOTE-TEXT'}});
        async.elapse(const Duration(seconds: 1));
        expect(c.read(firmwareProvider).notice!.version, '4.7.1');
        expect(c.read(firmwareProvider).notice!.notes, ['SECRET-NOTE-TEXT']);
        expect(_log('notice').single, {'kind': 'available', 'state': null, 'reason': 0, 'button': true, 'version': '4.7.1'});
        for (final e in AnalyticsLogger.instance.recent('hhmis') + AnalyticsLogger.instance.recent('fw')) {
          expect(e.toString(), isNot(contains('SECRET-NOTE-TEXT')));
        }
        expect(PrefsService.getString(PrefsKeys.fwLastNotice, ''), isNot(contains('SECRET')));
      });
    });

    test('on the bridge nothing but real news lights the bell', () {
      fakeAsync((async) {
        final (c, n, _) = bridge(async);
        n.onEvent({'_connected': true, '_unlocked': true});
        c.listen(bellProvider, (_, _) {});
        n.setNotification(true);
        async.elapse(const Duration(seconds: 2));
        expect(c.read(vehicleProvider).hasNotification, isFalse);
        expect(c.read(bellProvider), isFalse);
      });
    });
  });

  group('modes', () {
    test('boot logs the mode; Off is the default', () {
      final c = mock();
      expect(c.read(firmwareProvider).mode, FirmwareMode.off);
      expect(_log('mode').single, {'mode': 'off', 'source': 'boot'});
    });

    test('Off: a notice is recorded, and neither rings the bell nor offers the hand-over', () {
      fakeAsync((async) {
        final c = mock();
        final f = c.read(firmwareProvider.notifier);
        f.onNotice(available);
        expect(c.read(firmwareProvider).noticeWaiting, isTrue);
        expect(c.read(firmwareProvider).bell, isFalse);
        expect(c.read(bellProvider), isFalse);
        f.readBeforeUpdating();
        async.elapse(const Duration(seconds: 1));
        expect(c.read(passcodeGateProvider).open, isFalse);
        expect(c.read(firmwareProvider).ackOpen, isFalse);
        expect(_log('handover').single, {'step': 'refused', 'reason': 'mode_off'});
        c.read(toastProvider.notifier).dismiss();
      });
    });

    test('Ask me: the bell lights until the screen has shown that version, and again for a newer one', () {
      final c = mock();
      final f = c.read(firmwareProvider.notifier);
      f.setMode(FirmwareMode.ask);
      expect(_log('mode').last, {'mode': 'ask', 'source': 'rider'});
      f.onNotice(available);
      expect(c.read(bellProvider), isTrue);
      f.screenOpened();
      expect(c.read(bellProvider), isFalse);
      f.screenClosed();
      f.onNotice(available);
      expect(c.read(bellProvider), isFalse, reason: 'seen once');
      f.onNotice({...available, 'version': '4.7.2'});
      expect(c.read(bellProvider), isTrue);
      f.onNotice(const {'kind': 'up_to_date'});
      expect(c.read(bellProvider), isFalse);
    });

    void passcode(ProviderContainer c, FakeAsync async) {
      expect(c.read(passcodeGateProvider).open, isTrue);
      for (final d in [1, 2, 3, 4, 5, 6]) {
        c.read(passcodeGateProvider.notifier).enterDigit(d);
      }
      async.elapse(const Duration(seconds: 2));
    }

    test('Ask me: passcode, then the acknowledgement, then the stock dashboard', () {
      fakeAsync((async) {
        final c = mock();
        final f = c.read(firmwareProvider.notifier);
        f.setMode(FirmwareMode.ask);
        f.onNotice(available);
        f.readBeforeUpdating();
        expect(c.read(firmwareProvider).ackOpen, isFalse, reason: 'the passcode comes first');
        passcode(c, async);
        expect(c.read(firmwareProvider).ackOpen, isTrue);
        f.openStock();
        async.elapse(const Duration(seconds: 2));
        expect(c.read(firmwareProvider).ackOpen, isFalse);
        expect([for (final e in _log('handover')) e['step']], ['shown', 'acknowledged', 'opened']);
        async.elapse(const Duration(seconds: 10));
      });
    });

    test('"Not now" closes it and opens nothing', () {
      fakeAsync((async) {
        final c = mock();
        final f = c.read(firmwareProvider.notifier);
        f.setMode(FirmwareMode.ask);
        f.onNotice(available);
        f.readBeforeUpdating();
        passcode(c, async);
        f.notNow();
        expect(c.read(firmwareProvider).ackOpen, isFalse);
        expect([for (final e in _log('handover')) e['step']], ['shown', 'dismissed']);
      });
    });

    test('the hand-over is refused while locked, while moving, and out of Park', () {
      fakeAsync((async) {
        final c = mock();
        final v = c.read(vehicleProvider.notifier);
        final f = c.read(firmwareProvider.notifier);
        f.setMode(FirmwareMode.ask);
        f.onNotice(available);

        v.setLocked(true);
        f.readBeforeUpdating();
        v.setLocked(false);
        v.setVehicleState(VehicleState.riding);
        v.setSpeed(20);
        async.elapse(const Duration(seconds: 1));
        f.readBeforeUpdating();
        v.setSpeed(0);
        async.elapse(const Duration(seconds: 30));
        v.setVehicleState(VehicleState.ready);
        async.elapse(const Duration(seconds: 30));
        f.readBeforeUpdating();
        async.elapse(const Duration(seconds: 1));
        expect(c.read(passcodeGateProvider).open, isFalse);
        expect(c.read(firmwareProvider).ackOpen, isFalse);
        final reasons = [for (final e in _log('handover')) e['reason']];
        expect(reasons.first, 'locked');
        expect(reasons[1], anyOf('moving', 'riding'));
        expect(reasons.last, 'not_parked');
        expect(_log('handover').every((e) => e['step'] == 'refused'), isTrue);
        async.elapse(const Duration(seconds: 10));
      });
    });

    test('with OTA Shield blocking, the stock dashboard is not opened and OTA Shield is named', () {
      fakeAsync((async) {
        final platform = MockPlatformService()
          ..setInstalled('com.hxmst.otablocker')
          ..otaShield = const OtaShieldReport(running: true, blocked: 0, offerCount: 0);
        final c = ProviderContainer(overrides: [platformServiceProvider.overrideWithValue(platform)]);
        addTearDown(c.dispose);
        c.read(vehicleProvider.notifier).setLocked(false);
        c.listen(firmwareProvider, (_, _) {});
        async.elapse(const Duration(seconds: 1));
        final f = c.read(firmwareProvider.notifier);
        f.setMode(FirmwareMode.ask);
        f.onNotice(available);
        f.readBeforeUpdating();
        passcode(c, async);
        f.openStock();
        async.elapse(const Duration(seconds: 2));
        final s = c.read(firmwareProvider);
        expect(s.ackOpen, isTrue);
        expect(s.ackBlocked, isTrue);
        expect(_log('handover').last, {'step': 'refused', 'reason': 'ota_shield_on'});
        expect([for (final e in _log('handover')) e['step']], isNot(contains('opened')));
        expect(FirmwareAck.blockOn, contains('OTA Shield'));

        // Its block off: the hand-over goes ahead.
        platform.otaShield = OtaShieldReport.notRunning;
        f.openStock();
        async.elapse(const Duration(seconds: 2));
        expect(_log('handover').last, {'step': 'opened'});
      });
    });

    test('"Check now" is Ask me only', () {
      fakeAsync((async) {
        final events = StreamController<dynamic>();
        final calls = <String>[];
        final c = ProviderContainer(overrides: [
          vehicleProvider.overrideWith(() => AidlVehicleNotifier(identity: stockIdentity(), 
                events: events.stream,
                invoke: (m, a) async {
                  calls.add(m);
                  return true;
                },
              )),
        ]);
        final n = c.read(vehicleProvider.notifier) as AidlVehicleNotifier;
        c.listen(firmwareProvider, (_, _) {});
        n.onEvent({'_connected': true, '_unlocked': true, 'INT_VEHICLE_STATE': 3, 'INT_VEHICLE_SPEED': 0});
        async.elapse(const Duration(seconds: 20));
        final f = c.read(firmwareProvider.notifier);
        f.checkNow();
        async.elapse(const Duration(seconds: 1));
        expect(calls, isNot(contains('checkFirmwareUpdate')));
        f.setMode(FirmwareMode.ask);
        f.checkNow();
        async.elapse(const Duration(seconds: 1));
        expect(calls.where((m) => m == 'checkFirmwareUpdate'), hasLength(c.read(vehicleProvider).provenStopped ? 1 : 0));
        expect(c.read(vehicleProvider).provenStopped, isTrue, reason: 'the test must reach the send');
        async.elapse(const Duration(seconds: 10));
        c.dispose();
        events.close();
      });
    });
  });

  group('install in progress', () {
    test('shows in either mode and clears on failure, first boot, or silence', () {
      fakeAsync((async) {
        final c = mock();
        final f = c.read(firmwareProvider.notifier);
        f.onNotice(const {'kind': 'install_progress', 'state': 3, 'status': 'x', 'progress': 40});
        expect(c.read(firmwareProvider).installing, isTrue);
        expect(c.read(firmwareProvider).installProgress, 40);
        f.onNotice({...available, 'kind': 'install_failed', 'state': 6});
        expect(c.read(firmwareProvider).installing, isFalse);
        f.onNotice(const {'kind': 'install_progress', 'state': 3, 'progress': 41});
        f.onNotice(const {'kind': 'first_boot', 'autoDownload': false, 'autoInstall': false});
        expect(c.read(firmwareProvider).installing, isFalse);
        f.onNotice(const {'kind': 'install_progress', 'state': 3, 'progress': 42});
        async.elapse(FirmwareNotifier.installStale - const Duration(seconds: 1));
        expect(c.read(firmwareProvider).installing, isTrue);
        async.elapse(const Duration(seconds: 2));
        expect(c.read(firmwareProvider).installing, isFalse);
      });
    });

    test('progress is logged in steps of ten', () {
      final c = mock();
      final f = c.read(firmwareProvider.notifier);
      for (var p = 0; p <= 25; p++) {
        f.onNotice({'kind': 'install_progress', 'state': 3, 'progress': p});
      }
      expect([for (final e in _log('notice')) e['progress']], [0, 10, 20]);
    });
  });

  group('after a firmware change', () {
    void feed(ProviderContainer c, FakeAsync async, Map<String, String> versions) {
      final f = c.read(firmwareProvider.notifier);
      versions.forEach(f.onVersion);
      async.elapse(FirmwareNotifier.versionSettle + const Duration(seconds: 1));
    }

    const base = {'0': 'bcm-1', '1': 'bms-1', '3': 'hu-1', '5': 'mcu-1', '20': 'bl-1', 'moveos': '4.6.14'};

    test('the first run stores and does not warn', () {
      fakeAsync((async) {
        final c = mock();
        feed(c, async, base);
        expect(_log('version_changed').single, {'which': <String>[], 'first_run': true});
        expect(c.read(firmwareProvider).change, isNull);
        feed(c, async, {'4': 'hbc-1'});
        expect(_log('version_changed'), hasLength(1), reason: 'a late first value is not a change');
      });
    });

    test('an ECU-only change: logged, one line on the screen, no notice', () {
      fakeAsync((async) {
        feed(mock(), async, base);
        AnalyticsLogger.instance.resetForTest();
        final c = mock();
        feed(c, async, {...base, '1': 'bms-2', '20': 'bl-2'});
        expect(_log('version_changed').single, containsPair('which', ['1', '20']));
        final change = c.read(firmwareProvider).change!;
        expect(change.headUnit, isFalse);
        expect(c.read(firmwareProvider).changeNoticeOwed, isFalse);
        expect(c.read(firmwareChangeNoticeProvider), isNull);
      });
    });

    test('a head-unit change: the notice is owed once, at the next park, unlocked', () {
      fakeAsync((async) {
        feed(mock(), async, base);
        AnalyticsLogger.instance.resetForTest();
        final c = mock();
        c.listen(firmwareChangeNoticeProvider, (_, _) {});
        final v = c.read(vehicleProvider.notifier);
        v.setLocked(true);
        feed(c, async, {...base, '3': 'hu-2'});
        expect(_log('version_changed').single, containsPair('which', ['3']));
        expect(c.read(firmwareProvider).changeNoticeOwed, isTrue);
        expect(c.read(firmwareChangeNoticeProvider), isNull, reason: 'locked');
        v.setLocked(false);
        async.elapse(const Duration(seconds: 1));
        final shown = c.read(firmwareChangeNoticeProvider)!;
        expect((shown.from, shown.to), ('hu-1', 'hu-2'));
        c.read(firmwareProvider.notifier).answerChange(stock: false);
        async.elapse(const Duration(seconds: 1));
        expect(c.read(firmwareChangeNoticeProvider), isNull);
        c.dispose();

        // Not again at the next start, and no new change from the same values.
        final next = mock();
        feed(next, async, {...base, '3': 'hu-2'});
        expect(next.read(firmwareProvider).changeNoticeOwed, isFalse);
        expect(_log('version_changed'), hasLength(1));
      });
    });

    // Index 4 changed, and again 5 s later, right after an unlock, and each was reported.
    test('a version that flickers and comes back, or flips between answers it has given, is not a change', () {
      fakeAsync((async) {
        feed(mock(), async, {...base, '4': 'hbc-1'});
        AnalyticsLogger.instance.resetForTest();
        final c = mock();
        final f = c.read(firmwareProvider.notifier);
        f.onVersion('4', 'waking');
        async.elapse(const Duration(seconds: 5));
        f.onVersion('4', 'hbc-1');
        async.elapse(FirmwareNotifier.versionSettle + const Duration(seconds: 1));
        expect(_log('version_changed'), isEmpty);
        expect(c.read(firmwareProvider).change, isNull);

        // The same flicker at the next start, held for longer this time.
        final next = mock();
        feed(next, async, {...base, '4': 'waking'});
        feed(next, async, {...base, '4': 'hbc-1'});
        expect(_log('version_changed'), isEmpty);

        // A value never seen before, that stays, is still a change.
        feed(next, async, {'4': 'hbc-2'});
        expect(_log('version_changed').single, {
          'which': ['4'],
          'first_run': false,
          'changes': {
            '4': ['hbc-1', 'hbc-2'],
          },
        });
      });
    });

    test('MoveOS counts as the head unit', () {
      fakeAsync((async) {
        feed(mock(), async, base);
        final c = mock();
        feed(c, async, {...base, 'moveos': '4.7.1'});
        expect(c.read(firmwareProvider).changeNoticeOwed, isTrue);
        expect(c.read(firmwareProvider).change!.to, '4.7.1');
      });
    });
  });

  test('release notes: the stock JSON shape, a bare list, and plain text', () {
    expect(FirmwareNotifier.parseReleaseNotes('{"releaseNotes": ["a", " b ", ""]}'), ['a', 'b']);
    expect(FirmwareNotifier.parseReleaseNotes('["x", {"title": "T", "desc": "D"}]'), ['x', 'T: D']);
    expect(FirmwareNotifier.parseReleaseNotes('line one\n\nline two'), ['line one', 'line two']);
    expect(FirmwareNotifier.parseReleaseNotes(null), isEmpty);
    expect(FirmwareNotifier.parseReleaseNotes('  '), isEmpty);
  });
}
