#include "ControlClient.h"

#include "Net.h"
#include "Pairing.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <cstring>

#pragma comment(lib, "ws2_32.lib")

namespace atvm {
namespace {

std::string lastError(const char* what) {
    char buf[64];
    snprintf(buf, sizeof(buf), "%s (WSA %d)", what, WSAGetLastError());
    return buf;
}

JsonObject toJson(const Msg& m) {
    JsonObject o;
    for (const auto& [k, v] : m.text) o.set(k, v);
    for (const auto& [k, v] : m.number) o.set(k, v);
    return o;
}

Msg fromFlat(const FlatJson& f) {
    Msg m;
    for (const auto& [k, v] : f.strings) m.text[k] = v;
    for (const auto& [k, v] : f.numbers) m.number[k] = v;
    return m;
}

}  // namespace

ControlClient::ControlClient() = default;

ControlClient::~ControlClient() { close(); }

void ControlClient::close() {
    if (sock_ != -1) {
        closesocket(static_cast<SOCKET>(sock_));
        sock_ = -1;
    }
    recv_.clear();
}

bool ControlClient::connect(const std::string& ipv4, uint16_t port, int timeoutMs) {
    EnsureWinsock();
    sockaddr_in target = {};
    target.sin_family = AF_INET;                       // TV yalnız IPv4 dinliyor (§1 notu)
    target.sin_port = htons(port);
    if (InetPtonA(AF_INET, ipv4.c_str(), &target.sin_addr) != 1) return false;

    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return false;
    int nodelay = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&nodelay), sizeof(nodelay));

    // Zaman aşımlı connect: soketi geçici olarak non-blocking yap, seç, geri al.
    u_long one = 1;
    ioctlsocket(s, FIONBIO, &one);
    // Üye connect(), Winsock global işlevini gölgeliyor: ::connect şart.
    ::connect(s, reinterpret_cast<sockaddr*>(&target), sizeof(target));
    fd_set wfds;
    FD_ZERO(&wfds);
    FD_SET(s, &wfds);
    timeval tv{timeoutMs / 1000, (timeoutMs % 1000) * 1000};
    const int sel = select(0, nullptr, &wfds, nullptr, &tv);
    one = 0;
    ioctlsocket(s, FIONBIO, &one);
    if (sel <= 0) {
        closesocket(s);
        return false;
    }
    int err = 0;
    int len = sizeof(err);
    getsockopt(s, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&err), &len);
    if (err != 0) {
        closesocket(s);
        return false;
    }
    sock_ = static_cast<long long>(s);
    return true;
}

bool ControlClient::sendLine(const std::string& json) {
    if (sock_ == -1) return false;
    std::string wire = json;
    wire.push_back('\n');
    size_t sent = 0;
    while (sent < wire.size()) {
        const int n = ::send(static_cast<SOCKET>(sock_), wire.data() + sent,
                             static_cast<int>(wire.size() - sent), 0);
        if (n <= 0) { close(); return false; }
        sent += static_cast<size_t>(n);
    }
    return true;
}

std::optional<FlatJson> ControlClient::readLine(int timeoutMs) {
    if (sock_ == -1) return std::nullopt;
    char buf[2048];
    while (recv_.find('\n') == std::string::npos) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(static_cast<SOCKET>(sock_), &rfds);
        timeval tv{timeoutMs / 1000, (timeoutMs % 1000) * 1000};
        if (select(0, &rfds, nullptr, nullptr, &tv) <= 0) { close(); return std::nullopt; }
        const int n = ::recv(static_cast<SOCKET>(sock_), buf, sizeof(buf), 0);
        if (n <= 0) { close(); return std::nullopt; }
        recv_.append(buf, static_cast<size_t>(n));
        // §3: satır tavanı aşılırsa bağlantı düşer (alıcı da aynısını yapıyor).
        if (recv_.size() > static_cast<size_t>(kMaxLineBytes)) { close(); return std::nullopt; }
    }
    std::string line = recv_.substr(0, recv_.find('\n'));
    recv_.erase(0, line.size() + 1);
    if (!line.empty() && line.back() == '\r') line.pop_back();
    return ParseFlatJson(line);
}

ControlClient::Greet ControlClient::hello(const std::string& name, const std::string& deviceId,
                                         FlatJson* reply, std::string* errorOut) {
    JsonObject o;
    o.set("t", std::string("hello"));
    o.set("name", name);
    o.set("ver", static_cast<long long>(PairingConst::kVersion));
    if (!deviceId.empty()) o.set("device_id", deviceId);     // §3.4 — eski alıcı yok sayar
    if (!sendLine(o.dump())) {
        if (errorOut) *errorOut = lastError("hello gönderilemedi");
        return Greet::Failed;
    }
    auto in = readLine(8000);
    if (!in) {
        if (errorOut) *errorOut = "hello yanıtı okunamadı (kapandı / tavan / zaman aşımı)";
        return Greet::Failed;
    }
    if (reply) *reply = *in;
    const std::string t = in->str("t");
    if (in->num("ver", 0) != PairingConst::kVersion) {
        if (errorOut) *errorOut = "sürüm uyumsuz: yanıt ver=" + std::to_string(in->num("ver", 0));
        return Greet::Failed;
    }
    if (t == "challenge") return Greet::Challenged;
    if (t == "pair_required") return Greet::NeedPin;
    if (errorOut) *errorOut = "denied/" + in->str("reason");
    return Greet::Failed;
}

bool ControlClient::authenticate(const Bytes& key, const FlatJson& reply, std::string* errorOut) {
    const Bytes nonceTv = B64Decode(reply.str("nonce_tv"));
    if (nonceTv.size() != PairingConst::kNonceBytes) {
        if (errorOut) *errorOut = "challenge nonce boyutu bozuk";
        return false;
    }
    const Bytes nonceMac = RandomBytes(PairingConst::kNonceBytes);
    JsonObject o;
    o.set("t", std::string("proof"));
    o.set("nonce_mac", B64Encode(nonceMac));
    o.set("proof", B64Encode(SessionProof(key, Channel::Control, Role::Mac, nonceTv, nonceMac)));
    if (!sendLine(o.dump())) {
        if (errorOut) *errorOut = lastError("proof gönderilemedi");
        return false;
    }
    auto ready = readLine(8000);
    if (!ready || ready->str("t") != "ready") {
        if (errorOut)
            *errorOut = ready ? ("ready yerine " + ready->str("t") + "/" + ready->str("reason"))
                              : "ready okunamadı";
        return false;
    }
    // §3.2: TV de kendini kanıtlar; tutmazsa araya giren olabilir → bağlantıyı bırak.
    const Bytes want = SessionProof(key, Channel::Control, Role::Tv, nonceTv, nonceMac);
    if (!ConstantTimeEqual(want, B64Decode(ready->str("proof")))) {
        if (errorOut) *errorOut = "TV'nin oturum kanıtı tutmadı";
        close();
        return false;
    }
    session_ = ready->str("session");
    return true;
}

std::optional<Bytes> ControlClient::pairWithPin(const std::string& pinText, std::string* errorOut) {
    uint32_t pin = 0;
    if (!PasskeyFromText(pinText, pin)) {
        if (errorOut) *errorOut = "PIN 6 rakam değil";
        return std::nullopt;
    }
    PasskeyInitiator init(pin);
    Msg next = init.initMessage();
    for (int guard = 0; guard < 4 * PairingConst::kRounds + 8; ++guard) {
        if (!sendLine(toJson(next).dump())) {
            if (errorOut) *errorOut = lastError("eşleşme mesajı gönderilemedi");
            return std::nullopt;
        }
        auto in = readLine(20000);              // kullanıcı kodu yazarken TV 180 sn bekliyor
        if (!in) {
            if (errorOut) *errorOut = "eşleşme yanıtı okunamadı";
            return std::nullopt;
        }
        Msg out2;
        const auto f = init.handle(fromFlat(*in), out2);
        if (f.kind == PasskeyInitiator::Error::None && out2.type().empty())
            return init.key();                  // `paired` doğrulandı
        if (f.kind != PasskeyInitiator::Error::None) {
            if (errorOut) {
                *errorOut = f.reason.empty() ? std::to_string(static_cast<int>(f.kind)) : f.reason;
                if (f.kind == PasskeyInitiator::Error::Locked)
                    *errorOut += " (tekrar " + std::to_string(f.retryAfterMs / 1000) + " sn)";
            }
            return std::nullopt;
        }
        next = out2;
    }
    if (errorOut) *errorOut = "eşleşme tur sınırına takıldı";
    return std::nullopt;
}

}  // namespace atvm
