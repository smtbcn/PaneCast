import Foundation
import Network

struct DiscoveredTV: CustomStringConvertible {
    let name: String
    let host: String
    let controlPort: UInt16
    let mediaPort: UInt16
    /// mDNS yayını şu anda alındı mı — yani TV'de uygulama açık mı.
    var online = false
    var description: String { "\(name) @ \(host):\(controlPort) (medya udp/\(mediaPort))" }
    var reachable: Bool { !host.isEmpty }
    /// mDNS yayını "ATVM-Vestel_Google_TV" gibi gelir; arayüzde okunaklı hali gösterilir.
    var displayName: String {
        var s = name
        if s.hasPrefix("ATVM-") { s.removeFirst(5) }
        return s.replacingOccurrences(of: "_", with: " ")
    }
}

/// mDNS ile TV alıcımızı arar (keşif için sabit IP gerekmez).
///
/// Ölçülen iki engel:
/// 1) `NWBrowser` sonuçlarının ucu `.service(...)`, `.hostPort` değil → eski kod hiç kayıt
///    saklamıyor, arayüz "TV bulunamadı" diyordu.
/// 2) `NetServiceBrowser` bu süreçte hiç `didFind` üretmedi (aynı ağda `dns-sd` ve
///    `NWBrowser` cihazı görürken 0 sonuç).
/// Adres elde etmenin `NWBrowser` içindeki tek yolu `.service` ucuna TCP açmak; TV'nin kontrol
/// sunucusu tek kabul döngüsüyle çalıştığı için yoklama bağlantısı gerçek eşleştirmeyi bloke
/// ederdi. TXT kaydını okuyan API (`includeTxtRecord`) macOS 26'da var, hedeflediğimiz
/// sürümde yok. Bu yüzden: yayın adları taranır, adres eşleşmiş kayıttan gelir — TV bu
/// bilgisayara bir kez bağlandığında adı ve IP'si saklanır ve listeden seçilebilir olur.
enum TvDiscovery {
    static let serviceType = "_atvm._tcp"

    static func browse(seconds: Double = 3) async -> [DiscoveredTV] {
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: "local."), using: .tcp)
        var names: [String] = []
        let lock = NSLock()

        browser.browseResultsChangedHandler = { (results: Set<NWBrowser.Result>, _) in
            lock.lock(); defer { lock.unlock() }
            names = results.compactMap {
                if case let .service(name, _, _, _) = $0.endpoint { return name }
                return nil
            }
        }
        browser.start(queue: DispatchQueue(label: "atvm.browse"))
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        browser.cancel()

        lock.lock(); let found = names; lock.unlock()

        // Ağ yoklaması adresin asıl kaynağıdır: eşleşme silinse bile TV bulunabilir kalır.
        let present = TvPresence.query()
        var out: [DiscoveredTV] = present.map {
            DiscoveredTV(name: $0.name, host: $0.host, controlPort: $0.controlPort,
                         mediaPort: $0.mediaPort, online: true)
        }
        let known = KeyStore.names()                       // host → TV adı
        let byName = Dictionary(uniqueKeysWithValues: known.map { (Self.normalize($0.value), $0.key) })
        for name in found where !out.contains(where: { Self.normalize($0.name) == Self.normalize(name) }) {
            // mDNS yayını "ATVM-Vestel_Google_TV", TV'nin kendi bildirdiği ad "Vestel Google TV":
            // eşleşme ancak biçim farkı giderilirse bulunur (ölçüldü: ikisi farklı geliyordu).
            let host = byName[Self.normalize(name)] ?? ""
            // TV'nin kendi bildirdiği ad (hello/name) mDNS yayın kimliğinden daha doğru:
            // "ATVM-Vestel_Google_TV" yerine "Vestel Google TV" gösterilir.
            let reported = host.isEmpty ? nil : known[host]
            out.append(DiscoveredTV(name: reported ?? name, host: host, controlPort: 7601,
                                    mediaPort: 7602, online: true))
        }
        // Yayını olmayan ama daha önce eşleşmiş TV'ler de listelensin: kullanıcı IP yazmadan seçebilsin.
        for (host, name) in known where !out.contains(where: { $0.host == host }) {
            out.append(DiscoveredTV(name: name, host: host, controlPort: 7601, mediaPort: 7602, online: false))
        }
        return out.sorted { $0.name < $1.name }
    }

    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        if t.hasPrefix("atvm-") { t.removeFirst(5) }
        return t.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
