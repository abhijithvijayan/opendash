import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:grpc/grpc.dart';

import 'analytics_logger.dart';
import 'uds_dtc.dart';
import 'wifican_codec.dart';

/// Whitelisted `am` / shell actions invoked over the localhost
/// `diagnostics_server` gRPC (`wifican.WifiCanRpc/ExecuteADBCommand`,
/// 127.0.0.1:50005). Added after verifying with the decompiled HOHS
/// watchdog that HHMIC is NOT in its PROCESS_LIST — force-stopping it does
/// not trigger HOHS's SOM reboot.
///
/// Strictly hard-coded commands; no public `exec(String)` because the
/// writes policy forbids free-form shell.
abstract class RecoveryClient {
  Future<WifiCanResponse> execute(String command, Duration timeout);
  Future<void> shutdown();
}

class _GrpcRecoveryClient extends Client implements RecoveryClient {
  _GrpcRecoveryClient(this._channel) : super(_channel);
  final ClientChannel _channel;

  static final _executeAdbCommand = ClientMethod<List<int>, WifiCanResponse>(
    '/wifican.WifiCanRpc/ExecuteADBCommand',
    (cmd) => cmd,
    (bytes) => decodeResponse(bytes),
  );

  @override
  Future<WifiCanResponse> execute(String command, Duration timeout) {
    final call = $createUnaryCall(
      _executeAdbCommand,
      encodeCommand(command),
      options: CallOptions(timeout: timeout),
    );
    return call;
  }

  @override
  Future<void> shutdown() => _channel.shutdown();
}

class RecoveryService {
  RecoveryService({
    this.host = '127.0.0.1',
    this.port = 50005,
    this.timeout = const Duration(seconds: 5),
    RecoveryClient Function(String host, int port)? clientFactory,
  }) : _clientFactory = clientFactory ??
            ((h, p) => _GrpcRecoveryClient(ClientChannel(
                  h,
                  port: p,
                  options: const ChannelOptions(
                    credentials: ChannelCredentials.insecure(),
                    idleTimeout: Duration(seconds: 1),
                  ),
                )));

  final String host;
  final int port;
  final Duration timeout;
  final RecoveryClient Function(String host, int port) _clientFactory;

  /// Times this process has started the stock dashboard. Its `onStop`
  /// unregisters HSSS's Bluetooth receivers, so the Bluetooth settings
  /// notifier registers them again after a launch.
  static int stockLaunches = 0;

  static const _forceStopStock = 'am force-stop com.olaelectric.hmiclient';
  static const _startStock = 'am start -n com.olaelectric.hmiclient/.MainActivity';

  static const _package = 'in.abhijithvijayan.opendash';

  /// The commands that switch on OpenDash's own Android accesses, by
  /// `Access` name. Like everything this service sends, a fixed list: each
  /// one changes a setting for OpenDash's package only.
  static const accessGrants = {
    'overlay': 'appops set $_package SYSTEM_ALERT_WINDOW allow',
    'install': 'appops set $_package REQUEST_INSTALL_PACKAGES allow',
    'music': 'cmd notification allow_listener $_package/$_package.ProjectionMediaListener',
    'front': 'appops set $_package GET_USAGE_STATS allow',
    'home': 'cmd package set-home-activity $_package/.MainActivity',
  };

  /// Switches on one of OpenDash's Android accesses, so the rider need not
  /// find Android's page for it. True when the service ran the command;
  /// whether the access is on is read back from Android, not taken from
  /// this. Confirmed on the scooter for all five.
  Future<bool> grantAccess(String access) {
    final command = accessGrants[access];
    if (command == null) return Future.value(false);
    return _run([command], name: 'grant_$access');
  }

  /// Kills stock HHMIC. No-op if it was not running.
  Future<bool> forceStopStockDashboard() => _run(
        const [_forceStopStock],
        name: 'force_stop_stock_dashboard',
      );

  /// Brings up the stock dashboard's main activity. User returns to
  /// OpenDash by using stock Settings → Restart (or waiting for the daily
  /// silent reboot in HVSM).
  Future<bool> launchStockDashboard() {
    stockLaunches++;
    return _run(const [_startStock], name: 'launch_stock_dashboard');
  }

  /// A stock dashboard that came up white or frozen (seen after a
  /// Doze → wake cycle): kill it and start it again. It ends up in front.
  Future<bool> restartStockDashboard() {
    stockLaunches++;
    return _run(const [_forceStopStock, _startStock], name: 'restart_stock_dashboard');
  }

  /// Wakes a display stuck off or on the screensaver and keeps the
  /// screensaver from coming back.
  Future<bool> wakeAndDisableScreensaver() => _run(
        const ['input keyevent KEYCODE_WAKEUP', 'settings put secure screensaver_enabled 0'],
        name: 'wake_and_disable_screensaver',
      );

  /// Drops a `wm density` override (the deploy script sets 160), for when
  /// one leaves the stock dashboard or another app laid out wrong.
  Future<bool> resetDisplayDensity() => _run(
        const ['wm density reset'],
        name: 'reset_display_density',
      );

  /// Reboots the head unit only (HVSM's `rebootSOM` path), for the
  /// Recovery panel; Restart scooter uses the HHMIS command. The
  /// intent is logged and flushed first: the reboot can cut the log write.
  Future<bool> rebootHeadUnit({required String from}) async {
    logEvent('recovery', 'reboot_scooter', {'via': 'shell', 'from': from});
    await AnalyticsLogger.instance.flush();
    return _run(const ['reboot'], name: 'reboot_scooter');
  }

  /// The one CAN-transmitting command this service sends: a UDS
  /// ReadDTCInformation (19 02 09) to [ecu] over ISO-TP. `isotprecv` receives
  /// and auto-sends flow control; `cansend` transmits the single read frame.
  /// Fixed per ECU (only the read request is ever sent — never arbitrary
  /// frames). ${IFS} stands in for spaces so the daemon keeps it as one arg.
  static String dtcReadCommand(DtcEcu ecu) {
    final (tx, rx) = ecuCanIds(ecu);
    final t = tx.toRadixString(16).toUpperCase().padLeft(3, '0');
    final r = rx.toRadixString(16).toUpperCase().padLeft(3, '0');
    return 'sh -c timeout\${IFS}3\${IFS}isotprecv\${IFS}-s\${IFS}0x$t\${IFS}-d\${IFS}0x$r'
        '\${IFS}vcan0\${IFS}&\${IFS}sleep\${IFS}0.4;\${IFS}cansend\${IFS}vcan0\${IFS}$t#0319020900000000;\${IFS}wait';
  }

  /// Reads the stored/active trouble codes from [ecu] and resolves them to
  /// named faults via [catalog]. Read-only diagnostic: the only thing sent is
  /// the ReadDTCInformation request. Retries once if the first attempt gets no
  /// bytes (the isotprecv/cansend timing can miss a frame). A still-empty reply
  /// means the ECU did not answer — e.g. the MCU asleep while parked.
  Future<EcuFaultResult> readFaults(DtcEcu ecu, DtcCatalog catalog) async {
    final start = AnalyticsLogger.instance.monoMicros;
    RecoveryClient? client;
    try {
      client = _clientFactory(host, port);
      var payload = parseIsotpHex((await client.execute(dtcReadCommand(ecu), timeout)).message);
      if (payload.isEmpty) {
        payload = parseIsotpHex((await client.execute(dtcReadCommand(ecu), timeout)).message);
      }
      final result = ecuFaultResult(ecu, payload, catalog);
      logEvent('recovery', 'read_faults', {
        'ecu': ecu.name,
        'responded': result.responded,
        'count': result.dtcs.length,
        'active': result.dtcs.where((d) => d.active).length,
        'took_ms': (AnalyticsLogger.instance.monoMicros - start) ~/ 1000,
      });
      return result;
    } catch (e) {
      debugPrint('[recovery] read_faults ${ecu.name} failed: $e');
      logEvent('recovery', 'read_faults', {'ecu': ecu.name, 'responded': false, 'error': e.toString()});
      return const EcuFaultResult(false, []);
    } finally {
      await client?.shutdown();
    }
  }

  /// Sends [commands] in order over one channel and stops at the first that
  /// fails; one `recovery.action` for the whole action.
  Future<bool> _run(List<String> commands, {required String name}) async {
    final start = AnalyticsLogger.instance.monoMicros;
    RecoveryClient? client;
    var step = 0;
    try {
      client = _clientFactory(host, port);
      var ok = true;
      var message = '';
      for (; step < commands.length && ok; step++) {
        final result = await client.execute(commands[step], timeout);
        ok = result.ok;
        message = result.message;
      }
      logEvent('recovery', 'action', {
        'name': name,
        'success': ok,
        'took_ms': (AnalyticsLogger.instance.monoMicros - start) ~/ 1000,
        if (!ok) 'status_msg': message,
        if (!ok && commands.length > 1) 'failed_step': step - 1,
      });
      return ok;
    } catch (e) {
      debugPrint('[recovery] $name failed: $e');
      logEvent('recovery', 'action', {
        'name': name,
        'success': false,
        'took_ms': (AnalyticsLogger.instance.monoMicros - start) ~/ 1000,
        'error': e.toString(),
        if (commands.length > 1) 'failed_step': step,
      });
      return false;
    } finally {
      await client?.shutdown();
    }
  }
}

/// Default singleton the dashboard reaches for. Tests override via
/// construction + inject their own `clientFactory`.
RecoveryService recoveryService = RecoveryService();
