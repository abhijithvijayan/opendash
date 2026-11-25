import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/constants.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/state/crash_recovery.dart';
import 'package:opendash/state/toast_state.dart';

void main() {
  late ProviderContainer c;
  late MockPlatformService platform;
  String? toast() => c.read(toastProvider)?.message;

  setUp(() {
    platform = MockPlatformService();
    c = ProviderContainer(overrides: [platformServiceProvider.overrideWithValue(platform)]);
    c.listen(toastProvider, (_, _) {});
  });

  tearDown(() => c.dispose());

  test('launchStockApp starts the stock dashboard package', () async {
    platform.setInstalled(stockDashboardPackage);
    await c.read(crashRecoveryProvider.notifier).launchStockApp();
    expect(platform.launched, [stockDashboardPackage]);
    expect(toast(), isNull);
  });

  test('launchStockApp says so when the stock package is missing', () async {
    await c.read(crashRecoveryProvider.notifier).launchStockApp();
    expect(platform.launched, [stockDashboardPackage]);
    expect(toast(), 'Stock dashboard not installed');
  });

  test('setStockAsDefaultHome opens the system home chooser', () async {
    await c.read(crashRecoveryProvider.notifier).setStockAsDefaultHome();
    expect(platform.homeSettingsOpened, 1);
    expect(toast(), isNull);
  });

  test('service mode launches through the platform too', () async {
    final s = c.read(serviceModeOpenProvider.notifier);
    await s.launch('com.ola.mfgapp');
    expect(platform.launched, ['com.ola.mfgapp']);
    expect(toast(), 'Could not launch com.ola.mfgapp');
  });
}
