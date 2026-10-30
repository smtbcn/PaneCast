#include "Discover.h"

#include "Host.h"
#include "Net.h"
#include "Text.h"

#include <ws2tcpip.h>

#pragma comment(lib, "dnsapi.lib")

namespace atvm {
namespace {
constexpr DWORD kRegisterWaitMs = 5000;
constexpr DWORD kDeregisterWaitMs = 2000;
}  // namespace

VOID WINAPI SenderRegistrar::OnRegister(DWORD status, PVOID ctx, PDNS_SERVICE_INSTANCE) {
    auto* self = static_cast<SenderRegistrar*>(ctx);
    if (self == nullptr) return;
    InterlockedExchange(&self->status_, static_cast<LONG>(status));
    if (self->done_ != nullptr) SetEvent(self->done_);
}

SenderRegistrar::~SenderRegistrar() {
    Stop();
    if (done_ != nullptr) { CloseHandle(done_); done_ = nullptr; }
}

bool SenderRegistrar::Publish(const std::string& instanceName, uint16_t port) {
    if (active_) return true;
    error_.clear();

    lan_ = PrimaryLanAddress();
    IP4_ADDRESS ip4 = 0;
    if (!lan_.empty()) {
        in_addr a = {};
        if (InetPtonA(AF_INET, lan_.c_str(), &a) == 1) ip4 = a.S_un.S_addr;   // ağ bayt sırası
    }

    const std::string full = instanceName + "._atvm-sender._tcp.local";
    // pHostName SDK'da `_In_` (zorunlu), `_In_opt_` değil: NULL verilince örnek sessizce
    // NULL dönüyor ve GetLastError 0 kalıyor (ölçüldü 31.10.2026, winCore regtest varyant A/B).
    const std::wstring wFull = Wide(full);
    const std::wstring wHost = Wide(HostName() + ".local");
    // wPort host bayt sırasında bekleniyor: htons ile verilince SRV 47645 yayımladı
    // (= 0xBA1D, 7610'un ters çevrilmişi) ve dns-sd -L yanlış portu gösterdi (ölçüldü).
    instance_ = DnsServiceConstructInstance(wFull.c_str(), wHost.c_str(),
                                            ip4 != 0 ? &ip4 : nullptr, nullptr,
                                            port, 0, 0, 0, nullptr, nullptr);
    if (instance_ == nullptr) { error_ = "DnsServiceConstructInstance örnek üretmedi"; return false; }
    if (done_ == nullptr) done_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (done_ == nullptr) { error_ = "tamamlanma olayı açılamadı"; return false; }

    req_.Version = DNS_QUERY_REQUEST_VERSION1;
    req_.InterfaceIndex = 0;                       // 0 = bütün arayüzler
    req_.pServiceInstance = instance_;
    req_.pRegisterCompletionCallback = &SenderRegistrar::OnRegister;
    req_.pQueryContext = this;
    req_.hCredentials = nullptr;
    req_.unicastEnabled = FALSE;                   // yalnız mDNS; tek-eşleme bölge kaydı yok
    ResetEvent(done_);
    InterlockedExchange(&status_, static_cast<LONG>(DNS_REQUEST_PENDING));

    const DWORD rc = DnsServiceRegister(&req_, &cancel_);
    if (rc == DNS_REQUEST_PENDING) WaitForSingleObject(done_, kRegisterWaitMs);
    else if (rc != ERROR_SUCCESS) InterlockedExchange(&status_, static_cast<LONG>(rc));

    const LONG st = status_;
    if (st != ERROR_SUCCESS) {
        error_ = "kayıt tamamlanmadı (durum " + std::to_string(st) + ")";
        Stop();
        return false;
    }
    active_ = true;
    return true;
}

void SenderRegistrar::Stop() {
    if (active_) {
        active_ = false;
        ResetEvent(done_);
        InterlockedExchange(&status_, static_cast<LONG>(DNS_REQUEST_PENDING));
        const DWORD rc = DnsServiceDeRegister(&req_, &cancel_);
        if (rc == DNS_REQUEST_PENDING) WaitForSingleObject(done_, kDeregisterWaitMs);
    } else if (status_ == static_cast<LONG>(DNS_REQUEST_PENDING)) {
        // Kayıt beklemede takıldı: isteği iptal etmeden örneği serbest bırakmak, DNS
        // istemcisinin elindeki göstericiyi düşürürdü.
        DnsServiceRegisterCancel(&cancel_);
    }
    // Örnek, geri çağrı dönene kadar yaşamalı: DeRegister beklenmeden serbest bırakılmaz.
    if (instance_ != nullptr) { DnsServiceFreeInstance(instance_); instance_ = nullptr; }
}

}  // namespace atvm
