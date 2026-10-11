#!/bin/bash
# ADB eşleşmiş/uygun TV'ye tekrar bağlanma yardımcısı.
# Cihaz tarafında hiçbir ayarı değiştirmez; sadece yerel adb sunucusunu sıfırlar
# ve TV ekranındaki RSA onay diyaloğunu yeniden tetikler.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$ROOT/scripts/env.local.sh" ]] && source "$ROOT/scripts/env.local.sh"   # yerel değerler, depoda değil

ADB="${ADB:-/Volumes/YEDEK1/BELLEK/android/sdk/platform-tools/adb}"
[[ -x "$ADB" ]] || ADB="$(command -v adb || true)"
TV_IP="${1:-${TV_IP:-}}"    # boşsa aşağıdaki mDNS keşfi belirler

tv_from_mdns() {
  local name
  name="$(dns-sd -B _googlecast._tcp local. 2>/dev/null | awk 'NR>3 && !seen[$0]++ {print $NF; exit}')"
  [[ -z "$name" ]] && return 1
  dns-sd -L "$name" _googlecast._tcp local. 2>/dev/null |
    awk '/can be reached at/{print $6; exit}'
}

HOST="$(tv_from_mdns || true)"
if [[ -n "${HOST:-}" ]]; then
  IP="$(dscacheutil -q host -a name "$HOST" 2>/dev/null | awk '/ip_address/{print $2; exit}')"
  [[ -n "$IP" ]] && TV_IP="$IP" && echo "# mDNS keşfi: $HOST -> $TV_IP"
fi

[[ -n "$TV_IP" ]] || { echo "TV adresi bulunamadı: scripts/env.local.sh içinde TV_IP tanımla ya da TV'de alıcı uygulamasını açık tut."; exit 1; }
echo "# hedef: $TV_IP:5555"
"$ADB" disconnect "$TV_IP:5555" >/dev/null 2>&1 || true
"$ADB" kill-server >/dev/null 2>&1 || true
"$ADB" start-server >/dev/null 2>&1
"$ADB" connect "$TV_IP:5555" || true
sleep 2
"$ADB" devices -l
cat <<'TXT'

Eğer durum "unauthorized" ise:
  TV ekranındaki "Allow USB debugging / USB hata ayıklamaya izin verilsin mi?" penceresinde
  "Bu bilgisayara her zaman izin ver" kutusunu işaretle ve İzin Ver'e bas.
  Pencere görünmüyorsa bu scripti tekrar çalıştır (onay her yeni bağlantıda yeniden istenir).
TXT
