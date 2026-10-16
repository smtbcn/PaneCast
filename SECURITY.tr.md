# Güvenlik politikası

> Türkçesi bu dosya; İngilizce aslı: [SECURITY.md](SECURITY.md)

PaneCast **yalnızca yerel ağ** için tasarlanmıştır. İnternet dinleyicisi, bulut,
hesap, telemetri ve uzak erişim yoktur.

## Desteklenen sürüm
Bu proje etiketli bir sürüm hattından yayımlanır (şu an 0.2.x hattı; güncel değer `VERSION` içinde). Yalnız en yeni sürüm ve `main` desteklenir — eski sürümler yama almaz, yayın öncesi derlemeler güvenlik garantisi taşımaz.

## Raporlama
Güvenlik açığını **public issue olarak açma**. Repo sahibinin GitHub profilindeki e-posta
ile veya özel güvenlik danışması (private vulnerability report) ile bildir.

## Tehdit modeli

Saldırgan, Mac ve TV ile **aynı yerel ağda** varsayılır.

- **Pasif saldırgan** (trafiği yalnız dinler): eşleştirmeden PIN'i ya da eşleşme anahtarını
  öğrenemez. **Yayınlanan ekran ve ses içeriğini görür ve duyar** (aşağıda).
- **Etkin saldırgan** (araya girer, paket değiştirir, Mac ya da TV taklidi yapar): eşleştirmeyi
  ele geçirme olasılığı deneme başına en çok 10⁻⁶; denemeler TV'de sınırlıdır. Medya akışını
  bozabilir, sahte görüntü enjekte edebilir ve hizmeti engelleyebilir (aşağıda).
- Kapsam dışı: Mac'te ya da TV'de kod çalıştırabilen, kök yetkisi veya fiziksel erişimi olan saldırgan.

## Korunanlar

| Unsur | Durum |
|---|---|
| Eşleştirme | 6 haneli kod yalnız **TV ekranında** görünür; kullanıcı Mac'e yazar. Kod **ağdan hiç geçmez**, özeti de geçmez. Geçici ECDH P-256 + kodun 20 bitinin her biri için taahhüt/açılış turu (Bluetooth LE SC Passkey Entry yapısı, ayrıntı `docs/protocol.md` §3.2). Araya giren her biti dürüst taraf açmadan önce tahmin etmek zorundadır: deneme başına başarı ≤ 10⁻⁶. Ekranı görmeden TV ile doğrudan eşleşmeye çalışan biri için de aynı sınır geçerlidir. |
| Deneme sınırı | Her başarısız denemede kod yenilenir; TV'de 3 başarısız denemede 30 sn kilit, her tekrarda iki katı (en çok 8 dk). |
| Yeniden bağlantı | Kalıcı anahtarla **karşılıklı** HMAC kanıtı, bağlantı başına iki taraflı taze nonce, kanal ve rol etiketli (bir yönün kanıtı diğerine yansıtılamaz). PIN tekrar sorulmaz. |
| Yetki | `start`, `stop`, `unpair` (TV) ve `resume`, `stop`, `idr_request` (Mac) yalnız doğrulanmış oturumda kabul edilir. Doğrulanmamış bağlantının kapanması yayını durdurmaz. `ping` doğrulama istemez ve durum değiştirmez. |
| Kaynak tüketimi | Doğrulama öncesi satır sınırı 8 KB, sessiz bağlantı 15 sn'de kapanır (TV 7601 ve Mac 7610). |
| Sürüm | Eski protokol (v1) uçları `denied/version` alır; v1 anahtarları geçersizdir (TV ilk açılışta siler). |
| Anahtar saklama | Mac: macOS Anahtar Zinciri (`dev.atvm.sender`, hesap = TV IP'si); erişim imzalayan kimliğe bağlı. Eski `paired_keys.json` taşınır ve silinir. TV: uygulamaya özel dizin (`pair_key_v2.bin`), `allowBackup="false"`. |
| Loglar | PIN, anahtar ve ekran içeriği loglanmaz. Tek istisna: **debug** derlemesi otomatik test için eşleştirme kodunu logcat'e yazar; release derlemesi yazmaz. |
| macOS izni | Ekran Kaydı yalnız kullanıcı izniyle; ret durumunda yayın başlamaz. Bir pencerenin kendi sesini yayınlamak ayrıca Sistem Ses Kaydı izni ister; izin yoksa görüntü akmaya devam eder, ses kanalı sessiz kalır. Yayın ancak Mac'te bir pencere (ya da TV ekranı) seçiliyken başlar. |
| Tarama | Cihaz keşfi mDNS ile yapılır; **ağ taraması / kimlik denemesi yapılmaz**. |

## Korunmayanlar (kabul edilen açıklar)

| Unsur | Durum |
|---|---|
| **Medya şifrelemesi** | **YOK.** Görüntü ve ses RTP/UDP ile **düz metin** gider. Aynı ağda trafiği görebilen herkes yayınlanan pencereyi ve sesi kaydedebilir. Eşleştirme ve oturum kanıtı medyayı korumaz. |
| Medya bütünlüğü | RTP paketleri doğrulanmaz. Ağdaki biri SSRC'yi dinleyerek TV'ye sahte ya da bozuk paket enjekte edebilir; alıcı yalnız SSRC/PT eşleşmesine bakar. |
| Kontrol kanalı gizliliği | Kontrol mesajları (`start` parametreleri, cihaz adları, IDR istekleri) şifresizdir; yalnız oturum açılışı kimlik doğrulamalıdır. Oturum açıldıktan sonra mesajlar tek tek doğrulanmaz: TCP oturumunu ele geçirebilen etkin saldırgan o oturumda `stop` ya da `start` enjekte edebilir. |
| Hizmet engelleme | TV'nin kontrol dinleyicisi aynı anda tek bağlantı işler; ağdaki biri bağlanıp bekleyerek (bağlantı başına 15 sn; eşleşmemiş TV'de `hello` sonrası kod beklenirken 180 sn) ya da bilerek yanlış denemelerle kilidi tetikleyerek eşleştirmeyi geciktirebilir. |
| TV anahtar deposu | Donanım destekli anahtar deposu kullanılmıyor (bağımlılıksız tercih); kök yetkisi veya fiziksel erişimi olan saldırgan `pair_key_v2.bin` dosyasını okuyabilir. |
| Cihaz adları | `hello` mesajları Mac'in ve TV'nin kullanıcıya görünen adını düz metin taşır; mDNS yayınları da adı ağa duyurur. |
| Portlar | 7601/tcp ve 7602/udp TV'de, 7610/tcp Mac'te (yalnız IPv4) tüm arayüzlerde dinler; uygulama açıkken dinler, kapalıyken dinlemez. |

## Zafiyet kabul kriteri
Yalnız yerel ağda, eşleşme gerektirmeden kullanılabilen bir açığı ciddi sayarız (yukarıdaki kabul
edilen açıklar hariç). İnternet erişimi gerektiren bir şey "açık" değil, tasarım dışıdır.
