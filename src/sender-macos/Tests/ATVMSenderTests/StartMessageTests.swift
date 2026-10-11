import CoreMedia
import Network
import XCTest
@testable import atvm_sender

final class StartMessageTests: XCTestCase {
    func testVideoPacketCarriesSharedEpochTimestamp() {
        let epoch = SessionEpoch(hostSeconds: 500.0, videoBase: 123_456, audioBase: 0)
        let pk = RtpPacketizer(ssrc: 7, payloadType: 96, epoch: epoch)
        let annexB = Data([0, 0, 0, 1, 0x65, 1, 2, 3])
        let pts = CMTime(seconds: 500.25, preferredTimescale: 1_000_000_000)
        let packet = pk.packets(annexB: annexB, pts: pts)[0]
        var ts = UInt32(0)
        for b in [UInt8](packet)[4..<8] { ts = ts << 8 | UInt32(b) }
        XCTAssertEqual(ts, UInt32(123_456 + 22_500))
    }

    /// Yerel soketle: `start` satırı `sync`, `video_rtp_base`, `audio_rtp_base` taşıyor mu?
    func testControlClientStartCarriesSyncFields() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let received = expectation(description: "start satırı")
        let box = LineBox()
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                box.set(data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
                conn.send(content: Data("{\"t\":\"started\"}\n".utf8), completion: .contentProcessed { _ in })
                received.fulfill()
            }
        }
        let ready = expectation(description: "dinleyici")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port?.rawValue)

        let client = ControlClient(host: "127.0.0.1", port: port)
        try await client.connect()
        try await client.requestStart(MirrorEngine.StartInfo(
            width: 640, height: 360, fps: 60, bitrate: 1_000_000, ssrc: 1, mediaPort: 7602, payloadType: 96,
            audioSsrc: 2, audioPayloadType: 97, audioSampleRate: 48_000, audioChannels: 2,
            videoRtpBase: 4_000_000_000, audioRtpBase: 17))
        await fulfillment(of: [received], timeout: 5)
        client.disconnect()
        listener.cancel()

        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(box.get().utf8)) as? [String: Any])
        XCTAssertEqual(obj["t"] as? String, "start")
        XCTAssertEqual(obj["sync"] as? Int, 1)
        XCTAssertEqual(obj["video_rtp_base"] as? Int, 4_000_000_000)
        XCTAssertEqual(obj["audio_rtp_base"] as? Int, 17)
        XCTAssertEqual(obj["audio_payload_type"] as? Int, 97)
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
}
