import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/state/cruise_watch.dart';

void main() {
  test('a press that does not engage toasts after the arm window', () {
    final w = CruiseWatch();
    expect(w.onUpdate(pressed: false, engaged: false, availability: 4, nowMs: 0), isNull);
    expect(w.onUpdate(pressed: true, engaged: false, availability: 4, nowMs: 0), isNull);
    expect(w.onUpdate(pressed: true, engaged: false, availability: 4, nowMs: 1499), isNull);
    expect(w.onUpdate(pressed: true, engaged: false, availability: 4, nowMs: 1500), 'Cruise unavailable');
  });

  test('message is reason-aware per availability ordinal', () {
    String? fire(int? a) {
      final w = CruiseWatch();
      w.onUpdate(pressed: true, engaged: false, availability: a, nowMs: 0);
      return w.onUpdate(pressed: true, engaged: false, availability: a, nowMs: 1500);
    }

    expect(fire(2), 'Cruise not available in this mode');
    expect(fire(3), 'Cruise: speed out of range');
    expect(fire(4), 'Cruise unavailable');
    expect(fire(null), 'Cruise unavailable');
  });

  test('cruise engaging within the window cancels the toast', () {
    final w = CruiseWatch();
    w.onUpdate(pressed: true, engaged: false, availability: 0, nowMs: 0);
    expect(w.onUpdate(pressed: true, engaged: true, availability: 1, nowMs: 800), isNull);
    expect(w.onUpdate(pressed: true, engaged: true, availability: 1, nowMs: 1500), isNull);
    expect(w.onUpdate(pressed: true, engaged: true, availability: 1, nowMs: 3000), isNull);
  });

  test('a press while cruise is active (disengage) never toasts', () {
    final w = CruiseWatch();
    w.onUpdate(pressed: false, engaged: true, availability: 1, nowMs: 0);
    expect(w.onUpdate(pressed: true, engaged: true, availability: 1, nowMs: 10), isNull);
    expect(w.onUpdate(pressed: true, engaged: false, availability: 4, nowMs: 2000), isNull);
  });

  test('a burst of presses within the cooldown yields one toast', () {
    final w = CruiseWatch();
    // first press -> toast
    w.onUpdate(pressed: true, engaged: false, availability: 4, nowMs: 0);
    expect(w.onUpdate(pressed: true, engaged: false, availability: 4, nowMs: 1500), 'Cruise unavailable');
    // release, press again well within the 5s cooldown
    w.onUpdate(pressed: false, engaged: false, availability: 4, nowMs: 2000);
    w.onUpdate(pressed: true, engaged: false, availability: 4, nowMs: 2100);
    expect(w.onUpdate(pressed: true, engaged: false, availability: 4, nowMs: 3600), isNull);
  });

  test('no press, no toast', () {
    final w = CruiseWatch();
    expect(w.onUpdate(pressed: false, engaged: false, availability: 4, nowMs: 5000), isNull);
    expect(w.onUpdate(pressed: false, engaged: false, availability: 4, nowMs: 9000), isNull);
  });
}
