#!/usr/bin/env bash
# Alıcının kayıp kurtarma mantığını (VideoReorderBuffer + RtpDepacketizer kapısı) JVM'de sınar.
# Yeni bağımlılık yok: Gradle önbelleğindeki Kotlin derleyicisi kullanılır (önce bir kez
# `gradle assembleDebug` koşmuş olmalı). Önbellek yolu GRADLE_USER_HOME'dan gelir (yoksa ~/.gradle).
# Kaynaklar: receiver/app/src/main + receiver/selfcheck.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${GRADLE_USER_HOME:-$HOME/.gradle}/caches/modules-2/files-2.1"
jar() { find "$CACHE" -name "$1" ! -name '*sources*' | sort | tail -1; }
KC=$(jar 'kotlin-compiler-embeddable-2.0.21.jar')
[[ -n "$KC" ]] || { echo "kotlin-compiler-embeddable bulunamadı: $CACHE (önce gradle assembleDebug)"; exit 2; }
CP="$KC:$(jar 'kotlin-stdlib-2.0.21.jar'):$(jar 'kotlin-script-runtime-2.0.21.jar'):$(jar 'kotlin-reflect-2.0.21.jar'):$(jar 'kotlin-daemon-embeddable-2.0.21.jar'):$(jar 'trove4j-1.0.20200330.jar'):$(jar 'annotations-13.0.jar'):$(jar 'kotlinx-coroutines-core-jvm-1.6.4.jar')"
OUT="${TMPDIR:-/tmp}/atvm-reorder-selfcheck"
rm -rf "$OUT"; mkdir -p "$OUT"
SRC="$ROOT/receiver/app/src/main/java/dev/atvm/receiver"
java -cp "$CP" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect \
  -cp "$(jar 'kotlin-stdlib-2.0.21.jar')" -d "$OUT" \
  "$SRC/VideoReorderBuffer.kt" "$SRC/RtpDepacketizer.kt" \
  "$ROOT/receiver/selfcheck/android/util/Log.kt" "$ROOT/receiver/selfcheck/ReorderSelfCheck.kt"
java -cp "$OUT:$(jar 'kotlin-stdlib-2.0.21.jar')" dev.atvm.receiver.ReorderSelfCheckKt
