import 'package:pigeon/pigeon.dart';

// The command side of the vehicle channel, as one definition both sides
// are generated from:
//
//   dart run pigeon --input pigeons/vehicle_link.dart
//
// Every method answers true when the call reached the stock service and
// false when it did not go (service not bound, the scooter's software has
// no such command, the command is one OpenDash never sends). When the
// service was reached and threw, the Kotlin side raises `hhmis_error`.
@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/providers/vehicle_link.g.dart',
  kotlinOut: 'android/app/src/main/kotlin/in/abhijithvijayan/opendash/VehicleLink.g.kt',
  kotlinOptions: KotlinOptions(package: '`in`.abhijithvijayan.opendash', errorClassName: 'VehicleLinkError'),
  dartPackageName: 'opendash',
))
@HostApi()
abstract class VehicleLinkApi {
  /// A stock command by its stock name, with no value.
  bool sendVoid(String cmd);
  bool sendBool(String cmd, bool value);
  bool sendInt(String cmd, int value);
  bool sendString(String cmd, String value);

  /// The rider's "Check now": the only way the update check is sent.
  bool checkFirmwareUpdate();

  /// Puts OpenDash's update callbacks in the service's one slot, to watch.
  // The calls below wait for the stock service's reply, so Kotlin runs
  // them on a worker thread: the main thread also builds frames.
  @asyncCallback
  bool subscribeFirmware();
  @asyncCallback
  bool setBrightness(int value, bool persist);
  @asyncCallback
  bool setVolume(int level);
  @asyncCallback
  bool setMotorVolume(int level);
  @asyncCallback
  bool setChimeVolume(int level);

  /// Waits for the profile service's check and the scooter's answer.
  @asyncCallback
  bool verifyPasscode(String code, bool verifyOnly);
  bool mediaKey(String key);
  bool btSnapshot(String trigger);
  @asyncCallback
  bool reattachCallback();
}
