import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/scooter_model.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/hhmis_mapping.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/providers/stock_profile.dart';
import 'package:opendash/providers/vehicle_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/state/riding_settings.dart';
import 'package:opendash/state/scooter_capabilities.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:opendash/theme/colors.dart';
import 'package:opendash/theme/dash_theme.dart';
import 'package:opendash/widgets/gauges/power_bar.dart';
import 'package:opendash/widgets/indicators/telltale_strip.dart';
import 'package:opendash/widgets/overlays/unchecked_scooter_dialog.dart';
import 'package:opendash/widgets/panel/performance_page.dart';
import 'package:opendash/widgets/panel/rpm_gauge.dart';
import 'dart:convert';
import 'package:opendash/services/prefs_service.dart';
import 'helpers/stock.dart';

/// Scales that follow the scooter instead
/// of one model's data sheet, and the guard for a scooter nobody checked.
void main() {
  group('the highest values the scooter has reported', () {
    test('grow, never shrink, and round so they are saved rarely', () {
      var p = const ScooterPeaks();
      p = p.seen(dischargeLimitW: 12232, regenLimitW: 5109, rpm: 27, torque: 41.2);
      expect((p.dischargeLimitW, p.regenLimitW, p.rpm, p.torque), (12300, 5200, 27, 42));
      final same = p.seen(dischargeLimitW: 9800, regenLimitW: 0, rpm: 3, torque: 2);
      expect(identical(same, p), isTrue);
      expect(identical(p.seen(dischargeLimitW: 12300, regenLimitW: 5200, rpm: -27, torque: -42), p), isTrue);
      expect(p.seen(dischargeLimitW: 0, regenLimitW: 0, rpm: -30, torque: double.nan).rpm, 30, reason: 'reverse counts by size');
    });

    test('survive a save and a damaged save', () {
      const p = ScooterPeaks(dischargeLimitW: 12300, regenLimitW: 5200, rpm: 37, torque: 58);
      expect(ScooterPeaks.decode(p.encode()), p);
      for (final bad in ['', '1|2|3', 'a|b|c|d|e', '2|-1|2|3|4']) {
        expect(ScooterPeaks.decode(bad), const ScooterPeaks(), reason: bad);
      }
    });

    test('a pre-schema blob is discarded, so a raw-rpm peak from a no-profile build cannot poison the gauge', () {
      // Build 335 (no MoveOS 5 profile) stored raw rpm; the old 4-field
      // format. It must not be read as hundreds (1711 -> 171,100 rpm).
      expect(ScooterPeaks.decode('12300|5400|1711|58'), const ScooterPeaks(), reason: 'old 4-field blob dropped');
      // A blob from a different schema is also dropped.
      expect(ScooterPeaks.decode('1|12300|5400|1711|58'), const ScooterPeaks(), reason: 'other schema dropped');
      // After the drop, the gauge scale is the default, not 172,000.
      expect(rpmMaxFor(ScooterPeaks.decode('12300|5400|1711|58').rpm * VehicleData.rpmUnit), 4000);
    });

    test('the notifier keeps them through a state built from scratch', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(vehicleProvider.notifier);
      n.state = n.state.copyWith(dischargePowerLimitW: 12232, regenPowerLimitW: 5109, rpm: 36, torque: 57.5);
      expect(c.read(vehicleProvider).peaks, const ScooterPeaks(dischargeLimitW: 12300, regenLimitW: 5200, rpm: 36, torque: 58));
      n.state = const VehicleData();
      expect(c.read(vehicleProvider).peaks.dischargeLimitW, 12300);
    });
  });

  group('scales', () {
    const learned = ScooterPeaks(dischargeLimitW: 15000, regenLimitW: 5200, rpm: 52, torque: 71);

    test('the power bar ends at the live limit, then the highest seen, then the S1 Pro figure', () {
      expect(powerBarMaxFor(const VehicleData(dischargePowerLimitW: 9800, peaks: learned)), closeTo(9.8 * HhmisPower.displayScale, 1e-6));
      expect(powerBarMaxFor(const VehicleData(peaks: learned)), closeTo(15 * HhmisPower.displayScale, 1e-6));
      expect(powerBarMaxFor(const VehicleData()), PowerBar.defaultMaxPower);
    });

    test('regen is drawn against the most the battery has ever accepted', () {
      expect(regenBarMaxFor(const VehicleData()), defaultMaxRegen);
      final max = regenBarMaxFor(const VehicleData(peaks: learned));
      expect(max, closeTo(5.2 * HhmisPower.displayScale, 1e-6));
      expect(powerBarFraction(-1.95, maxPower: 8, maxRegen: max), closeTo(1.95 / max, 1e-9));
      expect(powerFraction(-1.95, maxRegen: max), closeTo(-1.95 / max, 1e-9));
      expect(powerFraction(4, maxPower: 8), 0.5);
    });

    test('the regen share is of the highest limit seen, 1.5 kW only before any', () {
      expect(regenCapacity(const VehicleData(regenPowerLimitW: 1500)), 1);
      expect(regenCapacity(const VehicleData(regenPowerLimitW: 2600, peaks: learned)), 0.5);
    });

    test('the rpm dial and torque bar stretch for a scooter that goes past the S1 Pro figures', () {
      expect(rpmMaxFor(0), 4000);
      expect(rpmMaxFor(3700), 4000);
      expect(rpmMaxFor(5200), 6000);
      expect(rpmAngle(3000, 6000), rpmAngle(2000, 4000));
      expect(torqueMaxFor(0), 58);
      expect(torqueMaxFor(58), 58);
      expect(torqueMaxFor(71), 80);
    });
  });

  group('units', () {
    test('the speed limit and cruise tell-tales follow the miles setting', () {
      final r = RidingSettings(speedLimitEnabled: true, speedLimit: 80);
      final km = speedLimitTelltale(const VehicleData(speed: 10), r)!;
      expect((km.label, km.description), ('80', 'Speed limit warning — 80 km/h'));
      final mi = speedLimitTelltale(const VehicleData(speed: 10), r, DashTheme.dark, true)!;
      expect((mi.label, mi.description), ('50', 'Speed limit warning — 50 mph'));
      final cruise = telltalesFor(const VehicleData(cruiseMode: CruiseMode.active, speed: 64), DashTheme.dark, true).single;
      expect(cruise.description, 'Cruise control — active at 40 mph');
    });
  });

  group('a scooter nobody has checked', () {
    test('the model is named only when it is known', () {
      expect(ScooterModel.label(3), 'S1 Pro');
      expect(ScooterModel.label(8), 'Not checked (type 8)');
      expect(ScooterModel.label(null), '');
    });

    test('the dialog says which part is unchecked', () {
      final both = UncheckedScooterDialog.body(const UncheckedScooter(serviceVersion: '4.9.0', vehicleType: 8));
      expect(both, contains('4.9.0'));
      expect(both, contains('type 8'));
      final model = UncheckedScooterDialog.body(const UncheckedScooter(vehicleType: 8));
      expect(model, isNot(contains('are off until')));
    });

    test('the dialog says how the command list was come by', () {
      String body(String source) => UncheckedScooterDialog.body(UncheckedScooter(serviceVersion: '5.0.2', source: source));
      expect(body(StockIdentity.sourceRead), contains('read the scooter\'s own list'));
      expect(body(StockIdentity.sourceFixture), contains('the one recorded for this software'));
      expect(body(StockIdentity.sourceAssumed), contains('could do something other than what it says'));
      for (final source in [StockIdentity.sourceRead, StockIdentity.sourceFixture, StockIdentity.sourceAssumed]) {
        expect(body(source), contains('are off until you allow them'));
        expect(body(source), contains('5.0.2'));
      }
    });

    ({AidlVehicleNotifier n, StreamController<dynamic> events, List<String> calls, ProviderContainer c}) bridge() {
      AnalyticsLogger.instance.resetForTest();
      PrefsService.resetForTest();
      final events = StreamController<dynamic>();
      final calls = <String>[];
      final c = ProviderContainer(overrides: [
        vehicleProvider.overrideWith(() => AidlVehicleNotifier(
              events: events.stream,
              invoke: (m, a) async {
                calls.add(a is Map && a['cmd'] != null ? '$m ${a['cmd']}' : m);
                return true;
              },
            )),
      ]);
      return (n: c.read(vehicleProvider.notifier) as AidlVehicleNotifier, events: events, calls: calls, c: c);
    }

    void run(void Function(FakeAsync async, ({AidlVehicleNotifier n, StreamController<dynamic> events, List<String> calls, ProviderContainer c}) b) body) {
      fakeAsync((async) {
        final b = bridge();
        body(async, b);
        b.c.dispose();
        b.events.close();
      });
    }

    const mode = {'cmd': HhmisCmd.modeUpdate, 'value': 2};

    test('nothing numbered is sent before the scooter has said which software it has; named calls still go', () {
      run((async, b) {
        b.events.add({'_connected': true, 'INT_VEHICLE_STATE': 3});
        async.flushMicrotasks();
        b.calls.clear();
        b.n.debugSend('sendIntCmd', mode);
        b.n.debugSend('sendVoidCmd', {'cmd': HhmisCmd.projectLoaded});
        b.n.debugSend('setVolume', 40);
        async.flushMicrotasks();
        expect(b.calls, ['setVolume']);
        expect(b.n.unchecked.value, isNull, reason: 'nothing to ask the rider yet');
        final held = AnalyticsLogger.instance.recent('hhmis', 'cmd_held').map((e) => (e['data']! as Map)['why']).toSet();
        expect(held, {'identifying'});

        b.events.add({'_contract': stockContract('gen1-moveos4-4.6.14')});
        async.flushMicrotasks();
        b.n.debugSend('sendIntCmd', mode);
        async.flushMicrotasks();
        expect(b.calls, ['setVolume', 'sendIntCmd INT_MODE_UPDATE']);
      });
    });

    test('nothing is held on the software OpenDash has been ridden on, and the model it has been ridden on', () {
      run((async, b) {
        b.events.add({'_connected': true, '_contract': stockContract('gen1-moveos4-4.6.14'), 'INT_PROFILE_VEHICLE_TYPE': 3});
        async.flushMicrotasks();
        expect(b.n.unchecked.value, isNull);
        expect(b.n.software.value!.checked, isTrue);
        expect(b.c.read(vehicleProvider).vehicleType, 3);
        b.n.debugSend('sendIntCmd', mode);
        async.flushMicrotasks();
        expect(b.calls, contains('sendIntCmd INT_MODE_UPDATE'));
        expect(AnalyticsLogger.instance.recent('hhmis', 'contract').single['data'],
            {'service': '4.6.14', 'source': 'read', 'name': 'gen1-moveos4-4.6.14', 'profile': 'moveOs4', 'checked': true, 'digest': 'digest-of-gen1-moveos4-4.6.14', 'commands': 71});
      });
    });

    test('the same software, unreadable, is still the checked one by its version', () {
      run((async, b) {
        b.events.add({'_connected': true, '_contract': stockContract('gen1-moveos4-4.6.14', source: StockIdentity.sourceFixture)});
        async.flushMicrotasks();
        expect(b.n.unchecked.value, isNull);
      });
    });

    test('MoveOS 5: recognised, never ridden, so the rider is asked; then commands go by name', () {
      run((async, b) {
        b.events.add({'_connected': true, '_contract': stockContract('gen1-moveos5-5.0.2')});
        async.flushMicrotasks();
        expect(b.n.unchecked.value, const UncheckedScooter(serviceVersion: '5.0.2', source: 'read', known: 'gen1-moveos5-5.0.2'));
        b.calls.clear();
        for (final m in ['sendIntCmd', 'sendVoidCmd', 'sendBoolCmd', 'sendStringCmd']) {
          b.n.debugSend(m, {'cmd': HhmisCmd.modeUpdate, 'value': m == 'sendStringCmd' ? 'x' : m == 'sendBoolCmd' ? true : 2});
        }
        b.n.checkFirmwareUpdate();
        b.n.debugSend('setVolume', 40);
        async.flushMicrotasks();
        expect(b.calls, ['setVolume']);
        expect(AnalyticsLogger.instance.recent('hhmis', 'cmd_held'), hasLength(5));

        b.n.allowUnchecked();
        expect(b.n.unchecked.value, isNull);
        b.n.debugSend('sendIntCmd', {'cmd': HhmisCmd.autoDownloadUpdate, 'value': 0});
        b.n.debugSend('sendVoidCmd', {'cmd': HhmisCmd.highBeamOff});
        async.flushMicrotasks();
        expect(b.calls, ['setVolume', 'sendIntCmd AUTODOWNLOAD_UPDATE', 'sendVoidCmd PARTY_MODE_HIGH_BEAM_OFF']);
      });
    });

    test('the rider\'s answer is kept under the lists that were read, or the version when they could not be', () {
      expect(stockIdentity('gen1-moveos5-5.0.2').key, 'hhmis:digest-of-gen1-m');
      expect(StockIdentity.fromEvent({...stockContract('gen1-moveos5-5.0.2'), 'digest': 'another-build'}).key, 'hhmis:another-build');
      expect(StockIdentity.fromEvent(stockContract('gen1-moveos5-5.0.2', source: StockIdentity.sourceFixture)).key, 'hhmis:5.0.2');
      expect(StockIdentity.fromEvent(stockContract('gen1-moveos4-4.6.14', source: StockIdentity.sourceAssumed, version: '4.9.0')).key, 'hhmis:4.9.0');
    });

    test('software nobody has recorded and that could not be read: asked, and told it is a guess', () {
      run((async, b) {
        for (final version in ['4.9.0', '']) {
          b.events.add({'_connected': true, '_contract': stockContract('gen1-moveos4-4.6.14', source: StockIdentity.sourceAssumed, version: version)});
          async.flushMicrotasks();
          expect(b.n.unchecked.value, UncheckedScooter(serviceVersion: version, source: 'assumed', known: 'gen1-moveos4-4.6.14'));
          b.calls.clear();
          b.n.debugSend('sendIntCmd', mode);
          async.flushMicrotasks();
          expect(b.calls, isEmpty, reason: 'version "$version"');
        }
      });
    });

    test('a command the scooter\'s software does not have is not sent, allowed or not', () {
      run((async, b) {
        final contract = stockContract('gen1-moveos4-4.6.14');
        contract['commands'] = [...(contract['commands']! as List).where((c) => c != 'PREDICT_RANGE_TOGGLE')];
        b.events.add({'_connected': true, '_contract': contract});
        async.flushMicrotasks();
        b.calls.clear();
        b.n.debugSend('sendIntCmd', {'cmd': HhmisCmd.features[RidingFeature.predictedRange], 'value': 1});
        b.n.debugSend('sendIntCmd', mode);
        async.flushMicrotasks();
        expect(b.calls, ['sendIntCmd INT_MODE_UPDATE']);
        expect((AnalyticsLogger.instance.recent('hhmis', 'cmd_no_number').single['data']! as Map)['cmd'], 'PREDICT_RANGE_TOGGLE');
      });
    });

    test('"Not now" hides the dialog and keeps the commands held', () {
      run((async, b) {
        b.events.add({'_connected': true, '_contract': stockContract('gen1-moveos5-5.0.2')});
        async.flushMicrotasks();
        b.n.dismissUnchecked();
        b.calls.clear();
        b.n.debugSend('sendIntCmd', mode);
        b.events.add({'_contract': stockContract('gen1-moveos5-5.0.2')});
        async.flushMicrotasks();
        expect(b.n.unchecked.value, isNull);
        expect(b.calls, isEmpty);
      });
    });

    test('an unchecked model is announced and holds nothing', () {
      run((async, b) {
        b.events.add({'_connected': true, '_contract': stockContract('gen1-moveos4-4.6.14'), 'INT_PROFILE_VEHICLE_TYPE': 8});
        async.flushMicrotasks();
        expect(b.n.unchecked.value, const UncheckedScooter(vehicleType: 8));
        b.calls.clear();
        b.n.debugSend('sendIntCmd', mode);
        async.flushMicrotasks();
        expect(b.calls, contains('sendIntCmd INT_MODE_UPDATE'));
      });
    });

    test('vehicle states arrive as the app\'s own numbers: 7 is park assist (motor on, not reverse), -1 unknown', () {
      const base = VehicleData();
      final assist = applyHhmisUpdate(base, {'INT_VEHICLE_STATE': 7});
      expect(assist.reverse, isFalse);
      expect(assist.locked, isFalse);
      expect(assist.vehicleState, isNot(VehicleState.unknown));
      expect(assist.vehicleState, isNot(VehicleState.parked));
      expect(applyHhmisUpdate(base, {'INT_VEHICLE_STATE': 5}).reverse, isTrue);
      expect(applyHhmisUpdate(base, {'INT_VEHICLE_STATE': -1}).vehicleState, VehicleState.unknown);
    });

    test('rpm: MoveOS 5 sends whole rpm, 4.6.14 hundreds; both are held in hundreds', () {
      expect(StockProfile.of(stockIdentity('gen1-moveos4-4.6.14')), isNot(isA<MoveOs5Profile>()));
      expect(StockProfile.of(stockIdentity('gen1-moveos5-5.0.2')), isA<MoveOs5Profile>());
      expect(StockProfile.of(null).name, 'moveOs4', reason: 'not identified yet');
      expect(StockProfile.of(StockIdentity.fromEvent(stockContract('gen1-moveos4-4.6.14', source: StockIdentity.sourceAssumed, version: ''))).name, 'moveOs4');
      expect(StockProfile.of(StockIdentity.fromEvent(stockContract('gen1-moveos5-5.0.2', version: '6.1.0'))).name, 'moveOs5', reason: 'a later major is read as the latest known');
      for (final (name, sent, held) in [('gen1-moveos4-4.6.14', 17, 17), ('gen1-moveos5-5.0.2', 17, 0), ('gen1-moveos5-5.0.2', 3640, 36)]) {
        run((async, b) {
          b.events.add({'_connected': true, '_contract': stockContract(name)});
          b.events.add({'INT_VEHICLE_SPEED': 0, 'INT_VEHICLE_MOTOR_RPM': sent});
          async.flushMicrotasks();
          expect(b.c.read(vehicleProvider).rpm, held, reason: '$name sent $sent');
        });
      }
      run((async, b) {
        // A MoveOS 5 scooter standing still at 17 rpm: no
        // longer "speed not trusted".
        b.events.add({'_connected': true, '_contract': stockContract('gen1-moveos5-5.0.2')});
        b.events.add({'INT_VEHICLE_SPEED': 0, 'INT_VEHICLE_MOTOR_RPM': 17});
        async.flushMicrotasks();
        expect(b.c.read(vehicleProvider).speedRpmMismatch, isFalse);
      });
    });

    test('MoveOS 5 profile: slow charger, power-boost light at a stop, the toggle it ignores', () {
      Map<Object?, Object?> on5(Map<Object?, Object?> d) {
        const MoveOs5Profile().normalise(d);
        return d;
      }
      expect(on5({'INT_BOOST_HYPER_CHARGE_STATUS': 3}), {'INT_BOOST_HYPER_CHARGE_STATUS': 0});
      expect(on5({'INT_BOOST_HYPER_CHARGE_STATUS': 2}), {'INT_BOOST_HYPER_CHARGE_STATUS': 2});
      expect(on5({'INT_VEHICLE_SPEED': 0})['BOOL_VEHICLE_ADAPTIVE_POWER_BOOST_STATUS'], isFalse);
      expect(on5({'STR_VEHICLE_DRIVE_MODE': 'PARKED'})['BOOL_VEHICLE_ADAPTIVE_POWER_BOOST_STATUS'], isFalse);
      expect(on5({'INT_VEHICLE_SPEED': 12}), {'INT_VEHICLE_SPEED': 12});
      expect(on5({'INT_VEHICLE_COMMAND': 0}), {'INT_VEHICLE_COMMAND': 0, 'BOOL_ACCIDENT_SEVERITY_STAT': false});
      final four = {'INT_BOOST_HYPER_CHARGE_STATUS': 3, 'INT_VEHICLE_SPEED': 0, 'INT_VEHICLE_COMMAND': 152, 'INT_VEHICLE_MOTOR_RPM': 17};
      const StockProfile().normalise(four);
      expect(four, {'INT_BOOST_HYPER_CHARGE_STATUS': 3, 'INT_VEHICLE_SPEED': 0, 'INT_VEHICLE_COMMAND': 152, 'INT_VEHICLE_MOTOR_RPM': 17},
          reason: '4.6.14 is passed through untouched');

      final apb = HhmisCmd.features[RidingFeature.adaptivePowerBoost]!;
      expect(ScooterCapabilities(software: stockIdentity('gen1-moveos4-4.6.14')).feature(RidingFeature.adaptivePowerBoost), isTrue);
      expect(ScooterCapabilities(software: stockIdentity('gen1-moveos5-5.0.2')).sends(apb), isFalse);
      expect(ScooterCapabilities(software: stockIdentity('gen1-moveos5-5.0.2')).feature(RidingFeature.adaptivePowerBoost), isFalse);
      expect(ScooterCapabilities(software: stockIdentity('gen1-moveos5-5.0.2')).sends(HhmisCmd.unlockSeat), isTrue);
    });

    test('service 7.x (Gen 3 MoveOS 5): the MoveOS 5 rewrites, the power boost toggle back, volume echoes halved', () {
      final gen3 = stockIdentity('gen3-moveos5-7.1.30');
      final p = StockProfile.of(gen3);
      expect(p, isA<Service7Profile>());
      expect(p.name, 'service7');
      expect(ScooterCapabilities(software: gen3).feature(RidingFeature.adaptivePowerBoost), isTrue);
      final delta = <Object?, Object?>{'INT_VEHICLE_MOTOR_RPM': 3640, '_chimeVolume': 15, '_motorVolume': 9};
      p.normalise(delta);
      expect(delta['INT_VEHICLE_MOTOR_RPM'], 36);
      expect(delta['_chimeVolume'], 7);
      expect(delta['_motorVolume'], 5);
      final five = <Object?, Object?>{'_chimeVolume': 7};
      StockProfile.of(stockIdentity('gen1-moveos5-5.0.2')).normalise(five);
      expect(five['_chimeVolume'], 7, reason: '5.0.2 already echoes 0-7');
    });

    test('the log for a MoveOS 5 scooter: what the profile changed, and the rider\'s mode name by length only', () {
      run((async, b) {
        b.events.add({'_connected': true, '_contract': stockContract('gen1-moveos5-5.0.2')});
        b.events.add({'INT_VEHICLE_MOTOR_RPM': 1700, 'INT_VEHICLE_COMMAND': 152});
        b.events.add({'STR_VEHICLE_DRIVE_MODE': 'Ravi12'});
        b.events.add({'STR_VEHICLE_DRIVE_MODE': 'EASY PARK', 'INT_VEHICLE_DIRECTION': 1});
        async.flushMicrotasks();
        final rewrites = {
          for (final e in AnalyticsLogger.instance.recent('hhmis', 'profile_rewrite'))
            (e['data']! as Map)['key']: e['data'],
        };
        expect(rewrites['INT_VEHICLE_MOTOR_RPM'], {'profile': 'moveOs5', 'key': 'INT_VEHICLE_MOTOR_RPM', 'from': 1700, 'to': 17});
        expect((rewrites['BOOL_ACCIDENT_SEVERITY_STAT']! as Map)['command'], 152);
        final modes = [for (final e in AnalyticsLogger.instance.recent('hhmis', 'drive_mode')) e['data']];
        expect(modes, [
          {'value': 'CUSTOM'},
          {'value': 'EASY PARK'},
        ], reason: 'the rider\'s name never reaches the log');
        expect(AnalyticsLogger.instance.recent('hhmis', 'direction_change').single['data'], {'from': null, 'to': 1});
      });
      run((async, b) {
        b.events.add({'_connected': true, '_contract': stockContract('gen1-moveos4-4.6.14'), 'INT_VEHICLE_MOTOR_RPM': 17});
        async.flushMicrotasks();
        expect(AnalyticsLogger.instance.recent('hhmis', 'profile_rewrite'), isEmpty, reason: '4.6.14 is not rewritten');
      });
    });

    test('the custom ride mode (MoveOS 5): its values, and in use while the drive mode is the rider\'s name', () {
      run((async, b) {
        b.events.add({'_connected': true, '_contract': stockContract('gen1-moveos5-5.0.2')});
        b.events.add({
          'STR_CUSTOM_RIDE_MODE_NAME': 'Ravi12',
          'CUSTOM_RIDE_MODE': 1,
          'DEFAULT_RIDE_MODE': 0,
          'CUSTOM_RIDE_SPEED': 65,
          'CUSTOM_RIDE_POWER_TORQUE': 40,
          'CUSTOM_RIDE_THROTTLE_SENSITIVITY': 2,
          'CUSTOM_RIDE_REGEN_INTENSITY': 2,
          'INT_DIY_RANGE_CHANGED': 124,
          'STR_VEHICLE_DISTANCE_COVERED_IN_CUSTOM_MODE_FOR_THE_DAY': '3.4',
        });
        async.flushMicrotasks();
        final c = b.c.read(vehicleProvider).customRide;
        expect(c, const CustomRideMode(
          name: 'Ravi12', enabled: true, isDefault: false, topSpeedKmh: 65, powerPercent: 40, throttle: 2, regen: 2, rangeKm: 124, todayKm: 3.4));
        expect(c.label, 'Ravi12');
        expect(b.c.read(vehicleProvider).customRideActive, isFalse);
        expect(AnalyticsLogger.instance.recent('hhmis', 'unknown_key_seen'), isEmpty, reason: 'every custom-mode key has a home now');

        b.events.add({'INT_VEHICLE_STATE': 4, 'STR_VEHICLE_DRIVE_MODE': 'Ravi12'});
        async.flushMicrotasks();
        expect(b.c.read(vehicleProvider).customRideActive, isTrue);
        expect(b.c.read(accentProvider), DashTheme.dark.custom);

        b.events.add({'STR_VEHICLE_DRIVE_MODE': 'NORMAL'});
        async.flushMicrotasks();
        expect(b.c.read(vehicleProvider).customRideActive, isFalse);
        expect(b.c.read(vehicleProvider).driveMode, DriveMode.normal);
      });
    });

    String? lastToast() {
      final t = AnalyticsLogger.instance.recent('ui', 'toast');
      return t.isEmpty ? null : (t.last['data']! as Map)['message'] as String?;
    }

    test('a held command says why, and "Not now" is asked again when the rider tries a button', () {
      run((async, b) {
        b.c.listen(toastProvider, (_, _) {});
        b.events.add({'_connected': true, 'INT_VEHICLE_STATE': 3});
        async.flushMicrotasks();
        b.n.setSoundMood(1);
        async.flushMicrotasks();
        expect(lastToast(), 'Still reading the scooter\'s software. Try again in a moment');

        b.events.add({'_contract': stockContract('gen1-moveos5-5.0.2')});
        async.flushMicrotasks();
        b.n.dismissUnchecked();
        expect(b.n.unchecked.value, isNull);
        b.n.setSoundMood(1);
        async.flushMicrotasks();
        expect(lastToast(), 'Allow OpenDash on this scooter first');
        expect(b.n.unchecked.value?.serviceVersion, '5.0.2', reason: 'the dialog is back');
        expect(b.calls.where((c) => c.contains('INT_MODE_UPDATE')), isEmpty);
      });
    });

    test('a setting applied before the vehicle service is bound fails quietly; after, it says so', () {
      fakeAsync((async) {
        AnalyticsLogger.instance.resetForTest();
        PrefsService.resetForTest();
        final events = StreamController<dynamic>();
        final c = ProviderContainer(overrides: [
          vehicleProvider.overrideWith(() => AidlVehicleNotifier(events: events.stream, invoke: (m, a) async => false)),
        ]);
        c.listen(toastProvider, (_, _) {});
        final n = c.read(vehicleProvider.notifier);
        n.setBrightness(30, persist: false);
        async.flushMicrotasks();
        expect(lastToast(), isNull);
        events.add({'_connected': true});
        async.flushMicrotasks();
        n.setBrightness(30, persist: false);
        async.flushMicrotasks();
        expect(lastToast(), 'Scooter not connected');
        c.dispose();
        events.close();
      });
    });

    test('an unknown string is logged by its length, never its text', () {
      run((async, b) {
        b.events.add({'_connected': true, 'STR_LOCATION_UPDATE': '12.9716 77.5946', 'INT_BLE_CAPP_STATUS': 1});
        async.flushMicrotasks();
        final seen = {
          for (final e in AnalyticsLogger.instance.recent('hhmis', 'unknown_key_seen')) (e['data']! as Map)['key']: (e['data']! as Map)['value'],
        };
        expect(seen['STR_LOCATION_UPDATE'], 'string(15)');
        expect(seen['INT_BLE_CAPP_STATUS'], 1);
      });
    });
  });

  group('scripts/check-head-unit-contract.py', () {
    const script = 'scripts/check-head-unit-contract.py';
    final python = Process.runSync('which', ['python3']).exitCode == 0;

    Map<String, Object?> recorded(String name) => Directory('contracts')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .map((f) => jsonDecode(f.readAsStringSync()) as Map<String, Object?>)
        .firstWhere((f) => f['name'] == name);

    /// An apktool-shaped folder holding [contract].
    Directory fake(Map<String, Object?> contract, {String? version}) {
      final dir = Directory.systemTemp.createTempSync('contract');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/apktool.yml').writeAsStringSync('versionInfo:\n  versionName: ${version ?? contract['version']}\n');
      File('${dir.path}/AndroidManifest.xml').writeAsStringSync('<manifest package="${contract['package']}"/>');
      void enumFile(String path, List<Object?> names) {
        final cls = path.split('/').last;
        File('${dir.path}/smali/$path.smali')
          ..createSync(recursive: true)
          ..writeAsStringSync([
            '.method static constructor <clinit>()V',
            for (final (i, n) in names.indexed) ...[
              '    const-string v1, "$n"',
              '    const/16 v2, 0x${i.toRadixString(16)}',
              '    invoke-direct {v0, v1, v2}, L$path;-><init>(Ljava/lang/String;I)V',
            ],
            '.end method',
          ].join('\n'));
        expect(cls, isNotEmpty);
      }

      const parcelables = 'com/android/hmiserverapp/parcelables';
      enumFile('$parcelables/ClientCmd', contract['commands']! as List);
      enumFile('$parcelables/ServerCmd', contract['events']! as List);
      enumFile('$parcelables/VehicleStates', contract['states']! as List);
      enumFile('com/olaelectric/vehicleinterface/CommandFromVehicle', contract['vehicleCommands']! as List);
      for (final MapEntry(key: iface, value: calls) in (contract['calls']! as Map).entries) {
        File('${dir.path}/smali/com/android/hmiserverapp/$iface\$Stub.smali').writeAsStringSync([
          for (final MapEntry(key: method, value: code) in (calls as Map).entries)
            '.field static final TRANSACTION_$method:I = 0x${(code as int).toRadixString(16)}',
        ].join('\n'));
      }
      return dir;
    }

    Map<String, Object?> changed(String name, void Function(Map<String, Object?> c) change) {
      final c = jsonDecode(jsonEncode(recorded(name))) as Map<String, Object?>;
      change(c);
      return c;
    }

    test('knows the build OpenDash has been ridden on', () {
      final r = Process.runSync('python3', [script, fake(recorded('gen1-moveos4-4.6.14')).path]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(r.stdout, contains('checked: OpenDash has run on this build'));
      expect(r.stdout, contains('No differences in what OpenDash needs'));
    }, skip: !python);

    test('a build that renumbers commands is fine as long as every name is there, and the moves are listed', () {
      final r = Process.runSync('python3', [
        script,
        fake(changed('gen1-moveos4-4.6.14', (c) => (c['commands']! as List).insert(5, 'BOOL_SOMETHING_NEW')), version: '4.9.0').path,
      ]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(r.stdout, contains('NOT checked'));
      expect(r.stdout, contains('INT_ESCL_LOCK_CMD: 6 -> 7'));
      expect(r.stdout, contains('new: 5 BOOL_SOMETHING_NEW'));
      expect(r.stdout, isNot(contains('BOOL_TOUCH_STATUS: 2')), reason: 'entries before the new one did not move');
    }, skip: !python);

    test('the recorded MoveOS 5 lists pass, and are not called checked', () {
      final r = Process.runSync('python3', [script, fake(recorded('gen1-moveos5-5.0.2')).path]);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect(r.stdout, contains('(NOT checked)'));
      expect(r.stdout, isNot(contains('This was a copy of the lists')), reason: 'recorded from the 5.0.2 service itself');
      expect(recorded('gen1-moveos5-5.0.2')['package'], 'com.android.hmiserverapp');
      expect(recorded('gen1-moveos5-5.0.2')['states'], contains('UNKNOWN'), reason: 'the dashboard\'s copy left it out');
    }, skip: !python);

    test('fails when a command OpenDash sends is gone, and names it', () {
      final r = Process.runSync('python3', [
        script,
        fake(changed('gen1-moveos4-4.6.14', (c) => (c['commands']! as List).remove('HAZARD_LIGHT_TOGGLE'))).path,
      ]);
      expect(r.exitCode, 1);
      expect(r.stdout, contains('HAZARD_LIGHT_TOGGLE is not a command here'));
    }, skip: !python);

    test('fails when a call OpenDash makes has another code, or a never-made one lands on one it makes', () {
      final moved = Process.runSync('python3', [
        script,
        fake(changed('gen1-moveos4-4.6.14', (c) => ((c['calls']! as Map)['IClientServiceInterface'] as Map)['onIntegerHMICmd'] = 18)).path,
      ]);
      expect(moved.exitCode, 1);
      expect(moved.stdout, contains('TX_INT_CMD = 16 here, onIntegerHMICmd is 18'));
      final danger = Process.runSync('python3', [
        script,
        fake(changed('gen1-moveos4-4.6.14', (c) => ((c['calls']! as Map)['IClientServiceInterface'] as Map)['install'] = 16)).path,
      ]);
      expect(danger.exitCode, 1);
      expect(danger.stdout, contains('DANGER'));
    }, skip: !python);

    test('every command the app can send exists on every recorded build', () {
      final provider = File('lib/providers/vehicle_provider.dart').readAsStringSync();
      final body = provider.substring(provider.indexOf('abstract final class HhmisCmd {'), provider.indexOf('\n}\n', provider.indexOf('abstract final class HhmisCmd {')));
      final used = {for (final m in RegExp(r"'([A-Z][A-Z0-9_]{3,})'").allMatches(body)) m.group(1)!};
      expect(used.length, greaterThan(40));
      for (final name in ['gen1-moveos4-4.6.14', 'gen1-moveos5-5.0.2', 'gen3-moveos5-7.1.30']) {
        expect(used.difference({...(recorded(name)['commands']! as List)}), isEmpty, reason: name);
      }
    });

    test('the generated Kotlin lists are what contracts/ gives', () {
      final r = Process.runSync('python3', [script, '--emit-kotlin', '--check']);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    }, skip: !python);

    test('only the build OpenDash has been ridden on is marked checked', () {
      expect(recorded('gen1-moveos4-4.6.14')['checked'], isTrue);
      expect(recorded('gen1-moveos4-4.6.14')['package'], 'com.android.hmiserverapp', reason: 'from the service itself');
      expect(recorded('gen1-moveos5-5.0.2')['checked'], isFalse);
      expect(recorded('gen3-moveos5-7.1.30')['checked'], isFalse);
    });

    test('every recorded build says which scooter generation and MoveOS it came from', () {
      final files = Directory('contracts').listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
      expect(files.length, greaterThanOrEqualTo(3));
      final prefixes = <String>[];
      for (final f in files) {
        final c = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
        final generation = c['generation'], moveos = c['moveos'];
        expect(generation, isA<int>(), reason: f.path);
        expect(moveos, isA<int>(), reason: f.path);
        expect(c['scooter'], isA<String>(), reason: f.path);
        expect(c['name'], 'gen$generation-moveos$moveos-${c['version']}', reason: f.path);
        expect(c['moveosVersion'], isA<String>(), reason: f.path);
        expect(f.uri.pathSegments.last, 'gen$generation-moveos$moveos-hhmis-${c['version']}.json');
        final prefix = c['fallbackFor'] as String? ?? '';
        if (prefix.isNotEmpty) prefixes.add(prefix);
      }
      // Two generations can run builds whose versions share a prefix: a
      // fallback that covers another's would stand in for the wrong scooter.
      for (final a in prefixes) {
        for (final b in prefixes) {
          if (!identical(a, b)) expect(a.startsWith(b), isFalse, reason: '$a and $b overlap');
        }
      }
    });

    test('says so when it is pointed at something else', () {
      final r = Process.runSync('python3', [script, Directory.systemTemp.createTempSync('empty').path]);
      expect(r.exitCode, 2);
    }, skip: !python);
  });
}
