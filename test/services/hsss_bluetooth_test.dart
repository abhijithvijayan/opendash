import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/services/hsss_bluetooth.dart';
import 'package:opendash/services/parcel_codec.dart';
import 'package:opendash/state/bt_settings.dart';

/// The expected bytes are built here from the layouts in HSSS
/// `IBluetoothSettings$Stub.onTransact`, without the codec under test:
/// little-endian int32s; a string is its UTF-16 length, the code units, a
/// 16-bit zero and padding to four bytes.
List<int> i32(int v) => (ByteData(4)..setInt32(0, v, Endian.little)).buffer.asUint8List();

List<int> str(String s) {
  final out = <int>[...i32(s.length)];
  for (final u in s.codeUnits) {
    out
      ..add(u & 0xff)
      ..add(u >> 8);
  }
  out.addAll([0, 0]);
  while (out.length % 4 != 0) {
    out.add(0);
  }
  return out;
}

/// A `BluetoothDevice` argument: the presence int, then its address.
List<int> dev(String address) => [...i32(1), ...str(address)];

const phone = 'AA:BB:CC:DD:EE:FF';

void main() {
  group('parcel primitives', () {
    test('a string is length, UTF-16LE, terminator, padded to 4', () {
      final w = ParcelWriter()..writeString('AB');
      expect(w.toBytes(), [2, 0, 0, 0, 0x41, 0, 0x42, 0, 0, 0, 0, 0]);
      final odd = ParcelWriter()..writeString('ABC');
      expect(odd.toBytes(), [3, 0, 0, 0, 0x41, 0, 0x42, 0, 0x43, 0, 0, 0]);
      final empty = ParcelWriter()..writeString('');
      expect(empty.toBytes(), [0, 0, 0, 0, 0, 0, 0, 0]);
      final none = ParcelWriter()..writeString(null);
      expect(none.toBytes(), [0xff, 0xff, 0xff, 0xff]);
    });

    test('reads back what it wrote, in order', () {
      final w = ParcelWriter()
        ..writeInt(-7)
        ..writeString('Ola S1 Pro')
        ..writeBool(true)
        ..writeString(null)
        ..writeString('é☂');
      final r = ParcelReader(w.toBytes());
      expect(r.readInt(), -7);
      expect(r.readString(), 'Ola S1 Pro');
      expect(r.readBool(), isTrue);
      expect(r.readString(), isNull);
      expect(r.readString(), 'é☂');
      expect(r.remaining, 0);
    });

    test('a truncated value throws instead of reading past the end', () {
      expect(() => ParcelReader([1, 0]).readInt(), throwsA(isA<ParcelFormatException>()));
      expect(() => ParcelReader([...i32(5), 0x41, 0]).readString(), throwsA(isA<ParcelFormatException>()));
    });
  });

  group('requests', () {
    void check(HsssRequest r, String method, List<int> data) {
      expect(r.method, method);
      expect(r.data, data, reason: r.method);
    }

    test('calls with no argument carry no payload', () {
      check(HsssBluetooth.enableBTRequest(), 'enableBT', const []);
      check(HsssBluetooth.isBtEnabledRequest(), 'isBtEnabled', const []);
      check(HsssBluetooth.getBondedDevicesRequest(), 'getBondedDevices', const []);
      check(HsssBluetooth.getScanModeRequest(), 'getScanMode', const []);
    });

    test('int and string arguments', () {
      check(HsssBluetooth.setScanModeRequest(23), 'setScanMode', i32(23));
      check(HsssBluetooth.setScanModeRequest(20), 'setScanMode', i32(20));
      check(HsssBluetooth.isBTProfileNullRequest(16), 'isBTProfileNull', i32(16));
      check(HsssBluetooth.registerAllBtProfilesRequest(), 'registerAllBtProfiles', const []);
      check(HsssBluetooth.pairingActionRequest('ACCEPT'), 'pairingAction', str('ACCEPT'));
      check(HsssBluetooth.pairingActionRequest('REJECT'), 'pairingAction', str('REJECT'));
    });

    test('a device is a presence int and its address', () {
      check(HsssBluetooth.forgetDeviceRequest(phone), 'forgetDevice', dev(phone));
      check(HsssBluetooth.disconnectDeviceRequest(phone), 'disconnectDevice', dev(phone));
      check(HsssBluetooth.connectDeviceRequest(phone), 'connectDevice', dev(phone));
      expect(dev(phone).length, 4 + 4 + 36);
    });

    test('argument order follows the stub', () {
      check(HsssBluetooth.callActionRequest('ACCEPT', phone), 'callAction', [...str('ACCEPT'), ...dev(phone)]);
      check(HsssBluetooth.callActionRequest('TERMINATE', phone), 'callAction', [...str('TERMINATE'), ...dev(phone)]);
      check(HsssBluetooth.setAllBtProfilesPriorityRequest(100, phone), 'setAllBtProfilesPriority', [...i32(100), ...dev(phone)]);
      check(HsssBluetooth.getConnectionStateRequest(phone, 'HEADSET_CLIENT'), 'getConnectionState', [...dev(phone), ...str('HEADSET_CLIENT')]);
      check(HsssBluetooth.enablePhoneCallsRequest(true, phone), 'enablePhoneCalls', [...i32(1), ...dev(phone)]);
      check(HsssBluetooth.enablePhoneCallsRequest(false, phone), 'enablePhoneCalls', [...i32(0), ...dev(phone)]);
    });
  });

  group('replies', () {
    test('a boolean and an int', () {
      expect(HsssBluetooth.decodeBool(i32(1)), isTrue);
      expect(HsssBluetooth.decodeBool(i32(0)), isFalse);
      expect(HsssBluetooth.decodeInt(i32(23)), 23);
      expect(() => HsssBluetooth.decodeBool(const []), throwsA(isA<ParcelFormatException>()));
    });

    test('BluetoothDeviceSet: presence, list flag, then writeList of devices', () {
      List<int> entry(String address) => [...i32(4), ...str('android.bluetooth.BluetoothDevice'), ...str(address)];
      final two = [...i32(1), ...i32(1), ...i32(2), ...entry(phone), ...entry('11:22:33:44:55:66')];
      expect(HsssBluetooth.decodeBondedDevices(two), [phone, '11:22:33:44:55:66']);
      expect(HsssBluetooth.decodeBondedDevices([...i32(1), ...i32(1), ...i32(0)]), isEmpty);
      expect(HsssBluetooth.decodeBondedDevices(i32(0)), isEmpty, reason: 'null set');
      expect(HsssBluetooth.decodeBondedDevices([...i32(1), ...i32(0)]), isEmpty, reason: 'null list');
    });

    test('a list entry that is not a BluetoothDevice is refused', () {
      final wrong = [...i32(1), ...i32(1), ...i32(1), ...i32(0), ...str('x')];
      expect(() => HsssBluetooth.decodeBondedDevices(wrong), throwsA(isA<ParcelFormatException>()));
    });
  });

  group('what may be sent', () {
    final kotlin = File('android/app/src/main/kotlin/in/abhijithvijayan/opendash/hsss/StockCalls.kt').readAsStringSync();
    Set<String> quoted(String block) => RegExp(r'"(\w+)"').allMatches(block).map((m) => m.group(1)!).toSet();

    test('the Kotlin allow-list is exactly the calls this codec builds, by name', () {
      final block = RegExp(r'object HsssCalls \{.*?val ALLOWED = setOf\(([^)]*)\)', dotAll: true).firstMatch(kotlin)!.group(1)!;
      expect(quoted(block), HsssBluetooth.all);
      expect(HsssBluetooth.all, hasLength(15));
    });

    test('nothing that silences HSSS for its other clients, or always throws', () {
      for (final name in ['unregisterReceivers', 'unregisterAllBtProfiles', 'pairingPopUp', 'disableBT']) {
        expect(HsssBluetooth.all, isNot(contains(name)));
      }
    });

    test('the probe set changes nothing', () {
      expect(HsssBluetooth.readOnly, {'isBtEnabled', 'getBondedDevices', 'isBTProfileNull', 'getConnectionState', 'getScanMode'});
      expect(HsssBluetooth.all.containsAll(HsssBluetooth.readOnly), isTrue);
    });

    test('the two profile values are the only ones Kotlin writes, by name', () {
      final block = RegExp(r'object HpmsCalls \{.*?val ALLOWED = setOf\(([^)]*)\)', dotAll: true).firstMatch(kotlin)!.group(1)!;
      expect(quoted(block), {HsssBtSettingsNotifier.syncContacts, HsssBtSettingsNotifier.syncContactsPermission});
    });

    test('Dart holds no transaction code and no profile ordinal', () {
      final codec = File('lib/services/hsss_bluetooth.dart').readAsStringSync();
      expect(codec, isNot(contains('0x')));
      expect(RegExp(r'static const \w+ = \d+;').allMatches(codec).map((m) => m.group(0)), [
        'static const scanNone = 20;',
        'static const scanDiscoverable = 23;',
        'static const priorityOn = 100;',
        'static const profileIdHfpClient = 16;',
      ], reason: 'Bluetooth values, which are arguments; a call is a name');
      final settings = File('lib/state/bt_settings.dart').readAsStringSync();
      expect(settings, isNot(contains('0x')));
      expect(settings, contains("{'method': request.method, 'data': request.data}"));
      expect(settings, isNot(contains("'code':")));
    });
  });
}
