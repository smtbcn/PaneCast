// PaneCast — Windows yayıncısı: TV'nin 7601 kontrol kanalına istemci (docs/protocol.md §1, §3).
// Çerçeve: tek satır = tek JSON nesnesi, `\n` biter, TCP_NODELAY, satır tavanı 8192 bayt,
// doğrulamadan önce sessiz bağlantı 15 sn'de kapanır. Medya (RTP/UDP) ayrı modüldür.
#pragma once

#include "Json.h"

#include <optional>
#include <string>

#include "Crypto.h"

namespace atvm {

class ControlClient {
public:
    static constexpr int kMaxLineBytes = 8192;        // §3 — aşan satır bağlantıyı düşürür
    static constexpr int kPreAuthTimeoutMs = 15000;   // §3 — doğrulanmamış sessiz bağlantı

    ControlClient();
    ~ControlClient();
    ControlClient(const ControlClient&) = delete;
    ControlClient& operator=(const ControlClient&) = delete;

    bool connected() const { return sock_ != -1; }
    bool connect(const std::string& ipv4, uint16_t port, int timeoutMs = 4000);
    void close();

    bool sendLine(const std::string& json);
    /// Bir satır okur; 8192 baytı aşarsa veya akış kapanırsa nullopt.
    std::optional<FlatJson> readLine(int timeoutMs = 8000);

    /// hello → challenge (eşleşmiş) | pair_required (PIN gerekir) | denied/sürüm hatası.
    enum class Greet { Challenged, NeedPin, Failed };
    Greet hello(const std::string& name, const std::string& deviceId, FlatJson* reply,
                std::string* errorOut);

    /// challenge alan `reply` üzerinden karşılıklı oturum kanıtı (§3.2 yeniden bağlantı).
    bool authenticate(const Bytes& key, const FlatJson& reply, std::string* errorOut);

    /// Eşleşme: pair_init → 20 tur → pair_confirm → paired. Başarıda K döner.
    std::optional<Bytes> pairWithPin(const std::string& pin, std::string* errorOut);

    /// Karşılıklı kanıttan sonra alıcının bildirdiği oturum parmak izi (§3.2 `session`).
    std::string session() const { return session_; }

private:
    long long sock_ = -1;
    std::string recv_;
    std::string session_;
};

}  // namespace atvm
