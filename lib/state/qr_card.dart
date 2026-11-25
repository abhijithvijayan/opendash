import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants.dart';
import '../models/scooter_model.dart';
import '../models/vehicle_data.dart';
import '../providers/mock_provider.dart';
import '../services/analytics_logger.dart';
import '../services/build_info.dart';
import 'riding_lockout.dart';
import 'scooter_capabilities.dart';

/// A web address shown as a QR code for the rider's phone (`QrCardDialog`):
/// a link is not something anyone can follow from a scooter.
class QrCard {
  const QrCard({required this.id, required this.title, required this.caption, required this.url, required this.shown});

  /// For the log.
  final String id;
  final String title;
  final String caption;

  /// What the code holds.
  final String url;

  /// The address as printed under the caption.
  final String shown;
}

/// The QR card on screen, or null. Closed when riding starts.
final qrCardProvider = NotifierProvider<QrCardNotifier, QrCard?>(QrCardNotifier.new);

class QrCardNotifier extends Notifier<QrCard?> {
  @override
  QrCard? build() {
    onRidingLockout(ref, close);
    return null;
  }

  void show(QrCard card, {required String from}) {
    uiTap('qr-card', {'card': card.id, 'from': from});
    state = card;
  }

  /// A new issue, with the scooter as it is now filled in.
  void reportIssue({required String from}) => show(
        QrCard(
          id: 'report-issue',
          title: 'Report an issue',
          caption:
              'Scan with your phone to open a new issue on GitHub. The OpenDash and MoveOS versions and the scooter model are filled in; nothing that identifies you or your scooter is.',
          url: reportIssueUrlFor(ref.read(vehicleProvider), ref.read(scooterCapabilitiesProvider).software),
          shown: issuesUrl,
        ),
        from: from,
      );

  /// The companion phone app's download page.
  void companionApp({required String from}) => show(
        const QrCard(
          id: 'companion',
          title: 'OpenDash Companion',
          caption:
              'Scan with your phone to download the companion app. It installs, updates and removes OpenDash from your phone, and sends updates to the scooter when it can\'t reach GitHub.',
          url: 'https://$companionRepoUrl/releases/latest',
          shown: companionRepoUrl,
        ),
        from: from,
      );

  void close() => state = null;
}

/// A new issue with what is needed to read it filled in: the OpenDash build,
/// the scooter's model and generation, MoveOS and the stock service build.
/// Nothing that identifies the rider or the vehicle (no VIN, name, phone,
/// place); the rider adds what they choose on the phone.
String reportIssueUrl({String model = '', String generation = '', String moveOs = '', String stockService = ''}) {
  final lines = [
    'OpenDash: ${BuildInfo.label}',
    if (model.isNotEmpty) 'Scooter: $model',
    if (generation.isNotEmpty) 'Generation: $generation',
    if (moveOs.isNotEmpty) 'MoveOS: $moveOs',
    if (stockService.isNotEmpty) 'Stock service: $stockService',
  ];
  return 'https://$issuesUrl/new?body=${Uri.encodeComponent('${lines.join('\n')}\n\nWhat happened:\n')}';
}

/// "Gen 1" from a recorded build's name (`gen1-moveos4-hhmis-4.6.14`), or
/// empty for a build nobody has recorded.
String generationOf(String recordedName) {
  final m = RegExp(r'^gen(\d+)-').firstMatch(recordedName);
  return m == null ? '' : 'Gen ${m[1]}';
}

/// [reportIssueUrl] for the scooter OpenDash is on now; on the mock, the
/// OpenDash build alone.
String reportIssueUrlFor(VehicleData v, StockIdentity? software) {
  if (!v.hhmisBacked) return reportIssueUrl();
  return reportIssueUrl(
    model: v.vehicleType == null ? '' : ScooterModel.nameFor(v.vehicleType) ?? 'type ${v.vehicleType}',
    generation: generationOf(software?.name ?? ''),
    moveOs: v.moveOsVersion,
    stockService: software == null ? '' : [software.version, if (software.name.isNotEmpty) '(${software.name})'].join(' '),
  );
}
