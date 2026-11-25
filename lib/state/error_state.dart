import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'crash_recovery.dart';
import 'riding_lockout.dart';
import '../services/analytics_logger.dart';

/// The unhandled error currently on screen, if any. Set by the global
/// handlers installed in main() and by the dev panel.
final appErrorProvider = NotifierProvider<AppErrorNotifier, String?>(AppErrorNotifier.new);

class AppErrorNotifier extends Notifier<String?> {
  /// Installed by main(): rebuilds the whole widget tree with a fresh
  /// container. Tests leave it null.
  static void Function()? onRestart;

  @override
  String? build() => null;

  void report(Object error, [StackTrace? stack]) {
    debugPrint('[OpenDash] unhandled: $error\n${stack ?? ''}');
    ref.read(crashRecoveryProvider.notifier).recordCrash();
    state = summarize(error);
    logEvent('error', 'shown', {'error': state, 'crashes': ref.read(crashRecoveryProvider).consecutiveCrashes});
  }

  /// Runs [body] and routes anything it throws through [report], the same
  /// path the global handlers use.
  void capture(void Function() body) {
    try {
      body();
    } catch (e, st) {
      report(e, st);
    }
  }

  void retry() {
    state = null;
    onRestart?.call();
  }

  void dismiss() => state = null;

  /// First line of the exception text, without the "Exception:" prefix.
  static String summarize(Object error) {
    final text = error.toString().split('\n').first.trim();
    return text.replaceFirst(RegExp(r'^(Exception|Bad state|Invalid argument\(s\)):\s*'), '');
  }
}

/// Wires Flutter's and the platform's error hooks to [appErrorProvider].
void installErrorHandlers(ProviderContainer container) {
  final previous = FlutterError.onError;
  // Framework errors surface mid-build or mid-paint, when providers may not
  // be modified, so the report waits for the frame to finish.
  FlutterError.onError = (details) {
    previous?.call(details);
    logEvent('error', 'flutter', {
      'error': details.exceptionAsString(),
      'stack': stackHead(details.stack),
      'context': details.context?.toDescription(),
      'library': details.library,
    });
    Future.microtask(() => container.read(appErrorProvider.notifier).report(details.exception, details.stack));
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    logEvent('error', 'platform', {'error': error.toString(), 'stack': stackHead(stack)});
    Future.microtask(() => container.read(appErrorProvider.notifier).report(error, stack));
    return true;
  };
}

/// The first ten frames, which is where the blame usually sits.
String? stackHead(StackTrace? stack, {int lines = 10}) {
  if (stack == null) return null;
  return stack.toString().split('\n').where((l) => l.trim().isNotEmpty).take(lines).join('\n');
}

final errorMinimizedProvider = NotifierProvider<ErrorMinimized, bool>(ErrorMinimized.new);

/// While riding (or with no trustworthy speed), the full-screen error card collapses to a status-bar chip
/// so the rider keeps the speedometer; a tap on the chip brings it back.
class ErrorMinimized extends Notifier<bool> {
  @override
  bool build() {
    onRidingLockout(ref, () {
      if (ref.read(appErrorProvider) != null) state = true;
    });
    ref.listen(appErrorProvider, (_, error) {
      if (error == null) {
        state = false;
      } else if (ref.read(ridingLockoutProvider)) {
        state = true;
      }
    });
    return false;
  }

  void expand() => state = false;
}
