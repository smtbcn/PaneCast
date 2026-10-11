import Foundation
import XCTest
@testable import atvm_sender

final class RetransmitTests: XCTestCase {
    private func rtp(seq: UInt16, ssrc: UInt32 = 0x11223344, marker: Bool = false) -> Data {
        var d = Data([0x80, marker ? 0xE0 : 0x60, UInt8(seq >> 8), UInt8(seq & 0xFF)])
        d.append(contentsOf: [0, 0, 0, 1])
        for shift in stride(from: 24, through: 0, by: -8) { d.append(UInt8((ssrc >> UInt32(shift)) & 0xFF)) }
        d.append(contentsOf: [0x41, UInt8(seq & 0xFF)])
        return d
    }

    // MARK: - RTCP NACK

    /// Alıcı tarafındaki (Kotlin) kurucunun ürettiği vektörle aynı baytlar:
    /// gönderen AABBCCDD, medya 11223344, seq 100,101,103,116,117,200.
    func testParsesNackProducedByReceiver() {
        let bytes: [UInt8] = [0x81, 0xCD, 0x00, 0x05, 0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22, 0x33, 0x44,
                              0x00, 0x64, 0x80, 0x05, 0x00, 0x75, 0x00, 0x00, 0x00, 0xC8, 0x00, 0x00]
        let nacks = RtcpFeedback.parseNacks(Data(bytes))
        XCTAssertEqual(nacks, [RtcpFeedback.Nack(mediaSsrc: 0x11223344, seqs: [100, 101, 103, 116, 117, 200])])
    }

    func testNackBlpWrapsAroundSequenceSpace() {
        // PID 65534, BLP bit0 (65535) + bit1 (0) + bit2 (1)
        let bytes: [UInt8] = [0x81, 0xCD, 0x00, 0x03, 0, 0, 0, 1, 0, 0, 0, 2, 0xFF, 0xFE, 0x00, 0x07]
        XCTAssertEqual(RtcpFeedback.parseNacks(Data(bytes)).first?.seqs, [65534, 65535, 0, 1])
    }

    func testIgnoresNonNackAndTruncatedFeedback() {
        // Receiver Report (PT=201) + sonra kısa/bozuk kuyruk
        let rr: [UInt8] = [0x80, 0xC9, 0x00, 0x01, 0, 0, 0, 1]
        XCTAssertTrue(RtcpFeedback.parseNacks(Data(rr)).isEmpty)
        let truncated: [UInt8] = [0x81, 0xCD, 0x00, 0x05, 0xAA, 0xBB]
        XCTAssertTrue(RtcpFeedback.parseNacks(Data(truncated)).isEmpty)
        // PLI (FMT=1 ama PT=206) NACK sayılmaz
        let pli: [UInt8] = [0x81, 0xCE, 0x00, 0x02, 0, 0, 0, 1, 0, 0, 0, 2]
        XCTAssertTrue(RtcpFeedback.parseNacks(Data(pli)).isEmpty)
    }

    func testCompoundPacketYieldsNackAfterReceiverReport() {
        let rr: [UInt8] = [0x80, 0xC9, 0x00, 0x01, 0, 0, 0, 1]
        let nack: [UInt8] = [0x81, 0xCD, 0x00, 0x03, 0, 0, 0, 1, 0, 0, 0, 2, 0x00, 0x0A, 0x00, 0x00]
        let parsed = RtcpFeedback.parseNacks(Data(rr + nack))
        XCTAssertEqual(parsed, [RtcpFeedback.Nack(mediaSsrc: 2, seqs: [10])])
    }

    // MARK: - halka

    func testRingReturnsOriginalBytesBySequence() {
        let ring = RtpRetransmitRing(capacity: 2048)
        let p = rtp(seq: 500)
        ring.store(p)
        XCTAssertEqual(ring.fetchForRetransmit(seq: 500, nowNs: 1_000, minIntervalNs: 0), p)
        XCTAssertNil(ring.fetchForRetransmit(seq: 501, nowNs: 1_000, minIntervalNs: 0))
    }

    func testRingOverwritesAfterCapacityAndKeepsWindow() {
        let ring = RtpRetransmitRing(capacity: 2048)
        for s in 0..<3000 { ring.store(rtp(seq: UInt16(s))) }
        XCTAssertNil(ring.fetchForRetransmit(seq: 100, nowNs: 1, minIntervalNs: 0), "2048'den eski paket kalmamalı")
        XCTAssertNotNil(ring.fetchForRetransmit(seq: 1000, nowNs: 1, minIntervalNs: 0))
        XCTAssertNotNil(ring.fetchForRetransmit(seq: 2999, nowNs: 1, minIntervalNs: 0))
    }

    func testRingHandlesSequenceWraparound() {
        let ring = RtpRetransmitRing(capacity: 2048)
        var s = UInt16(65000)
        for _ in 0..<1200 { ring.store(rtp(seq: s)); s = s &+ 1 }          // 65000 … 664 (sarma)
        XCTAssertEqual(ring.fetchForRetransmit(seq: 65535, nowNs: 1, minIntervalNs: 0), rtp(seq: 65535))
        XCTAssertEqual(ring.fetchForRetransmit(seq: 0, nowNs: 1, minIntervalNs: 0), rtp(seq: 0))
    }

    func testRingSuppressesBackToBackRetransmits() {
        let ring = RtpRetransmitRing(capacity: 2048)
        ring.store(rtp(seq: 7))
        XCTAssertNotNil(ring.fetchForRetransmit(seq: 7, nowNs: 10_000_000, minIntervalNs: 4_000_000))
        XCTAssertNil(ring.fetchForRetransmit(seq: 7, nowNs: 12_000_000, minIntervalNs: 4_000_000))
        XCTAssertNotNil(ring.fetchForRetransmit(seq: 7, nowNs: 15_000_000, minIntervalNs: 4_000_000))
    }

    func testStoreKeepsRingsPerSsrcAndIgnoresUnregistered() {
        let store = RtpRetransmitStore()
        store.register(ssrc: 0x11223344)
        store.record(rtp(seq: 1, ssrc: 0x11223344))
        store.record(rtp(seq: 1, ssrc: 0x55667788))                        // ses gibi kayıtsız SSRC
        XCTAssertNotNil(store.ring(for: 0x11223344)?.fetchForRetransmit(seq: 1, nowNs: 1, minIntervalNs: 0))
        XCTAssertNil(store.ring(for: 0x55667788))
    }

    // MARK: - token bucket

    func testTokenBucketPacesAtRateAfterBurst() {
        var b = TokenBucket(rate: 1_000_000, capacity: 16_000, now: 0)
        var sent = 0
        while b.tryTake(1_000, now: 0) { sent += 1 }
        XCTAssertEqual(sent, 16, "patlama tavanı kadar anında gider")
        XCTAssertEqual(b.waitTime(for: 1_000, now: 0), 0.001, accuracy: 1e-9)
        XCTAssertFalse(b.tryTake(1_000, now: 0.0005))
        XCTAssertTrue(b.tryTake(1_000, now: 0.001))
    }

    func testTokenBucketNeverExceedsCapacityWhenIdle() {
        var b = TokenBucket(rate: 1_000_000, capacity: 16_000, now: 0)
        XCTAssertTrue(b.tryTake(16_000, now: 0))
        var sent = 0
        while b.tryTake(1_000, now: 100) { sent += 1 }                    // 100 sn bekledi
        XCTAssertEqual(sent, 16)
    }

    func testTokenBucketReconfigureKeepsEarnedTokensAndClampsToNewCapacity() {
        var b = TokenBucket(rate: 1_000_000, capacity: 16_000, now: 0)
        XCTAssertTrue(b.tryTake(16_000, now: 0))
        b.reconfigure(rate: 2_000_000, capacity: 8_000, now: 0.002)       // 2 ms eski hızla 2000 B kazandı
        XCTAssertFalse(b.tryTake(2_001, now: 0.002))
        XCTAssertTrue(b.tryTake(2_000, now: 0.002))
        XCTAssertEqual(b.waitTime(for: 1_000, now: 0.002), 0.0005, accuracy: 1e-9)   // yeni hız
        b.reconfigure(rate: 2_000_000, capacity: 500, now: 100)
        XCTAssertFalse(b.tryTake(501, now: 100), "kapasiteyi aşan jeton tutulmaz")
    }

    // MARK: - pacer kuyruğu

    func testPacerQueueDropsWholeOldestFramesAndKeepsNewest() {
        var q = PacerQueue()
        let pkt = Data(count: 1000)
        q.append([pkt, pkt, pkt], au: 1)
        q.append([pkt, pkt], au: 2)
        q.append([pkt, pkt, pkt, pkt], au: 3)
        XCTAssertEqual(q.bytes, 9_000)
        let dropped = q.dropOldest(limit: 6_000)
        XCTAssertEqual(dropped.aus, 1)
        XCTAssertEqual(dropped.packets, 3)
        XCTAssertEqual(q.bytes, 6_000)
        XCTAssertEqual(q.peek()?.au, 2)
        // Tek (en yeni) kare sınırı aşsa bile atılmaz.
        let more = q.dropOldest(limit: 100)
        XCTAssertEqual(more.aus, 1)
        XCTAssertEqual(q.peek()?.au, 3)
        XCTAssertEqual(q.dropOldest(limit: 100).aus, 0)
    }

    func testPacerQueueFifoOrder() {
        var q = PacerQueue()
        q.append([Data([1]), Data([2])], au: 1)
        q.append([Data([3])], au: 2)
        var order: [UInt8] = []
        while let item = q.peek() { order.append(item.packet[0]); q.pop() }
        XCTAssertEqual(order, [1, 2, 3])
        XCTAssertTrue(q.isEmpty)
        XCTAssertEqual(q.bytes, 0)
    }
}
