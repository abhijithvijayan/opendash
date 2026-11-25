import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mock_provider.dart';
import 'profile_state.dart';
import '../services/trusted_clock.dart';

/// "Good morning, Owner" by the hour: morning 5-11, afternoon 12-16,
/// evening otherwise. An empty name drops the comma.
String greetingFor(DateTime now, String name) {
  final h = now.hour;
  final part = h >= 5 && h < 12
      ? 'Good morning'
      : h >= 12 && h < 17
          ? 'Good afternoon'
          : 'Good evening';
  final n = name.trim();
  return n.isEmpty ? part : '$part, $n';
}

final greetingProvider = NotifierProvider<GreetingNotifier, String?>(GreetingNotifier.new);

/// Welcome line shown once per boot, on the first unlock.
class GreetingNotifier extends Notifier<String?> {
  static const showFor = Duration(seconds: 3);
  bool _shown = false;
  Timer? _timer;

  bool get shownThisSession => _shown;

  @override
  String? build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen(vehicleProvider.select((v) => v.locked), (prev, locked) {
      if (prev == true && !locked) _onUnlock();
    });
    return null;
  }

  void _onUnlock() {
    if (_shown) return;
    _shown = true;
    show();
  }

  void show({DateTime? now}) {
    final name = ref.read(profileProvider).name.trim();
    // No "Good evening" off a clock that cannot be right.
    state = now == null && !TrustedClock.trusted
        ? (name.isEmpty ? 'Hello' : 'Hello, $name')
        : greetingFor(now ?? DateTime.now(), name);
    _timer?.cancel();
    _timer = Timer(showFor, () {
      _timer = null;
      state = null;
    });
  }
}
