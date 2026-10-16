package dev.atvm.receiver

/**
 * mDNS'in çözdüğü birden çok adresin aday sırası.
 *
 * Ölçülen kusur (gerçek Vestel TV, 16.10.2026): Mac'te Wi-Fi (en0) dışında bir de sanal makine
 * köprüsü (en1) varken `NsdServiceInfo.host` o köprünün adresine denk geldi; TV, kendi ağıyla
 * ilgisi olmayan adrese 7610 açmaya çalıştı, 4 sn sonra düştü ve kumandada "hiçbir şey olmadı"
 * göründü. Aynı servis adı ikinci kez çözüldüğünde doğru adres de gelebiliyordu — yani sonuç
 * keyfiydi. Artık çözümlemenin **tüm** adresleri aday listesine yazılıyor ve TV'nin kendi
 * adresleriyle aynı ağdaki aday önce deneniyor.
 */
object SenderAddresses {
    /**
     * mDNS'in verdiği tek adrese, o makinenin **diğer** adresleri de eklenir: `.local` adı
     * çözüldüğünde tüm arayüzlerin adresleri döner. `lookup` enjekte edilir ki JVM'de
     * sınanabilsin; çözümleme başarısız olursa tek adayla devam edilir (bağlantı denemesi
     * zaten kendi zaman aşımıyla düşer).
     */
    fun expand(address: String, lookup: (String) -> List<String>): List<String> {
        if (address.isBlank()) return emptyList()
        val extra = try { lookup(address) } catch (e: Exception) { emptyList() }
        return (listOf(address) + extra).filter { it.isNotBlank() }.distinct()
    }

    /** TV'nin kendi /24'üyle eşleşen adaylar önce; kalanlar sırasını korur; çöp değerler düşer. */
    fun order(candidates: List<String>, localIpv4s: List<String>): List<String> {
        val clean = candidates.filter { it.isNotBlank() && it != "0.0.0.0" && !it.contains(":") }.distinct()
        val prefixes = localIpv4s.mapNotNull { ip ->
            val parts = ip.split(".")
            if (parts.size == 4) parts.take(3).joinToString(".") else null
        }
        return clean.sortedBy { candidate -> if (prefixes.any { candidate.startsWith("$it.") }) 0 else 1 }
    }
}
