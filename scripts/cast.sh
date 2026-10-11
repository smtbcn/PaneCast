#!/bin/bash
# PaneCast — tek komutla yayın.
#
#   ./scripts/cast.sh list                      # TV'yi ve yayınlanabilir pencereleri listeler
#   ./scripts/cast.sh --app Safari              # Safari'nin ilk penceresini TV'ye verir
#   ./scripts/cast.sh --title "Netflix"         # başlığında geçen pencereyi verir
#   ./scripts/cast.sh --window 4473             # belirli pencere kimliği
#   ./scripts/cast.sh --app Safari --profile 720p60 --duration 3600
#
# Varsayılan: 1080p60, Ctrl-C ile durdurulana kadar sürer.
# Ekran kaydı izni: Terminal/Qoder üzerinden çalıştırırsan miras alınır;
# .app olarak (open) çalıştırırsan bir kez "Ekran Kaydı" onayı gerekir.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$ROOT/scripts/env.local.sh" ]] && source "$ROOT/scripts/env.local.sh"   # yerel değerler, depoda değil
ADB="${ADB:-/Volumes/YEDEK1/BELLEK/android/sdk/platform-tools/adb}"
TV="${TV_IP:-}"
SERIAL="${TV_SERIAL:-${TV:+$TV:5555}}"
[[ -n "$TV" ]] || { echo "TV_IP tanımlı değil: scripts/env.local.sh kopyala (env.local.sh.example) ya da TV_IP=... ile çalıştır."; exit 1; }

# Her zaman derle: `swift build --show-bin-path` YALNIZCA yol yazar, derleme yapmaz;
# çıktı yolu sabitlenirse eski bir ikili sessizce kullanılıyor sanılır.
(cd "$ROOT/src/sender-macos" && swift build) || { echo "derleme başarısız"; exit 1; }
BIN="$(cd "$ROOT/src/sender-macos" && swift build --show-bin-path)/atvm-sender"
[[ -x "$BIN" ]] || { echo "derleme çıktısı bulunamadı: $BIN"; exit 1; }

mode="${1:-}"
if [[ "$mode" == "list" ]]; then
  echo "── TV'ler ──"; "$BIN" list-tvs --seconds 3
  echo; echo "── pencereler ──"; "$BIN" list-windows | grep -vE "Denetim Merkezi|Dock|Menubar"
  exit 0
fi

# TV uykudaysa uyandır ve alıcıyı öne al (ekran koruyucu yüzeyi yok ediyor).
wake_receiver() {
  $ADB -s "$SERIAL" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
  sleep 1
  $ADB -s "$SERIAL" shell am start -n dev.atvm.receiver/.MainActivity --activity-clear-top >/dev/null 2>&1
  sleep 2
}
if ! $ADB devices 2>/dev/null | grep -q "$SERIAL.*device"; then
  echo "TV'de ADB kapalı olabilir — ağ üzerinden bağlanmayı deniyorum:"
  "$ROOT/scripts/tv-connect.sh" "$TV"
fi
wake_receiver

echo "yayın başlatılıyor (durdurmak için Ctrl-C)…"
exec "$BIN" mirror --tv "$TV" --duration "${ATVM_DURATION:-86400}" --wait-permission 180 "$@"
