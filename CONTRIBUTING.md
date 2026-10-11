# PaneCast — katkı rehberi

Kullanıcı belgeleri: [README.md](README.md) (English) · [README.tr.md](README.tr.md). Yayın süreci: [docs/RELEASING.md](docs/RELEASING.md).

## Ne arıyoruz
Düşük gecikme, az bağımlılık, gerçek cihazda doğrulanmış davranış. Özellik çoğaltma
değil; ölçülmüş iyileştirme.

## Zorunlu kurallar
1. **Lisans:** GPL/AGPL kod derlemeye giremez. Depoda yalnızca kendi yazdığımız kod
   vardır; üçüncü bir projeden satır alınırsa telif bildirimi o anda eklenir.
2. **Yayın temizliği:** Depoda başka bir uygulamanın/projenin adı ve kişisel ya da
   cihaz/ağ kimliği geçmez. Denetim her commit ve push'ta çalışır:
3. **Kanıt etiketi:** Her sayının kaynağı belirtilir — **Ölçüldü / Beyan (cihaz XML'i) /
   Hedef / Doğrulanamadı / Engellendi**. Çalıştırmadığın kodu "çalışıyor" yazma.
4. **Desteklenmeyeni desteklenmiş gösterme** (küçültülmüş pencere, Space, Windows tarafı).
5. **Bağımlılık:** Alıcı AndroidX'siz/framework-only kalmalı (32-bit, ~400 MB kullanılabilir
   RAM hedefi). Yeni bağımlılık gerekçelendirilmeli.
6. **Kaynak temizliği:** `stopCapture → VTCompressionSessionInvalidate → soket/mDNS kapatma`
   yolu her zaman çalışmalı.

## Derleme ve test sırası
```bash
./scripts/mac-encoder-probe.sh                 # kodlayıcı taban ölçümü (izin gerektirmez)
cd receiver && gradle assembleDebug               # GRADLE_USER_HOME ile önbellek yolu seçilebilir
./scripts/build-sender-app.sh debug            # → artifacts/build/PaneCast.app
./scripts/test-tv-initiated.py 6   # TV'nin yayını başlatma yönünü uçtan uca doğrula
<sender> selftest                              # Annex-B dönüşümü
<sender> mirror --tv <ip> --source synthetic   # izin gerektirmeden uçtan uca hat
<sender> mirror --tv <ip> --window <id>        # gerçek pencere (Ekran Kaydı izni gerekir)
```
CI (`.github/workflows/ci.yml`): alıcı derlemesi + `scripts/test-receiver-reorder.sh`, yayıncı `swift build` + `swift test`.
Gerçek TV gerektiren testler CI'da koşmaz ve "doğrulandı" sayılmaz.
`<sender>`: `artifacts/build/PaneCast.app/Contents/MacOS/PaneCast`.

## Commit
Küçük, tek konu, gerekçe içeren mesaj. Bu depo kendi yerel git kimliğini kullanır
(`git config --local user.email`; değer bilerek burada yazılmaz) ve makine genelindeki
hook kapısı `core.hooksPath` ile yalnız bu depo için devre dışıdır.

## Kılavuz
Tek yayınlanan tasarım belgesi: `docs/protocol.md` (tel taşımaya ait her şey orada).
Mimari/analiz/ölçüm notlarımız yayında değil; kod yorumları ve bu dosya yeterli.
