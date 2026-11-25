#!/bin/bash
# Deploy OpenDash to the scooter and make it the HOME launcher.
#
# Usage: scripts/deploy.sh <scooter-ip> [--no-home]
#
# Requires flutter and adb, with adb already authorised on the scooter
# (README, "Installing").
set -euo pipefail

SCOOTER_IP="${1:?Usage: deploy.sh <scooter-ip> [--no-home]}"
SET_HOME=1
[[ "${2:-}" == "--no-home" ]] && SET_HOME=0
DEV="$SCOOTER_IP:5555"
APK="build/app/outputs/flutter-apk/app-release.apk"

cd "$(dirname "$0")/.."

echo "=== Building release APK ==="
# The SHA lands in every log's app.start event, so a pulled log names its build.
GIT_SHA="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- lib android || echo -dirty)"
# The build number comes from pubspec.yaml's version (scripts/build-number.sh):
# a flashed build is above the release of its version, so it installs over
# it (Android refuses a lower one over a higher one) and is not offered it.
VERSION="$(sed -n 's/^version: *\([0-9A-Za-z.-]*\).*/\1/p' pubspec.yaml | head -1)"
BUILD="$(scripts/build-number.sh "$VERSION" dev)"
flutter build apk --release --build-number="$BUILD" --dart-define=GIT_SHA="$GIT_SHA"

echo "=== Connecting ADB ==="
adb connect "$DEV"
adb -s "$DEV" wait-for-device

echo "=== Setting display density ==="
adb -s "$DEV" shell wm density 160

echo "=== Disabling screensaver ==="
adb -s "$DEV" shell settings put secure screensaver_enabled 0

echo "=== Installing APK ==="
# Stop the running app first: installing over a live instance can leave it on
# a blank white screen from a stale render cache. A clean stop + cold start
# avoids it.
adb -s "$DEV" shell am force-stop in.abhijithvijayan.opendash || true
adb -s "$DEV" install -r -g "$APK"

if [[ "$SET_HOME" == 1 ]]; then
  echo "=== Setting OpenDash as the HOME launcher ==="
  adb -s "$DEV" shell cmd package set-home-activity in.abhijithvijayan.opendash/.MainActivity || \
    echo "set-home-activity refused; pick OpenDash from the launcher chooser instead"
fi

echo "=== Launching (cold start) ==="
adb -s "$DEV" shell am start -n in.abhijithvijayan.opendash/.MainActivity

echo "=== Done ==="
echo "Logs:   adb -s $DEV logcat -s HhmisService HhmisCallback flutter"
echo "Revert: adb -s $DEV shell cmd package set-home-activity com.olaelectric.hmiclient/.MainActivity"
