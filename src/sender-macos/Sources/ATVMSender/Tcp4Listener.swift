import Foundation

/// Yalnız IPv4 üzerinde çalışan küçük TCP kabul döngüsü.
///
/// Neden Network.framework değil: `NWListener(using: .tcp, on:)` bu makinede tek bir
/// IPv6 yuvası açtı (`lsof: TCP *:7610 (LISTEN)`, IPv4 kaydı yok) ve Android TV'den gelen
/// IPv4 SYN'leri sessizce düştü (ölçüldü: Mac'ten kendi LAN IP'ne bağlantı başarılı,
/// TV'den aynı porta 6 sn timeout). TV ile konuşan kanal IPv4 olmak zorunda.
final class Tcp4Listener: @unchecked Sendable {
    enum ListenerError: Error, CustomStringConvertible {
        case socket, bind(Int32), listen(Int32)
        var description: String {
            switch self {
            case .socket: return "socket açılamadı"
            case .bind(let e): return "port bağlanamadı (errno \(e)) — port kullanımda olabilir"
            case .listen(let e): return "listen başarısız (errno \(e))"
            }
        }
    }

    private var serverFd: Int32 = -1
    private var thread: Thread?
    private let queue = DispatchQueue(label: "atvm.tcp4", qos: .userInitiated)
    var onClient: ((Tcp4Connection) -> Void)?
    private(set) var port: UInt16 = 0

    func start(port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenerError.socket }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0))     // INADDR_ANY, yalnız IPv4
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let e = errno; close(fd); throw ListenerError.bind(Int32(e))
        }
        guard listen(fd, 8) == 0 else {
            let e = errno; close(fd); throw ListenerError.listen(Int32(e))
        }
        serverFd = fd
        self.port = port
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "atvm-accept"
        t.stackSize = 1 << 18
        t.start()
        thread = t
    }

    private func acceptLoop() {
        while serverFd >= 0 {
            var peer = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverFd, $0, &len)
                }
            }
            if cfd < 0 {
                if errno == EBADF || errno == EINVAL { return }
                continue
            }
            var noDelay: Int32 = 1
            setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
            let host = String(cString: inet_ntoa(peer.sin_addr))
            let conn = Tcp4Connection(fd: cfd, peerHost: host)
            queue.async { [weak self] in self?.onClient?(conn) }
        }
    }

    func stop() {
        if serverFd >= 0 { close(serverFd); serverFd = -1 }
    }
}

/// Tek bir istemciyle satır-temelli konuşma (JSON-lines).
final class Tcp4Connection: @unchecked Sendable {
    let peerHost: String
    private let fd: Int32
    private let writeLock = NSLock()

    /// Doğrulama öncesi sessiz kalan bağlantı bu sürede düşer (yavaş istemci dinleyiciyi tutamasın).
    static let preAuthReadTimeout: Int = 15
    /// Satır üst sınırı: satır sonu göndermeden veri yığan istemci belleği şişiremez.
    static let maxLineBytes = 8192

    init(fd: Int32, peerHost: String) {
        self.fd = fd; self.peerHost = peerHost
        setReadTimeout(seconds: Self.preAuthReadTimeout)
    }

    /// Doğrulanmış oturum uzun süre sessiz kalabilir (yalnız ara sıra idr_request): süre sınırı kalkar.
    func authenticated() { setReadTimeout(seconds: 0) }

    /// Okuyucu iş parçacığını uyandırır; soketi o kapatır (çift close olmasın).
    func close() { shutdown(fd, SHUT_RDWR) }

    private func setReadTimeout(seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// JSON-lines akışı. Sıra garantisi: her satır sırayla `yield` edilir,
    /// state machine (hello → challenge → proof → resume) buna dayanır.
    func messages() -> AsyncStream<[String: Any]> {
        let fd = self.fd
        return AsyncStream { continuation in
            let t = Thread {
                var buf = Data()
                var chunk = [UInt8](repeating: 0, count: 4096)
                reading: while true {
                    let n = read(fd, &chunk, chunk.count)
                    if n <= 0 { break }           // kapanış, hata ya da SO_RCVTIMEO
                    buf.append(contentsOf: chunk[0..<n])
                    while let nl = buf.firstIndex(of: 0x0A) {
                        let line = buf.subdata(in: buf.startIndex..<nl)
                        buf.removeSubrange(buf.startIndex...nl)
                        if line.count > Self.maxLineBytes { break reading }
                        if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                            continuation.yield(obj)
                        }
                    }
                    if buf.count > Self.maxLineBytes { break }
                }
                continuation.finish()
                shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
            }
            t.name = "atvm-reader"
            t.start()
        }
    }

    func send(_ obj: [String: Any?]) {
        var clean: [String: Any] = [:]
        for (k, v) in obj where v != nil { clean[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: clean) else { return }
        var line = data
        line.append(0x0A)
        writeLock.lock(); defer { writeLock.unlock() }
        line.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

}
