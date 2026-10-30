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
// Anahtar deposu şimdilik bilinçli olarak düz dosya; arayüz ve sürüm damgası gelirken
// Credential Locker / CNG korumalı depolamaya geçilecek (AGENTS.md "Windows yayıncı").
#include "../src/ControlClient.h"
#include "../src/Pairing.h"
#include "../src/Crypto.h"
#include "../src/Json.h"

#include <windows.h>
#include <cstdio>
#include <fstream>
#include <string>

using namespace atvm;

namespace {

std::string root() {
    char buf[MAX_PATH] = {};
    DWORD n = GetEnvironmentVariableA("LOCALAPPDATA", buf, sizeof(buf));
    if (n == 0 || n >= sizeof(buf)) return ".\\pane-pairs";
    return std::string(buf) + "\\PaneCast";
}

std::string join(const std::string& dir, const std::string& file) { return dir + "\\" + file; }

void makeDirs(const std::string& path) {
    std::string acc;
    for (size_t i = 0; i < path.size(); ++i) {
        acc.push_back(path[i]);
        if (path[i] == '\\' && acc.size() > 3) CreateDirectoryA(acc.c_str(), nullptr);
    }
    CreateDirectoryA(path.c_str(), nullptr);
}

/// §3.4: 12 rastgele bayt, padding'siz base64url; kurulumda bir kez üretilir ve saklanır.
std::string deviceId() {
    static std::string cached;
    if (!cached.empty()) return cached;
    const std::string p = join(root(), "device_id.txt");
    std::ifstream in(p, std::ios::binary);
    if (in) std::getline(in, cached);
    if (cached.size() != 16) {
        cached = B64Encode(RandomBytes(12));
        if (cached.size() != 16) return {};
        makeDirs(root());
        std::ofstream out(p, std::ios::binary | std::ios::trunc);
        out << cached;
    }
    return cached;
}

std::string keyPath(const std::string& ip) { return join(join(root(), "pairs"), ip + ".bin"); }

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

bool loadKey(const std::string& ip, Bytes& out) {
    std::ifstream in(keyPath(ip), std::ios::binary);
    if (!in) return false;
    out.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
    return out.size() == 32;
}

bool saveKey(const std::string& ip, const Bytes& key) {
    makeDirs(join(root(), "pairs"));
    std::ofstream out(keyPath(ip), std::ios::binary | std::ios::trunc);
    out.write(reinterpret_cast<const char*>(key.data()), static_cast<std::streamsize>(key.size()));
    return out.good();
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        printf("usage: winPair <TV_IP> [PIN]\n");
        return 2;
    }
    const std::string ip = argv[1];
    const std::string pin = argc > 2 ? argv[2] : "";
    const std::string id = deviceId();
    printf("DEVICE_ID=%s len=%zu\n", id.c_str(), id.size());

    ControlClient c;
    if (!c.connect(ip, 7601)) { printf("FAIL=connect %s:7601\n", ip.c_str()); return 1; }

    FlatJson reply;
    std::string err;
    const auto greet = c.hello("pane-win", id, &reply, &err);
    printf("HELLO=%s\n", greet == ControlClient::Greet::Challenged ? "challenge"
           : greet == ControlClient::Greet::NeedPin ? "pair_required" : "failed");

    if (greet == ControlClient::Greet::Challenged) {
        Bytes key;
        if (!loadKey(ip, key)) { printf("FAIL=no_stored_key\n"); return 1; }
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
        if (!saveKey(ip, *k)) { printf("FAIL=save_key\n"); return 1; }
        printf("PAIRED=ok FINGERPRINT=%s\n", Fingerprint(*k).c_str());
        return 0;
    }

    printf("FAIL=hello %s\n", err.c_str());
    return 1;
}
