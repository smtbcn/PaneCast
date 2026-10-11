import Foundation

// Video kaybı kurtarma yapı taşları: yeniden gönderim halkası, RTCP NACK ayrıştırıcı,
// token-bucket ve pacer kuyruğu. Hepsi saf mantıktır (ağ yok), birim testle sınanır.

/// Bir RTP paketinin başlığından alanlar (ağ sırası, büyük uçlu).
enum RtpHeader {
    static func sequence(_ p: Data) -> UInt16 {
        UInt16(p[p.startIndex + 2]) << 8 | UInt16(p[p.startIndex + 3])
    }
    static func ssrc(_ p: Data) -> UInt32 {
        let s = p.startIndex
        return UInt32(p[s + 8]) << 24 | UInt32(p[s + 9]) << 16 | UInt32(p[s + 10]) << 8 | UInt32(p[s + 11])
    }
}

/// Bir SSRC'nin son N paketini seq'e göre tutar; NACK gelince orijinal baytlar aynen yollanır
/// (aynı seq ve zaman damgası; alıcı seq ile tekilleştirir).
final class RtpRetransmitRing: @unchecked Sendable {
    static let defaultCapacity = 2048
    private let lock = NSLock()
    private let mask: Int
    private var packets: [Data?]
    private var seqs: [UInt16]
    private var lastRtx: [UInt64]

    /// `capacity` 2'nin kuvveti olmalı (seq 16 bit; 65536 buna bölünür, dolayısıyla sarma tutarlı).
    init(capacity: Int = RtpRetransmitRing.defaultCapacity) {
        precondition(capacity > 0 && capacity & (capacity - 1) == 0 && 65536 % capacity == 0)
        mask = capacity - 1
        packets = Array(repeating: nil, count: capacity)
        seqs = Array(repeating: 0, count: capacity)
        lastRtx = Array(repeating: 0, count: capacity)
    }

    func store(_ packet: Data) {
        let seq = RtpHeader.sequence(packet)
        let i = Int(seq) & mask
        lock.lock()
        packets[i] = packet
        seqs[i] = seq
        lastRtx[i] = 0
        lock.unlock()
    }

    /// Halkada varsa ve son `minInterval` ns içinde yeniden gönderilmediyse paketi verir ve zamanı işler.
    func fetchForRetransmit(seq: UInt16, nowNs: UInt64, minIntervalNs: UInt64) -> Data? {
        let i = Int(seq) & mask
        lock.lock(); defer { lock.unlock() }
        guard let p = packets[i], seqs[i] == seq else { return nil }
        if lastRtx[i] != 0, nowNs &- lastRtx[i] < minIntervalNs { return nil }
        lastRtx[i] = nowNs
        return p
    }
}

/// SSRC başına ayrı halka: ses NACK'ı sonradan eklenirse yalnız `register` yetsin diye genel tutuldu.
final class RtpRetransmitStore: @unchecked Sendable {
    private let lock = NSLock()
    private var rings: [UInt32: RtpRetransmitRing] = [:]

    func register(ssrc: UInt32, capacity: Int = RtpRetransmitRing.defaultCapacity) {
        lock.lock(); defer { lock.unlock() }
        if rings[ssrc] == nil { rings[ssrc] = RtpRetransmitRing(capacity: capacity) }
    }

    func ring(for ssrc: UInt32) -> RtpRetransmitRing? {
        lock.lock(); defer { lock.unlock() }
        return rings[ssrc]
    }

    /// Kaydı olan bir SSRC'nin paketini halkaya yazar; kayıtsız SSRC'ler (ör. ses) yok sayılır.
    func record(_ packet: Data) {
        ring(for: RtpHeader.ssrc(packet))?.store(packet)
    }
}

/// RFC 4585 geri bildirim paketleri. Yalnız Generic NACK (RTPFB, PT=205, FMT=1) okunur.
enum RtcpFeedback {
    struct Nack: Equatable {
        let mediaSsrc: UInt32
        let seqs: [UInt16]
    }

    static let rtpfb: UInt8 = 205

    /// (Bileşik olabilen) RTCP gönderisindeki tüm Generic NACK'ları çıkarır; bozuk/kısa kısımları atlar.
    static func parseNacks(_ data: Data) -> [Nack] {
        let b = [UInt8](data)
        var out: [Nack] = []
        var off = 0
        while off + 4 <= b.count {
            let version = b[off] >> 6
            let fmt = b[off] & 0x1F
            let pt = b[off + 1]
            let size = ((Int(b[off + 2]) << 8 | Int(b[off + 3])) + 1) * 4
            guard version == 2, size >= 4, off + size <= b.count else { break }
            if pt == rtpfb, fmt == 1, size >= 12 {
                let media = UInt32(b[off + 8]) << 24 | UInt32(b[off + 9]) << 16
                    | UInt32(b[off + 10]) << 8 | UInt32(b[off + 11])
                var seqs: [UInt16] = []
                var i = off + 12
                while i + 4 <= off + size {
                    let pid = UInt16(b[i]) << 8 | UInt16(b[i + 1])
                    let blp = UInt16(b[i + 2]) << 8 | UInt16(b[i + 3])
                    seqs.append(pid)
                    for k in 0..<16 where blp & (1 << UInt16(k)) != 0 { seqs.append(pid &+ UInt16(k) &+ 1) }
                    i += 4
                }
                out.append(Nack(mediaSsrc: media, seqs: seqs))
            }
            off += size
        }
        return out
    }
}

/// Basit token-bucket (bayt/sn). Saat dışarıdan verilir → deterministik test.
struct TokenBucket {
    private(set) var rate: Double
    private(set) var capacity: Double
    private var tokens: Double
    private var last: Double

    init(rate: Double, capacity: Double, now: Double) {
        self.rate = rate
        self.capacity = capacity
        tokens = capacity
        last = now
    }

    private mutating func refill(_ now: Double) {
        if now > last { tokens = min(capacity, tokens + (now - last) * rate); last = now }
    }

    /// Hız/kapasite değişimi: o ana dek biriken jeton eski hızla hesaplanır.
    mutating func reconfigure(rate newRate: Double, capacity newCapacity: Double, now: Double) {
        refill(now)
        rate = newRate
        capacity = newCapacity
        tokens = min(tokens, newCapacity)
    }

    /// Yeterli jeton varsa düşer ve true döner.
    mutating func tryTake(_ bytes: Int, now: Double) -> Bool {
        refill(now)
        guard tokens >= Double(bytes) else { return false }
        tokens -= Double(bytes)
        return true
    }

    /// `bytes` için gereken jetona kadar beklenecek süre (sn); 0: şimdi gönderilebilir.
    mutating func waitTime(for bytes: Int, now: Double) -> Double {
        refill(now)
        return tokens >= Double(bytes) ? 0 : (Double(bytes) - tokens) / rate
    }
}

/// Pacer'ın bekleyen paketleri; erişim birimi (AU) sınırı korunur ki taşma durumunda
/// paketler değil bütün kareler atılsın.
struct PacerQueue {
    struct Item { let packet: Data; let au: UInt64 }
    private var items: [Item] = []
    private var head = 0
    private(set) var bytes = 0

    var isEmpty: Bool { head >= items.count }

    mutating func append(_ packets: [Data], au: UInt64) {
        for p in packets { items.append(Item(packet: p, au: au)); bytes += p.count }
    }

    func peek() -> Item? { head < items.count ? items[head] : nil }

    mutating func pop() {
        guard head < items.count else { return }
        bytes -= items[head].packet.count
        head += 1
        if head > 4096 && head * 2 > items.count { items.removeFirst(head); head = 0 }
    }

    /// Bekleyen bayt `limit`'i aşıyorsa en eski AU'ları sırayla atar; en yeni AU her zaman kalır.
    /// Atılan (paket, AU) sayısını döndürür.
    mutating func dropOldest(limit: Int) -> (packets: Int, aus: Int) {
        var droppedPackets = 0, droppedAus = 0
        while bytes > limit, head < items.count, items[head].au != items[items.count - 1].au {
            let au = items[head].au
            while head < items.count, items[head].au == au {
                bytes -= items[head].packet.count
                head += 1
                droppedPackets += 1
            }
            droppedAus += 1
        }
        return (droppedPackets, droppedAus)
    }
}
