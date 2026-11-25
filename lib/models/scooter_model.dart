/// What OpenDash knows about scooter models, keyed by the number the
/// scooter reports (`INT_PROFILE_VEHICLE_TYPE`). One model has been
/// checked: the S1 Pro Gen 1. Add another only from evidence (a log or a
/// decompile from that model), never from a data sheet guess. The stock
/// apps hold two tables of model numbers that disagree on names, so a
/// name alone is not evidence either.
abstract final class ScooterModel {
  static const _names = {3: 'S1 Pro'};

  /// The model's name, or null for a number nobody has checked.
  static String? nameFor(int? type) => _names[type];

  /// For Settings: never a guess.
  static String label(int? type) => type == null ? '' : nameFor(type) ?? 'Not checked (type $type)';
}

/// Which build of the stock vehicle service this scooter has, as Kotlin
/// found out before it bound to it (`hhmis/StockContract.kt`, the
/// `_contract` event). Names only: the numbers stay on the Kotlin side.
class StockIdentity {
  const StockIdentity({
    required this.version,
    required this.source,
    this.name = '',
    this.checked = false,
    this.digest = '',
    this.commands = const {},
    this.states = const {},
  });

  factory StockIdentity.fromEvent(Map<Object?, Object?> e) => StockIdentity(
        version: e['version'] as String? ?? '',
        source: e['source'] as String? ?? sourceAssumed,
        name: e['name'] as String? ?? '',
        checked: e['checked'] == true,
        digest: e['digest'] as String? ?? '',
        commands: {...(e['commands'] as List? ?? const []).whereType<String>()},
        states: {...(e['states'] as List? ?? const []).whereType<String>()},
      );

  /// The lists were read from the service on this scooter.
  static const sourceRead = 'read';

  /// They could not be read; a build recorded for this version stands in.
  static const sourceFixture = 'fixture';

  /// They could not be read and nothing is recorded for this version: the
  /// lists of the build OpenDash was made on are used, which may be wrong.
  static const sourceAssumed = 'assumed';

  /// The service's version as Android reports it; empty when it cannot.
  final String version;
  final String source;

  /// The recorded build these lists are (`contracts/*.json`); empty for
  /// one nobody has recorded.
  final String name;

  /// OpenDash has been ridden on exactly this build.
  final bool checked;
  final String digest;

  /// Every stock command this build has, and every vehicle state.
  final Set<String> commands;
  final Set<String> states;

  /// What the rider's "Use OpenDash here" is remembered under: the lists
  /// themselves when they were read, the version otherwise.
  String get key => source == sourceRead ? 'hhmis:${digest.length > 16 ? digest.substring(0, 16) : digest}' : 'hhmis:$version';
}

/// A build of the stock software or a model number OpenDash has not been
/// checked on, waiting for the rider's answer.
class UncheckedScooter {
  const UncheckedScooter({this.serviceVersion, this.vehicleType, this.source = '', this.known = ''});

  /// Set when the numbered commands are being held for it.
  final String? serviceVersion;
  final int? vehicleType;

  /// [StockIdentity.source] and [StockIdentity.name] of that software.
  final String source;
  final String known;

  @override
  bool operator ==(Object other) =>
      other is UncheckedScooter &&
      other.serviceVersion == serviceVersion &&
      other.vehicleType == vehicleType &&
      other.source == source &&
      other.known == known;

  @override
  int get hashCode => Object.hash(serviceVersion, vehicleType, source, known);
}
