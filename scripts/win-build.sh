#!/usr/bin/env bash
# PaneCast — Windows çekirdeğini build-host'ta derleyip koşar (ADR-008: derleme PC'de yapılır;
# bu Mac'ten cross-build elendi: C++/WinRT MSVC ister, dotnet/cargo/mingw yok — ölçüldü).
#
# Kullanım: scripts/win-build.sh <exe-adi> [LIBS="<kitaplar>"] [RUN="<çalıştırma argümanları>"] <src/sender-windows göreli kaynaklar...>
#   scripts/win-build.sh pairingVectors tools/pairingVectors.cpp src/Crypto.cpp src/Pairing.cpp
#   scripts/win-build.sh winPair LIBS="bcrypt.lib crypt32.lib ws2_32.lib" tools/winPair.cpp src/ControlClient.cpp src/Json.cpp src/Pairing.cpp src/Crypto.cpp
#   scripts/win-build.sh winCore RUN="presence 1.5" tools/winCore.cpp src/KeyStore.cpp ...
#
# Senkron önce uzak kopyayı SİLER: `scp -r` varolan klasörün içine iç içe kopyalıyor ve
# bayat kaynak aynı hatayı tekrar ettiriyordu (ölçüldü). Kişisel değer yok: WIN_HOST yalnız
# scripts/env.local.sh içinde durur.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$ROOT/scripts/env.local.sh" ]] && source "$ROOT/scripts/env.local.sh"
HOST="${WIN_HOST:-}"
[[ -n "$HOST" ]] || { echo "WIN_HOST tanımsız: scripts/env.local.sh (gitignore) içine yaz."; exit 2; }

[[ $# -ge 2 ]] || { echo "kullanım: $0 <exe-adi> <kaynaklar...>"; exit 2; }
NAME="$1"; shift

echo "# 1) uzak kaynak klasörü tazeleniyor ($HOST)"
ssh "$HOST" 'Remove-Item -Recurse -Force "$env:USERPROFILE\\panecast-src" -ErrorAction SilentlyContinue' || true
echo "# 2) kaynaklar kopyalaniyor"
scp -q -r "$ROOT/src/sender-windows" "$HOST:panecast-src"
scp -q "$ROOT/src/sender-windows/tools/build-win.ps1" "$HOST:build-win.ps1"
# -File ile adlandırılmış parametreler: konumsal bağlama ilk kaynak yutuyordu (ölçüldü).
LIBS="bcrypt.lib crypt32.lib ws2_32.lib iphlpapi.lib"
if [[ "${1:-}" == LIBS=* ]]; then LIBS="${1#LIBS=}"; shift; fi
RUN=""
if [[ "${1:-}" == RUN=* ]]; then RUN="${1#RUN=}"; shift; fi
SRC="$(IFS=,; echo "$*")"
ssh "$HOST" "powershell -NoProfile -ExecutionPolicy Bypass -File \$env:USERPROFILE\\build-win.ps1 -Name $NAME -Sources $SRC -Libs \"$LIBS\" -RunArgs \"$RUN\""
