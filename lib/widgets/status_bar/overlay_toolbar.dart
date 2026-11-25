import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../screens/settings/widgets.dart';
import '../../state/overlay_state.dart';
import '../../state/ota_state.dart';
import '../../state/settings_state.dart';
import '../../state/theme_state.dart';
import '../overlays/alert_overlay.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';
import 'status_icons.dart';
import '../../services/analytics_logger.dart';

/// Slim strip that stands in for the status bar while a full-screen
/// overlay is up: back, the overlay's title, clock and battery. Nothing
/// else in the status bar matters to a parked rider inside a menu. A pull
/// down on it peeks the full bar.
class OverlayToolbar extends ConsumerStatefulWidget {
  const OverlayToolbar({super.key});

  /// Tall enough for the back button to sit inside it with air above and
  /// below: at 40 the 36 px disc touched the hairline and was hard to hit.
  static const height = 56.0;

  /// The back target hangs below the strip, to the size of a primary action.
  static const backHit = DashTouch.primary;

  /// The back target's width: a thumb anywhere near the corner lands on it.
  static const backWidth = 96.0;

  @override
  ConsumerState<OverlayToolbar> createState() => _OverlayToolbarState();
}

class _OverlayToolbarState extends ConsumerState<OverlayToolbar> {
  /// Kept through the slide-out, when no overlay is open any more.
  String _title = '';

  @override
  Widget build(BuildContext context) {
    _title = ref.watch(overlayTitleProvider) ?? _title;
    final title = _title;
    final time = ref.watch(vehicleProvider.select((v) => v.time));
    final soc = ref.watch(vehicleProvider.select((v) => v.socKnown ? v.batterySoc : null));
    final bars = ref.watch(vehicleProvider.select((v) => v.signalBars));
    final wifi = ref.watch(vehicleProvider.select((v) => v.wifiConnected));
    final installing = ref.watch(otaProvider.select((o) => o.status == OtaStatus.installing));
    // Change passcode is a sub-screen of settings; this is its only back arrow.
    final changeOpen = ref.watch(changePasscodeOpenProvider);
    final theme = ref.watch(uiThemeProvider);
    final peek = ref.read(statusBarPeekProvider.notifier);
    // The back target normally hangs 16px below the strip, where a thumb
    // overshoots; under an alert banner it stays inside the strip so the
    // banner keeps every tap that lands on it.
    final hit = ref.watch(alertBannerShiftProvider) > 0 ? OverlayToolbar.height : OverlayToolbar.backHit;

    return SizedBox(
      height: OverlayToolbar.backHit,
      child: Stack(
        children: [
          GestureDetector(
            key: const ValueKey('overlay-toolbar'),
            behavior: HitTestBehavior.opaque,
            onVerticalDragEnd: (d) {
              if ((d.primaryVelocity ?? 0) > 0) {
                uiSwipe('status-bar-pull');
                peek.peek();
              }
            },
            onVerticalDragUpdate: (d) {
              if (d.primaryDelta != null && d.primaryDelta! > 4) peek.peek();
            },
            child: Container(
              height: OverlayToolbar.height,
              decoration: BoxDecoration(
                color: theme.ink,
                border: Border(bottom: BorderSide(color: theme.slate, width: 1)),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Text(
                      title,
                      key: const ValueKey('toolbar-title'),
                      style: DashText.value(18, color: theme.bone),
                    ),
                  ),
                  Positioned(
                    right: DashSpace.gutter,
                    top: 0,
                    bottom: 0,
                    child: Row(
                      children: [
                        Text(time, key: const ValueKey('toolbar-clock'), style: DashText.caption(16, color: theme.ash)),
                        const SizedBox(width: 16),
                        SignalIcon(bars: bars),
                        const SizedBox(width: 8),
                        WifiIcon(on: wifi),
                        const SizedBox(width: 16),
                        BatteryIcon(soc: soc ?? 0, height: 16, color: theme.ash),
                        const SizedBox(width: 6),
                        Text(soc == null ? '—' : '$soc%', key: const ValueKey('toolbar-battery'), style: DashText.caption(16, color: theme.ash)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: DashSpace.gutter - 26,
            top: 0,
            child: BackArrow(
              key: const ValueKey('toolbar-back'),
              size: hit,
              width: OverlayToolbar.backWidth,
              iconSize: 30,
              discSize: 44,
              // The disc stays centred in the strip, 6 px clear of the
              // hairline, whether or not the target hangs below it.
              alignment: hit == OverlayToolbar.height ? Alignment.center : const Alignment(0, -0.5714),
              onTap: installing
                  ? null
                  : () {
                      if (changeOpen) {
                        ref.read(changePasscodeOpenProvider.notifier).close();
                      } else {
                        closeTopOverlay(ref);
                      }
                    },
            ),
          ),
        ],
      ),
    );
  }
}
