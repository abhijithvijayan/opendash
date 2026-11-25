import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/constants.dart';
import 'package:opendash/services/build_info.dart';

/// The release process: one version string, a release script that refuses
/// what must not be released, and workflows that keep the signing key where
/// it belongs.
void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final pubspecVersion = RegExp(r'^version:\s*([0-9A-Za-z.\-]+)', multiLine: true).firstMatch(pubspec)!.group(1)!;

  test('appVersion is the version in pubspec.yaml', () {
    expect(appVersion, pubspecVersion);
  });

  test('the build label leaves out what is not known', () {
    BuildInfo.number = null;
    expect(BuildInfo.label, appVersion);
    BuildInfo.number = 412;
    expect(BuildInfo.label, startsWith('$appVersion · build 412'));
    BuildInfo.number = null;
  });

  group('scripts/release.sh', () {
    ProcessResult run(List<String> args) => Process.runSync('bash', ['scripts/release.sh', ...args]);

    test('refuses without a version, or with one that is not three numbers (an -alpha.N / -beta.N label allowed)', () {
      for (final args in [<String>[], ['latest'], ['1.2'], ['v1.2.3'], ['1.2.3-beta'], ['1.2.3-rc.1'], ['1.2.3-beta.1+4']]) {
        final r = run(args);
        expect(r.exitCode, 1, reason: '$args');
        expect(r.stdout, contains('Usage'));
      }
      for (final label in ['9.9.9-alpha.1', '9.9.9-beta.12']) {
        final r = run([label]);
        expect(r.exitCode, 1, reason: label);
        expect(r.stdout, isNot(contains('Usage')), reason: '$label is a version; refused only for not being the one in pubspec.yaml');
        expect(r.stdout, contains('Refusing: asked for $label'));
      }
    });

    test('refuses to build with the crash flag in the environment, and unknown options', () {
      final crash = Process.runSync('bash', ['scripts/release.sh', pubspecVersion], environment: {'OPENDASH_CRASH': 'kotlin'});
      expect(crash.exitCode, 1);
      expect(crash.stdout, contains('OPENDASH_CRASH is set'));
      expect(run([pubspecVersion, '--publish']).exitCode, 1);
      // A build that fails at start is only ever made on purpose, by name,
      // and the workflow never asks for one.
      final script = File('scripts/release.sh').readAsStringSync();
      expect(script, contains('--crash-trial=kotlin'));
      expect(script, contains('CRASH-TRIAL.apk'));
      expect(File('.github/workflows/release.yml').readAsStringSync(), isNot(contains('crash')));
      expect(File('scripts/deploy.sh').readAsStringSync(), isNot(contains('OPENDASH_CRASH')));
    });

    test('refuses a version that is not the one in pubspec.yaml', () {
      final r = run(['99.99.99']);
      expect(r.exitCode, 1);
      expect(r.stdout, contains('Refusing'));
      expect(r.stdout, contains('pubspec.yaml says $pubspecVersion'));
    });

    test('refuses without a release key, before building anything', () {
      final r = run([pubspecVersion]);
      expect(r.exitCode, 1);
      expect(r.stdout, contains('Refusing'));
      if (!File('android/key.properties').existsSync()) {
        expect(r.stdout, contains('android/key.properties is missing'));
      }
      expect(r.stdout, isNot(contains('=== Building')));
    }, skip: File('android/key.properties').existsSync() && Process.runSync('git', ['status', '--porcelain', '--untracked-files=no']).stdout == ''
        ? 'a key is present and the tree is clean: it would build'
        : null);

    test('checks, in order: version, key, clean tree, then the signature after the build', () {
      final whole = File('scripts/release.sh').readAsStringSync();
      final script = whole.substring(whole.indexOf('set -euo pipefail'));
      final order = ['pubspec.yaml says', 'key.properties is missing', 'uncommitted changes', 'flutter build apk', 'APK is signed with a debug key', 'release key on record']
          .map(script.indexOf)
          .toList();
      expect(order.every((i) => i > 0), isTrue);
      expect(order, [...order]..sort());
      // It prints the publish command; it does not run it.
      expect(RegExp(r'^\s*gh release', multiLine: true).hasMatch(script), isFalse);
    });

    // The two forms seen: a local SDK, and GitHub's runner, where a
    // correctly signed APK was refused twice.
    test('the certificate is read from either form apksigner prints', () {
      final script = File('scripts/release.sh').readAsStringSync();
      final sed = RegExp(r"sed -n '(s/[^']*certificate SHA-256 digest: //p)'").firstMatch(script)!.group(1)!;
      String read(String output) =>
          (Process.runSync('bash', ['-c', 'printf "%s\\n" "\$0" | sed -n \'$sed\' | sort -u', output]).stdout as String).trim();
      const digest = '25f012a33b86ab2365b480b594998a131fa8e0edc3768c9e258440f98d4ba7ee';
      expect(read('Signer #1 certificate DN: CN=x\nSigner #1 certificate SHA-256 digest: $digest\nSigner #1 certificate SHA-1 digest: aa'), digest);
      expect(read('V2 Signer: certificate DN: CN=x\nV2 Signer: certificate SHA-256 digest: $digest\nV2 Signer: certificate SHA-1 digest: aa'), digest);
      expect(read('V2 Signer: certificate SHA-256 digest: $digest\nV3 Signer: certificate SHA-256 digest: $digest'), digest);
      expect(read('Verifies\nWARNING: something'), isEmpty);
    });

    test('deploy.sh and release.sh take the build number from the version, never the history', () {
      final deploy = File('scripts/deploy.sh').readAsStringSync();
      final release = File('scripts/release.sh').readAsStringSync();
      expect(deploy, contains(r'BUILD="$(scripts/build-number.sh "$VERSION" dev)"'));
      expect(deploy, contains(r'--build-number="$BUILD"'));
      expect(release, contains(r'BUILD="$(scripts/build-number.sh "$VERSION" "${TRIAL:+trial}")"'));
      expect(release, contains(r'--build-number="$BUILD"'));
      for (final script in [deploy, release]) {
        expect(script, isNot(contains('rev-list')));
      }
    });

    // Android, the self-update and the companion app all call a higher
    // build newer; 2001 is the highest build made before 0.3.0.
    test('build numbers rise with the version and stay above every earlier build', () {
      int build(String version, [String kind = 'release']) {
        final r = Process.runSync('scripts/build-number.sh', [version, kind]);
        expect(r.exitCode, 0, reason: '$version $kind: ${r.stderr}');
        return int.parse((r.stdout as String).trim());
      }

      expect(build('0.3.0'), 30000);
      expect(build('0.3.0'), greaterThan(2001));
      final order = ['0.2.9', '0.3.0-alpha.1', '0.3.0-alpha.2', '0.3.0-beta.1', '0.3.0-beta.9', '0.3.0', '0.3.1', '0.4.0', '1.0.0'];
      for (var i = 1; i < order.length; i++) {
        expect(build(order[i]), greaterThan(build(order[i - 1])), reason: '${order[i]} after ${order[i - 1]}');
      }
      expect(build('0.3.0', 'dev'), allOf(greaterThan(build('0.3.0')), lessThan(build('0.3.1-alpha.1'))));
      expect(build('0.3.0-beta.2', 'dev'), lessThan(build('0.3.0')));
      expect(build('0.3.0', 'trial'), build('0.3.0') + 1);
      for (final bad in ['0.3', 'v0.3.0', '0.100.0', '0.3.0-beta.0', '0.3.0-rc.1']) {
        expect(Process.runSync('scripts/build-number.sh', [bad]).exitCode, isNot(0), reason: bad);
      }
    });
  });

  group('workflows', () {
    final ci = File('.github/workflows/ci.yml').readAsStringSync();
    final release = File('.github/workflows/release.yml').readAsStringSync();
    String code(String yaml) => yaml.split('\n').where((l) => !l.trimLeft().startsWith('#')).join('\n');

    test('every action is pinned to a commit', () {
      for (final yaml in [ci, release]) {
        final uses = RegExp(r'uses:\s*(\S+)').allMatches(code(yaml)).map((m) => m.group(1)!).toList();
        expect(uses, isNotEmpty);
        for (final u in uses) {
          expect(RegExp(r'^[\w.-]+/[\w./-]+@[0-9a-f]{40}$').hasMatch(u), isTrue, reason: u);
        }
      }
    });

    test('CI uses no secret and cannot write to the repository', () {
      expect(code(ci), isNot(contains('secrets.')));
      expect(code(ci), isNot(contains('contents: write')));
      expect(code(ci), contains('pull_request:'));
    });

    test('the release starts from a version tag or by hand, from the gated environment, and ends as a draft', () {
      final c = code(release);
      final triggers = c.substring(c.indexOf('\non:'), c.indexOf('\npermissions:'));
      expect(triggers, contains('workflow_dispatch'));
      expect(triggers, contains("push:\n    tags:\n      - 'v*.*.*'"));
      for (final trigger in ['pull_request', 'branches', 'schedule', 'workflow_run', 'issue_comment']) {
        expect(triggers, isNot(contains(trigger)), reason: trigger);
      }
      expect(c, contains('environment: release'));
      // A tag can be put on any commit: only one that is on main is built.
      expect(c, contains('git merge-base --is-ancestor "\$GITHUB_SHA" origin/main'));
      expect(c.indexOf('merge-base --is-ancestor'), lessThan(c.indexOf('secrets.RELEASE_KEYSTORE_BASE64')));
      expect(c, contains(r'VERSION=${GITHUB_REF_NAME#v}'));
      expect(c, contains('--draft'));
      expect(c, contains('scripts/release.sh "\$VERSION"'));
      expect(c, contains('RELEASE_CERT_SHA256'));
      // The input reaches the shell as an environment variable, never pasted
      // into a script.
      expect(RegExp(r'run:[^\n]*\$\{\{\s*inputs').hasMatch(c), isFalse);
      expect(c.split('run: |').skip(1).any((block) => block.split('\n      - ').first.contains('\${{ inputs')), isFalse);
      // The key is removed whatever happened.
      expect(c, contains('if: always()'));
      // The notification job gets the ntfy secrets and nothing else: no
      // signing key, no environment, no permissions.
      final notify = c.substring(c.indexOf('\n  notify:'));
      expect(notify, contains('needs: [release]'));
      expect(notify, contains('permissions: {}'));
      expect(notify, isNot(contains('environment:')));
      expect(notify, isNot(contains('RELEASE_')));
      expect(RegExp(r'secrets\.(\w+)').allMatches(notify).map((m) => m.group(1)).toSet(), {'NTFY_URL', 'NTFY_TOKEN'});
    });

    test('the Flutter version in both workflows is one version', () {
      final versions = RegExp(r"flutter-version: '([^']+)'").allMatches(ci + release).map((m) => m.group(1)).toSet();
      expect(versions, hasLength(1));
    });
  });
}
