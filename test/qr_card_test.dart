import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/constants.dart';
import 'package:opendash/models/scooter_model.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/services/build_info.dart';
import 'package:opendash/state/qr_card.dart';
import 'package:opendash/widgets/overlays/qr_card_dialog.dart';

void main() {
  tearDown(() => BuildInfo.number = null);

  test('a new issue carries the OpenDash build, scooter model, generation, MoveOS and stock service', () {
    BuildInfo.number = 1234;
    final url = Uri.parse(reportIssueUrl(model: 'S1 Pro', generation: 'Gen 1', moveOs: '4.6.14', stockService: '4.6.14 (gen1-moveos4-hhmis-4.6.14)'));
    expect(url.scheme, 'https');
    expect('${url.host}${url.path}', '$issuesUrl/new');
    expect(url.queryParameters.keys, ['body']);
    expect(url.queryParameters['body'], 'OpenDash: $appVersion · build 1234\n'
        'Scooter: S1 Pro\nGeneration: Gen 1\nMoveOS: 4.6.14\nStock service: 4.6.14 (gen1-moveos4-hhmis-4.6.14)\n\nWhat happened:\n');
  });

  test('what is not known is left out, and the mock fills in the OpenDash build alone', () {
    final body = Uri.parse(reportIssueUrl()).queryParameters['body']!;
    expect(body, isNot(contains('Scooter:')));
    expect(body, isNot(contains('MoveOS:')));
    expect(Uri.parse(reportIssueUrlFor(const VehicleData(), null)).queryParameters['body'], body);
  });

  test('on the scooter the model, generation, MoveOS and stock build are read from it', () {
    const v = VehicleData(hhmisBacked: true, vehicleType: 3, moveOsVersion: '4.6.14');
    const software = StockIdentity(version: '4.6.14', source: StockIdentity.sourceRead, name: 'gen1-moveos4-hhmis-4.6.14');
    final body = Uri.parse(reportIssueUrlFor(v, software)).queryParameters['body']!;
    expect(body, contains('Scooter: S1 Pro\nGeneration: Gen 1\nMoveOS: 4.6.14\nStock service: 4.6.14 (gen1-moveos4-hhmis-4.6.14)'));
    final unknown = Uri.parse(reportIssueUrlFor(const VehicleData(hhmisBacked: true, vehicleType: 9), null)).queryParameters['body']!;
    expect(unknown, contains('Scooter: type 9'), reason: 'never a guessed name');
    expect(unknown, isNot(contains('Generation:')));
  });

  test('the generation comes from a recorded build name only', () {
    expect(generationOf('gen3-moveos5-hhmis-7.1.30'), 'Gen 3');
    expect(generationOf(''), '');
    expect(generationOf('something-else'), '');
  });

  test('the painter encodes that address as a scannable code', () {
    final painter = QrPainter(reportIssueUrl());
    expect(painter.data, reportIssueUrl());
    expect(painter.modules, greaterThanOrEqualTo(21));
    expect(painter.modules, lessThanOrEqualTo(61), reason: 'small enough to read off a 1280 px screen');
    // The three finder patterns sit in the corners.
    for (final (r, c) in [(0, 0), (0, painter.modules - 1), (painter.modules - 1, 0)]) {
      expect(painter.isDark(r, c), isTrue);
    }
  });

  test('the companion app card points at its latest release', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(qrCardProvider.notifier).companionApp(from: 'test');
    final card = c.read(qrCardProvider)!;
    expect(card.id, 'companion');
    expect(card.url, 'https://github.com/abhijithvijayan/opendash-companion/releases/latest');
    expect(card.shown, 'github.com/abhijithvijayan/opendash-companion');
  });
}
