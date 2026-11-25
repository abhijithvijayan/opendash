/// Detects a cruise-control press that fails to engage, so the dash can tell
/// the rider why nothing happened. The press and engagement come from CAN
/// (`LiveInputs`); cruise itself is owned by the VCU, which OpenDash cannot
/// command. Timestamp-based, no timers: the caller runs [onUpdate] on each
/// vehicle update.
class CruiseWatch {
  static const armWindowMs = 1500;
  static const cooldownMs = 5000;

  bool _prevPressed = false;
  int? _pendingSinceMs;
  int _lastToastMs = -cooldownMs;

  /// Returns a toast message when a press has gone [armWindowMs] without
  /// engaging (and the cooldown has passed), otherwise null.
  String? onUpdate({
    required bool pressed,
    required bool engaged,
    int? availability,
    required int nowMs,
  }) {
    // While cruise is active a press means "turn it off" — never a failure.
    if (engaged) {
      _pendingSinceMs = null;
      _prevPressed = pressed;
      return null;
    }
    if (pressed && !_prevPressed) _pendingSinceMs = nowMs;
    _prevPressed = pressed;

    final since = _pendingSinceMs;
    if (since != null && nowMs - since >= armWindowMs) {
      _pendingSinceMs = null;
      if (nowMs - _lastToastMs >= cooldownMs) {
        _lastToastMs = nowMs;
        return _message(availability);
      }
    }
    return null;
  }

  String _message(int? availability) => switch (availability) {
        2 => 'Cruise not available in this mode',
        3 => 'Cruise: speed out of range',
        _ => 'Cruise unavailable',
      };
}
