import 'dart:async';

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/analytics_logger.dart';
import '../theme/colors.dart';

enum ToastType {
  info,
  success,
  warning,
  error;

  Color get color => switch (this) {
        ToastType.info => DashColors.ash,
        ToastType.success => DashColors.eco,
        ToastType.warning => DashColors.warning,
        ToastType.error => DashColors.critical,
      };
}

class ToastData {
  const ToastData({
    required this.id,
    required this.message,
    required this.type,
    required this.duration,
  });

  final int id;
  final String message;
  final ToastType type;
  final Duration duration;
}

final toastProvider = NotifierProvider<ToastNotifier, ToastData?>(ToastNotifier.new);

/// One transient message at a time. A new toast replaces the current one.
class ToastNotifier extends Notifier<ToastData?> {
  static const defaultDuration = Duration(seconds: 3);
  static const logCap = 80;
  Timer? _timer;
  int _nextId = 0;

  @override
  ToastData? build() {
    ref.onDispose(() => _timer?.cancel());
    return null;
  }

  /// [logAs] replaces the text in the analytics log when the message
  /// carries something personal (a network name).
  void show(String message, {ToastType type = ToastType.info, Duration? duration, String? logAs}) {
    // The same message again while it is still up (two "Charger connected
    // but not charging" in one second): keep it up, once.
    final current = state;
    if (current != null && current.message == message && current.type == type) {
      _timer?.cancel();
      _timer = Timer(duration ?? defaultDuration, dismiss);
      return;
    }
    final text = logAs ?? message;
    logEvent('ui', 'toast', {'message': text.length > logCap ? text.substring(0, logCap) : text, 'type': type.name});
    _timer?.cancel();
    final d = duration ?? defaultDuration;
    state = ToastData(id: _nextId++, message: message, type: type, duration: d);
    _timer = Timer(d, dismiss);
  }

  void dismiss() {
    _timer?.cancel();
    _timer = null;
    state = null;
  }
}
