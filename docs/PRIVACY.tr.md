# Gizlilik politikası

> Türkçesi bu dosya; İngilizce aslı: [PRIVACY.md](PRIVACY.md)

**Kapsam:** Pane Cast Receiver (Android TV) ve Pane Cast Sender (macOS).
**Son güncelleme:** 2026-10-11

Pane Cast, kendi bilgisayarınızdaki bir pencereyi ya da ayrılmış bir ekranı yerel ağınız üzerinden
kendi TV'nize getirir. Bunu bizim hiçbir hizmetimiz olmadan yaptığı için, sizin hakkınızda bilebileceği
bir şey yoktur.

## Hiçbir veri toplamıyoruz

- Hesap yok, oturum açma yok, analitik yok, çökme bildirimi yok, reklam yok, izleme yok.
- Ne bize ne de herhangi bir üçüncü taraf sunucusuna veri gönderilir. İki uygulamanın hiçbirinde,
  kendi yerel ağınız dışını hedefleyen bir ağ istemcisi bulunmaz.
- Pane Cast'in bir arka uç servisi (backend) yoktur. Kaynak kodu açıktır ve denetlenebilir.

## Yerel ağınızda kalanlar

Yayını başlattığınızda yayıncı, UDP üzerinden TV'ye H.264 görüntü ve PCM ses akışı gönderir; iki cihaz
TCP üzerinden kontrol mesajları alışverişi yapar. Bu bağlantıdaki her şey yerel ağınızın (LAN) içinde kalır:

- **Ekran içeriği ve ses**: yayınlamayı seçtiğiniz her neyse onun görüntüsü ve sesi. Yerel ağ
  segmentinize ve medya portuna ulaşabilen biri bu trafiği izleyebilir; akış şifrelenmez. Yalnızca
  güvendiğiniz ağlarda yayın yapın.
- **Bir eşleştirme kodu**: TV ekranında gösterilir ve siz onu yayıncıya yazarsınız. O eşleştirmenin
  oturum anahtarını türetmek için kullanılır. Kodun kendisi sonrasında iki cihazda da saklanmaz;
  eşleştirme istediğiniz zaman TV'den (BACK tuşuna basılı tutarak) ya da yayıncıdan kaldırılabilir.
- **Cihaz adları ve adresleri** (mDNS hizmet keşfi, yerel ağ IP/portu, TV model adı) kendi cihazlarınızı
  bulmak ve onlara yeniden bağlanmak için kullanılır. Eşleştirme kaydı yayıncıda macOS'un şifreli
  Anahtar Zinciri'nde, TV'de uygulamanın kendi özel alanında tutulur — bulut hesabında değil — böylece
  kodu her seferinde yeniden girmeniz gerekmez. Eşleştirmeyi kaldırmak kaydı iki uçtan da siler.

Ağınızdan dışarı hiçbir şey çıkmaz: görüntü, ses, tanımlayıcı ve tanısal veri yok.

## Günlükler

macOS yayıncısı yerel bir günlük dosyası yazar (kendi oturum etkinliği ve penceresinde gösterdiği aynı
satırlar). Android TV alıcısı standart Android günlüklerini yazar. Günlükler cihazlarınızda kalır.
Yüklenmezler ve biz onları asla istemeyiz; bir hata bildirirseniz günlük göndermek tamamen sizin
tercihinizdir.

## Uygulamaların ihtiyaç duyduğu izinler ve nedenleri

- **Android TV alıcısı:** akışınızı alabilmek için `INTERNET` ve yerel ağ soket/çok noktalı yayın
  (multicast) izinleri; konum yok, kişiler yok, mikrofon yok, kamera yok, depolama izni yok, hesap yok.
- **macOS yayıncısı:** Ekran Kaydı (seçtiğiniz pencereyi ya da ekranı yakalamak için) ve Sistem Ses
  Kaydı (yayınladığınız uygulamaların sesini yakalamak için). İkisini de siz Sistem Ayarları'nda
  verirsiniz ve oradan istediğiniz zaman geri alabilirsiniz; uygulama bu izinler olmadan hiçbir şey
  yakalamaz.

## Çocuklar

Pane Cast, bir yetişkinin kendi cihazları için kullandığı bir araçtır ve kimsenin kişisel bilgisini toplamaz.

## Değişiklikler

Bu politika değişirse yeni sürüm bu depoda yayımlanır ve yukarıdaki tarih güncellenir.

## Kaynak

Yukarıdakilerin tümünü uygulayan kod açık kaynaklıdır; depo bağlantısı `README.md` dosyasındadır.
