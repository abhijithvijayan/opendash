import 'dart:typed_data';

import 'parcel_codec.dart';

/// One `IBluetoothSettings` call: the stock method's name and the request
/// payload that follows the interface token. `SystemSettingsClient.kt`
/// finds the method's transaction code in the HSSS installed on the
/// scooter, adds the token, transacts, checks the reply's exception header
/// and hands back what follows it.
typedef HsssRequest = ({String method, Uint8List data});

/// Client side of HSSS `com.olaelectric.systemsettings.IBluetoothSettings`
/// (`com.olaelectric.connectivityservice`, system uid), the interface stock
/// HHMIC drives Bluetooth through. Calls are made by method name, never by
/// transaction code: no code is written in Dart. Layouts are from
/// `IBluetoothSettings$Stub.onTransact` in HSSS.apk; what each call does is
/// from `BTInfoManager` / `BTPairingManagerRepo`. None is oneway: every
/// reply starts with the exception header.
///
/// A `BluetoothDevice` argument is an int 1 followed by the device, which
/// parcels as its address string. A boolean is an int.
///
/// Left out on purpose:
///  - `pairingPopUp`: dereferences a null `PairingInfo` and always
///    throws. The pairing code and the phone's name come from
///    `IPairingStatusUpdate`.
///  - `pairingStatus` is only ever false; `getIncomingCallName` returns
///    null; `getCurrentDeviceState` throws with no device.
///  - `unregisterReceivers`, `unregisterAllBtProfiles`: they silence HSSS
///    for every client. `registerReceivers` is Kotlin's to send.
///  - `callAction("REJECT")` also texts the caller through MAP; only
///    ACCEPT and TERMINATE are offered.
///  - `disableBT`: stock never switches the adapter off (its toggle
///    makes it unconnectable instead).
///  - `discoveryStatus`: stock scans only to reconnect a paired
///    phone; pairing starts on the phone.
abstract final class HsssBluetooth {
  static const enableBT = 'enableBT';
  static const isBtEnabled = 'isBtEnabled';
  static const pairingAction = 'pairingAction';
  static const forgetDevice = 'forgetDevice';
  static const disconnectDevice = 'disconnectDevice';
  static const connectDevice = 'connectDevice';
  static const callAction = 'callAction';

  /// HSSS takes its profile proxies (A2DP sink, AVRCP controller, HFP
  /// client, MAP and PBAP). Stock HHMIC calls it whenever it sets its
  /// Bluetooth listeners up (`BTInfoManager$1.registerProxyListeners`).
  /// Without the proxies HSSS's `disconnectDevice` and `callAction` answer
  /// "done" and do nothing.
  static const registerAllBtProfiles = 'registerAllBtProfiles';
  static const setScanMode = 'setScanMode';
  static const setAllBtProfilesPriority = 'setAllBtProfilesPriority';
  static const getBondedDevices = 'getBondedDevices';
  static const isBTProfileNull = 'isBTProfileNull';
  static const getConnectionState = 'getConnectionState';
  static const getScanMode = 'getScanMode';
  static const enablePhoneCalls = 'enablePhoneCalls';

  /// Every call this file can build; `HsssCalls.ALLOWED` in Kotlin refuses
  /// any other (a test compares the two lists).
  static const all = {
    enableBT, isBtEnabled, pairingAction, forgetDevice, disconnectDevice, connectDevice, callAction, registerAllBtProfiles,
    setScanMode,
    setAllBtProfilesPriority, getBondedDevices, isBTProfileNull, getConnectionState, getScanMode, enablePhoneCalls,
  };

  /// The calls that change nothing: the probe on each bind.
  static const readOnly = {isBtEnabled, getBondedDevices, isBTProfileNull, getConnectionState, getScanMode};

  /// `BluetoothAdapter` scan modes. Stock sets [scanDiscoverable] while a
  /// phone may connect and [scanNone] while Bluetooth is locked.
  static const scanNone = 20;
  static const scanDiscoverable = 23;

  /// `BluetoothProfile` priority stock sets on a phone it connects.
  static const priorityOn = 100;

  /// A profile name `getConnectionState` accepts; an unknown string throws
  /// inside HSSS.
  static const profileHfpClient = 'HEADSET_CLIENT';

  /// `isBTProfileNull` takes the `BluetoothProfile` id.
  static const profileIdHfpClient = 16;

  static const pairAccept = 'ACCEPT';
  static const pairReject = 'REJECT';
  static const callAccept = 'ACCEPT';
  static const callTerminate = 'TERMINATE';

  static HsssRequest _req(String method, [void Function(ParcelWriter w)? write]) {
    final w = ParcelWriter();
    write?.call(w);
    return (method: method, data: w.toBytes());
  }

  static void _device(ParcelWriter w, String address) {
    w.writeInt(1);
    w.writeString(address);
  }

  static HsssRequest isBtEnabledRequest() => _req(isBtEnabled);
  static HsssRequest registerAllBtProfilesRequest() => _req(registerAllBtProfiles);
  static HsssRequest getScanModeRequest() => _req(getScanMode);
  static HsssRequest getBondedDevicesRequest() => _req(getBondedDevices);
  static HsssRequest isBTProfileNullRequest(int profileId) => _req(isBTProfileNull, (w) => w.writeInt(profileId));

  static HsssRequest getConnectionStateRequest(String address, String profile) => _req(getConnectionState, (w) {
        _device(w, address);
        w.writeString(profile);
      });

  static HsssRequest enableBTRequest() => _req(enableBT);
  static HsssRequest setScanModeRequest(int mode) => _req(setScanMode, (w) => w.writeInt(mode));
  static HsssRequest connectDeviceRequest(String address) => _req(connectDevice, (w) => _device(w, address));
  static HsssRequest disconnectDeviceRequest(String address) => _req(disconnectDevice, (w) => _device(w, address));
  static HsssRequest forgetDeviceRequest(String address) => _req(forgetDevice, (w) => _device(w, address));
  static HsssRequest pairingActionRequest(String action) => _req(pairingAction, (w) => w.writeString(action));

  static HsssRequest setAllBtProfilesPriorityRequest(int priority, String address) =>
      _req(setAllBtProfilesPriority, (w) {
        w.writeInt(priority);
        _device(w, address);
      });

  static HsssRequest enablePhoneCallsRequest(bool on, String address) => _req(enablePhoneCalls, (w) {
        w.writeBool(on);
        _device(w, address);
      });

  static HsssRequest callActionRequest(String action, String address) => _req(callAction, (w) {
        w.writeString(action);
        _device(w, address);
      });

  static bool decodeBool(List<int> reply) => ParcelReader(reply).readBool();
  static int decodeInt(List<int> reply) => ParcelReader(reply).readInt();

  /// `BluetoothDeviceSet`: a presence int, a byte (in an int slot) saying
  /// whether the list is there, then `writeList` of `BluetoothDevice`:
  /// a count and, per device, VAL_PARCELABLE (4), the class name and the
  /// address. Returns the addresses.
  static List<String> decodeBondedDevices(List<int> reply) {
    final r = ParcelReader(reply);
    if (r.readInt() == 0 || r.readInt() == 0) return const [];
    final count = r.readInt();
    if (count < 0 || count > 64) throw ParcelFormatException('device count $count');
    final out = <String>[];
    for (var i = 0; i < count; i++) {
      final type = r.readInt();
      final name = r.readString();
      if (type != 4 || name != 'android.bluetooth.BluetoothDevice') {
        throw ParcelFormatException('list entry $type');
      }
      out.add(r.readString() ?? '');
    }
    return out;
  }
}
