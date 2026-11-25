import 'package:material_ui/material_ui.dart' show TimeOfDay;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/prefs_service.dart';
import '../services/analytics_logger.dart';

/// Clock format. True is 24-hour ("14:32"), false is 12-hour ("2:32 PM").
final use24HourProvider = NotifierProvider<Use24Hour, bool>(Use24Hour.new);

class Use24Hour extends Notifier<bool> {
  @override
  bool build() => PrefsService.getBool(PrefsKeys.use24h, false);
  void set(bool on) {
    logSettingsChange('use24h', state, on);
    state = on;
    PrefsService.setBool(PrefsKeys.use24h, on);
  }
}

/// Labels are a fixed example date: the chips read as what they produce.
enum DateOrder {
  dayMonth('8 November'),
  monthDay('November 8');

  const DateOrder(this.label);
  final String label;
}

/// Lock screen date order only.
final dateOrderProvider = NotifierProvider<DateOrderNotifier, DateOrder>(DateOrderNotifier.new);

class DateOrderNotifier extends Notifier<DateOrder> {
  @override
  DateOrder build() {
    final saved = PrefsService.getString(PrefsKeys.lockDate, '');
    return DateOrder.values.cast<DateOrder?>().firstWhere((o) => o!.name == saved, orElse: () => null) ?? DateOrder.dayMonth;
  }

  void set(DateOrder order) {
    logSettingsChange('lockDate', state, order);
    state = order;
    PrefsService.setString(PrefsKeys.lockDate, order.name);
  }
}

/// Distance and speed in miles instead of km. Vehicle data stays metric;
/// only the display converts.
final useMilesProvider = NotifierProvider<UseMiles, bool>(UseMiles.new);

class UseMiles extends Notifier<bool> {
  @override
  bool build() => PrefsService.getBool(PrefsKeys.useMiles, false);
  void set(bool on) {
    logSettingsChange('useMiles', state, on);
    state = on;
    PrefsService.setBool(PrefsKeys.useMiles, on);
  }
}

final useFahrenheitProvider = NotifierProvider<UseFahrenheit, bool>(UseFahrenheit.new);

class UseFahrenheit extends Notifier<bool> {
  @override
  bool build() => PrefsService.getBool(PrefsKeys.useFahrenheit, false);
  void set(bool on) {
    logSettingsChange('useFahrenheit', state, on);
    state = on;
    PrefsService.setBool(PrefsKeys.useFahrenheit, on);
  }
}

const kmPerMile = 1.609344;

int toDisplayDistance(int km, bool useMiles) => useMiles ? (km / kmPerMile).round() : km;

double toDisplayDistanceD(double km, bool useMiles) => useMiles ? km / kmPerMile : km;

String distanceUnit(bool useMiles) => useMiles ? 'mi' : 'km';

String speedUnit(bool useMiles) => useMiles ? 'mph' : 'km/h';

int toDisplayTemp(int celsius, bool useFahrenheit) =>
    useFahrenheit ? (celsius * 9 / 5 + 32).round() : celsius;

String tempUnit(bool useFahrenheit) => useFahrenheit ? '°F' : '°C';

String formatClock(int hour, int minute, {required bool use24Hour}) {
  final mm = minute.toString().padLeft(2, '0');
  if (use24Hour) return '${hour.toString().padLeft(2, '0')}:$mm';
  final h = hour % 12 == 0 ? 12 : hour % 12;
  return '$h:$mm ${hour < 12 ? 'AM' : 'PM'}';
}

String formatTimeOfDay(TimeOfDay t, {required bool use24Hour}) =>
    formatClock(t.hour, t.minute, use24Hour: use24Hour);

const _days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String formatDate(DateTime d, {DateOrder order = DateOrder.dayMonth}) {
  final day = _days[d.weekday - 1];
  final month = _months[d.month - 1];
  return switch (order) {
    DateOrder.dayMonth => '$day ${d.day} $month',
    DateOrder.monthDay => '$day $month ${d.day}',
  };
}

/// "M:SS" for media positions and durations.
String formatSeconds(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
