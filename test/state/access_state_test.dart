import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opendash/models/vehicle_data.dart';
import 'package:opendash/providers/mock_provider.dart';
import 'package:opendash/services/analytics_logger.dart';
import 'package:opendash/services/mock_platform_service.dart';
import 'package:opendash/services/platform_provider.dart';
import 'package:opendash/state/access_state.dart';
import 'package:opendash/state/apps_state.dart';
import 'package:opendash/state/screen_state.dart';
import 'package:opendash/state/toast_state.dart';

void main() {
  setUp(() {
    AnalyticsLogger.instance.resetForTest();
    AccessNotifier.debugAskAfterUnlock = true;
  });
  tearDown(() => AccessNotifier.debugAskAfterUnlock = false);

  /// A parked, unlocked scooter. [welcomed] is whether the once-per-install
  /// prompt has been through already (prefs do not persist in tests).
  void access(void Function(FakeAsync async, ProviderContainer c, MockPlatformService platform, AccessNotifier n) body,
      {void Function(MockPlatformService platform)? before, bool locked = false}) {
    fakeAsync((async) {
      final platform = MockPlatformService();
      before?.call(platform);
      final c = ProviderContainer(overrides: [platformServiceProvider.overrideWithValue(platform)]);
      for (final p in [sessionProvider, toastProvider, appManagerProvider, mockAppProvider, accessProvider]) {
        c.listen(p, (_, _) {});
      }
      c.read(vehicleProvider.notifier)
        ..setConnected(true)
        ..setVehicleState(VehicleState.parked)
        ..setLocked(locked);
      async.flushMicrotasks();
      body(async, c, platform, c.read(accessProvider.notifier));
      c.dispose();
    });
  }

  AccessView view(ProviderContainer c) => c.read(accessProvider);

  test('with everything allowed nothing is asked, and what waited runs at once', () {
    access((async, c, platform, n) {
      expect(view(c).request, isNull);
      expect(view(c).missing, isEmpty);
      var ran = 0;
      n.ask(title: 'Before CarPlay opens', accesses: const [Access.overlay, Access.music], required: {Access.overlay}, then: () => ran++);
      async.flushMicrotasks();
      expect(ran, 1);
      expect(view(c).request, isNull);
    });
  });

  test('after an install everything that is off is put to the rider once, and Allow switches it all on', () {
    access(before: (p) {
      p
        ..overlayAllowed = false
        ..installAllowed = false
        ..notificationAccess = false
        ..usageAccess = false
        ..defaultHome = false;
    }, (async, c, platform, n) {
      final request = view(c).request!;
      expect(request.title, 'Set up OpenDash');
      expect(request.accesses, Access.values);
      expect(view(c).missing, Access.values);
      n.allow();
      async.flushMicrotasks();
      expect(view(c).request, isNull, reason: 'all granted: nothing left to show');
      expect(view(c).missing, isEmpty);
      expect(AnalyticsLogger.instance.recent('access', 'grant'), hasLength(5));
    });
  });

  test('not while locked', () {
    access(locked: true, before: (p) => p.overlayAllowed = false, (async, c, platform, n) {
      expect(view(c).request, isNull);
    });
  });

  test('what the command service does not grant stays listed, with the way to Android\'s page', () {
    access(before: (p) {
      p
        ..overlayAllowed = false
        ..grantsRefused = true;
    }, (async, c, platform, n) {
      n.allow();
      async.flushMicrotasks();
      expect(view(c).request, isNotNull);
      expect(view(c).has(Access.overlay), isFalse, reason: 'believed only once Android reports it');
      n.openPage(Access.overlay);
      async.flushMicrotasks();
      expect(platform.overlayScreens, 1);
      expect(c.read(outsideAppProvider)?.id, 'system-access-overlay', reason: 'the island is the way back');
    });
  });

  test('a required access left off stops what waited; an optional one does not, and is not asked for again', () {
    access(before: (p) {
      p
        ..overlayAllowed = false
        ..notificationAccess = false
        ..grantsRefused = true;
    }, (async, c, platform, n) {
      n.done(); // the once-per-install prompt
      var ran = 0;
      n.ask(title: 'Before CarPlay opens', accesses: const [Access.overlay, Access.music], required: {Access.overlay}, then: () => ran++);
      async.flushMicrotasks();
      expect(view(c).request, isNotNull);
      n.done();
      expect(ran, 0);
      expect(c.read(toastProvider)!.message, contains('Show over other apps'));

      platform.overlayAllowed = true;
      n.ask(title: 'Before CarPlay opens', accesses: const [Access.overlay, Access.music], required: {Access.overlay}, then: () => ran++);
      async.flushMicrotasks();
      expect(view(c).request, isNotNull, reason: 'music is still off and has not been asked about in a flow');
      n.done();
      expect(ran, 1, reason: 'CarPlay opens without the music access');
    });
  });

  test('setting off closes the prompt and nothing that waited runs', () {
    access(before: (p) => p.overlayAllowed = false, (async, c, platform, n) {
      expect(view(c).request, isNotNull);
      c.read(vehicleProvider.notifier).setSpeed(20);
      async.elapse(const Duration(seconds: 3));
      expect(view(c).request, isNull);
    });
  });

  group('what counts as turning an access down', () {
    const carplay = [Access.install, Access.overlay, Access.music, Access.front];
    void missing(MockPlatformService p) => p
      ..installAllowed = false
      ..notificationAccess = false;

    test('switching everything off in the set-up prompt, then "Not now" before CarPlay, decides nothing', () {
      access(before: missing, (async, c, platform, n) {
        // After exactly this, CarPlay installed without a word
        // about its music access.
        n.allow(skip: {Access.install, Access.music});
        async.flushMicrotasks();
        expect(view(c).request, isNull);
        var ran = 0;
        n.ask(title: 'Before CarPlay is installed', accesses: carplay, required: {Access.install}, then: () => ran++);
        async.flushMicrotasks();
        expect(view(c).request!.startOff, isEmpty, reason: 'on by default: nothing was turned down in context');
        n.done();
        expect(ran, 0);

        // Install apps is granted through another app's prompt.
        platform.installAllowed = true;
        n.ask(title: 'Before CarPlay is installed', accesses: carplay, required: {Access.install}, then: () => ran++);
        async.flushMicrotasks();
        expect(view(c).request, isNotNull, reason: 'the music access is still to be asked about');
        expect(ran, 0);
      });
    });

    test('switched off with Continue before the app: not asked again, and shown switched off', () {
      access(before: missing, (async, c, platform, n) {
        n.done();
        var ran = 0;
        n.ask(title: 'Before CarPlay is installed', accesses: carplay, required: {Access.install}, then: () => ran++);
        async.flushMicrotasks();
        n.allow(skip: {Access.music});
        async.flushMicrotasks();
        expect(ran, 1);
        expect(platform.notificationAccess, isFalse);

        n.ask(title: 'Before CarPlay opens', accesses: const [Access.overlay, Access.music, Access.front], required: {Access.overlay}, then: () => ran++);
        async.flushMicrotasks();
        expect(ran, 2, reason: 'straight through');
        expect(view(c).request, isNull);

        platform.overlayAllowed = false;
        n.ask(title: 'Before CarPlay opens', accesses: const [Access.overlay, Access.music, Access.front], required: {Access.overlay}, then: () => ran++);
        async.flushMicrotasks();
        expect(view(c).request!.startOff, {Access.music}, reason: 'up for another reason: the earlier choice shows');
      });
    });

    test('"Not now" where the app can go ahead: it goes ahead, and is not asked again this session', () {
      access(before: (p) => p.notificationAccess = false, (async, c, platform, n) {
        n.done();
        var ran = 0;
        n.ask(title: 'Before CarPlay opens', accesses: const [Access.overlay, Access.music], required: {Access.overlay}, then: () => ran++);
        async.flushMicrotasks();
        n.done();
        expect(ran, 1);
        n.ask(title: 'Before CarPlay opens', accesses: const [Access.overlay, Access.music], required: {Access.overlay}, then: () => ran++);
        async.flushMicrotasks();
        expect(ran, 2);
        expect(view(c).request, isNull);
      });
    });

    // Seen on a scooter: "Not now" to music before Android Auto, then
    // CarPlay opened three seconds later with no prompt at all, music still
    // off.
    test('"Not now" before one app is not an answer for another', () {
      access(before: (p) => p.notificationAccess = false, (async, c, platform, n) {
        n.done();
        var auto = 0, carplay = 0;
        void askAuto(String title) => n.ask(
            title: title, scope: 'android-auto', accesses: const [Access.install, Access.overlay, Access.music], required: {Access.install}, then: () => auto++);
        void askCarplay() => n.ask(
            title: 'Before CarPlay opens', scope: 'carplay', accesses: const [Access.overlay, Access.music], required: {Access.overlay}, then: () => carplay++);

        askAuto('Before Android Auto is installed');
        async.flushMicrotasks();
        expect(view(c).request!.scope, 'android-auto');
        n.done();
        expect(auto, 1);

        askCarplay();
        async.flushMicrotasks();
        expect(view(c).request, isNotNull, reason: 'CarPlay has not been asked about its music access');
        expect(carplay, 0);
        expect(view(c).request!.title, 'Before CarPlay opens');
        n.done();
        expect(carplay, 1);

        // Each app's own "Not now" holds for that app, whichever of its
        // prompts comes next, until the next start.
        askAuto('Before Android Auto opens');
        askCarplay();
        async.flushMicrotasks();
        expect(view(c).request, isNull);
        expect((auto, carplay), (2, 2));

        // The review still lists it.
        n.review();
        async.flushMicrotasks();
        expect(view(c).request!.accesses, contains(Access.music));
        n.done();
      });
    });
  });
}
