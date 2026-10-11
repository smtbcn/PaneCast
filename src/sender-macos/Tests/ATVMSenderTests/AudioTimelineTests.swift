import CoreMedia
import XCTest
@testable import atvm_sender

final class AudioTimelineTests: XCTestCase {
    private let epoch = SessionEpoch(hostSeconds: 1000.0, videoBase: 5000, audioBase: 0xFFFF_FF00)

    func testFirstChunkAnchorsToEpochOffset() {
        var t = AudioTimeline(epoch: epoch)
        XCTAssertEqual(t.place(hostSeconds: 1000.5, pendingFrames: 0), .anchored)
        XCTAssertEqual(t.nextIndex, 24_000)
        XCTAssertEqual(t.currentTimestamp, 0xFFFF_FF00 &+ 24_000)        // 32 bit sarılır
    }

    func testSampleCounterContinuityWithinThreshold() {
        var t = AudioTimeline(epoch: epoch)
        _ = t.place(hostSeconds: 1001.0, pendingFrames: 0)
        // 512 çerçeve geldi; 480'i paketlendi, 32'si bekliyor.
        t.advance(frames: 480)
        // Sonraki parçanın ilk örneği tam 512 örnek sonra, host 8 ms jitter'lı.
        let next = 1001.0 + 512.0 / 48_000 + 0.008
        guard case .continuous(let drift) = t.place(hostSeconds: next, pendingFrames: 32) else {
            return XCTFail("sapma 20 ms altında, çapa değişmemeli")
        }
        XCTAssertEqual(drift, 8.0, accuracy: 0.05)
        XCTAssertEqual(t.nextIndex, 48_000 + 480)
        XCTAssertEqual(t.reanchors, 0)
    }

    func testReanchorsWhenDriftExceeds20ms() {
        var t = AudioTimeline(epoch: epoch)
        _ = t.place(hostSeconds: 1001.0, pendingFrames: 0)
        t.advance(frames: 480)
        let next = 1001.0 + 512.0 / 48_000 + 0.050                        // 50 ms boşluk
        guard case .reanchored(let drift) = t.place(hostSeconds: next, pendingFrames: 32) else {
            return XCTFail("50 ms sapma yeniden çapalamalı")
        }
        XCTAssertEqual(drift, 50.0, accuracy: 0.05)
        XCTAssertEqual(t.nextIndex, t.epoch.audioIndex(hostSeconds: next))
        XCTAssertEqual(t.reanchors, 1)
    }

    func testJustUnderThresholdDoesNotReanchor() {
        var t = AudioTimeline(epoch: epoch)
        _ = t.place(hostSeconds: 1001.0, pendingFrames: 0)
        guard case .continuous = t.place(hostSeconds: 1001.0 + 0.0199, pendingFrames: 0) else {
            return XCTFail("19,9 ms çapa değiştirmemeli")
        }
    }

    func testVideoTimestampUsesSharedEpoch() {
        XCTAssertEqual(epoch.videoTimestamp(hostSeconds: 1000.0), 5000)
        XCTAssertEqual(epoch.videoTimestamp(hostSeconds: 1000.5), 5000 + 45_000)
        XCTAssertEqual(epoch.videoTimestamp(hostSeconds: 999.9), 5000 &- 9_000)      // köksel önce: mod 2^32
        // Aynı anın ses ve görüntü damgaları aynı süreyi temsil eder.
        let videoTs: UInt32 = epoch.videoTimestamp(hostSeconds: 1002.25)
        let audioTs: UInt32 = epoch.audioTimestamp(index: epoch.audioIndex(hostSeconds: 1002.25))
        let videoSeconds = Double(videoTs &- epoch.videoBase) / 90_000.0
        let audioSeconds = Double(audioTs &- epoch.audioBase) / 48_000.0
        XCTAssertEqual(videoSeconds, 2.25, accuracy: 1e-9)
        XCTAssertEqual(audioSeconds, 2.25, accuracy: 1e-9)
    }

    func testHostClockMatchesCoreMediaHostClock() {
        let cm = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let mach = HostClock.now()
        XCTAssertEqual(cm, mach, accuracy: 0.005)
    }
}

final class PcmAudioPacketizerTests: XCTestCase {
    private let epoch = SessionEpoch(hostSeconds: 2000.0, videoBase: 0, audioBase: 1_000)

    private func timestamp(_ p: Data) -> UInt32 {
        var ts = UInt32(0)
        for b in [UInt8](p)[4..<8] { ts = ts << 8 | UInt32(b) }
        return ts
    }

    private func feed(_ pk: PcmAudioPacketizer, frames: Int, host: Double, value: Float = 0.25) -> [Data] {
        let buf = [Float](repeating: value, count: frames * 2)
        return buf.withUnsafeBufferPointer {
            pk.packets(interleaved: $0.baseAddress!, frames: frames, channels: 2, hostSeconds: host)
        }
    }

    func testContinuousCallbacksGiveGaplessFiveMsPackets() {
        let pk = PcmAudioPacketizer(ssrc: 1, payloadType: 97, epoch: epoch)
        var host = 2000.1
        var packets: [Data] = []
        for _ in 0..<100 {                                   // 100 × 512 çerçeve
            packets += feed(pk, frames: 512, host: host)
            host += 512.0 / 48_000
        }
        XCTAssertEqual(packets.count, 51_200 / 240)
        XCTAssertEqual(pk.pendingSamples, (51_200 % 240) * 2)
        XCTAssertEqual(timestamp(packets[0]), UInt32(1_000 + 4_800))                 // 100 ms × 48
        for (a, b) in zip(packets, packets.dropFirst()) { XCTAssertEqual(timestamp(b) &- timestamp(a), 240) }
        XCTAssertEqual(pk.reanchors, 0)
        XCTAssertEqual(packets[0].count, 12 + 960)
    }

    func testReanchorOnHostJumpMovesTimestampAndDropsPending() {
        let pk = PcmAudioPacketizer(ssrc: 1, payloadType: 97, epoch: epoch)
        var logs: [String] = []
        pk.onLog = { logs.append($0) }
        _ = feed(pk, frames: 512, host: 2000.0)
        let before = feed(pk, frames: 512, host: 2000.0 + 512.0 / 48_000)
        let after = feed(pk, frames: 512, host: 2000.0 + 1024.0 / 48_000 + 0.100)       // 100 ms boşluk
        XCTAssertEqual(pk.reanchors, 1)
        XCTAssertTrue(logs.contains { $0.contains("yeniden çapalandı") })
        let expectedFirst = UInt32(1_000 + epoch.audioIndex(hostSeconds: 2000.0 + 1024.0 / 48_000 + 0.100))
        XCTAssertEqual(timestamp(after[0]), expectedFirst)
        XCTAssertGreaterThan(timestamp(after[0]) &- timestamp(before.last!), 4_800 - 240)
    }

    func testCarryStaysBoundedForHugeChunk() {
        let pk = PcmAudioPacketizer(ssrc: 1, payloadType: 97, epoch: epoch)
        let packets = feed(pk, frames: 48_000 * 3 + 7, host: 2000.0)          // 3 sn tek çağrıda
        XCTAssertEqual(packets.count, (48_000 * 3 + 7) / 240)
        XCTAssertEqual(pk.pendingSamples, ((48_000 * 3 + 7) % 240) * 2)
        XCTAssertLessThan(pk.pendingSamples, 480)
    }

    func testDitherClampsAndKeepsSilenceExact() {
        var d = Dither()
        XCTAssertEqual(d.quantize(0), 0)
        XCTAssertEqual(d.quantize(.nan), 0)
        // Kırpma sonrası da dither uygulanır: tam ölçekte sonuç raya en çok 1 LSB uzak.
        XCTAssertGreaterThanOrEqual(d.quantize(5.0), 32766)
        XCTAssertLessThanOrEqual(d.quantize(-5.0), -32766)
        // Sabit 0,5 → ideal 16383,5; TPDF ile ortalama ideal değere yakın, her örnek ±1 LSB içinde.
        var sum = 0.0
        var worst = 0.0
        for _ in 0..<100_000 {
            let q = Double(d.quantize(0.5))
            sum += q
            worst = max(worst, abs(q - 16383.5))
        }
        XCTAssertEqual(sum / 100_000, 16383.5, accuracy: 0.05)
        XCTAssertLessThanOrEqual(worst, 1.5)
    }
}
