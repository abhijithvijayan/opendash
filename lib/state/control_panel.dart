import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mock_provider.dart';
import 'prompt_surface.dart';
import 'riding_lockout.dart';
import 'screen_state.dart';
import 'toast_state.dart';

final controlPanelOpenProvider =
    NotifierProvider<ControlPanelOpen, bool>(ControlPanelOpen.new);

/// Open/closed state of the slide-in quick actions panel. Closes itself on
/// every screen change so it never carries over to a screen it doesn't
/// belong on. It stays up without trustworthy vehicle data: the lockout
/// strips it down to the lights and Restart scooter, which is the way out.
class ControlPanelOpen extends Notifier<bool> {
  @override
  bool build() {
    ref.listen(screenStateProvider, (_, _) => state = false);
    return false;
  }

  void toggle() => state = !state;
  void open() => state = true;
  void close() => state = false;
}

final lockConfirmProvider =
    NotifierProvider<LockConfirm, bool>(LockConfirm.new);

/// Two-tap lock. The first tap arms for [window]; a second tap inside the
/// window locks the scooter, otherwise it disarms.
class LockConfirm extends Notifier<bool> {
  static const window = Duration(seconds: 2);
  Timer? _timer;

  @override
  bool build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen(screenStateProvider, (_, _) => cancel());
    return false;
  }

  void tap() {
    if (state) {
      cancel();
      ref.read(lockingProvider.notifier).start();
      return;
    }
    state = true;
    _timer?.cancel();
    _timer = Timer(window, cancel);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    if (state) state = false;
  }
}

final lockingProvider = NotifierProvider<LockingNotifier, bool>(LockingNotifier.new);

/// True while the lock command is in flight. The mock takes [duration];
/// Phase 2 ends it on the AIDL lock callback instead.
class LockingNotifier extends Notifier<bool> {
  static const duration = Duration(milliseconds: 1500);
  Timer? _timer;

  @override
  bool build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen(vehicleProvider.select((v) => v.provenStopped), (_, stopped) {
      if (stopped || !state) return;
      cancel();
      final v = ref.read(vehicleProvider);
      if (v.speed > 0) {
        ref.read(toastProvider.notifier).show('Locking cancelled — scooter is moving', type: ToastType.warning);
      } else {
        untrustedCancel(ref, v, 'lock');
      }
    });
    onOwnScreenLost(ref, () {
      if (!state) return;
      cancel();
      untrustedCancel(ref, ref.read(vehicleProvider), 'lock', ownScreen: true);
    });
    return false;
  }

  void start() {
    if (state) return;
    if (refuseUnlessStopped(ref, ref.read(vehicleProvider), 'lock', 'Stop to lock the scooter')) return;
    state = true;
    _timer?.cancel();
    _timer = Timer(duration, () {
      _timer = null;
      state = false;
      ref.read(vehicleProvider.notifier).lockScooter();
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    if (state) state = false;
  }
}

final leftSwitchFailureProvider =
    NotifierProvider<LeftSwitchFailure, bool>(LeftSwitchFailure.new);

/// Dev reminder that the physical left switch cluster is dead and the touch
/// panel is standing in for it. Display only.
class LeftSwitchFailure extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool on) => state = on;
}
