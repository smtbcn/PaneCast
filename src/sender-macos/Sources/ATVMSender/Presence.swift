import Foundation

/// Ağ yoklaması (UDP 7611): TV'nin adresini eşleşme kaydına ihtiyaç duymadan bulur.
///
/// Neden gerekli (ölçüldü): adres yalnız eşleşme kaydından okunuyordu; kullanıcı
/// "eşleştirmeyi unut" deyince adres de silindi ve yeniden eşleşmek için adres
/// gerekiyordu — tavuk-yumurta. Mac artık ağa `find` yayımlıyor, açık olan her alıcı
/// kendi adını + IPv4'ünü tek seferlik geri yazıyor.
enum TvPresence {
    static let port: UInt16 = 7611

    struct Reply {
        let name: String
        let host: String
        let controlPort: UInt16
        let mediaPort: UInt16
        let paired: Bool
    }

    /// `find` yayınlar ve `seconds` boyunca gelen yanıtları toplar.
    static func query(seconds: Double = 1.5) -> [Reply] {
        var out: [String: Reply] = [:]
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { Darwin.close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Yanıtların döneceği yuvayı bağla; doluysa geçici portla devam et.
        var me = sockaddr_in()
        me.sin_family = sa_family_t(AF_INET)
        me.sin_port = port.bigEndian
        me.sin_addr = in_addr(s_addr: in_addr_t(0))
        _ = withUnsafePointer(to: &me) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }

        // `name` da yazılır: alıcı, bu paketi *kaynak adresinden* tanıyıp kendisine ulaşılabilen
    // adresi öğrensin (çok arayüzlü Mac'te mDNS A kaydı yanlış arayüzü verebiliyor — ölçüldü).
    let payload = Data(#"{"t":"find","name":"\#(HostName.current)"}"#.utf8)
        func shout() {
            var to = sockaddr_in()
            to.sin_family = sa_family_t(AF_INET)
            to.sin_port = port.bigEndian
            to.sin_addr = in_addr(s_addr: in_addr_t(0xFFFFFFFF))   // 255.255.255.255
            _ = payload.withUnsafeBytes { raw in
                withUnsafePointer(to: &to) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        shout()
        let deadline = Date().addingTimeInterval(seconds)
        var buffer = [UInt8](repeating: 0, count: 1024)
        var shoutedTwice = false
        while true {
            let remainingMs = Int32(deadline.timeIntervalSinceNow * 1000)
            if remainingMs <= 0 { break }
            // select() kullanılamaz: FD_SET makro olarak tanımlı ve Swift'e görünmüyor.
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, remainingMs) > 0 else { break }
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0, let obj = try? JSONSerialization.jsonObject(with: Data(buffer[0..<n])) as? [String: Any],
                  (obj["t"] as? String) == "tv", let host = obj["ip"] as? String else { continue }
            out[host] = Reply(name: (obj["name"] as? String) ?? host, host: host,
                              controlPort: UInt16((obj["cport"] as? Int) ?? 7601),
                              mediaPort: UInt16((obj["mport"] as? Int) ?? 7602),
                              paired: (obj["paired"] as? Bool) ?? false)
            if !shoutedTwice && deadline.timeIntervalSinceNow > 0.4 {
                shout(); shoutedTwice = true    // geç uyanan cihazlar için ikinci tur
            }
        }
        return out.values.sorted { $0.name < $1.name }
    }
}
