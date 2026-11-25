import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/device_platform_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('in.abhijithvijayan.opendash.platform');

  setUp(() => AnalyticsLogger.instance.resetForTest());
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  test('a call Android could not carry out answers "no" or nothing, and is logged', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(code: 'error', message: 'boom'),
    );
    final platform = DevicePlatformService();
    expect(platform.isInstalled('a.b'), isFalse);
    expect(await platform.apkInfo('/x.apk'), isNull);
    expect(await platform.latestRelease('https://github.com/a/b/releases'), isNull);
    expect(await platform.downloadFile('https://github.com/a/b/releases', 'x.apk'), isNull);
    expect(await platform.networkCheck(), isEmpty);
    expect(platform.deviceInfo(), isEmpty);
    expect(AnalyticsLogger.instance.recent('platform', 'error'), hasLength(6),
        reason: 'thrown, it would reach the error screen from whatever tap started it');
  });

  test('with no Android side at all (a missing handler) nothing throws either', () async {
    expect(DevicePlatformService().canInstallApks(), isFalse);
  });
}
