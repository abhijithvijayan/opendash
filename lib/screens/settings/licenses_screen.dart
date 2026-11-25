import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/app_catalog.dart';
import '../../state/settings_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../widgets/overlays/alert_overlay.dart';
import '../../widgets/overlays/call_overlay.dart';
import '../../theme/tokens.dart';
import 'widgets.dart';

/// Every package the build ships, with its licence texts, from Flutter's
/// own registry (the NOTICES file the tool generates). Read once, on first
/// open: the file is a few hundred kilobytes.
final licensePackagesProvider = FutureProvider<List<(String, List<String>)>>((ref) async {
  final byPackage = <String, List<String>>{};
  await for (final entry in LicenseRegistry.licenses) {
    final text = entry.paragraphs.map((p) => p.text).join('\n\n');
    for (final pkg in entry.packages) {
      (byPackage[pkg] ??= []).add(text);
    }
  }
  final names = byPackage.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return [...offeredApps(), for (final n in names) (n, byPackage[n]!)];
});

/// The apps the Apps screen can install, listed ahead of the packages. They
/// are not part of OpenDash and no copy of them is shipped with it: each is
/// downloaded from its own project when the rider installs it. They are
/// named here so that what OpenDash puts on the head unit, and under which
/// licence, can be read in one place.
List<(String, List<String>)> offeredApps() => [
      for (final app in appCatalog.where((a) => a.downloadable))
        (
          '${app.appName.isEmpty ? app.name : app.appName} (from Apps)',
          [
            'Offered in Apps as "${app.name}". Not part of OpenDash: it is downloaded from its own project when you '
                'install it, and no copy is included with OpenDash.\n\n'
                'Licence: ${app.license}\n'
                'Source: ${app.releaseUrl.replaceFirst('https://', '').replaceFirst(RegExp(r'/releases$'), '')}',
          ],
        ),
    ];

final _licenseTextProvider = NotifierProvider<_LicenseText, String?>(_LicenseText.new);

class _LicenseText extends Notifier<String?> {
  @override
  String? build() {
    ref.listen(licensesScreenOpenProvider, (_, open) {
      if (!open) state = null;
    });
    return null;
  }

  void show(String pkg) => state = pkg;
  void hide() => state = null;
}

class LicensesScreen extends ConsumerWidget {
  const LicensesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(licensesScreenOpenProvider);
    final shift = ref.watch(alertBannerShiftProvider) + ref.watch(callBarShiftProvider);
    return AnimatedPositioned(
      duration: DashMotion.normal,
      curve: Curves.easeOutCubic,
      left: open ? 0 : 1280,
      top: shift,
      width: 1280,
      height: 768 - shift,
      child: open ? const _Body() : const SizedBox.shrink(),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shown = ref.watch(_licenseTextProvider);
    final packages = ref.watch(licensePackagesProvider);
    final texts = shown == null
        ? null
        : packages.value?.where((p) => p.$1 == shown).map((p) => p.$2).firstOrNull;
    return ColoredBox(
      key: const ValueKey('licenses-body'),
      color: DashColors.ink,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(DashSpace.gutter, DashSpace.overlayTop, DashSpace.gutter, DashSpace.bodyBottom),
        child: texts != null
            ? _LicenseDetail(package: shown!, texts: texts, onClose: ref.read(_licenseTextProvider.notifier).hide)
            : packages.when(
                loading: () => Center(child: Text('Reading licences…', style: DashText.caption(18))),
                error: (_, _) => Center(child: Text('Licences could not be read', style: DashText.caption(18))),
                data: (list) => ListView.builder(
                  itemCount: list.length,
                  itemExtent: 72,
                  itemBuilder: (context, i) {
                    final (pkg, licenses) = list[i];
                    return GestureDetector(
                      key: ValueKey('license-$pkg'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        ref.read(_licenseTextProvider.notifier).show(pkg);
                      },
                      child: Row(
                        children: [
                          Expanded(child: Text(pkg, style: DashText.value(18), maxLines: 1, overflow: TextOverflow.ellipsis)),
                          Text(licenses.length == 1 ? '1 licence' : '${licenses.length} licences', style: DashText.caption(15)),
                        ],
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}

class _LicenseDetail extends StatelessWidget {
  const _LicenseDetail({required this.package, required this.texts, required this.onClose});
  final String package;
  final List<String> texts;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Column(
        key: const ValueKey('license-text'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(package, style: DashText.title(26), maxLines: 1, overflow: TextOverflow.ellipsis)),
              PrimaryButton('Close', key: const ValueKey('license-close'), onTap: onClose),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.separated(
              itemCount: texts.length,
              separatorBuilder: (_, _) => const SettingsDivider(),
              itemBuilder: (context, i) => Text(texts[i], style: DashText.caption(14, color: DashColors.bone)),
            ),
          ),
        ],
      );
}
