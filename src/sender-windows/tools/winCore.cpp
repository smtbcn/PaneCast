// PaneCast — Windows yayıncısı: çekirdek teşhis aracı (görev #7).
//
// Arayüz gelene kadar her katman tek başına ölçülebilsin:
//   id             kalıcı kimliği basar; eski düz dosyalar taşındıysa taşıma notunu da yazar
//   keys           DPAPI deposundaki eşleşmeleri listeler (adres + ad + parmak izi)
//   presence [sn]  UDP 7611'e `find` YAYINLAR, alıcı yanıtlarını basar (paired/slot dahil)
//   probe <ip> [sn] aynı gövdeyi tek adrese gönderir — yayın yolunu tek adres yolundan ayırır
//   reg [sn]       `_atvm-sender._tcp` kaydını yayımlar, süre boyunca elde tutar (TV listesi)
//   regtest        örnek kurmanın varyantlarını dolaşır, her birinde GetLastError basar
//   serve [sn]     TCP 7610 dinleyici + mDNS kayıt birlikte: TV seçerse hello→proof→ready→
//                  resume zincirini burada ölçer (yayın motoru hâlihazırda bağlı yok)
//
// Etiketler ASCII, değerler UTF-8: konsol kod sayfası burada UTF-8'e çekiliyor.
#include "../src/SenderServer.h"   // önce gelir: winsock2 → windows sırası burada korunur
#include "../src/Discover.h"
#include "../src/Host.h"
#include "../src/KeyStore.h"
#include "../src/Net.h"
#include "../src/Pairing.h"
#include "../src/Presence.h"
#include "../src/Text.h"

#include <windows.h>

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using namespace atvm;

namespace {

struct ProbeCtx {
    HANDLE ev;
    LONG status;
};

VOID WINAPI ProbeCallback(DWORD status, PVOID ctx, PDNS_SERVICE_INSTANCE) {
    auto* c = static_cast<ProbeCtx*>(ctx);
    InterlockedExchange(&c->status, static_cast<LONG>(status));
    SetEvent(c->ev);
}

/// Örnek kurma varyantlarını dolaşır: hangisinin NULL döndüğünü ve GetLastError değerini
/// yan yana basar. Böylece "başarısız" tek bir sayıya değil, ölçülen bir karşılaştırmaya dayanır.
int RegisterProbe(const std::string& instance) {
    EnsureWinsock();
    const std::string lan = PrimaryLanAddress();
    IP4_ADDRESS ip4 = 0;
    if (!lan.empty()) {
        in_addr a = {};
        if (InetPtonA(AF_INET, lan.c_str(), &a) == 1) ip4 = a.S_un.S_addr;
    }
    printf("LAN=%s\n", lan.empty() ? "?" : lan.c_str());

    const std::wstring host = Wide(HostName() + ".local");
    const std::wstring svc = Wide(instance + "._atvm-sender._tcp.local");
    const std::wstring svcNoLocal = Wide(instance + "._atvm-sender._tcp");
    const std::wstring control = Wide("probe._http._tcp.local");

    struct Variant {
        const char* label;
        PCWSTR service;
        PCWSTR hostName;
        bool withIp;
    };
    const Variant variants[] = {
        {"A ad=local host=NULL ip=var",  svc.c_str(),       nullptr,      true},
        {"B ad=local host=var ip=var",   svc.c_str(),       host.c_str(), true},
        {"C ad=local host=var ip=NULL",  svc.c_str(),       host.c_str(), false},
        {"D ad=yalin host=var ip=var",   svcNoLocal.c_str(), host.c_str(), true},
        {"E denetim _http host=var",     control.c_str(),   host.c_str(), true},
    };

    PDNS_SERVICE_INSTANCE good = nullptr;
    std::string goodLabel;
    for (const auto& v : variants) {
        SetLastError(ERROR_SUCCESS);
        PDNS_SERVICE_INSTANCE ins = DnsServiceConstructInstance(
            v.service, v.hostName, v.withIp && ip4 != 0 ? &ip4 : nullptr, nullptr,
            htons(7610), 0, 0, 0, nullptr, nullptr);
        printf("VAR %s -> ins=%s err=%lu\n", v.label, ins ? "VAR" : "NULL", GetLastError());
        if (ins != nullptr && good == nullptr) { good = ins; goodLabel = v.label; }
        else if (ins != nullptr) DnsServiceFreeInstance(ins);
    }
    if (good == nullptr) { printf("SONUC=ornek_kurulamiyor\n"); return 1; }
    printf("SECILEN=%s\n", goodLabel.c_str());

    const HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    ProbeCtx ctx = {done, static_cast<LONG>(DNS_REQUEST_PENDING)};
    DNS_SERVICE_REGISTER_REQUEST req = {};
    DNS_SERVICE_CANCEL cancel = {};
    req.Version = DNS_QUERY_REQUEST_VERSION1;
    req.InterfaceIndex = 0;
    req.pServiceInstance = good;
    req.pRegisterCompletionCallback = &ProbeCallback;
    req.pQueryContext = &ctx;
    req.hCredentials = nullptr;
    req.unicastEnabled = FALSE;
    const DWORD rc = DnsServiceRegister(&req, &cancel);
    printf("REG rc=%lu", rc);
    if (rc == DNS_REQUEST_PENDING) {
        WaitForSingleObject(done, 5000);
        printf(" beklenen_durum=%ld\n", ctx.status);
    } else {
        printf(" senkron\n");
        InterlockedExchange(&ctx.status, static_cast<LONG>(rc));
    }
    if (ctx.status == ERROR_SUCCESS) {
        printf("HOLDING=8s\n");
        Sleep(8000);
        ResetEvent(done);
        const DWORD dr = DnsServiceDeRegister(&req, &cancel);
        if (dr == DNS_REQUEST_PENDING) WaitForSingleObject(done, 2000);
        printf("DEREGISTER=%lu durum=%ld\n", dr, ctx.status);
    } else {
        DnsServiceRegisterCancel(&cancel);
    }
    DnsServiceFreeInstance(good);
    CloseHandle(done);
    return ctx.status == ERROR_SUCCESS ? 0 : 1;
}

int PrintTvs(const std::vector<TvReply>& tvs) {
    printf("TV_COUNT=%zu\n", tvs.size());
    for (const auto& t : tvs) {
        printf("TV name=%s ip=%s cport=%d mport=%d paired=%d slots=%lld key_here=%d\n",
               t.name.c_str(), t.host.c_str(), t.controlPort, t.mediaPort,
               t.paired ? 1 : 0, t.freeSlots, KeyStore::IsPaired(t.host) ? 1 : 0);
    }
    return tvs.empty() ? 1 : 0;
}

}  // namespace

int main(int argc, char** argv) {
    SetConsoleOutputCP(CP_UTF8);
    setvbuf(stdout, nullptr, _IONBF, 0);      // uzak kabukta satır beklemesin: kayıt anı görünsün
    if (argc < 2) {
        printf("usage: winCore <id|keys|presence|probe|reg|regtest|serve> [args]\n");
        return 2;
    }
    const std::string cmd = argv[1];

    if (cmd == "regtest") return RegisterProbe("ATVM-" + HostName());

    const std::string note = KeyStore::Prepare();
    if (!note.empty()) printf("MIGRATED=%s\n", note.c_str());

    if (cmd == "id") {
        const std::string id = KeyStore::DeviceId();
        printf("NAME=%s\n", HostName().c_str());
        printf("DEVICE_ID=%s len=%zu\n", id.c_str(), id.size());
        return id.size() == 16 ? 0 : 1;
    }

    if (cmd == "keys") {
        const auto hosts = KeyStore::PairedHosts();
        const auto names = KeyStore::Names();
        printf("COUNT=%zu\n", hosts.size());
        for (const auto& h : hosts) {
            Bytes key;
            const std::string fp = KeyStore::KeyFor(h, key) ? Fingerprint(key) : std::string("?");
            const auto n = names.find(h);
            printf("HOST=%s NAME=%s FINGERPRINT=%s\n", h.c_str(),
                   n == names.end() ? "-" : n->second.c_str(), fp.c_str());
        }
        return 0;
    }

    if (cmd == "presence" || cmd == "probe") {
        const bool unicast = cmd == "probe";
        const std::string target = unicast ? (argc > 2 ? argv[2] : "") : "";
        if (unicast && target.empty()) { printf("usage: winCore probe <ip> [seconds]\n"); return 2; }
        const char* secArg = unicast ? (argc > 3 ? argv[3] : nullptr) : (argc > 2 ? argv[2] : nullptr);
        const double secs = secArg ? atof(secArg) : 1.5;
        const std::string id = KeyStore::DeviceId();
        printf("LOCAL name=%s id=%s\n", HostName().c_str(), id.c_str());
        if (unicast) {
            const std::string src = SourceToward(target);
            printf("TARGET=%s SRC=%s\n", target.c_str(), src.empty() ? "?" : src.c_str());
        }
        return PrintTvs(QueryPresence(HostName(), id, secs, target));
    }

    if (cmd == "reg") {
        const double secs = argc > 2 ? atof(argv[2]) : 20.0;
        const std::string instance = "ATVM-" + HostName();
        SenderRegistrar reg;
        const bool ok = reg.Publish(instance, 7610);
        printf("INSTANCE=%s PORT=7610 ADDR=%s OK=%d\n", instance.c_str(),
               reg.address().empty() ? "?" : reg.address().c_str(), ok ? 1 : 0);
        if (!ok) { printf("FAIL=%s\n", reg.lastError().c_str()); return 1; }
        printf("HOLDING=%.0fs\n", secs);
        Sleep(static_cast<DWORD>(secs * 1000));
        reg.Stop();
        printf("STOPPED=1 active=%d\n", reg.active() ? 1 : 0);
        return 0;
    }

    if (cmd == "serve") {
        const double secs = argc > 2 ? atof(argv[2]) : 20.0;
        SenderServer srv;
        srv.onLog = [](const std::string& s) { printf("LOG %s\n", s.c_str()); };
        srv.onResume = [](const std::shared_ptr<TvSession>& s) {
            printf("RESUME tv=%s(%s) media=%s:%u\n", s->name().c_str(), s->host().c_str(),
                   s->mediaHost().c_str(), s->mediaPort());
        };
        srv.onIdrRequest = [](const std::string& h) { printf("IDR host=%s\n", h.c_str()); };
        srv.onTvStop = [](const std::string& h) { printf("TV_STOP host=%s\n", h.c_str()); };
        const bool ok = srv.Start(7610, true);
        printf("LISTEN=%d PORT=%u ADVERTISED=%d ERROR=%s\n",
               srv.listening() ? 1 : 0, srv.port(), srv.advertised() ? 1 : 0,
               srv.lastError().empty() ? "-" : srv.lastError().c_str());
        if (!ok) return 1;
        printf("HOLDING=%.0fs\n", secs);
        Sleep(static_cast<DWORD>(secs * 1000));
        srv.Stop();
        printf("STOPPED listening=%d\n", srv.listening() ? 1 : 0);
        return 0;
    }

    printf("FAIL=unknown_command %s\n", cmd.c_str());
    return 2;
}
