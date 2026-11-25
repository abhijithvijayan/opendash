import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/analytics_logger.dart';
import '../../state/toast_state.dart';

final bookmarkProvider = NotifierProvider<BookmarkNotifier, int>(BookmarkNotifier.new);

/// A rider's "something just happened" marker in the analytics log: a
/// triple-tap on the status-bar clock (a stationary target that normal
/// use never hits three times in half a second) writes `user.bookmark` and
/// toasts the number so the gesture is known to have landed. The state is
/// the count this app session.
class BookmarkNotifier extends Notifier<int> {
  static const window = Duration(milliseconds: 500);
  static const tapsNeeded = 3;
  static const toastFor = Duration(seconds: 1);

  int _taps = 0;
  DateTime? _last;

  @override
  int build() => 0;

  /// One tap on the clock; [at] is injectable for tests.
  void tap([DateTime? at]) {
    final now = at ?? DateTime.now();
    if (_last != null && now.difference(_last!) > window) _taps = 0;
    _last = now;
    _taps++;
    if (_taps < tapsNeeded) return;
    _taps = 0;
    _last = null;
    add();
  }

  /// The dev panel button and the Developer settings row land here too.
  void add() {
    state++;
    logEvent('user', 'bookmark', {'seq': state, 'note': null});
    ref.read(toastProvider.notifier).show('Bookmark $state saved', duration: toastFor);
  }
}
