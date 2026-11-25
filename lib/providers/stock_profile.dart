import '../models/scooter_model.dart';
import 'hhmis_mapping.dart' show customRideModeName;

/// How one generation of the stock software says things, where it differs
/// from the one OpenDash was built on.
///
/// The rest of the app speaks 4.6.14: [VehicleData], the event mapping in
/// `hhmis_mapping.dart` and every screen. A generation that sends a value
/// in another unit or shape gets a subclass here, and [normalise] turns
/// what it sends into what 4.6.14 would have sent before anything reads
/// it. So nothing outside this file asks which software the scooter runs.
///
/// Not here: which commands and events exist and their numbers (read from
/// the scooter's own service, `StockIdentity`), and what the scooter is
/// fitted with (`ScooterCapabilities`, which asks [ignores]).
class StockProfile {
  const StockProfile();

  /// The profile for [software]; 4.6.14's while it is not known yet, and
  /// for a version that cannot be read.
  static StockProfile of(StockIdentity? software) {
    final major = int.tryParse((software?.version ?? '').split('.').first) ?? 0;
    if (major >= 7) return const Service7Profile();
    return major >= 5 ? const MoveOs5Profile() : const StockProfile();
  }

  /// For the log.
  String get name => 'moveOs4';

  /// Rewrites one batch of events from the stock service, in place, into
  /// what 4.6.14 sends.
  void normalise(Map<Object?, Object?> delta) {}

  /// A command this software still lists but does nothing with: a control
  /// that would send it is not offered.
  bool ignores(String cmd) => false;
}

/// MoveOS 5 (service 5.0.2, read from its smali against 4.6.14).
class MoveOs5Profile extends StockProfile {
  const MoveOs5Profile();

  /// `Accident_Detected` and `ACCIDENT_EMERGENCY_WINDOW`, in the app's
  /// numbering of vehicle commands (`StockFixtures.APP_VEHICLE_COMMANDS`).
  static const accidentCommands = {152, 186};

  /// The drive-mode words 5.0.2 `VehicleManager.setDriveMode` sends for a
  /// stock mode or state.
  static const stockDriveModes = {'ECO', 'NORMAL', 'SPORT', 'HYPER', 'REVERSE', 'PARKED', 'SNA', 'EASY PARK'};

  /// `Constants.SC_ON`: the ordinary charger, which 4.6.14 sends as 0.
  static const slowChargerOn = 3;

  @override
  String get name => 'moveOs5';

  @override
  void normalise(Map<Object?, Object?> delta) {
    // Whole rpm, where 4.6.14 `VehicleManager.setMotorRpm` sends hundreds
    // (`div-int/lit8 0x64`, gone in 5.0.2). A MoveOS 5
    // scooter at 0 km/h sent 17: read as hundreds it showed 1,700 rpm and
    // put a stopped scooter past the speed check's tolerance.
    final rpm = delta['INT_VEHICLE_MOTOR_RPM'];
    if (rpm is num) delta['INT_VEHICLE_MOTOR_RPM'] = rpm ~/ 100;

    // 5.0.2 no longer sends `BOOL_ACCIDENT_SEVERITY_STAT` (its
    // `onAccidentSeverityStatus` only logs); an accident arrives only as a
    // vehicle command. Raised as the key 4.6.14 sends, and lowered by any
    // other command, so a later accident counts as a new one.
    final command = delta['INT_VEHICLE_COMMAND'];
    if (command is int) delta['BOOL_ACCIDENT_SEVERITY_STAT'] = accidentCommands.contains(command);

    final charger = delta['INT_BOOST_HYPER_CHARGE_STATUS'];
    if (charger == slowChargerOn) delta['INT_BOOST_HYPER_CHARGE_STATUS'] = 0;

    // The custom ride mode's drive mode is the name the rider gave it
    // (`VehicleManager.setDriveMode`, `DriveModes.CUSTOM`). Any word that
    // is not a stock mode is that name; the name itself comes in its own
    // event, so it goes no further than this.
    final mode = delta['STR_VEHICLE_DRIVE_MODE'];
    if (mode is String && !stockDriveModes.contains(mode.toUpperCase())) {
      delta['STR_VEHICLE_DRIVE_MODE'] = customRideModeName;
    }

    // The service sets the power-boost light only from the VCU's drive
    // mode and leaves it at a stop; the 5.0.2 dashboard clears it at speed
    // 0 and on PARK.
    if (delta['INT_VEHICLE_SPEED'] == 0 || delta['STR_VEHICLE_DRIVE_MODE'] == 'PARKED') {
      delta['BOOL_VEHICLE_ADAPTIVE_POWER_BOOST_STATUS'] = false;
    }
  }

  /// 5.0.2 dropped the handler, the echo and the profile push of the power
  /// boost toggle (`IClientServiceInterfaceBuilder` case 47 is gone).
  @override
  bool ignores(String cmd) => cmd == 'ADAPTIVE_POWERBOOST_TOGGLE';
}

/// Service 7.x, MoveOS 5 as an S1 Pro Gen 3 runs it (7.1.30, read
/// from its smali against 5.0.2). Everything [MoveOs5Profile]
/// rewrites is the same there; two things are not.
class Service7Profile extends MoveOs5Profile {
  const Service7Profile();

  @override
  String get name => 'service7';

  @override
  void normalise(Map<Object?, Object?> delta) {
    super.normalise(delta);
    // 4.6.14 and 5.0.2 `SettingsServerConnection.setChimeVolume` /
    // `setMotorVolume` halve the 0-14 they are sent and echo 0-7; 7.1.30
    // keeps it whole (chime 14 becomes 15) and echoes that.
    for (final key in const ['_chimeVolume', '_motorVolume']) {
      final level = delta[key];
      if (level is int) delta[key] = (level / 2).round().clamp(0, 7);
    }
  }

  /// 7.1.30 handles the power boost toggle again, as 4.6.14 did
  /// (`IClientServiceInterfaceBuilder` case 49, `BOOL_APB_TOGGLE_STAT`).
  @override
  bool ignores(String cmd) => false;
}
