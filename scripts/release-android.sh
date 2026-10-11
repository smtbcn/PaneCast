#!/bin/bash
# PaneCast Android TV receiver release build: signed APK (GitHub) and AAB (Google Play).
#
# Usage:  ./scripts/release-android.sh
#
# Signing comes from receiver/keystore.properties (gitignored: storeFile, storePassword,
# keyAlias, keyPassword) or the environment (PANECAST_KEYSTORE, PANECAST_KEYSTORE_PASSWORD,
# PANECAST_KEY_ALIAS, PANECAST_KEY_PASSWORD). Without them gradle would produce an UNSIGNED
# release, so this script refuses to run. See docs/RELEASING.md for the one-time setup.
#
# Output: dist/PaneCast-Receiver-<version>.apk   (attach to the GitHub release)
#         artifacts/play/PaneCast-Receiver-<version>.aab   (upload to Google Play, not GitHub)
# Optional: GRADLE_USER_HOME (gradle cache), ANDROID_HOME (SDK; else receiver/local.properties).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RECEIVER="$ROOT/receiver"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
DIST="$ROOT/dist"
PLAY="$ROOT/artifacts/play"
APK_OUT="$DIST/PaneCast-Receiver-$VERSION.apk"
AAB_OUT="$PLAY/PaneCast-Receiver-$VERSION.aab"

if [[ ! -f "$RECEIVER/keystore.properties" && -z "${PANECAST_KEYSTORE:-}" ]]; then
  echo "No release signing configuration (receiver/keystore.properties or PANECAST_KEYSTORE*)." >&2
  echo "Create an upload keystore first: docs/RELEASING.md" >&2
  exit 1
fi

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$SDK" && -f "$RECEIVER/local.properties" ]]; then
  SDK="$(sed -n 's/^sdk\.dir=//p' "$RECEIVER/local.properties" | head -1)"
fi
[[ -d "$SDK/build-tools" ]] || { echo "Android SDK not found (set ANDROID_HOME or receiver/local.properties)" >&2; exit 1; }
BT="$(ls -1 "$SDK/build-tools" | sort -V | tail -1)"
APKSIGNER="$SDK/build-tools/$BT/apksigner"
[[ -x "$APKSIGNER" ]] || { echo "apksigner not found in $SDK/build-tools/$BT" >&2; exit 1; }

echo "# gradle assembleRelease bundleRelease (version $VERSION)"
(cd "$RECEIVER" && gradle assembleRelease bundleRelease)

APK_SRC="$RECEIVER/app/build/outputs/apk/release/app-release.apk"
AAB_SRC="$RECEIVER/app/build/outputs/bundle/release/app-release.aab"
[[ -f "$APK_SRC" ]] || { echo "signed APK missing ($APK_SRC): the release build was not signed" >&2; exit 1; }
[[ -f "$AAB_SRC" ]] || { echo "AAB missing: $AAB_SRC" >&2; exit 1; }

echo "# apksigner verify (build-tools $BT)"
# Print only the verdict and the certificate fingerprint: the DN lines name the key owner.
"$APKSIGNER" verify --verbose --print-certs "$APK_SRC" | grep -E "^Verifies|v[0-9] scheme|SHA-256 digest"
if "$APKSIGNER" verify --print-certs "$APK_SRC" | grep -qi "Android Debug"; then
  echo "APK is signed with the debug key; refusing." >&2
  exit 1
fi

mkdir -p "$DIST" "$PLAY"
cp "$APK_SRC" "$APK_OUT"
cp "$AAB_SRC" "$AAB_OUT"

echo
echo "# result"
ls -l "$APK_OUT" "$AAB_OUT" | awk '{print $5, $9}' | sed "s#$ROOT/##"
