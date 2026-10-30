// PaneCast — Windows yayıncısı: görünür makine adı.
// macOS tarafındaki `HostName.current` (Host.current().localizedName) karşılığı: kullanıcının
// Ayarlar → Sistem → Hakkında'da gördüğü "PC adı". mDNS kaydına ve `hello.name` alanına gider,
// yani TV ekranında "eşleşilen: <bu ad>" satırında görünür.
#pragma once

// WIN32_LEAN_AND_MEAN şart: windows.h aksi halde winsock.h (v1) çekiyor ve winsock2.h ile
// aynı çeviri biriminde 'sockaddr' yeniden tanımı veriyor (ölçüldü: C2011).
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <string>

namespace atvm {

/// DNS ana makine adı (ör. "DESKTOP-ORNEK"). Boş dönerse "Windows PC" yedeği: ad boşsa TV listesi
/// satırı anlamsız olur ama yayın yine de kurulabilir.
inline std::string HostName() {
    char buf[256] = {0};
    DWORD n = sizeof(buf);
    if (GetComputerNameExA(ComputerNamePhysicalDnsHostname, buf, &n) && n > 0) return std::string(buf, n);
    n = sizeof(buf);
    if (GetComputerNameA(buf, &n) && n > 0) return std::string(buf, n);
    return "Windows PC";
}

}  // namespace atvm
