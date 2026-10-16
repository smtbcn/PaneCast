#!/bin/bash
# Runs the macOS and Android release builds, then writes dist/SHA256SUMS.txt and
# dist/RELEASE_NOTES.md (from docs/release-notes-template.md).
#
# Usage:  ./scripts/release-all.sh
# Optional: RELEASE_CHANGES_FILE=<markdown file> for the "What's new" section and
#           RELEASE_CHANGES_TR_FILE=<markdown file> for its Turkish twin ("Neler yeni").
# The notes are bilingual by design: the template carries both languages, so a release
# that skips the Turkish file publishes an English-only note — the script warns loudly.
# Publishing is a separate, manual step: see docs/RELEASING.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
DIST="$ROOT/dist"
TEMPLATE="$ROOT/docs/release-notes-template.md"

rm -rf "$DIST"
"$ROOT/scripts/release-macos.sh"
"$ROOT/scripts/release-android.sh"

echo "# checksums"
(cd "$DIST" && shasum -a 256 \
  "PaneCast-$VERSION-macOS.dmg" "PaneCast-$VERSION-macOS.zip" "PaneCast-Receiver-$VERSION.apk" \
  > SHA256SUMS.txt)
cat "$DIST/SHA256SUMS.txt"

CHANGES="No change notes were provided for this release."
if [[ -n "${RELEASE_CHANGES_FILE:-}" ]]; then
  CHANGES="$(cat "$RELEASE_CHANGES_FILE")"
else
  echo "warning: RELEASE_CHANGES_FILE not set, release notes get a placeholder 'What's new' section" >&2
fi

CHANGES_TR="Bu sürüm için Türkçe not girilmedi."
if [[ -n "${RELEASE_CHANGES_TR_FILE:-}" ]]; then
  CHANGES_TR="$(cat "$RELEASE_CHANGES_TR_FILE")"
else
  echo "warning: RELEASE_CHANGES_TR_FILE not set — the Turkish section of the release notes will be empty" >&2
fi

PANECAST_VERSION="$VERSION" PANECAST_CHANGES="$CHANGES" PANECAST_CHANGES_TR="$CHANGES_TR" \
PANECAST_MACOS_STATUS="$(cat "$ROOT/artifacts/release-macos/status.txt")" \
PANECAST_SUMS="$DIST/SHA256SUMS.txt" PANECAST_TEMPLATE="$TEMPLATE" PANECAST_NOTES="$DIST/RELEASE_NOTES.md" \
/usr/bin/python3 - <<'PY'
import os
t = open(os.environ["PANECAST_TEMPLATE"], encoding="utf-8").read()
status = os.environ["PANECAST_MACOS_STATUS"].strip()
# Durum satırı İngilizce üretiliyor (release-macos.sh); Türkçe bölümde çevrilmiş hâli görünsün.
# Bilinmeyen bir cümle gelirse çeviri uydurulmaz, İngilizce metin kalır.
STATUS_TR = {
    "Developer ID signed, notarized and stapled.":
        "Developer ID ile imzalı, Apple tarafından noter onaylı ve dosyaya demetlenmiş.",
}
values = {
    "{{CHANGES}}": os.environ["PANECAST_CHANGES"].strip(),
    "{{CHANGES_TR}}": os.environ["PANECAST_CHANGES_TR"].strip(),
    "{{MACOS_STATUS}}": status,
    "{{MACOS_STATUS_TR}}": STATUS_TR.get(status, status),
    "{{CHECKSUMS}}": open(os.environ["PANECAST_SUMS"], encoding="utf-8").read().strip(),
    "{{VERSION}}": os.environ["PANECAST_VERSION"],
}
for k, v in values.items():
    t = t.replace(k, v)
open(os.environ["PANECAST_NOTES"], "w", encoding="utf-8").write(t)
PY

echo
echo "# dist"
ls -l "$DIST" | awk 'NR>1 {print $5, $9}'
echo "Play bundle (upload to Google Play only): artifacts/play/PaneCast-Receiver-$VERSION.aab"
