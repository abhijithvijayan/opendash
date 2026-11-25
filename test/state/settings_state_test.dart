import 'package:fake_async/fake_async.dart';
import 'package:material_ui/material_ui.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/passcode_state.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/sound_settings.dart';
import 'package:opendash/state/toast_state.dart';

void main() {
  void withApp(void Function(FakeAsync async, ProviderContainer c, VehicleNotifier v) body) {
    fakeAsync((async) {
      final c = ProviderContainer();
      for (final p in [
        sessionProvider, settingsScreenOpenProvider, changePasscodeOpenProvider,
        changePasscodeProvider, tripResetProvider, toastProvider, passcodeProvider,
      ]) {
        c.listen(p, (_, _) {});
      }
      final v = c.read(vehicleProvider.notifier);
      v.setConnected(true);
      v.setLocked(false);
      body(async, c, v);
      c.dispose();
    });
  }

  String? toast(ProviderContainer c) => c.read(toastProvider)?.message;

  group('settings screen', () {
    test('opens when parked, refuses and auto-closes while riding', () {
      withApp((async, c, v) {
        final s = c.read(settingsScreenOpenProvider.notifier);
        s.open();
        expect(c.read(settingsScreenOpenProvider), isTrue);
        v.setSpeed(10);
        expect(c.read(settingsScreenOpenProvider), isFalse);
        s.open();
        expect(c.read(settingsScreenOpenProvider), isFalse);
      });
    });

    test('closes on lock and sleep, not when the charger state flips', () {
      withApp((async, c, v) {
        final s = c.read(settingsScreenOpenProvider.notifier);
        s.open();
        v.setCharging(true);
        v.setCharging(false);
        v.setCharging(true);
        expect(c.read(settingsScreenOpenProvider), isTrue, reason: 'HHMIS charge state flaps; the rider stays in Settings');
        v.setCharging(false);
        s.open();
        v.setLocked(true);
        expect(c.read(settingsScreenOpenProvider), isFalse);
        v.setLocked(false);
        s.open();
        c.read(sessionProvider.notifier).sleep();
        expect(c.read(settingsScreenOpenProvider), isFalse);
      });
    });

    test('back closes the change passcode sub-screen too', () {
      withApp((async, c, v) {
        c.read(settingsScreenOpenProvider.notifier).open();
        c.read(changePasscodeOpenProvider.notifier).open();
        c.read(settingsScreenOpenProvider.notifier).close();
        expect(c.read(changePasscodeOpenProvider), isFalse);
      });
    });

    test('section, brightness and auto dark mode store values', () {
      withApp((async, c, v) {
        c.read(settingsSectionProvider.notifier).set(SettingsSection.sound);
        expect(c.read(settingsSectionProvider), SettingsSection.sound);
        c.read(brightnessProvider.notifier).set(140);
        expect(c.read(brightnessProvider), 100);
        c.read(brightnessProvider.notifier).set(35);
        expect(c.read(brightnessProvider), 35);
        final adm = c.read(autoDarkModeProvider.notifier);
        adm.setEnabled(true);
        expect(toast(c), 'Auto dark mode enabled');
        adm.setDarkAfter(const TimeOfDay(hour: 19, minute: 0));
        expect(c.read(autoDarkModeProvider).darkAfter, const TimeOfDay(hour: 19, minute: 0));
        expect(c.read(autoDarkModeProvider).lightAfter, const TimeOfDay(hour: 6, minute: 30));
      });
    });
  });

  group('trip reset', () {
    test('cancel keeps the trip, confirm clears it with a toast', () {
      withApp((async, c, v) {
        final before = c.read(vehicleProvider).tripMeter;
        expect(before, greaterThan(0));
        final popup = c.read(tripResetProvider.notifier);
        popup.open();
        expect(c.read(tripResetProvider), isTrue);
        popup.cancel();
        expect(c.read(vehicleProvider).tripMeter, before);
        popup.open();
        popup.confirm();
        expect(c.read(vehicleProvider).tripMeter, 0);
        expect(toast(c), 'Trip meter reset');
        expect(c.read(tripResetProvider), isFalse);
      });
    });

    test('hidden while riding', () {
      withApp((async, c, v) {
        c.read(tripResetProvider.notifier).open();
        v.setSpeed(12);
        expect(c.read(tripResetProvider), isFalse);
        c.read(tripResetProvider.notifier).open();
        expect(c.read(tripResetProvider), isFalse);
      });
    });
  });

  group('change passcode', () {
    void enter(ProviderContainer c, String pin) {
      for (final ch in pin.split('')) {
        c.read(changePasscodeProvider.notifier).enterDigit(int.parse(ch));
      }
    }

    test('verify -> new -> confirm updates the passcode and the lock screen accepts it', () {
      withApp((async, c, v) {
        c.read(settingsScreenOpenProvider.notifier).open();
        c.read(changePasscodeOpenProvider.notifier).open();
        expect(c.read(changePasscodeProvider).step, PasscodeStep.verify);
        enter(c, '123456');
        expect(c.read(changePasscodeProvider).step, PasscodeStep.create);
        enter(c, '258025');
        expect(c.read(changePasscodeProvider).step, PasscodeStep.confirm);
        expect(c.read(changePasscodeProvider).newPasscode, '258025');
        enter(c, '258025');
        expect(c.read(changePasscodeProvider).lastResult, ChangePasscodeResult.success);
        expect(toast(c), 'Passcode updated');
        expect(c.read(changePasscodeOpenProvider), isFalse);
        expect(v.passcode, '258025');

        v.setLocked(true);
        final lock = c.read(passcodeProvider.notifier);
        for (final d in [1, 2, 3, 4, 5, 6]) {
          lock.enterDigit(d);
        }
        expect(c.read(vehicleProvider).locked, isTrue, reason: 'old PIN rejected');
        async.elapse(const Duration(milliseconds: 600));
        for (final d in [2, 5, 8, 0, 2, 5]) {
          lock.enterDigit(d);
        }
        expect(c.read(vehicleProvider).locked, isFalse, reason: 'new PIN accepted');
      });
    });

    test('wrong current PIN fails, clears, and stays on verify', () {
      withApp((async, c, v) {
        c.read(changePasscodeOpenProvider.notifier).open();
        enter(c, '000000');
        var s = c.read(changePasscodeProvider);
        expect(s.lastResult, ChangePasscodeResult.failure);
        expect(s.failures, 1);
        async.elapse(const Duration(milliseconds: 600));
        s = c.read(changePasscodeProvider);
        expect(s.step, PasscodeStep.verify);
        expect(s.enteredDigits, isEmpty);
        expect(s.lastResult, isNull);
        expect(v.passcode, '123456');
      });
    });

    test('mismatch on confirm goes back to the new passcode step', () {
      withApp((async, c, v) {
        c.read(changePasscodeOpenProvider.notifier).open();
        enter(c, '123456');
        enter(c, '111111');
        enter(c, '222222');
        expect(c.read(changePasscodeProvider).lastResult, ChangePasscodeResult.mismatch);
        async.elapse(const Duration(milliseconds: 600));
        final s = c.read(changePasscodeProvider);
        expect(s.step, PasscodeStep.create);
        expect(s.newPasscode, isEmpty);
        expect(v.passcode, '123456');
        enter(c, '333333');
        enter(c, '333333');
        expect(v.passcode, '333333');
      });
    });

    test('delete removes the last digit', () {
      withApp((async, c, v) {
        c.read(changePasscodeOpenProvider.notifier).open();
        enter(c, '12');
        c.read(changePasscodeProvider.notifier).deleteDigit();
        expect(c.read(changePasscodeProvider).enteredDigits, [1]);
      });
    });
  });

  group('sound settings', () {
    test('preset switch changes the visible parameters; reset restores defaults', () {
      final c = ProviderContainer();
      c.listen(toastProvider, (_, _) {});
      final n = c.read(soundSettingsProvider.notifier);
      expect(c.read(soundSettingsProvider).presetParams.map((p) => p.$1), ['Bite', 'Analog / Cyber']);
      n.setPreset(SoundPreset.vintage);
      expect(c.read(soundSettingsProvider).presetParams, [('Age', 30), ('Size', 60)]);
      n.setPresetParam(0, 90);
      n.setPresetParam(1, 200);
      expect(c.read(soundSettingsProvider).vintageAge, 90);
      expect(c.read(soundSettingsProvider).vintageSize, 100);
      expect(c.read(soundSettingsProvider).boltBite, 50, reason: 'other presets untouched');
      n.setSoundVolume(10);
      n.setSystemSound(false);
      expect(c.read(soundSettingsProvider), isNot(const SoundSettings()));
      n.reset();
      expect(c.read(soundSettingsProvider), const SoundSettings());
      expect(c.read(toastProvider)!.message, 'Sound settings reset');
      c.dispose();
    });
  });

  group('riding settings', () {
    test('defaults, toggles with toasts, regen mode', () {
      final c = ProviderContainer();
      c.listen(toastProvider, (_, _) {});
      final n = c.read(ridingSettingsProvider.notifier);
      final s0 = c.read(ridingSettingsProvider);
      expect(s0.isOn(RidingFeature.adaptivePowerBoost), isTrue);
      expect(s0.isOn(RidingFeature.proximityUnlock), isFalse);
      expect(s0.regenMode, RegenMode.standard);
      n.setFeature(RidingFeature.adaptivePowerBoost, false);
      expect(c.read(ridingSettingsProvider).isOn(RidingFeature.adaptivePowerBoost), isFalse);
      expect(c.read(toastProvider)!.message, 'Adaptive Power Boost disabled');
      n.setRegenMode(RegenMode.off);
      expect(c.read(ridingSettingsProvider).regenMode, RegenMode.off);
      n.setAlarmSound(AlarmSound.alert2);
      expect(c.read(ridingSettingsProvider).alarmSound, AlarmSound.alert2);
      c.dispose();
    });

    test('hill hold asks for acknowledgement once', () {
      final c = ProviderContainer();
      c.listen(toastProvider, (_, _) {});
      final n = c.read(ridingSettingsProvider.notifier);
      n.setFeature(RidingFeature.hillHold, true);
      var s = c.read(ridingSettingsProvider);
      expect(s.hillHoldPrompt, isTrue);
      expect(s.isOn(RidingFeature.hillHold), isFalse, reason: 'not enabled until acknowledged');
      n.dismissHillHoldPrompt();
      expect(c.read(ridingSettingsProvider).isOn(RidingFeature.hillHold), isFalse);
      n.setFeature(RidingFeature.hillHold, true);
      n.acknowledgeHillHold();
      s = c.read(ridingSettingsProvider);
      expect(s.hillHoldPrompt, isFalse);
      expect(s.isOn(RidingFeature.hillHold), isTrue);
      expect(c.read(toastProvider)!.message, 'Hill hold enabled');
      n.setFeature(RidingFeature.hillHold, false);
      n.setFeature(RidingFeature.hillHold, true);
      expect(c.read(ridingSettingsProvider).hillHoldPrompt, isFalse, reason: 'skips the disclaimer');
      expect(c.read(ridingSettingsProvider).isOn(RidingFeature.hillHold), isTrue);
      c.dispose();
    });
  });
}
