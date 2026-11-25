/// One firmware update Ola offered that OTA Shield held back, as its daemon
/// recorded it. [atMs] is the head unit's clock when it came, which may have
/// been the firmware build date if the network had not set it yet.
class OtaShieldOffer {
  const OtaShieldOffer({required this.atMs, required this.reminder, required this.upgrades});
  final int atMs;

  /// A repeat of an offer already made.
  final bool reminder;
  final List<OtaShieldUpgrade> upgrades;

  static OtaShieldOffer fromMap(Map<Object?, Object?> m) => OtaShieldOffer(
        atMs: (m['at'] as num?)?.toInt() ?? 0,
        reminder: m['reminder'] == true,
        upgrades: [
          for (final u in m['upgrades'] as List? ?? const [])
            if (u is Map) OtaShieldUpgrade.fromMap(u),
        ],
      );
}

class OtaShieldUpgrade {
  const OtaShieldUpgrade({required this.component, required this.from, required this.to, required this.bytes});
  final String component;
  final String from;
  final String to;
  final int bytes;

  static OtaShieldUpgrade fromMap(Map<Object?, Object?> m) => OtaShieldUpgrade(
        component: m['component'] as String? ?? '',
        from: m['from'] as String? ?? '',
        to: m['to'] as String? ?? '',
        bytes: (m['size'] as num?)?.toInt() ?? 0,
      );
}

/// What OTA Shield's own service says (1.1.0 on, its API version 2).
/// [activated] is OTA Shield's saved intent, not proof its daemon runs:
/// [OtaShieldReport.running] is that.
class OtaShieldService {
  const OtaShieldService({
    required this.activated,
    required this.failsafe,
    this.step,
    this.activation,
    this.activationStep,
    this.activationError,
  });
  final bool activated;

  /// Its boot fail-safe has cut the scooter off from Ola's cloud (port 443
  /// refused, cloud service stopped): no updates, but no Ola app either.
  final bool failsafe;

  /// Its activation step ("IDLE", "STARTING_DAEMON", "ACTIVATED", "FAILED").
  final String? step;

  /// The activation OpenDash started: "running", "done" or "failed".
  final String? activation;
  final String? activationStep;

  /// OTA Shield's own words for a failed activation; shown, never logged.
  final String? activationError;

  /// An activation is under way, OpenDash's or one started in OTA Shield.
  bool get activating => activation == 'running' || !const {null, 'IDLE', 'ACTIVATED', 'FAILED'}.contains(step);

  /// The step to show: OpenDash's own activation's, else OTA Shield's.
  String? get currentStep => activation == 'running' ? activationStep : step;

  static OtaShieldService? fromMap(Object? m) {
    if (m is! Map) return null;
    final a = m['activation'];
    return OtaShieldService(
      activated: m['activated'] == true,
      failsafe: m['failsafe'] == true,
      step: m['step'] as String?,
      activation: a is Map ? a['phase'] as String? : null,
      activationStep: a is Map ? a['step'] as String? : null,
      activationError: a is Map ? a['error'] as String? : null,
    );
  }
}

/// What OTA Shield's daemon answered on its local control port. Not
/// [running] when nothing answered: the block is off, or OTA Shield was
/// never activated since the head unit started. [service] is null for an
/// OTA Shield before 1.1.0, whose service OpenDash does not use.
class OtaShieldReport {
  const OtaShieldReport({
    required this.running,
    this.blocked,
    this.inBytes,
    this.outBytes,
    this.offerCount,
    this.offers = const [],
    this.service,
  });
  final bool running;

  /// Firmware messages dropped, as its daemon counts them.
  final int? blocked;

  /// Cloud traffic its daemon let through: the Ola app still works.
  final int? inBytes;
  final int? outBytes;

  /// Offers on its record, of which [offers] holds the newest few.
  final int? offerCount;
  final List<OtaShieldOffer> offers;
  final OtaShieldService? service;

  /// Its fail-safe is up: Ola can send nothing, so nothing gets through.
  bool get failsafe => service?.failsafe ?? false;

  /// Nothing Ola sends can reach the scooter: blocking, or cut off.
  bool get keepsUpdatesOut => running || failsafe;

  static const notRunning = OtaShieldReport(running: false);

  static OtaShieldReport fromMap(Map<Object?, Object?>? m) {
    final service = OtaShieldService.fromMap(m?['service']);
    if (m == null || m['running'] != true) return OtaShieldReport(running: false, service: service);
    return OtaShieldReport(
      running: true,
      blocked: (m['blocked'] as num?)?.toInt(),
      inBytes: (m['inBytes'] as num?)?.toInt(),
      outBytes: (m['outBytes'] as num?)?.toInt(),
      offerCount: (m['offerCount'] as num?)?.toInt(),
      offers: [
        for (final o in m['offers'] as List? ?? const [])
          if (o is Map) OtaShieldOffer.fromMap(o),
      ],
      service: service,
    );
  }
}
