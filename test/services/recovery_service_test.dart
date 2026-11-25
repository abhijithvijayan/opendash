import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/recovery_service.dart';
import 'package:opendash/services/uds_dtc.dart';
import 'package:opendash/services/wifican_codec.dart';

/// Records every executed command and returns a scripted response. Lets us
/// assert the whitelist without a live diagnostics_server.
class _FakeClient implements RecoveryClient {
  _FakeClient({this.ok = true, this.throwOnExecute = false, this.errorMessage = 'no', this.failAt, this.responseMessage = ''});
  bool ok;

  /// stdout the server returns (for read commands like the DTC read).
  String responseMessage;

  /// Index of the one command that answers RESP_FAIL.
  int? failAt;
  bool throwOnExecute;
  String errorMessage;
  final executed = <String>[];
  int shutdowns = 0;

  @override
  Future<WifiCanResponse> execute(String command, Duration timeout) async {
    if (throwOnExecute) throw Exception('rpc refused');
    executed.add(command);
    final pass = ok && executed.length - 1 != failAt;
    return WifiCanResponse(pass ? 1 : 2, pass ? responseMessage : errorMessage);
  }

  @override
  Future<void> shutdown() async {
    shutdowns++;
  }
}

void main() {
  setUp(AnalyticsLogger.instance.resetForTest);
  tearDown(AnalyticsLogger.instance.resetForTest);

  test('readFaults sends only the DTC read request and parses the response', () async {
    // MCU returns three stored codes (status 0x08 = not active).
    final fake = _FakeClient(responseMessage: '59 02 09 13 0E F0 08 13 1A F2 08 \n');
    final svc = RecoveryService(clientFactory: (_, _) => fake);
    final cat = parseDtcCatalog({
      'mcu': {'130EF0': 'Motor position sensor disconnected'},
    });
    final res = await svc.readFaults(DtcEcu.mcu, cat);
    expect(fake.executed.first, contains('7A6#0319020900000000'), reason: 'only the 19 02 09 read frame is sent');
    expect(fake.executed.first, isNot(contains('3101')), reason: 'no UDS RoutineControl (start)');
    expect(fake.executed.first, isNot(contains('05F8')), reason: 'no balancing routine');
    expect(fake.executed.first, isNot(contains('isotpsend')), reason: 'receive + one cansend only');
    expect(res.responded, isTrue);
    expect(res.dtcs.map((d) => d.code), ['130EF0', '131AF2']);
    expect(res.dtcs[0].description, 'Motor position sensor disconnected');
    expect(res.dtcs[1].description, startsWith('Unknown'));
    expect(res.dtcs.every((d) => !d.active), isTrue);
    expect(fake.shutdowns, 1);
  });

  test('readFaults reports no-response (and retries once) when the ECU is silent', () async {
    final fake = _FakeClient(responseMessage: ''); // asleep MCU: empty output
    final svc = RecoveryService(clientFactory: (_, _) => fake);
    final res = await svc.readFaults(DtcEcu.mcu, parseDtcCatalog(const <String, dynamic>{}));
    expect(res.responded, isFalse);
    expect(res.dtcs, isEmpty);
    expect(fake.executed.length, 2, reason: 'one retry on an empty reply');
  });

  test('rebootHeadUnit logs its intent first, then sends exactly reboot', () async {
    final fake = _FakeClient();
    final svc = RecoveryService(clientFactory: (_, _) => fake);
    expect(await svc.rebootHeadUnit(from: 'settings'), isTrue);
    expect(fake.executed, ['reboot']);
    final events = AnalyticsLogger.instance.recent('recovery').map((e) => e['evt']).toList();
    expect(events, ['reboot_scooter', 'action']);
  });

  test('forceStopStockDashboard sends exactly the whitelisted am force-stop command', () async {
    final fake = _FakeClient();
    final svc = RecoveryService(clientFactory: (_, _) => fake);
    final ok = await svc.forceStopStockDashboard();
    expect(ok, isTrue);
    expect(fake.executed, ['am force-stop com.olaelectric.hmiclient']);
    expect(fake.shutdowns, 1, reason: 'channel is closed after every call');
    final events = AnalyticsLogger.instance.recent('recovery', 'action');
    expect(events, hasLength(1));
    final data = events.single['data']! as Map<Object?, Object?>;
    expect(data['name'], 'force_stop_stock_dashboard');
    expect(data['success'], isTrue);
  });

  test('launchStockDashboard sends exactly the whitelisted am start command', () async {
    final fake = _FakeClient();
    final svc = RecoveryService(clientFactory: (_, _) => fake);
    final ok = await svc.launchStockDashboard();
    expect(ok, isTrue);
    expect(fake.executed, ['am start -n com.olaelectric.hmiclient/.MainActivity']);
  });

  const forceStop = 'am force-stop com.olaelectric.hmiclient';
  const start = 'am start -n com.olaelectric.hmiclient/.MainActivity';
  const wake = 'input keyevent KEYCODE_WAKEUP';
  const screensaverOff = 'settings put secure screensaver_enabled 0';

  Map<Object?, Object?> action() =>
      AnalyticsLogger.instance.recent('recovery', 'action').single['data']! as Map<Object?, Object?>;

  final actions = <String, (Future<bool> Function(RecoveryService), List<String>)>{
    'wake_and_disable_screensaver': ((s) => s.wakeAndDisableScreensaver(), [wake, screensaverOff]),
    'restart_stock_dashboard': ((s) => s.restartStockDashboard(), [forceStop, start]),
    'reset_display_density': ((s) => s.resetDisplayDensity(), ['wm density reset']),
  };

  for (final MapEntry(key: name, value: (call, commands)) in actions.entries) {
    test('$name sends exactly its commands, in order, over one channel', () async {
      final fake = _FakeClient();
      expect(await call(RecoveryService(clientFactory: (_, _) => fake)), isTrue);
      expect(fake.executed, commands);
      expect(fake.shutdowns, 1);
      expect(action()['name'], name);
      expect(action()['success'], isTrue);
      expect(action().containsKey('failed_step'), isFalse);
    });

    test('$name: a thrown error returns false and logs success:false', () async {
      final fake = _FakeClient(throwOnExecute: true);
      expect(await call(RecoveryService(clientFactory: (_, _) => fake)), isFalse);
      expect(fake.executed, isEmpty);
      expect(action()['name'], name);
      expect(action()['success'], isFalse);
      expect(action()['error'] as String, contains('rpc refused'));
      expect(fake.shutdowns, 1);
    });
  }

  test('restartStockDashboard does not start the dashboard when the force-stop is refused', () async {
    final fake = _FakeClient(failAt: 0, errorMessage: 'denied');
    expect(await RecoveryService(clientFactory: (_, _) => fake).restartStockDashboard(), isFalse);
    expect(fake.executed, [forceStop]);
    expect(action()['success'], isFalse);
    expect(action()['status_msg'], 'denied');
    expect(action()['failed_step'], 0);
  });

  test('wakeAndDisableScreensaver reports the step that failed', () async {
    final fake = _FakeClient(failAt: 1);
    expect(await RecoveryService(clientFactory: (_, _) => fake).wakeAndDisableScreensaver(), isFalse);
    expect(fake.executed, [wake, screensaverOff]);
    expect(action()['failed_step'], 1);
  });

  test('the whole whitelist: six strings, none of them pm', () async {
    final fake = _FakeClient();
    final svc = RecoveryService(clientFactory: (_, _) => fake);
    await svc.forceStopStockDashboard();
    await svc.launchStockDashboard();
    await svc.restartStockDashboard();
    await svc.wakeAndDisableScreensaver();
    await svc.resetDisplayDensity();
    await svc.rebootHeadUnit(from: 'test');
    expect(fake.executed.toSet(), {forceStop, start, wake, screensaverOff, 'wm density reset', 'reboot'});
    expect(fake.executed.any((c) => c.startsWith('pm ')), isFalse);
  });

  test('a failing gRPC call returns false and logs the error', () async {
    final fake = _FakeClient(throwOnExecute: true);
    final svc = RecoveryService(clientFactory: (_, _) => fake);
    final ok = await svc.forceStopStockDashboard();
    expect(ok, isFalse);
    final events = AnalyticsLogger.instance.recent('recovery', 'action');
    expect(events, hasLength(1));
    final data = events.single['data']! as Map<Object?, Object?>;
    expect(data['success'], isFalse);
    expect((data['error']! as String), contains('rpc refused'));
    expect(fake.shutdowns, 1, reason: 'channel still closes on failure');
  });

  test('a RESP_FAIL status is reported as success:false with the server message', () async {
    final fake = _FakeClient(ok: false, errorMessage: 'nope');
    final svc = RecoveryService(clientFactory: (_, _) => fake);
    final ok = await svc.forceStopStockDashboard();
    expect(ok, isFalse);
    final data = AnalyticsLogger.instance.recent('recovery', 'action').single['data']! as Map<Object?, Object?>;
    expect(data['success'], isFalse);
    expect(data['status_msg'], 'nope');
  });

  test('a call that encodes correctly on the wire (round-trip through encodeCommand)', () {
    expect(encodeCommand('am force-stop com.olaelectric.hmiclient').first, 0x0a,
        reason: 'field 1, wire type 2');
    expect(encodeCommand(''), isEmpty);
  });
}
