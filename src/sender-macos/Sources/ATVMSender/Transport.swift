import Foundation
import Network
import CoreMedia

/// RFC 6184 RTP paketleyici: Annex-B erişim birimini MTU boyutunda paketlere böler.
/// Tek NAL sığıyorsa olduğu gibi, sığmıyorsa FU-A parçalarına ayrılır.
final class RtpPacketizer: @unchecked Sendable {
    static let headerSize = 12
    static let maxPayload = 1150          // 1500 MTU - IP/UDP başlık payı ile güvenli sınır

    let ssrc: UInt32
    let payloadType: UInt8
    private var sequence: UInt16 = UInt32.random(in: 0...UInt32(UInt16.max)).uint16Value
    /// 90 kHz zaman damgası, oturumun ortak köküne (`SessionEpoch`) göre PTS'ten türetilir;
    /// ses de aynı kökü kullandığı için iki akış tek eksende durur.
    private let epoch: SessionEpoch

    var packetsSent = 0
    var bytesSent = 0

    init(ssrc: UInt32, payloadType: UInt8, epoch: SessionEpoch) {
        self.ssrc = ssrc
        self.payloadType = payloadType
        self.epoch = epoch
    }

    /// Bir erişim birimini (Annex-B) RTP paketlerine çevirir.
    func packets(annexB: Data, pts: CMTime) -> [Data] {
        let nalus = splitAnnexB(annexB)
        guard !nalus.isEmpty else { return [] }
        let timestamp = epoch.videoTimestamp(hostSeconds: CMTimeGetSeconds(pts))
        let last = nalus.count - 1
        var out: [Data] = []
        for (i, nalu) in nalus.enumerated() {
            let marker = (i == last)
            if nalu.count <= Self.maxPayload {
                out.append(packet(payload: nalu, timestamp: timestamp, marker: marker))
            } else {
                out.append(contentsOf: fragmentation(nalu: nalu, timestamp: timestamp, marker: marker))
            }
        }
        return out
    }

    /// Annex-B baytlarını NAL birimlerine ayırır (start code 00 00 01 veya 00 00 00 01).
    private func splitAnnexB(_ data: Data) -> [Data] {
        var result: [Data] = []
        let bytes = [UInt8](data)
        var starts: [Int] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append(i + 3)
                i += 3
            } else if i + 3 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                starts.append(i + 4)
                i += 4
            } else {
                i += 1
            }
        }
        for (idx, start) in starts.enumerated() {
            let end = idx + 1 < starts.count ? starts[idx + 1] - 3 : bytes.count
            if end > start { result.append(Data(bytes[start..<end])) }
        }
        return result
    }

    /// FU-A (type 28) parçalama.
    private func fragmentation(nalu: Data, timestamp: UInt32, marker: Bool) -> [Data] {
        guard let first = nalu.first else { return [] }
        let nri = first & 0x60
        let nalType = first & 0x1F
        let body = nalu.dropFirst()
        let indicator: UInt8 = 28 | nri
        var out: [Data] = []
        var offset = body.startIndex
        var chunkIndex = 0
        while offset < body.endIndex {
            let remaining = body.endIndex - offset
            let len = min(Self.maxPayload - 2, remaining)
            let chunk = body[offset..<body.index(offset, offsetBy: len)]
            let startBit: UInt8 = chunkIndex == 0 ? 0x80 : 0
            let endBit: UInt8 = (body.index(offset, offsetBy: len) == body.endIndex) ? 0x40 : 0
            var payload = Data(capacity: 2 + len)
            payload.append(indicator)
            payload.append(startBit | endBit | nalType)
            payload.append(contentsOf: chunk)
            out.append(packet(payload: payload, timestamp: timestamp,
                              marker: endBit != 0 && marker))
            offset = body.index(offset, offsetBy: len)
            chunkIndex += 1
        }
        return out
    }

    private func packet(payload: Data, timestamp: UInt32, marker: Bool) -> Data {
        var p = Data(capacity: Self.headerSize + payload.count)
        p.append(0x80)                                  // V=2, P=0, X=0, CC=0
        p.append(marker ? (payloadType | 0x80) : payloadType)
        p.append(UInt8(sequence >> 8)); p.append(UInt8(sequence & 0xFF))
        p.append(UInt8(timestamp >> 24)); p.append(UInt8((timestamp >> 16) & 0xFF))
        p.append(UInt8((timestamp >> 8) & 0xFF)); p.append(UInt8(timestamp & 0xFF))
        p.append(UInt8(ssrc >> 24)); p.append(UInt8((ssrc >> 16) & 0xFF))
        p.append(UInt8((ssrc >> 8) & 0xFF)); p.append(UInt8(ssrc & 0xFF))
        p.append(payload)
        sequence = sequence &+ 1
        packetsSent += 1
        bytesSent += p.count
        return p
    }
}

extension UInt32 { var uint16Value: UInt16 { UInt16(truncatingIfNeeded: self) } }

/// Video paketlerini token-bucket ile yayar: kare başına tek patlama yerine ~2,5 × (hedef ya da
/// ölçülen, hangisi büyükse) bit hızında, en çok `burst` baytlık patlamalarla. Kodlayıcı hedefi
/// aşarsa (yüksek entropili içerik) pacer darboğaz olmasın diye ölçülen hıza uyar.
/// Sıra özel bir kuyrukta işlenir; ses buraya uğramaz. Kuyruk gecikmesi sınırı aşarsa en eski
/// kareler atılır (`onDrop`).
final class VideoPacer: @unchecked Sendable {
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending = PacerQueue()
    private var bucket: TokenBucket
    private var scheduled = false
    private var stopped = false
    private var nextAu: UInt64 = 0
    private let paceFactor: Double
    private let targetRate: Double
    private let maxQueueSeconds: Double
    private var measuredRate: Double = 0
    private var sampleStart: Double
    private var sampleBytes = 0
    /// false: gönderim şimdi kabul edilmedi (ağ kuyruğu dolu), paket kuyrukta kalır.
    private let transmit: (Data) -> Bool
    private let onDrop: (_ packets: Int, _ aus: Int) -> Void

    /// `targetRate` bayt/sn (hedef bit hızı), `paceFactor` ile çarpılarak yayma hızı olur.
    init(targetRate: Double, paceFactor: Double, burst: Double, maxQueueSeconds: Double, queue: DispatchQueue,
         transmit: @escaping (Data) -> Bool, onDrop: @escaping (Int, Int) -> Void) {
        self.queue = queue
        let now = Self.now()
        self.targetRate = targetRate
        self.paceFactor = paceFactor
        self.maxQueueSeconds = maxQueueSeconds
        self.sampleStart = now
        self.bucket = TokenBucket(rate: targetRate * paceFactor, capacity: burst, now: now)
        self.transmit = transmit
        self.onDrop = onDrop
    }

    /// Bit hızı referansı (bayt/sn): hedef ile son ölçülenin büyüğü; yeniden gönderim bütçesi de bunu kullanır.
    var referenceRate: Double {
        lock.lock(); defer { lock.unlock() }
        return max(targetRate, measuredRate)
    }

    /// 250 ms'lik örneklerle giren bayt hızını ölçer; yayma hızını gerekirse günceller. Kilit altında çağrılır.
    private func adaptRate(addedBytes: Int, now: Double) {
        sampleBytes += addedBytes
        let dt = now - sampleStart
        guard dt >= 0.25 else { return }
        let sample = Double(sampleBytes) / dt
        measuredRate = measuredRate == 0 ? sample : measuredRate * 0.6 + sample * 0.4
        sampleStart = now
        sampleBytes = 0
        let want = max(targetRate, measuredRate) * paceFactor
        if abs(want - bucket.rate) > bucket.rate * 0.1 {
            bucket.reconfigure(rate: want, capacity: bucket.capacity, now: now)
        }
    }

    /// Bir erişim biriminin tüm paketlerini sıraya koyar (çağıran thread'i bekletmez).
    func enqueue(_ packets: [Data]) {
        guard !packets.isEmpty else { return }
        lock.lock()
        if stopped { lock.unlock(); return }
        pending.append(packets, au: nextAu)
        nextAu += 1
        adaptRate(addedBytes: packets.reduce(0) { $0 + $1.count }, now: Self.now())
        let dropped = pending.dropOldest(limit: max(64 * 1024, Int(bucket.rate * maxQueueSeconds)))
        let start = !scheduled
        scheduled = true
        lock.unlock()
        if dropped.packets > 0 { onDrop(dropped.packets, dropped.aus) }
        if start { queue.async { [self] in drain() } }
    }

    func stop() {
        lock.lock()
        stopped = true
        pending = PacerQueue()
        lock.unlock()
    }

    private func drain() {
        lock.lock()
        while true {
            if stopped { scheduled = false; lock.unlock(); return }
            guard let item = pending.peek() else { scheduled = false; lock.unlock(); return }
            let size = item.packet.count
            let wait = bucket.waitTime(for: size, now: Self.now())
            if wait > 0 { lock.unlock(); reschedule(after: wait); return }
            if !transmit(item.packet) { lock.unlock(); reschedule(after: 0.001); return }
            _ = bucket.tryTake(size, now: Self.now())
            pending.pop()
        }
    }

    private func reschedule(after seconds: Double) {
        queue.asyncAfter(deadline: .now() + max(seconds, 0.0003)) { [self] in drain() }
    }
}

/// Medyayı UDP ile TV'ye gönderen katman.
///
/// - Video: `sendVideo` → pacer → (halkaya kayıt) → soket. Kayıp, TV'nin RTCP NACK'ıyla
///   halkadan aynen yeniden gönderilerek kurtarılır; yeniden gönderim hedef bit hızının
///   %25'iyle sınırlıdır.
/// - Ses: `sendAudio` pacer'a girmez, doğrudan soketten gider (video patlamasının arkasında beklemez).
/// - Sınama: `ATVM_DROP_VIDEO_PCT=<yüzde>` ilk iletimdeki video paketlerinin o kadarını yollamaz
///   (halkada tutulur, NACK ile kurtarılır).
final class MediaUdpSender: @unchecked Sendable {
    struct Counters {
        var nackRx = 0          // alınan RTCP NACK paketi
        var rtxTx = 0           // yeniden gönderilen paket
        var rtxSkip = 0         // halkada yok / çok yakın zamanda gönderildi / bütçe doldu
        var injDrop = 0         // sınama için bilerek düşürülen
        var paceDrop = 0        // pacer kuyruğu taşınca atılan
        var sendErrors = 0
    }

    /// Ağ yığınına verilmiş ama henüz işlenmemiş bayt tavanı: kuyruğu sığ tutar (ses de beklemesin).
    private static let maxInflightBytes = 64 * 1024
    /// Aynı seq'in art arda yeniden gönderimi arasındaki en kısa süre.
    private static let minRtxIntervalNs: UInt64 = 4_000_000
    /// Yeniden gönderim bütçesi: referans bit hızının payı.
    private static let rtxShare = 0.25

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "atvm.udp", qos: .userInteractive)
    private let pacerQueue = DispatchQueue(label: "atvm.pacer", qos: .userInteractive)
    private let store = RtpRetransmitStore()
    private let videoSsrc: UInt32
    private var pacer: VideoPacer!
    private let lock = NSLock()
    private var c = Counters()
    private var inflightBytes = 0
    private var rtxBucket: TokenBucket
    private var lastDropReport = 0.0
    private var cancelled = false
    let dropPercent: Double

    /// Pacer kuyruğu taşıp kareler atılınca (en çok 300 ms'de bir): sahibi kodlayıcıdan IDR istemeli.
    var onVideoDrop: ((_ packets: Int, _ aus: Int) -> Void)?

    var sendErrors: Int { counters().sendErrors }

    func counters() -> Counters {
        lock.lock(); defer { lock.unlock() }
        return c
    }

    init(host: String, port: UInt16, videoSsrc: UInt32, videoBitrate: Int) {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port)!, using: params)
        self.videoSsrc = videoSsrc
        let bps = Double(max(videoBitrate, 1_000_000)) / 8        // bayt/sn
        rtxBucket = TokenBucket(rate: bps * Self.rtxShare, capacity: bps * Self.rtxShare * 0.2, now: VideoPacer.now())
        let pct = Double(ProcessInfo.processInfo.environment["ATVM_DROP_VIDEO_PCT"] ?? "") ?? 0
        dropPercent = min(max(pct, 0), 100)
        store.register(ssrc: videoSsrc)
        pacer = VideoPacer(targetRate: bps, paceFactor: 2.5, burst: 16 * 1024, maxQueueSeconds: 0.15, queue: pacerQueue,
                           transmit: { [weak self] in self?.transmitVideo($0) ?? true },
                           onDrop: { [weak self] p, a in self?.pacerDropped(packets: p, aus: a) })
        connection.start(queue: queue)
        armReceive()
    }

    /// Bir video erişim biriminin paketleri (sıralı).
    func sendVideo(_ packets: [Data]) { pacer.enqueue(packets) }

    /// Ses paketi: pacer'ı atlar.
    func sendAudio(_ packet: Data) { rawSend(packet) }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        pacer.stop()
        connection.cancel()
    }

    // MARK: - gönderim

    private func rawSend(_ packet: Data) {
        let n = packet.count
        lock.lock(); inflightBytes += n; lock.unlock()
        connection.send(content: packet, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            self.lock.lock()
            self.inflightBytes -= n
            if err != nil { self.c.sendErrors += 1 }
            self.lock.unlock()
        })
    }

    /// Pacer'dan çağrılır. Ağ kuyruğu doluysa false (paket sırada bekler).
    private func transmitVideo(_ packet: Data) -> Bool {
        lock.lock(); let busy = inflightBytes >= Self.maxInflightBytes; lock.unlock()
        if busy { return false }
        store.record(packet)
        if dropPercent > 0, Double.random(in: 0..<100) < dropPercent {
            lock.lock(); c.injDrop += 1; lock.unlock()
            return true
        }
        rawSend(packet)
        return true
    }

    private func pacerDropped(packets: Int, aus: Int) {
        let now = VideoPacer.now()
        lock.lock()
        c.paceDrop += packets
        let report = now - lastDropReport >= 0.3
        if report { lastDropReport = now }
        lock.unlock()
        if report { onVideoDrop?(packets, aus) }
    }

    // MARK: - RTCP geri bildirimi

    private func armReceive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            self.lock.lock(); let done = self.cancelled; self.lock.unlock()
            if done { return }
            if let data, !data.isEmpty { self.handleFeedback(data) }
            if error != nil {
                // Kalıcı hata (ör. ICMP erişilemez) boş döngüye dönmesin.
                self.queue.asyncAfter(deadline: .now() + 0.1) { self.armReceive() }
            } else {
                self.armReceive()
            }
        }
    }

    private func handleFeedback(_ data: Data) {
        let now = DispatchTime.now().uptimeNanoseconds
        for nack in RtcpFeedback.parseNacks(data) {
            lock.lock(); c.nackRx += 1; lock.unlock()
            guard let ring = store.ring(for: nack.mediaSsrc) else { continue }
            for seq in nack.seqs {
                guard let packet = ring.fetchForRetransmit(seq: seq, nowNs: now,
                                                           minIntervalNs: Self.minRtxIntervalNs) else {
                    lock.lock(); c.rtxSkip += 1; lock.unlock()
                    continue
                }
                let ref = pacer.referenceRate
                lock.lock()
                rtxBucket.reconfigure(rate: ref * Self.rtxShare, capacity: ref * Self.rtxShare * 0.2,
                                      now: VideoPacer.now())
                let ok = rtxBucket.tryTake(packet.count, now: VideoPacer.now())
                if ok { c.rtxTx += 1 } else { c.rtxSkip += 1 }
                lock.unlock()
                if ok { rawSend(packet) }
            }
        }
    }
}
