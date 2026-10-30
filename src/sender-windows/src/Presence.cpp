#include "Presence.h"

#include "Json.h"
#include "Net.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>

#include <algorithm>
#include <chrono>
#include <map>
#include <vector>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "iphlpapi.lib")

namespace atvm {
namespace {

constexpr uint16_t kPresencePort = 7611;

/// `find` gövdesi (§2.1 + §3.4). `id` yoksa alıcı eski anlamı kullanır: `paired` =
/// "tabloda herhangi bir kayıt var mı". Kimlikle sorulan soru ise "bu bilgisayar eşleşmiş mi".
std::string FindPayload(const std::string& name, const std::string& deviceId) {
    JsonObject o;
    o.set("t", std::string("find"));
    o.set("name", name);
    if (!deviceId.empty()) o.set("id", deviceId);
    return o.dump();
}

/// Her açık IPv4 arayüzünün ALT-AĞ YÖNLENDİRMELİ yayın adresi (ör. 192.0.2.255).
/// Neden 255.255.255.255 değil: Windows sınırlı yayını TEK arayüzden çıkarıyor ve bu
/// makinede seçilen arayüz sanal anahtardı (ölçüldü 31.10.2026: kaynak adres o sanal
/// arayüzün adresi çıktı, yanıt 0; aynı gövde tek adrese gönderilince TV anında yanıtladı).
/// Yedi IPv4 adresi olan bir makinede doğru arayüzü yönlendirme tablosuna bırakmamak gerekiyor.
std::vector<sockaddr_in> BroadcastTargets() {
    std::vector<sockaddr_in> out;
    ULONG size = 15000;
    std::vector<char> buf(size);
    const ULONG flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                        GAA_FLAG_SKIP_DNS_SERVER | GAA_FLAG_SKIP_FRIENDLY_NAME;
    auto* head = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buf.data());
    if (GetAdaptersAddresses(AF_INET, flags, nullptr, head, &size) != ERROR_SUCCESS) return out;

    for (const IP_ADAPTER_ADDRESSES* a = head; a != nullptr; a = a->Next) {
        if (a->OperStatus != IfOperStatusUp) continue;
        if (a->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
        for (const IP_ADAPTER_UNICAST_ADDRESS* u = a->FirstUnicastAddress; u != nullptr; u = u->Next) {
            if (u->Address.lpSockaddr->sa_family != AF_INET) continue;
            const auto* sa = reinterpret_cast<const sockaddr_in*>(u->Address.lpSockaddr);
            const uint32_t addr = ntohl(sa->sin_addr.s_addr);
            if ((addr >> 16) == 0xA9FE) continue;        // 169.254/16: kendiliğinden bağ, yayını yok
            const ULONG prefix = u->OnLinkPrefixLength;
            if (prefix == 0 || prefix > 30) continue;    // /0 ve /31+/32 alt-ağ yayını üretmez
            const uint32_t mask = 0xFFFFFFFFu << (32 - prefix);
            sockaddr_in t = {};
            t.sin_family = AF_INET;
            t.sin_port = htons(kPresencePort);
            t.sin_addr.s_addr = htonl((addr & mask) | ~mask);
            out.push_back(t);
        }
    }
    return out;
}

}  // namespace

std::vector<TvReply> QueryPresence(const std::string& name, const std::string& deviceId,
                                   double seconds, const std::string& target) {
    EnsureWinsock();
    std::map<std::string, TvReply> seen;

    const SOCKET fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd == INVALID_SOCKET) return {};
    BOOL yes = TRUE;
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, reinterpret_cast<const char*>(&yes), sizeof(yes));
    // Mac 7611'e bağlanır; Windows'ta SO_REUSEADDR aynı porta başka bir sürecin de
    // bağlanmasına izin veriyor (paket çalma) ve ikinci uygulama örneği çakışıyor. Gerek de
    // yok: alıcı yanıtı paketin KAYNAK portuna gönderiyor (PresenceResponder.kt) → geçici port.
    sockaddr_in me = {};
    me.sin_family = AF_INET;
    me.sin_addr.s_addr = htonl(INADDR_ANY);
    me.sin_port = 0;
    bind(fd, reinterpret_cast<sockaddr*>(&me), sizeof(me));

    std::vector<sockaddr_in> targets;
    if (target.empty()) {
        targets = BroadcastTargets();
    } else {
        sockaddr_in t = {};
        t.sin_family = AF_INET;
        t.sin_port = htons(kPresencePort);
        if (InetPtonA(AF_INET, target.c_str(), &t.sin_addr) != 1) {
            closesocket(fd);
            return {};                                   // geçersiz adres: sessiz boş liste yok
        }
        targets.push_back(t);
    }
    if (targets.empty()) { closesocket(fd); return {}; }

    const std::string payload = FindPayload(name, deviceId);
    auto shout = [&] {
        for (const auto& t : targets)
            sendto(fd, payload.data(), static_cast<int>(payload.size()), 0,
                   reinterpret_cast<const sockaddr*>(&t), sizeof(t));
    };

    shout();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    char buf[1024];
    bool shoutedTwice = false;
    for (;;) {
        const auto remainMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                                  deadline - std::chrono::steady_clock::now())
                                  .count();
        if (remainMs <= 0) break;
        WSAPOLLFD pfd{fd, POLLIN, 0};
        if (WSAPoll(&pfd, 1, static_cast<int>(remainMs)) <= 0) break;

        sockaddr_in from = {};
        int fromLen = sizeof(from);
        const int n = recvfrom(fd, buf, sizeof(buf) - 1, 0,
                               reinterpret_cast<sockaddr*>(&from), &fromLen);
        if (n <= 0) continue;
        buf[n] = '\0';
        const auto obj = ParseFlatJson(buf);
        if (!obj || obj->str("t") != "tv") continue;     // başka bir yayıncının `find`'ı olabilir

        std::string host = obj->str("ip");
        if (host.empty()) {                              // alan bozuksa paketin kaynağı geçer
            char ip[INET_ADDRSTRLEN] = {};
            inet_ntop(AF_INET, &from.sin_addr, ip, sizeof(ip));
            host = ip;
        }
        if (host.empty()) continue;

        TvReply r;
        r.name = obj->str("name").empty() ? host : obj->str("name");
        r.host = host;
        r.controlPort = static_cast<int>(obj->num("cport", 7601));
        r.mediaPort = static_cast<int>(obj->num("mport", 7602));
        r.paired = obj->boolean("paired", false);
        r.freeSlots = obj->num("slot", -1);
        seen[host] = r;

        if (!shoutedTwice && remainMs > 400) {           // geç uyanan cihazlar için ikinci tur
            shout();
            shoutedTwice = true;
        }
    }
    closesocket(fd);

    std::vector<TvReply> out;
    out.reserve(seen.size());
    for (auto& kv : seen) out.push_back(std::move(kv.second));
    std::sort(out.begin(), out.end(),
              [](const TvReply& a, const TvReply& b) { return a.name < b.name; });
    return out;
}

}  // namespace atvm
