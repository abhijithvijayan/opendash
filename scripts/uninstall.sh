#!/bin/bash
# Uninstall OpenDash from the scooter and hand HOME back to the stock dashboard.
#
# Usage: scripts/uninstall.sh <scooter-ip> [--keep-home]
#
# Needs adb, already authorised on the scooter (README, "Installing").
#
# If you blocked firmware updates with a separate script, set
# FIRMWARE_UPDATES to its path and the block is taken off first, so that
# updates behave as stock had them once OpenDash is gone.
set -euo pipefail

SCOOTER_IP="${1:?Usage: uninstall.sh <scooter-ip> [--keep-home]}"
RESTORE_HOME=1
for arg in "${@:2}"; do
  case "$arg" in
    --keep-home) RESTORE_HOME=0 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done
DEV="$SCOOTER_IP:5555"
PKG="in.abhijithvijayan.opendash"
STOCK_HOME="com.olaelectric.hmiclient/.MainActivity"
FIRMWARE_UPDATES="${FIRMWARE_UPDATES:-}"

echo "=== Connecting ADB ==="
adb connect "$DEV"
adb -s "$DEV" wait-for-device

if ! adb -s "$DEV" shell pm list packages | grep -q "^package:$PKG$"; then
  echo "OpenDash is not installed on $SCOOTER_IP; nothing to do."
  exit 0
fi

if [[ "$RESTORE_HOME" == 1 ]]; then
  echo "=== Restoring stock dashboard as HOME ==="
  adb -s "$DEV" shell cmd package set-home-activity "$STOCK_HOME" || \
    echo "set-home-activity refused; pick the stock dashboard from the launcher chooser instead"
  # OpenDash's boot-time force-stop may have killed stock. Start it now so the
  # rider sees the dashboard at once, not a 5 s blank screen while Android
  # cold-starts it after the uninstall.
  echo "=== Pre-warming stock dashboard ==="
  adb -s "$DEV" shell am start -n "$STOCK_HOME" || \
    echo "am start refused; stock will cold-boot after uninstall completes"
  sleep 2
fi

if [[ -n "$FIRMWARE_UPDATES" ]]; then
  echo "=== Taking the firmware block off ==="
  if ! bash "$FIRMWARE_UPDATES" allow "$SCOOTER_IP"; then
    echo "The firmware block could not be checked or removed, so OpenDash was not uninstalled."
    echo "Unset FIRMWARE_UPDATES to uninstall anyway."
    exit 1
  fi
fi

echo "=== Uninstalling APK ==="
adb -s "$DEV" uninstall "$PKG"

echo "=== Resetting display density ==="
# The install set it to 160 for OpenDash; the stock dashboard is drawn for
# the head unit's own density.
adb -s "$DEV" shell wm density reset || echo "wm density reset refused; the stock dashboard stays at density 160"

echo "=== Done ==="
echo "OpenDash switched off the stock dashboard's update auto-download. Turn it on again in the"
echo "stock dashboard (Settings > Software update > auto-download) if you want it; OpenDash's"
echo "\"Restore stock update settings\" does the same before an uninstall."
if [[ -z "$FIRMWARE_UPDATES" ]]; then
  echo "If you blocked firmware updates with a separate script, remove that block too."
fi
