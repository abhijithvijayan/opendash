import 'dart:convert';
import 'dart:io';

import 'package:opendash/models/scooter_model.dart';

/// A recorded stock build (`contracts/*.json`) as Kotlin reports it in
/// `_contract`: [name] is the fixture's `gen<G>-moveos<M>-<version>` name, as
/// `gen1-moveos4-4.6.14` (the 4.6.14 service), `gen1-moveos5-5.0.2` (5.0.2) or
/// `gen3-moveos5-7.1.30` (7.1.30).
Map<String, Object?> stockContract(String name, {String source = StockIdentity.sourceRead, String? version}) {
  final fixture = Directory('contracts')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .map((f) => jsonDecode(f.readAsStringSync()) as Map<String, Object?>)
      .firstWhere((f) => f['name'] == name);
  return {
    'version': version ?? fixture['version'],
    'source': source,
    'name': name,
    'checked': fixture['checked'] == true && (version == null || version == fixture['version']),
    'digest': 'digest-of-$name',
    'commands': fixture['commands'],
    'states': fixture['states'],
  };
}

/// The scooter OpenDash has been ridden on.
StockIdentity stockIdentity([String name = 'gen1-moveos4-4.6.14']) => StockIdentity.fromEvent(stockContract(name));
