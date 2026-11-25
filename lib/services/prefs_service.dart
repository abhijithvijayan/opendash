import 'package:shared_preferences/shared_preferences.dart';

/// Every persisted key in one place.
abstract final class PrefsKeys {
  static const volume = 'volume';
  static const projectionMusicAsked = 'projectionMusicAsked';

  /// The access prompt was shown once after this install; and, per access,
  /// `accessDeclined.<name>`: an optional one the rider left off.
  static const accessWelcomed = 'accessWelcomed';
  static const accessDeclined = 'accessDeclined';
  static const brightness = 'brightness';

  /// Auto brightness: the rider's usual level by day and by night.
  static const autoBrightnessDay = 'autoBrightnessDay';
  static const autoBrightnessNight = 'autoBrightnessNight';
  static const theme = 'theme';
  static const customAccent = 'customAccent';
  static const use24h = 'use24h';
  static const useMiles = 'useMiles';
  static const useFahrenheit = 'useFahrenheit';
  static const lockDate = 'lockDate';
  static const autoDark = 'autoDark';
  static const sound = 'sound';
  static const chargeHistory = 'chargeHistory';
  static const rideSegments = 'rideSegments';
  static const chargeLimit = 'chargeLimit';
  static const riding = 'riding';

  /// Set only by the rider's own side-stand bypass (passcode and warning).
  /// A stored "sensor off" without it is not honoured.
  static const standBypassConfirmed = 'standBypassConfirmed';
  static const analyticsEnabled = 'analyticsEnabled';
  static const rideSeq = 'rideSeq';

  /// `<local date>|<Wh>`: pack energy drawn so far today.
  static const energyUsedToday = 'energyUsedToday';

  /// Unhandled errors since the last stable boot; see crash_recovery.dart.
  static const crashCount = 'crashCount';

  /// OpenDash updating itself (`lib/state/ota_state.dart`). `updateAuto`:
  /// check by itself (default) or only when asked. `updateEtag` /
  /// `updateCheckedAt`: the last answered check. `updateFound`: the newer
  /// release it found, kept so a "not modified" answer still has it.
  /// `updateSeen` / `updateSkipped`: the build numbers the rider has seen on
  /// the screen, or skipped.
  static const updateAuto = 'updateAuto';
  static const updateEtag = 'updateEtag';
  static const updateCheckedAt = 'updateCheckedAt';
  static const updateFound = 'updateFound';
  static const updateSeen = 'updateSeen';
  static const updateSkipped = 'updateSkipped';

  /// The build sent from the companion phone app that has been toasted, so a
  /// restart doesn't toast it again.
  static const updateIncomingToasted = 'updateIncomingToasted';

  /// Wall-clock ms-since-epoch when the passcode lockout ends. Restored
  /// across Doze/LMK restarts so the countdown survives a sleep cycle.
  static const passcodeLockoutEnd = 'passcodeLockoutEnd';

  /// The last wall-clock reading `TrustedClock` believed, ms since epoch.
  static const clockLastGood = 'clockLastGood';

  /// `AmbientHealth`: milliseconds the ambient value has spent at each level.
  static const ambientHealth = 'ambientHealth';

  /// Times Apps was opened by the swipe up from the dashboard's bottom edge.
  static const appsSwipeUsed = 'appsSwipeUsed';
  static String ridingFeature(String name) => 'riding_$name';

  /// The last `featureAvailable` map the vehicle reported, as JSON.
  static const featureAvailable = 'featureAvailable';

  /// The rider's custom ride mode settled config (MoveOS 5), as JSON, so
  /// the mode shows from boot before HHMIS re-sends it.
  static const customRide = 'customRide';

  /// The rider paused the smart headlight from the beam button and it has
  /// not resumed yet (the vehicle was told "off"; the setting stays on).
  static const smartHeadlightPaused = 'smartHeadlightPaused';

  /// The vehicle's stored "smart headlight off" was written by a pause of
  /// ours and has not yet been seen replaced by "on".
  static const smartHeadlightOffIsOurs = 'smartHeadlightOffIsOurs';

  /// "Phone calls on the dashboard": 1 on, 0 off, absent until the rider
  /// or the vehicle profile has said. And whether the consent was given.
  static const phoneCalls = 'phoneCalls';

  /// Scooter firmware control (`lib/state/firmware_state.dart`). `fwMode`:
  /// `off` / `ask`. `fwStockAutoDownloadFirst`: the stock auto-download
  /// value first seen, never overwritten; the undo puts it back.
  /// `fwRestored`: the rider restored stock update settings, so OpenDash
  /// neither switches auto-download off nor watches the update callbacks.
  /// `fwBlockLast` / `fwBlockRemovedUnseen`: left by the firmware-block
  /// reading OTA Shield replaced; cleared at start.
  /// `fwVersions`: the firmware versions seen at the last start.
  static const fwMode = 'fwMode';
  static const fwStockAutoDownloadFirst = 'fwStockAutoDownloadFirst';
  static const fwRestored = 'fwRestored';
  static const fwBlockLast = 'fwBlockLast';
  static const fwBlockRemovedUnseen = 'fwBlockRemovedUnseen';
  static const fwLastNotice = 'fwLastNotice';
  static const fwNoticeSeen = 'fwNoticeSeen';
  static const fwVersions = 'fwVersions';
  static const fwVersionsSeen = 'fwVersionsSeen';
  static const fwChange = 'fwChange';
  static const scooterPeaks = 'scooterPeaks';
  static const uncheckedAllowed = 'uncheckedAllowed';
  static const phoneCallsConsent = 'phoneCallsConsent';

  /// The anonymous weekly usage ping (`lib/state/usage_ping.dart`):
  /// `usagePing` on until turned off, `usagePingWeek` the ISO week last
  /// counted, `usagePingCounted` this install has been counted once.
  static const usagePing = 'usagePing';
  static const usagePingWeek = 'usagePingWeek';
  static const usagePingCounted = 'usagePingCounted';

  /// Auto theme's last decision and when, `light|<ms>` or `dark|<ms>`: it switches the theme
  /// only when that decision changes, so a theme the rider picks holds
  /// until the next sunrise or sunset, across a restart too.
  static const autoThemeDecision = 'autoThemeDecision';

  /// The rider's dark theme, by name, for auto theme to go back to at night
  /// after a restart spent on Light.
  static const themeLastDark = 'themeLastDark';

  /// Settings → Developer → "Bus log": on until it is turned off.
  static const busLog = 'busLog';
}

/// Thin static wrapper so notifiers can read settings synchronously in
/// `build()`. Before [init] (and in tests) every read returns its fallback
/// and writes are dropped, which keeps the Phase 1 defaults intact.
class PrefsService {
  static SharedPreferences? _prefs;

  static bool get ready => _prefs != null;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static void resetForTest() => _prefs = null;

  static bool getBool(String key, bool fallback) => _prefs?.getBool(key) ?? fallback;
  static int getInt(String key, int fallback) => _prefs?.getInt(key) ?? fallback;
  static double getDouble(String key, double fallback) => _prefs?.getDouble(key) ?? fallback;
  static String getString(String key, String fallback) => _prefs?.getString(key) ?? fallback;

  static Future<void> setBool(String key, bool v) async => _prefs?.setBool(key, v);
  static Future<void> setInt(String key, int v) async => _prefs?.setInt(key, v);
  static Future<void> setDouble(String key, double v) async => _prefs?.setDouble(key, v);
  static Future<void> setString(String key, String v) async => _prefs?.setString(key, v);
  static Future<void> remove(String key) async => _prefs?.remove(key);
}
