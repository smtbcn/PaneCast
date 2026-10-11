#!/usr/bin/env bash
# Alıcının eşleştirme v2 mantığını (PasskeyPairing + Pairing kilidi + satır sınırı) JVM'de sınar.
# Mac tarafındaki PairingTests.swift ile aynı test vektörünü kullanır: iki dil aynı baytları üretmeli.
# Yeni bağımlılık yok: Gradle önbelleğindeki Kotlin derleyicisi kullanılır (önce bir kez
# `gradle assembleDebug` koşmuş olmalı). Önbellek başka yerdeyse GRADLE_USER_HOME verin.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${GRADLE_USER_HOME:-$ROOT/.cache/gradle}/caches/modules-2/files-2.1"
jar() { find "$CACHE" -name "$1" ! -name '*sources*' | sort | tail -1; }
KC=$(jar 'kotlin-compiler-embeddable-2.0.21.jar')
CP="$KC:$(jar 'kotlin-stdlib-2.0.21.jar'):$(jar 'kotlin-script-runtime-2.0.21.jar'):$(jar 'kotlin-reflect-2.0.21.jar'):$(jar 'kotlin-daemon-embeddable-2.0.21.jar'):$(jar 'trove4j-1.0.20200330.jar'):$(jar 'annotations-13.0.jar'):$(jar 'kotlinx-coroutines-core-jvm-1.6.4.jar')"
OUT="${TMPDIR:-/tmp}/atvm-pairing-selfcheck"
rm -rf "$OUT"; mkdir -p "$OUT"
SRC="$ROOT/receiver/app/src/main/java/dev/atvm/receiver"
SC="$ROOT/receiver/selfcheck"
java -cp "$CP" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect \
  -cp "$(jar 'kotlin-stdlib-2.0.21.jar')" -d "$OUT" \
  "$SRC/PasskeyPairing.kt" "$SRC/Pairing.kt" "$SRC/Protocol.kt" \
  "$SC/android/util/Log.kt" "$SC/org/json/JSONObject.kt" "$SC/BuildConfig.kt" "$SC/PairingSelfCheck.kt"
java -cp "$OUT:$(jar 'kotlin-stdlib-2.0.21.jar')" dev.atvm.receiver.PairingSelfCheckKt
