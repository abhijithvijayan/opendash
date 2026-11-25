import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vehicle_data.dart';
import '../providers/mock_provider.dart';

enum ScreenState { booting, locked, parked, ready, riding, charging, sleep }

class SessionState {
  const SessionState({required this.booted, required this.asleep, this.noData = false});
  final bool booted;
  final bool asleep;

  /// The rider chose to enter the dashboard without HHMIS; the status bar
  /// flags the data as absent until the service connects.
  final bool noData;

  SessionState copyWith({bool? booted, bool? asleep, bool? noData}) =>
      SessionState(booted: booted ?? this.booted, asleep: asleep ?? this.asleep, noData: noData ?? this.noData);
}

final sessionProvider =
    NotifierProvider<SessionNotifier, SessionState>(SessionNotifier.new);

/// App-level state that is not vehicle data: whether the first HHMIS
/// handshake has completed, and whether the screen is asleep.
class SessionNotifier extends Notifier<SessionState> {
  /// Waiting out `VehicleNotifier.firstLockSettle` before the lock screen.
  Timer? _settle;

  @override
  SessionState build() {
    ref.onDispose(() => _settle?.cancel());
    void booted() {
      _settle?.cancel();
      _settle = null;
      if (!state.booted) state = state.copyWith(booted: true);
    }

    ref.listen(vehicleProvider.select((v) => v.hhmisConnected), (_, connected) {
      if (connected && !state.booted) {
        final settle = ref.read(vehicleProvider.notifier).firstLockSettle;
        if (!ref.read(vehicleProvider).locked || settle == Duration.zero) {
          booted();
        } else {
          _settle ??= Timer(settle, booted);
        }
      }
      if (connected && state.noData) state = state.copyWith(noData: false);
    });
    ref.listen(vehicleProvider.select((v) => v.locked), (_, locked) {
      if (!locked && _settle != null) booted();
    });
    return SessionState(
      booted: ref.read(vehicleProvider).hhmisConnected,
      asleep: false,
    );
  }

  void sleep() => state = state.copyWith(asleep: true);

  void wake() => state = state.copyWith(asleep: false);

  void reboot() {
    state = const SessionState(booted: false, asleep: false);
    ref.read(vehicleProvider.notifier).simulateBoot();
  }

  /// Boot timeout escape hatch: show the dashboard on last-known data.
  // TODO(no-data-path): no screen offers this any more (the start-up options lost "Continue without vehicle
  // data"). It and `noData` / `noDataVouched` stay until it is decided whether a no-data way
  // into the recovery tools is wanted back in another form; remove them together if not.
  void continueWithoutData() {
    _settle?.cancel();
    _settle = null;
    state = state.copyWith(booted: true, noData: true);
  }

  /// Dev: a boot where HHMIS never answers.
  void simulateAidlTimeout() {
    state = const SessionState(booted: false, asleep: false);
    ref.read(vehicleProvider.notifier).dropConnection();
  }
}

final screenStateProvider = Provider<ScreenState>((ref) {
  final session = ref.watch(sessionProvider);
  if (!session.booted) return ScreenState.booting;
  if (session.asleep) return ScreenState.sleep;
  final (charging, locked, vehicleState) = ref.watch(
    vehicleProvider.select((v) => (v.isCharging, v.locked, v.vehicleState)),
  );
  // Locked wins over charging: a scooter plugged in and locked still
  // needs the passcode keypad to be reachable. Observed on the scooter
  // when a lock-while-charging left the rider stuck on the charging screen
  // with no visible unlock path.
  if (locked) return ScreenState.locked;
  if (charging) return ScreenState.charging;
  return switch (vehicleState) {
    VehicleState.riding => ScreenState.riding,
    VehicleState.ready => ScreenState.ready,
    _ => ScreenState.parked,
  };
});
