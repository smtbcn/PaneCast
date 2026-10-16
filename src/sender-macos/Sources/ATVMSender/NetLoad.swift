import Foundation
import CoreWLAN

/// Ağ yükü matematiği — ölçüm kaynaklarından bağımsız, test edilebilir saf taraf.
///
/// Kural: okunamayan payda **0 değil nil** döner. "Wi-Fi hızı bilinmiyor → %0 dolu"
/// göstermek, boş bir hat var gibi rahatlatmak demekti (yanlış rahatlık).
enum NetMath {
    /// Sayaç farkından Mbps. İlk örnek yoksa, süre çok kısaysa ya da sayaç geriye
    /// düşmüşse (modem yeniden başlar, arayüz sıfırlanır) nil.
    static func mbps(previous: UInt64?, current: UInt64, seconds: Double) -> Double? {
        guard let p = previous, seconds > 0.05, current >= p else { return nil }
        return Double(current - p) * 8 / seconds / 1_000_000
    }

    /// Bir paydanın yüzdesi. Payda yok ya da anlamsız derecede küçükse nil;
    /// taşmasın diye %999'da kırpılır (yayın kapasiteyi aşarsa "999" gerçekçidir).
    static func share(part: Double?, of whole: Double?) -> Double? {
        guard let p = part, let w = whole, w > 0.05 else { return nil }
        return min(999, max(0, p / w * 100))
    }

    /// İki yönün toplamı; ikisi de nil ise nil.
    static func total(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case let (x?, y?): return x + y
        case let (x?, nil): return x
        case let (nil, y?): return y
        default: return nil
        }
    }
}

/// Yayının gittiği arabirimin işletim sayaçlarından Mbps üreten örnekleyici.
///
/// Arabirim adı tahmin edilmez: TV'nin adresine giden yoldaki yerel adres sorulur
/// (bağlı UDP soketi paket göndermez, yalnız yol çözer) ve o adresi taşıyan arabirim
/// bulunur. Böylece Wi-Fi/Ethernet/VPN karışıklığı çıkmaz.
@MainActor
final class InterfaceSampler {
    /// Hedef seçili değilken varsayılan yolu çözmek için kullanılan **belge adresi**
    /// (RFC 5737): gerçek bir cihaz değildir, soket bağlandığı için paket de gitmez.
    static let defaultRouteProbe = "203.0.113.9"

    private var lastIn: UInt64?
    private var lastOut: UInt64?
    private var lastAt: Date?
    private(set) var interfaceName: String?

    /// `peer` adresine giden arabirimin adı (en0 gibi); bulunamazsa nil.
    /// Bağlı UDP soketi paket GÖNDERMEZ, yalnız yönü çözer — bu yüzden hedefin gerçekten
    /// orada olması gerekmez; varsayılan yolu öğrenmek için RFC 5737 belge aralığı kullanılır.
    static func routeInterface(to peer: String) -> String? {
        guard var target = sockaddrStore(for: peer) else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let connected = withUnsafeMutablePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard named == 0, let myAddress = dottedQuad(&local.sin_addr) else { return nil }
        return interfaceAddresses().first { $0.address == myAddress }?.name
    }

    private static func sockaddrStore(for ip: String) -> sockaddr_in? {
        var storage = sockaddr_in()
        storage.sin_family = sa_family_t(AF_INET)
        storage.sin_port = in_port_t(9).bigEndian      // dokunulmaz: yalnız yön sorgulanıyor
        guard ip.withCString({ inet_pton(AF_INET, $0, &storage.sin_addr) }) == 1 else { return nil }
        return storage
    }

    private static func dottedQuad(_ addr: inout in_addr) -> String? {
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count)) != nil else { return nil }
        return String(cString: buf)
    }

    private static func interfaceAddresses() -> [(name: String, address: String)] {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return [] }
        defer { freeifaddrs(ifap) }
        var out: [(String, String)] = []
        var p = ifap
        while let i = p {
            let d = i.pointee
            if let sa = d.ifa_addr, sa.pointee.sa_family == AF_INET {
                var v4 = sa.pointee
                withUnsafeBytes(of: &v4) { raw in
                    var sin = raw.load(as: sockaddr_in.self)
                    if let a = dottedQuad(&sin.sin_addr) {
                        out.append((String(cString: d.ifa_name), a))
                    }
                }
            }
            p = d.ifa_next
        }
        return out
    }

    /// Arabirimin toplam alınan/gönderilen baytları (AF_LINK sayacı).
    static func counters(of iface: String) -> (inbound: UInt64, outbound: UInt64)? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }
        var p = ifap
        while let i = p {
            let d = i.pointee
            if let sa = d.ifa_addr, sa.pointee.sa_family == AF_LINK,
               String(cString: d.ifa_name) == iface, let data = d.ifa_data {
                let n = data.assumingMemoryBound(to: if_data.self).pointee
                return (UInt64(n.ifi_ibytes), UInt64(n.ifi_obytes))
            }
            p = d.ifa_next
        }
        return nil
    }

    /// Son çağrıdan bu yana Mbps; ilk çağrı nil (henüz fark yok).
    func sample(interface: String?) -> (inbound: Double?, outbound: Double?) {
        guard let interface, let now = InterfaceSampler.counters(of: interface) else { return (nil, nil) }
        interfaceName = interface
        let previousIn = lastIn, previousOut = lastOut, previousAt = lastAt
        lastIn = now.inbound; lastOut = now.outbound; lastAt = Date()
        guard let at = previousAt, let pi = previousIn, let po = previousOut else { return (nil, nil) }
        let dt = Date().timeIntervalSince(at)
        return (NetMath.mbps(previous: pi, current: now.inbound, seconds: dt),
                NetMath.mbps(previous: po, current: now.outbound, seconds: dt))
    }
}

/// Kablosuz bağlantının eşleşmiş fiziksel hızı: yayın bu havayolunu kullanıyor, dolayısıyla
/// "yayın hattı ne kadar dolduruyor" sorusunun doğru paydası budur. Kabloda nil döner.
enum WifiLink {
    static func rateMbps() -> Double? {
        guard let i = CWWiFiClient.shared().interface() else { return nil }
        // İlk çağrı 0 dönebiliyor (istemci henüz ısınmadan): 0 = bilinmiyor sayılır ve
        // arayüz % yerine "—" gösterir, uydurma %0 değil (ölçüldü: GUI'de ilk tur boş geldi).
        let r = i.transmitRate()
        return r > 0 ? Double(r) : nil
    }
}

/// Modemin WAN (internet) tarafının anlık yükü — UPnP IGD `WANCommonInterfaceConfig`.
///
/// Ölçülen gerçek: bu ağdaki modem kimlik sormadan `GetTotalBytesSent/Received` ve
/// `GetCommonLinkProperties` yanıtlıyor (kapasite ↓4/↑4 Mbps Cable ölçüldü).
/// **Yerel yayın WAN sayacına girmez** — Mac → TV trafiği modemin iç geçidinde kalır —
/// bu yüzden arayüzde "internet hattı" olarak etiketlenir. Modem yanıt vermezse durum
/// `unreachable` kalır ve sayı uydurulmaz. Geçiş adresi yalnız bellekte durur,
/// günlüğe ve depoya yazılmaz.
@MainActor
final class ModemLoad {
    enum State { case off, searching, unreachable, ready }

    private(set) var state: State = .off
    private(set) var accessType = "-"
    private(set) var capacityDownMbps: Double?
    private(set) var capacityUpMbps: Double?
    private(set) var wanDownMbps: Double?
    private(set) var wanUpMbps: Double?
    /// Kaç başarılı okuma turu yapıldı (ilk turda fark yoktur → "ölçülüyor" gösterilir).
    private(set) var rounds = 0

    private var controlURL: String?
    private var serviceType: String?
    private var lastSent: UInt64?
    private var lastRecv: UInt64?
    private var lastAt: Date?
    private var inFlight = false

    var onChange: (() -> Void)?

    var isEnabled: Bool { state != .off }

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        state = on ? .searching : .off
        rounds = 0
        controlURL = nil; serviceType = nil
        lastSent = nil; lastRecv = nil; lastAt = nil
        wanUpMbps = nil; wanDownMbps = nil
        capacityDownMbps = nil; capacityUpMbps = nil
        onChange?()
    }

    /// Bir tur: önce keşif, sonra sayaç + kapasite okuma. Eşzaman iki tur koşmaz.
    func poll() async {
        guard isEnabled, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        if controlURL == nil {
            guard let endpoint = await UpnpIgd.findGatewayConfig() else {
                if state != .unreachable { state = .unreachable; onChange?() }
                return
            }
            controlURL = endpoint.control
            serviceType = endpoint.service
            state = .ready
        }
        guard let control = controlURL, let service = serviceType else { return }
        // Modem iki ayrı eylemle yanıtlıyor: `GetTotalBytes` diye bir eylem yok
        // (ilk denemede bu ad kullanıldı → SOAP fault → "ulaşılamıyor" göründü).
        guard let sentText = await UpnpIgd.read(action: "GetTotalBytesSent", control: control, service: service,
                                                fields: ["NewTotalBytesSent"])?["NewTotalBytesSent"],
              let recvText = await UpnpIgd.read(action: "GetTotalBytesReceived", control: control, service: service,
                                                fields: ["NewTotalBytesReceived"])?["NewTotalBytesReceived"],
              let sent = UInt64(sentText), let recv = UInt64(recvText) else {
            if state == .ready { state = .unreachable; controlURL = nil; onChange?() }
            return
        }
        if capacityDownMbps == nil,
           let link = await UpnpIgd.read(action: "GetCommonLinkProperties", control: control, service: service,
                                         fields: ["NewWANAccessType", "NewLayer1DownstreamMaxBitRate",
                                                  "NewLayer1UpstreamMaxBitRate"]) {
            accessType = link["NewWANAccessType"] ?? "-"
            capacityDownMbps = link["NewLayer1DownstreamMaxBitRate"].flatMap { Double($0) }.map { $0 / 1_000_000 }
            capacityUpMbps = link["NewLayer1UpstreamMaxBitRate"].flatMap { Double($0) }.map { $0 / 1_000_000 }
        }
        rounds += 1
        let previousSent = lastSent, previousRecv = lastRecv, previousAt = lastAt
        lastSent = sent; lastRecv = recv; lastAt = Date()
        if let at = previousAt, let ps = previousSent, let pr = previousRecv {
            let dt = Date().timeIntervalSince(at)
            wanUpMbps = NetMath.mbps(previous: ps, current: sent, seconds: dt)
            wanDownMbps = NetMath.mbps(previous: pr, current: recv, seconds: dt)
            onChange?()
        }
    }
}

/// UPNP IGD konuşmasının ham tarafı: SSDP keşfi + SOAP okuma eylemleri.
/// Salt-okunur eylemler kullanılır (Get*); cihazın ayarına dokunulmaz.
enum UpnpIgd {
    struct Endpoint { let control: String; let service: String }

    private static let searchTarget = "urn:schemas-upnp-org:device:InternetGatewayDevice:1"

    /// SSDP M-SEARCH ile IGD arar; tanımını indirip `WANCommonInterfaceConfig`
    /// kontrol adresini döndürür. TV gibi IGD taklidi yapan cihazlar tanım
    /// doğrulamasında elenir.
    static func findGatewayConfig() async -> Endpoint? {
        for location in await searchLocations() {
            guard let xml = try? await get(URL(string: location)),
                  xml.contains("InternetGatewayDevice"),
                  let block = serviceBlock(xml, "WANCommonInterfaceConfig"),
                  let control = tag(block, "controlURL"),
                  let service = tag(block, "serviceType") else { continue }
            return Endpoint(control: absolute(control, base: location), service: service)
        }
        return nil
    }

    private static func searchLocations() async -> [String] {
        await withCheckedContinuation { (k: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .utility).async {
                let request = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"
                    + "MAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(searchTarget)\r\n\r\n"
                var found: [String] = []
                let fd = socket(AF_INET, SOCK_DGRAM, 0)
                defer { close(fd) }
                guard fd >= 0 else { k.resume(returning: []); return }
                var tv = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var dest = sockaddr_in()
                dest.sin_family = sa_family_t(AF_INET)
                dest.sin_port = in_port_t(1900).bigEndian
                inet_pton(AF_INET, "239.255.255.250", &dest.sin_addr)
                request.withCString { ptr in
                    _ = withUnsafePointer(to: &dest) { sa in
                        sa.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, ptr, strlen(ptr), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                var buf = [UInt8](repeating: 0, count: 2048)
                for _ in 0 ..< 8 {
                    var from = sockaddr_in()
                    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let n = withUnsafeMutablePointer(to: &from) { sa in
                        sa.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(fd, &buf, buf.count, 0, $0, &len)
                        }
                    }
                    guard n > 0 else { break }
                    let text = String(decoding: buf[0 ..< Int(n)], as: UTF8.self)
                    for line in text.split(whereSeparator: \.isNewline) where line.lowercased().hasPrefix("location:") {
                        let url = line.lowercased().replacingOccurrences(of: "location:", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        if !found.contains(url) { found.append(url) }
                    }
                }
                k.resume(returning: found)
            }
        }
    }

    /// SOAP eylemini çağırıp istenen dönüş alanlarını okur.
    static func read(action: String, control: String, service: String, fields: [String]) async -> [String: String]? {
        guard let url = URL(string: control) else { return nil }
        let body = """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"\
         s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
        <u:\(action) xmlns:u="\(service)"/></s:Body></s:Envelope>
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var out: [String: String] = [:]
        for f in fields { if let v = tag(text, f), !v.isEmpty { out[f] = v } }
        return out.isEmpty ? nil : out
    }

    private static func get(_ url: URL?) async throws -> String {
        guard let url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(decoding: data, as: UTF8.self)
    }

    /// Servis bloğu seçimi: testten de erişilebilir (kural test ediliyor, kopyalanmıyor).
    static func serviceBlock(_ xml: String, _ needle: String) -> String? {
        for rest in xml.components(separatedBy: "<service>").dropFirst() {
            guard let end = rest.range(of: "</service>") else { continue }
            let block = String(rest[..<end.lowerBound])
            if block.contains(needle) { return block }
        }
        return nil
    }

    static func tag(_ text: String, _ name: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound ..< close.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    private static func absolute(_ path: String, base: String) -> String {
        if path.hasPrefix("http") { return path }
        // Port KORUNUR: bu modem kontrol uçlarını web arayüzüyle aynı yerde değil,
        // SSDP'in de geldiği 1900 numaralı kapıda tutuyor. `url.host` ile kurulursa
        // istek 80'e düşer ve modem "405 Method Not Allowed" der (ölçüldü).
        guard let url = URLComponents(string: base), let host = url.host else { return path }
        let root = "\(url.scheme ?? "http")://\(host)" + (url.port.map { ":\($0)" } ?? "")
        return root + (path.hasPrefix("/") ? path : "/" + path)
    }
}
