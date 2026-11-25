import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/analytics_logger.dart';
import '../services/prefs_service.dart';

final analyticsEnabledProvider = NotifierProvider<AnalyticsEnabled, bool>(AnalyticsEnabled.new);

/// Settings -> Developer -> "Analytics logging". On by default so the
/// first test rides produce a file without anyone opting in.
class AnalyticsEnabled extends Notifier<bool> {
  @override
  bool build() => PrefsService.getBool(PrefsKeys.analyticsEnabled, true);

  void set(bool on) {
    if (on == state) return;
    // Order matters: the change is recorded while the logger still writes.
    if (on) AnalyticsLogger.instance.setEnabled(true);
    logSettingsChange('analytics', state, on);
    if (!on) AnalyticsLogger.instance.setEnabled(false);
    state = on;
    PrefsService.setBool(PrefsKeys.analyticsEnabled, on);
  }
}
