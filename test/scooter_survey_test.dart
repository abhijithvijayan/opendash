import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/scooter_survey.dart';

/// The log has to describe a scooter nobody has seen without naming it or
/// its rider.
void main() {
  setUp(AnalyticsLogger.instance.resetForTest);

  Uint8List frame(int id, List<int> data) =>
      Uint8List.fromList([(id >> 24) & 255, (id >> 16) & 255, (id >> 8) & 255, id & 255, 8, 0, 0, 0, ...data]);

  /// Little-endian millivolt words.
  List<int> mv(List<int> cells) => [for (final c in cells) ...[c & 255, c >> 8], for (var i = cells.length; i < 4; i++) ...[0, 0]];

  List<String> rows(String evt) =>
      [for (final e in AnalyticsLogger.instance.recent('survey', evt)) ...((e['data'] as Map)['rows'] as List).cast<String>()];

  Map<String, String> values() => {for (final r in rows('values')) r.split('|').first: r.substring(r.indexOf('|') + 1)};

  test('each value is recorded by type, count, range and the values it took', () {
    final s = ScooterSurvey();
    s.note({'INT_PROFILE_VEHICLE_TYPE': 3, 'INT_VEHICLE_STATE': 3, 'FLOAT_VEHICLE_VOLTAGE': 52.4567, 'BOOL_HIGH_BEAM_STATUS': false});
    s.note({'INT_VEHICLE_STATE': 4, 'FLOAT_VEHICLE_VOLTAGE': 51.2, 'STR_VEHICLE_DRIVE_MODE': 'NORMAL', '_hhmis': '4.6.14'});
    s.note({'STR_VEHICLE_DRIVE_MODE': 'HYPER', 'BOOL_HIGH_BEAM_STATUS': true});
    s.emit('test');
    final v = values();
    expect(v['INT_PROFILE_VEHICLE_TYPE'], 'int|1|3|3|3');
    expect(v['INT_VEHICLE_STATE'], 'int|2|3|4|3,4');
    expect(v['FLOAT_VEHICLE_VOLTAGE'], 'double|2|51.2|52.46|52.46,51.2');
    expect(v['BOOL_HIGH_BEAM_STATUS'], 'bool|2|||false,true');
    expect(v['STR_VEHICLE_DRIVE_MODE'], 'string|2|||NORMAL,HYPER');
    expect(v['_hhmis'], 'string|1|||4.6.14');
  });

  test('nothing that names the rider or the scooter is written', () {
    final s = ScooterSurvey(isText: (k) => k == '_hwInfo_1');
    const secrets = ['MB8XYZ1234567890A', '8991000012345678901', 'Asha', 'Asha phone', '+919812345678', 'AA:BB:CC:DD:EE:FF', '4321'];
    s.note({
      '_hwInfo_9': secrets[0],
      '_hwInfo_10': secrets[1],
      'STR_PROFILE_USER_NAME': secrets[2],
      '_btName': secrets[3],
      'STR_CUSTOMER_SUPPORT_NUMBER': secrets[4],
      '_btMac': secrets[5],
      'STR_PROFILE_PASSCODE': secrets[6],
      'FLOAT_NAVI_LATITUDE': 12.9716,
      'FLOAT_GEO_LONGITUDE': 77.5946,
      'STR_SOMETHING_NEW': 'free text nobody has classified',
      '_hwInfo_1': 'BMS 2.1.7',
    });
    s.emit('test');
    final text = jsonEncode(AnalyticsLogger.instance.recent('survey', 'values'));
    for (final secret in [...secrets, '12.97', '77.59', 'free text']) {
      expect(text.contains(secret), isFalse, reason: secret);
    }
    final v = values();
    expect(v['STR_SOMETHING_NEW'], 'string|1|||len31', reason: 'an unclassified string is only its length');
    expect(v['_hwInfo_9'], 'string|1|||len17');
    expect(v['FLOAT_NAVI_LATITUDE'], 'double|1|||', reason: 'a private key gives its type and count only');
    expect(v['_hwInfo_1'], 'string|1|||BMS 2.1.7', reason: 'ECU software versions are kept');
  });

  test('a value that keeps changing does not grow the log', () {
    final s = ScooterSurvey();
    for (var i = 0; i < 500; i++) {
      s.note({'INT_VEHICLE_SPEED': i % 90});
    }
    s.emit('test');
    final row = values()['INT_VEHICLE_SPEED']!;
    expect(row.startsWith('int|500|0|89|'), isTrue);
    expect(row.endsWith(',+'), isTrue);
    expect(row.split('|').last.split(',').length, 17);
  });

  test('battery frames keep their length, first and last bytes and which bits moved', () {
    final s = ScooterSurvey();
    s.noteFrame(frame(0x1A5, mv([3900, 3910, 3640, 3905])));
    s.noteFrame(frame(0x1A5, mv([3900, 3911, 3640, 3905])));
    s.noteFrame(Uint8List.fromList([1, 2, 3]));
    s.emit('test');
    expect(rows('frames').single, '1a5|2|16|8|3c0f460f380e410f|3c0f470f380e410f|0000010000000000');
  });

  test('rpm per km/h is the median of what was ridden, above walking pace only', () {
    final s = ScooterSurvey();
    s.note({'INT_VEHICLE_SPEED': 10, 'INT_VEHICLE_MOTOR_RPM': 9});
    expect(s.rpmPerKmh, (null, 0));
    for (final (speed, rpm) in [(40, 12), (60, 19), (80, 25), (100, 31), (50, 99)]) {
      s.note({'INT_VEHICLE_SPEED': speed, 'INT_VEHICLE_MOTOR_RPM': rpm});
    }
    final (ratio, samples) = s.rpmPerKmh;
    expect(samples, greaterThanOrEqualTo(5));
    expect(ratio, closeTo(0.31, 0.02));
  });

  test('a snapshot is written when the scooter locks, and not again with nothing new', () {
    final s = ScooterSurvey();
    s.note({'INT_VEHICLE_STATE': 3, 'INT_BATTERY_SOC': 80});
    expect(AnalyticsLogger.instance.recent('survey', 'values'), isEmpty);
    s.note({'INT_VEHICLE_STATE': 0});
    expect((AnalyticsLogger.instance.recent('survey', 'values').single['data'] as Map)['reason'], 'lock');
    s.note({'INT_VEHICLE_STATE': 0});
    expect(AnalyticsLogger.instance.recent('survey', 'values'), hasLength(1));
  });
}
