// PaneCast — Windows yayıncısı: TV ile eşleşme/yeniden bağlanma aracı (görev #7'nin tel testi).
//
// Bu araç iki şeyi gerçekten ölçülebilir kılar:
//  1) Windows'un CNG eşleştirmesi TV'nin 20 turlu passkey akışını TEL ÜZERİNDE tamamlayabiliyor mu
//     (vektör testi bunu bellekte kanıtlamıştı; sıra cihazda).
//  2) Aynı TV ikinci bilgisayarı eşleşmişken birincisini koruyor mu (docs/protocol.md §3.3).
//
// Kullanım: winPair <TV_IP> [PIN | --pin-file <yol>]
//   PIN verilmezse kayıtlı anahtarla yeniden bağlanır; --pin-file başsız QA içindir:
//   kod TV ekranından okunup dosyaya yazılır, araç aynı bağlantıda bekler (gelecek
//   arayüzde bu bir giriş kutusu; CLI'da etkileşimli stdin yok, ölçüldü).
// Konsola yalnız ASCII etiket basılır: uzak kabukta kod sayfası Türkçeyi bozuyor (ölçüldü).
// Anahtar ve kimlik KeyStore'da (DPAPI, kullanıcı+makine kapsamı); aracın eski düz dosyaları
// ilk erişimde oraya taşınır — kimlik TEK kalmalı, yoksa TV aynı bilgisayarı iki kayıt sayar.
#include "../src/ControlClient.h"
#include "../src/Crypto.h"
#include "../src/Host.h"
#include "../src/Json.h"
#include "../src/KeyStore.h"
#include "../src/Pairing.h"

#include <windows.h>
#include <cstdio>
#include <string>

using namespace atvm;

namespace {

/// Kodun ömrü TV'de 180 s; burada 150 s beklenir ki süre dolmadan hata dönsün.
/// Okuma CreateFile ile TAM paylaşımlı açılır: C++ ifstream'in varsayılan paylaşımı
/// yazmayı reddediyor ve dışarıdan kod yazılamıyordu (ölçüldü: Set-Content ihlali).
bool waitForPinFile(const std::string& path, std::string& pin) {
    for (int i = 0; i < 150; ++i) {
        HANDLE h = ::CreateFileA(path.c_str(), GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h != INVALID_HANDLE_VALUE) {
            char buf[64] = {};
            DWORD n = 0;
            if (ReadFile(h, buf, sizeof(buf) - 1, &n, nullptr) && n > 0) {
                std::string line(buf, n);
                while (!line.empty() && (line.back() == '\r' || line.back() == '\n' ||
                                         line.back() == ' ')) line.pop_back();
                if (line.size() == 6) { pin = line; CloseHandle(h); return true; }
            }
            CloseHandle(h);
        }
        Sleep(1000);
    }
    return false;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        printf("usage: winPair <TV_IP> [PIN]\n");
        return 2;
    }
    const std::string ip = argv[1];
    const std::string pin = argc > 2 ? argv[2] : "";
    const std::string note = KeyStore::Prepare();
    if (!note.empty()) printf("MIGRATED=%s\n", note.c_str());
    const std::string id = KeyStore::DeviceId();
    const std::string name = HostName();
    printf("DEVICE_ID=%s len=%zu NAME=%s\n", id.c_str(), id.size(), name.c_str());

    ControlClient c;
    if (!c.connect(ip, 7601)) { printf("FAIL=connect %s:7601\n", ip.c_str()); return 1; }

    FlatJson reply;
    std::string err;
    const auto greet = c.hello(name, id, &reply, &err);
    printf("HELLO=%s\n", greet == ControlClient::Greet::Challenged ? "challenge"
           : greet == ControlClient::Greet::NeedPin ? "pair_required" : "failed");

    if (greet == ControlClient::Greet::Challenged) {
        Bytes key;
        if (!KeyStore::KeyFor(ip, key)) { printf("FAIL=no_stored_key\n"); return 1; }
        if (!c.authenticate(key, reply, &err)) { printf("FAIL=reconnect %s\n", err.c_str()); return 1; }
        printf("RECONNECTED=ok SESSION=%s\n", c.session().c_str());
        return 0;
    }

    if (greet == ControlClient::Greet::NeedPin) {
        std::string code = pin;
        if (code == "--pin-file") {
            if (argc < 4) { printf("FAIL=pin_file_path_missing\n"); return 2; }
            printf("WAITING_PIN_FILE=%s\n", argv[3]);
            if (!waitForPinFile(argv[3], code)) { printf("FAIL=pin_timeout\n"); return 1; }
            printf("PIN_READ=1\n");
        }
        if (code.empty()) { printf("NEED_PIN=1\n"); return 3; }
        auto k = c.pairWithPin(code, &err);
        if (!k) { printf("FAIL=pair %s\n", err.c_str()); return 1; }
        KeyStore::StoreKey(ip, *k);
        if (!KeyStore::IsPaired(ip)) { printf("FAIL=save_key\n"); return 1; }
        printf("PAIRED=ok FINGERPRINT=%s\n", Fingerprint(*k).c_str());
        return 0;
    }

    printf("FAIL=hello %s\n", err.c_str());
    return 1;
}
