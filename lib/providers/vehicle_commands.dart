import '../models/vehicle_data.dart';

/// What a `CommandFromVehicle` ordinal (HHMIS `INT_VEHICLE_COMMAND`) does to
/// the dashboard. Derived from stock HHMIC `VehicleInfoManager.
/// handleDerateEvents` and HHMIS `VehicleManager.setVehicleCommand`
/// (decompiled): stock shows one popup at a time, held until the
/// next command or 0, for 3 s, or counting down 5 / 10 / 30 s; HHMIS only
/// plays the chime.
enum CommandEffect {
  /// Performance reduced; sets `deratingActive` until a rerate or LOCK.
  derate,

  /// Performance restored; clears `deratingActive`.
  rerate,

  /// A fault only a restart clears (the VCU sends no clear ordinal).
  fault,

  /// Information only.
  info,
}

class VehicleCommand {
  const VehicleCommand(
    this.effect,
    this.title,
    this.body, {
    this.held = true,
    this.seconds,
    this.countsDown = true,
    AlertPriority? priority,
    this.action,
  }) : priority = priority ??
            (effect == CommandEffect.fault
                ? AlertPriority.critical
                : effect == CommandEffect.derate
                    ? AlertPriority.warning
                    : AlertPriority.info);
  final CommandEffect effect;
  final String title;
  final String body;

  /// Stock holds the popup until the next command; otherwise it times out
  /// after 3 s and is a toast here.
  final bool held;

  /// Stock's `DERATION_BASED_POPUP` with a timer: the notice closes by
  /// itself after this long. With [countsDown] the body ends "in" and the
  /// seconds left are appended, as stock's `NotificationTimer.onTick` does.
  final int? seconds;
  final bool countsDown;

  /// Follows the effect unless given: stock's red / orange icon on a
  /// refusal that is no fault and latches nothing.
  final AlertPriority priority;
  final AlertAction? action;

  VehicleNotice notice(int ordinal, {int? secondsLeft}) => VehicleNotice(
        ordinal,
        title,
        secondsLeft != null && countsDown ? '$body $secondsLeft s' : body,
        priority,
        action: action,
      );
}

/// `INT_HILL_HOLD_STATUS` 4 (stock `onHillHoldActive`: `HILL_HOLD_POPUP`,
/// "Deactivating Hillhold in", 3 s `GenericTimerPopUp`) and the handlebar
/// prompt stock raises when the ESCL goes unlock-failed -> unlocked
/// (`showESCLUnlockPopup`). Neither is a `CommandFromVehicle`, so they take
/// ids no ordinal can have and share the one-notice-at-a-time slot.
const hillHoldNoticeId = -1;
const handlebarNoticeId = -2;
const hillHoldReleasing =
    VehicleCommand(CommandEffect.info, 'Hill hold', 'Releasing in', seconds: 3, priority: AlertPriority.warning);
const handlebarPrompt = VehicleCommand(
  CommandEffect.info,
  'Handlebar may still be locked',
  'Turn the handlebar, then retry',
  seconds: 10,
  countsDown: false,
  priority: AlertPriority.warning,
  action: AlertAction.retryUnlock,
);

const _overheated = VehicleCommand(CommandEffect.derate, 'Overheated', 'Wait for the scooter to cool down');
const _cantSwitch = VehicleCommand(CommandEffect.derate, 'Reduced performance', "Can't switch modes");
const _cantSwitchBrief = VehicleCommand(CommandEffect.derate, 'Reduced performance', "Can't switch modes", held: false);
const _hotToPark = VehicleCommand(CommandEffect.derate, 'Overheating', 'Switching to Park in', seconds: 10);
const _hotToNormal = VehicleCommand(CommandEffect.derate, 'Overheating', 'Switching to Normal in', seconds: 10);
const _toEco = VehicleCommand(CommandEffect.derate, 'Reduced performance', 'Switching to Eco in', seconds: 10);
const _sensorToNormal = VehicleCommand(CommandEffect.derate, 'Battery sensor issue', 'Switching to Normal in', seconds: 10);
const _batteryToNormal = VehicleCommand(CommandEffect.derate, 'Battery issue', 'Switching to Normal in', seconds: 10);
const _batteryToPark = VehicleCommand(CommandEffect.fault, 'Battery issue', 'Switching to Park in', seconds: 10);
const _contactService = VehicleCommand(CommandEffect.fault, 'Scooter issue', 'Contact service');
// Stock `showRestartButtonPopUp` (RESTART_POPUP): the popup has a button.
const _restart =
    VehicleCommand(CommandEffect.fault, 'Scooter issue', 'Restart the scooter', action: AlertAction.restartScooter);
const _reconnectCharger = VehicleCommand(CommandEffect.info, 'Charging not started', 'Reconnect the charger');
const _readyAgain = VehicleCommand(CommandEffect.rerate, 'Ready to ride again', '', held: false);
const _fullPerformance = VehicleCommand(CommandEffect.rerate, 'Full performance restored', '', held: false);
const _chargingSlowly = VehicleCommand(CommandEffect.info, 'Charging slowly', 'Contact service');
const _unableToCharge = VehicleCommand(CommandEffect.info, 'Unable to charge', 'Contact service');
const _cruiseUnavailable = VehicleCommand(CommandEffect.info, 'Reduced performance', 'Cruise unavailable', held: false);

/// Ordinals HHMIS forwards (the *_INPGRS states, the final SOC derates,
/// TYPE1/2/3 faults and 121-124 never reach the client).
const vehicleCommands = <int, VehicleCommand>{
  2: _contactService,
  3: _overheated,
  4: VehicleCommand(CommandEffect.derate, 'Battery empty', 'Charge to keep riding'),
  5: _cantSwitch,
  6: VehicleCommand(CommandEffect.derate, 'Battery low', 'Too low to switch modes'),
  7: VehicleCommand(CommandEffect.fault, 'Scooter issue', 'Switching to Park'),
  8: _readyAgain,
  9: _hotToPark,
  11: VehicleCommand(CommandEffect.derate, 'Out of charge', 'Parking in', seconds: 10),
  13: _hotToNormal,
  15: _fullPerformance,
  16: VehicleCommand(CommandEffect.derate, 'Very low battery', 'Switching to Eco in', seconds: 10),
  32: VehicleCommand(CommandEffect.derate, 'Low battery', 'Switching to Normal in', seconds: 30),
  // GENERAL_LOW_BATTERY: the VCU's own threshold, held like stock's popup.
  34: VehicleCommand(CommandEffect.info, 'Low battery', 'Charge soon', priority: AlertPriority.warning),
  35: _hotToNormal,
  37: _hotToPark,
  39: _overheated,
  40: _cantSwitch,
  41: _readyAgain,
  43: _hotToPark,
  44: _hotToPark,
  45: _overheated,
  46: _overheated,
  47: _cantSwitchBrief,
  48: _cantSwitchBrief,
  49: _hotToNormal,
  50: _hotToNormal,
  51: _fullPerformance,
  52: _fullPerformance,
  53: _fullPerformance,
  54: _toEco,
  55: _toEco,
  56: _readyAgain,
  57: _readyAgain,
  58: VehicleCommand(CommandEffect.info, 'Too hot to charge', 'Charging will start soon'),
  63: _sensorToNormal,
  64: VehicleCommand(CommandEffect.fault, 'Battery issue', 'Contact service'),
  65: _sensorToNormal,
  66: _sensorToNormal,
  67: _batteryToPark,
  68: _sensorToNormal,
  69: _batteryToPark,
  70: _chargingSlowly,
  71: VehicleCommand(CommandEffect.derate, 'Scooter issue', 'Limited to Eco'),
  72: _restart,
  73: _contactService,
  74: VehicleCommand(CommandEffect.fault, 'Scooter issue', 'Switched to Park'),
  75: _restart,
  76: _contactService,
  77: VehicleCommand(CommandEffect.fault, 'Battery sensor issue', 'Contact service'),
  78: _chargingSlowly,
  79: _unableToCharge,
  80: _chargingSlowly,
  81: _unableToCharge,
  82: _chargingSlowly,
  83: _unableToCharge,
  84: VehicleCommand(CommandEffect.info, 'Battery cold', 'Charging slowly'),
  85: VehicleCommand(CommandEffect.derate, 'Battery cold', 'Limited to Normal'),
  86: VehicleCommand(CommandEffect.derate, 'Battery too cold', 'Switching to Park'),
  87: _chargingSlowly,
  88: VehicleCommand(CommandEffect.derate, 'Scooter issue', "Can't switch modes"),
  91: _batteryToNormal,
  92: _batteryToNormal,
  93: VehicleCommand(CommandEffect.fault, 'Scooter issue', 'Switching to Park in', seconds: 10),
  94: _fullPerformance,
  95: _fullPerformance,
  96: _fullPerformance,
  97: _fullPerformance,
  98: _readyAgain,
  99: _cantSwitchBrief,
  100: _fullPerformance,
  101: _hotToNormal,
  102: VehicleCommand(CommandEffect.info, 'Charger hot', 'Charging slowly'),
  103: _cantSwitch,
  104: _cantSwitch,
  105: _cantSwitch,
  106: _contactService,
  107: VehicleCommand(CommandEffect.fault, 'Battery cutoff', 'Scooter coming to a halt'),
  108: _reconnectCharger,
  109: _reconnectCharger,
  113: VehicleCommand(CommandEffect.rerate, 'Normal mode available again', '', held: false),
  // The owner or a geofence took riding access away (red popups in stock).
  125: VehicleCommand(CommandEffect.info, 'Riding access revoked', 'Ends once the scooter is parked',
      priority: AlertPriority.critical),
  131: VehicleCommand(CommandEffect.info, 'Safe to unplug the Hypercharger', '', held: false),
  132: VehicleCommand(CommandEffect.info, 'Initializing Hypercharger', '', held: false),
  133: VehicleCommand(CommandEffect.info, 'Hypercharger fault', 'Unplug the charger now'),
  134: VehicleCommand(CommandEffect.info, 'Hill hold', 'May be less effective'),
  138: VehicleCommand(CommandEffect.info, 'Access revoked', 'Contact the owner to regain access',
      priority: AlertPriority.critical),
  // CONFIG_MISMATCH / VERSION_MISMATCH: stock reuses MCU_GRADE2_CONTACT_CS (73).
  139: _contactService,
  140: _contactService,
  142: VehicleCommand(CommandEffect.info, "Can't switch to Sport", 'Scooter issue'),
  143: VehicleCommand(CommandEffect.info, "Can't switch to Sport", 'Battery too low'),
  144: VehicleCommand(CommandEffect.info, "Can't switch to Sport", 'Scooter too hot'),
  // Parental control. 146 is the S1 Pro wording; the S1 Air variants
  // (5, 8) say "sports mode" only.
  146: VehicleCommand(CommandEffect.info, 'Not allowed to switch to Sport or Hyper', '', held: false),
  147: VehicleCommand(CommandEffect.info, 'Not allowed to switch to Hyper', '', held: false),
  154: VehicleCommand(CommandEffect.info, 'Low battery', 'Cruise off in', seconds: 5),
  155: VehicleCommand(CommandEffect.info, 'Low battery', 'Cruise unavailable'),
  157: VehicleCommand(CommandEffect.info, 'Battery too cold to charge', 'Please wait'),
  161: VehicleCommand(CommandEffect.info, 'Scooter issue', 'Cruise unavailable', held: false),
  162: VehicleCommand(CommandEffect.fault, 'Scooter issue', 'Pull over safely and contact service'),
  163: VehicleCommand(CommandEffect.fault, 'Scooter issue', 'Parked. Contact service'),
  164: VehicleCommand(CommandEffect.derate, 'Scooter issue', "Can't switch modes"),
  165: VehicleCommand(CommandEffect.derate, 'Reduced performance', 'Cruise unavailable'),
  166: VehicleCommand(CommandEffect.fault, 'Throttle issue', 'Contact service'),
  167: _cantSwitchBrief,
  168: _cruiseUnavailable,
  169: _toEco,
  171: _cantSwitchBrief,
  172: _cruiseUnavailable,
  173: _toEco,
  // Delivery, service-mode and part-mismatch states; red in stock where
  // the scooter also refuses to drive.
  180: VehicleCommand(CommandEffect.info, 'Not delivered yet', 'Delivery range used up', priority: AlertPriority.critical),
  181: VehicleCommand(CommandEffect.info, 'Scooter ready', 'Submit the OTP to confirm delivery',
      priority: AlertPriority.warning),
  182: VehicleCommand(CommandEffect.info, 'Service mode', 'Contact service', priority: AlertPriority.critical),
  183: VehicleCommand(CommandEffect.info, 'Service mode', 'The scooter is in service mode',
      priority: AlertPriority.warning),
  184: VehicleCommand(CommandEffect.info, 'Part mismatch', 'Contact service', priority: AlertPriority.critical),
  185: VehicleCommand(CommandEffect.info, "Can't ride", 'Part mismatch', priority: AlertPriority.critical),
};

/// Ordinals HHMIS forwards that have no popup of their own here, logged as
/// known so they don't count as unknown. They neither clear the current
/// notice nor open one.
const knownUnmappedCommands = <int>{
  // Charge complete. The vehicle repeats it on every wake of a full,
  // plugged-in scooter (five in 26 s seen once); the charge status
  // already drives the one banner and the "Charged. Safe to unplug" line.
  111,
  // SIDE_STAND_OPEN: stock's held "Your parking stand is open"; ours is the
  // side-stand banner, raised from BOOL_SIDE_STAND_ICON_STATUS 27-60 ms
  // after each 60 in a ride log.
  60,
  // PRNTCNTRL_ACS_RESET: not in stock's `handleDerateEvents` switch; shows
  // nothing. Once per unlock, just before a 0.
  148,
};
