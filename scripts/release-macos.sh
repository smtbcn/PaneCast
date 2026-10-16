#!/bin/bash
# PaneCast macOS release build: universal (arm64 + x86_64), Developer ID signed,
# hardened runtime, notarized, stapled; writes a .dmg and a .zip into dist/.
#
# Usage:  ./scripts/release-macos.sh [--unsigned]
#
# Configuration comes from scripts/signing.local.sh (gitignored, see
# signing.local.sh.example) or the environment:
#   RELEASE_IDENTITY  Developer ID Application identity (name or SHA-1 hash). Never printed.
#   NOTARY_PROFILE    keychain profile created with `xcrun notarytool store-credentials`.
# Without NOTARY_PROFILE the output is signed but NOT notarized (loud warning; Gatekeeper
# will warn users). --unsigned builds ad-hoc signed artifacts for CI/testing only.
#
# Output: dist/PaneCast-<version>-macOS.dmg, dist/PaneCast-<version>-macOS.zip
set -euo pipefail

UNSIGNED=0
for arg in "$@"; do
  case "$arg" in
    --unsigned) UNSIGNED=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 64 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
DIST="$ROOT/dist"
WORK="$ROOT/artifacts/release-macos"
APP="$WORK/PaneCast.app"
DMG="$DIST/PaneCast-$VERSION-macOS.dmg"
ZIP="$DIST/PaneCast-$VERSION-macOS.zip"

if [[ -f "$ROOT/scripts/signing.local.sh" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/signing.local.sh"
fi
RELEASE_IDENTITY="${RELEASE_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# Presence check only: the identity string carries a personal name and is never printed.
DEVID_COUNT="$(security find-identity -v -p codesigning | grep -c "Developer ID Application" || true)"
echo "# Developer ID Application identities in keychain: $DEVID_COUNT"

if [[ "$UNSIGNED" == 1 ]]; then
  SIGN_ID="-"
  NOTARIZE=0
  echo "WARNING: --unsigned: ad-hoc signature, no notarization. Not for end users." >&2
else
  if [[ -z "$RELEASE_IDENTITY" ]]; then
    echo "RELEASE_IDENTITY is not set (scripts/signing.local.sh or environment)." >&2
    echo "Set it to your Developer ID Application identity, or pass --unsigned for a test build." >&2
    exit 1
  fi
  SIGN_ID="$RELEASE_IDENTITY"
  NOTARIZE=1
  if [[ -z "$NOTARY_PROFILE" ]]; then
    NOTARIZE=0
    echo "################################################################" >&2
    echo "# WARNING: NOTARY_PROFILE is not set. Output will be SIGNED BUT   #" >&2
    echo "# NOT NOTARIZED. Gatekeeper will warn users. Do not publish it.  #" >&2
    echo "################################################################" >&2
  fi
fi

notarize() {  # notarize <file>: submit, wait, fail unless Accepted
  local file="$1" result status id
  result="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
  status="$(printf '%s' "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
  id="$(printf '%s' "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
  echo "notarization of $(basename "$file"): $status (submission $id)"
  if [[ "$status" != "Accepted" ]]; then
    echo "notarization failed; details: xcrun notarytool log $id --keychain-profile <profile>" >&2
    exit 1
  fi
}

rm -rf "$WORK"
mkdir -p "$WORK" "$DIST"
rm -f "$DMG" "$ZIP"

echo "# build universal app (version $VERSION)"
PANECAST_OUT="$WORK" PANECAST_SIGN_IDENTITY="$SIGN_ID" PANECAST_TIMESTAMP="$([[ "$UNSIGNED" == 1 ]] && echo 0 || echo 1)" \
  "$ROOT/scripts/build-sender-app.sh" release --universal

ARCHS="$(lipo -archs "$APP/Contents/MacOS/PaneCast")"
echo "# lipo archs: $ARCHS"
for a in arm64 x86_64; do
  [[ " $ARCHS " == *" $a "* ]] || { echo "binary lacks $a slice" >&2; exit 1; }
done
codesign --verify --deep --strict "$APP"

if [[ "$NOTARIZE" == 1 ]]; then
  echo "# notarize app"
  ditto -c -k --keepParent "$APP" "$WORK/notarize-app.zip"
  notarize "$WORK/notarize-app.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

echo "# dmg"
STAGE="$WORK/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/PaneCast.app"
ln -s /Applications "$STAGE/Applications"
# Disk imajı dış hacimde koşuluyor: `hdiutil create` arada bir "Resource busy" veriyor
# (ölçüldü: 0.2.12 yayımında iki kez, üstüste koşumlarda). Kaynak tarafında bırakılmış bir
# bağ varsa ondan kurtul, sonra kısa aralıklarla yeniden dene — sessiz başarısızlık yerine
# denenmiş bir geri çekilme.
for attempt in 1 2 3; do
  if hdiutil create -volname "PaneCast" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null 2>&1; then
    break
  fi
  echo "dmg denemesi $attempt başarısız — temizlik + yeniden deneme" >&2
  hdiutil detach "/Volumes/PaneCast" -force >/dev/null 2>&1 || true
  rm -f "$DMG"
  [ "$attempt" = 3 ] && { echo "dmg üretilemedi (3 deneme)" >&2; exit 1; }
  sleep 4
done
if [[ "$UNSIGNED" == 0 ]]; then
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
fi
if [[ "$NOTARIZE" == 1 ]]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

echo "# zip"
ditto -c -k --keepParent "$APP" "$ZIP"

SIGNED_STATE="Developer ID signed"
[[ "$UNSIGNED" == 1 ]] && SIGNED_STATE="ad-hoc signed (test build)"
NOTARIZED_STATE="not notarized"
[[ "$NOTARIZE" == 1 ]] && NOTARIZED_STATE="notarized and stapled"
echo "$SIGNED_STATE, $NOTARIZED_STATE" > "$WORK/status.txt"

echo
echo "# result"
ls -l "$DMG" "$ZIP" | awk '{print $5, $9}' | sed "s#$ROOT/##"
if [[ "$NOTARIZE" == 1 ]]; then
  # Only the first line (accepted/rejected + source) is shown: the rest names the certificate holder.
  echo "gatekeeper: $(spctl -a -vv -t exec "$APP" 2>&1 | head -1 | sed "s#$ROOT/##")"
else
  echo "NOT NOTARIZED: signed=$([[ "$UNSIGNED" == 1 ]] && echo no || echo yes), notarized=no"
fi
