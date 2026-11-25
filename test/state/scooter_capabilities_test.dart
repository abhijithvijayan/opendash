import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/scooter_model.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/scooter_capabilities.dart';

import '../helpers/stock.dart';

void main() {
  test('before the software is known, and in the mock, everything is there', () {
    const c = ScooterCapabilities();
    expect(c.sends(HhmisCmd.hazardToggle), isTrue);
    expect(c.hazard, isTrue);
    expect(c.regenModes, isTrue);
    expect(c.feature(RidingFeature.predictedRange), isTrue);
    expect(c.parkAssist, isFalse);
    expect(c.setsBluetoothPriorities, isTrue);
  });

  test('a feature needs both: the scooter fitted with it, and a command for it in its software', () {
    final four = stockIdentity();
    expect(ScooterCapabilities(software: four).feature(RidingFeature.hillHold), isTrue);
    expect(ScooterCapabilities(software: four, available: const {'hillHold': false}).feature(RidingFeature.hillHold), isFalse);

    final without = StockIdentity.fromEvent(
        {...stockContract('gen1-moveos4-4.6.14'), 'commands': [...four.commands.where((c) => c != 'PREDICT_RANGE_TOGGLE' && c != 'HAZARD_LIGHT_TOGGLE')]});
    final c = ScooterCapabilities(software: without);
    expect(c.feature(RidingFeature.predictedRange), isFalse);
    expect(c.feature(RidingFeature.hillHold), isTrue);
    expect(c.hazard, isFalse);
  });

  test('the smart headlight is taken as fitted whatever the scooter says', () {
    expect(const ScooterCapabilities(available: {'smartHeadlight': false}).feature(RidingFeature.smartHeadlight), isTrue);
  });

  test('every recorded build: what it adds and what the app does differently there', () {
    final four = ScooterCapabilities(software: stockIdentity());
    final five = ScooterCapabilities(software: stockIdentity('gen1-moveos5-5.0.2'));
    expect(four.parkAssist, isFalse);
    expect(five.parkAssist, isTrue);
    expect(four.setsBluetoothPriorities, isTrue);
    expect(five.setsBluetoothPriorities, isFalse, reason: 'stock 5.0.2 never sets them');
    for (final c in [four, five]) {
      expect(c.hazard, isTrue);
      expect(c.regenModes, isTrue);
      for (final f in HhmisCmd.features.keys) {
        // 5.0.2 lists the power boost toggle but no longer acts on it
        // (`MoveOs5Profile.ignores`).
        final offered = !(c == five && f == RidingFeature.adaptivePowerBoost);
        expect(c.feature(f), offered, reason: '${f.name} on ${c.software!.name}');
      }
    }
  });
}
