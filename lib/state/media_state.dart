import '../services/analytics_logger.dart';
import 'apps_state.dart';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mock_provider.dart';
import 'bt_settings.dart';
import 'riding_lockout.dart';
import 'screen_state.dart';
import 'settings_state.dart';
import 'toast_state.dart';

// These notifiers listen on vehicle selects and the ridingLockout notifier
// rather than derived providers such as screenState: provider-to-provider listeners
// rebuild lazily in Riverpod 3, so a derived provider's "close" callback
// can land after a later open().
bool _riding(Ref ref) => ref.read(ridingLockoutProvider);

/// Fires the connect/disconnect toasts. Kept alive from the root.
final btWatcherProvider = NotifierProvider<BtWatcher, bool>(BtWatcher.new);

class BtWatcher extends Notifier<bool> {
  @override
  bool build() {
    // What a drop costs the rider decides how it is said. The select
    // carries what Bluetooth was doing, because the same update that drops
    // the link also clears the music.
    ref.listen(vehicleProvider.select((v) => (v.btConnected, v.mediaPlaying || v.callActive)), (before, now) {
      final prev = before?.$1;
      final connected = now.$1;
      if (prev == connected) return;
      final name = ref.read(vehicleProvider).btDeviceName;
      final toast = ref.read(toastProvider.notifier);
      final projecting =
          (ref.read(outsideAppProvider)?.projection ?? false) || (ref.read(projectionResumeProvider)?.projection ?? false);
      if (connected) {
        toast.show(name.isEmpty ? 'Bluetooth connected' : 'Bluetooth connected: $name',
            type: ToastType.success, logAs: 'Bluetooth connected');
      } else if (projecting) {
        // Wireless CarPlay and Android Auto start over Bluetooth and then
        // let it go for Wi-Fi: the phone connects, drops
        // Bluetooth five seconds later, and CarPlay runs on. A warning on the
        // island then said the opposite of what the rider could see. The
        // same with CarPlay left behind the dashboard for a moment.
        logEvent('bt', 'disconnect_quiet', {'reason': 'projection'});
      } else if (before?.$2 ?? false) {
        // Music or a call went with it: that is worth a warning.
        toast.show('Bluetooth disconnected', type: ToastType.warning);
      } else {
        // Nothing was in use: said, not warned (a warning grows the island).
        toast.show('Bluetooth disconnected');
      }
      state = connected;
    });
    return ref.read(vehicleProvider).btConnected;
  }
}

final btScreenOpenProvider = NotifierProvider<BtScreenOpen, bool>(BtScreenOpen.new);

/// The Bluetooth settings screen. Never available while riding; closes
/// itself if the scooter starts moving or the screen state changes.
class BtScreenOpen extends Notifier<bool> {
  @override
  bool build() {
    onRidingLockout(ref, () => state = false);
    ref.listen(vehicleProvider.select((v) => (v.isCharging, v.locked)), (_, _) => state = false);
    ref.listen(sessionProvider, (_, _) => state = false);
    return false;
  }

  void open() {
    if (_riding(ref) || ref.read(vehicleProvider).locked) return;
    closeAllOverlays(ref, self: btScreenOpenProvider, keepSettings: true);
    state = true;
    ref.read(btSettingsProvider.notifier).screenOpened();
  }

  void close() => state = false;
}

final volumeOverlayProvider = NotifierProvider<VolumeOverlayState, bool>(VolumeOverlayState.new);

/// Volume popup. Auto-hides after [idle] without interaction. It shows the
/// level itself, so nothing is announced when it closes: a "Volume: 65%"
/// toast on top of the slider said the same thing twice.
///
/// [flash] is the stock behaviour for a level changed elsewhere (the
/// handlebar buttons): the popup shows for [idle], while riding too, where
/// it is display only. Stock holds it back for 1.5 s after a phone
/// connects or the vehicle state changes, when the stream is re-reported.
class VolumeOverlayState extends Notifier<bool> {
  static const idle = Duration(seconds: 3);
  static const blockAfterChange = Duration(milliseconds: 1500);
  static const blockAfterConnect = Duration(seconds: 8);
  Timer? _timer;
  Timer? _block;

  @override
  bool build() {
    ref.onDispose(() {
      _timer?.cancel();
      _block?.cancel();
    });
    ref.read(vehicleProvider.notifier).onExternalVolume = flash;
    // Unlocking counts as a state change here. When the head unit wakes,
    // HHMIS replays an old volume, and the real one follows about 650 ms
    // after the passcode is accepted: that step (12 to 7, once)
    // was read as the handlebar buttons and the bar came up at unlock.
    ref.listen(vehicleProvider.select((v) => (v.btConnected, v.vehicleState, v.locked)), (before, now) {
      _block?.cancel();
      // A phone that has just connected sets the volume to its own a few
      // seconds later, when its music starts: once that came 3.3 s
      // after the connection and the bar came up as if the rider had
      // pressed the buttons.
      final connected = before?.$1 == false && now.$1;
      _block = Timer(connected ? blockAfterConnect : blockAfterChange, () => _block = null);
    });
    // Music starting or stopping moves the level too (0.4 s later, same log).
    ref.listen(vehicleProvider.select((v) => v.mediaPlaying), (_, _) {
      if (_block != null) return;
      _block = Timer(blockAfterChange, () => _block = null);
    });
    onRidingLockout(ref, dismiss);
    ref.listen(vehicleProvider.select((v) => (v.isCharging, v.locked)), (_, _) => dismiss());
    ref.listen(sessionProvider, (_, _) => dismiss());
    return false;
  }

  void open() {
    if (_riding(ref)) return;
    state = true;
    touch();
  }

  void flash() {
    if (_block != null || ref.read(vehicleProvider).locked) return;
    state = true;
    touch();
  }

  /// Restart the idle clock on every interaction.
  void touch() {
    _timer?.cancel();
    _timer = Timer(idle, dismiss);
  }

  void setLevel(int level) {
    ref.read(vehicleProvider.notifier).setVolume(level, announce: false);
    touch();
  }

  void dismiss() {
    _timer?.cancel();
    _timer = null;
    if (!state) return;
    state = false;
  }
}
