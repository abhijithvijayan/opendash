import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/scooter_model.dart';
import '../providers/mock_provider.dart';
import '../providers/stock_profile.dart';
import '../providers/vehicle_provider.dart';
import 'riding_settings.dart';

/// What the scooter in front of the app has: the one place a screen or a
/// sender asks. It joins the two things that decide it, which arrive
/// separately and mean different things:
///
/// - what the scooter's software can be told ([software]: the commands its
///   stock service has, read from that service);
/// - what the scooter says it is fitted with ([available]: the
///   `*_FEATURE_AVAILABLE` events).
///
/// Unknown counts as "has it" on both: the software is not known for the
/// first moments of a start and never in the mock, and the scooter sends
/// each availability flag only when it changes.
class ScooterCapabilities {
  const ScooterCapabilities({this.software, this.available = const {}, this.vehicleType});

  final StockIdentity? software;

  /// `VehicleData.featureAvailable`.
  final Map<String, bool> available;
  final int? vehicleType;

  /// Whether the scooter's software has the stock command [cmd] and acts
  /// on it (`StockProfile.ignores`).
  bool sends(String cmd) =>
      software == null || (software!.commands.contains(cmd) && !StockProfile.of(software).ignores(cmd));

  /// Whether the scooter says it is fitted with [key] (a
  /// `RidingFeature.name`, `hazard` or `regen`).
  bool fitted(String key) =>
      // This VCU reports the smart headlight as absent yet acts on its trigger (seen in a ride log).
      // TODO(smart-headlight-available): overridden on the strength of one ride log from one scooter.
      // Another scooter may really lack it; drop the override once the flag's meaning is read from the stock service.
      key == 'smartHeadlight' || (available[key] ?? true);

  /// A riding feature can be switched on: fitted, and its command exists.
  /// One with no command of its own (kept in the app) only has to be fitted.
  bool feature(RidingFeature f) {
    final cmd = HhmisCmd.features[f];
    return fitted(f.name) && (cmd == null || sends(cmd));
  }

  bool get hazard => fitted('hazard') && sends(HhmisCmd.hazardToggle);

  /// Regen modes other than the default.
  bool get regenModes => fitted('regen') && sends(HhmisCmd.regenSettingsUpdate);

  /// The software has the low-speed "park assist" vehicle state (MoveOS 5).
  bool get parkAssist => software?.states.contains('PARK_ASSIST') ?? false;

  /// Whether to set each paired phone's profile priority when Bluetooth is
  /// switched off and on, as the stock 4.6.14 dashboard does. The stock
  /// 5.0.2 dashboard makes no such call anywhere, so only software OpenDash
  /// has been ridden on gets it.
  bool get setsBluetoothPriorities => software == null || software!.checked;

  @override
  bool operator ==(Object other) =>
      other is ScooterCapabilities &&
      identical(other.software, software) &&
      identical(other.available, available) &&
      other.vehicleType == vehicleType;

  @override
  int get hashCode => Object.hash(software, available, vehicleType);
}

final scooterCapabilitiesProvider = Provider<ScooterCapabilities>((ref) {
  final software = ref.watch(vehicleProvider.notifier).software;
  void changed() => ref.invalidateSelf();
  software.addListener(changed);
  ref.onDispose(() => software.removeListener(changed));
  final (available, type) = ref.watch(vehicleProvider.select((v) => (v.featureAvailable, v.vehicleType)));
  return ScooterCapabilities(software: software.value, available: available, vehicleType: type);
});
