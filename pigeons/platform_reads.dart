import 'package:pigeon/pigeon.dart';

// Reads Android answers at once, called directly (JNI) instead of over a
// channel, so Dart gets the value without a Future:
//
//   cd android && ./gradlew :app:compileReleaseKotlin && cd ..
//   dart run pigeon --input pigeons/platform_reads.dart
//
// Only reads that cannot block belong here: a direct call holds the thread
// that builds frames until it returns. Anything that crosses into a stock
// service, touches the network or reads a file stays on a channel.
@ConfigurePigeon(PigeonOptions(
  appDirectory: './',
  dartOut: 'lib/services/platform_reads.g.dart',
  // A package of its own: the binding generator looks classes up by name
  // and cannot find one under `in`, which Kotlin has to quote.
  kotlinOut: 'android/app/src/main/kotlin/opendash/reads/PlatformReads.g.kt',
  kotlinOptions: KotlinOptions(
    package: 'opendash.reads',
    errorClassName: 'PlatformReadsError',
    useJni: true,
    jniClassPaths: <String>['build/app/tmp/kotlin-classes/release'],
  ),
  dartPackageName: 'opendash',
))
@HostApi()
abstract class PlatformReadsApi {
  /// Bytes written so far for a direct download, 0 when none is running.
  int downloadProgress(String filename);
  bool canInstallApks();
  bool canDrawOverlays();
  bool hasNotificationAccess();
  bool isInstalled(String packageName);
  bool isDefaultHome();
  String? externalFilesDir();

  /// The package in front, null without usage access.
  String? foregroundPackage();
  Map<String, String> deviceInfo();
  Map<String, Object?> updateRecord();
}
