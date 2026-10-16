# Pane Cast'i yayımlama

> Türkçesi bu dosya; İngilizce aslı: [RELEASING.md](RELEASING.md)

Sürüm artefaktları **bakımcı (maintainer) tarafından yerel olarak** derlenir ve imzalanır. Buradaki
hiçbir şey CI'da koşmaz ve imzalama malzemesi asla commit'lenmez (`dist/`, `*.jks`, `*.keystore`,
`*.p12`, `receiver/keystore.properties`, `scripts/*.local.*` gitignore'dadır).

`X.Y.Z` sürümünün artefaktları (tek doğru kaynak: depo kökündeki `VERSION` dosyası; gradle de macOS
betikleri de onu okur):

| Dosya | Nereye gider |
|---|---|
| `dist/PaneCast-X.Y.Z-macOS.dmg` ve `.zip` | GitHub Release |
| `dist/PaneCast-Receiver-X.Y.Z.apk` | GitHub Release |
| `dist/SHA256SUMS.txt`, `dist/RELEASE_NOTES.md` | GitHub Release |
| `artifacts/play/PaneCast-Receiver-X.Y.Z.aab` | yalnız Google Play (GitHub'a asla eklenmez) |

Android `versionCode` değeri `VERSION` dosyasından `major*10000 + minor*100 + patch` biçiminde
türetilir (0.1.0 = 100). Her Play yüklemesinde bu değer artmalıdır.

## Tek seferlik kurulum (bunları bakımcı çalıştırır)

Gereksinimler: Xcode (komut satırı araçları + tam uygulama), JDK 17, Gradle 8.14, build-tools içeren
Android SDK, [GitHub CLI](https://cli.github.com), bir Apple Developer Program üyeliği.

### 1. Android yükleme anahtar deposu (keystore)

Keystore'u **deponun dışında** tutun ve yedekleyin (parola yöneticisi + çevrimdışı kopya). Onu
kaybetmek, GitHub APK hattına artık güncelleme çıkaramayacağınız anlamına gelir.

```bash
mkdir -p ~/.panecast
keytool -genkeypair -v -keystore ~/.panecast/upload.jks \
  -alias panecast -keyalg RSA -keysize 4096 -validity 10000
```

`receiver/keystore.properties` dosyasını oluşturun (gitignore'da):

```properties
storeFile=/absolute/path/to/upload.jks
storePassword=<store password>
keyAlias=panecast
keyPassword=<key password>
```

Alternatif olarak `PANECAST_KEYSTORE`, `PANECAST_KEYSTORE_PASSWORD`, `PANECAST_KEY_ALIAS` ve
`PANECAST_KEY_PASSWORD` değişkenlerini dışa aktarın. İkisi de yoksa `assembleRelease`, uyarıyla
**imzasız** bir APK üretir (asla debug anahtarına geri düşmez) ve `scripts/release-android.sh`
çalışmayı reddeder.

### 2. macOS Developer ID ve noter onayı (notarization)

1. Apple Developer hesabınızda bir **Developer ID Application** sertifikası oluşturun ve giriş
   (login) anahtar zincirine kurun. Kontrol: `security find-identity -v -p codesigning | grep "Developer ID Application"`.
2. Noter onayı kimlik bilgilerini bir kez saklayın (Apple ID hesap sayfasından alınan uygulamaya özel parola):

   ```bash
   xcrun notarytool store-credentials "panecast-notary" \
     --apple-id "<apple-id>" --team-id "<team-id>" --password "<app-specific-password>"
   ```
3. `scripts/signing.local.sh.example` dosyasını `scripts/signing.local.sh` olarak kopyalayın ve
   `RELEASE_IDENTITY` (1. adımdaki sertifika adı ya da SHA-1 özü) ile
   `NOTARY_PROFILE="panecast-notary"` alanlarını doldurun. `NOTARY_PROFILE` yoksa `release-macos.sh`
   yine imzalı bir derleme üretir ama yüksek sesle uyarır: derleme **noter onaylı (notarized) değil**,
   onu yayımlamayın.

## Yayın kontrol listesi

1. Yeni sürümü `VERSION` dosyasına yazın (ör. `0.1.0`). "What's new" metnini bir dosyaya yazın
   (aşağıda `RELEASE_CHANGES_FILE` olarak kullanılıyor) **ve Türkçe karşılığını kardeş dosyaya**
   yazın (`whats-new-<sürüm>.tr.md`, `RELEASE_CHANGES_TR_FILE` olarak kullanılır). Sürüm notları iki dillidir:
   Türkçe dosya olmadan yayımlanan sürümün "Neler yeni" bölümü boş kalır ve betik yüksek sesle uyarır.
2. Temiz denetimler:
   ```bash
   python3 scripts/scrub-personal-data.py --check --worktree
   (cd src/sender-macos && swift test)
   (cd receiver && gradle assembleDebug) && scripts/test-receiver-reorder.sh
   ```
   Denetim **commit üstverisini** de okur: `--check --worktree`, `git config user.email` değeri
   yasaklı bir kimliğe çözülen depoyu reddeder (bir iş makinesi çoğu zaman işveren adresini miras
   alır), `--check --all-history` ise ulaşılabilir her commit'in yazar ve imzacı e-postasını tarar.
   İzin verilen kamuya açık değerler `scripts/privacy-patterns.local.txt` (gitignore'da) dosyasında
   `+value` satırları olarak listelenir; aykırı değerler asla yazdırılmaz. Depo-yeri kimliği
   **ilk commit'ten önce** kurun — sonrasında geçmişi yeniden yazmak maliyetlidir ve push edilmiş
   bir işveren adresi geri alınamaz.
3. Her şeyi derleyin:
   ```bash
   RELEASE_CHANGES_FILE=path/to/whats-new.md \
   RELEASE_CHANGES_TR_FILE=path/to/whats-new.tr.md ./scripts/release-all.sh
   ```
   Bu, `release-macos.sh` (universal arm64 + x86_64, sertleştirilmiş çalışma zamanı, noter onayı,
   staple, dmg + zip) ve `release-android.sh` (imzalı APK + AAB, `apksigner verify`) betiklerini
   çalıştırır, sonra `docs/release-notes-template.md` şablonundan `dist/SHA256SUMS.txt` ve
   `dist/RELEASE_NOTES.md` dosyalarını yazar.
4. Yayımlamadan önce elle doğrulayın:
   - `xcrun stapler validate dist/PaneCast-X.Y.Z-macOS.dmg`
   - bağlanan dmg içindeki uygulamaya `spctl -a -vv -t exec` (beklenen "accepted", kaynak
     "Notarized Developer ID")
   - uygulamanın ikilisine `lipo -archs` (beklenen `x86_64 arm64`)
   - APK'yı gerçek bir Android TV'ye kurun ve bir eşleştirme + yayın oturumu çalıştırın; sesiyle
     birlikte bir Mac yayını yapın.
   - `dist/RELEASE_NOTES.md` macOS için "notarized and stapled" yazmalı; "not notarized" yazıyorsa
     kurulumu düzeltip yeniden derleyin.
5. Sürüm artışını commit'leyin, etiketleyin ve push edin (bakımcı işlemi). **Hafif (lightweight)**
   etiket kullanın: push öncesi gizlilik denetimi tarihçedeki her cismi okur ve açıklamalı (annotated)
   bir etiket cismi kendi etiketleyici adını ve e-postasını taşır; bu yüzden `git tag -a` kullanırsanız
   sürüm bu deponun kendi denetimine takılıp reddedilir.
   ```bash
   git tag v0.1.0
   git push origin main v0.1.0
   ```
6. GitHub Release'i oluşturun (bakımcı işlemi; önce gözden geçirmek için `--draft` ekleyin):
   ```bash
   gh release create v0.1.0 dist/* --title "PaneCast 0.1.0" --notes-file dist/RELEASE_NOTES.md
   ```
7. Yayımladıktan sonra varlıkları sürüm sayfasından indirin ve `SHA256SUMS.txt` üzerinden doğrulayın.

## Google Play (Android TV)

AAB `artifacts/play/PaneCast-Receiver-X.Y.Z.aab` dosyasıdır ve bir GitHub sürümüne asla eklenmez:
GitHub APK'sı ile Play APK'sı farklı sertifikalarla imzalanır (aşağıya bakın).

### Tek seferlik Console kurulumu

1. **Uygulamayı oluşturun**: Play Console'da `app.panecast.receiver` paketi için (varsayılan dil,
   başlık, ücretsiz, uygulama, hedef kitle). Paket adı sonrasında asla değişmez.
2. **Play App Signing:** Google tarafından üretilen uygulama imzalama anahtarını olduğu gibi bırakın.
   Kendi keystore'umuz yalnızca *yükleme* (upload) anahtarı olarak kalır; böylece deponun yakınından
   sızan bir anahtar Play imzalı kurulum üretemez.
3. **API için hizmet hesabı:** Google Cloud → IAM → hizmet hesabı → JSON anahtarı →
   `secrets/play-service-account.json` olarak kaydedin (gitignore'da, asla commit'lenmez). Sonra o
   e-posta adresini Play Console → Users and access permissions bölümünde "App releases: manage
   releases and testing tracks" yetkisiyle davet edin.
4. **Uygulama içeriği:** gizlilik politikası URL'si, içerik derecelendirme anketi, Veri güvenliği
   formu (Pane Cast hiçbir şey toplamaz: hesap yok, bulut yok, telemetri yok), reklamlar = yok.
   Politika metni `docs/PRIVACY.md` dosyasıdır ve bu deponun GitHub Pages sitesi üzerinden sunulur.
5. **Test kanalları:** kapalı test (closed-testing) kanalının deneyen listesi API üzerinden
   oluşturulamaz; önce Console → Testing → Closed testing içinde kendi e-posta adresinizi ekleyin.

### Yükleme

```bash
./scripts/release-all.sh                                   # rebuilds the AAB
./scripts/release-play.sh --selftest                       # offline proof of the JWT signing chain
PLAY_TRACK=closed ./scripts/release-play.sh                # upload → track → validate, nothing released
PLAY_TRACK=closed PLAY_COMMIT=1 ./scripts/release-play.sh  # the approved step: commit the release
```

Betik, AAB'nin yerel SHA-256 özetini yazdırır ve yüklemeden sonra Play'in geri bildirdiği özetle
karşılaştırır; böylece kırpılmış ya da yanlış bir derleme, hiçbir şey yayımlanmadan yakalanır. Jetonlar
ve anahtarlar asla yazdırılmaz. `validate` başarısız olursa değişiklik geri alınır ve Play'in kendi
iletisi eksik olan Console yanıtını adıyla bildirir.

### Önemli notlar

- Play for TV AAB, bir **leanback başlatıcı etkinliği** ve `android.software.leanback` özelliği
  ister (ikisi de manifest'te bildirilir). Üretim listesi için mağazada 1280x720 bir TV afişi ve TV
  ekran görüntüleri gereklidir; test kanalları mağaza görselleri olmadan yayımlanabilir.
- **Hedef API düzeyi:** alıcı `targetSdk = 34` bildirir (0.2.0'da Android TV Play alt sınırı için
  yükseltildi). Her yüklemeden önce güncel Play kuralını yeniden kontrol edin; 35 ve üstüne çıkmak
  gerçek TV'de yeniden test demek, çünkü buradaki alıcı donanımı API 30 çalıştırıyor. GitHub APK'ları
  bundan etkilenmez.
- `versionCode`, `VERSION` dosyasından türetilir (`major*10000 + minor*100 + patch`), yani 0.2.0 = 200.
  Her Play yüklemesinde kesinlikle artmalıdır.

### GitHub APK'sı ile Play derlemesi: imzalama anahtarları farklı

- GitHub APK'sı kendi yayın keystore'umuzla imzalanır; Play'in sunduğu APK ise Google'ın ürettiği
  uygulama imzalama anahtarıyla imzalanır.
- Android, imzalama sertifikası farklı olan bir uygulamanın güncellenmesini reddeder, dolayısıyla
  kimse iki kanal arasında güncelleme yaparak geçemez: önce kaldırın, bu saklanan eşleştirmeyi de
  siler. Mağaza listesinde bunu belirtin.
- Keystore'umuzu Play uygulama imzalama anahtarı olarak yüklemek iki kanalı birleştirirdi, ama
  deponun yakınındaki bir anahtarı Play imzalama yoluna sokar; bu ödün bu uygulama için kabul edilmedi.


## Kapsanmayanlar

- Windows yayıncısı: henüz yok.
- Otomatik güncellemeler: yok (güncelleme çatısı yok, telemetri yok).
