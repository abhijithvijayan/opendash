import 'dart:typed_data';

/// The flat part of Android's `Parcel` wire format, as Android 10 writes
/// it: every value padded to 4 bytes, little-endian. Enough for the HSSS
/// Bluetooth transactions (`hsss_bluetooth.dart`), whose arguments and
/// replies are ints, booleans, strings and `BluetoothDevice` (one string).
/// Binders and file descriptors are not flat and never pass through here;
/// `SystemSettingsClient.kt` handles those with the real `Parcel`.
class ParcelWriter {
  final BytesBuilder _out = BytesBuilder(copy: false);

  void writeInt(int v) {
    final b = ByteData(4)..setInt32(0, v, Endian.little);
    _out.add(b.buffer.asUint8List());
  }

  /// AIDL writes a boolean as an int.
  void writeBool(bool v) => writeInt(v ? 1 : 0);

  /// `Parcel.writeString`: the UTF-16 length in code units, the code units,
  /// a 16-bit terminator, then padding to a 4-byte boundary. Null is -1.
  void writeString(String? s) {
    if (s == null) {
      writeInt(-1);
      return;
    }
    final units = s.codeUnits;
    writeInt(units.length);
    final padded = ((units.length + 1) * 2 + 3) & ~3;
    final b = ByteData(padded);
    for (var i = 0; i < units.length; i++) {
      b.setUint16(i * 2, units[i], Endian.little);
    }
    _out.add(b.buffer.asUint8List());
  }

  Uint8List toBytes() => _out.toBytes();
}

/// Thrown by [ParcelReader] when the bytes end before the value does.
class ParcelFormatException implements Exception {
  const ParcelFormatException(this.message);
  final String message;

  @override
  String toString() => 'ParcelFormatException: $message';
}

class ParcelReader {
  ParcelReader(List<int> bytes) : _data = ByteData.sublistView(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));

  final ByteData _data;
  int _at = 0;

  int get remaining => _data.lengthInBytes - _at;

  int readInt() {
    if (remaining < 4) throw const ParcelFormatException('truncated int');
    final v = _data.getInt32(_at, Endian.little);
    _at += 4;
    return v;
  }

  bool readBool() => readInt() != 0;

  String? readString() {
    final length = readInt();
    if (length < 0) return null;
    final padded = ((length + 1) * 2 + 3) & ~3;
    if (remaining < padded) throw const ParcelFormatException('truncated string');
    final units = List<int>.generate(length, (i) => _data.getUint16(_at + i * 2, Endian.little));
    _at += padded;
    return String.fromCharCodes(units);
  }
}
