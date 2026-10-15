import Foundation
import Network

struct DiscoveredTV: CustomStringConvertible, Equatable {
    let name: String
    let host: String
    let controlPort: UInt16
    let mediaPort: UInt16
    /// mDNS yayını şu anda alındı mı — yani TV'de uygulama açık mı.
    var online = false
    /// TV kendi yoklama yanıtında "eşleşmişim" dedi mi (yalnız canlı satırlarda anlam taşır).
    var tvReportsPaired = false
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
    /// TV aksini bildirmediğinde kullanılan varsayılan kanallar (alıcıda sabit).
    static let defaultControlPort: UInt16 = 7601
    static let defaultMediaPort: UInt16 = 7602

    static func browse(seconds: Double = 3) async -> [DiscoveredTV] {
        let broadcast = await namesViaBonjour(seconds: seconds)
        let live = TvPresence.query()
        var stored = KeyStore.names()
        // Adresi taşınmış kayıtlar önce düşürülür: hayalet satır bu turda da görünmesin.
        for host in staleHosts(live: live, stored: stored, isPaired: { KeyStore.isPaired($0) }) {
            KeyStore.dropName(host)
            stored[host] = nil
        }
        return merge(live: live, broadcast: broadcast, stored: stored)
    }

    /// Yalnız ağ işini yapan kısmı: mDNS'te görünen yayın adları (sıra garanti edilmez).
    static func namesViaBonjour(seconds: Double) async -> [String] {
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

        lock.lock(); defer { lock.unlock() }
        return names.sorted()
    }

    /// Liste satırlarını ağ + kayıt verilerinden üretir. I/O ve anahtar çakışması yok:
    /// bellekte kurulabildiği için birim testi vardır.
    ///
    /// Ad **benzersiz değildir** — aynı modelden iki TV ya da adres değiştirmiş tek TV aynı adı
    /// taşır. Eski kod adı anahtar yaptığı benzersiz sözlüğe çeviriyordu (`uniqueKeysWithValues`)
    /// ve çakışmada süreç anında ölüyordu: ölçüldü, `paired_names.json`'da iki adres tek adı
    /// gösterirken uygulama açılışta SIGTRAP alıyordu ve bir daha açılmıyordu.
    static func merge(live: [TvPresence.Reply], broadcast: [String],
                      stored: [String: String]) -> [DiscoveredTV] {
        var rows: [DiscoveredTV] = []
        var listed: Set<String> = []

        // 1) Ağ yoklaması adresin asıl kaynağıdır: eşleşme silinse bile TV bulunabilir kalır,
        //    hem de TV'nin kendi bildirdiği portlarla.
        for reply in live where !reply.host.isEmpty && listed.insert(reply.host).inserted {
            rows.append(DiscoveredTV(name: reply.name, host: reply.host,
                                     controlPort: reply.controlPort, mediaPort: reply.mediaPort,
                                     online: true, tvReportsPaired: reply.paired))
        }

        // 2) Yayını alınıp yoklamada yanıt vermeyen TV: adresini eşleşmiş kayıttan bul.
        let candidates = hostCandidates(stored: stored)
        for name in broadcast where !rows.contains(where: { $0.name == name || Self.normalize($0.name) == Self.normalize(name) }) {
            guard let host = candidates[Self.normalize(name)]?.first else {
                // Adresini hiç bilmediğimiz yayın: satır yine görünsün — TV yayında ama bu Mac
                // onu hiç eşleştirmemiş (ya da eşleşme silinmiş).
                rows.append(DiscoveredTV(name: name, host: "", controlPort: defaultControlPort,
                                         mediaPort: defaultMediaPort, online: true))
                continue
            }
            // En olası aday zaten listedeyse bu yayın O cihazındır: ikinci (eskimiş) adayına
            // satır uydurmak yerine yayını atlıyoruz.
            if listed.contains(host) { continue }
            // TV'nin kendi bildirdiği ad (hello/name) mDNS yayın kimliğinden daha doğru:
            // "ATVM-Vestel_Google_TV" yerine "Vestel Google TV" gösterilir.
            listed.insert(host)
            rows.append(DiscoveredTV(name: stored[host] ?? name, host: host,
                                     controlPort: defaultControlPort, mediaPort: defaultMediaPort,
                                     online: true))
        }

        // Yayını olmayan ama daha önce eşleşmiş TV'ler de listelensin: kullanıcı IP yazmadan
        // seçebilsin ve "eşleşmeyi kaldır" çalışsın.
        for (host, name) in stored.sorted(by: { $0.key < $1.key }) where !listed.contains(host) {
            rows.append(DiscoveredTV(name: name, host: host, controlPort: defaultControlPort,
                                     mediaPort: defaultMediaPort, online: false))
        }
        // Ad + adres birlikte sıralanır: aynı ada sahip satırlar yan yana ve kararlı sırada dursun.
        return rows.sorted { ($0.name, $0.host) < ($1.name, $1.host) }
    }

    /// Ad → aday adresler, en olası başta. Anahtar normalize edilmiş ad; değer listedir,
    /// çünkü ad benzersiz değil (yukarıya bak).
    static func hostCandidates(stored: [String: String]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (host, name) in stored { out[normalize(name), default: []].append(host) }
        return out.mapValues { $0.sorted(by: newerHost) }
    }

    /// TV adını adres taşıyamaz: alıcı yayını `"ATVM-\(Build.MODEL)"` üretiyor (MainActivity.kt),
    /// yani aynı modeldeki iki cihaz aynı adı basar. Bu yüzden eşleşme kayıtları adres üzerinden
    /// tutulur ve ad yalnız gösterim etiketidir; çakışma artık durum değil, beklenen hâl.
    ///
    /// Tercih (sezgisel, kanıt değil): aynı ada sahip kayıtlarda sayısal olarak büyük adres,
    /// çünkü ev DHCP havuzları kiralama büyüdükçe ilerliyor. Adresi kesin bilen kaynak canlı ağ
    /// yoklamasıdır; bu sıralama yalnız ağda yanıt yokken hangi eski kaydın deneneceğini
    /// kararlı kılar. IPv4 değilse sözlük sırası kullanılır.
    static func newerHost(_ a: String, _ b: String) -> Bool {
        switch (ipv4(a), ipv4(b)) {
        case let (x?, y?): return x != y ? x > y : a < b
        case (.some, .none): return true     // protokolle konuşabilen adresler önce
        case (.none, .some): return false
        case let (.none, .none): return a < b
        }
    }

    /// Adresi taşınmış eskimiş ad kayıtları. Yalnız **kanıtla** silinir: TV kendi adresini ağ yoklamasında
    /// canlı bildirdiyse, aynı adı taşıyan ve o adres olmayan eşleşmesiz kayıtlar eski kiralamadır.
    /// Kanıt yoksa (TV kapalı, ya da Anahtar Zinciri geçici olarak okunamadı) hiçbir kayıt silinmez —
    /// `isPaired` her hatada false döndürdüğü için "eşleşmesiz" varsaymak yanıltıcı olurdu.
    static func staleHosts(live: [TvPresence.Reply], stored: [String: String],
                           isPaired: (String) -> Bool) -> [String] {
        let liveHosts = Set(live.map(\.host))
        let liveNames = Set(live.map { normalize($0.name) })
        return stored.compactMap { (host, name) in
            guard !host.isEmpty, !liveHosts.contains(host), liveNames.contains(normalize(name)),
                  !isPaired(host) else { return nil }
            return host
        }.sorted()
    }

    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        if t.hasPrefix("atvm-") { t.removeFirst(5) }
        return t.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func ipv4(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var n: UInt32 = 0
        for part in parts {
            guard let octet = UInt32(part), octet < 256 else { return nil }
            n = (n << 8) | octet
        }
        return n
    }
}
