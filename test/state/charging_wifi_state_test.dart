import 'package:fake_async/fake_async.dart';
import 'package:material_ui/material_ui.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/alert_state.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/theme_state.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:opendash/state/wifi_state.dart';
import 'package:opendash/theme/dash_theme.dart';

void main() {
  void withApp(void Function(FakeAsync async, ProviderContainer c, VehicleNotifier v) body) {
    fakeAsync((async) {
      final c = ProviderContainer();
      for (final p in [
        sessionProvider, toastProvider, dismissedAlertsProvider, wifiProvider, autoThemeProvider,
        themeProvider, uiThemeProvider, changePasscodeOpenProvider, licensesScreenOpenProvider,
        chargeLimitPopupProvider, tripResetProvider,
      ]) {
        c.listen(p, (_, _) {});
      }
      final v = c.read(vehicleProvider.notifier);
      v.setConnected(true);
      v.setLocked(false);
      async.elapse(const Duration(seconds: 5));
      body(async, c, v);
      c.dispose();
    });
  }

  String? toast(ProviderContainer c) => c.read(toastProvider)?.message;
  List<AlertKind> visible(ProviderContainer c) => c.read(visibleAlertsProvider).map((a) => a.kind).toList();

  group('charging', () {
    test('charge start time is set when charging begins and cleared after', () {
      withApp((async, c, v) {
        expect(c.read(vehicleProvider).chargeStartTime, isEmpty);
        v.setCharging(true);
        expect(c.read(vehicleProvider).chargeStartTime, matches(RegExp(r'^\d{1,2}:\d{2} [AP]M$')));
        v.setCharging(false);
        expect(c.read(vehicleProvider).chargeStartTime, isEmpty);
      });
    });

    test('charger states drive the plugged flag and complete is derived', () {
      withApp((async, c, v) {
        v.setChargerState(ChargingState.initializing);
        expect(c.read(vehicleProvider).isCharging, isTrue);
        expect(c.read(screenStateProvider), ScreenState.charging);
        v.setChargerState(ChargingState.notCharging);
        expect(c.read(vehicleProvider).isCharging, isTrue);
        v.setChargerState(ChargingState.complete);
        expect(c.read(vehicleProvider).chargingComplete, isTrue);
        expect(c.read(vehicleProvider).safeToUnplug, isTrue);
        v.setChargerState(ChargingState.normal);
        expect(c.read(vehicleProvider).isCharging, isFalse);
        expect(c.read(screenStateProvider), ScreenState.parked);
        v.setCharging(true);
        v.setBattery(100);
        expect(c.read(vehicleProvider).chargingState, ChargingState.complete);
        v.setBattery(90);
        expect(c.read(vehicleProvider).chargingState, ChargingState.charging);
      });
    });

    test('charge limit clamps and toasts once when reached', () {
      withApp((async, c, v) {
        v.setChargeLimit(10);
        expect(c.read(vehicleProvider).chargeLimit, 50);
        v.setChargeLimit(130);
        expect(c.read(vehicleProvider).chargeLimit, 100);
        v.setChargeLimit(80);
        v.setBattery(70);
        v.setCharging(true);
        v.setBattery(79);
        expect(toast(c), isNot('Charge limit reached (80%)'));
        v.setBattery(80);
        expect(toast(c), 'Charge limit reached (80%)');
        c.read(toastProvider.notifier).dismiss();
        v.setBattery(81);
        expect(toast(c), isNull, reason: 'only once per cycle');
        v.setBattery(70);
        v.setBattery(85);
        expect(toast(c), 'Charge limit reached (80%)');
      });
    });

    test('charge limit popup closes when the charger is unplugged', () {
      withApp((async, c, v) {
        v.setCharging(true);
        c.read(chargeLimitPopupProvider.notifier).open();
        expect(c.read(chargeLimitPopupProvider), isTrue);
        v.setCharging(false);
        expect(c.read(chargeLimitPopupProvider), isFalse);
      });
    });
  });

  group('transient alerts', () {
    test('ready while charging warns for five seconds and keeps charging', () {
      withApp((async, c, v) {
        v.setCharging(true);
        v.setVehicleState(VehicleState.ready);
        expect(c.read(vehicleProvider).isCharging, isTrue);
        expect(visible(c), contains(AlertKind.unplugChargerToRide));
        async.elapse(const Duration(seconds: 6));
        expect(visible(c), isNot(contains(AlertKind.unplugChargerToRide)));
      });
    });

    test('lock and unlock failures are warnings that clear', () {
      withApp((async, c, v) {
        v.failLock();
        expect(c.read(visibleAlertsProvider).single.kind, AlertKind.lockFailed);
        expect(c.read(visibleAlertsProvider).single.priority, AlertPriority.warning);
        v.failUnlock();
        expect(visible(c), containsAll([AlertKind.lockFailed, AlertKind.unlockFailed]));
        async.elapse(const Duration(seconds: 6));
        expect(visible(c), isEmpty);
      });
    });

    test('reverse toggles at a stop and stays while it moves', () {
      withApp((async, c, v) {
        v.activateReverse();
        expect(c.read(vehicleProvider).reverse, isTrue);
        v.setSpeed(5);
        expect(c.read(vehicleProvider).reverse, isTrue);
        v.activateReverse();
        expect(c.read(vehicleProvider).reverse, isTrue, reason: 'only at a stop');
        v.setSpeed(0);
        v.activateReverse();
        expect(c.read(vehicleProvider).reverse, isFalse);
      });
    });
  });

  group('wifi', () {
    test('toggle, connect to saved, disconnect, scan, with toasts', () {
      withApp((async, c, v) {
        final w = c.read(wifiProvider.notifier);
        expect(c.read(wifiProvider).connectedSsid, 'HomeWifi_5G');
        w.connect('Home_WiFi');
        expect(c.read(wifiProvider).connectedSsid, 'HomeWifi_5G', reason: 'one second delay');
        async.elapse(const Duration(milliseconds: 1100));
        expect(c.read(wifiProvider).connectedSsid, 'Home_WiFi');
        expect(toast(c), 'Connected to Home_WiFi');
        expect(c.read(wifiProvider).networks.firstWhere((n) => n.ssid == 'HomeWifi_5G').status, WifiNetwork.saved);
        w.connect('Cafe_Guest');
        expect(toast(c), 'Password entry coming in Phase 2');
        w.connect('Neighbor_Net');
        async.elapse(const Duration(milliseconds: 1100));
        expect(c.read(wifiProvider).connectedSsid, 'Neighbor_Net');
        w.disconnect();
        async.elapse(const Duration(milliseconds: 1100));
        expect(c.read(wifiProvider).connectedSsid, isNull);
        expect(toast(c), 'Disconnected from Neighbor_Net');
        expect(c.read(vehicleProvider).wifiConnected, isFalse);
        w.scan();
        expect(c.read(wifiProvider).scanning, isTrue);
        async.elapse(const Duration(milliseconds: 2100));
        expect(c.read(wifiProvider).scanning, isFalse);
        expect(c.read(wifiProvider).networks.first.signalStrength, 3);
        w.setEnabled(false);
        expect(toast(c), 'Wi-Fi turned off');
        expect(c.read(vehicleProvider).wifiConnected, isFalse);
        w.connect('Home_WiFi');
        async.elapse(const Duration(seconds: 2));
        expect(c.read(wifiProvider).connectedSsid, isNull, reason: 'radio off');
        w.setEnabled(true);
        expect(toast(c), 'Wi-Fi turned on');
        w.failConnection();
        expect(toast(c), 'Connection failed');
        expect(c.read(toastProvider)!.type, ToastType.warning);
      });
    });
  });

  group('light theme', () {
    test('exists, is light, and scales the glow down', () {
      expect(DashTheme.builtIn, contains(DashTheme.light));
      expect(DashTheme.light.isLight, isTrue);
      expect(DashTheme.light.ink.computeLuminance(), greaterThan(0.5));
      expect(DashTheme.light.glowScale, lessThan(1));
      expect(DashTheme.dark.glowScale, 1);
      expect(DashTheme.dark.isLight, isFalse);
    });

    test('auto dark mode swaps between light and the last dark theme', () {
      withApp((async, c, v) {
        c.read(themeProvider.notifier).setTheme(DashTheme.ember);
        c.read(autoDarkModeProvider.notifier).setEnabled(true);
        final s = c.read(autoThemeProvider.notifier);
        s.evaluate(const TimeOfDay(hour: 12, minute: 0));
        expect(c.read(themeProvider), DashTheme.ember, reason: 'picked by hand at noon: it holds until evening');
        s.evaluate(const TimeOfDay(hour: 23, minute: 0));
        s.evaluate(const TimeOfDay(hour: 12, minute: 0));
        expect(c.read(themeProvider), DashTheme.light);
        s.evaluate(const TimeOfDay(hour: 23, minute: 0));
        expect(c.read(themeProvider), DashTheme.ember, reason: 'back to the last dark theme');
        c.read(autoDarkModeProvider.notifier).setEnabled(false);
        s.evaluate(const TimeOfDay(hour: 12, minute: 0));
        expect(c.read(themeProvider), DashTheme.ember, reason: 'disabled');
      });
    });
  });

  group('misc', () {
    test('brightness presets cycle dim, medium, full', () {
      withApp((async, c, v) {
        final b = c.read(brightnessProvider.notifier);
        b.set(80);
        b.cyclePreset();
        expect(c.read(brightnessProvider), 100);
        b.cyclePreset();
        expect(c.read(brightnessProvider), 30);
        b.cyclePreset();
        expect(c.read(brightnessProvider), 60);
        expect(toast(c), 'Brightness: Medium');
      });
    });

    test('licenses screen opens and closes; passcode change closes when riding', () {
      withApp((async, c, v) {
        c.read(licensesScreenOpenProvider.notifier).open();
        expect(c.read(licensesScreenOpenProvider), isTrue);
        c.read(licensesScreenOpenProvider.notifier).close();
        expect(c.read(licensesScreenOpenProvider), isFalse);
        c.read(changePasscodeOpenProvider.notifier).open();
        v.setSpeed(12);
        expect(c.read(changePasscodeOpenProvider), isFalse);
      });
    });
  });
}
