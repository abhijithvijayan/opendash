#!/bin/bash
# Builds a release of OpenDash: a signed APK, its checksum, and the small
# file the app reads to tell whether a release is newer than what is
# installed. It does not publish anything.
#
# Usage: scripts/release.sh <version>      e.g. scripts/release.sh 0.2.0
#                                          or  scripts/release.sh 0.2.0-beta.1
#
# A -alpha.N or -beta.N suffix only labels the build; it is still published
# as a normal GitHub release (the app asks for releases/latest, which leaves
# GitHub pre-releases out), and the app decides "newer" by the build number.
#
# It refuses to build when:
#   - <version> is not the version in pubspec.yaml and lib/constants.dart;
#   - android/key.properties is missing (the build would be signed with a
#     debug key, which can never be installed over a released one);
#   - the working tree has uncommitted changes (the release would not be
#     the commit it names);
#   - RELEASE_CERT_SHA256 is set and the APK is signed by a different key.
#
# Output, in dist/:
#   opendash-<version>.apk
#   opendash-release.json   {version, build, apk, sha256, git_sha, min_build}
#
# The build number comes from the version (scripts/build-number.sh), never
# from the git history, so a restarted history cannot lower it. MIN_BUILD (default 0) says "only install over build N or later".
#
# Run by hand, or by .github/workflows/release.yml, which is the same script
# with the key supplied from the repository's secrets.
set -euo pipefail

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta)\.[0-9]+)?$ ]] || { echo "Usage: scripts/release.sh <version>   (three numbers, e.g. 0.2.0, or with -alpha.N / -beta.N, e.g. 0.2.0-beta.1)"; exit 1; }

# --crash-trial=kotlin|dart: a build that FAILS AT START, on purpose, for the
# maintainer's one trial of the "update that does not start" fallback.
# It is named so, gets the build number after the release so that the
# app offers it, and must only ever be published for that trial and deleted
# after. The GitHub workflow never passes this.
TRIAL=""
case "${2:-}" in
  "") ;;
  --crash-trial=kotlin) TRIAL=kotlin ;;
  --crash-trial=dart) TRIAL=dart ;;
  *) echo "Unknown option: $2"; exit 1 ;;
esac

cd "$(dirname "$0")/.."

if [[ -n "${OPENDASH_CRASH:-}" ]]; then
  echo "Refusing: OPENDASH_CRASH is set. A build that fails at start is only made with --crash-trial, for the one trial."
  exit 1
fi

PUBSPEC_VERSION="$(sed -n 's/^version: *\([0-9A-Za-z.-]*\).*/\1/p' pubspec.yaml | head -1)"
APP_VERSION="$(sed -n "s/^const appVersion = '\(.*\)';/\1/p" lib/constants.dart | head -1)"
if [[ "$PUBSPEC_VERSION" != "$VERSION" || "$APP_VERSION" != "$VERSION" ]]; then
  echo "Refusing: asked for $VERSION, but pubspec.yaml says $PUBSPEC_VERSION and lib/constants.dart says $APP_VERSION."
  echo "Change both, commit, and run this again."
  exit 1
fi

if [[ ! -f android/key.properties ]]; then
  echo "Refusing: android/key.properties is missing, so the build would be signed with a debug key."
  echo "Create it with storeFile, storePassword, keyAlias and keyPassword for the release keystore."
  exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "Refusing: there are uncommitted changes. A release is built from a commit."
  git status --short --untracked-files=no
  exit 1
fi

BUILD="$(scripts/build-number.sh "$VERSION" "${TRIAL:+trial}")"
GIT_SHA="$(git rev-parse --short HEAD)"
MIN_BUILD="${MIN_BUILD:-0}"
APK="opendash-$VERSION.apk"
TRIAL_ARGS=()
if [[ -n "$TRIAL" ]]; then
  APK="opendash-$VERSION-CRASH-TRIAL.apk"
  [[ "$TRIAL" == kotlin ]] && TRIAL_ARGS=(--android-project-arg opendash.crash=kotlin)
  [[ "$TRIAL" == dart ]] && TRIAL_ARGS=(--dart-define=OPENDASH_CRASH=dart)
  echo "!!! CRASH TRIAL ($TRIAL): this build fails at start, on purpose. Publish it only for the trial, and delete it after. !!!"
fi

echo "=== Building OpenDash $VERSION, build $BUILD, commit $GIT_SHA ==="
flutter build apk --release --build-number="$BUILD" --dart-define=GIT_SHA="$GIT_SHA" ${TRIAL_ARGS[@]+"${TRIAL_ARGS[@]}"}

mkdir -p dist
rm -f dist/opendash-*.apk dist/opendash-release.json
cp build/app/outputs/flutter-apk/app-release.apk "dist/$APK"

# Which key signed it. A debug-signed APK must never be released: nobody
# could install the next release over it.
APKSIGNER="$(ls "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1 || true)"
if [[ -z "$APKSIGNER" ]]; then
  echo "Refusing: apksigner was not found (set ANDROID_HOME), so the signature could not be checked."
  exit 1
fi
CERTS="$("$APKSIGNER" verify --print-certs "dist/$APK")"
# The line is "Signer #1 certificate SHA-256 digest: …" from the apksigner on
# a local SDK and "V2 Signer: certificate SHA-256 digest: …" from the
# one on GitHub's runner (where the first form matched nothing).
# One line per signing scheme, all the same certificate.
CERT="$(printf '%s\n' "$CERTS" | sed -n 's/^.*Signer.*certificate SHA-256 digest: //p' | sort -u)"
if [[ -z "$CERT" || "$(printf '%s\n' "$CERT" | wc -l)" -ne 1 ]]; then
  echo "Refusing: could not read one signing certificate from the APK. apksigner said:"
  printf '%s\n' "$CERTS" | grep -i 'certificate' || true
  rm -f "dist/$APK"
  exit 1
fi
if printf '%s\n' "$CERTS" | grep -q 'CN=Android Debug'; then
  echo "Refusing: the APK is signed with a debug key. Check android/key.properties."
  rm -f "dist/$APK"
  exit 1
fi
if [[ -n "${RELEASE_CERT_SHA256:-}" && "$CERT" != "$RELEASE_CERT_SHA256" ]]; then
  echo "Refusing: the APK is signed by $CERT,"
  echo "not by the release key on record ($RELEASE_CERT_SHA256)."
  rm -f "dist/$APK"
  exit 1
fi

SHA256="$(shasum -a 256 "dist/$APK" | cut -d' ' -f1)"
cat > dist/opendash-release.json <<JSON
{ "version": "$VERSION", "build": $BUILD, "apk": "$APK",
  "sha256": "$SHA256", "git_sha": "$GIT_SHA", "min_build": $MIN_BUILD }
JSON

echo
echo "Built:"
echo "  dist/$APK"
echo "  dist/opendash-release.json"
echo "Signed by (SHA-256 of the certificate): $CERT"
echo "APK SHA-256: $SHA256"
echo
echo "To publish, as a pre-release first (riders' dashboards only see full releases):"
echo "  gh release create v$VERSION dist/$APK dist/opendash-release.json --title \"OpenDash $VERSION\" --notes-file <notes.md> --prerelease"
