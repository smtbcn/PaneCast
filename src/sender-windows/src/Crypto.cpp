#include "Crypto.h"

#include <windows.h>
#include <bcrypt.h>
#include <wincrypt.h>
#include <cstring>
#include <memory>

#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "crypt32.lib")

#ifndef NT_SUCCESS
#define NT_SUCCESS(st) (((NTSTATUS)(st)) >= 0)
#endif

namespace atvm {
namespace {

/// Tek seferlik özet/HMAC: BCryptHash (bu SDK'da `BCryptComputeHash` yok — derleyici ölçümü).
Bytes Digest(const wchar_t* algorithm, bool hmac, const Bytes& key, const Bytes& data) {
    BCRYPT_ALG_HANDLE alg = nullptr;
    ULONG flags = hmac ? BCRYPT_ALG_HANDLE_HMAC_FLAG : 0;
    if (!NT_SUCCESS(BCryptOpenAlgorithmProvider(&alg, algorithm, nullptr, flags))) return {};
    Bytes out(32);
    ULONG written = 0;
    const NTSTATUS st = BCryptHash(alg, key.empty() ? nullptr : (PUCHAR)key.data(),
                                   (ULONG)key.size(), (PUCHAR)data.data(), (ULONG)data.size(),
                                   out.data(), (ULONG)out.size());
    BCryptCloseAlgorithmProvider(alg, 0);
    if (!NT_SUCCESS(st)) return {};
    (void)written;
    return out;
}

Bytes Concat(const std::vector<Bytes>& parts) {
    Bytes out;
    size_t n = 0;
    for (const Bytes& p : parts) n += p.size();
    out.reserve(n);
    for (const Bytes& p : parts) out.insert(out.end(), p.begin(), p.end());
    return out;
}

struct AlgHandle {
    BCRYPT_ALG_HANDLE h = nullptr;
    ~AlgHandle() { if (h) BCryptCloseAlgorithmProvider(h, 0); }
};

struct KeyHandle {
    BCRYPT_KEY_HANDLE h = nullptr;
    ~KeyHandle() { if (h) BCryptDestroyKey(h); }
};

}  // namespace

Bytes Sha256(const std::vector<Bytes>& parts) {
    return Digest(BCRYPT_SHA256_ALGORITHM, false, {}, Concat(parts));
}

Bytes HmacSha256(const Bytes& key, const std::vector<Bytes>& parts) {
    return Digest(BCRYPT_SHA256_ALGORITHM, true, key, Concat(parts));
}

/// RFC 5869, L = 32 bayt (tek blok) — §3.2'nin iki HKDF adımı da 32 bayt ister.
Bytes HkdfSha256(const Bytes& ikm, const Bytes& salt, const std::string& info) {
    const Bytes prk = HmacSha256(salt, {ikm});
    if (prk.empty()) return {};
    Bytes label = Concat({Bytes(info.begin(), info.end()), Bytes{0x01}});
    return HmacSha256(prk, {label});
}

Bytes RandomBytes(size_t n) {
    Bytes out(n);
    if (n == 0) return out;
    if (!NT_SUCCESS(BCryptGenRandom(nullptr, out.data(), (ULONG)n,
                                    BCRYPT_USE_SYSTEM_PREFERRED_RNG)))
        return {};
    return out;
}

Bytes B64Decode(const std::string& text) {
    DWORD len = 0;
    if (!CryptStringToBinaryA(text.c_str(), (DWORD)text.size(), CRYPT_STRING_BASE64, nullptr,
                              &len, nullptr, nullptr))
        return {};
    Bytes out(len);
    if (!CryptStringToBinaryA(text.c_str(), (DWORD)text.size(), CRYPT_STRING_BASE64, out.data(),
                              &len, nullptr, nullptr))
        return {};
    out.resize(len);
    return out;
}

std::string B64Encode(const Bytes& data) {
    DWORD len = 0;
    if (!CryptBinaryToStringA(data.data(), (DWORD)data.size(),
                              CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr, &len))
        return {};
    std::string out(len, '\0');
    if (!CryptBinaryToStringA(data.data(), (DWORD)data.size(),
                              CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, out.data(), &len))
        return {};
    while (!out.empty() && (out.back() == '\0' || out.back() == '\r' || out.back() == '\n'))
        out.pop_back();
    return out;
}

Bytes HexToBytes(const std::string& hex) {
    Bytes out;
    for (size_t i = 0; i + 1 < hex.size(); i += 2)
        out.push_back((uint8_t)std::strtoul(hex.substr(i, 2).c_str(), nullptr, 16));
    return out;
}

std::string BytesToHex(const Bytes& data) {
    static const char* d = "0123456789abcdef";
    std::string out;
    out.reserve(data.size() * 2);
    for (uint8_t b : data) { out.push_back(d[b >> 4]); out.push_back(d[b & 15]); }
    return out;
}

bool ConstantTimeEqual(const Bytes& a, const Bytes& b) {
    if (a.size() != b.size()) return false;
    uint8_t diff = 0;
    for (size_t i = 0; i < a.size(); ++i) diff |= (uint8_t)(a[i] ^ b[i]);
    return diff == 0;
}

// ---- EcdhKey -------------------------------------------------------------------

namespace {
constexpr ULONG kP256Bytes = 32;

struct PublicBlob {                 // BCRYPT_ECCPUBLIC_BLOB: başlık + X + Y
    BCRYPT_ECCKEY_BLOB hdr;
    uint8_t xy[2 * kP256Bytes];
};
struct PrivateBlob {                // BCRYPT_ECCPRIVATE_BLOB: başlık + X + Y + d
    BCRYPT_ECCKEY_BLOB hdr;
    uint8_t xy[2 * kP256Bytes];
    uint8_t d[kP256Bytes];
};
}  // namespace

EcdhKey::EcdhKey() {
    BCryptOpenAlgorithmProvider((BCRYPT_ALG_HANDLE*)&alg_, BCRYPT_ECDH_P256_ALGORITHM, nullptr, 0);
}

EcdhKey::~EcdhKey() { clear(); }

EcdhKey::EcdhKey(EcdhKey&& other) noexcept
    : alg_(other.alg_), private_(other.private_), publicPoint_(std::move(other.publicPoint_)) {
    other.alg_ = nullptr;
    other.private_ = nullptr;
}

EcdhKey& EcdhKey::operator=(EcdhKey&& other) noexcept {
    if (this != &other) {
        clear();
        alg_ = other.alg_; private_ = other.private_; publicPoint_ = std::move(other.publicPoint_);
        other.alg_ = nullptr; other.private_ = nullptr;
    }
    return *this;
}

void EcdhKey::clear() {
    if (private_) BCryptDestroyKey((BCRYPT_KEY_HANDLE)private_);
    if (alg_) BCryptCloseAlgorithmProvider((BCRYPT_ALG_HANDLE)alg_, 0);
    private_ = nullptr; alg_ = nullptr; publicPoint_.clear();
}

EcdhKey EcdhKey::Generate() {
    EcdhKey k;
    BCRYPT_KEY_HANDLE h = nullptr;
    if (!k.algOk() ||
        !NT_SUCCESS(BCryptGenerateKeyPair((BCRYPT_ALG_HANDLE)k.alg_, &h, 256, 0)) ||
        !NT_SUCCESS(BCryptFinalizeKeyPair(h, 0)))
        return EcdhKey();
    k.private_ = h;
    k.publicPoint_ = k.publicX963();
    return k;
}

bool EcdhKey::FromPrivate(const Bytes& scalar, const Bytes& publicX963, EcdhKey& out) {
    if (scalar.size() != kP256Bytes || publicX963.size() != 1 + 2 * kP256Bytes ||
        publicX963[0] != 0x04)
        return false;
    out = EcdhKey();
    if (!out.algOk()) return false;
    PrivateBlob pb = {};
    pb.hdr.dwMagic = BCRYPT_ECDH_PRIVATE_P256_MAGIC;
    pb.hdr.cbKey = kP256Bytes;
    memcpy(pb.xy, publicX963.data() + 1, 2 * kP256Bytes);
    memcpy(pb.d, scalar.data(), kP256Bytes);
    BCRYPT_KEY_HANDLE h = nullptr;
    if (!NT_SUCCESS(BCryptImportKeyPair((BCRYPT_ALG_HANDLE)out.alg_, nullptr,
                                        BCRYPT_ECCPRIVATE_BLOB, &h, (PUCHAR)&pb, sizeof(pb), 0)))
        return false;
    out.private_ = h;
    out.publicPoint_ = out.publicX963();
    return !out.publicPoint_.empty();
}

Bytes EcdhKey::publicX963() const {
    if (!private_) return {};
    PublicBlob out = {};
    ULONG written = 0;
    if (!NT_SUCCESS(BCryptExportKey((BCRYPT_KEY_HANDLE)private_, nullptr, BCRYPT_ECCPUBLIC_BLOB,
                                    (PUCHAR)&out, sizeof(out), &written, 0)) ||
        written != sizeof(out) || out.hdr.cbKey != kP256Bytes)
        return {};
    Bytes x963;
    x963.push_back(0x04);
    x963.insert(x963.end(), out.xy, out.xy + 2 * kP256Bytes);
    return x963;
}

bool EcdhKey::SecretWith(const Bytes& peerPublicX963, Bytes& out) const {
    // §3.2: kendi anahtarının yansıtılması reddedilir.
    if (!private_ || peerPublicX963.size() != 1 + 2 * kP256Bytes || peerPublicX963[0] != 0x04 ||
        peerPublicX963 == publicPoint_)
        return false;

    PublicBlob peer = {};
    // Eğri dışı nokta: içeri alım başarısız olmalı (ölçülecek — tools/cryptoProbe.cpp'de denenmedi).
    peer.hdr.dwMagic = BCRYPT_ECDH_PUBLIC_P256_MAGIC;
    peer.hdr.cbKey = kP256Bytes;
    memcpy(peer.xy, peerPublicX963.data() + 1, 2 * kP256Bytes);

    BCRYPT_KEY_HANDLE hPeer = nullptr;
    if (!NT_SUCCESS(BCryptImportKeyPair((BCRYPT_ALG_HANDLE)alg_, nullptr, BCRYPT_ECCPUBLIC_BLOB,
                                        &hPeer, (PUCHAR)&peer, sizeof(peer), 0)))
        return false;

    BCRYPT_HANDLE agree = nullptr;
    const bool ok = NT_SUCCESS(BCryptSecretAgreement((BCRYPT_KEY_HANDLE)private_, hPeer, &agree, 0));
    BCryptDestroyKey(hPeer);
    if (!ok) return false;

    uint8_t raw[64] = {};
    ULONG cb = 0;
    const NTSTATUS st = BCryptDeriveKey(agree, BCRYPT_KDF_RAW_SECRET, nullptr, raw, sizeof(raw),
                                        &cb, 0);
    BCryptDestroyKey((BCRYPT_KEY_HANDLE)agree);   // BCryptDestroySecret, bcrypt.h'ta bunun takma adı
    if (!NT_SUCCESS(st) || cb != kP256Bytes) return false;

    // Ölçülen tuzak: CNG küçük-endian veriyor; protokol büyük-endian x koordinatı bekliyor.
    out.assign(cb, 0);
    for (ULONG i = 0; i < cb; ++i) out[i] = raw[cb - 1 - i];
    return true;
}

}  // namespace atvm
