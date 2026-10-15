import Foundation
import CDnsSD

/// mDNS kayıtlarını **cihazın kapısını çalmadan** çözer: browse → resolve (hedef ad + port) →
/// A kaydı (IPv4). Üç soru da sistemin mDNS yanıtlayıcısına gider; TV'ye tek bayt gitmez, bu
/// yüzden TV'nin tek kabul döngülü kontrol sunucusu meşgul olmaz.
///
/// Neden gerekli (ölçüldü 2026-10-15, 22:54): TV'nin adresini yalnız iki kaynak verebiliyordu —
/// eşleşme kaydı ve TV'nin UDP yoklama yanıtı. TV adresini değiştirince eşleşme kaydı eski adresi
/// tutuyor, yoklama da yanıt vermeyince liste **ölü adreste "açık" satır** gösterip bağlantıyı
/// düşürüyordu. Yayın tek başına adres vermiyordu: `NWBrowser` yalnız yayın adı döndürüyor, TXT
/// okuma API'si hedeflenen macOS sürümünde yok. `dns-sd` aynı ağda cihazı görüyordu (ölçüldü:
/// `_airplay._tcp` yayını bu Mac'ten anında çözümlendi) → C API'si doğrudan kullanılıyor.
///
/// Kalan tek adres kaynağı olarak değil: `TvPresence` (TV'nin kendi yanıtı) kimlik kanıtı taşır,
/// bu çözümleyici ise eşleşmemiş bir TV'yi de adresiyle birlikte listeye getirir.
final class DnsSdBrowser: @unchecked Sendable {
    struct Entry: Equatable { let instance: String, host: String, port: UInt16 }

    private let lock = NSLock()
    private var targets: [String: (host: String, port: UInt16)] = [:]   // yayın adı → hedef ad
    private var addresses: [String: String] = [:]                       // hedef ad → IPv4
    /// "_atvm._tcp.local." — `DNSServiceResolve` tam servis adını döndürdüğü için yayın adına
    /// indirgemede kullanılır; ilk browse yanıtından bir kez yazılır.
    private var serviceSuffix = ""
    private var connection: DNSServiceRef?
    /// "Neden adres gelmedi?" sorusunu kullanıcıya söyleyebilmek için aşama kayıtları.
    private var notesLog: [String] = []

    func note(_ s: String) {
        lock.lock(); notesLog.append(s); let f = onNote; lock.unlock()
        f?(s)
    }
    var notes: [String] { lock.lock(); defer { lock.unlock() }; return notesLog }

    /// `type` yayınlarını `seconds` boyunca izler; çözümlenebildiklerini döndürür.
    /// Engelleyici (blocking) çağrı: ağ bekleme süresi kadar sürer, bu yüzden GUI'de
    /// ana iş parçasından değil, `browse` gibi bir arka plan görevinden çağrılır.
    static func resolve(type: String, seconds: Double, notes: ((String) -> Void)? = nil) -> [Entry] {
        let b = DnsSdBrowser()
        b.onNote = notes
        b.start(type: type)
        b.pump(seconds: seconds)
        b.stop()
        return b.snapshot()
    }

    var onNote: ((String) -> Void)?

    private func start(type: String) {
        var ref: DNSServiceRef?
        let created = DNSServiceCreateConnection(&ref)
        guard created == kDNSServiceErr_NoError, let conn = ref else {
            note("dns_sd: paylaşımlı bağlantı açılamadı (hata \(created))")
            return
        }
        connection = conn
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        // Paylaşımlı bağlantıda her alt sorgu, üst kopyasının kendi değişkeniyle açılır (dns_sd.h
        // §"Sharing"desi: `BrowseRef = SharedRef;` sonra `DNSServiceBrowse(&BrowseRef, ShareConnection…)`).
        var sub: DNSServiceRef? = conn
        type.withCString { reg in
            "local.".withCString { dom in
                let e = DNSServiceBrowse(&sub, kDNSServiceFlagsShareConnection, 0, reg, dom, dnsSdBrowseReply, ctx)
                if e != kDNSServiceErr_NoError { note("dns_sd: browse başarısız (hata \(e))"); connClose() }
            }
        }
    }

    private func stop() { connClose() }

    private func connClose() {
        lock.lock(); let c = connection; connection = nil; lock.unlock()
        if let c { DNSServiceRefDeallocate(c) }
    }

    /// Olayları `seconds` boyunca işler: dns_sd sonuçları soketten okunur.
    private func pump(seconds: Double) {
        guard let fd = connection.map(DNSServiceRefSockFD), fd >= 0 else { return }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let left = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, min(left, 200)) > 0 else { continue }
            guard (pfd.revents & Int16(POLLIN)) != 0 else { continue }
            // Paylaşımlı bağlantıda tüm alt sorgular aynı yuvadan gelir.
            guard let conn = connectionRef() else { return }
            if DNSServiceProcessResult(conn) != kDNSServiceErr_NoError { return }
        }
    }

    private func connectionRef() -> DNSServiceRef? {
        lock.lock(); defer { lock.unlock() }
        return connection
    }

    fileprivate func addBrowse(name: String, regtype: String, domain: String, index: UInt32, on: Bool) {
        // `DNSServiceResolve` geri çağrısı tam servis adını veriyor ("ATVM-X._atvm._tcp.local.");
        // NWBrowser ise yalnız yayını veriyor ("ATVM-X"). Liste aynı cihazı iki satır göstermesin
        // diye ikisi de yayın adına indirgenir.
        let suffix = (regtype.hasSuffix(".") ? regtype : regtype + ".")
            + (domain.hasSuffix(".") ? domain : domain + ".")
        lock.lock()
        if serviceSuffix.isEmpty { serviceSuffix = suffix }
        let known = targets[name] != nil
        if !on { targets[name] = nil }
        lock.unlock()
        guard on, !known else { return }
        // Paylaşımlı bağlantıda alt sorgular YALNIZ üst (parent) DNSServiceRef kopyasından açılır;
        // geri çağrının `call` parametresi alt bağlantıdır ve ondan açılan sorgu
        // kDNSServiceErr_BadParam (-65541) veriyor (ölçüldü).
        guard let parent = connectionRef() else { note("dns_sd: bağlantı kapanmış, resolve atlandı (\(name))"); return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var sub: DNSServiceRef? = parent
        let e = name.withCString { n in
            regtype.withCString { t in
                domain.withCString { d in
                    DNSServiceResolve(&sub, kDNSServiceFlagsShareConnection, index, n, t, d, dnsSdResolveReply, ctx)
                }
            }
        }
        if e != kDNSServiceErr_NoError { note("dns_sd: resolve istenemedi (\(name), hata \(e))") }
    }

    fileprivate func resolved(name: String, target: String, port: UInt16, index: UInt32) {
        let host = Self.trimDot(target)
        let instance = instance(fromFullname: name)
        lock.lock(); targets[instance] = (host, port); lock.unlock()
        note("dns_sd: \(instance) → \(host):\(port)")
        guard let parent = connectionRef() else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var sub: DNSServiceRef? = parent
        let e = target.withCString { t in
            DNSServiceQueryRecord(&sub, kDNSServiceFlagsShareConnection | kDNSServiceFlagsTimeout,
                                  index, t, UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                                  dnsSdQueryReply, ctx)
        }
        if e != kDNSServiceErr_NoError { note("dns_sd: A kaydı istenemedi (\(host), hata \(e))") }
    }

    fileprivate func address(hostTarget: String, address: String) {
        let host = Self.trimDot(hostTarget)
        // Aynı hedef adı birden çok A kaydı döndürebilir (127.0.0.1, arayüz adresleri):
        // kullanılabilir olan kazanır, döngü içi yalnız son çare olarak kalır.
        let usable = !address.hasPrefix("127.") && !address.hasPrefix("169.254.")
        lock.lock()
        if usable || addresses[host] == nil { addresses[host] = address }
        lock.unlock()
        note("dns_sd: \(host) → \(address)")
    }

    /// "ATVM-X._atvm._tcp.local." → "ATVM-X"; sonek eşleşmezse ad olduğu gibi kalır.
    private func instance(fromFullname full: String) -> String {
        lock.lock(); let suffix = serviceSuffix; lock.unlock()
        guard !suffix.isEmpty, full.hasSuffix(suffix) else { return Self.trimDot(full) }
        return String(full.dropLast(suffix.count + 1))   // baştaki nokta da gitsin
    }

    /// Yayın adı + hedef ad + port üçlüsünü birleştirir; adresi çözülememiş yayın düşürülür.
    private func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return targets.compactMap { (name, t) in
            addresses[t.host].map { Entry(instance: name, host: $0, port: t.port) }
        }.sorted { $0.instance < $1.instance }
    }

    /// dns_sd hedef adları nokta ile bitirir ("tv.local."); A kaydı yanıtı da bitiriyor ama
    /// eşleştirmeyi iki uçta da aynı biçime indirgemek pahalı bir hatayı önler.
    static func trimDot(_ s: String) -> String { s.hasSuffix(".") ? String(s.dropLast()) : s }
}

// MARK: - C geri çağrıları (bağlam yakalayamaz; `context` üzerinden nesneye dönülür)

private func browser(_ ctx: UnsafeMutableRawPointer?) -> DnsSdBrowser? {
    ctx.map { Unmanaged<DnsSdBrowser>.fromOpaque($0).takeUnretainedValue() }
}

private let dnsSdBrowseReply: DNSServiceBrowseReply = { _, flags, index, error, name, regtype, domain, ctx in
    guard let name, let regtype, let domain, let b = browser(ctx) else { return }
    if error != kDNSServiceErr_NoError { b.note("dns_sd: browse yanıtında hata \(error)"); return }
    let str = { (p: UnsafePointer<CChar>) -> String in String(cString: p) }
    b.addBrowse(name: str(name), regtype: str(regtype), domain: str(domain),
                index: index, on: (flags & kDNSServiceFlagsAdd) != 0)
}

private let dnsSdResolveReply: DNSServiceResolveReply = { _, _, index, error, fullName, hostTarget,
                                                             port, _, _, ctx in
    // Bu dns_sd başlığında ayrı "Reply" bayrağı yok; tek yanıt gelir ve yinelenirse ezilir.
    guard let fullName, let hostTarget, let b = browser(ctx) else { return }
    if error != kDNSServiceErr_NoError { b.note("dns_sd: resolve hatası \(error)"); return }
    // Port ağ sıralı (big-endian) gelir.
    b.resolved(name: String(cString: fullName), target: String(cString: hostTarget),
               port: UInt16(bigEndian: port), index: index)
}

private let dnsSdQueryReply: DNSServiceQueryRecordReply = { _, _, _, error, fullName, rtype,
                                                            _, rdLen, rd, _, ctx in
    guard let fullName, let b = browser(ctx) else { return }
    if error != kDNSServiceErr_NoError { b.note("dns_sd: A kaydı yanıtı hata \(error)"); return }
    guard rtype == UInt16(kDNSServiceType_A), rdLen == 4, let rd else { return }
    let bytes = Data(bytes: rd, count: 4)
    b.address(hostTarget: String(cString: fullName),
              address: bytes.map(String.init).joined(separator: "."))
}
