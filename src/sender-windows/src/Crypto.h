// PaneCast — Windows yayıncısı: kripto yardımçıları (yalnız işletim sistemi API'si)
// docs/protocol.md §3.2 bayt düzeni; macOS CryptoKit ve Android javax.crypto ile birebir aynı.
//
// ADR-001 gereği üçüncü taraf kripto yok: CNG (bcrypt.dll) + crypt32 (base64).
// Ölçülen iki tuzak burada yutuluyor (bkz. tools/cryptoProbe.cpp, 30.10.2026):
//  - BCRYPT_KDF_RAW_SECRET küçük-endian dönüyor → büyük-endian x koordinatına çevrilir.
//  - BCryptDeriveKey + BCRYPT_KDF_HKDF, paylaşılan sır tutamacıyla 0xC000000D veriyor →
//    HKDF-SHA256 (RFC 5869, L=32) HMAC üstünde elle kurulur; vektör kc ile doğrulandı.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace atvm {

using Bytes = std::vector<uint8_t>;

/// SHA-256, birdçok parçanın birleşimi üzerinden (Swift tarafındaki `sha256(_ parts: Data...)` aynısı).
Bytes Sha256(const std::vector<Bytes>& parts);
Bytes HmacSha256(const Bytes& key, const std::vector<Bytes>& parts);
Bytes HkdfSha256(const Bytes& ikm, const Bytes& salt, const std::string& info);

/// OS CSPRNG (BCryptGenRandom). §3.2'nin geçici nonce'ları ve `device_id` buradan gelir.
Bytes RandomBytes(size_t n);

Bytes B64Decode(const std::string& text);
std::string B64Encode(const Bytes& data);

Bytes HexToBytes(const std::string& hex);
std::string BytesToHex(const Bytes& data);

/// P-256 (secp256r1) ECDH anahtarı. X9.63 açık anahtar biçimi: 0x04 || X || Y (65 bayt).
class EcdhKey {
public:
    EcdhKey();
    ~EcdhKey();
    EcdhKey(EcdhKey&& other) noexcept;
    EcdhKey& operator=(EcdhKey&& other) noexcept;
    EcdhKey(const EcdhKey&) = delete;
    EcdhKey& operator=(const EcdhKey&) = delete;

    /// Yeni geçici anahtar çifti (her eşleştirme denemesinde bir tane, §3.2).
    static EcdhKey Generate();
    /// Sabit skalar + noktayı içeri alır (yalnız test vektörleri için; runtime kullanmaz).
    static bool FromPrivate(const Bytes& scalar, const Bytes& publicX963, EcdhKey& out);

    /// Algoritma tutamacı açıldı mı (anahtar içeri/ücrete alma ön koşulu).
    bool algOk() const { return alg_ != nullptr; }
    /// Elinizde gerçek bir özel anahtar tutamacı var mı.
    bool valid() const { return private_ != nullptr; }
    Bytes publicX963() const;

    /// Karaf tarafın X9.63 anahtarıyla ortak sırrı üretir. Eğri dışı nokta ve kendi
    /// anahtarının yansıtılması reddedilir (§3.2). Dönen baytlar büyük-endian x koordinatıdır.
    bool SecretWith(const Bytes& peerPublicX963, Bytes& out) const;

private:
    void clear();
    void* alg_ = nullptr;        // BCRYPT_ALG_HANDLE (ECDH_P256)
    void* private_ = nullptr;    // BCRYPT_KEY_HANDLE
    Bytes publicPoint_;          // 0x04||X||Y, export'tan okundu
};

/// Sabit zamanlı karşılaştırma (Swift `equal`, Kotlin `MessageDigest.isEqual` karşılığı).
bool ConstantTimeEqual(const Bytes& a, const Bytes& b);

/// §3.2 sabitleri: rol/karakter etiketleri ve tur sayıları.
struct PairingConst {
    static constexpr int kVersion = 2;
    static constexpr int kRounds = 20;
    static constexpr int kNonceBytes = 16;
    static constexpr uint8_t kTagMac = 0x4D;   // "M"
    static constexpr uint8_t kTagTv = 0x54;    // "T"
};

}  // namespace atvm
