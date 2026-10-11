#!/bin/bash
# TV ekran görüntüsünü alıp artifacts/tv/screenshots/ altına kaydeder (salt-okunur screencap).
#
# Not: bu cihazda `screencap` dosyayı /sdcard'a yazamıyor (ölçüldü:
# "Error opening file: /sdcard/atvm_shot.png"), /data/local/tmp çalışıyor.
# Ayrıca video katmanı yakalanmaz (composition type=DEVICE) — bu yalnız UI kanıtıdır.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$ROOT/scripts/env.local.sh" ]] && source "$ROOT/scripts/env.local.sh"

ADB="${ADB:-/Volumes/YEDEK1/BELLEK/android/sdk/platform-tools/adb}"
[[ -x "$ADB" ]] || ADB="$(command -v adb || true)"
DEV="${1:-${TV_SERIAL:-}}"
[[ -n "$DEV" ]] || { echo "TV hedefi verilmedi: scripts/env.local.sh içine TV_SERIAL yaz ya da argüman geç."; exit 1; }

OUT="$ROOT/artifacts/tv/screenshots"; mkdir -p "$OUT"
NAME="$OUT/tv-$(date +%Y%m%d-%H%M%S).png"
$ADB -s "$DEV" shell screencap -p /data/local/tmp/atvm_shot.png
$ADB -s "$DEV" pull /data/local/tmp/atvm_shot.png "$NAME" >/dev/null
$ADB -s "$DEV" shell rm /data/local/tmp/atvm_shot.png
echo "$NAME"
