import Foundation
import Network

struct DiscoveredTV: CustomStringConvertible, Equatable {
    let name: String
    let host: String
    let controlPort: UInt16
    let mediaPort: UInt16
    /// Ad nereden geliyor: mDNS çözümlemesi / TV'nin kendi yoklama yanıtı / yalnız eşleşme kaydı.
    var source: Source = .record
    enum Source: String, Equatable { case resolved, presence, broadcast, record
        var label: String {
            switch self {
            case .resolved: return "mDNS"
            case .presence: return "yoklama"
            case .broadcast: return "yayın"
            case .record: return "kayıt"
            }
        }
    }
    /// mDNS yayını şu anda alındı mı — yani TV'de uygulama açık mı.
    var online = false
    /// TV kendi yoklama yanıtında "eşleşmişim" dedi mi (yalnız canlı satırlarda anlam taşır).
    var tvReportsPaired = false
    var description: String { "\(name) @ \(host):\(controlPort) (medya udp/\(mediaPort), \(source.label))" }
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
/// Ölçülen engeller:
/// 1) `NWBrowser` sonuçlarının ucu `.service(...)`, `.hostPort` değil → yalnız yayın **adı** gelir.
/// 2) `NetServiceBrowser` bu süreçte hiç `didFind` üretmedi (aynı ağda `dns-sd` ve
///    `NWBrowser` cihazı görürken 0 sonuç).
/// 3) Adres elde etmenin `NWBrowser` içindeki tek yolu `.service` ucuna TCP açmak; TV'nin kontrol
/// sunucusu tek kabul döngüsüyle çalıştığı için yoklama bağlantısı gerçek eşleştirmeyi bloke
/// ederdi. TXT kaydını okuyan API (`includeTxtRecord`) macOS 26'da var, hedeflediğimiz
/// sürümde yok.
/// 4) Adresi eşleşme kaydından okumak DHCP taşımasında çöküyor: ölçüldü (2026-10-15), TV bir
/// adresi bırakıp diğerine geçince liste **ölü adreste "açık"** satır gösterdi ve bağlantı
/// kurulamadı; sayısal olarak büyük adresi seçmek de yanlıştı (yaşayan adres daha küçük numaralıydı).
/// Bu yüzden adres sırasıyla kanıttan gelir: mDNS çözümlemesi (`DnsSdBrowser`) → TV'nin kendi UDP
/// yoklama yanıtı (`TvPresence`) → yalnız tek anlamlıysa eşleşme kaydı.
enum TvDiscovery {
    static let serviceType = "_atvm._tcp"
    /// TV aksini bildirmediğinde kullanılan varsayılan kanallar (alıcıda sabit).
    static let defaultControlPort: UInt16 = 7601
    static let defaultMediaPort: UInt16 = 7602

    static func browse(seconds: Double = 3) async -> [DiscoveredTV] {
        async let resolved = dnsSdEntries(seconds: seconds)
        async let broadcast = namesViaBonjour(seconds: seconds)
        let live = TvPresence.query()     // TV'ler yanıt verirken mDNS sorguları sürsün
        let (found, names) = (await resolved, await broadcast)
        var stored = KeyStore.names()
        // Adresi taşınmış kayıtlar önce düşürülür: hayalet satır bu turda da görünmesin.
        for host in staleHosts(live: live, resolved: found, stored: stored,
                               isPaired: { KeyStore.isPaired($0) }) {
            KeyStore.dropName(host)
            stored[host] = nil
        }
        return merge(resolved: found, live: live, broadcast: names, stored: stored)
    }

    /// Cihaza tek bayt göndermeden ad + adres + port çözer (bkz. DnsSdBrowser).
    static func dnsSdEntries(seconds: Double) async -> [DnsSdBrowser.Entry] {
        await Task.detached(priority: .utility) {
            DnsSdBrowser.resolve(type: serviceType, seconds: seconds)
        }.value
    }

    /// Yalnız yayın adları: `NWBrowser` adres vermediği için eşleşmiş kaydı tamamlar.
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
    /// Ad **benzersiz değildir** — alıcı yayın adını modelden üretiyor (`MainActivity.kt`:
    /// `"ATVM-\(Build.MODEL)"`), yani aynı modelden iki TV ya da adres değiştirmiş tek TV aynı adı
    /// taşır. Eski kod adı anahtar yaptığı benzersiz sözlüğe çeviriyordu (`uniqueKeysWithValues`)
    /// ve çakışmada süreç anında ölüyordu: ölçüldü, `paired_names.json`'da iki adres tek adı
    /// gösterirken uygulama açılışta SIGTRAP alıyordu ve bir daha açılmıyordu.
    static func merge(resolved: [DnsSdBrowser.Entry], live: [TvPresence.Reply], broadcast: [String],
                      stored: [String: String]) -> [DiscoveredTV] {
        var rows: [DiscoveredTV] = []
        var listed: Set<String> = []

        // 1) mDNS çözümlemesi: güncel adres + TV'nin kendi portu. Eşleşmiş kayıt varsa adı o verir.
        for entry in resolved where !entry.host.isEmpty && listed.insert(entry.host).inserted {
            let reported = stored[entry.host] ?? entry.instance
            rows.append(DiscoveredTV(name: reported, host: entry.host, controlPort: entry.port,
                                     mediaPort: defaultMediaPort, source: .resolved, online: true,
                                     tvReportsPaired: live.first { $0.host == entry.host }?.paired ?? false))
        }

        // 2) Yayını çözümlenememiş ama yoklamaya yanıt vermiş TV: adres ve port TV'nin kendi bildirimi.
        for reply in live where !reply.host.isEmpty && listed.insert(reply.host).inserted {
            rows.append(DiscoveredTV(name: reply.name, host: reply.host, controlPort: reply.controlPort,
                                     mediaPort: reply.mediaPort, source: .presence, online: true,
                                     tvReportsPaired: reply.paired))
        }

        // 3) Yalnız yayın adı biliniyor (NWBrowser) ve mDNS/yoklama adresi yok: eşleşmiş kayıt tek
        //    anlamlıysa onun adresini kullan, değilse **uydurma** — adresi boş bırak.
        let candidates = hostCandidates(stored: stored)
        for name in broadcast where !rows.contains(where: { $0.name == name || Self.normalize($0.name) == Self.normalize(name) }) {
            let all = candidates[Self.normalize(name)] ?? []
            let free = all.filter { !listed.contains($0) }
            // Yayının sahibi zaten listelenmişse bu satıra gerek yok; adres bilinmiyorsa uydurmayız.
            if free.isEmpty, all.isEmpty {
                rows.append(DiscoveredTV(name: name, host: "", controlPort: defaultControlPort,
                                         mediaPort: defaultMediaPort, source: .broadcast, online: true))
            } else if free.count > 1 {
                // Aynı ada sahip birden çok eşleşmiş adres: hangisinin canlı olduğu bilinemez.
                // Yanlış adresi "açık" göstermek ölü adrese bağladığı için adresiz satır bırakılır.
                rows.append(DiscoveredTV(name: name, host: "", controlPort: defaultControlPort,
                                         mediaPort: defaultMediaPort, source: .broadcast, online: true))
            } else if free.count == 1 {
                let host = free[0]
                listed.insert(host)
                rows.append(DiscoveredTV(name: stored[host] ?? name, host: host,
                                         controlPort: defaultControlPort, mediaPort: defaultMediaPort,
                                         source: .broadcast, online: true))
            }
        }

        // 4) Yayını olmayan ama daha önce eşleşmiş TV'ler de listelensin: kullanıcı IP yazmadan
        //    seçebilsin ve "eşleşmeyi kaldır" çalışsın.
        for (host, name) in stored.sorted(by: { $0.key < $1.key }) where !listed.contains(host) {
            rows.append(DiscoveredTV(name: name, host: host, controlPort: defaultControlPort,
                                     mediaPort: defaultMediaPort, source: .record))
        }
        // Ad + adres birlikte sıralanır: aynı ada sahip satırlar yan yana ve kararlı sırada dursun.
        return rows.sorted { ($0.name, $0.host) < ($1.name, $1.host) }
    }

    /// Ad → o adı taşıyan eşleşmiş adresler (artan sırada, kararlı). Ad benzersiz olmadığı için
    /// anahtar başına **tek** değer değil liste tutulur; `uniqueKeysWithValues` çakışmada trap atar.
    static func hostCandidates(stored: [String: String]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (host, name) in stored { out[normalize(name), default: []].append(host) }
        return out.mapValues { $0.sorted() }
    }

    /// Listeden düşülecek eskimiş ad kayıtları. Yalnız **kanıtla** silinir: TV adresini mDNS
    /// çözümlemesinde ya da ağ yoklamasında canlı bildirdiyse, aynı adı taşıyan ve o adres
    /// olmayan eşleşmesiz kayıtlar eski kiralamadır. Kanıt yoksa (TV kapalı, ya da Anahtar
    /// Zinciri geçici olarak okunamadı) hiçbir kayıt silinmez — `isPaired` her hatada false
    /// döndürdüğü için "eşleşmesiz" varsaymak yanıltıcı olurdu.
    static func staleHosts(live: [TvPresence.Reply], resolved: [DnsSdBrowser.Entry],
                           stored: [String: String], isPaired: (String) -> Bool) -> [String] {
        let currentHosts = Set(live.map(\.host) + resolved.map(\.host))
        let currentNames = Set(live.map { normalize($0.name) } + resolved.map { normalize($0.instance) })
        return stored.compactMap { (host, name) in
            guard !host.isEmpty, !currentHosts.contains(host), currentNames.contains(normalize(name)),
                  !isPaired(host) else { return nil }
            return host
        }.sorted()
    }

    static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        if t.hasPrefix("atvm-") { t.removeFirst(5) }
        return t.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
