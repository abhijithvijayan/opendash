import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/screens/safe_mode/safe_mode_screen.dart';
import 'package:opendash/state/ota_state.dart';
import 'package:opendash/state/qr_card.dart';

const _release = OtaRelease(version: '0.3.0', build: 130, sha256: 'c0ffee', apkUrl: '');

/// Plays OpenDash's update state without timers, GitHub or the installer.
class _FakeOta extends OtaNotifier {
  _FakeOta(this.start);
  final OtaData start;
  int checks = 0, downloads = 0, installs = 0;

  @override
  OtaData build() => start;

  @override
  Future<void> check({bool auto = false}) async => checks++;

  @override
  Future<void> startDownload() async => downloads++;

  @override
  void startInstall() => installs++;
}

void main() {
  late ProviderContainer container;

  Future<_FakeOta> pump(WidgetTester tester, OtaData data, {bool locked = false}) async {
    await tester.binding.setSurfaceSize(const Size(1280, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fake = _FakeOta(data);
    final c = container = ProviderContainer(overrides: [otaProvider.overrideWith(() => fake)]);
    addTearDown(c.dispose);
    c.read(vehicleProvider.notifier).setLocked(locked);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const Directionality(textDirection: TextDirection.ltr, child: SafeModeScreen()),
    ));
    return fake;
  }

  Finder k(String id) => find.byKey(ValueKey(id));

  testWidgets('an update that is ready can be installed from safe mode', (tester) async {
    final ota = await pump(tester, const OtaData(status: OtaStatus.ready, release: _release));
    expect(find.text('Install OpenDash 0.3.0'), findsOneWidget);
    await tester.tap(k('safe-update-install'));
    expect(ota.installs, 1);
  });

  testWidgets('with nothing found yet, safe mode can check for one', (tester) async {
    final ota = await pump(tester, const OtaData());
    await tester.tap(k('safe-update-check'));
    expect(ota.checks, 1);
  });

  testWidgets('a release found can be downloaded from safe mode', (tester) async {
    final ota = await pump(tester, const OtaData(status: OtaStatus.available, release: _release));
    expect(find.text('Download OpenDash 0.3.0'), findsOneWidget);
    await tester.tap(k('safe-update-download'));
    expect(ota.downloads, 1);
  });

  testWidgets('a download in progress shows how far it is', (tester) async {
    await pump(tester, const OtaData(status: OtaStatus.downloading, release: _release, progress: 40));
    expect(find.text('Downloading OpenDash 0.3.0 · 40%'), findsOneWidget);
  });

  testWidgets('a locked scooter offers no update controls', (tester) async {
    await pump(tester, const OtaData(status: OtaStatus.ready, release: _release), locked: true);
    expect(k('safe-update-install'), findsNothing);
    expect(k('safe-update-check'), findsNothing);
  });

  testWidgets('safe mode offers the companion app as a QR code', (tester) async {
    await pump(tester, const OtaData());
    await tester.tap(k('safe-companion'));
    expect(container.read(qrCardProvider)?.id, 'companion');
  });
}
