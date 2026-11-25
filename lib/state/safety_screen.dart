import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vehicle_data.dart';
import '../providers/mock_provider.dart';
import '../services/analytics_logger.dart';
import 'screen_state.dart';
import 'toast_state.dart';

/// Stock's `TamperFallStatus` screens plus its ALARM vehicle state. Stock
/// keeps one integer, last writer wins (1 tamper, 2 fall, 3 accident). Here
/// the accident screen wins while it is unanswered, because it is the only
/// one with a reply; then fall; then the alarm.
enum SafetyScreen { accident, fall, alarm }

class SafetyScreenState {
  const SafetyScreenState({this.screen, this.busy = false});
  final SafetyScreen? screen;

  /// A reply or an unlock is on its way; the buttons wait for it.
  final bool busy;
}

final safetyScreenProvider =
    NotifierProvider<SafetyScreenNotifier, SafetyScreenState>(SafetyScreenNotifier.new);

class SafetyScreenNotifier extends Notifier<SafetyScreenState> {
  /// Stock `VehicleInfoManager.setAccidentSeverityStatus` posts the screen
  /// switch 200 ms after the status arrives.
  static const accidentDelay = Duration(milliseconds: 200);

  /// Ours: how long Unlock waits for the vehicle to leave ALARM before the
  /// alarm screen steps aside for the passcode keypad. Stock has no way out
  /// of its alarm screen but the state change.
  static const unlockWait = Duration(seconds: 5);

  Timer? _accidentTimer;
  Timer? _unlockTimer;
  int? _unlockSentMicros;
  bool _accidentUp = false;
  bool _keypad = false;
  bool _busy = false;

  @override
  SafetyScreenState build() {
    ref.onDispose(() {
      _accidentTimer?.cancel();
      _unlockTimer?.cancel();
    });
    ref.listen(vehicleProvider.select(_flags), _onFlags);
    // Already up when the app starts (ALARM survives a restart): no delay.
    _accidentUp = ref.read(vehicleProvider).accidentDetected;
    return _resolve();
  }

  static (bool, bool, bool, bool, bool) _flags(VehicleData v) =>
      (v.accidentDetected, v.fallDetected, v.tamperDetected, v.alarmActive, v.locked);

  void _onFlags((bool, bool, bool, bool, bool)? prev, (bool, bool, bool, bool, bool) next) {
    final (accident, fall, tamper, alarm, _) = next;
    final (wasAccident, wasFall, wasTamper, wasAlarm, _) = prev ?? (false, false, false, false, false);
    final v = ref.read(vehicleProvider);
    if (accident && !wasAccident) {
      // HHMIS reduces the VCU's severity enum to this one boolean.
      logEvent('safety', 'accident', {'severity': null, 'speed': v.speed, 'state': v.vehicleState.name});
      _accidentTimer?.cancel();
      _accidentTimer = Timer(accidentDelay, () {
        _accidentUp = true;
        _update();
      });
    } else if (!accident && wasAccident) {
      _accidentTimer?.cancel();
      _accidentUp = false;
    }
    if (fall && !wasFall) logEvent('safety', 'fall', {'speed': v.speed, 'state': v.vehicleState.name});
    if (alarm != wasAlarm) {
      logEvent('safety', 'alarm', {'on': alarm, 'tamper': tamper});
      if (!alarm) _unlockSettled('unlocked');
    }
    // A new alarm or alert brings the screen back over the keypad.
    if ((alarm && !wasAlarm) || (tamper && !wasTamper)) _keypad = false;
    if (!alarm && !tamper) _keypad = false;
    _update();
  }

  SafetyScreenState _resolve() {
    final v = ref.read(vehicleProvider);
    final screen = _accidentUp && v.accidentDetected
        ? SafetyScreen.accident
        : v.fallDetected
            ? SafetyScreen.fall
            // Ours: a tow/theft alert on an unlocked scooter is out of
            // place (the VCU raises it while locked), and it must not cover
            // the cluster of a scooter that may be moving. The banner and
            // the telltale still show it.
            : (v.alarmActive || (v.tamperDetected && v.locked)) && !_keypad
                ? SafetyScreen.alarm
                : null;
    return SafetyScreenState(screen: screen, busy: _busy);
  }

  void _update() {
    final next = _resolve();
    if (next.screen == state.screen && next.busy == state.busy) return;
    if (next.screen != null && next.screen != state.screen) {
      logModalShow('safety_${next.screen!.name}');
      if (ref.read(sessionProvider).asleep) ref.read(sessionProvider.notifier).wake();
    }
    state = next;
  }

  /// "I'm safe" / "Get help". One command per answer; the screen closes
  /// when the bridge has taken it.
  Future<void> reply({required bool safe}) async {
    if (state.screen != SafetyScreen.accident || _busy) return;
    _busy = true;
    _update();
    final sent = await ref.read(vehicleProvider.notifier).accidentReply(safe: safe);
    logEvent('safety', 'accident_reply', {'reply': safe ? 'safe' : 'help', 'sent': sent});
    _busy = false;
    if (sent) {
      // Stock's "Alert deactivated". Its "Our team will get in touch with
      // you shortly" belongs to the cloud alert stock HHMIC raises through
      // HPMS (`sendAccidentAlerttoCCM`), which this dashboard does not send.
      ref.read(toastProvider.notifier).show(
            safe ? 'Alert deactivated' : 'Help request sent to the scooter. Call $emergencyNumber in an emergency',
            type: ToastType.success,
            duration: safe ? null : const Duration(seconds: 6),
          );
    }
    _update();
  }

  /// The alarm screen's Unlock. Stock sends ALARM_UNLOCK_NOW with no
  /// passcode step of its own (`SettingsInfoManager.handleMessage`
  /// ACTION_ALARM_UNLOCKSCOOTER), so there is none here.
  Future<void> unlock() async {
    if (state.screen != SafetyScreen.alarm || _busy) return;
    _busy = true;
    _update();
    final vehicle = ref.read(vehicleProvider.notifier);
    final inAlarm = ref.read(vehicleProvider).alarmActive;
    _unlockSentMicros = AnalyticsLogger.instance.monoMicros;
    final sent = await vehicle.alarmUnlock();
    if (!sent) {
      _unlockSettled('send_failed', keypad: true);
    } else if (!inAlarm) {
      // A tow/theft alert outside ALARM: no state change will end it.
      vehicle.dismissTamper();
      _unlockSettled('dismissed');
    } else if (ref.read(vehicleProvider).alarmActive) {
      _unlockTimer?.cancel();
      _unlockTimer = Timer(unlockWait, () => _unlockSettled('no_change', keypad: true));
    }
    _update();
  }

  void _unlockSettled(String result, {bool keypad = false}) {
    final sentAt = _unlockSentMicros;
    if (sentAt == null) return;
    _unlockSentMicros = null;
    _unlockTimer?.cancel();
    _unlockTimer = null;
    _busy = false;
    logEvent('safety', 'alarm_unlock', {
      'result': result,
      'took_ms': (AnalyticsLogger.instance.monoMicros - sentAt) ~/ 1000,
      'state': ref.read(vehicleProvider).vehicleState.name,
    });
    if (keypad) {
      _keypad = true;
      if (result == 'no_change') {
        ref.read(toastProvider.notifier).show('Enter the passcode to unlock', type: ToastType.warning);
      }
    }
    _update();
  }
}
