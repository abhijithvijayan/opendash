import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../screens/settings/widgets.dart';
import '../../state/format_settings.dart';
import '../../state/settings_state.dart';
import '../../theme/colors.dart';

class TripResetDialog extends ConsumerWidget {
  const TripResetDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(tripResetProvider);
    final trip = ref.watch(vehicleProvider.select((v) => v.tripMeter));
    final useMiles = ref.watch(useMilesProvider);
    if (!open) return const SizedBox.shrink();
    final popup = ref.read(tripResetProvider.notifier);
    return Positioned.fill(
      child: ConfirmCard(
        width: 360,
        title: 'Reset trip meter?',
        body: 'Trip: ${toDisplayDistanceD(trip, useMiles).toStringAsFixed(1)} ${distanceUnit(useMiles)}',
        primaryLabel: 'Reset',
        primaryColor: DashColors.critical,
        onPrimary: popup.confirm,
        secondaryLabel: 'Cancel',
        onSecondary: popup.cancel,
      ),
    );
  }
}
