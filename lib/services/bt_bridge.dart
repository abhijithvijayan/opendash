import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Dart end of `BluetoothBridge.kt`. Events are one-key maps: `hsss`
/// (bool), `state`, `pairing`, `bond`, `callName`. Methods: `hsss`
/// (`{method, data}` → reply bytes, the method by its stock name),
/// `hsssRegisterCallbacks`, `hsssRegisterReceivers`, `profileUpdateInt`
/// (`{cmd, value}`, the value by its `ProfileManagerCmd` name),
/// `removeBond` (address), `refresh`.
class BtBridge {
  const BtBridge();

  static const _events = EventChannel('in.abhijithvijayan.opendash.bt/events');
  static const _commands = MethodChannel('in.abhijithvijayan.opendash.bt/commands');

  Stream<dynamic> events() => _events.receiveBroadcastStream();

  Future<Object?> invoke(String method, [Object? args]) => _commands.invokeMethod<Object?>(method, args);
}

final btBridgeProvider = Provider<BtBridge>((_) => const BtBridge());
