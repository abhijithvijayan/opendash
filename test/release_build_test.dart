import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/constants.dart';

/// What a build is told at release time, and nowhere else. A fork's release
/// workflow passes its own repository, so it checks its own releases.
void main() {
  test('without RELEASES_REPO a build checks this project\'s releases', () {
    expect(releasesRepo, 'abhijithvijayan/opendash');
  });

  test('a release is told which repository it came from, and where the usage ping goes', () {
    final script = File('scripts/release.sh').readAsStringSync();
    expect(script, contains('--dart-define=RELEASES_REPO='));
    expect(script, contains('--dart-define=USAGE_PING_URL='));
    final workflow = File('.github/workflows/release.yml').readAsStringSync();
    expect(workflow, contains(r'RELEASES_REPO: ${{ github.repository }}'));
  });
}
