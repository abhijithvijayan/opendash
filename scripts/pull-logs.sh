#!/bin/bash
# pull-logs.sh — Pull OpenDash's analytics logs off the scooter.
#
# Grabs the whole `analytics/` folder: the current log (opendash.jsonl), its
# rotated generations (opendash.1.jsonl …), the whole-bus changed-frames log
# (bus-*.jsonl) and its event bursts (burst-*.jsonl), and any raw CAN
# recordings (raw-*.jsonl). It is read-only — nothing is installed, changed
# or deleted on the scooter.
#
# Usage:
#   scripts/pull-logs.sh <scooter-ip> [dest-dir]
#
#   dest-dir defaults to logs/logs-<timestamp>/ (logs/ is gitignored), so a
#   repeat pull never overwrites an earlier one.
#
# How it pulls:
#   1. adb over TCP 5555 if the key is injected (fast, whole-folder pull).
#   2. Otherwise the diagnostics gRPC port (50005), one base64 read per file —
#      no adb key needed. Every reboot wipes the adb key and the scooter
#      reboots itself once a night, so after a reboot this is the only way in
#      without authorising adb again.
#
# Requires: adb and/or grpcurl + jq (base64 is in coreutils). The gRPC path
# needs proto/wifican.proto. Runs on macOS and Linux as-is; on Windows run it
# from Git Bash or WSL (it is a bash script, not cmd/PowerShell), and keep the
# repo's LF line endings (see .gitattributes).
set -euo pipefail

SCOOTER_IP="${1:?Usage: pull-logs.sh <scooter-ip> [dest-dir]}"
DEV="$SCOOTER_IP:5555"
GRPC="$SCOOTER_IP:50005"
PKG="in.abhijithvijayan.opendash"
R="/storage/emulated/0/Android/data/$PKG/files/analytics"
PROTO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Resolved against the directory you run the script from (not the repo root),
# so `pull-logs.sh <ip> .` lands the logs in your current folder. The proto
# for the gRPC fallback is found by its absolute path, so we never need to cd.
DEST="${2:-logs/logs-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$DEST"

grpc_out() {
  grpcurl -plaintext -max-msg-sz 67108864 -max-time 180 \
    -import-path "$PROTO_DIR/proto" -proto wifican.proto \
    -d "{\"cmd_msg\": \"$1\"}" \
    "$GRPC" wifican.WifiCanRpc/ExecuteADBCommand 2>/dev/null \
    | jq -r '.statusMsg // empty'
}

pull_via_adb() {
  command -v adb >/dev/null 2>&1 || return 1
  echo "=== Trying adb at $DEV ==="
  adb connect "$DEV" >/dev/null 2>&1 || true
  # A stale local server can show the device as offline; a plain shell probe
  # is the honest test of whether we can actually read from it.
  if ! adb -s "$DEV" shell true >/dev/null 2>&1; then
    echo "adb not connected (key not injected, or :5555 not up)."
    return 1
  fi
  echo "Listing:"
  adb -s "$DEV" shell ls -la "$R/" || true
  echo "Pulling $R/ -> $DEST/"
  # `pull <dir>/` copies the folder's contents into DEST.
  adb -s "$DEV" pull "$R/" "$DEST/"
}

pull_via_grpc() {
  command -v grpcurl >/dev/null 2>&1 || { echo "grpcurl not found; cannot use the gRPC fallback." >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "jq not found; cannot use the gRPC fallback." >&2; return 1; }
  echo "=== Falling back to gRPC at $GRPC ==="
  # ExecuteADBCommand splits its argument on spaces and runs it directly: no
  # pipes, no sh -c, one command per call. `ls -1` gives one name per line;
  # jq -r turns the escaped newlines back into real ones.
  local files
  files="$(grpc_out "ls -1 $R/")"
  if [[ -z "$files" ]]; then
    echo "No files listed at $R/ (wrong IP, app never launched, or no logs yet)." >&2
    return 1
  fi
  local f n=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    echo "  $f"
    # base64 -w0 keeps each file on one line; decode it back on the host.
    grpc_out "base64 -w0 $R/$f" | base64 -d > "$DEST/$f"
    n=$((n + 1))
  done <<< "$files"
  echo "Pulled $n file(s)."
}

echo "Destination: $DEST"
if pull_via_adb; then
  :
elif pull_via_grpc; then
  :
else
  echo "" >&2
  echo "Could not pull via adb or gRPC." >&2
  echo "  - For adb: authorise adb on the scooter first, again after any reboot (README, \"Installing\")." >&2
  echo "  - For gRPC: install grpcurl and jq, and check the scooter IP." >&2
  exit 1
fi

echo ""
echo "=== Done ==="
echo "Files in $DEST:"
ls -la "$DEST"
echo ""
echo "Quick look:  jq -r '.cat + \".\" + .evt' \"$DEST\"/opendash.jsonl | sort | uniq -c | sort -rn"
