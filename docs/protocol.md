# PaneCast Protokolü v2

Tek kaynak spesifikasyon. Uygulamalar:
- macOS: `src/sender-macos/Sources/ATVMSender/{Pairing,KeyStore,ControlClient,SenderServer,Transport,RtpRetransmit}.swift`
- Android TV: `receiver/app/src/main/java/dev/atvm/receiver/{Protocol,PasskeyPairing,Pairing,ControlLink,SenderConnector,RtpDepacketizer,VideoReorderBuffer}.kt`
- Test sürücüleri: `scripts/test-tv-initiated.py`, `scripts/test-audio-source.py`, `scripts/test-receiver-reorder.sh`, `scripts/test-receiver-pairing.sh`

Etiketler: **Doğrulandı** = iki gerçek uç arasında çalıştırıldı (Apple Silicon Mac ↔ Android TV alıcısı, API 30, 2026-10-10).

## 1. Taşıyıcılar

| Kanal | Taşıyıcı | Port | Durum |
|---|---|---|---|
| Kontrol (Mac → TV) | TCP, satır başına UTF-8 JSON (`\n` ayraç), `TCP_NODELAY` açık | 7601 | Doğrulandı |
| Medya | UDP, RTP (RFC 3550) + H.264 (RFC 6184) | 7602 | Doğrulandı |
| Keşif | mDNS/DNS-SD `_atvm._tcp.local.` | — | Doğrulandı (TV `NsdManager.registerService` → Mac `dns-sd`/`NWBrowser` ile gördü) |
| Ters kontrol (TV → Mac) | TCP, aynı JSON-lines sözlüğü | 7610 | Doğrulandı (Mac ucu, `scripts/test-tv-initiated.py`) |
| Bilgisayar keşfi | mDNS/DNS-SD `_atvm-sender._tcp.local.` | — | Doğrulandı (Mac `NetService` → `dns-sd -B` gördü; TV `NsdManager` listesi ekran görüntüsüyle doğrulandı) |

Sabit portlar MVP için yeterlidir; `start` mesajı `media_port` ve `payload_type` alanlarıyla port/PT bildirimini taşır.
7610 **yalnız IPv4** sokettir: `NWListener` bu makinede tek bir IPv6 yuvası açtı ve TV'nin IPv4
SYN'i düşdü (ölçüldü: Mac'ten kendi LAN IP'ne bağlantı var, TV'den 6 sn timeout). Bu yüzden POSIX
`AF_INET` dinleyici kullanılıyor (`Tcp4Listener.swift`).

## 2. Keşif

- TV alıcı uygulaması açılınca `_atvm._tcp` servisini yayınlar:
  `serviceName = "ATVM-<Build.MODEL>"`, `port = 7601`, TXT: `ver`, `cport`, `mport`.
- Mac yayınları tarar (`NWBrowser(.bonjour(type:"_atvm._tcp", domain:"local."))`).
- Yedek 1: Mac, TV'nin yerleşik yayın kaydını (`_googlecast._tcp`) tarayıp IP'yi bulabilir (Doğrulandı: TXT alanında cihaz modeli ve port 8009).
- Yedek 2: elle IP girişi (görev gereği).

## 3. Kontrol mesajları

Ortak alan: `t` (mesaj türü). Bilinmeyen `t` loglanır. Aykırı JSON → `denied/bad_json`; doğrulanmamış
bağlantı ardından kapanır. Her iki dinleyicide (TV 7601, Mac 7610) satır üst sınırı **8192 bayt**tır;
aşan bağlantı kapanır. Doğrulanmamış bağlantı **15 sn** sessiz kalırsa kapanır (TV, `pair_required`
sonrası kullanıcı kodu yazarken 180 sn bekler); doğrulanmış oturumda okuma süresi sınırı yoktur.

| Yön | `t` | Alanlar | Anlamı |
|---|---|---|---|
| Mac→TV | `hello` | `name`, `ver` (=2) | oturum açılışı |
| TV→Mac | `pair_required` | `pin_ttl_ms`, `ver` | eşleşme yok; 6 haneli kod TV ekranında |
| Mac→TV | `pair_init` | `pk` (b64, 65 B) | Mac'in geçici P-256 açık anahtarı (§3.2) |
| TV→Mac | `pair_key` | `pk` (b64, 65 B) | TV'nin geçici P-256 açık anahtarı |
| iki yön | `pk_commit` | `i`, `c` (b64, 32 B) | tur `i` taahhüdü: önce Mac, sonra TV |
| iki yön | `pk_open` | `i`, `n` (b64, 16 B) | tur `i` açılışı: önce Mac (TV sınar), sonra TV (Mac sınar) |
| Mac→TV | `pair_confirm` | `mac` (b64) | Mac'in anahtar onayı (20 tur bittikten sonra) |
| TV→Mac | `paired` | `session`, `mac` (b64) | anahtar kaydedildi + TV'nin anahtar onayı |
| Mac→TV | `pair_abort` | — | Mac denemeyi bıraktı (TV başarısız sayar) |
| TV→Mac | `challenge` | `nonce_tv` (b64), `ver` | zaten eşleşmiş; kanıt iste |
| Mac→TV | `proof` | `nonce_mac` (b64), `proof` (b64) | oturum kanıtı (§3.2) |
| TV→Mac | `ready` | `session`, `proof` (b64) | oturum açık + TV'nin kanıtı; tutmazsa Mac bağlantıyı bırakır |
| TV→Mac | `denied` | `reason`, (`ver`, `retry_after_ms`) | `version` / `locked` / `pin_mismatch` / `pin_expired` / `confirm_mismatch` / `bad_key` / `bad_message` / `auth_failed` / `not_paired` / `already_paired` / `unexpected_message` / `bad_json` |
| Mac→TV | `start` | `width,height,fps,bitrate,ssrc,media_port,payload_type` + `audio_ssrc,audio_payload_type,audio_sample_rate,audio_channels` + `sync,video_rtp_base,audio_rtp_base` | yayın parametreleri (§4.1) ve ortak saat tabanları (§5); yalnız doğrulanmış oturum |
| TV→Mac | `started` | `media_port` | çözücü + UDP hazır |
| TV→Mac | `cap_error` | `reason,max_width,max_height,codecs` | TV bu profili reddetti |
| TV→Mac | `idr_request` | — | paket kaybı: acil anahtar kare iste |
| Mac→TV | `stop` | — | yayını durdur; yalnız doğrulanmış oturum (aksi `denied/not_paired`) |
| TV→Mac | `stopped` | `reason?` | durdu |
| Mac→TV | `unpair` | — | eşleşmeyi sil; yalnız doğrulanmış oturum. TV `stopped/unpaired` yazar, bağlantıyı kapatır |
| çift | `ping`/`pong` | `now` | canlılık; doğrulama istemez, durum değiştirmez |

### 3.1 TV'nin başlattığı yön (kumandadan bilgisayar seçme)

Aynı sözlük, roller yer değiştirir. TV, `_atvm-sender._tcp` listesinden seçtiği bilgisayara
7610'dan bağlanır; böylece yayın iki yönden de başlatılabilir:

```
TV → Mac : hello     {role:"receiver", name, ver:2}
Mac → TV : challenge {nonce_mac, ver:2}      (kayıt yoksa denied/not_paired, sürüm farkı denied/version)
TV → Mac : proof     {nonce_tv, proof = P(K, "rev", "tv",  nonce_mac, nonce_tv)}
Mac → TV : ready     {proof = P(K, "rev", "mac", nonce_mac, nonce_tv)}   (TV doğrulayamazsa bırakır)
TV → Mac : resume    {media_host, media_port, name}
Mac → TV : start     {width,height,fps,bitrate,ssrc,media_port,payload_type,audio_*,sync,video_rtp_base,audio_rtp_base}
TV → Mac : started | cap_error            (çözücü + UDP soketi kuruldu)
... sonra normal akış: TV → Mac idr_request, Mac → TV RTP/UDP, her yönden stop
```

- Bağlantı **açık kalır**: IDR istekleri ve yayın sonlandırma bu soketten gider.
- `idr_request`, `stop` ve bağlantının kapanması yalnız `ready` sonrası yayını etkiler; doğrulanmamış
  bir bağlantı yayını durduramaz (`SenderServerTests`).
- Mac, arayüzde pencere seçili değilse `denied/no_window_selected_on_sender` yazar; rastgele bir
  pencereyi ağa vermez.
- TV'nin eşleşme anahtarı Mac'te Anahtar Zinciri'nde TV'nin IP'siyle durur (§3.3).
- Ölçülen (2026-10-10, v1 el sıkışması, `scripts/test-tv-initiated.py`, TV rolü betikle simüle edildi):
  57,5 fps yakalama, `idr_request` sonrası ana kare, kopuşta yayın 1 sn içinde durdu.
  v2 el sıkışması Mac ucunda birim testiyle doğrulandı; betik v2'ye güncellendi ama arayüzle yeniden
  koşulmadı. **TV ucu cihazda doğrulanamadı** (bilgisayar seçimi kumanda gerektirir).

### 3.2 Eşleştirme kriptosu (v2)

Yapı: Bluetooth LE Secure Connections **Passkey Entry** (geçici ECDH P-256 + PIN'in her biti için
taahhüt/açılış turu). Yalnız platform kriptosu: macOS CryptoKit, Android `java.security`/`javax.crypto`.
PIN TV'de `SecureRandom` ile üretilen 6 basamaklı rastgele sayıdır (`0…999999`, 20 bit); yalnız TV
ekranında görünür, kullanıcı Mac'e yazar. **Ne PIN ne de PIN'den türeyen bir özet ağdan geçer.**

```
pkMac, pkTv   : X9.63 sıkıştırılmamış P-256 noktası (65 B); her denemede yeni geçici anahtar
DH            : ECDH x koordinatı (32 B). Eğri dışı nokta ve karşının kendi anahtarını yansıtması reddedilir.
TH0           : SHA-256("atvm-pair-v2" ‖ pkMac ‖ pkTv)
kc            : HKDF-SHA256(ikm = DH, salt = TH0, info = "atvm-pk-commit-v2", L = 32)
r_i           : PIN'in i. biti (i = 0…19, en düşük bit önce)
Ca_i / Cb_i   : HMAC-SHA256(kc, "M"/"T" ‖ i ‖ r_i ‖ Na_i/Nb_i)      (N: 16 B rastgele, i ve r_i birer bayt)
tur i         : Mac→Ca_i, TV→Cb_i, Mac→Na_i (TV kendi r_i ile Ca_i'yi sınar),
                TV→Nb_i (Mac kendi r_i ile Cb_i'yi sınar)
TH            : SHA-256(TH0 ‖ Ca_0 ‖ Cb_0 ‖ Na_0 ‖ Nb_0 ‖ … ‖ Ca_19 ‖ Cb_19 ‖ Na_19 ‖ Nb_19)
K (kalıcı)    : HKDF-SHA256(ikm = DH, salt = TH, info = "atvm-pair-v2", L = 32)
onay          : Mac→ HMAC(K, "atvm-confirm-v2|mac" ‖ TH),  TV→ HMAC(K, "atvm-confirm-v2|tv" ‖ TH)
oturum kanıtı : P(K, kanal, rol, n_sunucu, n_istemci) = HMAC(K, "atvm-auth-v2|<kanal>|<rol>" ‖ n_sunucu ‖ n_istemci)
                kanal "ctl" (Mac→TV 7601, sunucu TV) / "rev" (TV→Mac 7610, sunucu Mac); rol kanıtı üreten taraf
session       : SHA-256("atvm-fp-v2" ‖ K) ilk 4 bayt, hex (anahtar baytı gösterilmez)
```

- **Neden bitler tek tek:** araya giren (Mac'e TV, TV'ye Mac gibi davranan) her turda biti, dürüst
  taraf açmadan önce kendi taahhüdüne bağlamak zorundadır; yanlış tahmin o turda reddedilir. PIN
  her denemede yeni olduğundan deneme başına başarı olasılığı en çok **10⁻⁶**'dır. Aynı sınır, ekranı
  görmeden TV ile doğrudan eşleşmeye çalışan biri için de geçerlidir (tek yönlü SAS bunu sağlamazdı:
  TV'nin ağdaki karşısı SAS'ı kendisi hesaplayabilir).
- **Pasif dinleyici:** taahhüt anahtarı `kc` ECDH'den türediği için açılan nonce'larla PIN bitlerini
  sınayamaz (standart Bluetooth'ta passkey sonradan açığa çıkar; burada çıkmaz). `K` da ECDH'ye dayanır.
- Mac onayını ancak kullanıcı kodu girip 20 tur tuttuktan sonra gönderir; TV anahtarı ancak bu onay
  doğrulanınca kaydeder, Mac de TV'nin onayı doğrulanınca.
- **Deneme sınırı (TV):** her deneme (`pair_init` alındıktan sonra başarısız biten: yanlış bit, kopma,
  zaman aşımı, `pair_abort`) kodu emekliye ayırır ve yenisini gösterir. 3 başarısız denemede 30 sn kilit;
  kilit her tekrarda iki katına çıkar (en çok 8 dk), başarılı eşleşmede sıfırlanır. Kilitliyken
  `denied/locked` + `retry_after_ms`.
- Yeniden bağlantı: TV `challenge{nonce_tv}`, Mac `proof{nonce_mac, P(K,"ctl","mac",…)}`, TV
  `ready{P(K,"ctl","tv",…)}` — iki taraf da anahtarı bildiğini kanıtlar. v1'de yalnız istemci kanıtlıyordu ve
  iki kanal aynı biçimi kullandığından TV'nin 7610 kanıtı 7601'e yansıtılabilirdi; kanal/rol etiketleri bunu önler.
- Karşılaştırmalar sabit zamanlı (`MessageDigest.isEqual`, Swift'te XOR birikimi).
- Ortak test vektörü (sabit özel anahtar/nonce/PIN → beklenen taahhüt, `K`, onay ve kanıtlar):
  `src/sender-macos/Tests/ATVMSenderTests/PairingTests.swift` ve `receiver/selfcheck/PairingSelfCheck.kt`;
  değerler CryptoKit'ten bağımsız saf tamsayı bir P-256 uygulamasıyla üretildi.
- Doğrulandı (2026-10-11, Mac ↔ Android TV, debug derlemesi): yanlış PIN ×3 → `pin_mismatch` ×3, sonra
  doğru PIN'le bile `locked` (29 sn); kilit sonrası eşleşme ve yayın; PIN'siz yeniden bağlantı aynı oturum
  parmak iziyle; günlükleyen vekilden geçen eşleşmede 6639 baytlık dökümde PIN dizisi 0 kez, 40 `pk_commit`
  ve 40 `pk_open`; v1 `hello` → `denied/version`; doğrulamasız `unpair`/`stop` → `denied/not_paired`;
  satır sonu olmayan 9000 bayt → bağlantı 0,04 sn'de kapandı; sessiz bağlantı 15,0 sn'de kapandı.

### 3.3 Anahtar saklama

- **Mac:** macOS Anahtar Zinciri, `kSecClassGenericPassword`, servis `dev.atvm.sender` (uygulama paketi
  kimliği), hesap = TV'nin IPv4 adresi, değer = 32 baytlık `K`. Erişim izni imzalayan kimliğe bağlıdır:
  aynı geliştirici kimliğiyle yeniden derlenen paket kaydı sormadan okur (başka yoldan ve farklı derlemeyle
  doğrulandı). İmzasız (ad-hoc) derlemede imza her derlemede değiştiği için macOS'un izin sormasını
  bekliyoruz (doğrulanmadı). Önceki sürümün
  `paired_keys.json` dosyası ilk erişimde Anahtar Zinciri'ne taşınır ve silinir; TV adları sır olmadığından
  `paired_names.json` dosyasında kalır.
- **TV:** uygulamaya özel dizinde `pair_key_v2.bin` (yalnız uygulamanın UID'si okur; `allowBackup="false"`,
  yedeğe ve buluta gitmez). Donanım anahtar deposu kullanılmıyor: kök yetkisi ya da fiziksel erişimi olan
  saldırgan okuyabilir (SECURITY.md). v1 anahtarı (`session_key.bin`) ilk açılışta silinir, çünkü düz metin
  giden PIN'den türüyordu; bu sürüme geçişte bir kez yeniden eşleşmek gerekir.
- Otomatik cihaz testi için yalnız **debug** derlemesi (`BuildConfig.DEBUG`) üretilen kodu logcat'e yazar
  (`ATVM-Pairing: DEBUG eşleştirme kodu`); release derlemesi kodu hiçbir yere yazmaz.

## 4. Medya: RTP + H.264

RTP başlığı 12 bayt: `V=2, P=0, X=0, CC=0`, `M`, `PT`, `seq (u16)`, `timestamp (u32, 90 kHz)`, `SSRC`.

- `PT=96` (dinamik, `start` ile bildirilir) → H.264.
- `SSRC`: yayıncının seçtiği 32-bit rastgele oturum kimliği. Alıcı eşleşmeyen SSRC'li paketleri atar.
  **Test modu:** `start.ssrc = 0` → alıcı ilk paketin SSRC'sine kilitlenir.
  Harici RTP üreticiler SSRC'yi her zaman bildirmediği için bu mod yalnız otomatik testte kullanılır (Doğrulandı).
- Payload: VideoToolbox çıktısı uzunluk-önekli (4 bayt BE) NAL birimleridir; yayıncı bunu **Annex-B**'ye çevirir
  (`00 00 00 01` start code) ve her keyframe öncesi SPS/PPS'i ekler.
  Doğrulandı: `selftest` çıktısı `00 00 00 01 27 42 c0 …` → ilk NAL tipi 7 (SPS), ardından 8 (PPS).
- Parçalama: tek NAL ≤ 1150 B ise doğrudan, değilse **FU-A** (type 28) parçaları; AU'nun son paketinde `M=1`.
- Boyut: `start.width/height` başlangıç çerçevesidir; pencerenin en-boy oranını korur (yatay profil kutusuna tek tip
  ölçekle sığar, 16'ya hizalı). Pencere yeniden boyutlanınca yayıncı oturumu ve SSRC'yi korur, kodlayıcıyı yeni
  boyutla yeniden kurar (yeni SPS/PPS + IDR). Alıcı gerçek boyutu çözücü çıktı biçiminden alır ve ekrana oranı
  bozmadan sığdırır (letterbox/pillarbox). Bu TV'nin çözücü tamponu ilk SPS'e göre ayrılıp büyümediği için resim
  bu boyutu aşarsa alıcı çözücüyü yeniden kurar ve IDR ister (Ölçüldü).
- Alıcı (RtpDepacketizer): tek-NAL / STAP-A / FU-A işler. Paketler önce sıralama/NACK tamponundan (§4.2) geçer;
  düzeltilemeyen kayıpta yarım AU atılır ve yalnız bir IDR AU'su çözücü kapısını yeniden açar.

### 4.1 Ses: RTP + PCM (PT=97)

Aynı UDP akışında ikinci bir yayın: `PT=97`, **ayrı SSRC**, 48 kHz saat, **L16** (RFC 3551: 16 bit işaretli,
ağ sırası = büyük uçlu), interleaved stereo. Paket **5 ms = 240 örnek/kanal**: 960 B yük + 12 B başlık = 972 B
(MTU altı, parçalanma yok), `M=1`. Alıcı yükü `AudioTrack`'e yazar; ardışık paketlerin zaman damgası farkı 240'tır
(kesinti olursa damga atlar, bkz. §5).

- Kaynak (yayıncı): **Core Audio süreç tap'i** (macOS 14.2+). Yakalanan uygulamanın tüm ses süreçleri
  (Chrome'da yardımcı süreç, Safari'de WebKit GPU servisi gibi) tek stereo karışım olarak alınır; aynı tap o süreçleri
  Mac'te de susturur (`mutedWhenTapped`, yayın bitince ya da yayıncı ölünce kalkar). Tap kurulamazsa yedek
  ScreenCaptureKit sesidir; yedek yolda **Mac'te susturma yoktur**. Ses uygulama düzeyindedir, sekme ayrımı yoktur.
- Dönüşüm: float32 → int16, kırpma + TPDF dither (tam sıfır girdi sıfır kalır).
- Ölçüldü (2026-10-11, yerel tap testi `atvm-sender audio-tap-test`, TV'ye gönderilmeden): 3,01 sn'de 601 paket
  (≈ 200/sn, ≈ 1,55 Mbps), tüm zaman damgası adımları 240.
- `start` mesajının ses alanları: `audio_ssrc`, `audio_payload_type`, `audio_sample_rate`, `audio_channels`.
  `audio_payload_type < 0` gelirse alıcı ses kanalını açmaz (geriye dönük uyumlu: eski yayıncı).

### 4.2 Video kaybı kurtarma: RTCP NACK ve yeniden gönderim

Wi-Fi'da görüntü paketleri kaybolur (ölçüldü: Mac Ethernet → AP → TV 5 GHz Wi-Fi, RTT ≈ 1,6 ms,
45 sn'lik yayında 12 seq boşluğu). Kayıp, ikinci bir yol açmadan aynı UDP soketiyle kurtarılır.
**Yalnız video** kapsamdadır; ses (PT=97) NACK'lanmaz (halka SSRC başına genel tutuldu, ses sonradan eklenebilir).

**Alıcı → yayıncı: Generic NACK** (RFC 4585 §6.2.1), bileşik olmayan tek RTCP paketi:

```
 0                   1                   2                   3
|V=2|P=0| FMT=1 |   PT=205    |          length (32 bit sözcük − 1)     |
|              gönderen SSRC (alıcının rastgele seçtiği)                |
|              medya SSRC (video SSRC'si)                               |
|              PID (16)         |          BLP (16)                     |   × N
```

- Soket: medya paketlerinin geldiği UDP soketi; hedef, **video paketlerinin kaynak adresi/portu**.
  Yayıncı aynı bağlı UDP akışından (`NWConnection`) okur.
- `PID` kayıp seq, `BLP` sonraki 16 seq için bit maskesi (bit0 = PID+1). 16 bit sarma doğru işlenir.
- Alıcı sıralama tamponu (`VideoReorderBuffer`): sıradaki paket doğrudan çözücü hattına gider
  (bekleme yok, kopya yok); ileri sıçrayan paket tampona alınır, aradaki seq'ler "eksik" sayılır.
  - 2 ms içinde gelirse sırası bozulmuş paket sayılır (NACK yok, `reordered`).
  - 2 ms sonra hâlâ yoksa NACK; 10 ms sonra hâlâ yoksa bir kez daha.
  - 30 ms içinde gelmezse **vazgeçilir**: o paketleri içeren erişim birimi (AU) atılır, kayıptan sonraki
    ilk AU de şüpheli sayılıp atılır (AU sınırı bilinemez), tamponda bekleyenler sırayla teslim edilir.
- **IDR kapısı:** vazgeçilince (ya da çözücü kurtarma / kuyruk birikintisi olunca) alıcı IDR'ye kadar
  çözücüye **hiçbir P AU'su vermez**; kapıyı yalnızca NAL tipi 5 içeren AU açar. IDR bekleyen alıcı
  `idr_request` yollar ve gelene dek 300 ms aralıkla tekrarlar. Birikinti (backpressure) isteği ayrı ve
  2 sn ile sınırlıdır; iki sınır ortak zaman damgası kullanmaz.
- Yeniden gönderilen paket orijinal baytlardır (aynı `seq`, `timestamp`, `SSRC`); alıcı `seq` ile tekilleştirir.

**Yayıncı:** SSRC başına son **2048** RTP paketi `seq`'e göre halkada tutulur (ilk iletim anında kaydedilir).
NACK gelince halkadaki paket aynen yollanır. Sınırlar: yeniden gönderim toplamı bit hızı referansının (§4.3) **%25**'iyle
(token-bucket, 0,2 sn patlama payı) ve aynı `seq` en erken 4 ms sonra tekrar. Halkada olmayan (eski/atılmış) seq
yok sayılır; alıcı 30 ms sonra vazgeçip IDR ister.

**İstatistik** (alıcı `ATVM-Stats`): `gap` = ilk iletimde kaybolup NACK'lanan paket, `nack` = gönderilen RTCP paketi,
`rtx` = NACK sonrası gelip boşluğu dolduran paket, `rtxLate` = vazgeçildikten sonra gelen paket,
`unrec` = vazgeçilen paket. Beklenen: `gap = rtx + unrec` (uçuşta olanlar hariç).
Yayıncı saniyelik satırı: `nackRx` (alınan NACK), `rtxTx` (yeniden gönderilen), `rtxSkip` (halkada yok / 4 ms kuralı / bütçe),
`injDrop` (sınama düşürmesi), `paceDrop` (pacer taşması).

**Bilinen sınır:** AU'nun *son* paketi kaybolursa alıcı bunu ancak sonraki paket gelince fark eder
(durağan ekranda bu, bir sonraki karedir); o zamana dek kare ekranda eski kalır.

### 4.3 Yayıncı pacing'i

Kodlayıcı bir AU'yu tek patlamada çıkarırdı (sınırsız gönderim kuyruğu, ses de aynı kuyrukta). Patlamanın AP
kuyruğunu zorlaması **varsayımdır, ölçülmedi**; pacing yalnız bu riski azaltmak için eklendi.
Şimdi video paketleri özel bir seri kuyrukta (`atvm.pacer`) token-bucket'tan geçer:

- hız = **2,5 × bit hızı referansı**, patlama ≤ **16 KB**. Referans = hedef bit hızı ile son ölçülen giriş hızının
  büyüğü (250 ms örnek, EWMA): kodlayıcı hedefi aştığında (ölçüldü: sentetik yüksek entropili içerik hedef 12 Mbps'e karşı
  ≈ 33 Mbps üretti) pacer darboğaz olup kare düşürmesin. İlk sürümde hız yalnız hedefe bağlıydı ve bu içerikte
  60 sn'de ≈ 13 bin paket (pacer taşması) atıldı; ölçülen hıza uyum bunu giderdi (`paceDrop=0`);
- ses paketleri pacer'ı **atlar** (video patlamasının arkasında beklemez);
- soket tarafında ağ yığınına verilmiş ama işlenmemiş bayt **64 KB** ile sınırlıdır (kuyruk sığ kalır, ses de bekleme görmez);
- pacer kuyruğu ≈ 150 ms'yi (hız × 0,15 sn, en az 64 KB) aşarsa **bütün en eski AU'lar** atılır (yalnız video), kodlayıcıdan
  kendine IDR istenir ve olay loglanır (`paceDrop`); aynı olay en çok 300 ms'de bir raporlanır.
- yeniden gönderimler pacer'a girmez (kendi %25 bütçesi vardır).

### 4.4 Sınama: kayıp enjeksiyonu

Yayıncıda `ATVM_DROP_VIDEO_PCT=<yüzde>` ortam değişkeni, **ilk iletimdeki** video paketlerinin o oranını yollamaz
(paket halkada tutulur, NACK ile kurtarılabilir). Yeniden gönderimler düşürülmez. Başlangıçta `SINAMA:` satırı yazılır.
Doğrulama: `scripts/test-receiver-reorder.sh` (alıcı mantığı, JVM), `swift test` (halka, NACK ayrıştırma, token-bucket, pacer kuyruğu).

### 4.5 Ölçümler (2026-10-11, Mac Ethernet → AP → TV 5 GHz Wi-Fi)

**Ölçüldü**, 1080p60 profili, sentetik kaynak (deterministik içerik, ≈ 33,7 Mbps), 60 sn/koşu. Gecikme = alıcının çözücü girişi → render
penceresi (§5), yani ağ gecikmesini içermez. `idr` toplam istek sayısıdır; bu içerikte tabanda da ≈ 19 (çözücü kuyruk
birikintisi, kayıpla ilgisiz).

| Koşu | gap | nack | rtx | unrec | idr | fps | p50 / p95 ms |
|---|---|---|---|---|---|---|---|
| eski kod (kurtarmasız), enjeksiyon yok | 110 (hepsi AU kaybı) | – | – | – | 20 | 57,1 | 34,2 / 65,1 |
| yeni kod, enjeksiyon yok | 0 | 0 | 0 | 0 | 19 | 57,6 | 33,8 / 64,7 |
| yeni kod, `ATVM_DROP_VIDEO_PCT=1` | 2180 | 2130 | 2180 | 0 | 19 | 55,4 | 33,5 / 64,8 |
| yeni kod, `ATVM_DROP_VIDEO_PCT=3` | 6464 | 5711 | 6464 | 0 | 18 | 55,7 | 33,7 / 63,9 |

- Eski kodda `gap` ham seq boşluğudur (her biri AU kaybı + IDR gereksinimi); yeni kodda ilk iletimde kaybolup NACK'lanan pakettir.
- Aynı oturumdaki temiz kontrolde (`gap=4 unrec=4`) 4 ardışık paket gerçek (enjekte edilmemiş) kayıp oldu ve
  yeniden gönderimleri 30 ms'den geç geldi; bu, vazgeçme yolunun gerçek ağda da çalıştığını gösterir.
- Aşırı kayıp (`ATVM_DROP_VIDEO_PCT=40`, 25 sn): çözücüye yalnızca 3 AU verildi (≈ 1500 kare üretildi); P kareleri
  IDR gelene dek tutuldu, `idr_request` 300 ms aralıkla gitti (82 istek). Yani bozuk kare beslenmedi.
- Gerçek pencere (QuickTime penceresi, 1080p60 profili): `=1` → gap 473, rtx 473, unrec 0, idr 1; `=3` → gap 150, rtx 150,
  unrec 0, idr 1; ses paketleri etkilenmedi (gönderilen 12187 / alınan 12076, alıcı satırı ~1 sn geriden okur).
  Bu koşularda içerik koşudan koşuya değişti (QuickTime penceresi bazen durağan), bu yüzden gecikme karşılaştırması yalnız sentetik tabloda yapıldı.
- Doğrulanamadı: gerçek içerikte kayıp-sonrası görüntünün gözle bozulmaması (`screencap` video katmanını yakalamaz); yerine sayaçlar
  (IDR istekleri yalnız `unrec` ile arttı, kapı dışı AU çözücüye gitmedi) kullanıldı.

## 5. Zamanlama ve gecikme

- Yayıncı RTP timestamp'i 90 kHz'de ortak köke (§5.1) göre `pts`'ten üretir; alıcı `releaseOutputBuffer(idx, true)` ile **anında render** eder
  (canlı yansıtmada kadre bekletme gecikmeyi artırır).
- Alıcı kuyruğu 3 AU ile sınırlıdır; dolarsa **en eski** düşürülür (`drop_q`), böylece birikinti oluşmaz.
- Gecikme ölçümü: AU'nun çözücüye veriliş anı bir FIFO'ya yazılır, render anında sırayla çıkarılır
  (B-frame olmadığı için sıra korunur). `presentationTimeUs` kullanILMAZ — bu çözücü onu yeniden
  tabanlıyor. `inflight = fed - rendered` gerçek birikintiyi verir.
- Ölçülen (2026-10-10, bu iki cihaz):
  - gerçek pencere 672x438@60: çözücü girişi → render **p50 3.3–4.0 ms, p95 4.3 ms**, birikinti 0–3 kare
  - sentetik 720p60 (yüksek entropi, 14 Mbps): **p50 23.0 ms, p95 31.3 ms**, birikinti 1–2 kare
- Bu sayılar TV panel/işleme gecikmesini ve SCK yakalama süresini içermez.

### 5.1 Ortak saat (A/V senkronu)

`start.sync = 1` ise iki akışın RTP zaman damgaları **aynı kök anına** bağlıdır. Kök, yayın başında Mac'in host
saatinde (mach absolute time; ScreenCaptureKit video PTS'i ve Core Audio `mHostTime` ile aynı eksen) seçilen bir
andır; TV'ye kendisi değil, o ana karşılık gelen iki taban bildirilir:

```
start: "sync": 1, "video_rtp_base": <u32>, "audio_rtp_base": <u32>

video_ts = video_rtp_base + round((pts_host_sn            - kök_sn) * 90000)   (mod 2^32)
audio_ts = audio_rtp_base + round((ilk_örnek_host_sn      - kök_sn) * 48000)   (mod 2^32)

=> (video_ts - video_rtp_base) / 90000  ==  (audio_ts - audio_rtp_base) / 48000   aynı anı gösterir
```

- Ses zaman damgası örnek sayacından türetilir (süreklilik); sayaçtan türeyen an ile cihazın bildirdiği host
  zamanı **20 ms'den fazla** ayrışırsa yayıncı host zamanına yeniden çapalar (damga atlar, yayıncı loglar).
  Alıcı bu atlamayı boşluk (ileri) ya da çakışma (geri) olarak ele almalıdır.
- Yedek ScreenCaptureKit ses yolunda aynı kural `CMSampleBuffer` PTS'i ile uygulanır.
- `sync` yoksa ya da `0` ise tabanlar anlamsızdır; eski alıcılar yeni alanları yok sayar (§7) ve akışlar
  eskisi gibi damga-bağımsız oynatılır.
- Alıcı (AvClock): `m` µs yerelde `m·1000 + P` ns'de çalınır/gösterilir; P = max(ses yolu, görüntü yolu), canlı
  ölçülür. Bu TV'de ses yolu (HAL ~110 ms) baskın olduğu için görüntü çözücü GİRİŞİNDE ~160 ms bekletilir
  (`releaseOutputBuffer(i, gelecek_ns)` bu çözücüde kare üretimini çökertti). Ölçüldü (2026-10-11, 40 sn, yazılım
  damgaları): avErr p50 ≈ −1 ms, |p95| 4–8 ms; cam→cam hizası insan kontrolü ister (ADR-006).

## 6. Hata davranışı

| Koşul | Davranış |
|---|---|
| TV çözücüyü kuramaz | `cap_error` + desteklenen sınırlar; Mac yayını başlatmaz |
| Kontrol kanalı kapanır | Alıcı yayını durdurur, `HAZIR` durumuna döner, dinlemeye devam eder |
| Video paketi kaybı, 30 ms içinde NACK ile kurtarılamadı | Etkilenen AU atılır, IDR gelene dek hiçbir P AU'su çözücüye verilmez, `idr_request` (300 ms aralıkla) |
| UDP sessizliği > 1.5 sn | Alıcı `soTimeout` ile hisseder; Mac `stop` göndermezse IDR isteği döngüsü boşa çıkar (M2: izleyici timeout) |
| PIN süresi doldu | TV yeni kod gösterir; eski kodla gelen `pair_init` → `denied/pin_expired` (başarısız sayılmaz) |
| Eşleştirme denemesi başarısız | Kod yenilenir; 3 başarısızlıkta 30 sn kilit (her tekrarda ×2, en çok 8 dk), `denied/locked` |
| Farklı protokol sürümü | Sunucu `denied{reason:"version", ver:2}` yazar ve kapatır; v1 TV'ye bağlanan v2 Mac, yanıtta `ver` olmadığından sürüm hatası verir |
| Surface yok edildi (TV uykusu) | Alıcı yayını durdurur (Doğrulandı: dreamx öne geçince loglandı) |

## 7. Sürüm politikası

`hello.ver = 2` (v2: passkey eşleştirmesi + karşılıklı oturum kanıtı). Geriye uyumsuz değişiklikte `ver` artar;
sunucu `denied{"reason":"version","ver":N}` döner, `hello` yanıtları `ver` taşır.
Alanda yeni özellik eklerken eski uçlar yok sayabilmeli (JSON, zorunlu alan yok).
