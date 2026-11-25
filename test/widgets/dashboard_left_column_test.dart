import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/main.dart';
import 'package:opendash/models/app_catalog.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/media_state.dart';
import 'package:opendash/widgets/gauges/battery_ring.dart';
import 'package:opendash/widgets/media/now_playing_bar.dart';
import 'package:opendash/widgets/panel/widget_panel.dart';

/// The boot button and the way back to a projection app share the lower left
/// of the dashboard; the volume belongs to the now-playing bar on the right.
/// The popup once sat on the boot button, then on the dial's "0";
/// this pins that none of them touch.
void main() {
  late ProviderContainer container;
  Finder k(String id) => find.byKey(ValueKey(id));

  Future<void> pumpDash(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [platformServiceProvider.overrideWithValue(MockPlatformService())],
      child: const OpenDashApp(),
    ));
    await tester.pump();
    container = ProviderScope.containerOf(tester.element(find.byType(OpenDashApp)));
    await tester.pump(const Duration(seconds: 2));
    container.read(vehicleProvider.notifier).setLocked(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Rects in design pixels, whatever the test surface scales the canvas to.
  Rect design(WidgetTester tester, Finder f) {
    final canvas = tester.getRect(find.byWidgetPredicate((w) => w is SizedBox && w.width == 1280 && w.height == 768).first);
    final s = canvas.height / 768;
    final r = tester.getRect(f);
    return Rect.fromLTRB((r.left - canvas.left) / s, (r.top - canvas.top) / s, (r.right - canvas.left) / s, (r.bottom - canvas.top) / s);
  }

  testWidgets('the way back to CarPlay sits below the boot button, and the volume is in the music bar, clear of both', (tester) async {
    await pumpDash(tester);
    final carplay = appCatalog.firstWhere((a) => a.id == 'carplay');
    container.read(projectionResumeProvider.notifier).offer(carplay);
    container.read(volumeOverlayProvider.notifier).open();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final boot = design(tester, k('dash-trunk'));
    final chip = design(tester, k('resume-projection'));
    final popup = design(tester, k('volume-popup'));

    expect(boot.top, closeTo(492, 1), reason: 'the boot button sits in the evenly-spaced left column');
    expect(boot.left, closeTo(72, 1));
    expect(chip.left, closeTo(boot.left, 1));
    expect(chip.top, greaterThanOrEqualTo(boot.bottom + 4), reason: 'below the boot button, in the open space (clear of the mode ladder above)');
    expect(chip.bottom, lessThanOrEqualTo(696), reason: 'clear of the trip strip');
    expect(chip.height, greaterThanOrEqualTo(56), reason: 'the minimum touch target');
    expect(popup.overlaps(boot), isFalse);
    expect(popup.overlaps(chip), isFalse);
    expect(chip.width, closeTo(boot.width, 1), reason: 'one column');
    expect(popup.top, greaterThanOrEqualTo(696), reason: 'inside the trip strip');
    expect(popup.bottom, lessThanOrEqualTo(768));
    expect(popup.right, lessThanOrEqualTo(1280 - 72 - NowPlayingBar.controlsWidth), reason: 'left of the transport controls');
    expect(popup.left, greaterThan(640), reason: 'on the music side of the strip, clear of the trip meter');

    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('the page dots are centred under the battery ring', (tester) async {
    await pumpDash(tester);
    final ring = design(tester, find.byType(BatteryRing));
    final dots = design(tester, find.byType(PageDots));
    expect(dots.center.dx, closeTo(ring.center.dx, 1));
  });

  testWidgets('a sideways swipe puts "Back to CarPlay" away', (tester) async {
    await pumpDash(tester);
    container.read(projectionResumeProvider.notifier).offer(appCatalog.firstWhere((a) => a.id == 'carplay'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.fling(k('resume-projection'), const Offset(400, 0), 1500);
    await tester.pumpAndSettle();
    expect(container.read(projectionResumeProvider), isNull);
    expect(k('resume-projection'), findsNothing);
  });
}
