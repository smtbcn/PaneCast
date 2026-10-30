#include "KeyStore.h"

#include <windows.h>
#include <wincrypt.h>

#include <cstdio>
#include <fstream>
#include <sstream>
#include <vector>

#include "Json.h"
#include "Text.h"

namespace atvm {
namespace {

std::string Dir() {
    WCHAR buf[MAX_PATH + 1] = {};
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
    if (n == 0 || n > MAX_PATH) return {};
    std::wstring p(buf, n);
    p += L"\\PaneCast";
    CreateDirectoryW(p.c_str(), nullptr);
    return Narrow(p);
}

std::string StorePath() { return Dir() + "\\store.bin"; }
std::string NamesPath() { return Dir() + "\\paired_names.json"; }

std::string B64Url(const Bytes& raw) {
    std::string s = B64Encode(raw);
    for (char& c : s) {
        if (c == '+') c = '-';
        else if (c == '/') c = '_';
    }
    while (!s.empty() && s.back() == '=') s.pop_back();
    return s;
}

// store.bin düz metni: 1. satır device_id, sonra host<TAB>b64.
struct Store {
    std::string deviceId;
    std::map<std::string, std::string> keys;   // host -> b64
};

bool DecryptBlob(const Bytes& in, Bytes& out) {
    // DPAPI girdiye dokunmaz ama DATA_BLOB pbData'sı BYTE* ister (imza const değil).
    DATA_BLOB src{ (DWORD)in.size(), const_cast<BYTE*>(in.data()) };
    DATA_BLOB dst{ 0, nullptr };
    if (!CryptUnprotectData(&src, nullptr, nullptr, nullptr, nullptr, 0, &dst)) return false;
    out.assign(dst.pbData, dst.pbData + dst.cbData);
    LocalFree(dst.pbData);
    return true;
}

bool EncryptBlob(const Bytes& in, Bytes& out) {
    DATA_BLOB src{ (DWORD)in.size(), (BYTE*)in.data() };
    DATA_BLOB dst{ 0, nullptr };
    if (!CryptProtectData(&src, L"Pane Cast", nullptr, nullptr, nullptr, 0, &dst)) return false;
    out.assign(dst.pbData, dst.pbData + dst.cbData);
    LocalFree(dst.pbData);
    return true;
}

/// Mac'teki `.atomic` yazımın karşılığı: geçici dosyaya yaz, sonra yerine taşı. Yarım kalan
/// bir yazım anahtarı bozmasın (çökme/aniden çekilen disk).
bool WriteAtomic(const std::string& path, const Bytes& data) {
    const std::string tmp = path + ".tmp";
    {
        std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
        if (!f) return false;
        f.write((const char*)data.data(), (std::streamsize)data.size());
        f.flush();
        if (!f) return false;
    }
    return MoveFileExA(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING) != 0;
}

Store LoadStore() {
    Store st;
    std::ifstream f(StorePath(), std::ios::binary);
    if (!f) return st;
    Bytes enc((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    f.close();
    Bytes plain;
    if (!DecryptBlob(enc, plain)) return st;
    std::string text(plain.begin(), plain.end());
    std::istringstream is(text);
    std::string line;
    bool first = true;
    while (std::getline(is, line)) {
        while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) line.pop_back();
        if (first) { st.deviceId = line; first = false; continue; }
        const size_t tab = line.find('\t');
        if (tab != std::string::npos && tab > 0)
            st.keys[line.substr(0, tab)] = line.substr(tab + 1);
    }
    return st;
}

bool SaveStore(const Store& st) {
    std::string text = st.deviceId + "\n";
    for (const auto& kv : st.keys) text += kv.first + "\t" + kv.second + "\n";
    Bytes plain(text.begin(), text.end());
    Bytes enc;
    if (!EncryptBlob(plain, enc)) return false;
    return WriteAtomic(StorePath(), enc);
}

void WriteNames(const std::map<std::string, std::string>& names) {
    JsonObject o;
    for (const auto& kv : names) o.set(kv.first, kv.second);
    const std::string text = o.dump();
    WriteAtomic(NamesPath(), Bytes(text.begin(), text.end()));
}

std::string LegacyIdPath() { return Dir() + "\\device_id.txt"; }
std::string LegacyPairsDir() { return Dir() + "\\pairs"; }

std::string TrimTail(std::string s) {
    while (!s.empty() && (s.back() == '\r' || s.back() == '\n' || s.back() == ' ')) s.pop_back();
    return s;
}

/// `winPair` aracının düz dosyalarını (device_id.txt + pairs\<ip>.bin) depoya katlar.
/// Kimlik kazanma sırası: eski dosya, store.bin'den ÜSTÜN — TV'nin bildiği kimlik odur ve
/// taşınmazsa aynı bilgisayar ikinci bir kayıt gibi görünür, sınırlı yuvayı tüketir (§3.4).
/// Silme kuralı Mac'teki taşımayla aynı: hepsi yazılabildiyse düz dosyalar silinir, depo
/// yazılamadıysa yerinde kalır ve sonraki açılışta yeniden denenir.
std::string MigrateLegacyFiles() {
    Store st = LoadStore();
    bool touched = false;

    std::string legacyId;
    {
        std::ifstream idf(LegacyIdPath(), std::ios::binary);
        if (idf) std::getline(idf, legacyId);
    }
    legacyId = TrimTail(legacyId);
    if (legacyId.size() == 16 && st.deviceId != legacyId) { st.deviceId = legacyId; touched = true; }

    std::vector<std::string> moved;
    WIN32_FIND_DATAA fd;
    const HANDLE h = FindFirstFileA((LegacyPairsDir() + "\\*.bin").c_str(), &fd);
    if (h != INVALID_HANDLE_VALUE) {
        do {
            const std::string path = LegacyPairsDir() + "\\" + fd.cFileName;
            std::ifstream f(path, std::ios::binary);
            Bytes key((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
            if (key.size() != 32) continue;              // yarım/bozuk dosya: dokunma
            const std::string stem(fd.cFileName);
            const size_t dot = stem.rfind('.');
            st.keys[dot == std::string::npos ? stem : stem.substr(0, dot)] = B64Encode(key);
            touched = true;
            moved.push_back(path);
        } while (FindNextFileA(h, &fd));
        FindClose(h);
    }

    if (!touched) return {};
    if (!SaveStore(st)) return "DPAPI deposu yazılamadı; düz anahtar dosyaları korunuyor";
    for (const auto& p : moved) DeleteFileA(p.c_str());
    if (legacyId.size() == 16) DeleteFileA(LegacyIdPath().c_str());
    RemoveDirectoryA(LegacyPairsDir().c_str());          // boşsa düşer, doluysa dokunulmaz
    char note[80];
    snprintf(note, sizeof(note), "eski düz anahtarlar DPAPI deposuna taşındı (%d)", (int)moved.size());
    return note;
}

}  // namespace

std::string KeyStore::Prepare() {
    static const std::string note = MigrateLegacyFiles();
    return note;
}

std::string KeyStore::DeviceId() {
    (void)Prepare();
    Store st = LoadStore();
    if (st.deviceId.size() == 16) return st.deviceId;
    const std::string id = B64Url(RandomBytes(12));
    if (id.size() != 16) return {};
    st.deviceId = id;
    SaveStore(st);
    return id;
}

bool KeyStore::KeyFor(const std::string& host, Bytes& out32) {
    (void)Prepare();
    const Store st = LoadStore();
    auto it = st.keys.find(host);
    if (it == st.keys.end()) return false;
    const Bytes key = B64Decode(it->second);
    if (key.size() != 32) return false;
    out32 = key;
    return true;
}

bool KeyStore::IsPaired(const std::string& host) {
    (void)Prepare();
    const Store st = LoadStore();
    return st.keys.count(host) != 0;
}

std::vector<std::string> KeyStore::PairedHosts() {
    (void)Prepare();
    const Store st = LoadStore();
    std::vector<std::string> out;
    for (const auto& kv : st.keys)
        if (B64Decode(kv.second).size() == 32) out.push_back(kv.first);
    return out;
}

void KeyStore::StoreKey(const std::string& host, const Bytes& key32) {
    if (key32.size() != 32) return;
    (void)Prepare();
    Store st = LoadStore();
    st.keys[host] = B64Encode(key32);
    SaveStore(st);
}

void KeyStore::Remove(const std::string& host) {
    (void)Prepare();
    Store st = LoadStore();
    st.keys.erase(host);
    SaveStore(st);
    DropName(host);
}

void KeyStore::StoreName(const std::string& name, const std::string& host) {
    if (host.rfind("127.", 0) == 0) return;   // döngü içi test kaydı listeyi kirletmesin
    (void)Prepare();
    auto names = Names();
    if (names[host] == name) return;
    names[host] = name;
    WriteNames(names);
}

std::map<std::string, std::string> KeyStore::Names() {
    std::ifstream f(NamesPath(), std::ios::binary);
    if (!f) return {};
    std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    const auto parsed = ParseFlatJson(text);
    if (!parsed) return {};
    return parsed->strings;
}

void KeyStore::DropName(const std::string& host) {
    (void)Prepare();
    auto names = Names();
    if (names.erase(host) == 0) return;
    WriteNames(names);
}

}  // namespace atvm
