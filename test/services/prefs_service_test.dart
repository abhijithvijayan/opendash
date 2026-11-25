import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/services/prefs_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PrefsService', () {
    tearDown(PrefsService.resetForTest);

    test('returns fallbacks and ignores writes before init', () async {
      expect(PrefsService.ready, isFalse);
      expect(PrefsService.getBool('x', true), isTrue);
      expect(PrefsService.getInt('x', 7), 7);
      expect(PrefsService.getString('x', 'd'), 'd');
      await PrefsService.setInt('x', 9);
      expect(PrefsService.getInt('x', 7), 7);
    });

    test('round-trips values once initialised', () async {
      SharedPreferences.setMockInitialValues({'brightness': 40});
      await PrefsService.init();
      expect(PrefsService.ready, isTrue);
      expect(PrefsService.getInt('brightness', 80), 40);
      await PrefsService.setBool('use24h', true);
      await PrefsService.setString('theme', 'Ember');
      await PrefsService.setDouble('geo', 2.5);
      expect(PrefsService.getBool('use24h', false), isTrue);
      expect(PrefsService.getString('theme', 'Dark'), 'Ember');
      expect(PrefsService.getDouble('geo', 1), 2.5);
      await PrefsService.remove('theme');
      expect(PrefsService.getString('theme', 'Dark'), 'Dark');
    });
  });
}
