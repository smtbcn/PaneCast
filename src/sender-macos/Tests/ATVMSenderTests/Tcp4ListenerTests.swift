import Foundation
import XCTest
@testable import atvm_sender

/// 7610 dinleyicisinin doğrulama öncesi sınırları: satır sonu göndermeden veri yığan istemci düşer.
final class Tcp4ListenerTests: XCTestCase {
    func testOversizedLineDropsConnection() throws {
        let listener = Tcp4Listener()
        let port = UInt16.random(in: 47_000...48_000)
        try listener.start(port: port)
        defer { listener.stop() }
        let gotLine = expectation(description: "normal satır")
        let closed = expectation(description: "bağlantı kapandı")
        listener.onClient = { conn in
            Task {
                var lines = 0
                for await _ in conn.messages() { lines += 1; if lines == 1 { gotLine.fulfill() } }
                XCTAssertEqual(lines, 1)
                closed.fulfill()
            }
        }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(rc, 0)
        defer { close(fd) }
        let first = Array("{\"t\":\"ping\"}\n".utf8)
        _ = first.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let junk = [UInt8](repeating: 0x61, count: Tcp4Connection.maxLineBytes + 4096)
        _ = junk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        wait(for: [gotLine, closed], timeout: 5)
    }
}
