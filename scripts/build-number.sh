#!/bin/bash
# Prints the Android build number for an OpenDash version. Android and the
# app (self-update, the companion app) decide "newer" by this number, so it
# comes from the version and never from the git history, which has been
# restarted before (builds made then reached 1001 and 2001).
#
# Usage: scripts/build-number.sh <version> [release|dev|trial]
#
#   X.Y.Z            X*1000000 + Y*10000 + Z*100        0.3.0 -> 30000
#   X.Y.Z-alpha.N    that - 99 + N   (N 1..48)          0.3.0-alpha.1 -> 29902
#   X.Y.Z-beta.N     that - 50 + N   (N 1..49)          0.3.0-beta.1 -> 29951
#   dev   (deploy.sh)        + 1: a flashed build installs over the release
#                            of its version and is never offered it, but is
#                            offered the next alpha (+ 2 and up); for an
#                            alpha or beta, + 0 (Android installs an equal
#                            build), so the final release is still offered
#   trial (--crash-trial)    + 1: offered over the release it was made from
#
# Y and Z stay below 100.
set -euo pipefail

VERSION="${1:-}"
KIND="${2:-release}"
if [[ ! "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-(alpha|beta)\.([0-9]+))?$ ]]; then
  echo "Not a version: '$VERSION' (three numbers, e.g. 0.3.0, or with -alpha.N / -beta.N)" >&2
  exit 1
fi
MAJOR=$((10#${BASH_REMATCH[1]}))
MINOR=$((10#${BASH_REMATCH[2]}))
PATCH=$((10#${BASH_REMATCH[3]}))
STAGE="${BASH_REMATCH[5]}"
N="${BASH_REMATCH[6]:-0}"
N=$((10#$N))
if (( MINOR > 99 || PATCH > 99 )); then
  echo "Minor and patch must stay below 100: $VERSION" >&2
  exit 1
fi

BUILD=$((MAJOR * 1000000 + MINOR * 10000 + PATCH * 100))
case "$STAGE" in
  alpha) (( N >= 1 && N <= 48 )) || { echo "alpha.N must be 1..48: $VERSION" >&2; exit 1; }; BUILD=$((BUILD - 99 + N)) ;;
  beta) (( N >= 1 && N <= 49 )) || { echo "beta.N must be 1..49: $VERSION" >&2; exit 1; }; BUILD=$((BUILD - 50 + N)) ;;
esac
case "$KIND" in
  release) ;;
  dev) [[ -z "$STAGE" ]] && BUILD=$((BUILD + 1)) ;;
  trial) BUILD=$((BUILD + 1)) ;;
  *) echo "Unknown kind: $KIND (release, dev or trial)" >&2; exit 1 ;;
esac
echo "$BUILD"
