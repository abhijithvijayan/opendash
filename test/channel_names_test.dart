import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/providers/vehicle_provider.dart';

/// The Flutter side and the Android side find each other by channel name,
/// and a name that differs on one side fails only on the scooter, silently.
/// The names carry the app's own id (they once used a shorter one that nobody owns).
void main() {
  const appId = 'in.abhijithvijayan.opendash';

  Set<String> namesUnder(String dir, String extension) {
    final found = <String>{};
    for (final file in Directory(dir).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith(extension)) continue;
      for (final m in RegExp('["\']($appId\\.[a-z]+(?:/[a-z]+)?)["\']').allMatches(file.readAsStringSync())) {
        found.add(m.group(1)!);
      }
    }
    return found;
  }

  test('every channel has the same name in Dart and in Kotlin, under the app id', () {
    final dart = namesUnder('lib', '.dart');
    final kotlin = namesUnder('android/app/src/main/kotlin', '.kt');
    expect(dart, isNotEmpty);
    expect(dart, kotlin);
    expect(dart, {
      '$appId.platform',
      '$appId.vehicle/events',
      '$appId.media/events',
      '$appId.media/commands',
      '$appId.bt/events',
      '$appId.bt/commands',
      '$appId.island',
    });
  });

  test('vehicle commands go over the generated link, and it is the one the definition gives', () {
    final provider = File('lib/providers/vehicle_provider.dart').readAsStringSync();
    final used = {
      for (final m in RegExp(r"(?:_invoke|_send|_cmd|_rawInvoke)\(\s*'([a-zA-Z]+)'").allMatches(provider)) m.group(1)!,
    }..remove('callAction');
    expect(used, isNotEmpty);
    expect(used.difference(AidlVehicleNotifier.linkMethods), isEmpty);
    final carried = provider.substring(provider.indexOf('static Future<Object?> _channelInvoke'), provider.indexOf('static const linkMethods'));
    for (final method in AidlVehicleNotifier.linkMethods) {
      expect(carried, contains("'$method' => _link."), reason: method);
    }

    final definition = File('pigeons/vehicle_link.dart').readAsStringSync();
    final defined = {
      for (final m in RegExp(r'^  bool (\w+)\(', multiLine: true).allMatches(definition)) m.group(1)!,
    };
    expect(defined, hasLength(AidlVehicleNotifier.linkMethods.length));
    final dart = File('lib/providers/vehicle_link.g.dart').readAsStringSync();
    final kotlin = File('android/app/src/main/kotlin/in/abhijithvijayan/opendash/VehicleLink.g.kt').readAsStringSync();
    for (final name in defined) {
      expect(dart, contains('Future<bool> $name('), reason: 'Dart $name');
      expect(kotlin, contains('fun $name('), reason: 'Kotlin $name');
    }
  });
}
