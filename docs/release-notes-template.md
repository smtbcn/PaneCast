# PaneCast {{VERSION}}

> İki dil: English below, **Türkçe** sonradan gelir. / Two languages: the Turkish part follows the English one.

Show one Mac window full-screen on your Android TV, with that app's audio. Local network only.

## What's new

{{CHANGES}}

## Downloads

| File | For |
|---|---|
| `PaneCast-{{VERSION}}-macOS.dmg` | Mac (macOS 14.2+ for per-app audio, 14.0+ video only), universal arm64 + x86_64 |
| `PaneCast-{{VERSION}}-macOS.zip` | Same app as a zip |
| `PaneCast-Receiver-{{VERSION}}.apk` | Android TV (Android 8.0+, API 26) |
| `SHA256SUMS.txt` | Checksums of the files above |

Windows sender: planned, not available yet.

macOS build: {{MACOS_STATUS}}.

## Install

- Mac: open the `.dmg`, drag PaneCast to Applications, start it, allow Screen Recording and System Audio Recording.
- TV: sideload the `.apk` (file manager or `adb install`), open PaneCast; it shows a pairing code.

Details: see the README.

## Verify the download

```
shasum -a 256 -c SHA256SUMS.txt
```

SHA-256:

```
{{CHECKSUMS}}
```

## Known limitations

- Media stream is not encrypted on the local network.
- Minimized windows and some Spaces can stop capture.
- One TV, one session at a time.
- The Android APK from GitHub and a Google Play build are signed with different keys; they cannot update each other (uninstall first when switching).

---

# PaneCast {{VERSION}} — Türkçe

Bir Mac penceresini Android TV'de tam ekran, o uygulamanın kendi sesiyle gösterin. Yalnızca yerel ağda çalışır.

## Neler yeni

{{CHANGES_TR}}

## İndirmeler

| Dosya | Ne için |
|---|---|
| `PaneCast-{{VERSION}}-macOS.dmg` | Mac (uygulama başına ses için macOS 14.2+, yalnız görüntü için 14.0+), evrensel arm64 + x86_64 |
| `PaneCast-{{VERSION}}-macOS.zip` | Aynı uygulamanın zip hâli |
| `PaneCast-Receiver-{{VERSION}}.apk` | Android TV (Android 8.0+, API 26) |
| `SHA256SUMS.txt` | Yukarıdaki dosyaların sağlama toplamları |

Windows yayıncısı: planlandı, henüz yayımlanmadı.

macOS derlemesi: {{MACOS_STATUS_TR}}.

## Kurulum

- Mac: `.dmg` dosyasını açın, PaneCast'i Uygulamalar'a sürükleyin, başlatın; **Ekran Kaydı** ve **Sistem Ses Kaydı** izinlerine izin verin.
- TV: `.apk` dosyasını yan yükleyin (dosya yöneticisi ya da `adb install`), PaneCast'i açın; ekranda bir eşleştirme kodu görünür.

Ayrıntılar README'de.

## İndirmeyi doğrula

```
shasum -a 256 -c SHA256SUMS.txt
```

Sağlama toplamları yukarıdaki İngilizce bölümde listelenmiştir; aynı dosyalardır.

## Bilinen sınırlar

- Medya akışı yerel ağda şifrelenmez.
- Küçültülmüş pencereler ve bazı Space'ler yakalamayı durdurabilir.
- Tek TV, aynı anda tek oturum.
- GitHub'daki APK ile Google Play derlemesi farklı anahtarlarla imzalanır; birbirinin üzerine güncellenemez (geçiş yaparken önce kaldırın).
