#!/bin/bash
# Wraps the PaneCast macOS sender into a real PaneCast.app bundle.
#
# Why a bundle: Screen Recording and System Audio Recording (TCC) permissions are only
# granted to an app with an identity (bundle id + signature). A raw CLI binary is refused
# (ScreenCaptureKit error -3801).
#
# Usage:  ./scripts/build-sender-app.sh [debug|release] [--universal]
# Output: artifacts/build/PaneCast.app   (override the directory with PANECAST_OUT)
#
# --universal builds arm64 + x86_64 (release use; needs the full Xcode toolchain).
# Version comes from the VERSION file at the repository root.
#
# Signing identity, first match wins (the certificate name is personal, never committed):
#   1) PANECAST_SIGN_IDENTITY environment variable
#   2) IDENTITY in scripts/signing.local.sh (gitignored; see signing.local.sh.example)
#   3) ad-hoc ("-"): the signature changes on every build, so macOS forgets the Screen
#      Recording grant each time. Use a real Apple Development identity for day-to-day work.
# PANECAST_TIMESTAMP=1 adds a secure timestamp (required for notarization; needs network).
set -euo pipefail

MODE="debug"
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    debug|release) MODE="$arg" ;;
    --universal) UNIVERSAL=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 64 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/src/sender-macos"
OUT="${PANECAST_OUT:-$ROOT/artifacts/build}"
APP="$OUT/PaneCast.app"
# The SwiftPM executable product. The bundle executable is always named PaneCast.
SWIFT_PRODUCT="${PANECAST_SWIFT_PRODUCT:-atvm-sender}"

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
IFS=. read -r V_MAJOR V_MINOR V_PATCH <<< "$VERSION"
[[ -n "${V_MAJOR:-}" && -n "${V_MINOR:-}" && -n "${V_PATCH:-}" ]] \
  || { echo "VERSION must be MAJOR.MINOR.PATCH, got: $VERSION" >&2; exit 1; }
BUILD_NUMBER=$((V_MAJOR * 10000 + V_MINOR * 100 + V_PATCH))

IDENTITY="${PANECAST_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f "$ROOT/scripts/signing.local.sh" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/signing.local.sh"
  IDENTITY="${IDENTITY:-}"
fi
IDENTITY="${IDENTITY:--}"

ARCH_FLAGS=()
if [[ "$UNIVERSAL" == 1 ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "# swift build -c $MODE ${ARCH_FLAGS[*]:-}"
cd "$PKG"
# `swift build --show-bin-path` only prints the path, it does not build: build first.
swift build -c "$MODE" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$MODE" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/$SWIFT_PRODUCT"
[[ -x "$BIN" ]] || { echo "build output not found: $BIN" >&2; exit 1; }

echo "# bundle: $APP (version $VERSION, build $BUILD_NUMBER)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PaneCast"
if [[ -f "$PKG/Resources/AppIcon.icns" ]]; then
  cp "$PKG/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "warning: $PKG/Resources/AppIcon.icns missing, bundling without an icon" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>              <string>PaneCast</string>
    <key>CFBundleIdentifier</key>              <string>app.panecast.sender</string>
    <key>CFBundleName</key>                    <string>PaneCast</string>
    <key>CFBundleDisplayName</key>             <string>PaneCast</string>
    <key>CFBundlePackageType</key>             <string>APPL</string>
    <key>CFBundleShortVersionString</key>      <string>$VERSION</string>
    <key>CFBundleVersion</key>                 <string>$BUILD_NUMBER</string>
    <!-- 14.0 is enough for window video; per-app audio isolation (Core Audio process tap) needs 14.2. -->
    <key>LSMinimumSystemVersion</key>          <string>14.0</string>
    <key>NSHighResolutionCapable</key>         <true/>
    <key>CFBundleIconFile</key>                <string>AppIcon</string>
    <key>LSUIElement</key>                     <false/>
    <key>NSMainNibFile</key>                   <string></string>
    <key>NSAudioCaptureUsageDescription</key>  <string>PaneCast captures the audio of the app you choose to play it on your TV and to mute that app on this Mac. Other apps are not captured.</string>
    <key>NSScreenCaptureUsageDescription</key> <string>PaneCast captures the window you choose to show it full-screen on your TV. Nothing leaves your local network.</string>
    <key>NSLocalNetworkUsageDescription</key>  <string>PaneCast finds your TV and streams the chosen window to it over your local network.</string>
    <key>NSHumanReadableCopyright</key>        <string>Local-network tool. Screen content is sent only to the TV you pair with.</string>
</dict>
</plist>
PLIST

cat > "$OUT/sender-entitlements.plist" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- The app is not sandboxed. Screen Recording and System Audio Recording are TCC
         permissions and need no entitlement; hardened runtime is enabled at signing. -->
    <key>com.apple.security.network.client</key><true/>
</dict>
</plist>
ENT

SIGN_FLAGS=(--force --options runtime --entitlements "$OUT/sender-entitlements.plist")
if [[ "${PANECAST_TIMESTAMP:-0}" == 1 ]]; then
  SIGN_FLAGS+=(--timestamp)
fi
codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP/Contents/MacOS/PaneCast"
codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP"

echo
echo "# verification"
# Only identifier/format/flags are printed: Authority and TeamIdentifier lines are personal.
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "^Identifier=|^Format=|flags=" | head -3
echo "bundle id: $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"
echo "archs:     $(lipo -archs "$APP/Contents/MacOS/PaneCast")"
echo
echo "Run:  $APP/Contents/MacOS/PaneCast"
echo "On first start macOS asks for Screen Recording and System Audio Recording; without them capture fails (-3801)."
echo "The grant persists across rebuilds only while bundle id and signing identity stay the same."
