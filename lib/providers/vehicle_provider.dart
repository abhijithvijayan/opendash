import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../constants.dart';
import '../models/scooter_model.dart';
import '../models/vehicle_data.dart';
import '../models/connection_health.dart';
import '../services/analytics_logger.dart';
import '../services/log_privacy.dart';
import '../services/prefs_service.dart';
import '../state/passcode_state.dart';
import '../state/prompt_surface.dart';
import '../state/riding_lockout.dart';
import '../state/riding_settings.dart';
import '../state/scooter_capabilities.dart';
import '../state/settings_state.dart';
import '../state/sound_settings.dart';
import '../state/firmware_state.dart';
import '../state/sun_times.dart';
import '../state/cruise_watch.dart';
import '../state/toast_state.dart';
import 'hhmis_mapping.dart';
import 'media_bridge.dart';
import 'mock_provider.dart';
import 'stock_profile.dart';
import 'vehicle_commands.dart';
import 'vehicle_link.g.dart';
import '../services/trusted_clock.dart';
import '../services/ambient_health.dart';

/// What `_send` reports: whether HHMIS took the call, and if not, whether it
/// was bound but threw ([hhmisErrorCode]) rather than unreachable. [held]:
/// it was not sent because the scooter's software is not known yet
/// (`identifying`) or the rider has not allowed it (`unchecked`).
typedef _Sent = ({bool ok, bool rejected, String? held});

/// What [AidlVehicleNotifier._invoke] answers for a command it held.
class _Held {
  const _Held(this.why);
  final String why;
}

/// The error code `VehicleChannel.kt` answers with when HHMIS itself threw.
const hhmisErrorCode = 'hhmis_error';

/// The commands the dashboard sends, each by its stock `ClientCmd` name.
/// No number appears on this side: Kotlin looks the name up in the list of
/// the service installed on the scooter (`hhmis/StockContract.kt`), and
/// `scripts/check-head-unit-contract.py` reads this class to know which
/// names OpenDash needs. Values (what a command carries) are plain ints.
abstract final class HhmisCmd {
  static const blePairStat = 'BOOL_BLE_PAIR_STAT';
  static const esclLock = 'INT_ESCL_LOCK_CMD';
  static const sideStandStatus = 'INT_SIDE_STAND_STATUS';
  /// What stock HHMIC reports about the phone (`HMIServerConnectionSingle`
  /// `isBTCallingActive` / `isBtMediaPlaying` / `onBTCallStatus`); ordinals
  /// from HHMIS `parcelables/ClientCmd.smali`.
  static const btCallActiveStatus = 'INT_BT_CALL_ACTIVE_STATUS';
  static const btMediaPlaying = 'INT_BT_MEDIA_PLAYING';
  static const callStatus = 'CALL_STATUS';
  static const chargeLimit = 'INT_HC_SOC_LIMIT_SET';
  static const passcodeChange = 'STR_PROFILE_PASSCODE_CHANGE';
  static const unlockSeat = 'VOID_UNLOCK_SEAT';
  /// `VOID_RESET_TRIPO_METER_B` (ordinal 28). It zeroes
  /// `STR_VEHICLE_DISTANCE_COVERED_BY_ALL_USERS` (raw-value capture),
  /// which stock HHMIC binds to its second meter
  /// (`TripometerSecond`) and which is the one meter we show (`tripMeter`,
  /// see `hhmis_mapping.dart`). Stock's first meter, `Tripometer` ←
  /// `_BY_INDIVIDUAL_USER`, has its own reset; we neither show nor reset it.
  static const resetTrip = 'VOID_RESET_TRIPO_METER_B';
  static const highBeamOn = 'PARTY_MODE_HIGH_BEAM_ON';
  static const highBeamOff = 'PARTY_MODE_HIGH_BEAM_OFF';
  static const leftIndicatorOn = 'PARTY_MODE_LEFT_INDICATOR_ON';
  static const leftIndicatorOff = 'PARTY_MODE_LEFT_INDICATOR_OFF';
  static const rightIndicatorOn = 'PARTY_MODE_RIGHT_INDICATOR_ON';
  static const rightIndicatorOff = 'PARTY_MODE_RIGHT_INDICATOR_OFF';
  static const frontDrlOn = 'PARTY_MODE_FRONT_DRL_ON';
  static const frontDrlOff = 'PARTY_MODE_FRONT_DRL_OFF';
  static const regenSettingsUpdate = 'REGEN_SETTINGS_UPDATE';
  static const hazardToggle = 'HAZARD_LIGHT_TOGGLE';

  /// ALARM_SOUND_ALERT: 0 / 1 picks the alarm sound; HHMIS persists it and
  /// plays it as a preview until STOP_ALARM_SOUND.
  static const alarmSoundAlert = 'ALARM_SOUND_ALERT';

  /// SAFETY_DETECTION_SENSITIVITY: 0 Tow_Theft_Low_Sensitivity, 1 High.
  static const safetySensitivity = 'SAFETY_DETECTION_SENSITIVITY';
  static const stopAlarmSound = 'STOP_ALARM_SOUND';

  /// The accident screen's two answers and the alarm screen's Unlock; void
  /// commands, ordinals from HHMIS `ClientCmd.smali` (0x38, 0x39, 0x40).
  /// HHMIS forwards each once to the VCU as I_AM_SAFE, NEED_HELP and
  /// Alarm_unlock_Now (`IClientServiceInterfaceBuilder$1.onVoidHMICmd`).
  static const accidentIAmSafe = 'ACCIDENT_RECOVERY_IAM_SAFE';
  static const accidentNeedHelp = 'ACCIDENT_RECOVERY_NEED_HELP';
  static const alarmUnlockNow = 'ALARM_UNLOCK_NOW';
  static const hillHoldConditionAccepted = 'HILL_HOLD_CONDITION_ACCEPTED';

  static const esclLockValue = 0;
  static const esclUnlockValue = 1;

  /// CTA_IGNORE: stock HHMIC's answer the moment ESCL reports a failed
  /// lock or unlock; the VCU carries on without the steering lock.
  static const esclIgnoreValue = 2;
  static const playChime = 'INT_PLAY_CHIME';

  /// INT_PLAY_CHIME 1 = OLA_NOTIFICATION_NEGATIVE in HHMIS.
  static const chimeNegative = 1;
  static const hazardOn = 1;
  static const esclStatusLocked = 3;
  static const esclStatusLockFailed = 4;
  static const hazardOff = 0;
  static const vehicleStateLock = 0;
  static const vehicleStatePasscode = 2;
  static const vehicleStatePark = 3;
  static const touchStatus = 'BOOL_TOUCH_STATUS';

  /// BOOL_TRIGGER_SMART_LIGHT_ACTION, true at night. HHMIS persists
  /// INT_SMART_HEAD_LIGHT = 2 on every one, so stock always follows it with
  /// SMART_HEADLIGHT_TOGGLE (47) = 1, which puts the persisted state back.
  static const triggerSmartLight = 'BOOL_TRIGGER_SMART_LIGHT_ACTION';

  /// INT_MODE_UPDATE: stock `Constants.Moods` (0 Eclipse, 1 Vintage,
  /// 2 Bolt). HHMIS persists it and switches the engine sound and chime set.
  static const modeUpdate = 'INT_MODE_UPDATE';
  static const projectLoaded = 'PROJECT_LOADED';
  static const rebootOnFaultAck = 'VOID_REBOOT_ON_FAULT_ACK';

  /// AUTODOWNLOAD_UPDATE: the stock dashboard's auto-download setting, 1 on
  /// / 0 off. HHMIS only stores it in the rider's profile
  /// (`IClientServiceInterfaceBuilder$1.onIntegerHMICmd` ->
  /// `VehicleProfileManager.persistUserSettings`); HOTA never reads it.
  static const autoDownloadUpdate = 'AUTODOWNLOAD_UPDATE';

  /// VOID_CHECK_FOR_UPDATE: HHMIS asks HOTA whether an update is waiting
  /// (`OtaManager.isUpdateAvailable`). Sent only by the rider's "Check
  /// now", through its own channel method.
  static const checkForUpdate = 'VOID_CHECK_FOR_UPDATE';

  /// Never sent. Each acts on a firmware download or install in HOTA:
  /// 1 BOOL_INSTALL_ERROR_STAT, 20 VOID_CANCEL_DOWNLOAD,
  /// 22 VOID_CHECK_INSTALL_ERROR_STAT, 24 VOID_RETRY_DOWNLOAD
  /// The Kotlin channel refuses them too.
  static const neverSent = {'BOOL_INSTALL_ERROR_STAT', 'VOID_CANCEL_DOWNLOAD', 'VOID_CHECK_INSTALL_ERROR_STAT', 'VOID_RETRY_DOWNLOAD'};

  /// Whether [cmd] may go out through [method]. [checkForUpdate] has one
  /// way out, and it is not the generic void command.
  /// The channel methods that carry a `ClientCmd` number.
  static const numbered = {'sendIntCmd', 'sendVoidCmd', 'sendBoolCmd', 'sendStringCmd', 'checkFirmwareUpdate'};

  /// The versions of the stock service (`com.android.hmiserverapp`) whose
  /// command and event numbers match the tables here and in Kotlin
  /// (`scripts/check-head-unit-contract.py`). On any other, the numbered
  /// commands are held until the rider allows them.
  static const checkedServiceVersions = {'4.6.14'};

  static bool sendable(String method, String? cmd) =>
      cmd == null || (!neverSent.contains(cmd) && cmd != checkForUpdate);

  /// What the stock "Ride now" / "Lock now" popup buttons send
  /// (Ride_Now 0x53 / Lock_Now 0x54).
  static const sideStandRideNow = 0;
  static const sideStandLockNow = 1;

  /// Symbolic names for the analytics log.
  static const names = {
    projectLoaded: 'projectLoaded',
    rebootOnFaultAck: 'rebootOnFaultAck',
    autoDownloadUpdate: 'autoDownloadUpdate',
    blePairStat: 'blePairStat',
    triggerSmartLight: 'triggerSmartLight',
    modeUpdate: 'modeUpdate',
    esclLock: 'esclLock',
    sideStandStatus: 'sideStandStatus',
    btCallActiveStatus: 'btCallActiveStatus',
    btMediaPlaying: 'btMediaPlaying',
    callStatus: 'callStatus',
    chargeLimit: 'chargeLimit',
    passcodeChange: 'passcodeChange',
    unlockSeat: 'unlockSeat',
    resetTrip: 'resetTrip',
    highBeamOn: 'highBeamOn',
    highBeamOff: 'highBeamOff',
    leftIndicatorOn: 'leftIndicatorOn',
    leftIndicatorOff: 'leftIndicatorOff',
    rightIndicatorOn: 'rightIndicatorOn',
    rightIndicatorOff: 'rightIndicatorOff',
    frontDrlOn: 'frontDrlOn',
    frontDrlOff: 'frontDrlOff',
    regenSettingsUpdate: 'regenSettingsUpdate',
    hazardToggle: 'hazardToggle',
    alarmSoundAlert: 'alarmSoundAlert',
    safetySensitivity: 'safetySensitivity',
    stopAlarmSound: 'stopAlarmSound',
    accidentIAmSafe: 'accidentIAmSafe',
    accidentNeedHelp: 'accidentNeedHelp',
    alarmUnlockNow: 'alarmUnlockNow',
    hillHoldConditionAccepted: 'hillHoldConditionAccepted',
    'ADAPTIVE_POWERBOOST_TOGGLE': 'adaptivePowerBoost',
    'ACCIDENT_DETECTION_TOGGLE': 'fallDetection',
    'TOW_THEFT_TOGGLE': 'tamper',
    'PROXIMITY_TOGGLE': 'proximityUnlock',
    'HILL_HOLD_TOGGLE': 'hillHold',
    'SMART_HEADLIGHT_TOGGLE': 'smartHeadlight',
    'SMART_DRL_TOGGLE': 'smartDrl',
    'AUTO_HEADLIGHT_TOGGLE': 'autoHeadlight',
    'AUTO_INDICATOR_TURNOFF_TOGGLE': 'autoTurnOff',
    'MOTOR_CUTOFF_TOGGLE': 'motorCutOff',
    'VACATION_MODE_TOGGLE': 'vacationMode',
    'TAKE_ME_HOME_TOGGLE': 'takeMeHome',
    // SIDE_STAND_TOGGLE sideStandCutOff: polarity unknown (Q1), do not send.
    'PREDICT_RANGE_TOGGLE': 'predictedRange',
  };

  static const features = {
    RidingFeature.adaptivePowerBoost: 'ADAPTIVE_POWERBOOST_TOGGLE',
    RidingFeature.fallDetection: 'ACCIDENT_DETECTION_TOGGLE',
    RidingFeature.tamper: 'TOW_THEFT_TOGGLE',
    RidingFeature.proximityUnlock: 'PROXIMITY_TOGGLE',
    RidingFeature.hillHold: 'HILL_HOLD_TOGGLE',
    RidingFeature.smartHeadlight: 'SMART_HEADLIGHT_TOGGLE',
    RidingFeature.smartDrl: 'SMART_DRL_TOGGLE',
    RidingFeature.autoHeadlight: 'AUTO_HEADLIGHT_TOGGLE',
    RidingFeature.autoTurnOff: 'AUTO_INDICATOR_TURNOFF_TOGGLE',
    RidingFeature.motorCutOff: 'MOTOR_CUTOFF_TOGGLE',
    RidingFeature.vacationMode: 'VACATION_MODE_TOGGLE',
    RidingFeature.takeMeHome: 'TAKE_ME_HOME_TOGGLE',
    // sideStandCutOff: SIDE_STAND_TOGGLE polarity not settled; see Q1.
    RidingFeature.predictedRange: 'PREDICT_RANGE_TOGGLE',
  };
}

/// Whether the pack volts and amps in [v] are being delivered right now,
/// for the energy integrators: HHMIS is neither stale nor silent, or the
/// CAN stream is live. A frozen reading is not integrated. The mock is
/// always live.
bool packReadingsLive(VehicleNotifier n, VehicleData v) =>
    n is! AidlVehicleNotifier || n.canLive || !(v.hhmisStale || v.hhmisSilent);

/// Vehicle data from HHMIS over the Android bridge. Inherits the mock so
/// every command the UI calls exists; the ones HHMIS can carry are
/// overridden to send a ClientCmd and let the vehicle echo the result.
/// Reverse and drive mode selection have no HHMIS path and keep the mock's
/// local behaviour. Music and calls come from `MediaBridge.kt`, not HHMIS.
class AidlVehicleNotifier extends VehicleNotifier {
  /// HHMIS answers a new connection with vehicle state 0 (locked) and the
  /// real state about 0.6 s later: twice, when OpenDash was started on an
  /// unlocked scooter, the lock screen showed for that long before the
  /// dashboard. The start-up screen stays up for this long instead; a
  /// scooter that really is locked gets its keypad that much later, once.
  @override
  // TODO(first-lock-settle): 1 s covers the 0.6 s seen twice on one day. Check more starts on an
  // unlocked scooter (hhmis.bind_success to the first real INT_VEHICLE_STATE) before trusting the margin.
  Duration get firstLockSettle => const Duration(seconds: 1);

  /// [identity]: a scooter already identified, for a bridge that has no
  /// Kotlin side to say so (tests). The app itself waits for `_contract`.
  AidlVehicleNotifier({
    Stream<dynamic>? events,
    Future<Object?> Function(String method, Object? args)? invoke,
    StockIdentity? identity,
  })  : _events = events ?? MediaBridge.merge(_eventChannel.receiveBroadcastStream(), MediaBridge.events()),
        _rawInvoke = invoke ?? _channelInvoke {
    software.value = identity;
  }

  static const _eventChannel = EventChannel('in.abhijithvijayan.opendash.vehicle/events');
  static final _link = VehicleLinkApi();
  static const passcodeTimeout = Duration(seconds: 5);

  /// Stock HHMIC's WakeLockNotifier period for BOOL_TOUCH_STATUS.
  static const touchStatusEvery = Duration(seconds: 1);

  /// The vehicle locks a parked, unlocked scooter this long after the last
  /// touch it was told of. Not in any app's code: measured on a scooter
  /// (four idle locks, the handlebar lock engaging 63.4 to 63.7 s after the
  /// last `true`, and a `true` at 62.0 s that did not stop one).
  // TODO(idle-lock): measured on one scooter from four locks, not read from any code. safety.idle_lock_warning
  // (outcome locked / overdue) in every log says whether it still holds; measure it per scooter instead.
  static const idleLockAfter = Duration(seconds: 61);

  /// The warning shows for the last part of that.
  static const idleLockWarning = Duration(seconds: 15);

  /// How long "the stand is up, it will not lock" stays.
  static const standUpHintFor = Duration(seconds: 8);

  /// How long "Locking" may stand without the scooter locking before the
  /// guess is taken down as wrong.
  // TODO(idle-lock): chosen, not measured.
  static const idleLockOverdue = Duration(seconds: 15);
  static const smartLightEvery = Duration(minutes: 1);

  /// A usable light reading (0-100) below this is night while the clock
  /// is unknown; the auto theme's default dark threshold.
  static const smartLightNightAmbient = 25;

  static const trunkThrottle = Duration(seconds: 2);

  /// Wall clock for the day/night decision; tests pin it.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// HHMIS answers PROJECT_LOADED after 3 s with a PARK and then the saved
  /// state; a PARK in this window is held [projectLoadedEchoHold] to see if
  /// the real state follows.
  static const projectLoadedEchoFrom = Duration(seconds: 2);
  static const projectLoadedEchoUntil = Duration(seconds: 7);
  static const projectLoadedEchoHold = Duration(milliseconds: 400);
  /// Seen in a restart log: after a scooter reboot HHMIS's first state
  /// values flashed PASSCODE -> PARK -> PASSCODE in 300 ms, long enough to
  /// pop the dashboard behind the pin screen. A PARK that arrives right
  /// after the first PASSCODE of a session is held [coldBindParkHold]; if a
  /// non-PARK state follows, the PARK is dropped as a bind-time glitch.
  static const coldBindParkWindow = Duration(seconds: 2);
  static const coldBindParkHold = Duration(milliseconds: 500);

  /// HHMIS streams ~5 batches a second; this long without one when a
  /// passcode went unanswered means another client holds the slot.
  static const passcodeStaleness = Duration(seconds: 2);
  static const passcodeChangeTimeout = Duration(seconds: 3);
  static const passcodeRepeatWindow = Duration(seconds: 1);
  static const unknownKeysRollup = Duration(seconds: 30);

  /// Stock `SettingsInfoManager` ACTION_LOCKSCOOTER (the vacation popup's
  /// confirm): hazards off, then VACATION_MODE_TOGGLE = 1 after 200 ms.
  static const vacationSendDelay = Duration(milliseconds: 200);

  /// How long a lock waits for the "locked" echo (ESCL 3 or a vehicle
  /// state transition to LOCK / CHARGING-while-locking) before it counts
  /// as failed, and how long the failure stays on
  /// [VehicleData.lockFailedAtMicros]. A ride log showed the confirm
  /// arriving ~12 s after the send; 15 s leaves a margin without masking
  /// a genuinely dead lock for long.
  static const lockEchoTimeout = Duration(seconds: 15);
  static const lockFailedHold = Duration(seconds: 10);

  /// OpenDash's own debounce (stock raises no popup from the status
  /// callback; its 3 s `checkESCL{Lock,Unlock}FailedStatus` re-check is
  /// armed by the popup buttons and only re-sends CTA_IGNORE + a chime).
  /// The fail banner only fires if the ESCL still reports
  /// the same failure after the window. We use the same 3 s so transient
  /// ESCL=2/4 blips during the VCU retry burst (30 × 100 ms)
  /// don't scare the rider.
  @visibleForTesting
  static const esclFailDebounce = Duration(seconds: 3);
  @visibleForTesting
  static const esclStatusSna = 0;
  @visibleForTesting
  static const esclStatusUnlocked = 1;
  @visibleForTesting
  static const esclStatusUnlockFailed = 2;

  /// Foreground-only watchdog for a stolen HHMIS callback slot (HHMIC's
  /// addCallback overwrites ours). Awake HHMIS sends batches every
  /// 0.15-0.2 s, so 12 s of silence while resumed means the slot is gone.
  @visibleForTesting
  static const stalenessThreshold = Duration(seconds: 12);

  /// HHMIS streams many batches a second while we are in front (the longest
  /// foreground gap in two days of logs was under 2 s), so this long
  /// without one means the speed on screen is frozen. Reattach still waits
  /// for [stalenessThreshold].
  static const staleAfter = Duration(seconds: 3);
  static const staleCheckEvery = Duration(milliseconds: 500);

  /// HVDP `VehicleLockStateBCM.Vehicle_Locked`, read from CAN 0x144.
  @visibleForTesting
  static const bcmLocked = 3;
  @visibleForTesting
  static const stalenessCheckEvery = Duration(seconds: 3);

  /// Wait before each reattach attempt, from the previous one. Once used
  /// up, only real data (or a fresh bind) re-arms the watchdog, so a
  /// legitimately quiet HHMIS is not poked forever.
  @visibleForTesting
  static const reattachBackoffs = <Duration>[Duration.zero, Duration(seconds: 10), Duration(seconds: 30)];

  /// HHMIS answers every addCallback with its own forced LOCK
  /// (setStarTup) and the system volume (updateInitialSystemVolume). A
  /// batch of only those, this soon after a reattach, is that echo: it
  /// proves nothing about the vehicle and its LOCK is not the vehicle's.
  @visibleForTesting
  static const reattachEchoWindow = Duration(seconds: 1);
  static const _echoKeys = {'INT_VEHICLE_STATE', '_volume'};

  /// The drive-mode strings the stock services send (4.6.14 and 5.0.2
  /// `VehicleManager.setDriveMode`); anything else is a rider's own name.
  static const _stockDriveModes = {...MoveOs5Profile.stockDriveModes, customRideModeName};

  /// Keys whose raw transitions are logged one by one; the rest only show
  /// up in the per-batch key list.
  static const _transitionEvents = {
    'INT_VEHICLE_STATE': 'state_change',
    'INT_VEHICLE_ESCL_STATUS': 'escl_change',
    'INT_CHARGE_STATUS': 'charge_state_change',
    'BOOL_HIGH_BEAM_STATUS': 'high_beam_raw',
    'INT_CHARGE_MODE': 'charge_mode',
    'INT_BOOST_HYPER_CHARGE_STATUS': 'hyper_charge_status',
    'INT_HILL_HOLD_STATUS': 'hill_hold',
    'INT_VEHICLE_TRUNK_STATUS': 'trunk_status',
    // MoveOS 5: which value is reverse in park assist is not known yet.
    'INT_VEHICLE_DIRECTION': 'direction_change',
    // MoveOS 5: the phone app connected over BLE (1), and what else.
    'INT_BLE_CAPP_STATUS': 'ble_capp_status',
    // false makes the dashboard ignore touches (stock does the same before
    // the 12 V cut); suspected once in a slow passcode entry.
    'BOOL_HEAD_UNIT_POWER_FLAG': 'head_unit_power',
    // Minutes remaining; the charging screen shows the clock time ("3:45 PM, 80% at").
    'INT_BATTERY_TIME_TO_FULL_CHARGE_UPDATE': 'charge_minutes_full',
    'INT_BATTERY_OPTIMUM_CHARGE_TIME': 'charge_minutes_80',
    'INT_FC_BATTERY_TIME_TO_FULL_CHARGE_UPDATE': 'fc_minutes_full',
    'INT_FC_BATTERY_OPTIMUM_CHARGE_UPDATE': 'fc_minutes_80',
    // Bluetooth connection changes, with the
    // source (`via`) SystemStatus.kt took them from. A ride log
    // settled the roles: A2DP sink, AVRCP controller, HFP client.
    '_bt': 'bt_change',
    // Seven installs once timed out on the road and the log could
    // not say whether Wi-Fi was up or what the mobile signal was.
    '_wifi': 'wifi_change',
    '_signal': 'signal_change',
    // Capture raw indicator transitions so a ride with working
    // switches can settle whether BOOL_*_INDICATOR_STATUS follows the
    // handlebar steady-on (= animate locally) or the blink itself (=
    // render as received). The handlebar switches on the test scooter are
    // broken, so these never fire there; the log stays empty.
    'BOOL_LEFT_INDICATOR_STATUS': 'left_indicator_raw',
    'BOOL_RIGHT_INDICATOR_STATUS': 'right_indicator_raw',
  };

  /// The way out to Kotlin. The class speaks in a method name and its
  /// arguments (which is what tests stand in for); here that becomes a call
  /// on the generated [VehicleLinkApi] (`pigeons/vehicle_link.dart`), so the
  /// two sides cannot disagree on a method or the type of an argument.
  static Future<Object?> _channelInvoke(String method, Object? args) {
    if (MediaBridge.methods.contains(method)) return MediaBridge.invoke(method, args);
    final a = args is Map ? args : const <Object?, Object?>{};
    return switch (method) {
      'sendVoidCmd' => _link.sendVoid(a['cmd']! as String),
      'sendBoolCmd' => _link.sendBool(a['cmd']! as String, a['value']! as bool),
      'sendIntCmd' => _link.sendInt(a['cmd']! as String, a['value']! as int),
      'sendStringCmd' => _link.sendString(a['cmd']! as String, a['value']! as String),
      'checkFirmwareUpdate' => _link.checkFirmwareUpdate(),
      'subscribeFirmware' => _link.subscribeFirmware(),
      'setBrightness' => _link.setBrightness(a['value']! as int, a['persist'] as bool? ?? true),
      'setVolume' => _link.setVolume(args! as int),
      'setMotorVolume' => _link.setMotorVolume(args! as int),
      'setChimeVolume' => _link.setChimeVolume(args! as int),
      'verifyPasscode' => _link.verifyPasscode(a['code']! as String, a['verifyOnly'] as bool? ?? false),
      'mediaKey' => _link.mediaKey(args! as String),
      'btSnapshot' => _link.btSnapshot(args as String? ?? ''),
      'reattachCallback' => _link.reattachCallback(),
      _ => throw MissingPluginException('no vehicle link method $method'),
    };
  }

  /// Every method [_channelInvoke] carries, for the test that no caller
  /// uses one it does not.
  @visibleForTesting
  static const linkMethods = {
    'sendVoidCmd', 'sendBoolCmd', 'sendIntCmd', 'sendStringCmd', 'checkFirmwareUpdate', 'subscribeFirmware',
    'setBrightness', 'setVolume', 'setMotorVolume', 'setChimeVolume', 'verifyPasscode', 'mediaKey', 'btSnapshot',
    'reattachCallback',
  };

  final Stream<dynamic> _events;
  final Future<Object?> Function(String method, Object? args) _rawInvoke;

  /// What this scooter has, for the senders in this class. Screens read
  /// `scooterCapabilitiesProvider`, which this class cannot (it would be
  /// reading a provider that watches it).
  ScooterCapabilities get capabilities =>
      ScooterCapabilities(software: software.value, available: state.featureAvailable, vehicleType: state.vehicleType);

  /// How the scooter's software says things; every difference between
  /// generations is applied through it (`stock_profile.dart`).
  StockProfile get profile => StockProfile.of(software.value);

  bool _commandsHeld = false;
  bool _uncheckedDismissed = false;
  int _heldLogged = 0;

  /// `hhmis.profile_rewrite`: what a [StockProfile] changed in a batch, so a
  /// log from that software shows the value as it was sent. The first 10
  /// per key; every accident it raises.
  final Map<Object?, int> _rewritesLogged = {};
  void _logRewrites(StockProfile p, Map<Object?, Object?> before, Map<Object?, Object?> after) {
    Object? shown(Object? v) => v is String ? 'string(${v.length})' : v;
    for (final MapEntry(:key, value: to) in after.entries) {
      final from = before[key];
      if (before.containsKey(key) && from == to) continue;
      final n = _rewritesLogged[key] ?? 0;
      if (n >= 10 && !(key == 'BOOL_ACCIDENT_SEVERITY_STAT' && to == true)) continue;
      _rewritesLogged[key] = n + 1;
      logEvent('hhmis', 'profile_rewrite', {
        'profile': p.name,
        'key': key,
        'from': before.containsKey(key) ? shown(from) : null,
        'to': shown(to),
        if (key == 'BOOL_ACCIDENT_SEVERITY_STAT') 'command': before['INT_VEHICLE_COMMAND'],
      });
    }
  }

  /// The one way out to the Kotlin channel. A numbered command (one that
  /// goes by its place in a stock list) waits here while the scooter's
  /// software is not known yet, and, on a build OpenDash has not been
  /// ridden on, until the rider has allowed it (`UncheckedScooterDialog`).
  /// One the scooter's software does not have is not sent at all. The
  /// passcode, volume and brightness calls are not numbered and still go.
  Future<Object?> _invoke(String method, Object? args) {
    if (!HhmisCmd.numbered.contains(method)) return _rawInvoke(method, args);
    final cmd = method == 'checkFirmwareUpdate' ? HhmisCmd.checkForUpdate : (args is Map ? args['cmd'] : null);
    final identity = software.value;
    final why = identity == null ? 'identifying' : _commandsHeld ? 'unchecked' : null;
    if (why != null) {
      if (_heldLogged++ < 20) logEvent('hhmis', 'cmd_held', {'method': method, 'cmd': cmd, 'why': why});
      return Future.value(_Held(why));
    }
    if (cmd is String && !identity!.commands.contains(cmd)) {
      logEvent('hhmis', 'cmd_no_number', {'cmd': cmd, 'name': HhmisCmd.names[cmd], 'software': identity.version});
      return Future.value(false);
    }
    return _rawInvoke(method, args);
  }

  /// Compares the scooter's software and its model number with what
  /// OpenDash has been ridden on, less what the rider has allowed.
  // TODO(unchecked-scooter): never run on a scooter where it fires (the test scooter is 4.6.14, model number not
  // sent in 70 min). The dialog, the hold and "Use OpenDash here" are proven by tests only.
  void _checkScooter(int? vehicleType) {
    final allowed = PrefsService.getString(PrefsKeys.uncheckedAllowed, '').split('|').toSet();
    final identity = software.value;
    final service = identity?.version;
    final newService = identity != null && !identity.checked && !allowed.contains(identity.key);
    final newType = vehicleType != null && ScooterModel.nameFor(vehicleType) == null && !allowed.contains('type:$vehicleType');
    if (newService != _commandsHeld) {
      logEvent('hhmis', newService ? 'contract_unchecked' : 'contract_ok', {'service': service});
    }
    _commandsHeld = newService;
    final next = newService || newType
        ? UncheckedScooter(
            serviceVersion: newService ? service : null,
            vehicleType: newType ? vehicleType : null,
            source: newService ? identity.source : '',
            known: newService ? identity.name : '',
          )
        : null;
    if (next != null && next != unchecked.value) {
      logEvent('vehicle', 'unchecked_scooter', {'service': next.serviceVersion, 'type': next.vehicleType});
    }
    unchecked.value = _uncheckedDismissed ? null : next;
  }

  @override
  void allowUnchecked() {
    final u = unchecked.value;
    if (u == null) return;
    final allowed = PrefsService.getString(PrefsKeys.uncheckedAllowed, '').split('|').where((e) => e.isNotEmpty).toSet();
    if (u.serviceVersion != null) allowed.add(software.value!.key);
    if (u.vehicleType != null) allowed.add('type:${u.vehicleType}');
    PrefsService.setString(PrefsKeys.uncheckedAllowed, allowed.join('|'));
    logEvent('vehicle', 'unchecked_allowed', {'service': u.serviceVersion, 'type': u.vehicleType});
    _commandsHeld = false;
    unchecked.value = null;
  }

  @override
  void dismissUnchecked() {
    logEvent('vehicle', 'unchecked_dismissed', {'held': _commandsHeld});
    _uncheckedDismissed = true;
    unchecked.value = null;
  }
  final _power = HhmisPower();
  StreamSubscription<dynamic>? _sub;
  Completer<(bool, int)>? _pendingPasscode;
  Timer? _passcodeTimer;
  int? _passcodeSentMicros;
  (bool, Object?, int)? _lastPasscodeResult;
  Completer<bool?>? _pendingPasscodeChange;
  Timer? _passcodeChangeTimer;
  Timer? _unknownTimer;
  Timer? _lockTimer;
  Timer? _lockFailedTimer;
  Timer? _esclLockFailDebounce;
  Timer? _esclUnlockFailDebounce;
  Timer? _lockRecheck;
  Timer? _noticeTimer;
  Timer? _chargeLimitTimer;
  Timer? _touchTimer;
  Timer? _smartLightTimer;
  bool _silentLogged = false;
  bool _smartHeadlightOn = false;
  bool _smartHeadlightPaused = false;
  // TODO(smart-headlight-stale): seen working twice in one day (hhmis.smart_light_stale_off at the unlock
  // after a pause, the beam back on by itself within half a minute). Not yet seen: a pause ended by long-press.
  bool _smartOffIsOurs = false;

  void _setSmartOffIsOurs(bool on) {
    if (_smartOffIsOurs == on) return;
    _smartOffIsOurs = on;
    on ? PrefsService.setBool(PrefsKeys.smartHeadlightOffIsOurs, true) : PrefsService.remove(PrefsKeys.smartHeadlightOffIsOurs);
  }
  bool? _lastSmartLightNight;
  Timer? _staleTimer;
  int _reattachTotal = 0;
  String? _lastCmdName;
  bool? _lastCmdOk;
  int? _lastCmdMs;
  int? _lastVehicleCommand;
  int? _lastPopupId;
  bool _touched = false;
  final Map<String, num> _tripRaw = {};
  /// The first batch after a cold bind
  /// can carry `BOOL_HEAD_UNIT_POWER_FLAG = false`; stock HHMIC ignores
  /// that initial false, otherwise the pin pad goes dead.
  bool _sawHeadUnitPowerTrue = false;
  bool? _lastTouchSent;
  bool _projectLoadedSent = false;
  int? _projectLoadedAtMicros;
  Timer? _parkEchoTimer;
  /// BLE pairing prompt auto-declines after
  /// 30 s on screen, or when the rider moves off / changes state.
  Timer? _blePairTimer;
  static const blePairTimeout = Duration(seconds: 30);
  Timer? _coldBindParkTimer;
  Timer? _stalenessTimer;
  bool _resumed = true;
  int? _lastHhmisMicros;
  int? _resumedAtMicros;
  int? _lastVehicleStateMicros;
  int? _firstPasscodeAtMicros;
  int _reattachAttempts = 0;
  int? _nextReattachAfter;
  int? _reattachSentMicros;
  int _attempts = VehicleNotifier.maxPasscodeAttempts;
  int _seq = 0;
  final Map<String, Object?> _lastRaw = {};
  final Set<String> _unknownKeys = {};
  String? _customRideSaved;
  int? _connectedAtMicros;
  bool _everConnected = false;
  bool _highBeamOverride = false;
  int _volumeSteps = defaultVolumeSteps;
  int? _volumeIndex;
  int? _volumeSentIndex;
  bool _mediaLive = false;
  CallPhase _callPhase = CallPhase.none;
  int? _callId;

  @override
  VehicleData build() {
    startClock();
    ref.onDispose(() {
      _sub?.cancel();
      _passcodeTimer?.cancel();
      _passcodeChangeTimer?.cancel();
      _unknownTimer?.cancel();
      _lockTimer?.cancel();
      _lockFailedTimer?.cancel();
      _esclLockFailDebounce?.cancel();
      _esclUnlockFailDebounce?.cancel();
      _lockRecheck?.cancel();
      _positionLightCheck?.cancel();
      _noticeTimer?.cancel();
      _noticeMinTimer?.cancel();
      _chargeLimitTimer?.cancel();
      _touchTimer?.cancel();
      _smartLightTimer?.cancel();
      _staleTimer?.cancel();
      _parkEchoTimer?.cancel();
      _blePairTimer?.cancel();
      _vacationTimer?.cancel();
    _coldBindParkTimer?.cancel();
      _stalenessTimer?.cancel();
    });
    _sub = _events.listen((Object? event) {
      _inbound.start();
      _partFrom = _inbound.elapsedMicroseconds;
      try {
        onEvent(event);
      } finally {
        _part(7);
        _inbound.stop();
      }
    }, onError: (Object e) {
      debugPrint('[AIDL] event error: $e');
      if (_everConnected) {
        logEvent('hhmis', 'unbind', {'reason': 'event error: $e', 'up_for_s': _upForSeconds()});
      } else {
        logEvent('hhmis', 'bind_refused', {'error': e.toString()});
      }
    });
    _unknownTimer = Timer.periodic(unknownKeysRollup, (_) => _rollupUnknownKeys());
    _touchTimer = Timer.periodic(touchStatusEvery, (_) => _sendTouchStatus());
    _smartLightTimer = Timer.periodic(smartLightEvery, (_) => _triggerSmartLight('tick'));
    _staleTimer = Timer.periodic(staleCheckEvery, (_) => _checkStale());
    _startStalenessTimer();
    // A pause that outlived the process (the vehicle still has "off"): the
    // setting is on, and the next park or lock resumes it.
    _smartHeadlightPaused = PrefsService.getBool(PrefsKeys.smartHeadlightPaused, false);
    _smartOffIsOurs = PrefsService.getBool(PrefsKeys.smartHeadlightOffIsOurs, false);
    if (_smartHeadlightPaused || _smartOffIsOurs) _smartHeadlightOn = true;
    final knownFeatures = _savedFeatureAvailability();
    if (knownFeatures.isNotEmpty) logEvent('hhmis', 'feature_available_seed', {'features': knownFeatures});
    final savedCustom = CustomRideMode.decodeConfig(PrefsService.getString(PrefsKeys.customRide, ''));
    _customRideSaved = savedCustom.encodeConfig();
    return VehicleData(
      featureAvailable: knownFeatures,
      customRide: savedCustom,
      smartHeadlight: _smartHeadlightPaused ? SmartHeadlight.paused : SmartHeadlight.off,
      time: now(),
      hhmisBacked: true,
      lockState: 4,
      socSeen: false,
      rangeSeen: false,
      motorTempSeen: false,
      batteryTempSeen: false,
      ambientKnown: false,
      ambientUsable: _ambientHealth.verdict == AmbientVerdict.usable,
      signalBars: 0,
      wifiConnected: false,
      gpsFix: false,
      scooterBtName: '',
      moveOsVersion: '',
      vswVersion: '',
      vdpVersion: '',
      hmiVersion: appVersion,
      bcmVersion: '',
      bmsVersion: '',
      mcuVersion: '',
      hbcVersion: '',
      huVersion: '',
      bleVersion: '',
      vin: '',
      iccid: '',
      wifiMac: '',
      ipAddress: '',
      btMac: '',
      peaks: peaks,
      volume: PrefsService.getInt(PrefsKeys.volume, 50),
      chargeLimit: PrefsService.getInt(PrefsKeys.chargeLimit, 100).clamp(50, 100),
    );
  }

  /// The BOOL `*_FEATURE_AVAILABLE` keys come from one CAN frame that HVDP
  /// hands to HHMIS, and HHMIS forwards each to whoever holds its callback
  /// slot at that moment; once a value is false it never forwards that key
  /// again (`VPServerConnection$9.is*FeatureAvailable`), and PROJECT_LOADED
  /// replays only the three INT ones (`pumpUIDate`). A session that starts
  /// after that has no other way to learn them (once, none of the
  /// nine arrived), so the last report is kept. The vehicle's word wins.
  static Map<String, bool> _savedFeatureAvailability() {
    final raw = PrefsService.getString(PrefsKeys.featureAvailable, '');
    if (raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return {
        for (final MapEntry(:key, :value) in decoded.entries)
          if (key is String && value is bool) key: value,
      };
    } on FormatException {
      return const {};
    }
  }

  /// HHMIS's answer to each feature toggle (`onIntegerHMICmd`): true once
  /// the command was handed to HVDP, for an off as much as an on. Smart
  /// headlight is left out: its 47 is re-sent every minute.
  static const featureAcks = {
    'BOOL_APB_TOGGLE_STAT': RidingFeature.adaptivePowerBoost,
    'BOOL_ACCIDENT_DETECTION_TOGGLE_STAT': RidingFeature.fallDetection,
    'BOOL_TOW_THEFT_TOGGLE_STAT': RidingFeature.tamper,
    'BOOL_PROXIMITY_TOGGLE_STAT': RidingFeature.proximityUnlock,
    'BOOL_HILL_HOLD_TOGGLE_STAT': RidingFeature.hillHold,
    'BOOL_SMART_DRL_TOGGLE_STAT': RidingFeature.smartDrl,
    'BOOL_AUTO_HEADLIGHT_TOGGLE_STAT': RidingFeature.autoHeadlight,
    'BOOL_AUTO_INDICATOR_TURNOFF_TOGGLE_STAT': RidingFeature.autoTurnOff,
    'BOOL_MOTOR_CUTOFF_TOGGLE_STAT': RidingFeature.motorCutOff,
    'BOOL_TAKE_ME_HOME_TOGGLE_STAT': RidingFeature.takeMeHome,
  };

  @override
  bool acksFeature(RidingFeature feature) => featureAcks.containsValue(feature);

  /// One coalesced batch from the bridge. Public so tests can feed it.
  void onEvent(dynamic event) {
    if (event is! Map) return;
    final delta = Map<Object?, Object?>.from(event);
    // A firmware update callback. Taken out before anything else sees the
    // batch: it carries release notes, which are shown and never logged.
    final firmware = delta.remove('_fw');
    if (firmware is Map) onFirmwareNotice?.call(firmware);
    if (firmware != null && delta.isEmpty) return;
    if (delta.isNotEmpty && delta.keys.every(MediaBridge.keys.contains)) {
      _onMediaBridge(delta);
      return;
    }
    // Who the scooter is: Kotlin says so once, before it binds, and again
    // to every new listener. Taken out here: it is a list of names, not a
    // value from the scooter.
    final contract = delta.remove('_contract');
    if (contract is Map) {
      final identity = StockIdentity.fromEvent(contract);
      if (identity.digest != software.value?.digest || identity.version != software.value?.version) {
        logEvent('hhmis', 'contract', {
          'service': identity.version,
          'source': identity.source,
          'name': identity.name,
          'profile': StockProfile.of(identity).name,
          'checked': identity.checked,
          'digest': identity.digest,
          'commands': identity.commands.length,
        });
      }
      software.value = identity;
      _checkScooter(state.vehicleType);
      if (delta.isEmpty) return;
    }
    _part(0);
    survey.note(delta);
    rawBatch?.call(delta);
    _part(1);
    // From here on everything reads what 4.6.14 sends.
    final p = profile;
    final before = p is MoveOs5Profile ? Map<Object?, Object?>.of(delta) : null;
    p.normalise(delta);
    if (before != null) _logRewrites(p, before, delta);
    _part(2);
    final regenFlag = delta['BOOL_VEHICLE_REGEN_AVAIL_STATUS'];
    if (regenFlag is bool) _hhmisRegenFlag = regenFlag;
    if (_canOwnsRegen) delta.remove('BOOL_VEHICLE_REGEN_AVAIL_STATUS');
    // Our own 47 = 0 is in the profile until the resume: a profile replay
    // in between must not switch the rider's setting off.
    //
    // Nor after it. The pause ends at the lock, where nothing may be sent,
    // so the profile still holds our 0 at the next unlock and replays it
    // just after the 47 = 1 that resumes. On a night ride that
    // replay switched the setting off on screen while the vehicle had it on
    // and was holding the high beam: thirteen taps on the beam button sent
    // a plain "off" that the vehicle ignores in that state. An "off" that
    // is ours is not news; the vehicle's "on" ends the matter.
    final smartStored = delta['INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT'];
    if (smartStored != null) {
      if (_smartHeadlightPaused) {
        delta.remove('INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT');
      } else if (_smartOffIsOurs) {
        if (smartStored == 1) {
          _setSmartOffIsOurs(false);
        } else {
          logEvent('hhmis', 'smart_light_stale_off', {'value': smartStored});
          delta.remove('INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT');
        }
      }
    }
    final echo = _isReattachEcho(delta);
    if (echo) {
      logEvent('hhmis', 'reattach_echo', {'keys': delta.keys.whereType<String>().toList()});
      delta.remove('INT_VEHICLE_STATE');
    }
    if (_parkEchoTimer != null && delta.containsKey('INT_VEHICLE_STATE')) {
      _parkEchoTimer!.cancel();
      _parkEchoTimer = null;
      logEvent('hhmis', 'project_loaded_echo', {'then': delta['INT_VEHICLE_STATE']});
    }
    if (_isProjectLoadedPark(delta)) {
      _projectLoadedAtMicros = null;
      delta.remove('INT_VEHICLE_STATE');
      _parkEchoTimer = Timer(projectLoadedEchoHold, () {
        _parkEchoTimer = null;
        onEvent({'INT_VEHICLE_STATE': HhmisCmd.vehicleStatePark});
      });
    }
    // Track the first PASSCODE of a session so we can hold a transient PARK
    // that follows it within [coldBindParkWindow].
    final rawState = delta['INT_VEHICLE_STATE'];
    if (rawState == HhmisCmd.vehicleStatePasscode && _firstPasscodeAtMicros == null) {
      _firstPasscodeAtMicros = AnalyticsLogger.instance.monoMicros;
    }
    final firstPasscode = _firstPasscodeAtMicros;
    final inColdBindWindow = firstPasscode != null &&
        (AnalyticsLogger.instance.monoMicros - firstPasscode) < coldBindParkWindow.inMicroseconds;
    if (_coldBindParkTimer != null && rawState != null && rawState != HhmisCmd.vehicleStatePark) {
      _coldBindParkTimer!.cancel();
      _coldBindParkTimer = null;
      logEvent('hhmis', 'cold_bind_park_dropped', {'then': rawState});
    }
    if (rawState == HhmisCmd.vehicleStatePark &&
        _lastRaw['INT_VEHICLE_STATE'] == HhmisCmd.vehicleStatePasscode &&
        inColdBindWindow &&
        _coldBindParkTimer == null) {
      delta.remove('INT_VEHICLE_STATE');
      _coldBindParkTimer = Timer(coldBindParkHold, () {
        _coldBindParkTimer = null;
        // Closes the cold-bind window so the re-posted PARK is applied by
        // onEvent instead of looping back into this guard.
        _firstPasscodeAtMicros = null;
        onEvent({'INT_VEHICLE_STATE': HhmisCmd.vehicleStatePark});
      });
    }
    _safetyOneShots(delta);
    // Capture _lastRaw snapshots BEFORE _logBatch mutates them, so
    // transition-aware checks downstream (ESCL debounce) see the real
    // previous value instead of the just-written new one.
    final prevEscl = _lastRaw['INT_VEHICLE_ESCL_STATUS'];
    final prevHillHold = _lastRaw['INT_HILL_HOLD_STATUS'];
    final prevTrunk = _lastRaw['INT_VEHICLE_TRUNK_STATUS'];
    final prevRawState = _lastRaw['INT_VEHICLE_STATE'];
    final prevHeadUnitPower = _lastRaw['BOOL_HEAD_UNIT_POWER_FLAG'];
    _logBatch(delta, live: !echo);
    if (delta.containsKey('INT_VEHICLE_STATE')) _lastVehicleStateMicros = AnalyticsLogger.instance.monoMicros;
    // The two trip counters, raw (metres): the first value of each in this
    // process, and any step back, which is a reset. Every value used to be
    // logged, to find which counter ClientCmd 28 zeroes (the "all users"
    // one); with that settled it was 17,064 of the 35,676 lines of one
    // evening's rides.
    for (final (key, name) in const [
      ('STR_VEHICLE_DISTANCE_COVERED_BY_INDIVIDUAL_USER', 'individual'),
      ('STR_VEHICLE_DISTANCE_COVERED_BY_ALL_USERS', 'all'),
    ]) {
      final raw = delta[key];
      if (raw == null) continue;
      final metres = num.tryParse('$raw');
      final before = _tripRaw[name];
      if (before == null || metres == null || metres < before) {
        logEvent('safety', 'trip_value', {'key': name, 'raw': raw, 'from': ?before});
      }
      if (metres != null) _tripRaw[name] = metres;
    }
    final volumeIndex = delta['_volume'];
    if (volumeIndex is int) delta['_volume'] = _volumeFromIndex(volumeIndex);
    _part(3);
    var next = applyHhmisUpdate(state, delta, power: _power, onUnknown: (k) => _noteUnknown(k, delta[k]));
    _part(4);
    // A free handlebar is not an unlocked scooter. After one cold boot
    // ESCL arrived as 1 with the vehicle in PASSCODE and the
    // dashboard showed for 129 ms, until the next state event; with no
    // such event it would have stayed. The vehicle state owns the lock
    // while it says LOCK, ALARM or PASSCODE.
    if (delta['INT_VEHICLE_ESCL_STATUS'] == esclStatusUnlocked &&
        const {0, 1, 2}.contains(rawState ?? prevRawState) &&
        state.locked &&
        !next.locked &&
        delta['_unlocked'] != true) {
      logEvent('hhmis', 'escl_unlock_ignored', {'state': rawState ?? prevRawState});
      next = next.copyWith(lockState: 4);
    }
    if (!next.socSeen && delta['INT_BATTERY_SOC'] is num) next = next.copyWith(socSeen: true);
    if (!next.rangeSeen && delta['INT_VEHICLE_RANGE'] is num) next = next.copyWith(rangeSeen: true);
    if (!next.motorTempSeen && delta['FLOAT_MOTOR_TEMPERATURE'] is num) next = next.copyWith(motorTempSeen: true);
    if (!next.batteryTempSeen && delta['FLOAT_BATTERY_EFF_TEMP'] is num) next = next.copyWith(batteryTempSeen: true);
    if (!identical(next.featureAvailable, state.featureAvailable)) {
      _logFeatureAvailability(delta);
      PrefsService.setString(PrefsKeys.featureAvailable, jsonEncode(next.featureAvailable));
    }
    // Keep the custom mode's settled config so its ladder row and By-mode
    // bar are there from the next boot; the live figures do not trigger a
    // write (encodeConfig leaves them out).
    final customCfg = next.customRide.encodeConfig();
    if (customCfg != _customRideSaved) {
      _customRideSaved = customCfg;
      PrefsService.setString(PrefsKeys.customRide, customCfg);
    }
    final connected = delta['_connected'];
    if (connected is bool) next = next.copyWith(hhmisConnected: connected);
    if (delta.containsKey('INT_PROFILE_VEHICLE_TYPE')) _checkScooter(next.vehicleType);
    final moveOs = delta['_moveOs'];
    if (moveOs is String) onFirmwareVersion?.call(FirmwareNotifier.moveOsKey, moveOs);
    if (delta['_vdpMissing'] == true) next = next.copyWith(hhmisConnected: false);
    // Data implies connected, unless the same batch says it is not.
    if (connected != false && delta.keys.any((k) => k is String && !k.startsWith('_'))) {
      next = next.copyWith(hhmisConnected: true);
    }
    if (delta['_unlocked'] == true) next = next.copyWith(lockState: 0);
    // Handle a BLE pairing prompt.
    // STR_PROXIMITY_BLE_PASSCODE arriving outside PARK or CHARGING at
    // standstill: refuse at once. Inside a valid state: arm a 30 s
    // auto-decline so the prompt doesn't sit there forever.
    if (delta.containsKey('STR_PROXIMITY_BLE_PASSCODE')) {
      final code = next.btPairingCode;
      if (code.isNotEmpty) {
        final okState = (next.vehicleState == VehicleState.parked ||
                next.vehicleState == VehicleState.charging) &&
            next.speed == 0 &&
            !next.speedRpmMismatch;
        if (!okState) {
          _blePairTimer?.cancel();
          _blePairTimer = null;
          next = next.copyWith(btPairingCode: '');
          logEvent('hhmis', 'ble_pair_auto_declined', {'reason': 'invalid_state', 'state': next.vehicleState.name});
          _bool(HhmisCmd.blePairStat, false);
        } else {
          _blePairTimer?.cancel();
          _blePairTimer = Timer(blePairTimeout, () {
            if (state.btPairingCode.isEmpty) return;
            logEvent('hhmis', 'ble_pair_auto_declined', {'reason': 'timeout'});
            state = state.copyWith(btPairingCode: '');
            _bool(HhmisCmd.blePairStat, false);
          });
        }
      }
    }
    // Any ack closes the prompt (no explicit field; a raw BOOL event is enough).
    if (delta['BOOL_PROXIMITY_PAIRING_ACK'] == true && next.btPairingCode.isNotEmpty) {
      _blePairTimer?.cancel();
      _blePairTimer = null;
      next = next.copyWith(btPairingCode: '');
      logEvent('hhmis', 'ble_pair_ack', {});
    }
    // Riding away or changing to a state that isn't PARK/CHARGING cancels
    // an outstanding prompt and tells the VCU no.
    if (next.btPairingCode.isNotEmpty && _blePairTimer != null) {
      final movedOff = next.speed > 1 || next.speedRpmMismatch;
      final badState = next.vehicleState != VehicleState.parked &&
          next.vehicleState != VehicleState.charging;
      if (movedOff || badState) {
        _blePairTimer?.cancel();
        _blePairTimer = null;
        next = next.copyWith(btPairingCode: '');
        logEvent('hhmis', 'ble_pair_auto_declined', {'reason': movedOff ? 'speed' : 'state_change'});
        _bool(HhmisCmd.blePairStat, false);
      }
    }
    // The head-unit-power flag was
    // disabling touch on every batch even without a change, and the very
    // first value after a bind can be false (then quickly true). Only
    // react on an actual change AND only after we've seen a true at
    // least once - otherwise the pin pad is dead from the start. On the
    // true -> false edge, also clear any typed passcode digits.
    final rawHeadUnitPower = delta['BOOL_HEAD_UNIT_POWER_FLAG'];
    if (rawHeadUnitPower is bool) {
      if (rawHeadUnitPower) {
        _sawHeadUnitPowerTrue = true;
      } else if (!_sawHeadUnitPowerTrue) {
        // First-ever false before any true: keep touch enabled.
        next = next.copyWith(touchDisabled: false);
      }
      // Stock `UserProfileManager.setHeadUnitPowerFlag` blanks a
      // half-typed passcode when the screen goes off. Done on the raw
      // edge: `touchDisabled` is cancelled just below whenever the scooter
      // is parked, which is always at the lock screen, so a listener on it
      // never fired (once, two digits were still there after the
      // screen timed out, and the next attempt failed).
      if (!rawHeadUnitPower && prevHeadUnitPower == true) ref.read(screenOffProvider.notifier).mark();
    }
    // TODO(touch-gate): a precaution against a stuck false that was suspected once and never shown.
    // ui.touch_blocked while parked in a log would prove the stuck case; none has.
    // Clear touchDisabled whenever the scooter parks or the speed is low:
    // the stock gate only matters at road speed. Belt-and-braces against
    // a stale false that never recovered to true.
    if (next.touchDisabled &&
        (next.vehicleState == VehicleState.parked || next.speed <= 1)) {
      next = next.copyWith(touchDisabled: false);
    }
    for (final MapEntry(:key, :value) in delta.entries) {
      if (key is! String || !key.startsWith(_hwInfoPrefix) || value is! String || value.isEmpty) continue;
      final id = int.tryParse(key.substring(_hwInfoPrefix.length));
      if (id != null) {
        next = _applyHardwareInfo(next, id, value);
        if (FirmwareNotifier.versionIds.contains(id)) onFirmwareVersion?.call('$id', value);
      }
    }
    final escl = delta['INT_VEHICLE_ESCL_STATUS'];
    // A pending lock also resolves when HHMIS reports
    // LOCK (0), or CHARGING (6) once the lock state says locked. ESCL = 3
    // is still the primary; this is for the case where the ESCL stays at 4
    // (handlebar free) but the vehicle itself transitioned.
    // A bare 6 must not count: on the charger HHMIS repeats 6 all the time,
    // and once it "confirmed" a lock 84 ms after the send,
    // 7.4 s before the scooter locked (6 -> 0 -> 6, lock 0 -> 4).
    final stateConfirmsLock = rawState == 0 || (rawState == 6 && next.pendingLock != null && next.locked);
    if (escl == HhmisCmd.esclStatusLocked || stateConfirmsLock) {
      next = _lockConfirmed(next, handlebarFree: escl == HhmisCmd.esclStatusLockFailed);
    }
    final pendingLock = next.pendingLock;
    // ESCL 4 fails the lock only when the vehicle state did NOT also say
    // locked; otherwise it's a free handlebar, warned above.
    if (escl == HhmisCmd.esclStatusLockFailed && pendingLock != null && !stateConfirmsLock) {
      state = next;
      _lockFailed(pendingLock, timedOut: false);
      next = state;
    }
    if (escl is int) _esclDebounce(escl, previous: prevEscl, unlocked: !next.locked);
    // Stock `updateVehicleESCLLockStatus` shows
    // its handlebar-unlock popup when the ESCL goes unlock-failed (2) ->
    // unlocked (1); the popup's button is CTA_UNLOCK.
    if (escl == esclStatusUnlocked && prevEscl == esclStatusUnlockFailed) {
      logEvent('safety', 'handlebar_prompt', {});
      next = _withNotice(next, handlebarNoticeId, handlebarPrompt);
    }
    final hillHold = delta['INT_HILL_HOLD_STATUS'];
    if (hillHold is int && hillHold != prevHillHold) next = _hillHold(next, hillHold);
    // Stock `setTrunkOpenStatus` shows its boot popup
    // on a change in PARK or CHARGING only.
    final trunk = delta['INT_VEHICLE_TRUNK_STATUS'];
    if ((trunk == 2 || trunk == 3) &&
        prevTrunk != null &&
        trunk != prevTrunk &&
        const {3, 6}.contains(_lastRaw['INT_VEHICLE_STATE'])) {
      toast(trunk == 2 ? 'Boot open' : 'Boot closed', trunk == 2 ? ToastType.info : ToastType.success);
    }
    // Stock re-arms the limit each time a hyper or
    // boost charger starts.
    if (next.hyperCharging && !state.hyperCharging) _sendChargeLimitAtHyperStart(next);
    // Mirror HHMIS's brightness echo into the slider. Direct ref.read on
    // the brightness notifier here (not ref.listen in the brightness
    // provider) avoids a circular dependency with the ambient→brightness
    // path in mock_provider's `_applyAmbient`.
    final mirroredBrightness = next.vehicleBrightness;
    if (mirroredBrightness != null && mirroredBrightness != state.vehicleBrightness) {
      ref.read(brightnessProvider.notifier).mirror(mirroredBrightness);
    }
    final attempts = delta['INT_PROFILE_REMAINING_ATTEMPTS'];
    if (attempts is int) {
      _setAttempts(attempts);
      _reportAttempts(attempts);
    }
    final passcode = delta['_passcode'];
    if (passcode is Map) {
      final ok = passcode['success'] == true;
      final remaining = passcode['remaining'];
      final sent = _passcodeSentMicros;
      _passcodeSentMicros = null;
      // HHMIS calls onPasscodeVerify twice per verification, ~80 ms apart
      // (every unlock); the second has no send to pair with.
      final nowMicros = AnalyticsLogger.instance.monoMicros;
      final lastResult = _lastPasscodeResult;
      final repeat = sent == null &&
          lastResult != null &&
          lastResult.$1 == ok &&
          lastResult.$2 == remaining &&
          nowMicros - lastResult.$3 < passcodeRepeatWindow.inMicroseconds;
      _lastPasscodeResult = (ok, remaining, nowMicros);
      if (!repeat) {
        logEvent('safety', 'passcode_result', {
          'success': ok,
          'remaining': remaining,
          'round_trip_ms': sent == null ? null : (nowMicros - sent) ~/ 1000,
        });
      }
      if (remaining is int) {
        _setAttempts(remaining);
        _reportAttempts(remaining);
      }
      if (ok) _attempts = VehicleNotifier.maxPasscodeAttempts;
      _finishPasscode(ok, _attempts);
    }
    final changeAck = delta['BOOL_PROFILE_PASSCODE_CHANGED_ACK'];
    if (changeAck is bool) _finishPasscodeChange(changeAck);
    // Stock closes the ESCL popups whenever the vehicle reaches LOCK,
    // PASSCODE or MOTOR_ON: the VCU has moved on, so the warning is stale.
    // Locked while charging HHMIS reports 6, not 0 (seen in a log), so
    // the lock itself counts too.
    // LOCK is a power cycle as far as the VCU's derate and fault latches go.
    if (delta['INT_VEHICLE_STATE'] == HhmisCmd.vehicleStateLock &&
        (next.deratingActive || next.faultActive || next.notice != null)) {
      next = next.copyWith(deratingActive: false, faultActive: false, faultCode: '', notice: () => null);
    }
    if (const {0, 2, 4}.contains(delta['INT_VEHICLE_STATE']) || (next.locked && !state.locked)) {
      _cancelEsclDebounces();
      if (next.lockFailedWarning || next.unlockFailedWarning) {
        next = next.copyWith(lockFailedWarning: false, unlockFailedWarning: false);
      }
      if (next.notice?.command == handlebarNoticeId) next = next.copyWith(notice: () => null);
    }
    final lastLive = _lastHhmisMicros;
    if (next.hhmisStale && lastLive != null && AnalyticsLogger.instance.monoMicros - lastLive < staleAfter.inMicroseconds) {
      next = next.copyWith(hhmisStale: false);
      logEvent('hhmis', 'stale', {'on': false});
    }
    if (next.hhmisSilent && lastLive != null && AnalyticsLogger.instance.monoMicros - lastLive < staleAfter.inMicroseconds) {
      next = next.copyWith(hhmisSilent: false);
      if (_resumed) logEvent('hhmis', 'stale', {'on': false, 'in_front': true});
    }
    if (_highBeamOverride) {
      if (delta['INT_VEHICLE_STATE'] == HhmisCmd.vehicleStateLock) {
        _highBeamOverride = false;
        logEvent('hhmis', 'high_beam_override', {'on': false, 'source': 'lock'});
        _void(HhmisCmd.highBeamOff);
        next = next.copyWith(highBeam: _lastRaw['BOOL_HIGH_BEAM_STATUS'] == true);
      } else {
        next = next.copyWith(highBeam: true);
      }
    }
    final smartMirror = next.featureMirror['smartHeadlight'];
    final smartMirrorChanged = smartMirror != null && smartMirror != state.featureMirror['smartHeadlight'];
    final movedOff = state.speed == 0 && next.speed > 0;
    final unlocked = state.locked && !next.locked;
    _part(5);
    state = next;
    _part(6);
    if (movedOff) _endNoticeHoldOnMoveOff();
    _applyCallbacks(delta);
    if (smartMirrorChanged) {
      _smartHeadlightOn = smartMirror;
      if (smartMirror) _triggerSmartLight('restore');
    }
    // A pause lasts until the scooter is locked (or a long-press). PARK is
    // not the end of a ride: the stand going down at a stop reports PARK,
    // and once that undid a pause 13 s after the tap.
    final rawNow = delta['INT_VEHICLE_STATE'];
    if (_smartHeadlightPaused && rawNow != prevRawState && rawNow == HhmisCmd.vehicleStateLock) {
      _resumeSmartHeadlight('lock');
    }
    if (unlocked && !(smartMirrorChanged && smartMirror)) _triggerSmartLight('unlock');
    _syncSmartHeadlight();
    for (final MapEntry(key: key, value: feature) in featureAcks.entries) {
      final ok = delta[key];
      if (ok is! bool) continue;
      logEvent('hhmis', 'feature_ack', {'feature': feature.name, 'ok': ok});
      featureAckHandler?.call(feature, ok);
    }
    final music = delta['INT_BT_MUSIC_COMMAND'];
    if (music is int) _musicCommand(music);
    final callHandle = delta['BOOL_BT_CALL_HANDLE_REQUEST'];
    if (callHandle is bool) _callHandleRequest(callHandle);
    // HHMIS replays these two only at unlock (`VehicleProfileManager.
    // setPersistedData`); 1 is on.
    final syncContacts = delta['INT_PERSISTED_SYNC_CONTACT'];
    final syncConsent = delta['INT_PERSISTED_SYNC_CONTACT_CONSENT'];
    if (syncContacts is int || syncConsent is int) {
      phoneCallsHandler?.call(syncContacts is int ? syncContacts == 1 : null, syncConsent is int ? syncConsent == 1 : null);
    }
    final popup = delta['_notificationPopup'];
    if (popup is Map) _notificationPopup(popup);
    if (!_projectLoadedSent && state.provenStopped && const {3, 6}.contains(_lastRaw['INT_VEHICLE_STATE'])) {
      _sendProjectLoaded();
    }
    final vehicleCommand = delta['INT_VEHICLE_COMMAND'];
    if (vehicleCommand is int) _vehicleCommand(vehicleCommand);
    final companion = delta['INT_RIDING_SETTING_CAPP_TOGGLE_REQUEST'];
    if (companion is int) {
      final handler = companionRequestHandler;
      logEvent('hhmis', 'companion_request', {'value': companion, 'handled': handler != null});
      handler?.call(companion);
    }
  }

  /// The raw values behind a change of [VehicleData.featureAvailable]: the
  /// INT keys carry more than yes/no (tow/tamper is 2 on this scooter).
  void _logFeatureAvailability(Map<Object?, Object?> delta) {
    for (final MapEntry(:key, :value) in delta.entries) {
      if (key is! String || !(key.endsWith('_FEATURE_AVAILABLE') || key == 'INT_TECH_PACH_REGEN')) continue;
      logEvent('hhmis', 'feature_available', {'key': key, 'value': value});
    }
  }

  /// HHMIS's `showNotificationPopup` ids (stock `Constants.NotificationPopupId`)
  /// and what the stock popups they drive tell the rider. HHMIS plays the
  /// chime itself; without the text the rider hears a warning and sees
  /// nothing (seen on a ride attempt with the charger plugged in).
  static const notificationPopups = {
    2: 'Start the motor to use reverse',
    3: 'Start the motor to change mode',
    4: 'Hold the brake to start',
    5: 'Stop the scooter to switch off',
    6: 'Unplug the charger to ride',
    7: 'Close the side stand to ride',
  };

  /// `INT_VEHICLE_COMMAND` one-shots that are a toast. Derate, fault and
  /// charging messages are in `vehicleCommands`; the side-stand (59, 160)
  /// and no-brake (62) refusals flash their hint banners; 130 (unplug to
  /// ride) also arrives as TX 14 id 6; 60 side stand and 23 trunk have
  /// their own banners and telltales.
  static const vehicleCommandToasts = {
    42: 'Charger connected but not charging',
    61: 'Put the side stand down to lock',
    112: 'Charging stopped: battery too hot',
    137: 'Release the emergency button to start charging',
    170: 'Release the throttle to ride',
  };

  /// Stock HHMIC shows one vehicle popup at a time and closes it on 0 or on
  /// the next command; HHMIS only chimes. In one log every refusal reached
  /// us chime-only. Derates latch `deratingActive` until a rerate; faults
  /// have no clear ordinal and latch until LOCK.
  void _vehicleCommand(int value) {
    _lastVehicleCommand = value;
    final command = vehicleCommands[value];
    final toastText = vehicleCommandToasts[value];
    final hint = switch (value) {
      59 || 160 => showStandHint,
      62 => showBrakeHint,
      _ => null,
    };
    final knownUnmapped = knownUnmappedCommands.contains(value);
    logEvent('hhmis', 'vehicle_command', {
      'value': value,
      // 60 and 148 have no popup of their own here but are expected.
      // 0 is the "close the popup" signal, not an unknown ordinal.
      'known': value == 0 || command != null || toastText != null || hint != null || knownUnmapped,
      if (command != null) 'effect': command.effect.name,
      if (knownUnmapped) 'unmapped': true,
    });
    // An unknown ordinal (and a knownUnmapped
    // one) must NOT clear the current notice. Only a 0 close or a new
    // known command replaces it.
    var next = state;
    final current = next.notice;
    // Stock ignores a command whose popup is still up (`activePopUp`), so a
    // repeat does not restart a countdown.
    final repeat = command != null && command.held && current?.command == value;
    // The condition is back: forget a close that was waiting.
    if (repeat) _deferredCommand = null;
    final closes = (value == 0 || command != null) && !repeat;
    // Seen on a ride: 134 then 0 came 400 ms apart, three times in
    // three seconds (stock closes on the 0 just as fast). A held notice
    // stays up [noticeMinDisplay]; a close, or a notice of lower priority,
    // waits for that. Equal or higher priority replaces it at once, and so
    // does a countdown, whose seconds are already running on the vehicle.
    final held = current != null && (_noticeMinTimer?.isActive ?? false);
    final replaces = command != null &&
        command.held &&
        (command.seconds != null || command.priority.index <= (current?.priority.index ?? 0));
    final defer = closes && held && !replaces;
    if (defer) {
      _deferredCommand = command != null && command.held ? value : 0;
      logEvent('hhmis', 'notice_deferred', {'command': current.command, 'pending': _deferredCommand});
    } else if (closes) {
      _noticeTimer?.cancel();
      _clearNoticeHold();
      next = next.copyWith(notice: () => null);
    }
    if (command != null) {
      next = switch (command.effect) {
        CommandEffect.derate => next.copyWith(deratingActive: true),
        // A rerate also clears any latched fault.
        // CAN_FAIL (93) is a fault effect; its matching rerate (98) left
        // faultActive / faultCode set otherwise.
        CommandEffect.rerate => next.copyWith(deratingActive: false, faultActive: false, faultCode: ''),
        CommandEffect.fault => next.copyWith(faultActive: true, faultCode: 'C$value'),
        CommandEffect.info => next,
      };
      if (command.held && !repeat && !defer) next = _withNotice(next, value, command);
    }
    state = next;
    if (command != null && !command.held) {
      toast(command.body.isEmpty ? command.title : '${command.title}. ${command.body}',
          command.effect == CommandEffect.rerate ? ToastType.success : ToastType.warning);
    }
    if (toastText != null) toast(toastText, ToastType.warning);
    hint?.call();
  }

  /// [v] with [c] as the one vehicle notice. A timed one closes by itself,
  /// counting down in its text if stock's does.
  VehicleData _withNotice(VehicleData v, int id, VehicleCommand c) {
    _noticeTimer?.cancel();
    _clearNoticeHold();
    final seconds = c.seconds;
    if (seconds == null) {
      _noticeMinTimer = Timer(noticeMinDisplay, () => _noticeHoldElapsed(id));
    } else {
      _noticeTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        final left = seconds - t.tick;
        if (state.notice?.command != id) return t.cancel();
        if (left <= 0) t.cancel();
        if (left <= 0 || c.countsDown) {
          state = state.copyWith(notice: () => left <= 0 ? null : c.notice(id, secondsLeft: left));
        }
      });
    }
    return v.copyWith(notice: () => c.notice(id, secondsLeft: seconds));
  }

  /// The least a held vehicle notice is on screen. Countdown notices keep
  /// their own timing.
  static const noticeMinDisplay = Duration(seconds: 4);
  Timer? _noticeMinTimer;

  /// What arrived while the current notice was inside [noticeMinDisplay]:
  /// 0 to close it, or the ordinal of a lower-priority notice to show next.
  int? _deferredCommand;

  void _clearNoticeHold() {
    _noticeMinTimer?.cancel();
    _noticeMinTimer = null;
    _deferredCommand = null;
  }

  /// A notice the vehicle has already cleared is only being held so it can
  /// be read. Once the rider sets off it is no longer worth their eyes
  /// ("Hill hold may be less effective" once stayed up while riding
  /// away).
  void _endNoticeHoldOnMoveOff() {
    final id = state.notice?.command;
    if (id == null || _deferredCommand != 0 || !(_noticeMinTimer?.isActive ?? false)) return;
    _noticeMinTimer?.cancel();
    logEvent('hhmis', 'notice_hold_ended', {'command': id, 'reason': 'moved_off'});
    _noticeHoldElapsed(id);
  }

  void _noticeHoldElapsed(int id) {
    _noticeMinTimer = null;
    final pending = _deferredCommand;
    _deferredCommand = null;
    if (pending == null || state.notice?.command != id) return;
    final command = vehicleCommands[pending];
    state = command == null ? state.copyWith(notice: () => null) : _withNotice(state, pending, command);
  }

  /// Stock `onHillHoldActive`: 2 is a 3 s
  /// green-tick "Hill hold activated", 4 the "Deactivating Hillhold in"
  /// countdown, anything else hides the countdown.
  VehicleData _hillHold(VehicleData v, int status) {
    if (status == 4) return _withNotice(v, hillHoldNoticeId, hillHoldReleasing);
    if (status == 2) toast('Hill hold activated', ToastType.success);
    if (v.notice?.command != hillHoldNoticeId) return v;
    _noticeTimer?.cancel();
    return v.copyWith(notice: () => null);
  }

  /// Stock `BatteryInfoManager.setHyperChargeStatus`: 0, then 150 ms later
  /// the limit, or 100 once the pack is already past it. Stock's 70 %
  /// default for a rider who never set one is not copied; ours stays "none".
  void _sendChargeLimitAtHyperStart(VehicleData v) {
    final limit = v.chargeLimit > v.batterySoc ? v.chargeLimit : 100;
    logEvent('hhmis', 'charge_limit_armed', {'limit': limit, 'soc': v.batterySoc});
    _int(HhmisCmd.chargeLimit, 0);
    _chargeLimitTimer?.cancel();
    _chargeLimitTimer = Timer(chargeLimitDelay, () => _int(HhmisCmd.chargeLimit, limit));
  }

  static const chargeLimitDelay = Duration(milliseconds: 150);

  void _notificationPopup(Map<Object?, Object?> popup) {
    final id = popup['id'];
    final type = popup['type'];
    final status = popup['status'];
    if (id is int) _lastPopupId = id;
    final text = notificationPopups[id];
    final hint = switch (id) {
      3 => showModeHint,
      4 => showBrakeHint,
      6 => showUnplugHint,
      7 => showStandHint,
      _ => null,
    };
    logEvent('hhmis', 'notification_popup', {'id': id, 'type': type, 'status': status, 'known': text != null});
    // Id 1 (side stand open with the motor on) is the side-stand banner's job.
    // A type-1 popup with status false is the vehicle clearing it.
    if (text == null || (type == 1 && status != true)) return;
    if (hint != null) {
      hint();
    } else {
      toast(text, ToastType.warning);
    }
  }

  int _upForSeconds() {
    final since = _connectedAtMicros;
    return since == null ? -1 : (AnalyticsLogger.instance.monoMicros - since) ~/ 1000000;
  }

  static const _batchSample = 20;
  static const _batchLogEvery = Duration(seconds: 1);

  /// On the charger: one a second was still 3,250 lines an hour all night
  /// The values are in the heartbeat and in `battery.cells`.
  static const _batchLogEveryCharging = Duration(seconds: 10);
  int _batchLoggedAtMicros = 0;
  int _batchCounter = 0;
  final _inbound = Stopwatch();
  int _inboundFromBatch = 0;

  /// Where [_inbound]'s time went, in handler order ([_partNames]).
  final _parts = List<int>.filled(8, 0);
  int _partFrom = 0;
  static const _partNames = ['before', 'survey', 'profile', 'guards', 'mapping', 'checks', 'notify', 'after'];

  void _part(int i) {
    final now = _inbound.elapsedMicroseconds;
    _parts[i] += now - _partFrom;
    _partFrom = now;
  }

  /// HHMIS fires ~100 batches/sec; logging each one filled a 10 MB file in 10
  /// minutes. Log the first batch of each connection (so we
  /// always see what's arriving right after bind) and sample 1-in-
  /// [_batchSample] after that; state transitions and `unknown_key_seen`
  /// cover what the sampled batches miss. Key lists are never cut.
  void _logBatch(Map<Object?, Object?> delta, {required bool live}) {
    final now = AnalyticsLogger.instance.monoMicros;
    final connected = delta['_connected'];
    if (connected == true && _connectedAtMicros == null) {
      _connectedAtMicros = now;
      _batchCounter = 0;
      _resetReattach();
      logEvent('hhmis', 'bind_success', {'state': delta['INT_VEHICLE_STATE'] ?? _lastRaw['INT_VEHICLE_STATE']});
      if (!_everConnected) bootMark('hhmis_connected');
      _everConnected = true;
      onHhmisAttached?.call();
    } else if (connected == false && _connectedAtMicros != null) {
      logEvent('hhmis', 'unbind', {'reason': 'bridge', 'up_for_s': _upForSeconds()});
      _connectedAtMicros = null;
      _lastHhmisMicros = null;
      _firstPasscodeAtMicros = null;
    }
    _batchCounter++;
    // Every 20th batch, and no more than one a second: on the charger HHMIS
    // sends ~100 single-key batches a second, which was five log lines a
    // second and 10 MB every 90 minutes.
    if (_batchCounter == 1 ||
        (_batchCounter % _batchSample == 0 &&
            now - _batchLoggedAtMicros >= (state.isCharging ? _batchLogEveryCharging : _batchLogEvery).inMicroseconds)) {
      _batchLoggedAtMicros = now;
      final keys = delta.keys.whereType<String>().toList();
      logEvent('hhmis', 'batch', {
        'batch_size': keys.length,
        'keys': keys,
        'sample': _batchSample,
        'nth': _batchCounter,
        // Main-thread time in this handler since the last such line, and
        // how many batches it covers: what the stock service's updates cost.
        'handler_ms': (_inbound.elapsedMicroseconds / 100).round() / 10,
        'handler_batches': _batchCounter - _inboundFromBatch,
        // The same time by step: `notify` is `state = next`, every provider
        // and widget that follows the vehicle state.
        'handler_parts_ms': {for (var i = 0; i < _parts.length; i++) _partNames[i]: (_parts[i] / 100).round() / 10},
      }, const {'keys'});
      _parts.fillRange(0, _parts.length, 0);
      _partFrom = 0;
      _inbound.reset();
      _inboundFromBatch = _batchCounter;
    }
    if (delta['_vdpMissing'] == true) logEvent('hhmis', 'unbind', {'reason': 'vdp_missing', 'up_for_s': _upForSeconds()});
    if (live && delta.keys.any((k) => k is String && _isLivenessKey(k))) {
      _lastHhmisMicros = now;
      if (_reattachAttempts > 0) {
        logEvent('hhmis', 'reattach_recovered', {'attempts': _reattachAttempts});
        _resetReattach();
      }
    }
    // SystemStatus.kt sends `_btVia` just before (or with) `_bt`: the source
    // that holds the flag up, or the trigger that dropped it.
    final btVia = delta['_btVia'];
    if (btVia is String) _lastRaw['_btVia'] = btVia;
    for (final MapEntry(key: key, value: evt) in _transitionEvents.entries) {
      if (!delta.containsKey(key)) continue;
      final raw = delta[key];
      final prev = _lastRaw[key];
      if (raw != prev) logEvent('hhmis', evt, {'from': prev, 'to': raw, if (key == '_bt') 'via': _lastRaw['_btVia']});
      _lastRaw[key] = raw;
    }
    final mode = delta['STR_VEHICLE_DRIVE_MODE'];
    if (mode is String) {
      // On MoveOS 5 the custom ride mode arrives as the name the rider gave
      // it: logged by its length, never its text.
      final known = _stockDriveModes.contains(mode);
      if (mode != _lastRaw['STR_VEHICLE_DRIVE_MODE']) {
        logEvent('hhmis', 'drive_mode', {'value': known ? mode : 'string(${mode.length})', if (!known) 'known': false});
      }
      _lastRaw['STR_VEHICLE_DRIVE_MODE'] = mode;
    }
  }

  /// Tracks distinct values we've already logged for each unknown key,
  /// so a fluctuating enum (REGEN_SETTINGS_TOGGLE, _FEATURE_AVAILABLE
  /// and the like) still shows its full range for mapping work, but a
  /// steady key only logs once.
  final Map<String, Set<Object?>> _unknownValuesSeen = {};
  static const _maxUnknownValuesPerKey = 10;

  void _noteUnknown(String key, Object? raw) {
    _unknownKeys.add(key);
    // A string's length, never its text: on newer software an unknown
    // string can be the scooter's position or a phone notification.
    final loggable = raw is num || raw is bool ? raw : raw is String ? 'string(${raw.length})' : null;
    final seen = _unknownValuesSeen.putIfAbsent(key, () => <Object?>{});
    if (seen.length >= _maxUnknownValuesPerKey || !seen.add(loggable)) return;
    logEvent('hhmis', 'unknown_key_seen', {
      'key': key,
      'value': loggable,
      'type': raw.runtimeType.toString(),
      'first_batch_at': _batchCounter,
      'distinct_values_so_far': seen.length,
    });
  }

  void _rollupUnknownKeys() {
    if (_unknownKeys.isEmpty) return;
    logEvent('hhmis', 'unknown_keys', {'count': _unknownKeys.length, 'keys': _unknownKeys.toList()..sort()}, const {'keys'});
    _unknownKeys.clear();
  }

  /// Tests: a sensor history to start from, in place of the saved one.
  @visibleForTesting
  static AmbientHealth Function()? debugAmbientHealth;

  late final AmbientHealth _ambientHealth =
      debugAmbientHealth?.call() ?? AmbientHealth.fromJson(PrefsService.getString(PrefsKeys.ambientHealth, ''));
  AmbientVerdict? _ambientVerdict;
  int _ambientSavedAtMicros = 0;
  static const _ambientSaveEvery = Duration(minutes: 1);

  /// Feeds one reading to [AmbientHealth]; true once the value has shown
  /// itself to be a light sensor. Logged at the first reading of the
  /// process and whenever the verdict changes.
  bool _watchAmbient(int ambient) {
    final now = AnalyticsLogger.instance.monoMicros;
    _ambientHealth.add(ambient, now, brightness: ref.read(brightnessProvider));
    final verdict = _ambientHealth.verdict;
    if (verdict != _ambientVerdict) {
      logEvent('sensor', 'ambient_health', {'from': _ambientVerdict?.name, 'value': ambient, ..._ambientHealth.describe()},
          const {'seconds'});
      _ambientVerdict = verdict;
    }
    if (now - _ambientSavedAtMicros >= _ambientSaveEvery.inMicroseconds) {
      _ambientSavedAtMicros = now;
      PrefsService.setString(PrefsKeys.ambientHealth, _ambientHealth.toJson());
    }
    return verdict == AmbientVerdict.usable;
  }

  /// The value that raises each safety screen. HHMIS sends these on change,
  /// so the same value again is a replay (a reattach, a retaken callback
  /// slot), and it must not bring back a screen the rider has answered.
  static const _safetyRaisers = <String, Object>{
    'BOOL_ACCIDENT_SEVERITY_STAT': true,
    'INT_FALL_DETECTION_ALERT': 1,
    'INT_TOW_THEFT_DETECTION_ALERT': towTheftActive,
  };
  final Map<String, Object?> _lastSafetyRaw = {};

  void _safetyOneShots(Map<Object?, Object?> delta) {
    final tow = delta['INT_TOW_THEFT_DETECTION_ALERT'];
    if (tow != null) {
      logEvent('safety', 'tow_theft', {
        'value': tow,
        'source': 'hhmis',
        'state': delta['INT_VEHICLE_STATE'] ?? _lastRaw['INT_VEHICLE_STATE'],
        'repeat': tow == _lastSafetyRaw['INT_TOW_THEFT_DETECTION_ALERT'],
      });
    }
    for (final MapEntry(:key, value: raiser) in _safetyRaisers.entries) {
      if (!delta.containsKey(key)) continue;
      final raw = delta[key];
      if (raw == raiser && _lastSafetyRaw[key] == raiser) delta.remove(key);
      _lastSafetyRaw[key] = raw;
    }
  }

  bool _isReattachEcho(Map<Object?, Object?> delta) {
    final sent = _reattachSentMicros;
    if (sent == null) return false;
    if (AnalyticsLogger.instance.monoMicros - sent > reattachEchoWindow.inMicroseconds) return false;
    final keys = delta.keys.whereType<String>();
    if (keys.isEmpty || !keys.every(_echoKeys.contains)) return false;
    return !delta.containsKey('INT_VEHICLE_STATE') || delta['INT_VEHICLE_STATE'] == 0;
  }

  /// Underscore keys that carry real HHMIS callbacks, as opposed to bridge
  /// or Android status keys.
  static bool _isLivenessKey(String k) =>
      !k.startsWith('_') ||
      k == '_rangeByMode' ||
      k == '_passcode' ||
      k == '_unlocked' ||
      k == '_volume' ||
      k.startsWith(_hwInfoPrefix);

  /// TX 2 arrives as one key per id (`_hwInfo_6` = VIN), so two ids landing
  /// in one bridge batch, or in the replay snapshot, cannot overwrite each
  /// other.
  static const _hwInfoPrefix = '_hwInfo_';

  /// The callbacks that are not ServerCmd updates and have no VehicleData
  /// field: sunrise / sunset (TX 8), the persisted sound levels (TX 10 / 11),
  /// widget info (TX 3) and the cloud popup command (TX 12).
  void _applyCallbacks(Map<Object?, Object?> delta) {
    final sun = delta['_sunTimes'];
    if (sun is Map) {
      final times = SunTimes.parse(sun['sunrise'], sun['sunset']);
      // HHMIS repeats it every minute; only a new value is worth a line.
      if (times != ref.read(sunTimesProvider)) {
        logEvent('hhmis', 'sun_times', {
          'sunrise': LogPrivacy.sunTime(sun['sunrise']),
          'sunset': LogPrivacy.sunTime(sun['sunset']),
          'parsed': times.known,
        });
        ref.read(sunTimesProvider.notifier).set(times);
      }
    }
    final motor = delta['_motorVolume'];
    final chime = delta['_chimeVolume'];
    if (motor is int || chime is int) {
      logEvent('hhmis', 'sound_levels', {'motor': motor, 'chime': chime});
      ref.read(soundSettingsProvider.notifier).mirrorVehicle(
            motorLevel: motor is int ? motor : null,
            chimeLevel: chime is int ? chime : null,
          );
    }
    // The cloud battery-health popup. Stock HHMIC's handler for this
    // callback is empty and sends no acknowledgement (it acknowledges only
    // its own, file-driven SOH popup once that is on screen), so neither do
    // we: nothing is shown, and HHMIS keeps its copy.
    final popup = delta['_popupCommand'];
    if (popup is Map) {
      final content = popup['content'];
      logEvent('hhmis', 'popup_command', {
        'id': popup['id'],
        'header': popup['header'],
        'content_len': content is String ? content.length : null,
        'icon': popup['icon'],
      });
    }
  }

  /// The day/night trigger, and the 47 = 1 that has to follow it, go out
  /// only while this is true: the vehicle has reported the feature on
  /// (`INT_SMART_HEADLIGHT_PERSIST_BUTTON_STAT` = 1) or the rider switched
  /// it on in this session. Never from the prefs default, which is "on"
  /// even on a scooter that has it off. `BOOL_SMART_HEAD_LIGHT_FEATURE_AVAILABLE`
  /// is logged but does not gate it (see [VehicleData.isFeatureAvailable]).
  @protected
  bool get smartHeadlightTriggerEnabled => _smartHeadlightOn;

  /// Stock `SettingsInfoManager.findDayOrNightNTriggerSmartLight`: on
  /// enable, when the persisted state arrives, on resume and every minute,
  /// tell the VCU whether it is night, then re-assert the toggle. Not a
  /// cmd_send per minute: only a change of the answer is logged.
  void _triggerSmartLight(String reason) {
    if (!smartHeadlightTriggerEnabled || _smartHeadlightPaused || _connectedAtMicros == null) return;
    // Nothing is sent to a locked or sleeping scooter: one night every
    // hourly wake sent the pair, 14 times overnight. The unlock sends it.
    if (state.locked || !_resumed) return;
    final sun = ref.read(sunTimesProvider);
    // With no believable clock (TrustedClock): a light reading, if this
    // scooter's sensor has proven itself (`VehicleData.ambientReading`;
    // on a Gen 1 it reads 60 at noon and at midnight, so it has not);
    // otherwise the stand-in time, the last good reading plus uptime,
    // behind by however long the scooter was off. With neither it counts
    // as night: a headlight on by day costs nothing, one off at night
    // does.
    final byClock = TrustedClock.trusted;
    final light = byClock ? null : state.ambientReading;
    final basis = byClock
        ? 'clock'
        : light != null
            ? 'ambient'
            : TrustedClock.hasEstimate
                ? 'estimate'
                : 'failsafe';
    final night = switch (basis) {
      'clock' => sun.isNight(clock()),
      'ambient' => light! < smartLightNightAmbient,
      'estimate' => sun.isNight(TrustedClock.now()),
      _ => true,
    };
    // The minute tick is logged, as a trigger and as two commands, only
    // when its answer changes; every other reason always is.
    final logged = night != _lastSmartLightNight || reason != 'tick';
    if (logged) {
      logEvent('hhmis', 'smart_light_trigger', {
        'night': night,
        'reason': reason,
        'sun_known': sun.known,
        'basis': basis,
        'ambient': ?light,
      });
    }
    _lastSmartLightNight = night;
    final trigger = {'cmd': HhmisCmd.triggerSmartLight, 'value': night};
    final toggle = {'cmd': HhmisCmd.features[RidingFeature.smartHeadlight], 'value': 1};
    if (logged) {
      _send('sendBoolCmd', trigger);
      _send('sendIntCmd', toggle);
    } else {
      _invoke('sendBoolCmd', trigger).catchError((Object _) => null);
      _invoke('sendIntCmd', toggle).catchError((Object _) => null);
    }
  }

  @override
  void onClockTrust(bool trusted) {
    if (trusted) _triggerSmartLight('clock');
  }

  void _syncSmartHeadlight() {
    final mode = !smartHeadlightTriggerEnabled
        ? SmartHeadlight.off
        : _smartHeadlightPaused
            ? SmartHeadlight.paused
            : SmartHeadlight.auto;
    if (state.smartHeadlight != mode) state = state.copyWith(smartHeadlight: mode);
  }

  void _setSmartHeadlightPaused(bool on, String source) {
    if (_smartHeadlightPaused == on) return;
    _smartHeadlightPaused = on;
    // The pause writes 47 = 0 into the rider's profile.
    if (on) _setSmartOffIsOurs(true);
    PrefsService.setBool(PrefsKeys.smartHeadlightPaused, on);
    logEvent('hhmis', 'smart_light_pause', {'on': on, 'source': source});
    _syncSmartHeadlight();
  }

  /// The VCU gets the lamp back: a manual high beam of ours is switched
  /// off first, then the normal enable (trigger, 47 = 1).
  void _resumeSmartHeadlight(String source) {
    if (!_smartHeadlightPaused) return;
    _setSmartHeadlightPaused(false, source);
    if (_highBeamOverride) {
      _highBeamOverride = false;
      logEvent('hhmis', 'high_beam_override', {'on': false, 'source': 'smart_resume'});
      _void(HhmisCmd.highBeamOff);
      state = state.copyWith(highBeam: _lastRaw['BOOL_HIGH_BEAM_STATUS'] == true);
    }
    _triggerSmartLight('unpause');
  }

  @override
  void resumeSmartHeadlight() {
    if (!_smartHeadlightPaused) return;
    _resumeSmartHeadlight('long_press');
    toast('Smart headlight resumed');
  }

  /// Stock HHMIC sends PROJECT_LOADED once its UI is up; 3 s later HHMIS
  /// sends HMI_Wakeup_pass to the VCU and re-pumps ride and UI data. With
  /// HHMIC killed at our start (and later disabled) nobody else sends it.
  ///
  /// Stock sends it unconditionally, in whatever state the project loads
  /// (`MainActivity.onProjectLoaded`). HHMIS decides 3000 ms later: it
  /// skips the whole reply when its saved state is then PASSCODE or ALARM,
  /// and otherwise replays PARK, then the saved state, then the pumps and
  /// the wake-up (`IClientServiceInterfaceBuilder$1.lambda$onVoidHMICmd$0`).
  ///
  /// We wait for PARK or CHARGING at standstill instead. LOCK would be
  /// answered, but with the screen awake LOCK turns into PASSCODE within
  /// 3 s (87 of the 118 LOCK -> PASSCODE transitions in four days of
  /// logs; the rest are overnight sleeps), so the reply is skipped and our
  /// one send is spent (seen once: sent at LOCK, PASSCODE 80 ms later, no
  /// wake-up, no data re-pump). Mid-ride the replayed PARK would end the
  /// ride.
  void _sendProjectLoaded() {
    _projectLoadedSent = true;
    _projectLoadedAtMicros = AnalyticsLogger.instance.monoMicros;
    logEvent('hhmis', 'project_loaded_sent', {'state': _lastRaw['INT_VEHICLE_STATE']});
    _send('sendVoidCmd', {'cmd': HhmisCmd.projectLoaded});
  }

  bool _isProjectLoadedPark(Map<Object?, Object?> delta) {
    final sent = _projectLoadedAtMicros;
    if (sent == null || delta['INT_VEHICLE_STATE'] != HhmisCmd.vehicleStatePark) return false;
    final age = AnalyticsLogger.instance.monoMicros - sent;
    if (age > projectLoadedEchoUntil.inMicroseconds) {
      _projectLoadedAtMicros = null;
      return false;
    }
    return age >= projectLoadedEchoFrom.inMicroseconds && _lastRaw['INT_VEHICLE_STATE'] != HhmisCmd.vehicleStatePark;
  }

  void _checkStale() {
    final connectedAt = _connectedAtMicros;
    // Before HHMIS's first data the badge already says "Connecting…"; a stale
    // flag there was a false alarm (seen at a boot: 4.4 s after the bind).
    final last = _lastHhmisMicros;
    if (connectedAt == null || last == null) return;
    if (!_resumed) {
      // Behind another app nothing is drawn and nothing is reattached (see
      // [_checkStaleness]), but a frozen speed must not pass for a stop.
      final silentFor = AnalyticsLogger.instance.monoMicros - last;
      if (state.hhmisSilent || silentFor < staleAfter.inMicroseconds) return;
      // Once per pause: a sleeping scooter sends data each minute, which
      // flipped this 1,831 times in a day's log.
      if (!_silentLogged) logEvent('hhmis', 'stale', {'on': true, 'gap_ms': silentFor ~/ 1000, 'in_front': false});
      _silentLogged = true;
      state = state.copyWith(hhmisSilent: true);
      return;
    }
    if (state.hhmisStale) return;
    // HHMIS is silent while the screen is off; measuring from the last
    // pre-sleep value flashed "Reconnecting…" at every wake (one night,
    // every ~67 min, gap ~4000 s, cleared 0.5 s later).
    final resumedAt = _resumedAtMicros;
    final since = resumedAt != null && resumedAt > last ? resumedAt : last;
    final gap = AnalyticsLogger.instance.monoMicros - since;
    if (gap < staleAfter.inMicroseconds) return;
    logEvent('hhmis', 'stale', {'on': true, 'gap_ms': gap ~/ 1000});
    state = state.copyWith(hhmisStale: true);
  }

  @override
  void markTouched() {
    _touched = true;
    // Told to the vehicle at once, not at the next one-second tick: it
    // locks a parked scooter about a minute after the last touch it heard
    // of (once, a touch a moment before that limit went out half a
    // second later, and the scooter locked).
    if (_lastTouchSent == true || !_resumed || _connectedAtMicros == null || state.speed > 1) return;
    _lastTouchSent = true;
    _awakeAtMicros = AnalyticsLogger.instance.monoMicros;
    logEvent('hhmis', 'touch_status', {'on': true, 'at': 'touch'});
    _invoke('sendBoolCmd', {'cmd': HhmisCmd.touchStatus, 'value': true}).catchError((Object _) => null);
    _updateIdleLock();
  }

  @override
  HhmisHealth get health {
    final now = AnalyticsLogger.instance.monoMicros;
    final connectedAt = _connectedAtMicros;
    final last = _lastHhmisMicros;
    return HhmisHealth(
      connectedForMicros: connectedAt == null ? null : now - connectedAt,
      lastDataAgoMicros: last == null ? null : now - last,
      stale: state.hhmisStale,
      inFront: _resumed,
      batches: _batchCounter,
      reattaches: _reattachTotal,
      projectLoadedSent: _projectLoadedSent,
      touchOn: _lastTouchSent,
      lastCommand: _lastCmdName,
      lastCommandOk: _lastCmdOk,
      lastCommandMs: _lastCmdMs,
      lastVehicleCommand: _lastVehicleCommand,
      lastPopupId: _lastPopupId,
    );
  }

  /// Stock Settings → Reboot Scooter: `VOID_REBOOT_ON_FAULT_ACK` (23). HHMIS
  /// answers with a short burst, not a retry loop: `Scooter_Reboot` to the
  /// VCU every 20 ms for 100 ms (`PeriodicMessenger`, 5 sends). The whole
  /// scooter restarts, not just the head unit (~70 s per stock's text).
  /// Stock's settings path also clears DA/CCM app data and calls HPMS
  /// `restartScooter()` first; its fault-popup path sends 23 alone, as here.
  @override
  Future<bool> rebootScooter() async {
    logEvent('recovery', 'reboot_scooter', {'via': 'hhmis'});
    await AnalyticsLogger.instance.flush();
    return (await _send('sendVoidCmd', {'cmd': HhmisCmd.rebootOnFaultAck})).ok;
  }

  @override
  void btSnapshot(String reason) => _invoke('btSnapshot', reason).catchError((Object _) => null);

  /// Diagnostics → Connections. addCallback makes HHMIS flash LOCK, which
  /// the reattach-echo path already absorbs.
  @override
  void reattachNow() {
    if (state.speed > 0) return;
    logEvent('hhmis', 'reattach_manual', {});
    _reattachSentMicros = AnalyticsLogger.instance.monoMicros;
    _reattachTotal++;
    _invoke('reattachCallback', null).then((ok) {
      if (ok == true) onHhmisAttached?.call();
    }, onError: (Object e) {
      logEvent('hhmis', 'reattach_failed', {'error': e.toString()});
    });
  }

  /// BOOL_TOUCH_STATUS once a second while in front, as stock HHMIC's
  /// WakeLockNotifier does; HHMIS forwards it to the VCU, which owns the
  /// screen-sleep timer. Not a cmd_send per tick: only changes are logged.
  void _sendTouchStatus() {
    if (!_resumed || _connectedAtMicros == null) {
      _updateIdleLock();
      return;
    }
    final v = state;
    // Stock disables touch above 1 km/h, so a touch there never counts.
    final awake = (_touched && v.speed <= 1) ||
        (v.mediaPlaying && (v.vehicleState == VehicleState.parked || v.isCharging)) ||
        v.btPairingCode.isNotEmpty;
    _touched = false;
    if (awake != _lastTouchSent) logEvent('hhmis', 'touch_status', {'on': awake});
    _lastTouchSent = awake;
    if (awake) _awakeAtMicros = AnalyticsLogger.instance.monoMicros;
    _invoke('sendBoolCmd', {'cmd': HhmisCmd.touchStatus, 'value': awake}).catchError((Object _) => null);
    _updateIdleLock();
  }

  /// When the vehicle last heard something that keeps it awake, or since
  /// when it has been waiting for that (the unlock, the return to our
  /// screen).
  int _awakeAtMicros = 0;
  bool _idleCounting = false;
  bool _idleWasMoving = false;
  bool _idleStandWasUp = false;
  bool _standUpWaiting = false;
  bool _standUpHinted = false;
  int _standUpSinceMicros = 0;
  int _standUpHintAtMicros = 0;

  /// Left parked and unlocked with the stand up: said once, at the moment
  /// a lock would have come, and taken down after [standUpHintFor]. Not
  /// again until the scooter has been ridden, locked or put on its stand.
  void _updateStandUpHint(bool waiting, int now) {
    if (!waiting) {
      _standUpWaiting = false;
      _standUpHinted = false;
      standUpHint.value = false;
      return;
    }
    if (!_standUpWaiting) {
      _standUpWaiting = true;
      _standUpSinceMicros = now;
    }
    final from = _awakeAtMicros > _standUpSinceMicros ? _awakeAtMicros : _standUpSinceMicros;
    if (!_standUpHinted && now - from >= idleLockAfter.inMicroseconds) {
      _standUpHinted = true;
      _standUpHintAtMicros = now;
      standUpHint.value = true;
      logEvent('safety', 'stand_up_hint', {'shown': true});
    } else if (standUpHint.value && now - _standUpHintAtMicros >= standUpHintFor.inMicroseconds) {
      standUpHint.value = false;
    }
  }

  /// Where the vehicle's own countdown to the idle lock stands, for the
  /// warning. Only where that lock has been seen: unlocked, parked, off the
  /// charger, standing still, on our own screen.
  void _updateIdleLock() {
    final v = state;
    final idle = _resumed &&
        _connectedAtMicros != null &&
        !v.locked &&
        v.vehicleState == VehicleState.parked &&
        !v.isCharging &&
        v.speed == 0;
    // The vehicle counts only with the side stand down. Seen once: parked
    // with the stand up it stayed unlocked, and locked 61 s after the stand
    // went down; in every log before, a warning shown with the stand up
    // never ended in a lock (3 of 3), one with it down did 53 times of 68.
    final counting = idle && v.sideStand;
    final now = AnalyticsLogger.instance.monoMicros;
    // The vehicle counts from the last touch it heard of, the ones on the
    // passcode screen included; only an older one is replaced by "now".
    if (counting && !_idleCounting && now - _awakeAtMicros > idleLockAfter.inMicroseconds) _awakeAtMicros = now;
    // Coming to a stop: the minute starts at the stop, not at a touch made
    // while riding (once, 51 s after the last touch the scooter
    // parked, and it was still unlocked 43 s after that).
    // TODO(idle-lock-after-ride): one observation. When the scooter does lock after a stop, with or
    // without another app in front, is not known: read the next logs for a stop followed by a lock with no touch.
    if (counting && _idleWasMoving) _awakeAtMicros = now;
    // So does the stand going down.
    if (counting && _idleStandWasUp) _awakeAtMicros = now;
    _idleStandWasUp = idle && !v.sideStand;
    _updateStandUpHint(idle && !v.sideStand, now);
    _idleWasMoving = !v.locked && v.vehicleState != VehicleState.parked;
    _idleCounting = counting;
    int? left;
    var overdue = false;
    if (counting) {
      final idle = Duration(microseconds: now - _awakeAtMicros);
      overdue = idle > idleLockAfter + idleLockOverdue;
      if (!overdue && idle >= idleLockAfter - idleLockWarning) {
        left = (idleLockAfter - idle).inSeconds.clamp(0, idleLockWarning.inSeconds);
      }
    }
    final was = idleLockIn.value;
    if (left == was) return;
    if (was == null) logEvent('safety', 'idle_lock_warning', {'shown': true, 'in_s': left, 'stand': v.sideStand});
    if (left == null) logEvent('safety', 'idle_lock_warning', {'shown': false, 'outcome': v.locked ? 'locked' : overdue ? 'overdue' : 'awake', 'was_s': was});
    idleLockIn.value = left;
  }

  void onLifecyclePause() {
    if (!_resumed) return;
    _resumed = false;
    _silentLogged = false;
    logEvent('hhmis', 'lifecycle_pause', {'was_connected': _connectedAtMicros != null});
    _stalenessTimer?.cancel();
    _stalenessTimer = null;
    ref.read(promptSurfaceVisibleProvider.notifier).screenShown(false);
  }

  /// Only reattaches when the data already looks stale: each reattach makes
  /// HHMIS flash LOCK, which closes overlays and wipes passcode digits, and
  /// most returns from another app need nothing.
  void onLifecycleResume() {
    if (_resumed) return;
    _resumed = true;
    _resumedAtMicros = AnalyticsLogger.instance.monoMicros;
    logEvent('hhmis', 'lifecycle_resume', {'was_connected': _connectedAtMicros != null});
    ref.read(promptSurfaceVisibleProvider.notifier).screenShown(true);
    _triggerSmartLight('resume');
    _startStalenessTimer();
    _checkStaleness(resumeTriggered: true);
  }

  void _startStalenessTimer() {
    _stalenessTimer?.cancel();
    _stalenessTimer = _resumed ? Timer.periodic(stalenessCheckEvery, (_) => _checkStaleness()) : null;
  }

  void _resetReattach() {
    _reattachAttempts = 0;
    _nextReattachAfter = null;
  }

  /// While paused the stock dashboard may legitimately hold HHMIS's single
  /// callback slot; taking it back then would freeze the rider's escape hatch.
  void _checkStaleness({bool resumeTriggered = false, Duration threshold = stalenessThreshold}) {
    final connectedAt = _connectedAtMicros;
    if (!_resumed || connectedAt == null) return;
    final now = AnalyticsLogger.instance.monoMicros;
    final gap = now - (_lastHhmisMicros ?? connectedAt);
    if (gap < threshold.inMicroseconds) return;
    if (_reattachAttempts >= reattachBackoffs.length) return;
    if (now < (_nextReattachAfter ?? 0)) return;
    logEvent('hhmis', 'reattach_scheduled', {
      'gap_s': gap ~/ 1000000,
      'resume_triggered': resumeTriggered,
      'attempt': _reattachAttempts,
    });
    _reattachAttempts++;
    _reattachTotal++;
    _nextReattachAfter = _reattachAttempts < reattachBackoffs.length
        ? now + reattachBackoffs[_reattachAttempts].inMicroseconds
        : null;
    _reattachSentMicros = now;
    _invoke('reattachCallback', null).then((ok) {
      if (ok != true) logEvent('hhmis', 'reattach_failed', {'error': 'not bound'});
      // The stock dashboard takes the update slot along with ours.
      if (ok == true) onHhmisAttached?.call();
    }, onError: (Object e) {
      logEvent('hhmis', 'reattach_failed', {'error': e.toString()});
    });
  }

  /// Gives the lock screen HPMS's own count, so a lockout tracks the
  /// vehicle's 5-minute window rather than a local timer alone.
  void _reportAttempts(int remaining) {
    if (remaining < 0) return;
    ref.read(passcodeReportProvider.notifier).report(remaining);
  }

  /// HPMS reports -1 after a verify-only challenge (the settings gate),
  /// which does not spend an attempt.
  void _setAttempts(int remaining) =>
      _attempts = remaining == -1 ? VehicleNotifier.maxPasscodeAttempts : remaining;

  /// Once the CAN nibble has reported, the HHMIS boolean stops writing
  /// regenAvailability. They are different signals: HHMIS forwards the BMS
  /// 0x640 `regenAvailabilityFlag` (`(b0 & 0x28) == 0x28`), the CAN path
  /// reads the VCU's 0x683 RegenAvailability enum. Letting both write made
  /// them flicker against each other; the VCU enum is the richer one.
  ///
  /// Released whenever the CAN stream is lost
  /// so HHMIS's boolean takes over again instead of pinning a stale
  /// VCU value until reconnection.
  bool _canOwnsRegen = false;
  bool _canLive = false;

  /// The CAN stream is delivering battery frames right now.
  bool get canLive => _canLive;
  bool? _hhmisRegenFlag;

  /// Called by the gRPC provider when the CAN session drops. HHMIS owns
  /// regen again (its last flag is re-applied, or the value goes back to
  /// unread), and what only CAN carries returns to its pre-first-frame
  /// value so a frozen reading is not shown as live (G-3): ambient light
  /// unknown, no BMS limits (the power bar falls back to its fixed
  /// ceiling), no pack voltage. Trunk, tow/theft, bus voltage and current
  /// stay: HHMIS writes those too.
  @override
  void releaseCanOwnership() {
    if (!_canLive) return;
    _canLive = false;
    _canOwnsRegen = false;
    final flag = _hhmisRegenFlag;
    state = state.copyWith(
      ambientKnown: false,
      regenPowerLimitW: 0,
      dischargePowerLimitW: 0,
      packVoltage: 0,
      odometerM: 0,
      regenAvailability: flag == true ? 1 : 0,
      regenAvailabilityKnown: flag != null,
    );
    logEvent('grpc', 'can_values_cleared', {'hhmis_regen_flag': flag});
  }

  /// Sensor data bridged from the CAN stream for what HHMIS does not carry
  /// (ambient light, service flag, Eco range, BMS ceilings). Fields both
  /// paths carry are last-write-wins into the same VehicleData; a null
  /// means the frame has not arrived and the current value stands.
  final CruiseWatch _cruiseWatch = CruiseWatch();

  void applySensorUpdate({
    required int? ambientBrightness,
    required bool? serviceIndicator,
    required int? regenPowerLimitW,
    required int? dischargePowerLimitW,
    required int? rangeEcoCan,
    required int? regenAvailability,
    required int? towTheftState,
    required double? busVoltage,
    required double? packVoltage,
    required double? packCurrent,
    required bool? trunkClosed,
    required int? vehicleLockStateBcm,
    int? odometerM,
    double? pduTemp,
    double? mcuTemp,
    ThermalLimits? thermalLimits,
    LiveInputs? liveInputs,
  }) {
    _canLive = true;
    if (regenAvailability != null) _canOwnsRegen = true;
    final towChanged = towTheftState != null && towTheftState != state.towTheftState;
    if (towChanged) {
      logEvent('safety', 'tow_theft', {'value': towTheftState, 'source': 'can', 'state': _lastRaw['INT_VEHICLE_STATE']});
    }
    final ambient = ambientBrightness?.clamp(0, 100);
    final ambientUsable = ambient == null ? null : _watchAmbient(ambient);
    final ambientChanged = ambient != null && (ambient != state.ambientBrightness || !state.ambientKnown);
    // 0x144 is the BCM's last lock *operation*, not whether the vehicle is
    // locked: in one log it read Lock_Fail (4) for minutes on a parked,
    // unlocked scooter, the vehicle went to LOCK with the BCM
    // still at 4, and after each passcode unlock it trails HHMIS's PARK by
    // 0.1-0.8 s. So HHMIS's INT_VEHICLE_STATE owns lockState. CAN may only
    // assert Locked (3) while HHMIS has sent no vehicle state recently (a
    // stale replay, a stolen callback slot), and never unlocks. The
    // fail/unlock-fail warnings stay with HHMIS's one-shot ESCL event.
    final lastState = _lastVehicleStateMicros;
    final hhmisStateFresh = lastState != null &&
        AnalyticsLogger.instance.monoMicros - lastState < stalenessThreshold.inMicroseconds;
    final lockState = vehicleLockStateBcm == bcmLocked && !hhmisStateFresh ? 4 : null;
    if (lockState != null && state.lockState != lockState) {
      logEvent('can', 'lock_asserted', {
        'bcm': vehicleLockStateBcm,
        'from': state.lockState,
        'hhmis_state_age_ms': lastState == null ? null : (AnalyticsLogger.instance.monoMicros - lastState) ~/ 1000,
      });
    }
    // HHMIS forwards a latch change only in its SLEEP /
    // VEHICLE_IDLE states (`VPServerConnection$4.isTrunkLock`; LOCK and
    // PASSCODE here) and otherwise speaks through the VCU's open / close
    // notices. Until HHMIS has reported a trunk status the raw 0x353 bit
    // stands in for it; after that it may follow along in those states,
    // never contradict HHMIS in PARK, riding or charging.
    final rawState = _lastRaw['INT_VEHICLE_STATE'];
    final canOwnsTrunk = _lastRaw['INT_VEHICLE_TRUNK_STATUS'] == null ||
        rawState == HhmisCmd.vehicleStateLock ||
        rawState == HhmisCmd.vehicleStatePasscode;
    final trunkOpen = trunkClosed == null || !canOwnsTrunk ? null : !trunkClosed;
    state = state.copyWith(
      ambientBrightness: ambient,
      ambientKnown: ambient == null ? null : true,
      ambientUsable: ambientUsable,
      serviceIndicator: serviceIndicator,
      regenPowerLimitW: regenPowerLimitW,
      dischargePowerLimitW: dischargePowerLimitW,
      rangeEcoCan: rangeEcoCan,
      regenAvailability: regenAvailability,
      regenAvailabilityKnown: regenAvailability == null ? null : true,
      towTheftState: towTheftState,
      // As on the HHMIS key: only ACTIVE raises the alert (once, on the
      // change), and only the end of ALARM takes it down.
      tamperDetected: towChanged && towTheftState == towTheftActive ? true : null,
      busVoltage: busVoltage,
      packVoltage: packVoltage,
      packCurrent: packCurrent,
      odometerM: odometerM,
      pduTemp: pduTemp?.round(),
      pduTempSeen: pduTemp == null ? null : true,
      mcuTemp: mcuTemp?.round(),
      mcuTempSeen: mcuTemp == null ? null : true,
      thermalLimits: thermalLimits,
      liveInputs: liveInputs,
      trunkOpen: trunkOpen,
      trunkStateKnown: trunkOpen == null ? null : true,
      lockState: lockState,
    );
    if (ambientChanged) applyAmbient();
    if (liveInputs != null) {
      final cruiseMsg = _cruiseWatch.onUpdate(
        pressed: liveInputs.cruise,
        engaged: liveInputs.cruiseEngaged || state.cruiseMode == CruiseMode.active,
        availability: liveInputs.cruiseAvailability,
        nowMs: AnalyticsLogger.instance.monoMicros ~/ 1000,
      );
      if (cruiseMsg != null) {
        logEvent('can', 'cruise_unavailable', {'availability': liveInputs.cruiseAvailability});
        toast(cruiseMsg, ToastType.info);
      }
    }
  }

  /// HHMIS TX 2 `onUpdateHardwareInfo(int id, String value)`. Ids from the
  /// decompiled stock stub: 0 BCM, 1 BMS, 2 BLE, 3 HU, 4 HBC, 5 MCU, 6 VIN.
  /// 0x14-0x16 are bootloaders the UI doesn't surface.
  VehicleData _applyHardwareInfo(VehicleData v, int id, String value) {
    switch (id) {
      case 0:
        return v.copyWith(bcmVersion: value);
      case 1:
        return v.copyWith(bmsVersion: value);
      case 2:
        return v.copyWith(bleVersion: value);
      case 3:
        return v.copyWith(huVersion: value);
      case 4:
        return v.copyWith(hbcVersion: value);
      case 5:
        return v.copyWith(mcuVersion: value);
      case 6:
        return v.copyWith(vin: value);
    }
    return v;
  }

  /// Switch-cube media buttons, as HHMIS `setDepadEvent` emits them.
  void _musicCommand(int code) {
    // Seen on a ride: three play presses with no phone connected, and nothing
    // on screen said why nothing happened.
    // The key still goes out (harmless, and right if the flag is wrong).
    if (!state.btConnected && !_mediaLive) {
      logEvent('media', 'key_no_phone', {'code': code});
      toast('No phone connected', ToastType.warning);
    }
    switch (code) {
      case 0:
        // Stock picks from the phone's real state (`BtMediaManager`
        // `isPlayPauseStatus`); without one, let the phone toggle.
        if (!_mediaLive) {
          _cmd('mediaKey', 'playPause');
        } else if (state.mediaPlaying) {
          mediaPause();
        } else {
          mediaPlay();
        }
      case 1:
        mediaNext();
      case 2:
        mediaPrev();
    }
  }

  /// Every command is logged as `cmd_send` / `cmd_result` sharing a `seq`,
  /// so the file shows what was sent and whether the bridge took it.
  /// [_Sent.rejected]: HHMIS was bound but threw, as opposed to not bound.
  Future<_Sent> _send(String method, Object? args, {Map<String, Object?>? describe}) async {
    final cmd = args is Map ? args['cmd'] : null;
    if (cmd is String && !HhmisCmd.sendable(method, cmd)) {
      logEvent('hhmis', 'cmd_refused', {'cmd': cmd, 'method': method});
      return (ok: false, rejected: false, held: null);
    }
    final seq = ++_seq;
    final started = AnalyticsLogger.instance.monoMicros;
    logEvent('hhmis', 'cmd_send', {'seq': seq, ...describe ?? _describe(method, args)});
    bool ok;
    var rejected = false;
    String? held;
    String? error;
    try {
      final answer = await _invoke(method, args);
      ok = answer == true;
      if (answer is _Held) held = answer.why;
    } catch (e) {
      debugPrint('[AIDL] $method failed: $e');
      ok = false;
      rejected = e is PlatformException && e.code == hhmisErrorCode;
      error = e.toString();
    }
    final tookMs = (AnalyticsLogger.instance.monoMicros - started) ~/ 1000;
    logEvent('hhmis', 'cmd_result', {'seq': seq, 'success': ok, 'took_ms': tookMs, 'error': error, 'held': ?held});
    final d = describe ?? _describe(method, args);
    _lastCmdName = (d['name'] ?? d['type'] ?? method).toString();
    _lastCmdOk = ok;
    _lastCmdMs = tookMs;
    return (ok: ok, rejected: rejected, held: held);
  }

  /// The raw send path, for the test that pins what it refuses.
  @visibleForTesting
  Future<bool> debugSend(String method, Object? args) async => (await _send(method, args)).ok;

  /// A held command is not a lost connection: once the trunk on a
  /// MoveOS 5 scooter said "Scooter not connected" until the rider found
  /// the dialog. It is offered again here, even after "Not now".
  void _toastFailure(_Sent r) {
    switch (r.held) {
      case 'unchecked':
        toast('Allow OpenDash on this scooter first', ToastType.warning);
        _uncheckedDismissed = false;
        _checkScooter(state.vehicleType);
      case 'identifying':
        toast('Still reading the scooter\'s software. Try again in a moment', ToastType.warning);
      default:
        toast(r.rejected ? 'Scooter refused the command' : 'Scooter not connected', ToastType.warning);
    }
  }

  /// Settings OpenDash applies by itself at start-up, before the vehicle
  /// service is bound (seen: brightness at 0.3 s, the bind at 0.6 s).
  /// Failing then says nothing: at the bind the vehicle replays its saved
  /// levels, and auto brightness applies its own on that echo.
  static const _quietBeforeBind = {'setBrightness', 'setVolume', 'setMotorVolume', 'setChimeVolume'};

  static Map<String, Object?> _describe(String method, Object? args) {
    final type = switch (method) {
      'sendVoidCmd' => 'void',
      'sendIntCmd' => 'int',
      'sendBoolCmd' => 'bool',
      'sendStringCmd' => 'string',
      _ => method,
    };
    String? cmd;
    Object? value;
    if (args is Map) {
      cmd = args['cmd'] as String?;
      value = args['value'];
    } else {
      value = args;
    }
    if (cmd == HhmisCmd.passcodeChange) value = '<redacted>';
    return {
      'cmd': cmd,
      'name': cmd == null ? null : HhmisCmd.names[cmd],
      'type': type,
      'value': value,
      if (args is Map && args['persist'] != null) 'persist': args['persist'],
    };
  }

  /// Fire-and-forget command; the rider hears about a failure.
  void _cmd(String method, Object? args, {String? onSent}) {
    _send(method, args).then((r) {
      if (!r.ok) {
        if (!r.rejected && r.held == null && !state.hhmisConnected && _quietBeforeBind.contains(method)) return;
        _toastFailure(r);
      } else if (onSent != null) {
        toast(onSent);
      }
    });
  }

  void _void(String cmd, {String? onSent}) => _cmd('sendVoidCmd', {'cmd': cmd}, onSent: onSent);
  void _int(String cmd, int value, {String? onSent}) => _cmd('sendIntCmd', {'cmd': cmd, 'value': value}, onSent: onSent);
  void _bool(String cmd, bool value) => _cmd('sendBoolCmd', {'cmd': cmd, 'value': value});

  /// CTA_LOCK (0x6BC 16) is the VCU's own popup reply; outside one the VCU
  /// may ignore it, so "sent" proves nothing. The lock stays pending until
  /// ESCL echoes "locked".
  @override
  void lockScooter() => _lock(LockSource.userLock, HhmisCmd.esclLock, HhmisCmd.esclLockValue);

  /// Lock_Now (0x6BC 54); a ride log showed the VCU ignoring it
  /// unsolicited, so it waits for the echo like [lockScooter].
  @override
  void autoPark() => _lock(LockSource.autoPark, HhmisCmd.sideStandStatus, HhmisCmd.sideStandLockNow);

  /// CTA_UNLOCK (INT_ESCL_LOCK_CMD=1).
  /// Mirrors stock's lock-recheck pattern so a still-failing unlock after
  /// 3 s plays the negative chime, and a transient 2 flip doesn't leave
  /// the warning on screen. Does not latch a pending state; the UI uses
  /// `unlockFailedWarning` for the banner.
  @override
  void retryUnlock() {
    _esclUnlockFailDebounce?.cancel();
    _esclUnlockFailDebounce = Timer(esclFailDebounce, () {
      _esclUnlockFailDebounce = null;
      if (_lastRaw['INT_VEHICLE_ESCL_STATUS'] != esclStatusUnlockFailed) return;
      _sendEsclIgnore(esclStatusUnlockFailed, 'unlock_recheck');
      _send('sendIntCmd', {'cmd': HhmisCmd.playChime, 'value': HhmisCmd.chimeNegative});
    });
    logEvent('safety', 'unlock_retry_sent', {'cmd': HhmisCmd.esclLock, 'value': HhmisCmd.esclUnlockValue});
    _send('sendIntCmd', {'cmd': HhmisCmd.esclLock, 'value': HhmisCmd.esclUnlockValue}).then((r) {
      if (!r.ok) _toastFailure(r);
    });
  }

  void _lock(LockSource source, String cmd, int value) {
    if (refuseUnlessStopped(ref, state, source.name, 'Stop to lock the scooter')) return;
    // Stock turns hazards off with the lock (SettingsInfoManager on
    // ACTION_LOCKSCOOTER).
    if (state.hazard) _setHazard(false);
    // Stock's LOCK_HANDLE_PRESSED re-checks 3 s later: still failed means
    // CTA_IGNORE again and the negative chime.
    _lockRecheck?.cancel();
    _lockRecheck = Timer(esclFailDebounce, () {
      _lockRecheck = null;
      if (_lastRaw['INT_VEHICLE_ESCL_STATUS'] != HhmisCmd.esclStatusLockFailed) return;
      _sendEsclIgnore(HhmisCmd.esclStatusLockFailed, 'lock_recheck');
      _send('sendIntCmd', {'cmd': HhmisCmd.playChime, 'value': HhmisCmd.chimeNegative});
    });
    final sentAt = AnalyticsLogger.instance.monoMicros;
    final attempt = LockAttempt(sentAtMicros: sentAt, source: source);
    _lockTimer?.cancel();
    _lockFailedTimer?.cancel();
    state = state.copyWith(pendingLock: () => attempt, lockFailedAtMicros: () => null);
    logEvent('safety', 'lock_sent', {'source': source.name, 'cmd': cmd, 'value': value});
    _lockTimer = Timer(lockEchoTimeout, () => _lockFailed(attempt, timedOut: true));
    _send('sendIntCmd', {'cmd': cmd, 'value': value}).then((r) {
      if (r.ok) {
        toast('Locking');
        return;
      }
      _toastFailure(r);
      if (state.pendingLock != attempt) return;
      _lockTimer?.cancel();
      state = state.copyWith(pendingLock: () => null);
    });
  }

  /// No echo in time, or ESCL said "lock failed" (4). A timeout is only a
  /// guess at the ESCL's speed, so a "locked" within [lockFailedHold] still
  /// confirms it.
  // TODO(lock-timeout): the timeout is a guess at how long the handlebar lock takes; collect the real times from
  // hhmis.cmd_send esclLock to state.lock_change before tightening or loosening it.
  void _lockFailed(LockAttempt attempt, {required bool timedOut}) {
    if (state.pendingLock != attempt || state.lockFailedAtMicros != null) return;
    _lockTimer?.cancel();
    final now = AnalyticsLogger.instance.monoMicros;
    final waited = (now - attempt.sentAtMicros) ~/ 1000;
    if (timedOut) {
      logEvent('safety', 'lock_timeout', {'source': attempt.source.name, 'waited_ms': waited});
      toast('Scooter did not confirm the lock', ToastType.warning);
    } else {
      logEvent('safety', 'lock_rejected', {'source': attempt.source.name, 'took_ms': waited});
      toast('Steering lock failed', ToastType.warning);
    }
    state = state.copyWith(lockFailedAtMicros: () => now);
    _lockFailedTimer?.cancel();
    // The attempt ends with the hold: a "locked" or "lock failed" after it
    // belongs to something else (a key fob, a later press), not this attempt.
    _lockFailedTimer = Timer(lockFailedHold, () {
      if (state.pendingLock == attempt) state = state.copyWith(pendingLock: () => null, lockFailedAtMicros: () => null);
    });
  }

  VehicleData _lockConfirmed(VehicleData next, {bool handlebarFree = false}) {
    final attempt = next.pendingLock;
    if (attempt == null) return next;
    _lockTimer?.cancel();
    _lockFailedTimer?.cancel();
    logEvent('safety', 'lock_confirmed', {
      'source': attempt.source.name,
      'took_ms': (AnalyticsLogger.instance.monoMicros - attempt.sentAtMicros) ~/ 1000,
      'after_failure': next.lockFailedAtMicros != null,
      if (handlebarFree) 'handlebar_free': true,
    });
    // Takes back a "did not confirm" the rider has already seen.
    if (next.lockFailedAtMicros != null) toast('Scooter locked', ToastType.success);
    // ESCL still at 4 after the vehicle locked: the latch holds but the
    // handlebar is free. Warn, don't fail.
    if (handlebarFree) toast('Scooter locked - handlebar still free', ToastType.warning);
    return next.copyWith(pendingLock: () => null, lockFailedAtMicros: () => null);
  }

  /// 3-second debounce mirroring stock HHMIC `VehicleInfoManager.
  /// checkESCL{Lock,Unlock}FailedStatus`. ESCL=2/4 is a transient during the
  /// VCU's retry burst; we only raise the warning if the state is still at
  /// the same failure 3 s later. Clean states (Unlocked/Locked) cancel both
  /// pending debounces and clear any already-shown warning.
  ///
  /// The INITIAL ESCL value of a session is inherited state, not an active
  /// failure — e.g., scooter was locked yesterday with handlebars slightly
  /// off and HHMIS still reports 4 (LOCK_FAIL). Only transitions from a
  /// non-fail state (Unlocked/Locked, or any prior observed value) into 4/2
  /// arm the debounce. Verified against a ride log where a
  /// cold-bind ESCL=4 triggered a confusing "Handlebars not locked" alert
  /// while the scooter was charging and the rider was entering passcode.
  /// But HHMIS may send no ESCL at all until the first lock attempt: on the
  /// one boot the first value was 4 at the rider's lock, with
  /// the scooter unlocked for a minute, and without CTA_IGNORE the VCU took
  /// 9.5 s to lock. A first value while unlocked is a live failure.
  void _esclDebounce(int escl, {required Object? previous, required bool unlocked}) {
    final live = previous != null || unlocked;
    // Stock HHMIC answers every ESCL lock/unlock failure with CTA_IGNORE at
    // once (VehicleInfoManager.updateVehicleESCLLockStatus). Without it the
    // VCU sat in PARK for 6-40 s on a day's rides before locking.
    final failed = escl == HhmisCmd.esclStatusLockFailed || escl == esclStatusUnlockFailed;
    if (failed && live && previous != escl) _sendEsclIgnore(escl, 'escl');
    switch (escl) {
      case esclStatusUnlocked || HhmisCmd.esclStatusLocked:
        _cancelEsclDebounces();
      case HhmisCmd.esclStatusLockFailed:
        _esclUnlockFailDebounce?.cancel();
        _esclUnlockFailDebounce = null;
        if (!live) return;
        if (_esclLockFailDebounce?.isActive ?? false) return;
        _esclLockFailDebounce = Timer(esclFailDebounce, () {
          _esclLockFailDebounce = null;
          if (_lastRaw['INT_VEHICLE_ESCL_STATUS'] != HhmisCmd.esclStatusLockFailed) return;
          if (state.locked || const {0, 2, 4}.contains(_lastRaw['INT_VEHICLE_STATE'])) return;
          logEvent('safety', 'escl_fail_debounced', {'kind': 'lock', 'escl': HhmisCmd.esclStatusLockFailed});
          state = state.copyWith(lockFailedWarning: true);
        });
      case esclStatusUnlockFailed:
        _esclLockFailDebounce?.cancel();
        _esclLockFailDebounce = null;
        if (!live) return;
        if (_esclUnlockFailDebounce?.isActive ?? false) return;
        _esclUnlockFailDebounce = Timer(esclFailDebounce, () {
          _esclUnlockFailDebounce = null;
          if (_lastRaw['INT_VEHICLE_ESCL_STATUS'] != esclStatusUnlockFailed) return;
          if (const {0, 2, 4}.contains(_lastRaw['INT_VEHICLE_STATE'])) return;
          logEvent('safety', 'escl_fail_debounced', {'kind': 'unlock', 'escl': esclStatusUnlockFailed});
          state = state.copyWith(unlockFailedWarning: true);
        });
    }
  }

  void _cancelEsclDebounces() {
    _esclLockFailDebounce?.cancel();
    _esclLockFailDebounce = null;
    _esclUnlockFailDebounce?.cancel();
    _esclUnlockFailDebounce = null;
  }

  void _sendEsclIgnore(int escl, String trigger) {
    logEvent('safety', 'escl_ignore_sent', {'escl': escl, 'trigger': trigger});
    _send('sendIntCmd', {'cmd': HhmisCmd.esclLock, 'value': HhmisCmd.esclIgnoreValue});
  }

  @override
  void openTrunk() {
    if (refuseUnlessStopped(ref, state, 'trunk', 'Stop to open the boot')) return;
    // Don't send unlockSeat while locked. What the VCU
    // does with the command in LOCK is still unknown; the error
    // overlay and safe-mode screen also hide the button in this state.
    if (state.locked) {
      toast('Unlock the scooter to open the boot', ToastType.warning);
      return;
    }
    // Seen on a ride: two taps 157 ms apart sent unlockSeat twice; the
    // trunk status that would have disabled the button came 1.4 s later.
    if (throttled('trunk', trunkThrottle)) return;
    _void(HhmisCmd.unlockSeat, onSent: 'Opening boot');
  }

  /// The seat latch only opens; closing is by hand.
  @override
  void toggleTrunk() {
    if (!state.trunkStateKnown || state.trunkOpen) return;
    openTrunk();
  }

  // The stock PARTY_MODE_*_INDICATOR_ON/OFF commands (35-38)
  // keep the lamp steady - "they won't blink, they just stay on" - and
  // stock has no non-party path for indicators from UI. The control
  // panel buttons are now display-only (see control_panel.dart); the
  // notifier methods are no-ops so an unexpected caller doesn't send a
  // steady-on party command.
  @override
  void toggleLeftIndicator() {}

  @override
  void toggleRightIndicator() {}

  /// HAZARD_LIGHT_TOGGLE carries the target state (1 on, 0 off); HHMIS turns
  /// it into Hazard_Light_Turn_ON/OFF. Like stock HHMIC the state is held
  /// locally and BOOL_HAZARD_LIGHT_PERSIST_TOGGLE_STAT overwrites it. Reading
  /// it off both turn signals sent 1 on every tap: they flash on separate
  /// frames, so they are never true together.
  @override
  void toggleHazard() {
    if (throttled('hazard')) return;
    _setHazard(!hazardOn, onSent: true);
  }

  void _setHazard(bool on, {bool onSent = false}) {
    state = state.copyWith(hazard: on);
    _int(HhmisCmd.hazardToggle, on ? HhmisCmd.hazardOn : HhmisCmd.hazardOff,
        onSent: onSent ? (on ? 'Hazard on' : 'Hazard off') : null);
  }

  /// PARTY_MODE_HIGH_BEAM_ON/OFF drive the lamp directly and HHMIS never
  /// echoes BOOL_HIGH_BEAM_STATUS for them: in one log every tap re-sent
  /// On and the beam stayed lit through lock until a reboot. The dashboard
  /// remembers what it switched on, shows it, and switches it off at LOCK.
  ///
  /// The smart headlight outranks them: once four taps sent
  /// highBeamOff and the beam the VCU had switched on stayed lit. A tap on
  /// a beam it is holding therefore pauses it (47 = 0, which did release the
  /// lamp in that log), and the button is the manual switch until the next
  /// park, lock or long-press.
  @override
  void toggleHighBeam() {
    if (state.smartHeadlight == SmartHeadlight.auto && state.highBeam && !_highBeamOverride) {
      _setSmartHeadlightPaused(true, 'tap');
      // TODO(high-beam): mostly shown on night rides. Once at
      // 38 km/h, 47 = 0 and six highBeamOff left the VCU-held
      // beam lit until the scooter parked, so "it is day" is sent first and
      // the VCU's own day setting puts the beam out. Seen since:
      //  1. pause tap while moving (24 km/h): beam off 0.35 s later.
      //  2. pause tap at a standstill, then a ride: it stayed off.
      //  4. low beam stayed on through all of it.
      // Still to see: 3. after a pause, long-press to resume, moving and
      // stopped (both rides ended the pause by locking), and 1. at speed.
      _send('sendBoolCmd', {'cmd': HhmisCmd.triggerSmartLight, 'value': false});
      _send('sendIntCmd', {'cmd': HhmisCmd.features[RidingFeature.smartHeadlight], 'value': 0});
      _void(HhmisCmd.highBeamOff, onSent: 'Smart headlight paused');
      return;
    }
    final on = !state.highBeam;
    _highBeamOverride = on;
    logEvent('hhmis', 'high_beam_override', {'on': on, 'source': 'tap'});
    state = state.copyWith(highBeam: on || _lastRaw['BOOL_HIGH_BEAM_STATUS'] == true);
    _void(on ? HhmisCmd.highBeamOn : HhmisCmd.highBeamOff, onSent: on ? 'High beam on' : 'High beam off');
    // "High beam off" is what was asked, not what happened: the vehicle
    // keeps the beam when its own headlight logic has it (once,
    // thirteen such toasts with the beam on throughout). Say so.
    _highBeamCheck?.cancel();
    if (!on) {
      _highBeamCheck = Timer(highBeamEcho, () {
        if (_highBeamOverride || _lastRaw['BOOL_HIGH_BEAM_STATUS'] != true) return;
        logEvent('hhmis', 'high_beam_held', {'smart': state.smartHeadlight.name});
        state = state.copyWith(highBeam: true);
        toast('The scooter is keeping the high beam on', ToastType.warning);
      });
    }
  }

  static const highBeamEcho = Duration(seconds: 2);
  Timer? _highBeamCheck;

  @override
  void togglePositionLight() {
    final on = !state.positionLight;
    _void(on ? HhmisCmd.frontDrlOn : HhmisCmd.frontDrlOff);
    // The reported state often does not follow this command (once,
    // parked: three "off" taps, still reported on, three "off" toasts).
    // Say what the scooter reported, not what was asked.
    _positionLightCheck?.cancel();
    _positionLightCheck = Timer(positionLightEcho, () {
      final did = state.positionLight == on;
      logEvent('hhmis', 'position_light_result', {'asked': on, 'did': did});
      did
          ? toast(on ? 'Position light on' : 'Position light off')
          : toast('Position light: scooter did not confirm', ToastType.warning);
    });
  }

  static const positionLightEcho = Duration(milliseconds: 1500);
  Timer? _positionLightCheck;

  /// Drive mode is picked on the switch cube; HHMIS has no ClientCmd for
  /// it, so the ladder must not repaint a mode the VCU is not in.
  @override
  void selectDriveMode(DriveMode mode) {
    if (state.speed > 0) return;
    toast('Mode is on the handlebar switch');
  }

  @override
  void setDriveMode(DriveMode mode) => selectDriveMode(mode);

  @override
  bool get managesSmartHeadlightLocally => false;

  @override
  void sendRegenMode(RegenMode mode) {
    if (mode != RegenMode.standard && !capabilities.regenModes) {
      logEvent('hhmis', 'feature_blocked', {'feature': 'regen', 'value': mode.index});
      return;
    }
    _int(HhmisCmd.regenSettingsUpdate, mode.index);
  }

  @override
  void acceptHillHoldTerms() => _void(HhmisCmd.hillHoldConditionAccepted);

  @override
  void sendAlarmSound(int index) => _int(HhmisCmd.alarmSoundAlert, index);

  @override
  void stopAlarmSound() => _void(HhmisCmd.stopAlarmSound);

  @override
  Future<bool> accidentReply({required bool safe}) async {
    final r = await _send('sendVoidCmd', {'cmd': safe ? HhmisCmd.accidentIAmSafe : HhmisCmd.accidentNeedHelp});
    if (!r.ok) {
      _toastFailure(r);
      return false;
    }
    state = state.copyWith(accidentDetected: false);
    return true;
  }

  @override
  Future<bool> alarmUnlock() async {
    final r = await _send('sendVoidCmd', {'cmd': HhmisCmd.alarmUnlockNow});
    if (!r.ok) _toastFailure(r);
    return r.ok;
  }

  @override
  void sendSafetySensitivity(int level) => _int(HhmisCmd.safetySensitivity, level);

  Timer? _vacationTimer;

  @override
  void enterVacationMode() {
    if (state.hazard) _setHazard(false);
    _vacationTimer?.cancel();
    _vacationTimer = Timer(vacationSendDelay, () => _int(HhmisCmd.features[RidingFeature.vacationMode]!, 1));
  }

  void _onMediaBridge(Map<Object?, Object?> delta) {
    final steps = delta['_volumeMax'];
    if (steps is int && steps > 0) {
      logEvent('media', 'volume_max', {'max': steps});
      if (steps != _volumeSteps) {
        _volumeSteps = steps;
        final index = _volumeIndex;
        if (index != null) state = state.copyWith(volume: volumePercentFor(index, steps));
      }
    }
    final media = delta['_media'];
    if (media is Map) _onMedia(media);
    final call = delta['_call'];
    if (call is Map) _onCall(call);
  }

  /// HHMIS reports the raw STREAM_MUSIC index (`updateInitialSystemVolume`,
  /// `SettingsContentObserver`). The slider is finer than the stream, so
  /// the rider's own value stays while it still means this index.
  int _volumeFromIndex(int index) {
    // A level we did not ask for is the rider on the handlebar or the
    // phone: show it, as stock does (`SettingsInfoManager.updateVolume` ->
    // `showVolumePopup`, 3 s). Once the buttons moved the volume
    // 5 to 14 and the screen showed nothing.
    final external = _volumeIndex != null && index != _volumeIndex && index != _volumeSentIndex;
    if (external) {
      Future.microtask(() {
        if (ref.mounted) onExternalVolume?.call();
      });
    }
    _volumeIndex = index;
    if (index != _volumeSentIndex) _volumeSentIndex = null;
    logEvent('hhmis', 'volume', {'index': index, 'max': _volumeSteps});
    return volumeIndexFor(state.volume, _volumeSteps) == index ? state.volume : volumePercentFor(index, _volumeSteps);
  }

  void _onMedia(Map<Object?, Object?> media) {
    final live = media['connected'] == true;
    if (live != _mediaLive) logEvent('media', 'source', {'live': live});
    _mediaLive = live;
    final was = state.mediaPlaying;
    state = applyMediaUpdate(state, media);
    if (state.mediaPlaying == was) return;
    logEvent('media', 'state', {
      'playing': state.mediaPlaying,
      'has_title': state.songTitle.isNotEmpty,
      'duration_s': state.mediaDuration,
    });
    _report(HhmisCmd.btMediaPlaying, state.mediaPlaying ? 1 : 0);
  }

  void _onCall(Map<Object?, Object?> call) {
    final update = callUpdateFor(call, phase: _callPhase, currentId: _callId);
    if (update == null) return;
    final was = _callPhase;
    _callPhase = update.phase;
    _callId = update.phase == CallPhase.none ? null : update.id;
    logEvent('call', 'state', {
      'from': was.name,
      'to': update.phase.name,
      'active_status': update.activeStatus,
      'call_status': update.callStatus,
    });
    switch (update.phase) {
      case CallPhase.ringing:
        state = state.copyWith(
          callIncoming: true,
          callActive: false,
          callMuted: false,
          callerName: phonebookName,
          callerNumber: update.number,
        );
      case CallPhase.dialing:
        state = state.copyWith(
          callIncoming: false,
          callActive: true,
          callMuted: false,
          callDuration: 0,
          callerName: '',
          callerNumber: update.number,
        );
      case CallPhase.active:
        if (was == CallPhase.none) state = state.copyWith(callerName: '', callerNumber: update.number);
        super.acceptCall();
      case CallPhase.none:
        if (was == CallPhase.ringing) {
          state = state.copyWith(callIncoming: false, callActive: false);
        } else {
          super.endCall();
        }
    }
    _report(HhmisCmd.btCallActiveStatus, update.activeStatus);
    _report(HhmisCmd.callStatus, update.callStatus);
  }

  /// Switch-cube press while HHMIS knows a call is up (`setDepadEvent`):
  /// true answers, false declines or hangs up.
  void _callHandleRequest(bool accept) {
    logEvent('call', 'handle_request', {'accept': accept, 'phase': _callPhase.name});
    if (_callPhase == CallPhase.ringing) {
      accept ? acceptCall() : rejectCall();
    } else if (!accept && _callPhase != CallPhase.none) {
      endCall();
    }
  }

  void _callAction(String action) {
    _invoke('callAction', action).then((ok) => ok == true, onError: (Object _) => false).then((ok) async {
      var via = 'hfp';
      final fallback = callActionFallback;
      // Not for a decline: HSSS's REJECT also texts the caller.
      if (!ok && fallback != null && action != 'reject') {
        via = 'hsss';
        ok = await fallback(action).catchError((Object _) => false);
      }
      logEvent('call', 'action', {'action': action, 'ok': ok, 'phase': _callPhase.name, 'via': via});
      if (!ok) toast("Couldn't $action the call", ToastType.warning);
    });
  }

  /// A status report to HHMIS: logged like any command, but a failure is
  /// not the rider's business.
  void _report(String cmd, int value) => _send('sendIntCmd', {'cmd': cmd, 'value': value});

  /// HHMIS owns the take-me-home state; the mock countdown would clear it.
  @override
  void tickTakeMeHome() {}

  /// The phone moves to the next track on its own; the mock's tick would
  /// send it a "next" at the end of every song.
  @override
  void tickMedia() {
    if (!state.mediaPlaying || state.mediaPosition >= state.mediaDuration) return;
    state = state.copyWith(mediaPosition: state.mediaPosition + 1);
  }

  @override
  void activateReverse() {
    toast(state.movingOrUnknown ? 'Stop to use reverse' : 'Reverse is on the handlebar switch', ToastType.warning);
  }

  @override
  void resetTrip() => _void(HhmisCmd.resetTrip, onSent: 'Trip meter reset');

  /// The limit is stock's hypercharge
  /// limit. It is kept across restarts and sent only while a hyper or boost
  /// charger is connected; [_sendChargeLimitAtHyperStart] sends it when one
  /// starts. VOID_STOP_CHARGE (25) at the limit is not sent: whether the
  /// VCU stops by itself is unanswered.
  @override
  void setChargeLimit(int percent) {
    final limit = percent.clamp(50, 100);
    state = state.copyWith(chargeLimit: limit);
    PrefsService.setInt(PrefsKeys.chargeLimit, limit);
    if (state.hyperCharging) _int(HhmisCmd.chargeLimit, limit);
  }

  @override
  void setVolume(int level, {bool announce = true}) {
    super.setVolume(level, announce: announce);
    final index = volumeIndexFor(state.volume, _volumeSteps);
    if (index == _volumeSentIndex) return;
    _volumeSentIndex = index;
    _cmd('setVolume', index);
  }

  @override
  void setBrightness(int level, {bool persist = true}) =>
      _cmd('setBrightness', {'value': level.clamp(0, 100), 'persist': persist});

  @override
  void setMotorVolume(int level) => _cmd('setMotorVolume', level.clamp(0, 14));

  @override
  void setChimeVolume(int level) => _cmd('setChimeVolume', level.clamp(0, 14));

  @override
  void setSoundMood(int mood) => _int(HhmisCmd.modeUpdate, mood);

  @override
  void setFeature(RidingFeature feature, bool on) {
    if (feature == RidingFeature.smartHeadlight) {
      // The rider's own word, either way: nothing of ours is pending.
      _setSmartOffIsOurs(false);
      _smartHeadlightOn = on;
      _setSmartHeadlightPaused(false, 'setting');
      _syncSmartHeadlight();
      if (on) {
        if (!smartHeadlightTriggerEnabled) return;
        if (_connectedAtMicros != null) {
          _triggerSmartLight('enable');
          return;
        }
      }
    }
    final cmd = HhmisCmd.features[feature];
    if (cmd == null) return;
    // Never switch on something the scooter says it lacks,
    // or that its software has no command for.
    if (on && !capabilities.feature(feature)) {
      logEvent('hhmis', 'feature_blocked', {'feature': feature.name, 'value': 1});
      return;
    }
    _int(cmd, on ? 1 : 0);
  }

  @override
  FutureOr<(bool, int)> verifyPasscode(String pin) => _challenge(pin, verifyOnly: false);

  @override
  FutureOr<bool?> checkPasscode(String pin) async {
    final (ok, remaining) = await _challenge(pin, verifyOnly: true);
    // No-answer is distinct from a wrong PIN; the
    // gate must not spend an attempt on it.
    if (remaining == VehicleNotifier.passcodeNoAnswer) return null;
    return ok;
  }

  @override
  int get passcodeAttemptsRemaining => _attempts;

  @override
  void resetPasscodeAttempts() => _attempts = VehicleNotifier.maxPasscodeAttempts;

  /// HPMS answers with BOOL_PROFILE_PASSCODE_CHANGED_ACK; nothing is
  /// "updated" until it does. True only on a positive ack.
  @override
  Future<bool> changePasscode(String pin) async {
    _finishPasscodeChange(null);
    final completer = Completer<bool?>();
    _pendingPasscodeChange = completer;
    final sent = await _send('sendStringCmd', {'cmd': HhmisCmd.passcodeChange, 'value': pin});
    if (!sent.ok) {
      _finishPasscodeChange(null);
      _toastFailure(sent);
      return false;
    }
    if (identical(_pendingPasscodeChange, completer)) {
      _passcodeChangeTimer = Timer(passcodeChangeTimeout, () => _finishPasscodeChange(null));
    }
    final ack = await completer.future;
    logEvent('safety', 'passcode_change_result', {'ack': ack});
    switch (ack) {
      case true:
        toast('Passcode updated', ToastType.success);
      case false:
        toast('Change failed', ToastType.warning);
      case null:
        toast('No confirmation — try again', ToastType.warning);
    }
    return ack == true;
  }

  void _finishPasscodeChange(bool? ack) {
    _passcodeChangeTimer?.cancel();
    _passcodeChangeTimer = null;
    final c = _pendingPasscodeChange;
    _pendingPasscodeChange = null;
    if (c != null && !c.isCompleted) c.complete(ack);
  }

  Future<(bool, int)> _challenge(String pin, {required bool verifyOnly}) {
    _finishPasscode(false, _attempts);
    final completer = Completer<(bool, int)>();
    _pendingPasscode = completer;
    _passcodeSentMicros = AnalyticsLogger.instance.monoMicros;
    _send(
      'verifyPasscode',
      {'code': pin, 'verifyOnly': verifyOnly},
      describe: {'cmd': null, 'name': 'verifyPasscode', 'type': 'passcode', 'value': null, 'verify_only': verifyOnly},
    ).then((sent) {
      if (!sent.ok) {
        toast("Couldn't reach the scooter, try again", ToastType.warning);
        _finishPasscode(false, VehicleNotifier.passcodeNoAnswer);
        return;
      }
      if (identical(_pendingPasscode, completer)) {
        _passcodeTimer = Timer(passcodeTimeout, () => _passcodeNoAnswer(completer));
      }
    });
    return completer.future;
  }

  /// Seen once: stock HHMIC, alive for the first seconds after an
  /// install, held HHMIS's single callback slot: the scooter unlocked on the
  /// rider's correct PIN, HHMIS told HHMIC, and the lock screen called it
  /// wrong. No answer is not a wrong PIN, and it means the slot is probably
  /// gone, so take it back now rather than after the 12 s staleness window.
  // TODO(passcode-no-answer): "the slot is probably gone" is inferred from one install. Check each
  // safety.passcode_no_answer in a log: was a reattach needed, and did it bring the answer?
  void _passcodeNoAnswer(Completer<(bool, int)> completer) {
    if (!identical(_pendingPasscode, completer)) return;
    logEvent('safety', 'passcode_no_answer', {});
    toast("Scooter didn't answer, try again", ToastType.warning);
    _finishPasscode(false, VehicleNotifier.passcodeNoAnswer);
    _checkStaleness(threshold: passcodeStaleness);
  }

  void _finishPasscode(bool ok, int remaining) {
    _passcodeTimer?.cancel();
    _passcodeTimer = null;
    final c = _pendingPasscode;
    _pendingPasscode = null;
    if (c != null) passcodeUnanswered.value = !ok && remaining == VehicleNotifier.passcodeNoAnswer;
    if (c != null && !c.isCompleted) c.complete((ok, remaining));
  }

  @override
  void confirmPairing() {
    if (state.btPairingCode.isEmpty) return;
    state = state.copyWith(btPairingCode: '');
    _bool(HhmisCmd.blePairStat, true);
  }

  @override
  void cancelPairing() {
    if (state.btPairingCode.isEmpty) return;
    state = state.copyWith(btPairingCode: '');
    _bool(HhmisCmd.blePairStat, false);
  }

  // No local guess at the playing state: it follows the phone's own
  // session (`_media`), so the bar never shows what the phone is not doing.
  @override
  void mediaPlay() => _cmd('mediaKey', 'play');

  @override
  void mediaPause() => _cmd('mediaKey', 'pause');

  @override
  bool get callMuteSupported => false;

  @override
  void acceptCall() => _callAction('accept');

  @override
  void rejectCall() => _callAction('reject');

  @override
  void endCall() => _callAction('end');

  @override
  void toggleCallMute() {}

  @override
  void mediaNext() => _cmd('mediaKey', 'next');

  @override
  void mediaPrev() => _cmd('mediaKey', 'prev');

  // The link flags, signal and Bluetooth identity
  // come from SystemStatus.kt. The mock setters must not overwrite them
  // (the Bluetooth one also invented a connected phone).
  @override
  void setWifi(bool on) {}

  @override
  void setSignalBars(int bars) {}

  @override
  void setGps(bool on) {}

  @override
  void setBtConnected(bool on, {String? name}) {}

  @override
  void disconnectBt() {}

  @override
  void simulateBoot() {}

  /// The bell on the scooter belongs to real news (`bellProvider`); the
  /// simulated update of the mock build must not light it.
  @override
  void setNotification(bool on) {}

  @override
  void setStockAutoDownload(int? value) {}

  @override
  Future<bool> sendStockAutoDownload(int value) async =>
      (await _send('sendIntCmd', {'cmd': HhmisCmd.autoDownloadUpdate, 'value': value == 0 ? 0 : 1})).ok;

  @override
  Future<bool> checkFirmwareUpdate() async => (await _send(
        'checkFirmwareUpdate',
        null,
        describe: const {'cmd': HhmisCmd.checkForUpdate, 'name': 'checkForUpdate', 'type': 'void', 'value': null},
      ))
          .ok;

  @override
  Future<bool> subscribeFirmware() async {
    try {
      return await _invoke('subscribeFirmware', null) == true;
    } catch (e) {
      debugPrint('[AIDL] subscribeFirmware failed: $e');
      return false;
    }
  }

  @override
  void dropConnection() {}

  @override
  void setConnected(bool on) {}
}
