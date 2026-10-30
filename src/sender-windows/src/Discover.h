// PaneCast — Windows yayıncısı: DNS-SD (mDNS) kaydı — yalnız OS API'si.
//
// TV'nin "bilgisayar seç" akışı `_atvm-sender._tcp` taramasına bakıyor (SenderBrowser.kt);
// bu kayıt olmadan TV tarafındaki uzaktan başlatma bilgisayarı hiç görmüyor. Mac karşılığı
// NetService.publish (SenderServer.swift). Windows'ta Bonjour SDK'sı YOK (ADR-001): işletimin
// kendi mDNS yığını, WinDNS.h → DnsServiceRegister.
//
// Ölçülen tuzak (31.10.2026): bu makinede yedi IPv4 adresi var ve A kaydını işletime
// bırakmak Hyper-V anahtarının adresini yayımlayabiliyor → adres açıkça veriliyor.
// İkinci tuzak: DnsServiceConstructInstance'ın pHostName parametresi zorunlu; NULL
// verilirse örnek NULL dönüyor ve GetLastError 0 kalıyor (sessiz ret).
#pragma once

// Sıra şart: WinDNS.h temel Win32 tiplerini (PWSTR, DWORD) windows.h'ten bekliyor; önce
// gelirse windnsdef.h "bilinmeyen geçersiz kılma belirticisi" veriyor (ölçüldü).
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <WinDNS.h>

#include <cstdint>
#include <string>

namespace atvm {

class SenderRegistrar {
public:
    SenderRegistrar() = default;
    ~SenderRegistrar();
    SenderRegistrar(const SenderRegistrar&) = delete;
    SenderRegistrar& operator=(const SenderRegistrar&) = delete;

    /// `instanceName` = "ATVM-<HostName>" (§2). Tam ad: <instance>._atvm-sender._tcp.local
    /// Kaydın tamamlanmasını bekler (5 sn); başarılıysa süreç yaşarken yayında kalır.
    bool Publish(const std::string& instanceName, uint16_t port);
    /// Kaydı düşürür (Mac'in `NetService.stop()` karşılığı): TV listesinde hayalet satır kalmasın.
    void Stop();

    bool active() const { return active_; }
    /// Yayımlanan IPv4 (teşhis için; boşsa A kaydı işletimin seçimine bırakıldı).
    const std::string& address() const { return lan_; }
    const std::string& lastError() const { return error_; }

private:
    static VOID WINAPI OnRegister(DWORD status, PVOID ctx, PDNS_SERVICE_INSTANCE instance);

    DNS_SERVICE_REGISTER_REQUEST req_ = {};
    DNS_SERVICE_CANCEL cancel_ = {};
    PDNS_SERVICE_INSTANCE instance_ = nullptr;
    HANDLE done_ = nullptr;
    LONG status_ = 0;
    bool active_ = false;
    std::string lan_;
    std::string error_;
};

}  // namespace atvm
