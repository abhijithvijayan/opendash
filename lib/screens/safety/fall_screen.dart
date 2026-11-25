import 'package:flutter/widgets.dart';

import 'safety_overlay.dart';

/// Stock `TamperFallScreens/FallDetectedPopup` (TamperFallStatus 2): two
/// lines and no button. It goes when the vehicle reports the fall over, or
/// leaves ALARM.
class FallScreen extends StatelessWidget {
  const FallScreen({super.key});

  @override
  Widget build(BuildContext context) => const SafetyScaffold(
        kicker: 'SAFETY ALERT',
        title: 'Fall detected',
        lines: ['Live location tracking on'],
      );
}
