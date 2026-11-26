#!/bin/bash
# Install the latest OpenDash APK from a folder onto the scooter.
#
# For handing someone a prebuilt build: drop one or more opendash APKs in a
# folder (e.g. opendash-0.1.1-beta.6.apk), run this from there, and it flashes
# the newest one. Unlike deploy.sh it does NOT build — it installs an existing
# .apk file.
#
# Usage: scripts/install.sh <scooter-ip> [apk-dir] [--no-home]
#   apk-dir defaults to the current directory.
#
# Needs adb, already authorised on the scooter (README, "Installing").
# This script only installs; it does not authorise adb.
set -euo pipefail

SCOOTER_IP="${1:?Usage: install.sh <scooter-ip> [apk-dir] [--no-home]}"
APK_DIR="."
SET_HOME=1
for arg in "${@:2}"; do
  case "$arg" in
    --no-home) SET_HOME=0 ;;
    *) APK_DIR="$arg" ;;
  esac
done

DEV="$SCOOTER_IP:5555"
PKG="in.abhijithvijayan.opendash"

# --- Pick the newest APK in APK_DIR ----------------------------------------
# Rank by the version in the filename (MAJOR.MINOR.PATCH[-beta.N]): a release
# outranks any beta of the same version, and beta.6 beats beta.5. If no file
# carries a version, fall back to the most recently modified .apk.
pick_latest() {
  local best="" best_key=-1 found_versioned=0 f base ver maj min pat rest beta key
  for f in "$APK_DIR"/*.apk; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    ver="$(printf '%s' "$base" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?' | head -1 || true)"
    [[ -n "$ver" ]] || continue
    found_versioned=1
    maj="${ver%%.*}"; rest="${ver#*.}"
    min="${rest%%.*}"; rest="${rest#*.}"
    pat="${rest%%-*}"
    if [[ "$ver" == *-beta.* ]]; then beta="${ver##*-beta.}"; else beta=999; fi
    key=$(( 10#$maj * 1000000000 + 10#$min * 1000000 + 10#$pat * 1000 + 10#$beta ))
    if (( key > best_key )); then best_key=$key; best="$f"; fi
  done
  if (( found_versioned == 0 )); then
    # No version in any filename: newest by modification time.
    best="$(ls -t "$APK_DIR"/*.apk 2>/dev/null | head -1 || true)"
  fi
  printf '%s' "$best"
}

APK="$(pick_latest)"
if [[ -z "$APK" ]]; then
  echo "No .apk found in '$APK_DIR'." >&2
  exit 1
fi
echo "=== Installing: $(basename "$APK") ==="

echo "=== Connecting ADB ==="
adb connect "$DEV" || true
# Wait briefly for an *authorised* device. If adb isn't authorised yet, say so
# and point at the key-injection step rather than hanging on wait-for-device.
state=""
for _ in 1 2 3 4 5 6; do
  state="$(adb -s "$DEV" get-state 2>/dev/null || true)"
  [[ "$state" == "device" ]] && break
  sleep 1
done
if [[ "$state" != "device" ]]; then
  echo
  echo "adb is not ready on $DEV (state: ${state:-unreachable})."
  echo "Authorise adb on the scooter first (README, \"Installing\"), then re-run:"
  echo "  bash install.sh $SCOOTER_IP"
  exit 1
fi

# The scooter's own density: OpenDash scales to the display at any density,
# and forcing 160 shrank every other app and Android's own screens.
echo "=== Using the scooter's display density ==="
adb -s "$DEV" shell wm density reset || true

echo "=== Disabling screensaver ==="
adb -s "$DEV" shell settings put secure screensaver_enabled 0 || true

echo "=== Installing APK ==="
# Stop the running app first: installing over a live instance can leave it on a
# blank white screen from a stale render cache. A clean stop + cold start avoids it.
adb -s "$DEV" shell am force-stop "$PKG" || true
adb -s "$DEV" install -r -g "$APK"

if [[ "$SET_HOME" == 1 ]]; then
  echo "=== Setting OpenDash as the HOME launcher ==="
  adb -s "$DEV" shell cmd package set-home-activity "$PKG/.MainActivity" || \
    echo "set-home-activity refused; pick OpenDash from the launcher chooser instead"
fi

echo "=== Launching (cold start) ==="
adb -s "$DEV" shell am start -n "$PKG/.MainActivity" || true

echo "=== Done ==="
echo "Revert HOME: adb -s $DEV shell cmd package set-home-activity com.olaelectric.hmiclient/.MainActivity"
