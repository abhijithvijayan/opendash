import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/scooter_model.dart';
import '../../providers/mock_provider.dart';
import '../../screens/settings/widgets.dart';
import '../../services/analytics_logger.dart';
import '../../state/prompt_surface.dart';
import '../../state/riding_lockout.dart';

/// Shown, parked only, when the scooter's own software or its model is
/// one OpenDash has not been checked on. On unchecked software the
/// numbered commands are held until "Use OpenDash here": a command number
/// that has moved could do something other than what the button says.
class UncheckedScooterDialog extends ConsumerWidget {
  const UncheckedScooterDialog({super.key});

  static String body(UncheckedScooter u) => [
        if (u.serviceVersion != null) ...[
          'OpenDash has not been ridden on this scooter\'s software${u.serviceVersion!.isEmpty ? '' : ' (${u.serviceVersion})'}.',
          switch (u.source) {
            StockIdentity.sourceRead =>
              'It has read the scooter\'s own list of commands and will use that, so each button should do what it says, but nobody has tried.',
            StockIdentity.sourceFixture =>
              'It could not read the scooter\'s own list of commands and would use the one recorded for this software, which nobody has tried.',
            _ =>
              'It could not read the scooter\'s own list of commands and has no record of this software. It would use the list of the software it was made on: a button could do something other than what it says.',
          },
          'Its buttons that control the scooter are off until you allow them.',
        ],
        if (u.vehicleType != null)
          'This scooter model (type ${u.vehicleType}) has not been checked. Battery details and gauge scales were set up for the S1 Pro and may be wrong here.',
        'If anything looks wrong, use the stock dashboard.',
      ].join(' ');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vehicle = ref.read(vehicleProvider.notifier);
    final visible = ref.watch(ownScreenVisibleProvider) && !ref.watch(ridingLockoutProvider);
    return ValueListenableBuilder<UncheckedScooter?>(
      valueListenable: vehicle.unchecked,
      builder: (context, u, _) {
        if (u == null || !visible) return const SizedBox.shrink();
        return Positioned.fill(
          key: const ValueKey('unchecked-scooter'),
          child: ConfirmCard(
            width: 620,
            title: 'Not checked on this scooter',
            body: body(u),
            primaryLabel: 'Use OpenDash here',
            onPrimary: () {
              uiTap('unchecked-allow');
              vehicle.allowUnchecked();
            },
            secondaryLabel: 'Not now',
            onSecondary: () {
              uiTap('unchecked-later');
              vehicle.dismissUnchecked();
            },
          ),
        );
      },
    );
  }
}
