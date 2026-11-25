import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/app_catalog.dart';
import 'package:opendash/screens/settings/licenses_screen.dart';

void main() {
  test('every app Apps can install is named in Licences with its licence and where it comes from', () {
    final listed = offeredApps();
    expect(listed.map((e) => e.$1), [
      'Headunit Revived (from Apps)',
      'DiPlay (from Apps)',
      'DuckDuckGo (from Apps)',
      'Organic Maps (from Apps)',
      'NewPipe (from Apps)',
      'Material Files (from Apps)',
      'Termux (from Apps)',
      'OTA Shield (from Apps)',
    ]);
    for (final app in appCatalog.where((a) => a.downloadable)) {
      final text = listed.firstWhere((e) => e.$1.startsWith(app.appName.isEmpty ? app.name : app.appName)).$2.single;
      expect(text, contains('Licence: ${app.license}'), reason: app.id);
      expect(text, matches(RegExp(r'Source: (github\.com|codeberg\.org)/')), reason: app.id);
      expect(text, isNot(contains('/releases')), reason: app.id);
      expect(text, contains('no copy is included'), reason: app.id);
    }
  });
}
