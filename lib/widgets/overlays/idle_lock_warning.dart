import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mock_provider.dart';
import '../../theme/colors.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';

/// "Locking in 8 s": the scooter locks itself about a minute after the last
/// touch, whatever is on screen, and at first nothing said it was
/// about to. Any touch anywhere keeps it awake, so this takes none itself.
///
/// With the side stand up the scooter does not lock itself at all. The
/// same place then says that, quietly and once, at the moment a lock would
/// have come (`standUpHint`).
class IdleLockWarning extends ConsumerWidget {
  const IdleLockWarning({super.key});

  static const top = 692.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vehicle = ref.read(vehicleProvider.notifier);
    return ValueListenableBuilder<int?>(
      valueListenable: vehicle.idleLockIn,
      builder: (context, left, _) {
        if (left == null) {
          return ValueListenableBuilder<bool>(
            valueListenable: vehicle.standUpHint,
            builder: (context, hint, _) => hint
                ? _strip(
                    key: const ValueKey('stand-up-hint'),
                    border: DashColors.ash,
                    lead: 'Not locked',
                    leadColor: DashColors.bone,
                    rest: 'Put the side stand down and it locks by itself',
                  )
                : const SizedBox.shrink(),
          );
        }
        return _strip(
          key: const ValueKey('idle-lock-warning'),
          border: DashColors.warning,
          lead: left > 0 ? 'Locking in $left s' : 'Locking',
          leadColor: DashColors.warning,
          rest: 'Touch the screen to stay unlocked',
        );
      },
    );
  }

  Widget _strip({required Key key, required Color border, required String lead, required Color leadColor, required String rest}) {
    return Positioned(
          top: top,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Center(
              child: Container(
                key: key,
                height: DashTouch.min,
                padding: const EdgeInsets.symmetric(horizontal: 28),
                decoration: BoxDecoration(
                  color: DashColors.inkLift,
                  borderRadius: BorderRadius.circular(DashRadius.button),
                  border: Border.all(color: border, width: 1.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(lead, style: DashText.value(20, color: leadColor)),
                    const SizedBox(width: 14),
                    Text(rest, style: DashText.caption(18, color: DashColors.bone)),
                  ],
                ),
              ),
            ),
          ),
        );
  }
}
