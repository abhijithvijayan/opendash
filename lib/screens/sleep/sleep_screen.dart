import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/screen_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// Black screen while the vehicle sleeps. A double tap wakes it; a faint
/// hint appears after two seconds and goes again after five.
class SleepScreen extends ConsumerStatefulWidget {
  const SleepScreen({super.key});

  static const hintDelay = Duration(seconds: 2);
  static const hintDuration = Duration(seconds: 5);

  @override
  ConsumerState<SleepScreen> createState() => _SleepScreenState();
}

class _SleepScreenState extends ConsumerState<SleepScreen> {
  static const tapWindow = Duration(milliseconds: 400);
  bool _hint = false;
  Timer? _show;
  Timer? _hide;
  DateTime? _lastTap;

  /// Own two-tap detection: a second tap within [tapWindow] wakes. This
  /// avoids the double-tap recognizer's minimum-gap rule, which drops taps
  /// that arrive too close together.
  void _tap() {
    final now = DateTime.now();
    final last = _lastTap;
    _lastTap = now;
    if (last != null && now.difference(last) <= tapWindow) {
      _lastTap = null;
      ref.read(sessionProvider.notifier).wake();
    }
  }

  @override
  void initState() {
    super.initState();
    _show = Timer(SleepScreen.hintDelay, () {
      if (!mounted) return;
      setState(() => _hint = true);
      _hide = Timer(SleepScreen.hintDuration, () {
        if (mounted) setState(() => _hint = false);
      });
    });
  }

  @override
  void dispose() {
    _show?.cancel();
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _tap(),
      child: ColoredBox(
        color: const Color(0xFF000000),
        child: Center(
          child: AnimatedOpacity(
            opacity: _hint ? 0.3 : 0,
            duration: const Duration(milliseconds: 400),
            child: Text('Double-tap to wake', key: const ValueKey('sleep-hint'), style: DashText.caption(20, color: DashColors.ash)),
          ),
        ),
      ),
    );
  }
}
