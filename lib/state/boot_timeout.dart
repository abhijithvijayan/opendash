import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screen_state.dart';

enum BootTimeout { waiting, slow, options }

final bootTimeoutProvider = NotifierProvider<BootTimeoutNotifier, BootTimeout>(BootTimeoutNotifier.new);

/// Escalates the boot splash while HHMIS stays silent: a "taking longer"
/// note at [slowAfter], escape hatches at [optionsAfter]. A manufacturer
/// OTA that changes the AIDL surface would land here.
class BootTimeoutNotifier extends Notifier<BootTimeout> {
  static const slowAfter = Duration(seconds: 15);
  static const optionsAfter = Duration(seconds: 30);
  Timer? _slow;
  Timer? _options;

  @override
  BootTimeout build() {
    ref.onDispose(_cancel);
    ref.listen(sessionProvider.select((s) => s.booted), (_, booted) {
      if (booted) {
        _cancel();
        state = BootTimeout.waiting;
      } else {
        _start();
      }
    });
    if (!ref.read(sessionProvider).booted) _start();
    return BootTimeout.waiting;
  }

  void _start() {
    _cancel();
    _slow = Timer(slowAfter, () => state = BootTimeout.slow);
    _options = Timer(optionsAfter, () => state = BootTimeout.options);
  }

  void _cancel() {
    _slow?.cancel();
    _options?.cancel();
    _slow = null;
    _options = null;
  }
}
