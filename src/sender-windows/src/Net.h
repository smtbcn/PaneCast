// PaneCast — Windows yayıncısı: Winsock'un süreçte bir kez başlatılması + LAN arayüzü seçimi.
// WSAStartup sayaçlıdır ama her ağ bileşeninin kendi globalini tutması gereksiz; C++11
// statik yerel başlatması thread-safe olduğu için tek satırlık çağrı yetiyor.
#pragma once

#include <winsock2.h>
#include <ws2tcpip.h>

#include <string>

#pragma comment(lib, "ws2_32.lib")

namespace atvm {

inline void EnsureWinsock() {
    static const int once = [] {
        WSADATA d;
        return WSAStartup(MAKEWORD(2, 2), &d);
    }();
    (void)once;
}

/// Hedefe giden yolun kullandığı yerel IPv4 adresi. Paket GÖNDERİLMEZ: UDP soketini bir
/// hedefe bağlamak yalnız yönlendirme tablosuna "hangi arayüzden çıkardım" diye sormaktır.
inline std::string SourceToward(const std::string& ipv4) {
    EnsureWinsock();
    const SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == INVALID_SOCKET) return {};
    sockaddr_in t = {};
    t.sin_family = AF_INET;
    t.sin_port = htons(53);
    if (InetPtonA(AF_INET, ipv4.c_str(), &t.sin_addr) != 1) { closesocket(s); return {}; }
    if (connect(s, reinterpret_cast<sockaddr*>(&t), sizeof(t)) != 0) { closesocket(s); return {}; }
    sockaddr_in me = {};
    int n = sizeof(me);
    getsockname(s, reinterpret_cast<sockaddr*>(&me), &n);
    closesocket(s);
    char buf[INET_ADDRSTRLEN] = {};
    if (!inet_ntop(AF_INET, &me.sin_addr, buf, sizeof(buf))) return {};
    return buf;
}

/// Varsayılan rotanın çıktığı arayüzün IPv4 adresi (ör. 192.0.2.14). Bu makinede yedi
/// IPv4 adresi var (Wi-Fi, Ethernet, Hyper-V, Bluetooth, üç sanal) ve sınırlı yayın
/// 255.255.255.255 Hyper-V anahtarından çıktı (ölçüldü 31.10.2026): LAN'a giden yolu
/// işletimin tercihine bırakmamak gerekiyor.
inline std::string PrimaryLanAddress() {
    return SourceToward("8.8.8.8");       // LAN dışı hedef → varsayılan rota → gerçek LAN
}

}  // namespace atvm
