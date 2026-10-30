#!/usr/bin/env bash
# PaneCast — Windows çekirdeğini build-host'ta derleyip koşar (ADR-008: derleme PC'de yapılır;
# bu Mac'ten cross-build elendi: C++/WinRT MSVC ister, dotnet/cargo/mingw yok — ölçüldü).
#
# Kullanım: scripts/win-build.sh <exe-adi> <src/sender-windows içine göreli kaynaklar...>
#   scripts/win-build.sh pairingVectors tools/pairingVectors.cpp src/Crypto.cpp src/Pairing.cpp
#
# Senkron önce uzak kopyayı SİLER: `scp -r` varolan klasörün içine iç içe kopyalıyor ve
# bayat kaynak aynı hatayı tekrar ettiriyordu (ölçüldü). Kişisel değer yok: WIN_HOST yalnız
# scripts/env.local.sh içinde durur.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$ROOT/scripts/env.local.sh" ]] && source "$ROOT/scripts/env.local.sh"
HOST="${WIN_HOST:-winbuild}"

[[ $# -ge 2 ]] || { echo "kullanım: $0 <exe-adi> <kaynaklar...>"; exit 2; }
NAME="$1"; shift

echo "# 1) uzak kaynak klasörü tazeleniyor ($HOST)"
ssh "$HOST" 'Remove-Item -Recurse -Force "$env:USERPROFILE\\panecast-src" -ErrorAction SilentlyContinue' || true
echo "# 2) kaynaklar kopyalaniyor"
scp -q -r "$ROOT/src/sender-windows" "$HOST:panecast-src"
scp -q "$ROOT/src/sender-windows/tools/build-win.ps1" "$HOST:build-win.ps1"
ssh "$HOST" "powershell -NoProfile -ExecutionPolicy Bypass -File \$env:USERPROFILE\\build-win.ps1 $NAME $*"
