import '../constants.dart';

/// Which build this is. The version comes from `pubspec.yaml` (a test keeps
/// [appVersion] equal to it), the commit from the build command
/// (`--dart-define=GIT_SHA`), and the build number from the installed
/// package itself (Android's `versionCode`, read once at start): it is the
/// number Android compares when one build is installed over another, so it
/// is read back, not kept as a second constant.
abstract final class BuildInfo {
  static const gitSha = String.fromEnvironment('GIT_SHA');

  /// Android's version code; null on the web and before it has been read.
  static int? number;

  /// "0.2.0 · build 412 · a1b2c3d", leaving out what is not known.
  static String get label => [appVersion, if (number != null) 'build $number', if (gitSha.isNotEmpty) gitSha].join(' · ');
}
