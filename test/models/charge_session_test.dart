import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/charge_session.dart';

void main() {
  test('tracker accumulates Wh over measured seconds and keeps the peak', () {
    final t = ChargeEnergyTracker();
    for (var i = 0; i < 60; i++) {
      t.sample(50, 8, 1);
    }
    expect(t.energyKwh, closeTo(0.0067, 0.0001));
    expect(t.peakPowerKw, closeTo(0.4, 1e-9));
    expect(t.durationMinutes, 1);
    expect(t.samples, 60);
    t.sample(55, 10, 1);
    expect(t.peakPowerKw, closeTo(0.55, 1e-9));
    expect(t.avgPowerKw, closeTo(t.energyKwh / (61 / 3600), 1e-6));
  });

  test('a late tick counts for the time that really passed', () {
    final t = ChargeEnergyTracker();
    t.sample(50, 10, 2.5);
    expect(t.energyKwh * 1000, closeTo(50 * 10 * 2.5 / 3600, 1e-9));
  });

  test('a gap longer than maxGap adds time but no energy', () {
    final t = ChargeEnergyTracker();
    t.sample(50, 10, 1);
    t.sample(50, 10, 65);
    expect(t.energyKwh * 1000, closeTo(50 * 10 / 3600, 1e-9));
    expect(t.durationMinutes, 1, reason: 'the session lasted that long on the clock');
  });

  test('current drawn from the pack while plugged in is not charging', () {
    final t = ChargeEnergyTracker();
    for (var i = 0; i < 60; i++) {
      t.sample(57, -0.5, 1);
    }
    expect(t.energyKwh, 0);
    expect(t.samples, 0);
  });

  test('duration and average power are by the clock, quiet seconds included', () {
    final t = ChargeEnergyTracker();
    for (var i = 0; i < 60; i++) {
      t.sample(50, 10, 1);
    }
    for (var i = 0; i < 60; i++) {
      t.sample(50, 0, 1);
    }
    expect(t.durationMinutes, 2);
    expect(t.avgPowerKw, closeTo(0.25, 1e-9), reason: '0.5 kW for half of two minutes');
  });

  test('summary carries the session figures', () {
    final t = ChargeEnergyTracker();
    for (var i = 0; i < 120; i++) {
      t.sample(52, 9, 1);
    }
    final s = t.summary(startSoc: 32, endSoc: 98, timestamp: 1700000000000);
    expect(s.startSoc, 32);
    expect(s.endSoc, 98);
    expect(s.durationMinutes, 2);
    expect(s.energyKwh, closeTo(0.0156, 0.0001));
    expect(s.peakPowerKw, closeTo(0.468, 1e-9));
    expect(s.avgPowerKw, closeTo(0.468, 1e-6));
    expect(s.timestamp, 1700000000000);
  });

  test('summary JSON round-trips and rejects bad input', () {
    const s = ChargeSessionSummary(
      energyKwh: 1.84, startSoc: 32, endSoc: 98, durationMinutes: 48, peakPowerKw: 2.4, avgPowerKw: 2.3, timestamp: 1700000000000,
    );
    final back = ChargeSessionSummary.fromJson(s.toJson());
    expect(back, s);
    expect(ChargeSessionSummary.fromJson({'energyKwh': 'lots'}), isNull);
    expect(ChargeSessionSummary.fromJson('nope'), isNull);
    expect(ChargeSessionSummary.fromJson({...s.toJson(), 'timestamp': 1.5}), isNull);
  });

  test('samples with no power do not count', () {
    final t = ChargeEnergyTracker();
    t.sample(0, 0, 1);
    t.sample(52, 0, 1);
    expect(t.samples, 0);
    t.sample(52, 9, 1);
    expect(t.samples, 1);
  });

  test('an empty session reports zeros, not NaN', () {
    final t = ChargeEnergyTracker();
    expect(t.avgPowerKw, 0);
    expect(t.energyKwh, 0);
    expect(t.durationMinutes, 0);
  });

  test('a wide charge implies a full-pack capacity; a short one does not', () {
    const wide = ChargeSessionSummary(
      energyKwh: 2.1, startSoc: 32, endSoc: 98, durationMinutes: 60, peakPowerKw: 2.6, avgPowerKw: 2.1, timestamp: 1700000000000,
    );
    // 2.1 kWh over 66 points -> ~3.18 kWh full pack.
    expect(wide.impliedPackKwh, closeTo(2.1 / 0.66, 1e-6));
    const narrow = ChargeSessionSummary(
      energyKwh: 0.3, startSoc: 80, endSoc: 90, durationMinutes: 10, peakPowerKw: 2, avgPowerKw: 1.8, timestamp: 1700000000000,
    );
    expect(narrow.impliedPackKwh, isNull, reason: '10-point span is too short to trust');
  });
}
