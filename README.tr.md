# PaneCast

[English](README.md) | [Türkçe](README.tr.md)

Mac'inizde bir pencere seçin; Android TV'nizde tam ekran, o uygulamanın sesiyle birlikte
görünsün. Uygulama Mac'te susturulur, diğer tüm uygulamalar orada çalmaya devam eder.
Her şey yerel ağınızda kalır: hesap, bulut ve telemetri yok.

- Bugün Mac → Android TV. Windows yayıncısı planlı, henüz yok.
- Yalnızca seçilen pencere yakalanır; masaüstünün geri kalanı gönderilmez.
- Açık kaynak, MIT.

## İndirme

Son sürümü [GitHub Releases](../../releases) sayfasından alın:

| Platform | Dosya |
|---|---|
| macOS (universal, Apple silicon + Intel) | `PaneCast-<sürüm>-macOS.dmg` (veya `.zip`) |
| Android TV | `PaneCast-Receiver-<sürüm>.apk` |
| Windows | Planlı, henüz yok |

İndirdiklerinizi aynı sürümdeki `SHA256SUMS.txt` ile doğrulayın.

## Kurulum

**Mac**

1. `.dmg` dosyasını açın ve PaneCast'i Uygulamalar'a sürükleyin.
2. PaneCast'i başlatın. macOS **Ekran Kaydı** ve **Sistem Ses Kaydı** izni ister;
   ikisine de izin verin (Sistem Ayarları → Gizlilik ve Güvenlik). macOS isterse uygulamayı yeniden başlatın.

**Android TV**

1. `.apk` dosyasını yan yükleyin: TV'ye kopyalayıp bir dosya yöneticisiyle açın ya da
   `adb install PaneCast-Receiver-<sürüm>.apk`. İstenirse o kaynaktan kuruluma izin verin.
2. TV'de PaneCast'i açın. Bir eşleştirme kodu gösterir.

## Kullanım

1. Mac ve TV aynı ağda olsun. Keşif otomatiktir (mDNS).
2. İlk seferde bir kez eşleştirin: TV'de görünen kodu girin. Kod ağ üzerinden gönderilmez.
3. Yayını iki taraftan da başlatabilirsiniz: Mac'te bir pencere seçin ya da TV'den yayın isteyin.
4. Pencere TV'de tam ekran ve sesiyle görünür. İki taraftan da durdurulabilir.

## Gereksinimler

| | En düşük |
|---|---|
| Mac | Uygulama bazlı ses ayrımı için macOS 14.2; macOS 14.0'da yalnız görüntü (yedek) |
| Android TV | Android 8.0 (API 26). Android 11 TV'de denendi |
| Ağ | Aynı yerel ağ; aşağıdaki sayılar için kablolu Mac ve 5 GHz Wi-Fi TV kullanıldı |

TV'de donanım H.264 çözücüsü gerekir (yazılım yedeği yoktur).

## TV ekranı modu

Uygulamada **TV ekranı (ayrı ekran)** seçilirse tek pencere yerine sanal bir ekranın tamamı yayınlanır. Mac'te "PaneCast TV" adında TV boyutunda (1920x1080) bir ekran açılır; oraya taşıdığın pencereler (tam ekran da olur) ve sesleri TV'de oynar. O ekrandan ayrılan uygulamaların sesi Mac'te yeniden açılır. Sanal ekran her zaman görünür olduğundan ana ekranda uygulama değiştirmek yayını artık dondurmaz (ana ekrandaki tam ekran pencere, başka uygulamaya geçince macOS tarafından gizlenir). CLI: `mirror --tv <ip> --tv-display`.

- Sistem Ayarları → Masaüstü ve Dock → "Ekranların ayrı Space'leri var" açık kalmalı (varsayılan).
- Mod, macOS'un özel (herkese açık olmayan) bir API'sine dayanır (CoreGraphics sanal ekranları). Gelecekteki bir macOS güncellemesi bunu bozabilir; bozulursa uygulama çökmez, modu bir iletiyle kapatır.

## Başarım

Tek bir kurulumda ölçüldü: Ethernet'te Mac mini M4, 5 GHz Wi-Fi'da Android 11 TV.
Başka ağ ve cihazlarda sonuçlar farklı olur.

| Metrik | Sonuç | Kaynak |
|---|---|---|
| Yakalama | 1080p60 | Ölçüldü |
| TV'de oynatılan | ~58 fps, 60 sn boyunca 0 düşen kare | Ölçüldü |
| Çözme-gösterim gecikmesi | p50 ≈ 9 ms | Ölçüldü (TV tarafı) |
| Ses/görüntü senkron hatası | p95 ≈ 5–8 ms | Ölçüldü (yazılım zaman damgası) |
| Kayıp kurtarma | %1 ve %3 enjekte kayıpta 0 kurtarılamayan paket | Ölçüldü |

Bunlar yazılım zaman damgalarıdır; camdan cama gecikmeyi **kanıtlamaz**, o ölçülmedi.

## Nasıl çalışır

```
Mac                                                       Android TV
ScreenCaptureKit (tek pencere) → VideoToolbox H.264 ─┐
                                  RTP/UDP, hız       ├──→  RTP → MediaCodec (donanım) → ekran
                                  düzenleme, NACK  ──┘
Core Audio süreç tap'i (yalnız o uygulama) → L16 RTP ───→  titreşim tamponu → AudioTrack
ortak saat ile ses/görüntü senkronu
TCP kontrol kanalı (eşleştirme, başlat/durdur)  ←──────→  mDNS keşfi
```

- Görüntü: pencere yakalama, donanım H.264, RTP/UDP; hız düzenlemeli gönderim ve kayıp paketler için NACK ile yeniden gönderim.
- Ses: Core Audio süreç tap'i yalnız seçilen uygulamayı yakalar, 16 bit PCM olarak RTP ile gider ve titreşim tamponundan çalınır. Görüntü ve ses tek saati paylaşır.
- Kontrol ve keşif: TCP kontrol kanalı; TV'yi ve Mac'i mDNS bulur.
- Tel ayrıntıları: [`docs/protocol.md`](docs/protocol.md).

## Gizlilik

Hesap, bulut, telemetri, analitik yok. PaneCast yalnızca yerel ağınızda eşleştirdiğiniz
cihazlarla konuşur. Çalışmak için internet gerekmez.

## Güvenlik

- Eşleştirme, ekrandaki kodla onaylanan geçici (ephemeral) bir anahtar değişimi kullanır; kod ağ üzerinden geçmez.
- **Medya akışı (görüntü ve ses) yerel ağda şifreli değildir.** Aynı ağda trafiği yakalayan biri izleyebilir. Güvendiğiniz bir ağ kullanın.
- Ayrıntılar ve sorun bildirme: [`SECURITY.md`](SECURITY.md).

## Sınırlar

- Ses ayrımı **uygulama bazlıdır, tarayıcı sekmesi bazlı değil**: bir tarayıcı penceresini yayınlarsanız o tarayıcı uygulamasının tüm sesi gider ve Mac'te susturulur.
- Küçültülmüş pencereler ve bazı Space durumlarında yakalama durabilir.
- Aynı anda tek TV, tek oturum.
- Windows yayıncısı henüz yok.
- Medya akışı korumasızdır (bkz. Güvenlik).

## Kaynaktan derleme

Yayıncı (macOS): macOS 26 üzerinde Xcode 27 / Swift 6.4 ile geliştirildi; paket macOS 14'ü hedefler.

```bash
./scripts/build-sender-app.sh debug      # → artifacts/build/PaneCast.app
(cd src/sender-macos && swift test)
```

Ekran Kaydı izni yalnız gerçek bir `.app` paketine verilir; ham ikiliyi değil paketi çalıştırın.

Alıcı (Android TV): JDK 17, Gradle 8.14, Android SDK (platform 36).

```bash
cd receiver && gradle assembleDebug       # üçüncü taraf bağımlılık yok, AndroidX yok
```

Yayın derlemeleri ve imzalama: [`docs/RELEASING.md`](docs/RELEASING.md) (İngilizce).

## Katkı

[`CONTRIBUTING.md`](CONTRIBUTING.md) dosyasına bakın. Kısaca: yeni özellikten çok ölçülmüş iyileştirme,
yeni çalışma zamanı bağımlılığı yok, depoda kişisel veri yok.

## Lisans

[MIT](LICENSE).
