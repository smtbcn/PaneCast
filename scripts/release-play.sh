#!/bin/bash
# PaneCast → Google Play: imzalı AAB'yi Play Developer API ile yükler, kanala verir, doğrular.
#
# Kullanım:
#   ./scripts/release-play.sh --selftest                        # ağa çıkmadan JWT zincirini kanıtlar
#   PLAY_TRACK=closed ./scripts/release-play.sh                 # yükle + kanala ver + validate (commit YOK)
#   PLAY_TRACK=closed PLAY_COMMIT=1 ./scripts/release-play.sh   # onaylı adımda commit (yayına alma)
#
# Gereksinimler (hiçbiri depoya girmez):
#   secrets/play-service-account.json — Google Cloud hizmet hesabı JSON anahtarı (client_email, private_key).
#     Play Console → Kullanıcılar ve erişim hakları → bu hizmet hesabı e-postası davet edilmeli ve
#     "App releases: manage releases and testing tracks" yetkisi verilmeli.
#   Uygulama Play Console'da bir kez oluşturulmuş olmalı (paket adı app.panecast.receiver).
#   Kapalı test kanalı için testçı listesi Console'da tanımlı olmalı (API üzerinden oluşturulamaz).
#
# Token/anahtar hiçbir yere yazılmaz ve basılmaz; yalnız HTTP durumu ve Play'in kendi hata metni görünür.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
PACKAGE="${PANECAST_PACKAGE:-app.panecast.receiver}"
AAB="${PANECAST_AAB:-$ROOT/artifacts/play/PaneCast-Receiver-$VERSION.aab}"
KEY_FILE="${PLAY_SERVICE_ACCOUNT:-$ROOT/secrets/play-service-account.json}"
TRACK="${PLAY_TRACK:-closed}"
STATUS="${PLAY_STATUS:-completed}"
USER_FRACTION="${PLAY_FRACTION:-}"
API="https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD_API="https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
SCOPE="https://www.googleapis.com/auth/androidpublisher"
WORK="$ROOT/artifacts/play-publish"

die() { echo "hata: $*" >&2; exit 1; }
b64url() { tr '+/' '-_' | tr -d '=\n'; }          # stdin → base64url (satır sonu yok)

# RS256 JWT kurar: $1 = token_uri, $2 = hizmet hesabı e-postası, $3 = imza anahtarı (PEM yolu)
make_assertion() {
  local token_uri="$1" email="$2" pem="$3" now exp header claims input sig
  now="$(date +%s)"; exp=$((now + 3500))
  header='{"alg":"RS256","typ":"JWT"}'
  claims="$(printf '%s' "$email" | /usr/bin/python3 -c '
import json, sys, time
email = sys.stdin.read().strip()
now = int(time.time())
print(json.dumps({"iss": email, "scope": "'"$SCOPE"'", "aud": sys.argv[1],
                  "exp": now + 3500, "iat": now}, separators=(",", ":")), end="")
' "$token_uri")"
  input="$(printf '%s' "$header" | base64 | b64url).$(printf '%s' "$claims" | base64 | b64url)"
  sig="$(printf '%s' "$input" | openssl dgst -sha256 -sign "$pem" -binary | base64 | b64url)"
  printf '%s.%s' "$input" "$sig"
}

# base64url imzasını DER'e çevirir (doğrulama için)
sig_to_der() {
  /usr/bin/python3 -c '
import base64, sys
s = sys.stdin.read().strip()
sys.stdout.buffer.write(base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)))
'
}

# ---- --selftest: çevrimiçi olmadan imzalama zincirinin doğru olduğunu kanıtla ----
# NOT: depo gizlilik denetimi e-posta desenini yasaklıyor → iss burada adres şeklinde yazılmaz.
SELFTEST_ISS="selftest-service-account"
if [[ "${1:-}" == "--selftest" ]]; then
  rm -rf "$WORK"; mkdir -p "$WORK"; chmod 700 "$WORK"
  openssl genrsa -out "$WORK/test.key" 2048 2>/dev/null
  assertion="$(make_assertion "https://oauth2.googleapis.com/token" "$SELFTEST_ISS" "$WORK/test.key")"
  payload="${assertion%.*}"; got="${assertion##*.}"
  printf '%s' "$payload" > "$WORK/msg"
  printf '%s' "$got" | sig_to_der > "$WORK/sig.der"
  openssl rsa -in "$WORK/test.key" -pubout -out "$WORK/test.pub" 2>/dev/null
  if openssl dgst -sha256 -verify "$WORK/test.pub" -signature "$WORK/sig.der" "$WORK/msg" >/dev/null 2>&1
  then
    parts=$(printf '%s' "$assertion" | awk -F. '{print NF}')
    echo "selftest: JWT $parts parçalı, RS256 imzası açık anahtarla DOĞRULANDI (ağ kullanılmadı)"
    echo "selftest: claims alanları iss/scope/aud/exp/iat; assertion ${#assertion} bayt"
    rm -rf "$WORK"; exit 0
  fi
  echo "selftest: JWT imzası DOĞRULANAMADI" >&2
  rm -rf "$WORK"; exit 1
fi

[[ -f "$AAB" ]] || die "AAB yok: $AAB (önce ./scripts/release-all.sh)"
[[ -f "$KEY_FILE" ]] || die "hizmet hesabı anahtarı yok: $KEY_FILE
  Google Cloud Console → IAM ve ayrıcalıklar → Hizmet hesapları → anahtar oluştur (JSON) → bu ada kaydedin.
  Play Console → Kullanıcılar ve erişim hakları → kullanıcı davet edin (aynı e-posta), 'App releases'
  yetkisini verin. Dosya secrets/ altında ve .gitignore'dadır."
command -v jq >/dev/null || die "jq gerekli (brew install jq)"

rm -rf "$WORK"; mkdir -p "$WORK"; chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

SERVICE_EMAIL="$(jq -r '.client_email' "$KEY_FILE")"
TOKEN_URI="$(jq -r '.token_uri // "https://oauth2.googleapis.com/token"' "$KEY_FILE")"
[[ -n "$SERVICE_EMAIL" && "$SERVICE_EMAIL" != "null" ]] || die "$KEY_FILE içinde client_email yok"
jq -r '.private_key' "$KEY_FILE" > "$WORK/claim.pem"; chmod 600 "$WORK/claim.pem"
[[ -s "$WORK/claim.pem" ]] || die "$KEY_FILE içinde private_key yok"

LOCAL_SHA="$(shasum -a 256 "$AAB" | awk '{print $1}')"
echo "# yüklenecek: $(basename "$AAB") · paket $PACKAGE · kanal $TRACK · durum $STATUS"
echo "# yerel sha256: $LOCAL_SHA"

http() { local method="$1" url="$2"; shift 2
         curl -sS -o "$WORK/resp.json" -w '%{http_code}' -X "$method" "$url" "$@"; }

# 1) erişim jetonu
assertion="$(make_assertion "$TOKEN_URI" "$SERVICE_EMAIL" "$WORK/claim.pem")"
code="$(http POST "$TOKEN_URI" --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
      --data-urlencode "assertion=$assertion")"
[[ "$code" == "200" ]] || die "token alınamadı (HTTP $code): $(jq -r '.error_description // .error // "-"' "$WORK/resp.json" 2>/dev/null | head -1)"
ACCESS_TOKEN="$(jq -r '.access_token' "$WORK/resp.json")"
AUTH=(-H "Authorization: Bearer $ACCESS_TOKEN")

# 2) düzenleme oturumu
code="$(http POST "$API/$PACKAGE/edits" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{}')"
case "$code" in
  200) ;;
  401|403) die "yetki reddedildi (HTTP $code). Play Console'da bu hizmet hesabına 'App releases' yetkisi verin." ;;
  404) die "paket Console'da yok (HTTP 404). Console → Uygulama oluştur → paket adı $PACKAGE (sabit), sonra yeniden deneyin." ;;
  *) die "edit açılamadı (HTTP $code): $(head -c 300 "$WORK/resp.json")" ;;
esac
EDIT_ID="$(jq -r '.id' "$WORK/resp.json")"
EDIT="$API/$PACKAGE/edits/$EDIT_ID"

# 3) AAB yüklenir; Play'in döndürdüğü sha256 yerel dosyayla karşılaştırılır
code="$(http POST "$UPLOAD_API/$PACKAGE/edits/$EDIT_ID/bundles?uploadType=media" "${AUTH[@]}" \
      -H 'Content-Type: application/octet-stream' --data-binary "@$AAB")"
[[ "$code" == "200" ]] || die "AAB yüklenemedi (HTTP $code): $(head -c 300 "$WORK/resp.json")"
REMOTE_SHA="$(jq -r '.sha256 // "-"' "$WORK/resp.json")"
VERSION_CODE="$(jq -r '.versionCode // "-"' "$WORK/resp.json")"
[[ "$REMOTE_SHA" == "$LOCAL_SHA" ]] || die "Play'deki sha256 yerel ile uyuşmuyor (Play: $REMOTE_SHA)"
echo "# yüklendi: versionCode=$VERSION_CODE · Play sha256 = yerel sha256"

# 4) kanala ver
if [[ -n "$USER_FRACTION" ]]; then
  release="$(jq -nc --arg s stagedRollout --argjson f "$USER_FRACTION" --argjson vc "[$VERSION_CODE]" \
             '{versionCodes:$vc, status:$s, userFraction:$f}')"
else
  release="$(jq -nc --arg s "$STATUS" --argjson vc "[$VERSION_CODE]" '{versionCodes:$vc, status:$s}')"
fi
body="$(jq -nc --arg track "$TRACK" --argjson r "$release" '{track:$track, releases:[$r]}')"
code="$(http PUT "$EDIT/tracks/$TRACK" "${AUTH[@]}" -H 'Content-Type: application/json' -d "$body")"
[[ "$code" == "200" ]] || die "kanal ayarlanamadı (HTTP $code): $(head -c 400 "$WORK/resp.json")"
echo "# kanal $TRACK: $(jq -c '.releases' "$WORK/resp.json")"

# 5) Play doğrulaması; commit ancak PLAY_COMMIT=1 ile
code="$(http POST "$EDIT:validate" "${AUTH[@]}")"
if [[ "$code" != "200" ]]; then
  echo "!! Play doğrulaması geçmedi (HTTP $code): $(head -c 600 "$WORK/resp.json")" >&2
  http DELETE "$EDIT" "${AUTH[@]}" >/dev/null || true
  die "değişiklik geri alındı; eksik olan Console yanıtları (içerik puanı, veri güvenliği, gizlilik politikası, testçı listesi) tamamlanmalı"
fi
echo "# validate: OK"

if [[ "${PLAY_COMMIT:-0}" == "1" ]]; then
  code="$(http POST "$EDIT:commit" "${AUTH[@]}" -H 'Content-Type: application/json' -d '{}')"
  [[ "$code" == "200" ]] || die "commit başarısız (HTTP $code): $(head -c 400 "$WORK/resp.json")"
  echo "# commit: $VERSION sürümü $TRACK kanalında Play'e teslim edildi"
else
  http DELETE "$EDIT" "${AUTH[@]}" >/dev/null || true
  echo "# dry-run bitti (edit geri alındı). Yayına almak için: PLAY_COMMIT=1 ile yeniden çalıştırın."
fi
