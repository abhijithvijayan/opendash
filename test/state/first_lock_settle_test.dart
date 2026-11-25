import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/screen_state.dart';

/// A vehicle that, like HHMIS, says "locked" first and the truth a moment
/// later.
class _Hhmis extends VehicleNotifier {
  @override
  Duration get firstLockSettle => const Duration(seconds: 1);
}

void main() {
  void start(void Function(FakeAsync async, ProviderContainer c, VehicleNotifier v) body) {
    fakeAsync((async) {
      final c = ProviderContainer(overrides: [vehicleProvider.overrideWith(_Hhmis.new)]);
      c.listen(screenStateProvider, (_, _) {});
      final v = c.read(vehicleProvider.notifier)
        ..dropConnection()
        ..setLocked(true);
      c.read(sessionProvider.notifier).simulateAidlTimeout();
      async.flushMicrotasks();
      expect(c.read(screenStateProvider), ScreenState.booting);
      body(async, c, v);
      c.dispose();
    });
  }

  test('a first "locked" that turns out not to be is never shown as the lock screen', () {
    start((async, c, v) {
      v.setConnected(true);
      async.elapse(const Duration(milliseconds: 600));
      expect(c.read(screenStateProvider), ScreenState.booting,
          reason: 'the lock screen showed for 0.6 s before the dashboard');
      v.setLocked(false);
      async.flushMicrotasks();
      expect(c.read(screenStateProvider), ScreenState.parked);
      async.elapse(const Duration(seconds: 2));
      expect(c.read(screenStateProvider), ScreenState.parked);
    });
  });

  test('a scooter that really is locked gets its lock screen a second after connecting', () {
    start((async, c, v) {
      v.setConnected(true);
      async.elapse(const Duration(milliseconds: 999));
      expect(c.read(screenStateProvider), ScreenState.booting);
      async.elapse(const Duration(milliseconds: 1));
      expect(c.read(screenStateProvider), ScreenState.locked);
    });
  });
}
