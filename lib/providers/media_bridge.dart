import 'dart:async';

import 'package:flutter/services.dart';

import '../models/vehicle_data.dart';
import '../services/analytics_logger.dart';

/// Dart end of `MediaBridge.kt`: the phone's music and calls as the head
/// unit's Bluetooth stack reports them, and the STREAM_MUSIC step count.
/// Its batches carry only [keys], on their own channel, and are merged into
/// the vehicle event stream so the notifier has one input.
abstract final class MediaBridge {
  static const _events = EventChannel('in.abhijithvijayan.opendash.media/events');
  static const _commands = MethodChannel('in.abhijithvijayan.opendash.media/commands');

  static const keys = {'_media', '_call', '_volumeMax'};
  static const methods = {'callAction'};

  static Stream<dynamic> events() => _events.receiveBroadcastStream();

  static Future<Object?> invoke(String method, Object? args) => _commands.invokeMethod<Object?>(method, args);

  /// [vehicle] with [media] folded in. A media channel error is logged and
  /// dropped: the notifier reads any stream error as HHMIS going away.
  static Stream<dynamic> merge(Stream<dynamic> vehicle, Stream<dynamic> media) {
    late final StreamController<dynamic> out;
    StreamSubscription<dynamic>? a;
    StreamSubscription<dynamic>? b;
    out = StreamController<dynamic>(
      onListen: () {
        a = vehicle.listen(out.add, onError: out.addError);
        b = media.listen(out.add, onError: (Object e) => logEvent('media', 'channel_error', {'error': e.toString()}));
      },
      onCancel: () async {
        await a?.cancel();
        await b?.cancel();
      },
    );
    return out.stream;
  }
}

/// AOSP's STREAM_MUSIC step count, used until the bridge reports the head
/// unit's own. HHMIS scales its RING and CALL streams by 6.66 (= 100 / 15),
/// which points at the same number.
const defaultVolumeSteps = 15;

/// HHMIS `updateVolume` hands the value to HSSS unscaled, and HSSS drops
/// anything above `getStreamMaxVolume` without a word
/// (`VolumeSettingsRepository.setVolume`), so the slider's 0-100 has to
/// become a stream index on the way out and back.
int volumeIndexFor(int percent, int steps) => (percent.clamp(0, 100) * steps / 100).round();

int volumePercentFor(int index, int steps) => steps <= 0 ? 0 : (index.clamp(0, steps) * 100 / steps).round();

/// One `_media` map applied to the now-playing fields. AVRCP on this stack
/// carries no cover art, so the note icon stands in.
VehicleData applyMediaUpdate(VehicleData v, Map<Object?, Object?> m) {
  if (m['connected'] != true) {
    return v.copyWith(mediaPlaying: false, songTitle: '', songArtist: '', albumArt: '', mediaPosition: 0, mediaDuration: 0);
  }
  final title = m['title'] is String ? m['title'] as String : '';
  final artist = m['artist'] is String ? m['artist'] as String : '';
  final durationMs = m['durationMs'] is num ? (m['durationMs'] as num).toInt() : 0;
  final positionMs = m['positionMs'] is num ? (m['positionMs'] as num).toInt() : -1;
  final duration = durationMs > 0 ? durationMs ~/ 1000 : 0;
  final newTrack = title != v.songTitle || artist != v.songArtist;
  var position = positionMs >= 0 ? positionMs ~/ 1000 : (newTrack ? 0 : v.mediaPosition);
  if (duration > 0 && position > duration) position = duration;
  return v.copyWith(
    mediaPlaying: m['playing'] == true,
    songTitle: title,
    songArtist: artist,
    albumArt: '',
    mediaPosition: position,
    mediaDuration: duration,
  );
}

enum CallPhase { none, ringing, dialing, active }

/// A change of [CallPhase] and what stock HHMIC tells HHMIS at that point:
/// [activeStatus] for ClientCmd 14 `INT_BT_CALL_ACTIVE_STATUS` and
/// [callStatus] for ClientCmd 61 `CALL_STATUS`.
typedef CallUpdate = ({CallPhase phase, int id, String number, int activeStatus, int callStatus});

/// `BluetoothHeadsetClientCall` states, as `MediaBridge.kt` forwards them.
abstract final class HfpCall {
  static const active = 0;
  static const dialing = 2;
  static const alerting = 3;
  static const incoming = 4;
  static const waiting = 5;
  static const terminated = 7;

  /// The HFP link itself went away; whatever call was up is over.
  static const linkLost = -1;
}

/// Maps one `_call` map onto a phase change, or null when it changes
/// nothing: a second call while one is up, a hold, a repeat of the phase,
/// or the end of a call we never saw start.
///
/// The values are stock's (HHMIC `TelephonyInfoManager`): cmd 14 is 1 for a
/// ringing call (0 when the phone rings in-band, so HHMIS skips its own
/// chime), 2 once answered, 4 dialling, 5 once the other side answers,
/// 6 when over; cmd 61 is 1 ringing, 3 answered, 2 outgoing, 4 over. HHMIS
/// ducks the motor sound on 2/4/5 and restores it on 6, and while a call
/// is up it turns switch-cube presses into `BOOL_BT_CALL_HANDLE_REQUEST`
/// (`IClientServiceInterfaceBuilder$1.onIntegerHMICmd`,
/// `VehicleManager.checkBtCallStatus`).
CallUpdate? callUpdateFor(Map<Object?, Object?> m, {required CallPhase phase, required int? currentId}) {
  final state = m['state'];
  final id = m['id'] is int ? m['id'] as int : 0;
  if (state is! int) return null;
  final number = m['number'] is String ? m['number'] as String : '';
  final outgoing = m['outgoing'] == true;
  if (phase != CallPhase.none && id != HfpCall.linkLost && currentId != null && id != currentId) return null;
  final CallUpdate? next = switch (state) {
    HfpCall.incoming || HfpCall.waiting => (
        phase: CallPhase.ringing,
        id: id,
        number: number,
        activeStatus: m['inBand'] == true ? 0 : 1,
        callStatus: 1,
      ),
    HfpCall.dialing || HfpCall.alerting => (phase: CallPhase.dialing, id: id, number: number, activeStatus: 4, callStatus: 2),
    HfpCall.active => (
        phase: CallPhase.active,
        id: id,
        number: number,
        activeStatus: outgoing ? 5 : 2,
        callStatus: outgoing ? 2 : 3,
      ),
    HfpCall.terminated => (phase: CallPhase.none, id: id, number: number, activeStatus: 6, callStatus: 4),
    _ => null,
  };
  if (next == null || next.phase == phase) return null;
  return next;
}
