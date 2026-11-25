import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/services/mock_platform_service.dart';

void main() {
  group('MockPlatformService', () {
    late MockPlatformService svc;

    setUp(() => svc = MockPlatformService());

    test('isInstalled returns false for unknown package', () async {
      expect(svc.isInstalled('com.example.missing'), isFalse);
    });

    test('setInstalled makes isInstalled return true', () async {
      svc.setInstalled('com.example.app');
      expect(svc.isInstalled('com.example.app'), isTrue);
    });

    test('setInstalled(installed: false) removes package', () async {
      svc.setInstalled('com.example.app');
      svc.setInstalled('com.example.app', installed: false);
      expect(svc.isInstalled('com.example.app'), isFalse);
    });

    test('launchApp succeeds only for installed packages', () async {
      expect(await svc.launchApp('com.example.app'), isFalse);
      svc.setInstalled('com.example.app');
      expect(await svc.launchApp('com.example.app'), isTrue);
    });

    test('installApk returns true', () async {
      expect(await svc.installApk('/mock/path.apk'), isTrue);
    });

    test('downloadFile returns a path', () async {
      final path = await svc.downloadFile('https://example.com/app.apk', 'app.apk');
      expect(path, isNotNull);
      expect(path, contains('app.apk'));
    });

    test('a catalog app\'s download reads as that app, signed with its key', () async {
      final info = await svc.apkInfo('/mock/cache/apks/carplay.apk');
      expect(info!.package, 'com.shihab.diplay');
      expect(info.signer, hasLength(64));
      expect(await svc.apkInfo('/mock/file'), isNull);
    });
  });
}
