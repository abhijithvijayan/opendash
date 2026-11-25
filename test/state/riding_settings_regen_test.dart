import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/riding_settings.dart';

class _RecordingVehicle extends VehicleNotifier {
  final sent = <RegenMode>[];
  @override
  void sendRegenMode(RegenMode mode) {
    sent.add(mode);
    super.sendRegenMode(mode);
  }
}

void main() {
  test('every regen mode reaches the vehicle, and the setting follows its echo', () {
    final c = ProviderContainer(overrides: [vehicleProvider.overrideWith(_RecordingVehicle.new)]);
    addTearDown(c.dispose);
    final vehicle = c.read(vehicleProvider.notifier) as _RecordingVehicle;
    final riding = c.read(ridingSettingsProvider.notifier);
    const picks = [RegenMode.city, RegenMode.highway, RegenMode.off, RegenMode.standard];
    for (final m in picks) {
      riding.setRegenMode(m);
      expect(c.read(ridingSettingsProvider).regenMode, m);
      expect(c.read(ridingSettingsProvider).regenPending, isNull);
    }
    expect(vehicle.sent, picks);
  });

  test('picking the active mode again sends nothing', () {
    final c = ProviderContainer(overrides: [vehicleProvider.overrideWith(_RecordingVehicle.new)]);
    addTearDown(c.dispose);
    final vehicle = c.read(vehicleProvider.notifier) as _RecordingVehicle;
    c.read(ridingSettingsProvider.notifier).setRegenMode(RegenMode.standard);
    expect(vehicle.sent, isEmpty);
  });

  test('HVSM replays the vehicle persisted mode and the setting follows it', () {
    final c = ProviderContainer(overrides: [vehicleProvider.overrideWith(_RecordingVehicle.new)]);
    addTearDown(c.dispose);
    final vehicle = c.read(vehicleProvider.notifier) as _RecordingVehicle;
    c.read(ridingSettingsProvider);
    vehicle.setRegenMode(RegenMode.off);
    expect(c.read(ridingSettingsProvider).regenMode, RegenMode.off);
    expect(vehicle.sent, isEmpty, reason: 'a vehicle echo must not loop back as a send');
    vehicle.setRegenMode(RegenMode.highway);
    expect(c.read(ridingSettingsProvider).regenMode, RegenMode.highway);
    expect(vehicle.sent, isEmpty);
  });
}
