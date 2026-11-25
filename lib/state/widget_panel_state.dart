import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mock_provider.dart';
import '../services/analytics_logger.dart';
import 'screen_state.dart';

/// Which page the right-hand widget panel shows. Page 0 is the battery ring.
/// A screen or lock transition snaps back to it so the battery is what the
/// rider sees first.
///
/// Stopping and setting off again is not such a transition. The vehicle
/// state flips between ready and riding at every traffic light (118 times
/// in one 90-minute ride), and each flip used to snap the panel
/// back, mid-swipe included: on the move the pages would not stay put, and
/// a swipe felt like it had not taken.
final widgetPageProvider = NotifierProvider<WidgetPage, int>(WidgetPage.new);

class WidgetPage extends Notifier<int> {
  static const count = 3;

  @override
  int build() {
    ref.listen(
      vehicleProvider.select((v) => (v.isCharging, v.locked, v.vehicleState.motorOn ? null : v.vehicleState)),
      (_, _) => _reset('vehicle'),
    );
    ref.listen(sessionProvider, (_, _) => _reset('session'));
    return 0;
  }

  void _reset(String cause) {
    if (state == 0) return;
    logEvent('ui', 'panel_reset', {'from': state, 'cause': cause});
    state = 0;
  }

  void set(int page) => state = page.clamp(0, count - 1);
}
