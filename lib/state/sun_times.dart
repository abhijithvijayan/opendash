import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Today's sunrise and sunset as HHMIS reports them (callback TX 8, from
/// the range service's GPS position). Null until the first report, or when
/// a string does not parse.
class SunTimes {
  const SunTimes({this.sunrise, this.sunset});

  /// Stock `SettingsInfoManager.df` is "yyyy-MM-dd HH:mm:ss", local time,
  /// which `DateTime.tryParse` reads as local.
  factory SunTimes.parse(Object? sunrise, Object? sunset) => SunTimes(
        sunrise: sunrise is String ? DateTime.tryParse(sunrise.trim()) : null,
        sunset: sunset is String ? DateTime.tryParse(sunset.trim()) : null,
      );

  final DateTime? sunrise;
  final DateTime? sunset;

  bool get known => sunrise != null && sunset != null;

  /// Stock's fallback when the vehicle has not reported yet
  /// (`findDayOrNightNTriggerSmartLight`: "06:00:00" / "18:00:00").
  static const fallbackSunriseHour = 6;
  static const fallbackSunsetHour = 18;

  /// Day is strictly between sunrise and sunset, as stock compares it.
  /// The reported times carry a date; only the time of day is used, so a
  /// report from yesterday still gives the right answer today.
  bool isNight(DateTime now) {
    final minute = now.hour * 60 + now.minute;
    final rise = sunrise, set = sunset;
    final from = rise != null && set != null ? rise.hour * 60 + rise.minute : fallbackSunriseHour * 60;
    final until = rise != null && set != null ? set.hour * 60 + set.minute : fallbackSunsetHour * 60;
    return !(minute > from && minute < until);
  }

  @override
  bool operator ==(Object other) => other is SunTimes && other.sunrise == sunrise && other.sunset == sunset;

  @override
  int get hashCode => Object.hash(sunrise, sunset);
}

final sunTimesProvider = NotifierProvider<SunTimesNotifier, SunTimes>(SunTimesNotifier.new);

class SunTimesNotifier extends Notifier<SunTimes> {
  @override
  SunTimes build() => const SunTimes();

  void set(SunTimes times) => state = times;
}
