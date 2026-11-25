import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/bt_bridge.dart';
import 'package:opendash/services/hsss_bluetooth.dart';
import 'package:opendash/services/parcel_codec.dart';
import 'package:opendash/services/recovery_service.dart';
import 'package:opendash/state/bt_settings.dart';
import 'package:opendash/state/media_state.dart';
import 'package:opendash/state/prompt_surface.dart';
import 'package:opendash/state/toast_state.dart';

import '../helpers/stock.dart';

const pixel = 'AA:BB:CC:DD:EE:01';
const work = 'AA:BB:CC:DD:EE:02';
const pixelName = 'Pixel of Asha';
const pairingCode = '482917';

Uint8List i32(int v) => (ParcelWriter()..writeInt(v)).toBytes();

/// One HSSS call as sent: the stock method's name and the payload bytes.
class Tx {
  const Tx(this.method, this.data);
  final String method;
  final List<int> data;

  @override
  bool operator ==(Object other) => other is Tx && other.method == method && listEquals(other.data, data);

  @override
  int get hashCode => Object.hash(method, Object.hashAll(data));

  @override
  String toString() => 'Tx($method, $data)';
}

/// Stands in for `BluetoothBridge.kt`: records every call and answers the
/// way HSSS would.
class FakeBridge extends BtBridge {
  final controller = StreamController<dynamic>(sync: true);
  final calls = <(String, Object?)>[];
  final failing = <String>{};
  bool hsssThrows = false;
  bool hfpProxyMissing = false;

  @override
  Stream<dynamic> events() => controller.stream;

  @override
  Future<Object?> invoke(String method, [Object? args]) async {
    calls.add((method, args));
    if (failing.contains(method)) throw PlatformException(code: 'hsss_error', message: 'java.lang.IllegalStateException: refused');
    if (method != 'hsss') return true;
    if (hsssThrows) throw PlatformException(code: 'hsss_error', message: 'java.lang.IllegalStateException: HSSS not bound');
    final called = (args as Map)['method'] as String;
    return switch (called) {
      HsssBluetooth.getScanMode => i32(23),
      HsssBluetooth.getBondedDevices => (ParcelWriter()
            ..writeInt(1)
            ..writeInt(1)
            ..writeInt(0))
          .toBytes(),
      HsssBluetooth.isBTProfileNull => i32(hfpProxyMissing ? 1 : 0),
      HsssBluetooth.getConnectionState => i32(2),
      _ => i32(1),
    };
  }

  void emit(Map<String, Object?> event) => controller.add(event);

  /// The HSSS calls sent so far, as (method, payload).
  List<Tx> get hsss => [
        for (final (m, a) in calls)
          if (m == 'hsss') Tx((a as Map)['method'] as String, (a['data'] as Uint8List).toList()),
      ];

  List<Tx> get writes => [
        for (final c in hsss)
          if (!HsssBluetooth.readOnly.contains(c.method)) c,
      ];

  List<String> get methods => [for (final (m, _) in calls) m];
}

Map<String, Object?> adapter({bool enabled = true, int scan = 23, String? connected, bool two = true}) => {
      'state': {
        'enabled': enabled,
        'scanMode': scan,
        'name': 'bluebird',
        'devices': [
          {'address': pixel, 'name': pixelName, 'connected': connected == pixel},
          if (two) {'address': work, 'name': 'Work phone', 'connected': connected == work},
        ],
      },
    };

void main() {
  late FakeBridge bridge;
  late ProviderContainer c;

  BtSettings bt() => c.read(btSettingsProvider);
  BtSettingsNotifier n() => c.read(btSettingsProvider.notifier);
  VehicleNotifier v() => c.read(vehicleProvider.notifier);
  List<Map<String, Object?>> log(String cat, String evt) =>
      [for (final e in AnalyticsLogger.instance.recent(cat, evt)) (e['data'] as Map).cast<String, Object?>()];

  setUp(() {
    AnalyticsLogger.instance.resetForTest();
    bridge = FakeBridge();
    RecoveryService.stockLaunches = 0;
  });

  /// The head unit's notifier over the fake bridge, on the mock vehicle
  /// (unlocked, stopped, data trusted).
  Future<void> start({bool bound = true, String? connected}) async {
    c = ProviderContainer(overrides: [
      btBridgeProvider.overrideWithValue(bridge),
      btSettingsProvider.overrideWith(HsssBtSettingsNotifier.new),
    ]);
    addTearDown(c.dispose);
    c.listen(btSettingsProvider, (_, _) {});
    c.listen(toastProvider, (_, _) {});
    v().setLocked(false);
    bridge.emit(adapter(connected: connected));
    if (bound) bridge.emit({'hsss': true});
    await pumpEventQueue();
    bridge.calls.clear();
  }

  group('a binder that fails', () {
    test('never bound: read-only, the adapter state still shows', () async {
      await start(bound: false);
      expect(bt().readOnly, HsssBtSettingsNotifier.notBound);
      expect(bt().phones.map((p) => p.name), [pixelName, 'Work phone']);
      expect(bt().on, isTrue);
      await n().setOn(false);
      expect(bridge.calls, isEmpty);
    });

    test('bound but every call throws: read-only, the probe says so', () async {
      bridge.hsssThrows = true;
      await start();
      expect(bt().readOnly, HsssBtSettingsNotifier.notBound);
      expect(log('bt', 'probe').single, containsPair('ok', false));
      expect(log('bt', 'hsss_call').every((e) => e['ok'] == false), isTrue);
    });

    test('the callbacks cannot be registered: read-only', () async {
      bridge.failing.add('hsssRegisterCallbacks');
      await start();
      expect(bt().readOnly, HsssBtSettingsNotifier.notBound);
    });

    test('HSSS goes away: read-only until it is back', () async {
      await start();
      expect(bt().readOnly, isNull);
      bridge.emit({'hsss': false});
      expect(bt().readOnly, HsssBtSettingsNotifier.notBound);
      bridge.emit({'hsss': true});
      await pumpEventQueue();
      expect(bt().readOnly, isNull);
      expect(bridge.methods, containsAllInOrder(['hsssRegisterCallbacks', 'hsssRegisterReceivers']));
    });
  });

  group('bound', () {
    test('on bind: probe, then our callbacks and the receivers', () async {
      c = ProviderContainer(overrides: [
        btBridgeProvider.overrideWithValue(bridge),
        btSettingsProvider.overrideWith(HsssBtSettingsNotifier.new),
      ]);
      addTearDown(c.dispose);
      c.listen(btSettingsProvider, (_, _) {});
      bridge.emit({'hsss': true});
      await pumpEventQueue();
      expect(bridge.methods.where((m) => m != 'hsss'), ['hsssRegisterCallbacks', 'hsssRegisterReceivers']);
      expect(bridge.writes, isEmpty);
      expect(bridge.hsss.map((c) => c.method).toSet(), {'isBtEnabled', 'getScanMode', 'getBondedDevices', 'isBTProfileNull'});
      final probe = log('bt', 'probe').single;
      expect(probe, containsPair('ok', true));
      expect(probe, containsPair('scan_mode', 23));
      expect(probe, containsPair('hfp_proxy', true));
      expect(bt().readOnly, isNull);
    });

    test('the adapter is the truth for on, visible, name and phones', () async {
      await start(connected: pixel);
      expect((bt().on, bt().visible, bt().name), (true, true, 'bluebird'));
      expect(bt().connected?.address, pixel);
      bridge.emit(adapter(scan: 21));
      expect((bt().on, bt().visible), (true, false));
      bridge.emit(adapter(scan: 20));
      expect((bt().on, bt().visible), (false, false));
      bridge.emit(adapter(enabled: false));
      expect(bt().on, isFalse);
    });

    test('opening the screen makes the scooter visible when it is on but hidden', () async {
      await start();
      n().screenOpened();
      await pumpEventQueue();
      expect(bridge.writes, isEmpty, reason: 'already visible');
      bridge.emit(adapter(scan: 21));
      n().screenOpened();
      await pumpEventQueue();
      expect(bridge.writes, [Tx('setScanMode', i32(23))]);
      bridge.calls.clear();
      bridge.emit(adapter(scan: 20));
      n().screenOpened();
      await pumpEventQueue();
      expect(bridge.writes, isEmpty, reason: 'off stays off');
    });

    test('Connect sends connectDevice, Disconnect sends disconnectDevice', () async {
      await start();
      await n().toggleConnection(pixel);
      expect(bridge.writes, [Tx('connectDevice', HsssBluetooth.connectDeviceRequest(pixel).data)]);
      bridge.calls.clear();
      bridge.emit(adapter(connected: pixel));
      await pumpEventQueue();
      bridge.calls.clear();
      await n().toggleConnection(pixel);
      expect(bridge.writes, [Tx('disconnectDevice', HsssBluetooth.disconnectDeviceRequest(pixel).data)]);
    });

    test('one phone at a time', () async {
      await start(connected: pixel);
      await n().toggleConnection(work);
      expect(bridge.writes, isEmpty);
      expect(c.read(toastProvider)?.message, 'Disconnect $pixelName first');
    });

    test('off is stock\'s: disconnect, priorities to 0, unconnectable; the adapter stays up', () async {
      await start(connected: pixel);
      await n().setOn(false);
      expect(bridge.writes, [
        Tx('disconnectDevice', HsssBluetooth.disconnectDeviceRequest(pixel).data),
        Tx('setAllBtProfilesPriority', HsssBluetooth.setAllBtProfilesPriorityRequest(0, pixel).data),
        Tx('setAllBtProfilesPriority', HsssBluetooth.setAllBtProfilesPriorityRequest(0, work).data),
        Tx('setScanMode', i32(20)),
      ]);
      expect(log('bt', 'toggle').single, {'on': false, 'ok': true});
    });

    test('on: visible and priorities back to 100', () async {
      await start();
      bridge.emit(adapter(scan: 20));
      await n().setOn(true);
      expect(bridge.writes, [
        Tx('setScanMode', i32(23)),
        Tx('setAllBtProfilesPriority', HsssBluetooth.setAllBtProfilesPriorityRequest(100, pixel).data),
        Tx('setAllBtProfilesPriority', HsssBluetooth.setAllBtProfilesPriorityRequest(100, work).data),
      ]);
    });

    // Stock 5.0.2 sets no priority anywhere: a phone left at 0 there
    // would have nothing to raise it again.
    test('on software OpenDash has not been ridden on, no priority is set either way, and the log says so', () async {
      await start(connected: pixel);
      v().software.value = stockIdentity('gen1-moveos5-5.0.2');
      await n().setOn(false);
      expect(bridge.writes, [
        Tx('disconnectDevice', HsssBluetooth.disconnectDeviceRequest(pixel).data),
        Tx('setScanMode', i32(20)),
      ]);
      expect(log('bt', 'priorities_skipped').single, {'on': false, 'phones': 2});
      bridge.calls.clear();
      bridge.emit(adapter(scan: 20));
      await n().setOn(true);
      expect(bridge.writes, [Tx('setScanMode', i32(23))]);
      expect(log('bt', 'priorities_skipped').last, {'on': true, 'phones': 2});
      expect(log('bt', 'toggle').map((e) => e['ok']), [true, true]);
    });

    test('on the software OpenDash is ridden on, the priorities are set as before', () async {
      await start(connected: pixel);
      v().software.value = stockIdentity();
      await n().setOn(false);
      expect(bridge.writes.where((w) => w.method == 'setAllBtProfilesPriority'), hasLength(2));
      expect(log('bt', 'priorities_skipped'), isEmpty);
    });

    test('on with the adapter down: enableBT now, the scan mode once it is up', () async {
      await start();
      bridge.emit(adapter(enabled: false, scan: 20));
      await n().setOn(true);
      expect(bridge.writes.first.method, 'enableBT');
      expect(bridge.writes.where((w) => w.method == 'setScanMode'), isEmpty);
      bridge.calls.clear();
      bridge.emit(adapter(scan: 21));
      await pumpEventQueue();
      expect(bridge.writes, [Tx('setScanMode', i32(23))]);
    });

    test('Forget asks first; confirmed, it clears HSSS, disconnects and unpairs', () async {
      await start(connected: pixel);
      n().askForget(pixel);
      expect(bt().forgetAddress, pixel);
      expect(bridge.calls, isEmpty);
      n().cancelForget();
      expect(bt().forgetAddress, isEmpty);
      n().askForget(pixel);
      await n().confirmForget();
      await pumpEventQueue();
      expect(bridge.writes, [
        Tx('forgetDevice', HsssBluetooth.forgetDeviceRequest(pixel).data),
        Tx('disconnectDevice', HsssBluetooth.disconnectDeviceRequest(pixel).data),
      ]);
      expect(bridge.calls.where((c) => c.$1 == 'removeBond').single.$2, pixel);
      expect(log('bt', 'forget').single, {'ok': true});
    });

    test('the pair-fail HSSS raises for the removed bond is not shown', () async {
      await start();
      n().askForget(work);
      await n().confirmForget();
      bridge.emit({'pairing': {'event': 'fail', 'value': null}});
      expect(bt().pairFailed, isFalse);
      bridge.emit({'pairing': {'event': 'fail', 'value': null}});
      expect(bt().pairFailed, isTrue, reason: 'only the one after a forget');
    });

    test('an unpair the sandbox refuses is reported', () async {
      bridge.failing.add('removeBond');
      await start();
      n().askForget(work);
      await n().confirmForget();
      expect(log('bt', 'forget').single, {'ok': false});
      expect(c.read(toastProvider)?.message, "Couldn't forget the phone");
    });
  });

  group('pairing', () {
    void request() {
      bridge.emit({'pairing': {'event': 'pin', 'value': pairingCode}});
      bridge.emit({'pairing': {'event': 'popup', 'value': pixelName}});
    }

    List<Object?> stages() => [for (final e in log('bt', 'pairing')) e['stage']];
    List<String> actions() => [
          for (final w in bridge.writes)
            if (w.method == 'pairingAction') ParcelReader(w.data).readString()!,
        ];

    test('the prompt shows the code and the name; Pair accepts, then the bond', () async {
      await start();
      request();
      expect((bt().pairingOpen, bt().pairingCode, bt().pairingName), (true, pairingCode, pixelName));
      await n().acceptPairing();
      expect(actions(), ['ACCEPT']);
      expect(bt().pairingOpen, isFalse);
      bridge.emit({'pairing': {'event': 'pin', 'value': '000000'}});
      bridge.emit({'pairing': {'event': 'dismiss', 'value': null}});
      bridge.emit({'bond': {'address': pixel, 'state': 12, 'prev': 11, 'reason': -1}});
      expect(stages(), ['requested', 'shown', 'accepted', 'bonded']);
      expect(c.read(toastProvider)?.message, 'Phone paired');
    });

    test('Cancel rejects', () async {
      await start();
      request();
      n().rejectPairing();
      await pumpEventQueue();
      expect(actions(), ['REJECT']);
      expect(bt().pairingOpen, isFalse);
      bridge.emit({'bond': {'address': pixel, 'state': 10, 'prev': 11, 'reason': 3}});
      expect(stages(), ['requested', 'shown', 'rejected'], reason: 'our own cancel is not a failure');
    });

    test('a request with no passkey shows no code', () async {
      await start();
      bridge.emit({'pairing': {'event': 'pin', 'value': '-2147483648'}});
      bridge.emit({'pairing': {'event': 'popup', 'value': pixelName}});
      expect(bt().pairingOpen, isTrue);
      expect(bt().pairingCode, isEmpty);
    });

    test('refused at once while moving, locked, in the background or with a phone connected', () async {
      for (final (reason, arrange) in <(String, void Function())>[
        ('moving', () => v().setSpeed(12)),
        ('locked', () => v().setLocked(true)),
        ('background', () => c.read(promptSurfaceVisibleProvider.notifier).screenShown(false)),
        ('phone_connected', () => bridge.emit(adapter(connected: work))),
      ]) {
        AnalyticsLogger.instance.resetForTest();
        bridge = FakeBridge();
        await start();
        arrange();
        await pumpEventQueue();
        bridge.calls.clear();
        request();
        await pumpEventQueue();
        expect(bt().pairingOpen, isFalse, reason: reason);
        expect(actions(), ['REJECT'], reason: reason);
        expect(log('bt', 'pairing').last, {'stage': 'rejected', 'reason': reason});
      }
    });

    test('refused with six phones paired', () async {
      await start();
      bridge.emit({
        'state': {
          'enabled': true,
          'scanMode': 23,
          'name': 'bluebird',
          'devices': [for (var i = 0; i < 6; i++) {'address': 'AA:BB:CC:DD:EE:1$i', 'name': 'p$i', 'connected': false}],
        },
      });
      request();
      await pumpEventQueue();
      expect(actions(), ['REJECT']);
      expect(log('bt', 'pairing').last, {'stage': 'rejected', 'reason': 'too_many'});
    });

    test('an open prompt is rejected when the scooter moves, locks or leaves the screen', () async {
      for (final (reason, act) in <(String, void Function())>[
        ('moving', () => v().setSpeed(5)),
        ('locked', () => v().setLocked(true)),
        ('background', () => c.read(promptSurfaceVisibleProvider.notifier).screenShown(false)),
      ]) {
        AnalyticsLogger.instance.resetForTest();
        bridge = FakeBridge();
        await start();
        request();
        expect(bt().pairingOpen, isTrue);
        act();
        await pumpEventQueue();
        expect(bt().pairingOpen, isFalse, reason: reason);
        expect(actions(), ['REJECT'], reason: reason);
        expect(log('bt', 'pairing').last, {'stage': 'rejected', 'reason': reason});
      }
    });

    test('unanswered, it is rejected after the timeout', () {
      fakeAsync((async) {
        start();
        async.flushMicrotasks();
        request();
        async.elapse(BtSettingsNotifier.pairingTimeout - const Duration(seconds: 1));
        expect(bt().pairingOpen, isTrue);
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(bt().pairingOpen, isFalse);
        expect(actions(), ['REJECT']);
        expect(log('bt', 'pairing').last, {'stage': 'rejected', 'reason': 'timeout'});
      });
    });

    test('the phone gives up: the prompt closes, logged as failed with the reason', () async {
      await start();
      request();
      bridge.emit({'bond': {'address': pixel, 'state': 10, 'prev': 11, 'reason': 2}});
      expect(bt().pairingOpen, isFalse);
      expect(bt().pairFailed, isFalse);
      expect(log('bt', 'pairing').last, {'stage': 'failed', 'reason': 'bond_2'});
      expect(actions(), isEmpty);
    });

    test('HSSS\'s pair-fail shows stock\'s "Device pairing failed" until dismissed', () async {
      await start();
      request();
      await n().acceptPairing();
      bridge.emit({'pairing': {'event': 'fail', 'value': null}});
      expect(bt().pairFailed, isTrue);
      expect(log('bt', 'pairing').last, {'stage': 'failed', 'reason': 'hsss'});
      n().dismissPairFailed();
      expect(bt().pairFailed, isFalse);
    });

    test('a pairing action HSSS refuses is a failure', () async {
      await start();
      request();
      bridge.hsssThrows = true;
      await n().acceptPairing();
      expect(log('bt', 'pairing').last, {'stage': 'failed', 'reason': 'send'});
    });
  });

  group('calls on the dashboard', () {
    List<(String, Object?)> profileWrites() => [
          for (final (m, a) in bridge.calls)
            if (m == 'profileUpdateInt') ('${(a as Map)['cmd']}', a['value']),
        ];

    test('first time: the consent, and nothing is written until it is accepted', () async {
      await start(connected: pixel);
      await n().setCallsAllowed(true);
      expect(bt().consentOpen, isTrue);
      expect(bt().callsAllowed, isFalse);
      expect(bridge.calls, isEmpty);
      n().declineConsent();
      expect(bt().consentOpen, isFalse);
      expect(bridge.calls, isEmpty);
    });

    test('accepted: consent value, then the setting, then enablePhoneCalls, in stock\'s order', () async {
      await start(connected: pixel);
      await n().setCallsAllowed(true);
      await n().acceptConsent();
      expect(bridge.methods, ['profileUpdateInt', 'profileUpdateInt', 'hsss']);
      expect(profileWrites(), [('INT_SYNC_CONTACTS_PERMISSION', 1), ('INT_SYNC_CONTACTS', 1)]);
      expect(bridge.writes, [Tx('enablePhoneCalls', HsssBluetooth.enablePhoneCallsRequest(true, pixel).data)]);
      expect((bt().callsAllowed, bt().callsConsent), (true, true));
      expect(log('call', 'allowed').last, {'on': true, 'consent': true, 'trigger': 'consent', 'saved': true});
    });

    test('off, and on again without the consent', () async {
      await start(connected: pixel);
      await n().setCallsAllowed(true);
      await n().acceptConsent();
      bridge.calls.clear();
      await n().setCallsAllowed(false);
      expect(profileWrites(), [('INT_SYNC_CONTACTS', 0)]);
      expect(bridge.writes, [Tx('enablePhoneCalls', HsssBluetooth.enablePhoneCallsRequest(false, pixel).data)]);
      bridge.calls.clear();
      await n().setCallsAllowed(true);
      expect(bt().consentOpen, isFalse);
      expect(profileWrites(), [('INT_SYNC_CONTACTS', 1)]);
    });

    test('with no phone connected only the profile is written', () async {
      await start();
      await n().setCallsAllowed(true);
      await n().acceptConsent();
      expect(profileWrites(), [('INT_SYNC_CONTACTS_PERMISSION', 1), ('INT_SYNC_CONTACTS', 1)]);
      expect(bridge.writes, isEmpty);
    });

    test('a profile write that fails is said, and the phone is still told', () async {
      bridge.failing.add('profileUpdateInt');
      await start(connected: pixel);
      await n().setCallsAllowed(true);
      await n().acceptConsent();
      expect(log('call', 'allowed').last, containsPair('saved', false));
      expect(c.read(toastProvider)?.message, "Couldn't save this to the scooter profile");
      expect(bridge.writes.single.method, 'enablePhoneCalls');
    });

    test('the vehicle\'s values at unlock are mirrored, and nothing is sent', () async {
      await start(connected: pixel);
      v().phoneCallsHandler!(true, true);
      await pumpEventQueue();
      expect((bt().callsAllowed, bt().callsConsent), (true, true));
      expect(bridge.calls, isEmpty);
      expect(log('call', 'allowed').last, {'on': true, 'consent': true, 'trigger': 'vehicle'});
      v().phoneCallsHandler!(true, null);
      expect(log('call', 'allowed'), hasLength(1), reason: 'no change, no line');
    });

    test('a phone connecting is told the setting, once it is known', () async {
      await start();
      bridge.emit(adapter(connected: pixel));
      await pumpEventQueue();
      expect(bridge.writes, isEmpty, reason: 'not known yet');
      bridge.emit(adapter());
      v().phoneCallsHandler!(false, null);
      bridge.emit(adapter(connected: pixel));
      await pumpEventQueue();
      expect(bridge.writes, [Tx('enablePhoneCalls', HsssBluetooth.enablePhoneCallsRequest(false, pixel).data)]);
      bridge.calls.clear();
      bridge.emit(adapter(connected: pixel));
      await pumpEventQueue();
      expect(bridge.writes, isEmpty, reason: 'only on the connection');
    });

    test('the caller name from HSSS reaches the call; a bare number does not', () async {
      await start(connected: pixel);
      v().simulateIncomingCall(name: '', number: '+91 98765 43210');
      bridge.emit({'callName': {'state': 4, 'name': '+919876543210'}});
      expect(c.read(vehicleProvider).callerName, isEmpty);
      bridge.emit({'callName': {'state': 4, 'name': 'DEEFAULTT'}});
      expect(c.read(vehicleProvider).callerName, isEmpty);
      bridge.emit({'callName': {'state': 4, 'name': 'Asha'}});
      expect(c.read(vehicleProvider).callerName, 'Asha');
    });

    test('answering through HSSS: only with its HFP proxy up, never a REJECT', () async {
      await start(connected: pixel);
      final fallback = v().callActionFallback!;
      expect(await fallback('accept'), isTrue);
      expect(bridge.hsss.map((c) => c.method), ['isBTProfileNull', 'isBTProfileNull', 'callAction'], reason: 'the proxies are checked, then the call goes');
      expect(bridge.writes.single, Tx('callAction', HsssBluetooth.callActionRequest('ACCEPT', pixel).data));
      bridge.calls.clear();
      expect(await fallback('end'), isTrue);
      expect(bridge.writes.single, Tx('callAction', HsssBluetooth.callActionRequest('TERMINATE', pixel).data));
      bridge.calls.clear();
      bridge.hfpProxyMissing = true;
      expect(await fallback('accept'), isFalse);
      expect(bridge.writes.map((t) => t.method), [HsssBluetooth.registerAllBtProfiles],
          reason: 'HSSS is asked to take its proxies; with them still missing no call action is sent');
    });

    // HSSS had restarted, nobody had asked it to take its
    // profile proxies, and twenty presses of Disconnect were answered
    // "done" with music, calls and AVRCP still connected.
    test('a disconnect first has HSSS take its profile proxies when they are missing', () async {
      await start(connected: pixel);
      bridge.calls.clear();
      bridge.hfpProxyMissing = true;
      await c.read(btSettingsProvider.notifier).toggleConnection(pixel);
      final sent = bridge.hsss.map((t) => t.method).toList();
      expect(sent, containsAllInOrder([HsssBluetooth.isBTProfileNull, HsssBluetooth.registerAllBtProfiles, HsssBluetooth.disconnectDevice]));
      expect(log('bt', 'profiles_registered').last, {'reason': 'disconnect', 'ok': true});
    });

    test('with the proxies there, a disconnect asks for nothing more', () async {
      await start(connected: pixel);
      bridge.calls.clear();
      await c.read(btSettingsProvider.notifier).toggleConnection(pixel);
      expect(bridge.hsss.map((t) => t.method), isNot(contains(HsssBluetooth.registerAllBtProfiles)));
      expect(bridge.hsss.map((t) => t.method), contains(HsssBluetooth.disconnectDevice));
    });
  });

  group('stock dashboard', () {
    test('after a visit to stock the callbacks and receivers are registered again', () {
      fakeAsync((async) {
        start();
        async.flushMicrotasks();
        final surface = c.read(promptSurfaceVisibleProvider.notifier);
        surface.screenShown(false);
        surface.screenShown(true);
        async.elapse(const Duration(seconds: 10));
        expect(bridge.calls, isEmpty, reason: 'another app, not stock');

        RecoveryService.stockLaunches++;
        surface.screenShown(false);
        surface.screenShown(true);
        async.elapse(HsssBtSettingsNotifier.reRegisterAfter);
        async.flushMicrotasks();
        expect(bridge.methods, ['hsssRegisterCallbacks', 'hsssRegisterReceivers']);
        bridge.calls.clear();
        surface.screenShown(false);
        surface.screenShown(true);
        async.elapse(const Duration(seconds: 10));
        expect(bridge.calls, isEmpty, reason: 'once per launch');
      });
    });
  });

  test('names, addresses and pairing codes stay out of the log', () async {
    await start(connected: work);
    c.listen(btWatcherProvider, (_, _) {});
    await n().toggleConnection(pixel);
    bridge.emit({'pairing': {'event': 'popup', 'value': pixelName}});
    v().setBtConnected(true, name: pixelName);
    await n().toggleConnection(work);
    bridge.emit(adapter());
    bridge.emit({'pairing': {'event': 'pin', 'value': pairingCode}});
    bridge.emit({'pairing': {'event': 'popup', 'value': pixelName}});
    await n().acceptPairing();
    bridge.emit({'bond': {'address': pixel, 'state': 12, 'prev': 11, 'reason': -1}});
    bridge.emit(adapter(connected: pixel));
    await n().setCallsAllowed(true);
    await n().acceptConsent();
    bridge.emit({'callName': {'state': 4, 'name': 'Asha'}});
    n().askForget(pixel);
    await n().confirmForget();
    await pumpEventQueue();
    final all = jsonEncode([
      for (final cat in ['bt', 'call', 'ui', 'safety']) AnalyticsLogger.instance.recent(cat),
    ]);
    expect(all, contains('"pairing"'));
    expect(all, contains('Disconnect the connected phone first'));
    expect(all, contains('"Bluetooth connected"'));
    for (final secret in [pixel, work, pixelName, 'Work phone', pairingCode, 'Asha', 'bluebird']) {
      expect(all, isNot(contains(secret)), reason: secret);
    }
  });

  group('mock', () {
    setUp(() {
      c = ProviderContainer();
      addTearDown(c.dispose);
      c.listen(btSettingsProvider, (_, _) {});
      v().setLocked(false);
    });

    test('starts on, visible, with two paired phones and every control live', () {
      expect((bt().on, bt().visible, bt().readOnly), (true, true, null));
      expect(bt().phones, hasLength(2));
      expect(bt().connected, isNull);
    });

    test('connect, disconnect and off follow the vehicle mock', () async {
      final phone = bt().phones.last;
      await n().toggleConnection(phone.address);
      expect(c.read(vehicleProvider).btConnected, isTrue);
      expect(c.read(vehicleProvider).btDeviceName, phone.name);
      expect(bt().connected?.address, phone.address);
      await n().setOn(false);
      expect(c.read(vehicleProvider).btConnected, isFalse);
      expect((bt().on, bt().visible), (false, false));
    });

    test('a pairing request, accepted, adds the phone', () async {
      n().simulatePairingRequest();
      expect(bt().pairingOpen, isTrue);
      await n().acceptPairing();
      expect(bt().pairingOpen, isFalse);
      expect(bt().phones.map((p) => p.name), contains(BtSettingsNotifier.mockPairingName));
    });

    test('pairing failed, forget and the calls toggle', () async {
      n().simulatePairFailed();
      expect(bt().pairFailed, isTrue);
      n().dismissPairFailed();
      final first = bt().phones.first;
      n().askForget(first.address);
      await n().confirmForget();
      expect(bt().phones.map((p) => p.address), isNot(contains(first.address)));
      await n().setCallsAllowed(true);
      expect(bt().consentOpen, isTrue);
      await n().acceptConsent();
      expect((bt().callsAllowed, bt().callsConsent), (true, true));
      await n().setCallsAllowed(false);
      expect(bt().callsAllowed, isFalse);
    });
  });
}
