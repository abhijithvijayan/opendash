import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../services/analytics_logger.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../theme/tokens.dart';

/// 3x4 keypad of 112px round keys. Keys press in and darken like a physical
/// safe keypad. One key at a time: a tap within [debounce] of the last one,
/// or while a finger is down on another key, is dropped (seen once: one
/// press registered as two digits 1 ms apart and cost a passcode attempt).
class Keypad extends StatefulWidget {
  const Keypad({
    super.key,
    required this.onDigit,
    required this.onDelete,
    this.enabled = true,
  });

  final ValueChanged<int> onDigit;
  final VoidCallback onDelete;
  final bool enabled;

  static const keySize = 112.0;
  static const columnGap = 20.0;
  static const rowGap = 16.0;
  static const width = keySize * 3 + columnGap * 2;
  static const height = keySize * 4 + rowGap * 3;
  static const debounce = Duration(milliseconds: 50);

  @override
  State<Keypad> createState() => _KeypadState();
}

class _KeypadState extends State<Keypad> {
  static const _delete = -1;
  final Set<int> _down = {};
  final Map<int, Duration> _pressedAt = {};
  Duration? _lastAccepted;

  // TODO(keypad-press-twice): the first log showed short presses that slid 13 to 37 px, all on
  // the passcode gate; keys now count on lift. Check the next logs: ui.keypad_no_digit should be rare and only
  // with a large moved_px. Why the gate lost taps the lock screen kept is not known.
  // A press that lit a key and entered nothing: a key often had to be
  // pressed twice even after it was seen to glow. A key
  // lights on finger-down and enters on a completed tap, so a press that
  // slides, is held, or loses to another gesture lights it for nothing.
  // Each such press is logged with how it ended, how long it was held and
  // how far the finger moved: never which key, which would give the
  // passcode away.
  final Map<int, Offset> _downAt = {};
  final Map<int, double> _moved = {};
  final Set<int> _tapped = {};

  void _pressBegan(int id, PointerDownEvent e) {
    _pressedAt[id] = e.timeStamp;
    _downAt[id] = e.position;
    _moved[id] = 0;
    _tapped.remove(id);
  }

  void _pressMoved(int id, PointerMoveEvent e) {
    final from = _downAt[id];
    if (from == null) return;
    final d = (e.position - from).distance;
    if (d > (_moved[id] ?? 0)) _moved[id] = d;
  }

  /// After the gesture arena has had its say on this pointer.
  void _pressEnded(int id, PointerEvent e, String end) {
    final began = _pressedAt[id];
    final moved = _moved[id] ?? 0;
    _downAt.remove(id);
    Future.microtask(() {
      if (_tapped.remove(id)) return;
      _noDigit(id, end, began == null ? null : e.timeStamp - began, moved);
    });
  }

  void _noDigit(int id, String end, Duration? held, double moved) {
    logEvent('ui', 'keypad_no_digit', {
      'key': id == _delete ? 'delete' : 'digit',
      'end': end,
      'held_ms': held?.inMilliseconds,
      // Physical pixels: the keypad is drawn scaled, the finger is not.
      'moved_px': moved.round(),
      'enabled': widget.enabled,
      'others_down': _down.where((k) => k != id).length,
    });
  }

  @override
  void dispose() {
    // The keypad went away under a finger (the screen changed mid-press).
    for (final id in _downAt.keys.toList()) {
      _noDigit(id, 'keypad_gone', null, _moved[id] ?? 0);
    }
    super.dispose();
  }

  /// Compares pointer-down event timestamps. Equal stamps are one input
  /// packet, i.e. overlapping fingers, which the multi-touch check covers.
  bool _accept(int key) {
    if (_down.any((k) => k != key)) {
      logEvent('ui', 'keypad_debounce_drop', {'reason': 'multi_touch'});
      return false;
    }
    final at = _pressedAt[key];
    final last = _lastAccepted;
    if (at != null && last != null) {
      final gap = at - last;
      if (gap > Duration.zero && gap < Keypad.debounce) {
        logEvent('ui', 'keypad_debounce_drop', {'reason': 'debounce', 'gap_us': gap.inMicroseconds});
        return false;
      }
    }
    if (at != null) _lastAccepted = at;
    return true;
  }

  Widget _key(int id, {required VoidCallback onTap, required Widget child, bool flat = false}) => Listener(
        onPointerDown: (e) => _pressBegan(id, e),
        onPointerMove: (e) => _pressMoved(id, e),
        onPointerUp: (e) => _pressEnded(id, e, 'up'),
        onPointerCancel: (e) => _pressEnded(id, e, 'cancel'),
        child: _Key(
          enabled: widget.enabled,
          flat: flat,
          onDown: (down) => down ? _down.add(id) : _down.remove(id),
          onTap: () {
            // A tap that the debounce drops has its own event.
            _tapped.add(id);
            if (_accept(id)) onTap();
          },
          child: child,
        ),
      );

  @override
  Widget build(BuildContext context) {
    const keySize = Keypad.keySize;
    const columnGap = Keypad.columnGap;
    const rowGap = Keypad.rowGap;
    final enabled = widget.enabled;
    Widget row(List<Widget> keys) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < keys.length; i++) ...[
              if (i > 0) const SizedBox(width: columnGap),
              keys[i],
            ],
          ],
        );

    Widget digit(int d) => _key(d, onTap: () => widget.onDigit(d), child: Text('$d', style: DashText.value(48)));

    return AnimatedOpacity(
      opacity: enabled ? 1 : 0.3,
      duration: DashMotion.normal,
      child: IgnorePointer(
        ignoring: !enabled,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            row([digit(1), digit(2), digit(3)]),
            const SizedBox(height: rowGap),
            row([digit(4), digit(5), digit(6)]),
            const SizedBox(height: rowGap),
            row([digit(7), digit(8), digit(9)]),
            const SizedBox(height: rowGap),
            row([
              const SizedBox(width: keySize, height: keySize),
              digit(0),
              _key(
                _delete,
                onTap: widget.onDelete,
                flat: true,
                child: Icon(Icons.backspace_outlined, size: 36, color: DashColors.ash),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

class _Key extends StatefulWidget {
  const _Key({required this.child, required this.onTap, required this.onDown, required this.enabled, this.flat = false});
  final Widget child;
  final VoidCallback onTap;
  final ValueChanged<bool> onDown;
  final bool enabled;
  final bool flat;

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> {
  bool _down = false;

  void _set(bool down) {
    widget.onDown(down);
    if (_down != down) setState(() => _down = down);
  }

  /// How far past its edge a finger may drift and still be on the key.
  static const slack = 16.0;

  int? _pointer;

  bool _on(Offset local) =>
      local.dx >= -slack && local.dy >= -slack && local.dx <= Keypad.keySize + slack && local.dy <= Keypad.keySize + slack;

  // A key is a button, not a tap gesture: it counts when the finger lifts
  // on it. As a tap it lost presses that slid a little or that another
  // gesture claimed. In one log three of fifteen presses on the passcode
  // gate lit the key and entered nothing, each held 53 to 93 ms and moved
  // 13 to 37 px. Sliding off the
  // key before lifting still takes the press back.
  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        if (_pointer != null) return;
        _pointer = e.pointer;
        _set(true);
      },
      onPointerMove: (e) {
        if (!mounted || e.pointer != _pointer || _on(e.localPosition)) return;
        _pointer = null;
        _set(false);
      },
      // A finger that lifts after the keypad has gone enters nothing.
      onPointerUp: (e) {
        if (!mounted || e.pointer != _pointer) return;
        _pointer = null;
        _set(false);
        HapticFeedback.lightImpact();
        widget.onTap();
      },
      onPointerCancel: (e) {
        if (!mounted || e.pointer != _pointer) return;
        _pointer = null;
        _set(false);
      },
      child: AnimatedScale(
        scale: _down ? 0.94 : 1,
        duration: DashMotion.fast,
        child: AnimatedContainer(
          duration: DashMotion.fast,
          width: Keypad.keySize,
          height: Keypad.keySize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.flat
                ? (_down ? DashColors.slate.withValues(alpha: 0.5) : Colors.transparent)
                // A touch of slate in the key face keeps it visible on the
                // Light theme, where inkLift is pure white.
                : (_down ? DashColors.slate.withValues(alpha: 0.9) : Color.lerp(DashColors.inkLift, DashColors.slate, 0.35)!),
            border: widget.flat
                ? null
                : Border.all(color: DashColors.slate.withValues(alpha: _down ? 1 : 0.9), width: 1.5),
          ),
          child: Center(child: widget.child),
        ),
      ),
    );
  }
}

/// Six PIN slots. Shakes and flashes red on failure, flashes mint on success.
class PinDots extends StatefulWidget {
  const PinDots({
    super.key,
    required this.filled,
    required this.shakeTrigger,
    required this.color,
  });

  final int filled;

  /// Any change to this value replays the shake.
  final int shakeTrigger;
  final Color color;

  static const count = 6;

  @override
  State<PinDots> createState() => _PinDotsState();
}

class _PinDotsState extends State<PinDots> with SingleTickerProviderStateMixin {
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );

  @override
  void didUpdateWidget(PinDots old) {
    super.didUpdateWidget(old);
    if (old.shakeTrigger != widget.shakeTrigger) _shake.forward(from: 0);
  }

  @override
  void dispose() {
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shake,
      builder: (context, child) {
        final t = _shake.value;
        final dx = math.sin(t * math.pi * 3) * 14 * (1 - t);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < PinDots.count; i++) ...[
            if (i > 0) const SizedBox(width: 36),
            AnimatedContainer(
              duration: DashMotion.fast,
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < widget.filled ? widget.color : Colors.transparent,
                border: Border.all(
                  color: i < widget.filled ? widget.color : DashColors.slate,
                  width: 2,
                ),
                boxShadow: i < widget.filled
                    ? [BoxShadow(color: widget.color.withValues(alpha: 0.45), blurRadius: 10)]
                    : null,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
