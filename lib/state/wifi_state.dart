import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mock_provider.dart';
import 'riding_lockout.dart';
import 'toast_state.dart';

enum WifiNetwork { connected, saved, secured, open }

class WifiEntry {
  const WifiEntry(this.ssid, this.status, this.signalStrength, {required this.isSecured});
  final String ssid;
  final WifiNetwork status;

  /// 0-3 bars.
  final int signalStrength;
  final bool isSecured;

  WifiEntry withStatus(WifiNetwork s) => WifiEntry(ssid, s, signalStrength, isSecured: isSecured);

  String get signalLabel => switch (signalStrength) { 3 => 'Strong', 2 => 'Good', 1 => 'Fair', _ => 'Weak' };
  String get security => isSecured ? 'WPA2' : 'Open';
}

class WifiSettings {
  const WifiSettings({
    this.enabled = true,
    this.connectedSsid = 'HomeWifi_5G',
    this.networks = defaultNetworks,
    this.scanning = false,
  });

  static const defaultNetworks = [
    WifiEntry('HomeWifi_5G', WifiNetwork.connected, 3, isSecured: true),
    WifiEntry('Home_WiFi', WifiNetwork.saved, 2, isSecured: true),
    WifiEntry('Neighbor_Net', WifiNetwork.open, 2, isSecured: false),
    WifiEntry('Cafe_Guest', WifiNetwork.secured, 1, isSecured: true),
    WifiEntry('ServiceCenter', WifiNetwork.secured, 3, isSecured: true),
  ];


  final bool enabled;
  final String? connectedSsid;
  final List<WifiEntry> networks;
  final bool scanning;

  WifiEntry? get connected =>
      connectedSsid == null ? null : networks.cast<WifiEntry?>().firstWhere((n) => n!.ssid == connectedSsid, orElse: () => null);

  WifiSettings copyWith({bool? enabled, String? Function()? connectedSsid, List<WifiEntry>? networks, bool? scanning}) =>
      WifiSettings(
        enabled: enabled ?? this.enabled,
        connectedSsid: connectedSsid != null ? connectedSsid() : this.connectedSsid,
        networks: networks ?? this.networks,
        scanning: scanning ?? this.scanning,
      );
}

final wifiProvider = NotifierProvider<WifiNotifier, WifiSettings>(WifiNotifier.new);

/// Mock Wi-Fi. Connects and disconnects after a one second delay, scans for
/// two, and keeps the vehicle's wifiConnected flag in step.
class WifiNotifier extends Notifier<WifiSettings> {
  static const connectDelay = Duration(seconds: 1);
  static const scanDuration = Duration(seconds: 2);
  Timer? _timer;

  @override
  WifiSettings build() {
    ref.onDispose(() => _timer?.cancel());
    return const WifiSettings();
  }

  void _toast(String m, {ToastType type = ToastType.info, String? logAs}) =>
      ref.read(toastProvider.notifier).show(m, type: type, logAs: logAs);

  // On Android the real _wifi flag comes from
  // SystemStatus (ConnectivityManager). The mock Wi-Fi UI must not
  // overwrite it.
  void _syncVehicle() {
    if (useAidlVehicle) return;
    ref.read(vehicleProvider.notifier).setWifi(state.enabled && state.connectedSsid != null);
  }

  List<WifiEntry> _relabel(List<WifiEntry> nets, String? connected, {String? previouslyConnected}) => [
        for (final n in nets)
          if (n.ssid == connected)
            n.withStatus(WifiNetwork.connected)
          else if (n.ssid == previouslyConnected || n.status == WifiNetwork.connected)
            n.withStatus(WifiNetwork.saved)
          else
            n,
      ];

  void setEnabled(bool on) {
    _timer?.cancel();
    state = state.copyWith(
      enabled: on,
      scanning: false,
      connectedSsid: () => on ? state.connectedSsid : null,
      networks: on ? state.networks : _relabel(state.networks, null, previouslyConnected: state.connectedSsid),
    );
    _toast(on ? 'Wi-Fi turned on' : 'Wi-Fi turned off');
    _syncVehicle();
  }

  /// Saved and open networks connect after a delay; secured ones need a
  /// password, which waits for the Phase 2 keyboard.
  void connect(String ssid) {
    if (!state.enabled) return;
    final entry = state.networks.firstWhere((n) => n.ssid == ssid);
    if (entry.status == WifiNetwork.connected) return;
    if (entry.status == WifiNetwork.secured) {
      _toast('Password entry coming in Phase 2');
      return;
    }
    _timer?.cancel();
    _timer = Timer(connectDelay, () {
      _timer = null;
      state = state.copyWith(
        connectedSsid: () => ssid,
        networks: _relabel(state.networks, ssid, previouslyConnected: state.connectedSsid),
      );
      _toast('Connected to $ssid', logAs: 'Connected to <ssid>');
      _syncVehicle();
    });
  }

  void disconnect() {
    final ssid = state.connectedSsid;
    if (ssid == null) return;
    _timer?.cancel();
    _timer = Timer(connectDelay, () {
      _timer = null;
      state = state.copyWith(
        connectedSsid: () => null,
        networks: _relabel(state.networks, null, previouslyConnected: ssid),
      );
      _toast('Disconnected from $ssid', logAs: 'Disconnected from <ssid>');
      _syncVehicle();
    });
  }

  void scan() {
    if (!state.enabled || state.scanning) return;
    state = state.copyWith(scanning: true);
    _timer?.cancel();
    _timer = Timer(scanDuration, () {
      _timer = null;
      final nets = [...state.networks];
      final connected = nets.where((n) => n.status == WifiNetwork.connected).toList();
      final rest = nets.where((n) => n.status != WifiNetwork.connected).toList()
        ..sort((a, b) => b.signalStrength.compareTo(a.signalStrength));
      state = state.copyWith(scanning: false, networks: [...connected, ...rest]);
    });
  }

  void failConnection() => _toast('Connection failed', type: ToastType.warning);
}

final wifiDetailsOpenProvider = NotifierProvider<WifiDetailsOpen, bool>(WifiDetailsOpen.new);

class WifiDetailsOpen extends Notifier<bool> {
  @override
  bool build() {
    onRidingLockout(ref, () => state = false);
    return false;
  }

  void open() {
    if (ref.read(ridingLockoutProvider)) return;
    state = true;
  }

  void close() => state = false;
}
