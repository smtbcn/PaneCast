// PaneCast — Windows yayıncısı: ağ yoklaması (UDP 7611, docs/protocol.md §2.1)
//
// Mac karşılığı TvPresence.swift: `find` yayımlanır, açık her alıcı kendi adını + IPv4'ünü
// bir kez geri yazar. Alıcı bu paketin KAYNAK adresini ulaşılabilir adresimiz olarak öğrenir
// (çok arayüzlü makinede mDNS A kaydı yanlış arayüzü verebiliyor — ölçüldü).
#pragma once

#include <string>
#include <vector>

namespace atvm {

struct TvReply {
    std::string name;
    std::string host;
    int controlPort = 7601;
    int mediaPort = 7602;
    /// "bu kimliğin anahtarı var mı" — yoklama `id` taşıyorsa kimliğe göre cevaplanır (§2.1).
    bool paired = false;
    /// Boş eşleşme yuvası sayısı; -1 = eski alıcı, alanı göndermiyor.
    long long freeSlots = -1;
};

/// `find` yayımlar ve `seconds` boyunca gelen yanıtları toplar (ada göre sıralı).
/// `target` boşsa 255.255.255.255'e yayın yapılır; doluysa gövde yalnız o adrese gönderilir
/// (teşhis: yayın yolunun kendisini tek adres yolundan ayırmak için).
std::vector<TvReply> QueryPresence(const std::string& name, const std::string& deviceId,
                                   double seconds = 1.5, const std::string& target = {});

}  // namespace atvm
