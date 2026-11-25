import 'package:fake_async/fake_async.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/app_catalog.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/theme_state.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:opendash/theme/colors.dart';
import 'package:opendash/theme/dash_theme.dart';
import 'package:opendash/widgets/indicators/telltale_strip.dart';
import 'package:opendash/widgets/overlays/nav_bar.dart';

void main() {
  void withApp(void Function(FakeAsync async, ProviderContainer c, VehicleNotifier v) body) {
    fakeAsync((async) {
      final c = ProviderContainer(
        overrides: [platformServiceProvider.overrideWithValue(MockPlatformService())],
      );
      for (final p in [
        sessionProvider, themeProvider, uiThemeProvider, toastProvider,
        appLauncherOpenProvider, mockAppProvider, settingsScreenOpenProvider,
        appManagerProvider,
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

  group('turn parsing', () {
    test('maps instruction keywords to glyphs', () {
      expect(turnKindFor('Turn left onto Brigade Road'), TurnKind.left);
      expect(turnKindFor('Turn right'), TurnKind.right);
      expect(turnKindFor('Continue straight'), TurnKind.straight);
      expect(turnKindFor('Make a U-turn'), TurnKind.uTurn);
      expect(turnKindFor('Slight left'), TurnKind.slightLeft);
      expect(turnKindFor('bear RIGHT ahead'), TurnKind.slightRight);
      expect(turnKindFor('Arrive at destination'), TurnKind.arrive);
      expect(turnKindFor('Merge onto highway'), TurnKind.unknown);
    });
  });

  group('themes', () {
    test('built-ins are complete and opaque', () {
      for (final t in DashTheme.builtIn) {
        expect(t.name, isNotEmpty);
        for (final c in [t.ink, t.inkLift, t.bone, t.ash, t.slate, t.eco, t.normal, t.sport, t.hyper, t.charging, t.parked, t.critical, t.warning]) {
          expect(c.a, 1.0, reason: '${t.name} colours must be opaque');
        }
        if (t.isLight) {
          expect(t.ink.computeLuminance(), greaterThan(t.bone.computeLuminance()));
        } else {
          expect(t.ink.computeLuminance(), lessThan(t.bone.computeLuminance()));
        }
      }
      expect(DashTheme.dark.eco, DashColors.eco, reason: 'statics are the dark theme');
    });

    test('setTheme updates, toasts, and the eased theme follows in 500ms', () {
      withApp((async, c, v) {
        c.read(themeProvider.notifier).setTheme(DashTheme.midnight);
        expect(c.read(themeProvider), DashTheme.midnight);
        expect(c.read(toastProvider)!.message, 'Theme: Midnight');
        async.elapse(const Duration(milliseconds: 100));
        final mid = c.read(uiThemeProvider);
        expect(mid.ink, isNot(DashTheme.dark.ink));
        expect(mid.ink, isNot(DashTheme.midnight.ink));
        async.elapse(const Duration(milliseconds: 600));
        expect(c.read(uiThemeProvider), DashTheme.midnight);
      });
    });

    test('custom accents override one mode and reset on theme switch', () {
      withApp((async, c, v) {
        const indigo = Color(0xFF6B5CE7);
        c.read(themeProvider.notifier).setTheme(DashTheme.dark);
        c.read(themeProvider.notifier).setAccent('ECO', indigo);
        expect(c.read(themeProvider).eco, indigo);
        expect(c.read(themeProvider).normal, DashTheme.dark.normal);
        expect(c.read(themeProvider).name, 'Dark');
        expect(c.read(toastProvider)!.message, 'ECO accent updated');
        expect(c.read(themeProvider.notifier).isBase(DashTheme.dark), isFalse);
        c.read(themeProvider.notifier).setTheme(DashTheme.dark);
        expect(c.read(themeProvider).eco, DashTheme.dark.eco);
      });
    });

    test('accent provider reads the theme, including overrides', () {
      withApp((async, c, v) {
        v.setVehicleState(VehicleState.ready);
        v.setDriveMode(DriveMode.sport);
        expect(c.read(accentProvider), DashTheme.light.sport, reason: 'Light is the default theme');
        c.read(themeProvider.notifier).setTheme(DashTheme.ember);
        async.elapse(const Duration(milliseconds: 700));
        expect(c.read(accentProvider), DashTheme.ember.sport);
        c.read(themeProvider.notifier).setAccent('SPORT', const Color(0xFF4CE0D2));
        async.elapse(const Duration(milliseconds: 700));
        expect(c.read(accentProvider), const Color(0xFF4CE0D2));
      });
    });

    test('tell-tales take their colours from the theme', () {
      final t = telltalesFor(const VehicleData(brakeWorn: true), DashTheme.ember).single;
      expect(t.color, DashTheme.ember.warning);
    });

    test('the regen tell-tale is suppressed while reversing or under smart park', () {
      bool hasRegen(VehicleData v) => telltalesFor(v).any((t) => t.id == 'regen');
      expect(hasRegen(const VehicleData(regenNotification: true)), isTrue);
      expect(hasRegen(const VehicleData(regenNotification: true, reverse: true)), isFalse,
          reason: 'regen is a forward-riding readout');
      expect(hasRegen(const VehicleData(regenNotification: true, parkAssist: true)), isFalse,
          reason: 'MoveOS 5 left the flag set during easy-park creep');
    });
  });

  group('apps', () {
    test('launcher is blocked while riding and auto-closes', () {
      withApp((async, c, v) {
        final launcher = c.read(appLauncherOpenProvider.notifier);
        v.setSpeed(10);
        launcher.open();
        expect(c.read(appLauncherOpenProvider), isFalse);
        v.setSpeed(0);
        c.read(settingsScreenOpenProvider.notifier).open();
        launcher.open();
        expect(c.read(appLauncherOpenProvider), isTrue);
        expect(c.read(settingsScreenOpenProvider), isFalse, reason: 'apps is top level, so settings closes');
        v.setCharging(true);
        expect(c.read(appLauncherOpenProvider), isTrue, reason: 'plugging in does not close it');
        v.setLocked(true);
        expect(c.read(appLauncherOpenProvider), isFalse);
      });
    });

    test('coming-soon apps only toast', () {
      withApp((async, c, v) {
        c.read(appLauncherOpenProvider.notifier).open();
        final comingSoonApp = const CatalogApp(
          id: 'not-yet',
          name: 'Not Yet',
          package: '',
          description: '',
          releaseUrl: '',
          license: '',
          comingSoon: true,
        );
        c.read(appManagerProvider.notifier).launch(comingSoonApp);
        async.elapse(const Duration(milliseconds: 100));
        expect(c.read(toastProvider)!.message, 'Coming soon');
        expect(c.read(mockAppProvider), isNull);
      });
    });

    test('mock launch shows placeholder and lock closes it', () {
      withApp((async, c, v) {
        c.read(appLauncherOpenProvider.notifier).open();
        final autoApp = appCatalog.firstWhere((a) => a.id == 'android-auto');
        c.read(appManagerProvider.notifier).launch(autoApp);
        async.elapse(const Duration(milliseconds: 100));
        expect(c.read(mockAppProvider), autoApp);
        expect(c.read(appLauncherOpenProvider), isFalse, reason: 'launcher closes behind the app');
        v.setLocked(true);
        expect(c.read(mockAppProvider), isNull, reason: 'lock closes the app');
      });
    });
  });

  group('nav', () {
    test('dismiss clears nav and toasts', () {
      withApp((async, c, v) {
        v.setNavActive(true);
        expect(c.read(vehicleProvider).navActive, isTrue);
        v.setNavDirection('Arrive at destination', distance: '50 m');
        expect(c.read(vehicleProvider).distanceToTurn, '50 m');
        v.dismissNav();
        expect(c.read(vehicleProvider).navActive, isFalse);
        expect(c.read(toastProvider)!.message, 'Navigation dismissed');
      });
    });
  });
}
