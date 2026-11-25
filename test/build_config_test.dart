import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Gradle file can't be exercised from a Dart test;
/// these keep the two properties that silently regress on a template
/// refresh or a Flutter upgrade. `flutter build apk --release` on a checkout
/// with no key.properties is the real check of the fallback.
void main() {
  final gradle = File('android/app/build.gradle.kts').readAsStringSync();

  test('SDK levels are literals, not the Flutter SDK defaults', () {
    expect(gradle, contains(RegExp(r'^\s*compileSdk = \d+$', multiLine: true)));
    expect(gradle, contains(RegExp(r'^\s*minSdk = \d+$', multiLine: true)));
    expect(gradle, contains(RegExp(r'^\s*targetSdk = \d+$', multiLine: true)));
    for (final inherited in ['flutter.compileSdkVersion', 'flutter.minSdkVersion', 'flutter.targetSdkVersion']) {
      expect(gradle, isNot(contains(inherited)));
    }
    final min = int.parse(RegExp(r'minSdk = (\d+)').firstMatch(gradle)!.group(1)!);
    expect(min, lessThanOrEqualTo(29), reason: 'the head unit is Android 10');
  });

  test('release signing reads key.properties and falls back to the debug key', () {
    expect(gradle, contains('rootProject.file("key.properties")'));
    expect(gradle, contains('signingConfigs.getByName(if (hasReleaseKey) "release" else "debug")'));
    expect(gradle, isNot(contains(RegExp(r'storePassword = "'))), reason: 'no password in the build file');
  });

  test('keys and key.properties are gitignored, and none is tracked', () {
    final ignored = File('.gitignore').readAsLinesSync().toSet();
    expect(ignored, containsAll(['key.properties', '*.jks', '*.keystore']));
    final tracked = Process.runSync('git', ['ls-files']).stdout.toString().split('\n');
    expect(
      tracked.where((f) => f.endsWith('key.properties') || f.endsWith('.jks') || f.endsWith('.keystore') || f.endsWith('.p12')),
      isEmpty,
    );
  });
}
