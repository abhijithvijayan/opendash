import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The logged reason when a safety flow stops for want of a surface.
const noPromptSurfaceReason = 'background';

/// A surface on which the rider can see a safety prompt and answer it is
/// showing: OpenDash's own screen (fed by the activity lifecycle,
/// `AidlVehicleNotifier.onLifecyclePause` / `onLifecycleResume`; the mock is
/// always showing), or the dash island over a phone-projection app once
/// Kotlin has confirmed it drew it (`lib/state/dash_island.dart`).
///
/// Nothing that counts down to, or waits to send, a vehicle command may run
/// without it. It says nothing about the data: whether the speed can be
/// trusted is `VehicleData.speedTrusted`, whichever surface shows the prompt.
///
/// Prompts that need the whole screen (restart confirm, lock countdown,
/// passcode, recovery, Bluetooth pairing) read [ownScreenVisibleProvider]
/// instead: the island cannot host them.
/// True while a tap on the island is being carried out. The island is
/// only trusted as a surface for prompts over a projection app, because
/// some system pages hide overlays without saying so; but a finger on it
/// proves it is there for that one action. Its boot button was once
/// pressed 24 times over Android Settings and refused each time,
/// with nothing said.
bool islandTapInHand = false;

final promptSurfaceVisibleProvider = NotifierProvider<PromptSurface, bool>(PromptSurface.new);

class PromptSurface extends Notifier<bool> {
  bool _screen = true;
  bool _island = false;

  @override
  bool build() => true;

  /// OpenDash's own screen became, or stopped being, the resumed activity.
  void screenShown(bool shown) {
    _screen = shown;
    ref.read(ownScreenVisibleProvider.notifier)._set(shown);
    _update();
  }

  /// The island is confirmed on screen over a projection app, or is not.
  void islandShown(bool shown) {
    _island = shown;
    _update();
  }

  void _update() {
    final next = _screen || _island;
    if (state != next) state = next;
  }
}

/// OpenDash's own screen is the resumed activity.
final ownScreenVisibleProvider = NotifierProvider<OwnScreen, bool>(OwnScreen.new);

class OwnScreen extends Notifier<bool> {
  @override
  bool build() => true;

  void _set(bool shown) {
    if (state != shown) state = shown;
  }
}

/// Runs [fn] when the last prompt surface goes away.
void onPromptSurfaceLost(Ref ref, void Function() fn) {
  ref.listen(promptSurfaceVisibleProvider, (_, visible) {
    if (!visible) fn();
  });
}

/// Runs [fn] when OpenDash's own screen stops being in front, island or not.
void onOwnScreenLost(Ref ref, void Function() fn) {
  ref.listen(ownScreenVisibleProvider, (_, visible) {
    if (!visible) fn();
  });
}
