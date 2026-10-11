#!/bin/bash
# PaneCast — TV tarafını salt-okunur denetle.
# Cihazda HİÇBİR şeyi değiştirmez: yalnızca getprop/dumpsys/cat/pull.
# Kullanım: ./scripts/tv-audit.sh [adb-serial]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/artifacts/tv"
ADB="${ADB:-/Volumes/YEDEK1/BELLEK/android/sdk/platform-tools/adb}"
[[ -x "$ADB" ]] || ADB="$(command -v adb || true)"
DEV="${1:-${TV_SERIAL:-}}"

if [[ -z "$ADB" ]]; then echo "adb bulunamadı"; exit 1; fi
mkdir -p "$OUT"

if [[ -z "$DEV" ]]; then
  DEV="$($ADB devices | awk 'NR>1 && $2=="device"{print $1; exit}')"
fi
if [[ -z "$DEV" ]]; then
  echo "Yetkili cihaz yok. Önce: ./scripts/tv-connect.sh  (TV ekranındaki onayı kabul et)"
  $ADB devices -l
  exit 2
fi
echo "# cihaz: $DEV"

sh() { $ADB -s "$DEV" shell "$@" 2>/dev/null | tr -d '\r'; }

PROPS="ro.product.model ro.product.brand ro.product.manufacturer ro.product.name ro.product.device
ro.build.display.id ro.build.date ro.build.type ro.build.version.release ro.build.version.sdk
ro.build.version.security_patch ro.hardware ro.board.platform ro.soc.model ro.soc.manufacturer
ro.product.cpu.abi ro.product.cpu.abilist ro.product.cpu.abilist64
dalvik.vm.heapsize dalvik.vm.heapgrowthlimit ro.opengles.version"

{
  for p in $PROPS; do
    printf "%-34s = %s\n" "$p" "$(sh getprop "$p")"
  done
} | tee "$OUT/props.txt"

sh cat /proc/meminfo | head -4                > "$OUT/meminfo.txt"
sh "cat /sys/devices/system/cpu/possible;
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null;
    grep -m3 -E 'model name|CPU part|Features' /proc/cpuinfo" > "$OUT/cpu.txt"
sh "wm size; wm density"                      > "$OUT/display.txt"
sh dumpsys display                            > "$OUT/dumpsys_display.txt"
sh pm list features                           > "$OUT/features.txt"
sh dumpsys media.audio_policy                 > "$OUT/dumpsys_audio_policy.txt"
sh dumpsys SurfaceFlinger                     > "$OUT/dumpsys_surfaceflinger.txt"

for f in media_codecs.xml media_codecs_c2.xml media_codecs_google_video_le.xml \
         media_codecs_performance.xml media_codecs_performance_c2.xml; do
  $ADB -s "$DEV" pull "/vendor/etc/$f" "$OUT/$f" >/dev/null 2>&1 || echo "eksik: $f"
done

echo
echo "# artefaktlar: $OUT"
echo "# kod adı yeteneklerini özetlemek için: ./scripts/tv-codecs.py $OUT"
