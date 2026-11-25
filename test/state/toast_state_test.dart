import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/state/toast_state.dart';
import 'package:opendash/theme/colors.dart';

void main() {
  test('show, auto-dismiss and replace', () {
    fakeAsync((async) {
      final c = ProviderContainer();
      c.listen(toastProvider, (_, _) {});
      final t = c.read(toastProvider.notifier);
      t.show('hello');
      expect(c.read(toastProvider)!.message, 'hello');
      expect(c.read(toastProvider)!.type, ToastType.info);
      async.elapse(const Duration(milliseconds: 2900));
      expect(c.read(toastProvider), isNotNull);
      async.elapse(const Duration(milliseconds: 200));
      expect(c.read(toastProvider), isNull);

      t.show('one', type: ToastType.success);
      final first = c.read(toastProvider)!;
      async.elapse(const Duration(seconds: 2));
      t.show('two', type: ToastType.error, duration: const Duration(seconds: 1));
      final second = c.read(toastProvider)!;
      expect(second.message, 'two');
      expect(second.id, isNot(first.id));
      async.elapse(const Duration(milliseconds: 1100));
      expect(c.read(toastProvider), isNull, reason: 'old timer was cancelled, new one fired');

      t.show('three');
      t.dismiss();
      expect(c.read(toastProvider), isNull);
      c.dispose();
    });
  });

  test('every toast is logged with its type; personal text is replaced, long text cut', () {
    AnalyticsLogger.instance.resetForTest();
    final c = ProviderContainer();
    c.listen(toastProvider, (_, _) {});
    final t = c.read(toastProvider.notifier);
    t.show('Opening boot');
    t.show('Connected to HomeNet', logAs: 'Connected to <ssid>');
    t.show('x' * 200, type: ToastType.warning);
    final logged = AnalyticsLogger.instance.recent('ui', 'toast').map((e) => e['data']! as Map).toList();
    expect(logged[0], {'message': 'Opening boot', 'type': 'info'});
    expect(logged[1], {'message': 'Connected to <ssid>', 'type': 'info'});
    expect(logged[2], {'message': 'x' * ToastNotifier.logCap, 'type': 'warning'});
    expect(c.read(toastProvider)!.message, hasLength(200), reason: 'only the log line is cut');
    c.dispose();
    AnalyticsLogger.instance.resetForTest();
  });

  test('toast types carry their colours', () {
    expect(ToastType.info.color, DashColors.ash);
    expect(ToastType.success.color, DashColors.eco);
    expect(ToastType.warning.color, DashColors.warning);
    expect(ToastType.error.color, DashColors.critical);
  });

  test('mock actions raise toasts', () {
    final c = ProviderContainer();
    c.listen(toastProvider, (_, _) {});
    final v = c.read(vehicleProvider.notifier);
    v.setConnected(true);
    v.setLocked(false);
    v.setDriveMode(DriveMode.sport);
    expect(c.read(toastProvider)!.message, 'Drive mode: SPORT');
    v.toggleTrunk();
    expect(c.read(toastProvider)!.message, 'Boot opened');
    expect(c.read(toastProvider)!.type, ToastType.success);
    v.toggleHighBeam();
    expect(c.read(toastProvider)!.message, 'High beam on');
    v.setSpeed(10);
    v.activateReverse();
    expect(c.read(toastProvider)!.type, ToastType.warning);
    v.setSpeed(0);
    v.lockScooter();
    expect(c.read(toastProvider)!.message, 'Scooter locked');
    c.dispose();
  });
}
