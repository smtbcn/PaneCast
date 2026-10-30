// PaneCast — Windows yayıncısı: eşleşme anahtarı deposu (yalnız OS API'si)
//
// Mac karşılığı Anahtar Zinciri (KeyStore.swift). Windows'ta Credential Locker BİLİNÇLİ
// SEÇİLMEDİ: oradaki kimlik bilgileri Microsoft hesabıyla cihazlar arasında dolaşır →
// eşleşme anahtarı makineden çıkardı; DPAPI blob'u kullanıcı+makine kapsamındadır,
// Anahtar Zinciri'nin kapsamıyla aynı (ADR-008 kararı).
//
// Biçim: %LOCALAPPDATA%\PaneCast\store.bin = CryptProtectData ile şifrelenmiş düz metin
// (1. satır device_id, sonra satır başına host<TAB>base64 anahtar). TV adları sır değildir:
// Mac'teki gibi ayrı düz dosyada (paired_names.json).
// İlk erişimde `winPair` aracının düz dosyaları (device_id.txt, pairs\*.bin) buraya taşınır
// ve silinir — Mac'in `paired_keys.json` taşımasının birebir karşılığı.
#pragma once

#include <map>
#include <string>
#include <vector>

#include "Crypto.h"

namespace atvm {

class KeyStore {
public:
    /// Eski düz dosyaları (`device_id.txt`, `pairs\*.bin`) DPAPI deposuna taşır ve sonucu
    /// arayüz günlüğü için döndürür. Mac'teki `KeyStore.prepare()` karşılığı: kimlik TEK
    /// olmalı, yoksa TV aynı bilgisayarı iki ayrı kayıt sayar ve sınırlı yuvayı tüketir (§3.4).
    static std::string Prepare();

    /// Kalıcı yayıncı kimliği (§3.4): 12 bayt → padding'siz base64url, tam 16 karakter.
    /// İlk çağrıda üretilir ve depoya yazılır; ana makine adından/MAC'ten türetilmez.
    static std::string DeviceId();

    static bool KeyFor(const std::string& host, Bytes& out32);
    static bool IsPaired(const std::string& host);
    static void StoreKey(const std::string& host, const Bytes& key32);
    static void Remove(const std::string& host);
    /// Depodaki adresler (sıralı). Arayüz listesini keşif çizer; bu, deponun kendi kanıtı.
    static std::vector<std::string> PairedHosts();

    static void StoreName(const std::string& name, const std::string& host);
    static std::map<std::string, std::string> Names();
    static void DropName(const std::string& host);
};

}  // namespace atvm
