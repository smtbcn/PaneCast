// PaneCast — Windows yayıncısı: eşleştirme v2 (§3.2) başlatıcı tarafı.
// Bayt düzeni macOS (Pairing.swift) ve Android (PasskeyPairing.kt) ile birebir aynı olmalı;
// tools/pairingVectors.cpp deposundaki sabit vektörlerle bayt-bayt sınanır.
//
// Ağdan bağımsızdır: mesajları `Msg` haritası olarak alır, göndereceklerini döner —
// JSON-lines katmanı (modül 2) bu arayüzün üstüne oturur.
#pragma once

#include "Crypto.h"

#include <functional>
#include <map>
#include <string>

namespace atvm {

/// Bir kontrol mesajı: `t` türü, metin alanları (base64 dahil) ve sayı alanları.
struct Msg {
    std::map<std::string, std::string> text;
    std::map<std::string, long long> number;

    Msg() = default;
    Msg(const std::string& type) { text["t"] = type; }
    const std::string& type() const {
        static const std::string kEmpty;
        auto it = text.find("t");
        return it == text.end() ? kEmpty : it->second;
    }
    std::string str(const std::string& k) const {
        auto it = text.find(k);
        return it == text.end() ? std::string() : it->second;
    }
    long long num(const std::string& k, long long def) const {
        auto it = number.find(k);
        return it == number.end() ? def : it->second;
    }
};

enum class Role { Mac, Tv };
enum class Channel { Control, Reverse };          // "ctl" (yayıncı→TV 7601), "rev" (TV→yayıncı 7610)

uint8_t RoleChar(Role r);                          // 'M' / 'T'
const char* RoleName(Role r);                      // "mac" / "tv"  (protokol sabitidir, §3.2)
const char* ChannelName(Channel c);                // "ctl" / "rev"

/// §3.2 yardımcıları.
Bytes Th0(const Bytes& pkSelf, const Bytes& pkPeer);
Bytes CommitKey(const Bytes& dh, const Bytes& th0);
Bytes Commitment(const Bytes& kc, Role role, int round, uint8_t bit, const Bytes& nonce);
Bytes PairingKey(const Bytes& dh, const Bytes& th);
Bytes Confirm(const Bytes& key, Role role, const Bytes& th);
Bytes SessionProof(const Bytes& key, Channel channel, Role role, const Bytes& serverNonce,
                   const Bytes& clientNonce);
std::string Fingerprint(const Bytes& key);
uint8_t PasskeyBit(uint32_t passkey, int i);
bool PasskeyFromText(const std::string& text, uint32_t& out);

/// Başlatıcı (yayıncı) durum makinesi — Pairing.swift:PasskeyInitiator'ın birebir karşılığı.
class PasskeyInitiator {
public:
    enum class Error { None, PinRejected, Locked, Denied, BadPeerKey, PeerProofInvalid,
                       Unexpected };
    struct Failure {
        Error kind = Error::None;
        std::string reason;
        long long retryAfterMs = 0;
    };

    /// `nonce` sabit verilebilir (vektör testi) yoksa OS CSPRNG'den üretilir.
    explicit PasskeyInitiator(uint32_t passkey, std::function<Bytes()> nonce = nullptr);
    /// Test vektörleri için: çağranın içeri aldığı sabit anahtarla kurulur.
    PasskeyInitiator(uint32_t passkey, EcdhKey&& fixedKey, std::function<Bytes()> nonce);

    /// pair_init mesajı (geçici açık anahtarımız).
    Msg initMessage() const;
    Bytes publicKey() const { return selfPublic_; }

    /// TV mesajını işler; gönderilecek sonraki mesajı `out`a yazar.
    /// Bittiğinde (TV onayı doğrulandı) out boş kalır ve `key()` dolar.
    Failure handle(const Msg& m, Msg& out);

    /// Eşleşmenin türettiği kalıcı anahtar K (bitmeden boş).
    Bytes key() const { return pairingKey_; }
    /// §3.2 testleri için arabirimler: ortak sır ve taahhüt anahtarı.
    const Bytes& dh() const { return dh_; }
    const Bytes& commitKeyBytes() const { return kc_; }
    const Bytes& transcriptHash() const { return th_; }

private:
    enum class Phase { AwaitingKey, AwaitingCommit, AwaitingOpen, AwaitingPaired, Done };

    Msg commitMessage();

    EcdhKey ephemeral_;
    Bytes selfPublic_;
    uint32_t passkey_;
    std::function<Bytes()> nonce_;
    Phase phase_ = Phase::AwaitingKey;
    Bytes dh_, kc_, transcript_, th_, pairingKey_, na_, ca_, cb_;
    int round_ = 0;
};

}  // namespace atvm
