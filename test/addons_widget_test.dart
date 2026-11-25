import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/settings_state.dart';
import 'package:opendash/state/theme_state.dart';
import 'package:opendash/theme/dash_theme.dart';
import 'package:opendash/widgets/gauges/speed_dial.dart';
import 'package:opendash/widgets/overlays/nav_bar.dart';

void main() {
  late ProviderContainer container;
  VehicleNotifier v() => container.read(vehicleProvider.notifier);
  Finder k(String id) => find.byKey(ValueKey(id));

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenDashApp()));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 500));
    v().setLocked(false);
    // The unlock raises the handlebar hint; let it expire before tapping.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('nav bar slides in on the dashboard only and closes with a toast', (tester) async {
    await pumpApp(tester);
    AnimatedPositioned bar() => tester.widget<AnimatedPositioned>(
          find.ancestor(of: k('nav-bar'), matching: find.byType(AnimatedPositioned)).first,
        );
    expect(bar().bottom, 72 - NavBar.height);
    v().setNavActive(true);
    await settle(tester);
    expect(bar().bottom, 72);
    expect(find.text('Turn right onto MG Road'), findsOneWidget);
    expect(find.text('400 m'), findsOneWidget);
    expect(find.text('7.6 km · 23 min'), findsOneWidget);
    expect(find.text('14 min'), findsNothing, reason: 'no separate eta next to the totals');
    expect(tester.widget<TurnIcon>(find.byType(TurnIcon)).kind, TurnKind.right);
    v().setNavDirection('Arrive at destination');
    await settle(tester);
    expect(tester.widget<TurnIcon>(find.byType(TurnIcon)).kind, TurnKind.arrive);

    v().setCharging(true);
    await settle(tester);
    expect(k('nav-bar'), findsNothing, reason: 'charging screen has no nav bar');
    v().setCharging(false);
    await settle(tester);
    await tester.tap(k('nav-close'));
    await settle(tester);
    expect(container.read(vehicleProvider).navActive, isFalse);
    expect(find.text('Navigation dismissed'), findsOneWidget);
  });

  testWidgets('apps launcher shows catalog cards with status and coming-soon label', (tester) async {
    await pumpApp(tester);
    v().setSpeed(20);
    await tester.pump();
    expect(k('status-apps'), findsNothing);
    v().setSpeed(0);
    await tester.pump();
    await tester.tap(k('status-apps'));
    await settle(tester);
    expect(container.read(appLauncherOpenProvider), isTrue);
    expect(find.text('Android Auto'), findsOneWidget);
    expect(find.text('CarPlay'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.text('Coming soon'), findsNothing);
    expect(find.text('Screen Mirror'), findsNothing);
    // OTA Shield is not offered while it is not installed.
    expect(find.text('OTA Shield'), findsNothing);
    expect(find.text('Not installed'), findsNWidgets(7));
    for (final name in ['Browser', 'Maps', 'NewPipe', 'File Manager']) {
      expect(find.text(name), findsOneWidget);
    }
  });

  testWidgets('theme cards switch the theme and the dial follows', (tester) async {
    await pumpApp(tester);
    expect(tester.widget<SpeedDial>(find.byType(SpeedDial)).theme, DashTheme.light);
    container.read(settingsScreenOpenProvider.notifier).open();
    await settle(tester);
    await tester.ensureVisible(k('theme-ember'));
    await settle(tester);
    await tester.tap(k('theme-ember'));
    await tester.pump(const Duration(milliseconds: 700));
    await settle(tester);
    expect(container.read(themeProvider), DashTheme.ember);
    expect(find.text('Theme: Ember'), findsOneWidget);
    container.read(settingsScreenOpenProvider.notifier).close();
    await settle(tester);
    expect(tester.widget<SpeedDial>(find.byType(SpeedDial)).theme, DashTheme.ember);
  });

  testWidgets('accent picker reveals presets and applies one', (tester) async {
    await pumpApp(tester);
    container.read(settingsScreenOpenProvider.notifier).open();
    await settle(tester);
    expect(k('accent-popover'), findsNothing);
    await tester.ensureVisible(k('accent-SPORT'));
    await tester.tap(k('accent-SPORT'));
    await settle(tester);
    expect(k('accent-popover'), findsOneWidget);
    await tester.ensureVisible(k('preset-1'));
    await tester.tap(k('preset-1'));
    await settle(tester);
    expect(container.read(themeProvider).sport, accentPresets[1]);
    expect(find.text('SPORT accent updated'), findsOneWidget);
  });

  testWidgets('About credits open the author and repo links as QR codes', (tester) async {
    await pumpApp(tester);
    container.read(settingsScreenOpenProvider.notifier).open();
    await settle(tester);
    await tester.tap(k('section-about'));
    await settle(tester);
    expect(find.text('MoveOS+ Unlocked'), findsNothing);
    expect(find.text('Open-source replacement dashboard for electric scooters'), findsOneWidget);
    await tester.tap(k('about-author'));
    await settle(tester);
    expect(k('qr-card-code'), findsOneWidget);
    expect(find.text('abhijithvijayan.in'), findsOneWidget);
    await tester.tap(k('qr-card-close'));
    await settle(tester);
    await tester.tap(k('about-repo'));
    await settle(tester);
    expect(k('qr-card-code'), findsOneWidget);
    expect(find.text('github.com/abhijithvijayan/opendash'), findsNWidgets(2), reason: 'the About line and the card');
  });
}
