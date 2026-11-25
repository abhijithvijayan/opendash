import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mock_provider.dart';
import '../services/analytics_logger.dart';
import '../services/bt_bridge.dart';
import '../services/hsss_bluetooth.dart';
import '../services/prefs_service.dart';
import '../services/recovery_service.dart';
import 'prompt_surface.dart';
import 'riding_lockout.dart';
import 'scooter_capabilities.dart';
import 'toast_state.dart';

@immutable
class BtPhone {
  const BtPhone({required this.address, required this.name, this.connected = false});
  final String address;
  final String name;
  final bool connected;

  String get label => name.isEmpty ? 'Phone' : name;

  @override
  bool operator ==(Object other) =>
      other is BtPhone && other.address == address && other.name == name && other.connected == connected;

  @override
  int get hashCode => Object.hash(address, name, connected);
}

@immutable
class BtSettings {
  const BtSettings({
    this.on = false,
    this.visible = false,
    this.name = '',
    this.phones = const [],
    this.readOnly,
    this.pairingOpen = false,
    this.pairingCode = '',
    this.pairingName = '',
    this.pairFailed = false,
    this.callsAllowed = false,
    this.callsConsent = false,
    this.consentOpen = false,
    this.forgetAddress = '',
  });

  /// Stock's Bluetooth toggle: the adapter is up and phones may connect.
  /// "Off" leaves the adapter running, as stock's toggle does, and makes
  /// the head unit unconnectable.
  final bool on;

  /// Discoverable: a phone can find the scooter and start pairing.
  final bool visible;

  /// The name phones see.
  final String name;

  /// Paired phones.
  final List<BtPhone> phones;

  /// Null when the controls work; otherwise why they do not.
  final String? readOnly;

  final bool pairingOpen;

  /// Six digits, or empty when the phone sent no code to compare.
  final String pairingCode;
  final String pairingName;
  final bool pairFailed;

  final bool callsAllowed;
  final bool callsConsent;
  final bool consentOpen;

  /// The phone the Forget confirmation is up for; empty when it is not.
  final String forgetAddress;

  BtPhone? get connected {
    for (final p in phones) {
      if (p.connected) return p;
    }
    return null;
  }

  BtPhone? phone(String address) {
    for (final p in phones) {
      if (p.address == address) return p;
    }
    return null;
  }

  static const _keep = Object();

  BtSettings copyWith({
    bool? on,
    bool? visible,
    String? name,
    List<BtPhone>? phones,
    Object? readOnly = _keep,
    bool? pairingOpen,
    String? pairingCode,
    String? pairingName,
    bool? pairFailed,
    bool? callsAllowed,
    bool? callsConsent,
    bool? consentOpen,
    String? forgetAddress,
  }) =>
      BtSettings(
        on: on ?? this.on,
        visible: visible ?? this.visible,
        name: name ?? this.name,
        phones: phones ?? this.phones,
        readOnly: identical(readOnly, _keep) ? this.readOnly : readOnly as String?,
        pairingOpen: pairingOpen ?? this.pairingOpen,
        pairingCode: pairingCode ?? this.pairingCode,
        pairingName: pairingName ?? this.pairingName,
        pairFailed: pairFailed ?? this.pairFailed,
        callsAllowed: callsAllowed ?? this.callsAllowed,
        callsConsent: callsConsent ?? this.callsConsent,
        consentOpen: consentOpen ?? this.consentOpen,
        forgetAddress: forgetAddress ?? this.forgetAddress,
      );
}

final btSettingsProvider = NotifierProvider<BtSettingsNotifier, BtSettings>(
  useAidlVehicle ? HsssBtSettingsNotifier.new : BtSettingsNotifier.new,
);

/// Bluetooth settings: power, the paired phones, the pairing prompt and
/// "calls on the dashboard". This class is the mock and holds the rules
/// both sources share; [HsssBtSettingsNotifier] carries them out on the
/// head unit.
///
/// Pairing is started from the phone, as on stock: the scooter is visible,
/// the phone picks it, and the code arrives here to be confirmed. Stock has
/// no list of nearby devices and HSSS no call that starts a bond.
class BtSettingsNotifier extends Notifier<BtSettings> {
  /// The Bluetooth stack gives up on an unanswered request after about
  /// this long; nothing in HSSS dismisses the prompt when it does.
  static const pairingTimeout = Duration(seconds: 30);

  /// Stock rejects a pairing request once six phones are paired.
  static const maxPhones = 6;

  static const mockPairingName = 'Pixel 8';
  static const mockPairingCode = '482917';

  Timer? _pairTimer;
  bool _attempt = false;
  final List<({String address, String name})> _mockPhones = [
    (address: '00:11:22:33:44:01', name: VehicleNotifier.mockDeviceName),
    (address: '00:11:22:33:44:02', name: 'Galaxy S24'),
  ];

  @override
  BtSettings build() {
    ref.onDispose(() => _pairTimer?.cancel());
    watchSafety();
    ref.listen(vehicleProvider.select((v) => (v.btConnected, v.btDeviceName, v.scooterBtName)), (_, _) {
      state = state.copyWith(name: ref.read(vehicleProvider).scooterBtName, phones: _mockList());
    });
    return BtSettings(on: true, visible: true, name: ref.read(vehicleProvider).scooterBtName, phones: _mockList());
  }

  List<BtPhone> _mockList() {
    final v = ref.read(vehicleProvider);
    if (v.btConnected && v.btDeviceName.isNotEmpty && !_mockPhones.any((p) => p.name == v.btDeviceName)) {
      _mockPhones.add((address: '00:11:22:33:44:${(_mockPhones.length + 1).toString().padLeft(2, '0')}', name: v.btDeviceName));
    }
    return [
      for (final p in _mockPhones) BtPhone(address: p.address, name: p.name, connected: v.btConnected && v.btDeviceName == p.name),
    ];
  }

  /// A pairing prompt needs eyes and an answer: it goes when the scooter
  /// moves or locks, or when OpenDash is no longer what is on screen.
  @protected
  void watchSafety() {
    onRidingLockout(ref, () => _drop('moving'));
    ref.listen(vehicleProvider.select((v) => v.locked), (_, locked) {
      if (locked) _drop('locked');
    });
    onOwnScreenLost(ref, () => _drop('background'));
  }

  void _drop(String reason) {
    _reject(reason);
    if (state.consentOpen || state.forgetAddress.isNotEmpty || state.pairFailed) {
      state = state.copyWith(consentOpen: false, forgetAddress: '', pairFailed: false);
    }
  }

  /// [logAs] stands in for a message that names a phone.
  void _toast(String message, [ToastType type = ToastType.info, String? logAs]) =>
      ref.read(toastProvider.notifier).show(message, type: type, logAs: logAs);

  bool _refuse(String flow) {
    final why = state.readOnly;
    if (why != null) {
      _toast(why, ToastType.warning);
      return true;
    }
    return refuseUnlessStopped(ref, ref.read(vehicleProvider), flow, 'Stop to change Bluetooth settings');
  }

  // What the head unit does differently.

  @protected
  Future<bool> sendPower(bool on) async {
    if (!on) ref.read(vehicleProvider.notifier).setBtConnected(false);
    state = state.copyWith(on: on, visible: on);
    return true;
  }

  @protected
  Future<bool> sendVisible() async => true;

  @protected
  Future<bool> sendConnect(BtPhone phone, bool connect) async {
    ref.read(vehicleProvider.notifier).setBtConnected(connect, name: phone.name);
    return true;
  }

  @protected
  Future<bool> sendForget(BtPhone phone) async {
    if (phone.connected) ref.read(vehicleProvider.notifier).setBtConnected(false);
    _mockPhones.removeWhere((p) => p.address == phone.address);
    state = state.copyWith(phones: _mockList());
    return true;
  }

  @protected
  Future<bool> sendPairing(bool accept) async {
    if (accept) {
      final name = state.pairingName.isEmpty ? mockPairingName : state.pairingName;
      if (!_mockPhones.any((p) => p.name == name)) {
        _mockPhones.add((address: '00:11:22:33:44:${(_mockPhones.length + 1).toString().padLeft(2, '0')}', name: name));
      }
      state = state.copyWith(phones: _mockList());
      onBonded();
    }
    return true;
  }

  /// [consent] writes the consent value first, as stock does when the
  /// rider accepts it.
  @protected
  Future<bool> sendCalls(bool on, {required bool consent}) async => true;

  // Rider commands.

  /// The Bluetooth screen opened: while it is up the scooter is visible.
  void screenOpened() {
    if (state.readOnly != null || !state.on || state.visible) return;
    sendVisible();
  }

  Future<void> setOn(bool on) async {
    if (_refuse('bt_toggle')) return;
    final ok = await sendPower(on);
    logEvent('bt', 'toggle', {'on': on, 'ok': ok});
    if (!on) ref.read(vehicleProvider.notifier).btSnapshot('off');
    if (!ok) _toast("Couldn't switch Bluetooth ${on ? 'on' : 'off'}", ToastType.warning);
  }

  /// A tap on a paired phone: connect it, or disconnect it if it is the
  /// connected one. One phone at a time, as on stock.
  Future<void> toggleConnection(String address) async {
    final phone = state.phone(address);
    if (phone == null || _refuse('bt_connect')) return;
    final other = state.connected;
    if (!phone.connected && other != null) {
      _toast('Disconnect ${other.label} first', ToastType.warning, 'Disconnect the connected phone first');
      return;
    }
    final connect = !phone.connected;
    final ok = await sendConnect(phone, connect);
    logEvent('bt', 'connect', {'connect': connect, 'ok': ok});
    if (!connect) ref.read(vehicleProvider.notifier).btSnapshot('disconnect');
    if (!ok) {
      _toast(connect ? "Couldn't connect" : "Couldn't disconnect", ToastType.warning);
    } else if (connect) {
      _toast('Connecting…');
    }
  }

  void askForget(String address) {
    if (state.phone(address) == null || _refuse('bt_forget')) return;
    state = state.copyWith(forgetAddress: address);
  }

  void cancelForget() => state = state.copyWith(forgetAddress: '');

  Future<void> confirmForget() async {
    final phone = state.phone(state.forgetAddress);
    state = state.copyWith(forgetAddress: '');
    if (phone == null || _refuse('bt_forget')) return;
    final ok = await sendForget(phone);
    logEvent('bt', 'forget', {'ok': ok});
    _toast(ok ? 'Phone forgotten' : "Couldn't forget the phone", ok ? ToastType.info : ToastType.warning);
  }

  // Pairing.

  /// A phone asked to pair. Refused at once, as stock does, while riding or
  /// locked, with a phone already connected or with [maxPhones] paired; and
  /// with no screen to show it on.
  void onPairingRequest({required String name, required String code}) {
    logEvent('bt', 'pairing', {'stage': 'requested', 'has_code': code.isNotEmpty});
    _attempt = true;
    // Locked first: a locked scooter's data goes quiet, which reads as
    // "may be moving" (a request to a locked, parked scooter was once
    // logged as refused for moving).
    final reason = ref.read(vehicleProvider).locked
        ? 'locked'
        : ref.read(ridingLockoutProvider)
            ? 'moving'
            : !ref.read(ownScreenVisibleProvider)
                ? 'background'
                : state.connected != null
                    ? 'phone_connected'
                    : state.phones.length >= maxPhones
                        ? 'too_many'
                        : null;
    if (reason != null) {
      if (reason == 'phone_connected') {
        _toast('Disconnect ${state.connected!.label} to pair another phone', ToastType.warning, 'Disconnect the connected phone to pair another');
      }
      if (reason == 'too_many') _toast('$maxPhones phones are paired. Forget one first', ToastType.warning);
      _reject(reason);
      return;
    }
    _pairTimer?.cancel();
    _pairTimer = Timer(pairingTimeout, () => _reject('timeout'));
    state = state.copyWith(pairingOpen: true, pairingCode: code, pairingName: name, pairFailed: false);
    logEvent('bt', 'pairing', {'stage': 'shown'});
  }

  void _closePrompt() {
    _pairTimer?.cancel();
    _pairTimer = null;
    if (state.pairingOpen) state = state.copyWith(pairingOpen: false, pairingCode: '', pairingName: '');
  }

  void _reject(String reason) {
    if (!_attempt) return;
    _attempt = false;
    _closePrompt();
    logEvent('bt', 'pairing', {'stage': 'rejected', 'reason': reason});
    sendPairing(false);
  }

  void rejectPairing() => _reject('rider');

  Future<void> acceptPairing() async {
    if (!state.pairingOpen) return;
    if (refuseUnlessStopped(ref, ref.read(vehicleProvider), 'bt_pair', 'Stop to pair a phone')) {
      _reject('moving');
      return;
    }
    logEvent('bt', 'pairing', {'stage': 'accepted'});
    // Before the prompt closes: the mock reads the name from it.
    final sent = sendPairing(true);
    _closePrompt();
    if (!await sent && _attempt) {
      _attempt = false;
      logEvent('bt', 'pairing', {'stage': 'failed', 'reason': 'send'});
      _toast("Couldn't confirm the pairing", ToastType.warning);
    }
  }

  /// HSSS closed the prompt (it does after every accept and reject).
  @protected
  void onPromptDismissed() => _closePrompt();

  @protected
  void onBonded() {
    _closePrompt();
    if (!_attempt) return;
    _attempt = false;
    logEvent('bt', 'pairing', {'stage': 'bonded'});
    _toast('Phone paired', ToastType.success);
  }

  /// The bond did not form. [popup] is stock's "Device pairing failed"
  /// (HSSS `showPairFailPopUp`); anything else gets a toast.
  @protected
  void onPairFailed({required String reason, bool popup = false}) {
    _closePrompt();
    if (popup) state = state.copyWith(pairFailed: true);
    if (!_attempt) return;
    _attempt = false;
    logEvent('bt', 'pairing', {'stage': 'failed', 'reason': reason});
    if (!popup) _toast('Pairing did not complete', ToastType.warning);
  }

  void dismissPairFailed() => state = state.copyWith(pairFailed: false);

  // Calls on the dashboard.

  Future<void> setCallsAllowed(bool on) async {
    if (_refuse('bt_calls')) return;
    if (on && !state.callsConsent) {
      state = state.copyWith(consentOpen: true);
      return;
    }
    await _applyCalls(on, consent: false);
  }

  Future<void> acceptConsent() async {
    if (!state.consentOpen) return;
    state = state.copyWith(consentOpen: false);
    if (_refuse('bt_calls')) return;
    await _applyCalls(true, consent: true);
  }

  void declineConsent() => state = state.copyWith(consentOpen: false);

  Future<void> _applyCalls(bool on, {required bool consent}) async {
    state = state.copyWith(callsAllowed: on, callsConsent: consent ? true : null);
    saveCalls();
    final saved = await sendCalls(on, consent: consent);
    logEvent('call', 'allowed', {'on': on, 'consent': state.callsConsent, 'trigger': consent ? 'consent' : 'toggle', 'saved': saved});
    if (!saved) _toast("Couldn't save this to the scooter profile", ToastType.warning);
  }

  @protected
  void saveCalls() {
    PrefsService.setInt(PrefsKeys.phoneCalls, state.callsAllowed ? 1 : 0);
    PrefsService.setBool(PrefsKeys.phoneCallsConsent, state.callsConsent);
  }

  // Dev panel.

  void simulatePairingRequest() => onPairingRequest(name: mockPairingName, code: mockPairingCode);

  void simulatePairFailed() {
    _attempt = _attempt || state.pairingOpen;
    onPairFailed(reason: 'mock', popup: true);
  }
}

/// The head unit: state from the adapter (`BluetoothBridge.kt`), commands
/// through HSSS `IBluetoothSettings` and, for the calls setting, HPMS.
/// Read-only, and saying so, until HSSS is bound, has answered the probe
/// and holds our callbacks.
class HsssBtSettingsNotifier extends BtSettingsNotifier {
  static const notBound = "The scooter's Bluetooth service is not answering. Bluetooth is read-only";

  /// How long after coming back to the front HSSS's receivers are
  /// registered again: stock's `onStop`, which unregisters them, runs after
  /// our resume.
  static const reRegisterAfter = Duration(seconds: 5);

  /// `ProfileManagerCmd` names.
  static const syncContacts = 'INT_SYNC_CONTACTS';
  static const syncContactsPermission = 'INT_SYNC_CONTACTS_PERMISSION';

  /// `BluetoothDevice.BOND_*`.
  static const _bondNone = 10;
  static const _bonding = 11;
  static const _bonded = 12;

  StreamSubscription<dynamic>? _sub;
  Timer? _reRegister;
  bool _ready = false;
  bool _adapterOn = false;
  bool _callsKnown = false;
  bool _skipPairFail = false;
  String _pin = '';
  int _launchesSeen = 0;

  BtBridge get _bridge => ref.read(btBridgeProvider);

  @override
  BtSettings build() {
    ref.onDispose(() {
      _sub?.cancel();
      _pairTimer?.cancel();
      _reRegister?.cancel();
    });
    watchSafety();
    _sub = _bridge.events().listen(_onEvent, onError: (Object e) => logEvent('bt', 'channel_error', {'error': e.toString()}));
    final vehicle = ref.read(vehicleProvider.notifier);
    vehicle.phoneCallsHandler = _vehicleCalls;
    vehicle.callActionFallback = _hsssCallAction;
    ref.listen(ownScreenVisibleProvider, (_, shown) {
      if (shown) _afterResume();
    });
    final calls = PrefsService.getInt(PrefsKeys.phoneCalls, -1);
    _callsKnown = calls >= 0;
    return BtSettings(
      readOnly: notBound,
      callsAllowed: calls == 1,
      callsConsent: PrefsService.getBool(PrefsKeys.phoneCallsConsent, false),
    );
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    final hsss = event['hsss'];
    if (hsss is bool) hsss ? _onBound() : _onUnbound();
    final adapter = event['state'];
    if (adapter is Map) _applyAdapter(adapter);
    final pairing = event['pairing'];
    if (pairing is Map) _pairingEvent(pairing['event'], pairing['value']);
    final bond = event['bond'];
    if (bond is Map) _bondEvent(bond);
    final caller = event['callName'];
    if (caller is Map) _callerName(caller['state'], caller['name']);
  }

  void _onUnbound() {
    _ready = false;
    state = state.copyWith(readOnly: notBound);
  }

  Future<void> _onBound() async {
    final answered = await _probe();
    if (!answered) return;
    final ok = await _register();
    _ready = ok;
    state = state.copyWith(readOnly: ok ? null : notBound);
    if (ok) _afterAdapterChange();
    if (ok) _ensureProfiles('bound');
  }

  /// How long HSSS's proxies take to arrive after it asks for them.
  static const profileProxyWait = Duration(seconds: 1);

  /// HSSS drops, and answers calls on, only the connections it holds a
  /// profile proxy for, and it takes those proxies when a dashboard asks.
  /// Stock asks every time it sets Bluetooth up; OpenDash never did. So
  /// whenever HSSS had restarted (it has been seen to crash, and with
  /// the stock dashboard stopped nobody else asks), Disconnect and
  /// Bluetooth off were answered "done" and did nothing: a rider pressed
  /// Disconnect twenty times with music, calls and AVRCP still connected
  /// (`bt.snapshot`). Asked here when the proxies are missing.
  Future<void> _ensureProfiles(String reason) async {
    final missing = _tryDecode(
      await _hsss(HsssBluetooth.isBTProfileNullRequest(HsssBluetooth.profileIdHfpClient)),
      HsssBluetooth.decodeBool,
    );
    if (missing != true) return;
    final ok = await _hsss(HsssBluetooth.registerAllBtProfilesRequest()) != null;
    logEvent('bt', 'profiles_registered', {'reason': reason, 'ok': ok});
    if (ok) await Future<void>.delayed(profileProxyWait);
  }

  /// The read-only calls: do they answer, and do the layouts decode.
  Future<bool> _probe() async {
    final enabled = await _hsss(HsssBluetooth.isBtEnabledRequest());
    final scan = await _hsss(HsssBluetooth.getScanModeRequest());
    final bonded = await _hsss(HsssBluetooth.getBondedDevicesRequest());
    final hfpNull = await _hsss(HsssBluetooth.isBTProfileNullRequest(HsssBluetooth.profileIdHfpClient));
    final phone = state.connected;
    final hfp = phone == null ? null : await _hsss(HsssBluetooth.getConnectionStateRequest(phone.address, HsssBluetooth.profileHfpClient));
    int? bondedCount;
    String? error;
    try {
      if (bonded != null) bondedCount = HsssBluetooth.decodeBondedDevices(bonded).length;
    } catch (e) {
      error = e.toString();
    }
    final ok = enabled != null && scan != null && bondedCount != null;
    logEvent('bt', 'probe', {
      'ok': ok,
      'enabled': _tryDecode(enabled, HsssBluetooth.decodeBool),
      'scan_mode': _tryDecode(scan, HsssBluetooth.decodeInt),
      'bonded': bondedCount,
      'adapter_bonded': state.phones.length,
      'hfp_proxy': hfpNull == null ? null : !(_tryDecode(hfpNull, HsssBluetooth.decodeBool) ?? true),
      'hfp_state': _tryDecode(hfp, HsssBluetooth.decodeInt),
      'error': error,
    });
    return ok;
  }

  static T? _tryDecode<T>(Uint8List? reply, T Function(List<int>) decode) {
    if (reply == null) return null;
    try {
      return decode(reply);
    } catch (_) {
      return null;
    }
  }

  /// Our pairing and call-name callbacks into HSSS's slots, and its
  /// Bluetooth receivers registered (see `SystemSettingsClient.kt`).
  /// [afterStock]: stock's `onStop` has unregistered the receivers, so they
  /// are registered even though this process already did once.
  Future<bool> _register({bool afterStock = false}) async {
    final callbacks = await _native('hsssRegisterCallbacks');
    final receivers = await _native('hsssRegisterReceivers', afterStock);
    _launchesSeen = RecoveryService.stockLaunches;
    logEvent('bt', 'hsss_register', {'callbacks': callbacks, 'receivers': receivers, 'after_stock': afterStock});
    return callbacks;
  }

  void _afterResume() {
    if (!_ready || RecoveryService.stockLaunches == _launchesSeen) return;
    _reRegister?.cancel();
    _reRegister = Timer(reRegisterAfter, () {
      if (_ready && ref.read(ownScreenVisibleProvider)) _register(afterStock: true);
    });
  }

  Future<bool> _native(String method, [Object? args]) async {
    try {
      return await _bridge.invoke(method, args) == true;
    } catch (e) {
      logEvent('bt', 'native_error', {'method': method, 'error': _short(e)});
      return false;
    }
  }

  static String _short(Object e) {
    final text = e is PlatformException ? (e.message ?? e.code) : e.toString();
    return text.length > 160 ? text.substring(0, 160) : text;
  }

  /// One HSSS call, by method name; null when it was not sent (also when
  /// the scooter's HSSS has no such method) or HSSS threw.
  Future<Uint8List?> _hsss(HsssRequest request) async {
    if (!_ready && !HsssBluetooth.readOnly.contains(request.method)) {
      logEvent('bt', 'hsss_call', {'method': request.method, 'ok': false, 'error': 'read_only'});
      return null;
    }
    try {
      final reply = await _bridge.invoke('hsss', {'method': request.method, 'data': request.data});
      logEvent('bt', 'hsss_call', {'method': request.method, 'ok': true});
      return reply is Uint8List ? reply : Uint8List(0);
    } catch (e) {
      logEvent('bt', 'hsss_call', {'method': request.method, 'ok': false, 'error': _short(e)});
      return null;
    }
  }

  Future<bool> _hsssBool(HsssRequest request) async => _tryDecode(await _hsss(request), HsssBluetooth.decodeBool) ?? false;

  void _applyAdapter(Map<Object?, Object?> a) {
    final before = state.connected?.address;
    _adapterOn = a['enabled'] == true;
    final scan = a['scanMode'] is int ? a['scanMode'] as int : HsssBluetooth.scanNone;
    final raw = a['devices'];
    state = state.copyWith(
      on: _adapterOn && scan != HsssBluetooth.scanNone,
      visible: _adapterOn && scan == HsssBluetooth.scanDiscoverable,
      name: a['name'] is String ? a['name'] as String : '',
      phones: [
        if (raw is List)
          for (final d in raw)
            if (d is Map && d['address'] is String)
              BtPhone(address: d['address'] as String, name: d['name'] is String ? d['name'] as String : '', connected: d['connected'] == true),
      ],
    );
    final now = state.connected?.address;
    if (now != null && now != before) _onPhoneConnected(now);
    _afterAdapterChange();
  }

  /// Switching Bluetooth on from a stopped adapter takes two steps: the
  /// scan mode can only be set once the adapter is up.
  bool _wantVisible = false;

  void _afterAdapterChange() {
    if (!_wantVisible || !_adapterOn || !_ready) return;
    _wantVisible = false;
    if (!state.visible) sendVisible();
  }

  /// Stock tells HSSS the calls setting on every connection
  /// (`TelephonyInfoManager.onBTConnectionUpdate`): on connects the HFP
  /// client and syncs the phonebook, off disconnects the HFP client. With
  /// HHMIC stopped nobody else does. Nothing is sent until the setting is
  /// known.
  void _onPhoneConnected(String address) {
    if (!_ready || !_callsKnown) return;
    final on = state.callsAllowed;
    _hsss(HsssBluetooth.enablePhoneCallsRequest(on, address));
    logEvent('call', 'allowed', {'on': on, 'consent': state.callsConsent, 'trigger': 'connect'});
  }

  /// The profile's values, replayed by HHMIS at unlock. The vehicle wins;
  /// nothing is sent on a mirror.
  void _vehicleCalls(bool? allowed, bool? consent) {
    if (allowed != null) _callsKnown = true;
    if ((allowed == null || allowed == state.callsAllowed) && (consent == null || consent == state.callsConsent)) return;
    state = state.copyWith(callsAllowed: allowed, callsConsent: consent);
    saveCalls();
    logEvent('call', 'allowed', {'on': state.callsAllowed, 'consent': state.callsConsent, 'trigger': 'vehicle'});
  }

  void _pairingEvent(Object? event, Object? value) {
    switch (event) {
      case 'pin':
        _pin = value is String ? value : '';
      case 'popup':
        final code = RegExp(r'^\d{6}$').hasMatch(_pin) ? _pin : '';
        _pin = '';
        onPairingRequest(name: value is String ? value : '', code: code);
      case 'dismiss':
        onPromptDismissed();
      case 'fail':
        // HSSS raises it for a removed bond too, which is what Forget does;
        // stock skips that one as well (`disablePairFailPopup`).
        if (_skipPairFail) {
          _skipPairFail = false;
        } else {
          onPairFailed(reason: 'hsss', popup: true);
        }
    }
  }

  void _bondEvent(Map<Object?, Object?> bond) {
    final to = bond['state'];
    if (to == _bonded) {
      onBonded();
    } else if (to == _bondNone && bond['prev'] == _bonding) {
      onPairFailed(reason: 'bond_${bond['reason']}');
    }
  }

  /// HSSS hands back the number itself when its phonebook has no match.
  void _callerName(Object? callState, Object? name) {
    if (callState is! int) return;
    final text = name is String && name != 'DEEFAULTT' && RegExp(r'[^\d\s+\-()*#]').hasMatch(name) ? name : '';
    ref.read(vehicleProvider.notifier).applyCallerName(callState, text);
  }

  /// Answer / hang up through HSSS when the hidden HFP client call was
  /// refused. HSSS's own `callAction` recurses without end while its HFP
  /// proxy is missing, so that is asked first.
  Future<bool> _hsssCallAction(String action) async {
    final phone = state.connected;
    if (!_ready || phone == null) return false;
    await _ensureProfiles('call');
    if (!ref.mounted) return false;
    final proxyMissing = _tryDecode(
      await _hsss(HsssBluetooth.isBTProfileNullRequest(HsssBluetooth.profileIdHfpClient)),
      HsssBluetooth.decodeBool,
    );
    if (proxyMissing != false) return false;
    final verb = action == 'accept' ? HsssBluetooth.callAccept : HsssBluetooth.callTerminate;
    return _hsssBool(HsssBluetooth.callActionRequest(verb, phone.address));
  }

  /// Stock's toggle (`BTInfoManager.checkForConnectionStatus`). Off:
  /// disconnect the phone, drop every paired phone's profile priority to 0
  /// and make the adapter unconnectable. On: connectable and discoverable,
  /// priorities back to 100. The adapter itself is only ever switched on.
  ///
  /// The priorities are stock 4.6.14's; the 5.0.2 dashboard sets none, so
  /// they go only to software OpenDash has been ridden on
  /// (`ScooterCapabilities.setsBluetoothPriorities`): a phone left at 0 on
  /// a service nothing raises it on again would not reconnect.
  @override
  Future<bool> sendPower(bool on) async {
    final priorities = ref.read(scooterCapabilitiesProvider).setsBluetoothPriorities;
    if (!priorities) logEvent('bt', 'priorities_skipped', {'on': on, 'phones': state.phones.length});
    if (!on) {
      final phone = state.connected;
      if (phone != null) await _ensureProfiles('off');
      if (!ref.mounted) return false;
      if (phone != null) await _hsss(HsssBluetooth.disconnectDeviceRequest(phone.address));
      if (priorities) {
        for (final p in state.phones) {
          await _hsss(HsssBluetooth.setAllBtProfilesPriorityRequest(0, p.address));
        }
      }
      final ok = await _hsss(HsssBluetooth.setScanModeRequest(HsssBluetooth.scanNone)) != null;
      _native('refresh');
      return ok;
    }
    var ok = true;
    if (!_adapterOn) {
      _wantVisible = true;
      ok = await _hsss(HsssBluetooth.enableBTRequest()) != null;
    } else {
      ok = await sendVisible();
    }
    if (priorities) {
      for (final p in state.phones) {
        await _hsss(HsssBluetooth.setAllBtProfilesPriorityRequest(HsssBluetooth.priorityOn, p.address));
      }
    }
    _native('refresh');
    return ok;
  }

  @override
  Future<bool> sendVisible() async {
    final ok = await _hsss(HsssBluetooth.setScanModeRequest(HsssBluetooth.scanDiscoverable)) != null;
    _native('refresh');
    return ok;
  }

  @override
  Future<bool> sendConnect(BtPhone phone, bool connect) async {
    if (!connect) await _ensureProfiles('disconnect');
    if (!ref.mounted) return false;
    final reply = await _hsss(
      connect ? HsssBluetooth.connectDeviceRequest(phone.address) : HsssBluetooth.disconnectDeviceRequest(phone.address),
    );
    return reply != null;
  }

  /// Stock's order: HSSS `forgetDevice` (which only clears the phonebook it
  /// pulled), a disconnect if it is the connected phone, then the unpair
  /// itself, which HSSS has no call for.
  @override
  Future<bool> sendForget(BtPhone phone) async {
    _skipPairFail = true;
    await _hsss(HsssBluetooth.forgetDeviceRequest(phone.address));
    if (phone.connected) await _hsss(HsssBluetooth.disconnectDeviceRequest(phone.address));
    final ok = await _native('removeBond', phone.address);
    if (!ok) _skipPairFail = false;
    _native('refresh');
    return ok;
  }

  @override
  Future<bool> sendPairing(bool accept) async =>
      await _hsss(HsssBluetooth.pairingActionRequest(accept ? HsssBluetooth.pairAccept : HsssBluetooth.pairReject)) != null;

  /// Stock's order when the consent is accepted: the consent value
  /// (`INT_SYNC_CONTACTS_PERMISSION`), then the setting
  /// (`INT_SYNC_CONTACTS`), then `enablePhoneCalls` for the connected phone.
  @override
  Future<bool> sendCalls(bool on, {required bool consent}) async {
    _callsKnown = true;
    var saved = true;
    if (consent) saved = await _native('profileUpdateInt', {'cmd': syncContactsPermission, 'value': 1});
    saved = await _native('profileUpdateInt', {'cmd': syncContacts, 'value': on ? 1 : 0}) && saved;
    final phone = state.connected;
    if (phone != null) await _hsss(HsssBluetooth.enablePhoneCallsRequest(on, phone.address));
    return saved;
  }

  @override
  void simulatePairingRequest() {}

  @override
  void simulatePairFailed() {}
}
