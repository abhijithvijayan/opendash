import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/models/app_catalog.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/media_state.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/toast_state.dart';

void main() {
  void withMedia(void Function(FakeAsync async, ProviderContainer c, VehicleNotifier v) body) {
    fakeAsync((async) {
      final c = ProviderContainer();
      c.listen(sessionProvider, (_, _) {});
      c.listen(btWatcherProvider, (_, _) {});
      c.listen(btScreenOpenProvider, (_, _) {});
      c.listen(volumeOverlayProvider, (_, _) {});
      c.listen(toastProvider, (_, _) {});
      final v = c.read(vehicleProvider.notifier);
      v.setConnected(true);
      v.setLocked(false);
      body(async, c, v);
      c.dispose();
    });
  }

  VehicleData read(ProviderContainer c) => c.read(vehicleProvider);
  String? toast(ProviderContainer c) => c.read(toastProvider)?.message;

  group('media', () {
    test('new fields round-trip through copyWith and equality', () {
      const v = VehicleData();
      final n = v.copyWith(
        albumArt: 'x', mediaPosition: 10, mediaDuration: 200, volume: 70,
        musicOnSpeaker: true, callIncoming: true, callMuted: true, callDuration: 5,
        btDeviceName: 'phone', scooterBtName: 'scoot',
      );
      expect(n.volume, 70);
      expect(n.btDeviceName, 'phone');
      expect(n, isNot(v));
      expect(n, n.copyWith());
      expect(v.volume, 50);
      expect(v.scooterBtName, 'S1Pro-2408');
    });

    // The BT flag stayed false with music playing, so the
    // bar no longer waits for it.
    test('mediaVisible follows playing, whatever the BT flag says', () {
      expect(const VehicleData(mediaPlaying: true).mediaVisible, isTrue);
      expect(const VehicleData(mediaPlaying: true, btConnected: true).mediaVisible, isTrue);
      expect(const VehicleData(btConnected: true).mediaVisible, isFalse);
    });

    test('next and prev cycle the track list and wrap', () {
      withMedia((async, c, v) {
        v.setMediaPlaying(true);
        expect(read(c).songTitle, 'Nightcall');
        for (var i = 1; i < VehicleNotifier.tracks.length; i++) {
          v.mediaNext();
          expect(read(c).songTitle, VehicleNotifier.tracks[i].$1);
        }
        v.mediaNext();
        expect(read(c).songTitle, 'Nightcall', reason: '5 -> 1');
        v.mediaPrev();
        expect(read(c).songTitle, 'Midnight City', reason: '1 -> 5');
        expect(toast(c), 'Midnight City');
      });
    });

    test('play and pause update state and toast', () {
      withMedia((async, c, v) {
        v.mediaPlay();
        expect(read(c).mediaPlaying, isTrue);
        expect(read(c).btConnected, isTrue);
        expect(toast(c), 'Playing');
        v.mediaPause();
        expect(read(c).mediaPlaying, isFalse);
        expect(toast(c), 'Paused');
      });
    });

    test('volume clamps and announces', () {
      withMedia((async, c, v) {
        v.setVolume(140);
        expect(read(c).volume, 100);
        expect(toast(c), 'Volume: 100%');
        v.setVolume(-5, announce: false);
        expect(read(c).volume, 0);
        v.toggleMusicOnSpeaker();
        expect(read(c).musicOnSpeaker, isTrue);
      });
    });

    test('volume overlay auto-dismisses after 3s idle, with no toast: the slider showed the level', () {
      withMedia((async, c, v) {
        final overlay = c.read(volumeOverlayProvider.notifier);
        overlay.open();
        expect(c.read(volumeOverlayProvider), isTrue);
        overlay.setLevel(60);
        expect(toast(c), isNull, reason: 'no toast while the slider is open');
        async.elapse(const Duration(milliseconds: 2500));
        overlay.setLevel(65);
        async.elapse(const Duration(milliseconds: 2500));
        expect(c.read(volumeOverlayProvider), isTrue, reason: 'interaction restarted the clock');
        async.elapse(const Duration(milliseconds: 600));
        expect(c.read(volumeOverlayProvider), isFalse);
        expect(read(c).volume, 65);
        expect(toast(c), isNull);
      });
    });

    test('a level changed on the handlebar shows the popup for 3 s, riding too, and closes without a toast', () {
      withMedia((async, c, v) {
        final overlay = c.read(volumeOverlayProvider.notifier);
        v.setSpeed(40);
        async.elapse(VolumeOverlayState.blockAfterChange);
        overlay.flash();
        expect(c.read(volumeOverlayProvider), isTrue);
        async.elapse(const Duration(milliseconds: 2000));
        overlay.flash();
        async.elapse(const Duration(milliseconds: 2000));
        expect(c.read(volumeOverlayProvider), isTrue, reason: 'each step restarts the clock');
        async.elapse(const Duration(milliseconds: 1100));
        expect(c.read(volumeOverlayProvider), isFalse);
        expect(toast(c), isNull, reason: 'the popup already said it');
      });
    });

    test('no popup for 1.5 s after an unlock: the volume HHMIS re-reports then is not the rider\'s', () {
      withMedia((async, c, v) {
        final overlay = c.read(volumeOverlayProvider.notifier);
        v.setLocked(true);
        async.elapse(VolumeOverlayState.blockAfterChange);
        v.setLocked(false);
        async.elapse(const Duration(milliseconds: 650));
        overlay.flash();
        expect(c.read(volumeOverlayProvider), isFalse, reason: '12 to 7, 650 ms after the passcode');
        async.elapse(VolumeOverlayState.blockAfterChange);
        overlay.flash();
        expect(c.read(volumeOverlayProvider), isTrue, reason: 'a real press afterwards still shows');
        async.elapse(const Duration(seconds: 4));
      });
    });

    test('no popup while locked, nor while a phone that has just connected sets its own volume', () {
      withMedia((async, c, v) {
        final overlay = c.read(volumeOverlayProvider.notifier);
        async.elapse(VolumeOverlayState.blockAfterChange);
        v.setBtConnected(true);
        async.flushMicrotasks();
        overlay.flash();
        expect(c.read(volumeOverlayProvider), isFalse, reason: 'the stream is re-reported on connect');
        // The phone's own level arrived 3.3 s after it connected,
        // when its music started, and the bar came up by itself.
        async.elapse(const Duration(milliseconds: 3300));
        overlay.flash();
        expect(c.read(volumeOverlayProvider), isFalse, reason: 'the phone setting its level, not the rider');
        async.elapse(VolumeOverlayState.blockAfterConnect);
        overlay.flash();
        expect(c.read(volumeOverlayProvider), isTrue);
        overlay.dismiss();
        v.setLocked(true);
        async.elapse(VolumeOverlayState.blockAfterChange);
        overlay.flash();
        expect(c.read(volumeOverlayProvider), isFalse);
      });
    });

    test('volume overlay refuses to open while riding', () {
      withMedia((async, c, v) {
        v.setSpeed(20);
        c.read(volumeOverlayProvider.notifier).open();
        expect(c.read(volumeOverlayProvider), isFalse);
      });
    });
  });

  group('calls', () {
    test('incoming -> accept -> duration counts -> mute -> end', () {
      withMedia((async, c, v) {
        v.simulateIncomingCall();
        expect(read(c).callIncoming, isTrue);
        expect(read(c).callerLabel, 'Rahul');
        v.acceptCall();
        expect(read(c).callActive, isTrue);
        expect(read(c).callIncoming, isFalse);
        expect(toast(c), 'Call connected');
        async.elapse(const Duration(seconds: 3));
        expect(read(c).callDuration, 3);
        v.toggleCallMute();
        expect(read(c).callMuted, isTrue);
        expect(toast(c), 'Muted');
        v.endCall();
        expect(read(c).callActive, isFalse);
        expect(read(c).callDuration, 0);
        expect(read(c).callMuted, isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(read(c).callDuration, 0, reason: 'timer stopped');
        expect(toast(c), 'Call ended');
      });
    });

    test('reject clears the incoming call', () {
      withMedia((async, c, v) {
        v.simulateIncomingCall();
        v.rejectCall();
        expect(read(c).callIncoming, isFalse);
        expect(read(c).callActive, isFalse);
        expect(toast(c), 'Call rejected');
      });
    });

    test('caller label falls back to number, then Unknown', () {
      expect(const VehicleData(callerNumber: '123').callerLabel, '123');
      expect(const VehicleData().callerLabel, 'Unknown');
    });
  });

  group('bluetooth', () {
    test('connect and disconnect toasts fire on transitions only', () {
      withMedia((async, c, v) {
        v.setBtConnected(true);
        expect(toast(c), "Bluetooth connected: Rahul's iPhone");
        c.read(toastProvider.notifier).dismiss();
        v.setBtConnected(true);
        expect(toast(c), isNull, reason: 'no transition');
        v.setMediaPlaying(true);
        v.setBtConnected(false);
        expect(toast(c), 'Bluetooth disconnected');
        expect(c.read(toastProvider)!.type, ToastType.warning);
        expect(read(c).mediaPlaying, isFalse);
        expect(read(c).songTitle, isEmpty);
        expect(read(c).btDeviceName, isEmpty);
      });
    });

    // Wireless CarPlay connected over Bluetooth, let it go for
    // Wi-Fi five seconds later, and the island warned "Bluetooth
    // disconnected" over a CarPlay that was working.
    test('no disconnect warning while a projection app is in front', () {
      withMedia((async, c, v) {
        final carplay = appCatalog.firstWhere((a) => a.projection);
        v.setBtConnected(true);
        c.read(toastProvider.notifier).dismiss();
        c.read(outsideAppProvider.notifier).set(carplay);
        v.setBtConnected(false);
        expect(toast(c), isNull);
        expect(AnalyticsLogger.instance.recent('bt', 'disconnect_quiet').single['data'], {'reason': 'projection'});
        c.read(outsideAppProvider.notifier).set(null);
        v.setBtConnected(true);
        c.read(toastProvider.notifier).dismiss();
        v.setBtConnected(false);
        expect(toast(c), 'Bluetooth disconnected', reason: 'on the dashboard it is still said');
        expect(c.read(toastProvider)!.type, ToastType.info, reason: 'nothing was playing: said, not warned');
        c.read(toastProvider.notifier).dismiss();

        // CarPlay left behind the dashboard, its way back still offered.
        v.setBtConnected(true);
        c.read(toastProvider.notifier).dismiss();
        c.read(projectionResumeProvider.notifier).offer(carplay);
        v.setBtConnected(false);
        expect(toast(c), isNull);
      });
    });

    test('BT screen opens when parked and closes when riding starts', () {
      withMedia((async, c, v) {
        final screen = c.read(btScreenOpenProvider.notifier);
        screen.open();
        expect(c.read(btScreenOpenProvider), isTrue);
        v.setSpeed(15);
        expect(c.read(btScreenOpenProvider), isFalse);
        screen.open();
        expect(c.read(btScreenOpenProvider), isFalse, reason: 'locked out while riding');
        v.setSpeed(0);
        screen.open();
        expect(c.read(btScreenOpenProvider), isTrue);
        v.setCharging(true);
        expect(c.read(btScreenOpenProvider), isFalse, reason: 'screen change closes it');
      });
    });
  });
}
