import Foundation
import XCTest
@testable import atvm_sender

/// 7610 (TV → Mac) el sıkışması v2: karşılıklı kanıt, sürüm reddi, doğrulanmamış `stop`un yayına dokunmaması.
/// Anahtar Zinciri kullanılmaz: anahtar enjekte edilir.
@MainActor
final class SenderServerTests: XCTestCase {
    let key = Data(repeating: 0x5A, count: 32)

    private func client(_ port: UInt16) throws -> (FileHandle, LineIn) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(rc, 0)
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return (h, LineIn(fd: fd))
    }

    private func send(_ h: FileHandle, _ o: [String: Any]) {
        var d = try! JSONSerialization.data(withJSONObject: o); d.append(0x0A)
        h.write(d)
    }

    private func server(stops: @escaping (String) -> Void) -> (SenderServer, UInt16) {
        let s = SenderServer(keyFor: { [key] host in host == "127.0.0.1" ? key : nil })
        s.onTvStop = stops
        let port = UInt16.random(in: 48_001...49_000)
        s.start(port: port, advertise: false)
        return (s, port)
    }

    func testMutualProofAndAuthenticatedStop() async throws {
        var stopped: [String] = []
        let (srv, port) = server { stopped.append($0) }
        defer { srv.stop() }
        let (h, input) = try client(port)
        send(h, ["t": "hello", "role": "receiver", "name": "test-tv", "ver": 2])
        let ch = try await input.next()
        XCTAssertEqual(ch["t"] as? String, "challenge")
        XCTAssertEqual(ch["ver"] as? Int, 2)
        let nonceMac = Data(base64Encoded: ch["nonce_mac"] as! String)!
        let nonceTv = PairingCrypto.randomNonce()
        let proof = PairingCrypto.sessionProof(key, .reverse, .tv, serverNonce: nonceMac, clientNonce: nonceTv)
        send(h, ["t": "proof", "nonce_tv": nonceTv.base64EncodedString(), "proof": proof.base64EncodedString()])
        let ready = try await input.next()
        XCTAssertEqual(ready["t"] as? String, "ready")
        let macProof = Data(base64Encoded: ready["proof"] as? String ?? "")
        XCTAssertEqual(macProof, PairingCrypto.sessionProof(key, .reverse, .mac, serverNonce: nonceMac, clientNonce: nonceTv))
        send(h, ["t": "stop"])
        let st = try await input.next()
        XCTAssertEqual(st["t"] as? String, "stopped")
        XCTAssertEqual(stopped, ["127.0.0.1"])
    }

    func testWrongProofIsDeniedAndUnauthenticatedStopIgnored() async throws {
        var stopped: [String] = []
        let (srv, port) = server { stopped.append($0) }
        defer { srv.stop() }
        let (h, input) = try client(port)
        send(h, ["t": "stop"])                                       // doğrulamasız
        let first = try await input.next()
        XCTAssertEqual(first["reason"] as? String, "unexpected_message")
        send(h, ["t": "hello", "role": "receiver", "name": "x", "ver": 2])
        _ = try await input.next()
        send(h, ["t": "proof", "nonce_tv": PairingCrypto.randomNonce().base64EncodedString(),
                 "proof": Data(repeating: 0, count: 32).base64EncodedString()])
        let denied = try await input.next()
        XCTAssertEqual(denied["reason"] as? String, "auth_failed")
        let after = try? await input.next()
        XCTAssertNil(after)                                          // sunucu bağlantıyı kapattı
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(stopped, [])                                  // kapanış yayını durdurmadı
    }

    /// TV yayını **kendi başına** kestiğinde (kumandadan DURDUR) Mac'e `stopped` yazar.
    /// Ölçülen kusur: bu mesaj hiç gönderilmiyordu; Mac "Yayında" kalıp pencereyi ağa
    /// yazmayı sürdürüyordu. Mac yanıt olarak `stopped` geri YAZMAZ (döngü olmasın).
    func testUnsolicitedStoppedFromTvStopsSenderWithoutEcho() async throws {
        var stopped: [String] = []
        let (srv, port) = server { stopped.append($0) }
        defer { srv.stop() }
        let (h, input) = try client(port)
        send(h, ["t": "hello", "role": "receiver", "name": "test-tv", "ver": 2])
        let ch = try await input.next()
        let nonceMac = Data(base64Encoded: ch["nonce_mac"] as! String)!
        let nonceTv = PairingCrypto.randomNonce()
        send(h, ["t": "proof", "nonce_tv": nonceTv.base64EncodedString(),
                 "proof": PairingCrypto.sessionProof(key, .reverse, .tv, serverNonce: nonceMac,
                                                     clientNonce: nonceTv).base64EncodedString()])
        let readyReply = try await input.next()
        XCTAssertEqual(readyReply["t"] as? String, "ready")

        send(h, ["t": "stopped", "reason": "kullanıcı DURDUR"])
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(stopped, ["127.0.0.1"], "TV'nin durdurma bildirisi yayını kesmeli")

        let echo = try? await input.next()
        XCTAssertNil(echo, "bildirim yanıt istemez: geri yazılırsa mesaj iki uçta döner")
    }

    func testOldVersionIsRejected() async throws {        let (srv, port) = server { _ in }
        defer { srv.stop() }
        let (h, input) = try client(port)
        send(h, ["t": "hello", "role": "receiver", "name": "x", "ver": 1])
        let r = try await input.next()
        XCTAssertEqual(r["reason"] as? String, "version")
        XCTAssertEqual(r["ver"] as? Int, 2)
    }
}

/// Engelleyici okuma ana iş parçacığını tutmasın diye ayrı kuyrukta satır okur.
final class LineIn: @unchecked Sendable {
    private let fd: Int32
    private var buf = Data()
    init(fd: Int32) { self.fd = fd }

    func next() async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                var chunk = [UInt8](repeating: 0, count: 4096)
                while true {
                    if let nl = self.buf.firstIndex(of: 0x0A) {
                        let line = self.buf.subdata(in: self.buf.startIndex..<nl)
                        self.buf.removeSubrange(self.buf.startIndex...nl)
                        let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
                        cont.resume(returning: o); return
                    }
                    let n = read(self.fd, &chunk, chunk.count)
                    if n <= 0 { cont.resume(throwing: URLError(.networkConnectionLost)); return }
                    self.buf.append(contentsOf: chunk[0..<n])
                }
            }
        }
    }
}
