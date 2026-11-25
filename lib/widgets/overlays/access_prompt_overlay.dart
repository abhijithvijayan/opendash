import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../screens/settings/widgets.dart';
import '../../services/analytics_logger.dart';
import '../../state/access_state.dart';
import '../../theme/colors.dart';
import '../../theme/tokens.dart';
import '../../theme/typography.dart';

/// The access prompt (`accessProvider`): what a flow needs from Android,
/// listed before the flow starts.
///
/// Each line that is off is a switch, already on: Continue allows what is
/// switched on. The first version drew a hollow circle per line with one
/// "Allow all" button, and a rider could not tell whether
/// the circles were to be tapped (the log has a 24 s pause, then the
/// "Open page" link, before Allow). What is needed for the thing asked for
/// cannot be switched off here; the rest can.
class AccessPromptOverlay extends ConsumerStatefulWidget {
  const AccessPromptOverlay({super.key});

  @override
  ConsumerState<AccessPromptOverlay> createState() => _AccessPromptOverlayState();
}

class _AccessPromptOverlayState extends ConsumerState<AccessPromptOverlay> {
  /// Switched off by the rider in the prompt that is up.
  final Set<Access> _skip = {};
  AccessRequest? _for;

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(accessProvider);
    final request = view.request;
    if (request == null) return const SizedBox.shrink();
    if (!identical(request, _for)) {
      _for = request;
      _skip
        ..clear()
        ..addAll(request.startOff);
    }
    final access = ref.read(accessProvider.notifier);
    final off = [for (final a in request.accesses) if (!view.has(a)) a];
    final on = [for (final a in off) if (!_skip.contains(a)) a];
    return Positioned.fill(
      key: const ValueKey('access-prompt'),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ColoredBox(
          color: DashColors.ink.withValues(alpha: DashScrim.backdrop),
          child: Center(
            child: Container(
              width: 680,
              padding: const EdgeInsets.all(DashSpace.dialogPad),
              decoration: BoxDecoration(
                color: DashColors.inkLift,
                borderRadius: BorderRadius.circular(DashRadius.dialog),
                border: Border.all(color: DashColors.slate, width: 1.5),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(request.title, key: const ValueKey('access-title'), style: DashText.title(22, color: DashColors.bone)),
                  const SizedBox(height: 6),
                  Text(
                    off.isEmpty
                        ? 'Everything here is allowed.'
                        : 'Continue lets OpenDash do what is switched on below. Nothing else on the scooter changes.',
                    style: DashText.caption(16, color: DashColors.ash),
                  ),
                  const SizedBox(height: 10),
                  for (final a in request.accesses)
                    if (view.has(a))
                      _Allowed(a)
                    else ...[
                      ToggleRow(
                        key: ValueKey('access-row-${a.name}'),
                        label: a.label,
                        caption: request.required.contains(a) ? '${a.why} Needed for this.' : a.why,
                        value: !_skip.contains(a),
                        // What the thing asked for needs stays on.
                        onChanged: request.required.contains(a) || view.busy
                            ? null
                            : (v) => setState(() => v ? _skip.remove(a) : _skip.add(a)),
                      ),
                      // Only after Continue could not switch it on.
                      if (view.failed.contains(a))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text("Couldn't be switched on from here.", style: DashText.caption(14, color: DashColors.warning)),
                              ),
                              TextButtonLink(
                                "Open Android's page",
                                key: ValueKey('access-open-${a.name}'),
                                color: DashColors.bone,
                                onTap: () => access.openPage(a),
                              ),
                            ],
                          ),
                        ),
                    ],
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (off.isNotEmpty)
                        TextButtonLink(
                          'Not now',
                          key: const ValueKey('access-done'),
                          color: DashColors.bone,
                          onTap: () {
                            uiTap('access-done');
                            access.done();
                          },
                        ),
                      const SizedBox(width: 20),
                      Opacity(
                        opacity: view.busy ? 0.4 : 1,
                        child: PrimaryButton(
                          view.busy ? 'Allowing…' : off.isEmpty ? 'Done' : 'Continue',
                          key: const ValueKey('access-allow'),
                          onTap: () {
                            uiTap('access-allow', {'on': on.length, 'off': _skip.length});
                            off.isEmpty ? access.done() : access.allow(skip: {..._skip});
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Already on: nothing to switch, so not drawn as something to tap.
class _Allowed extends StatelessWidget {
  const _Allowed(this.access);
  final Access access;

  @override
  Widget build(BuildContext context) => Padding(
        key: ValueKey('access-row-${access.name}'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(child: Text(access.label, style: DashText.caption(18, color: DashColors.ash))),
            Icon(Icons.check_rounded, size: 22, color: DashColors.eco),
            const SizedBox(width: 6),
            Text('Allowed', style: DashText.caption(16, color: DashColors.eco)),
          ],
        ),
      );
}
