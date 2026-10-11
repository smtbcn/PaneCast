import CoreMedia
import Foundation

/// RTP/UDP ses yükü: L16 PCM (RFC 3551, PT=97, 48 kHz stereo, 5 ms paketler).
///
/// Neden hâlâ L16: AAC'ye geçiş iki ölçülen engelle durdu —
/// 1) `AVAudioCompressedBuffer(format:packetCapacity:maximumPacketSize:)` bu macOS'ta geçerli her
///    AAC biçiminde (hem `AVAudioFormat(settings:)` hem ASBD'den kurulan) AudioToolbox içinde
///    SIGSEGV üretiyor; crash raporu `EABLImpl::create` + `-[AVAudioBuffer initWithFormat:...]`.
/// 2) Aynı işin C API'si `AudioConverterFillComplexBuffer` `kAudioConverterErr_UnspecifiedError`
///    ('what') dönüyor; cookie düzgün bayt gösterimiyle de verildi (`!dat`).
/// L16 standart ve kayıpsız; yerel ağda 1,5 Mbps bedeli kabul edilebilir.
///
/// Girdi iki yoldan gelir. Birincisi Core Audio süreç tap'i: **interleaved float32**, 48 kHz,
/// çağrı başına host zamanı (`mHostTime`) ile. İkincisi ScreenCaptureKit yedeği: **planar float32**
/// (ölçüldü: `48000 Hz/2 ch/32 bit/float/planar`) ve `CMSampleBuffer` PTS'i. Planar tamponu düz dizi
/// gibi okumak kanalları üst üste bindirip sesi cızırtıya çeviriyordu; kanallar dilimlere ayrılır,
/// örnek örnek sıralanır, sonra ağ sırasına (büyük uçlu) yazılır.
///
/// Zaman damgası oturumun ortak köküne bağlıdır (`SessionEpoch`): paketin ilk örneğinin host
/// zamanı kökten çıkarılıp 48 kHz'e çevrilir; böylece görüntüyle aynı eksende durur.
final class PcmAudioPacketizer: @unchecked Sendable {
    /// 5 ms @ 48 kHz = 240 örnek/kanal → 960 bayt yük + 12 bayt başlık = 972 B (MTU altı).
    static let samplesPerPacket = 240
    static let headerSize = 12

    let ssrc: UInt32
    let payloadType: UInt8
    let sampleRate = 48_000
    let channelCount = 2

    private var sequence: UInt16 = UInt32.random(in: 0...UInt32(UInt16.max)).uint16Value
    private var timeline: AudioTimeline
    private var dither = Dither()
    /// Tek paketlik sınırlı tampon: dolunca paket çıkar, hiçbir zaman büyümez.
    private var carry: [Int16] = []

    var packetsSent = 0
    var bytesSent = 0
    var rejected = 0
    var onLog: ((String) -> Void)?
    private var loggedFormat = false
    private var loggedFailure = false

    static var lastReason = "henüz dönüşüm denenmedi"
    static var lastPath = "-"

    init(ssrc: UInt32, payloadType: UInt8, epoch: SessionEpoch) {
        self.ssrc = ssrc
        self.payloadType = payloadType
        self.timeline = AudioTimeline(epoch: epoch)
        carry.reserveCapacity(Self.samplesPerPacket * channelCount)
    }

    var reanchors: Int { timeline.reanchors }
    /// Paketlenmeyi bekleyen örnek sayısı (hep bir paketten az).
    var pendingSamples: Int { carry.count }

    /// Core Audio tap'inden: interleaved float32, `channels` kanal, ilk örneğin host zamanı `hostSeconds`.
    func packets(interleaved p: UnsafePointer<Float>, frames: Int, channels: Int, hostSeconds: Double) -> [Data] {
        guard frames > 0, channels > 0 else { return [] }
        if !loggedFormat {
            loggedFormat = true
            onLog?("ses girdisi: tap · \(channels) ch interleaved float32 · L16/PT=\(payloadType) · paket \(Self.samplesPerPacket) örnek/kanal")
        }
        return ingest(frames: frames, hostSeconds: hostSeconds) { f in
            let l = p[f * channels]
            return (l, channels > 1 ? p[f * channels + 1] : l)
        }
    }

    /// ScreenCaptureKit yedeğinden: planar float32, zaman damgası `CMSampleBuffer` PTS'i (host saati).
    func packets(from sb: CMSampleBuffer) -> [Data] {
        guard sb.isValid, let planes = Self.floatPlanes(sb) else {
            rejected += 1
            if !loggedFailure {
                loggedFailure = true
                onLog?("ses çerçevesi okunamadı: \(Self.lastReason) · "
                      + Self.formatNote(sb, declaredRate: sampleRate, declaredChannels: channelCount))
            }
            return []
        }
        if !loggedFormat {
            loggedFormat = true
            onLog?(Self.formatNote(sb, declaredRate: sampleRate, declaredChannels: channelCount)
                   + " · L16/PT=\(payloadType) · paket \(Self.samplesPerPacket) örnek/kanal")
        }
        let frames = planes.map { $0.count }.min() ?? 0
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let host = pts.isNumeric ? CMTimeGetSeconds(pts)
            : HostClock.now() - Double(frames) / Double(sampleRate)
        return ingest(frames: frames, hostSeconds: host) { f in
            (planes[0][f], planes.count > 1 ? planes[1][f] : planes[0][f])
        }
    }

    private func ingest(frames: Int, hostSeconds: Double, sample: (Int) -> (Float, Float)) -> [Data] {
        let unit = Self.samplesPerPacket * channelCount
        switch timeline.place(hostSeconds: hostSeconds, pendingFrames: carry.count / channelCount) {
        case .reanchored(let driftMs):
            carry.removeAll(keepingCapacity: true)
            onLog?(String(format: "ses saati yeniden çapalandı: sapma %+.1f ms (toplam %d)", driftMs, timeline.reanchors))
        case .anchored, .continuous:
            break
        }
        var out: [Data] = []
        for f in 0..<frames {
            let (l, r) = sample(f)
            carry.append(dither.quantize(l))
            carry.append(dither.quantize(r))
            if carry.count == unit {
                out.append(packet(samples: carry, timestamp: timeline.currentTimestamp))
                timeline.advance(frames: Self.samplesPerPacket)
                carry.removeAll(keepingCapacity: true)
            }
        }
        return out
    }

    private func packet(samples: [Int16], timestamp: UInt32) -> Data {
        var p = Data(capacity: Self.headerSize + samples.count * 2)
        p.append(0x80)
        p.append(payloadType | 0x80)                 // marker: AU sınırı (L16 için anlamsız ama zararsız)
        p.append(UInt8(sequence >> 8)); p.append(UInt8(sequence & 0xFF))
        p.append(UInt8(timestamp >> 24)); p.append(UInt8((timestamp >> 16) & 0xFF))
        p.append(UInt8((timestamp >> 8) & 0xFF)); p.append(UInt8(timestamp & 0xFF))
        p.append(UInt8(ssrc >> 24)); p.append(UInt8((ssrc >> 16) & 0xFF))
        p.append(UInt8((ssrc >> 8) & 0xFF)); p.append(UInt8(ssrc & 0xFF))
        for s in samples {
            p.append(UInt8(truncatingIfNeeded: Int(s) >> 8))
            p.append(UInt8(truncatingIfNeeded: Int(s) & 0xFF))
        }
        sequence = sequence &+ 1
        packetsSent += 1
        bytesSent += p.count
        return p
    }

    // MARK: - Yakalama tamponu okuma (ScreenCaptureKit yedeği)

    /// Planar (ya da interleaved) float32 tamponunu kanal dilimlerine ayırır.
    /// Yalnızca ölçülen gerçek biçim (float32) kabul edilir; başka bir şey gelirse
    /// tahmin edilmez, red loglanır.
    static func floatPlanes(_ sb: CMSampleBuffer) -> [[Float]]? {
        guard let desc = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else {
            lastReason = "ASBD okunamadı"; return nil
        }
        let asbd = asbdPtr.pointee
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard isFloat, asbd.mBitsPerChannel == 32 else {
            lastReason = "float32 değil (\(asbd.mBitsPerChannel) bit, float=\(isFloat))"; return nil
        }
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        guard let planes = blockPlanes(sb, channels: channels, planar: planar) else { return nil }
        lastPath = "bitişik-blok"
        guard (planes.map { $0.count }.min() ?? 0) > 0 else { lastReason = "boş kanal"; return nil }
        if !planar && channels > 1 {
            // Tek dilimde örnek örnek dizilmiş kanallar: kanal dilimlerine ayır.
            let all = planes[0]
            let frames = all.count / channels
            return (0..<channels).map { c in (0..<frames).map { all[$0 * channels + c] } }
        }
        return planes
    }

    /// Blok bitişikse kanal dilimleri eşit boyda ve sıralıdır; çerçeve sayısıyla doğrulanır,
    /// uyuşmazsa cızırtı göndermek yerine reddedilir.
    private static func blockPlanes(_ sb: CMSampleBuffer, channels: Int, planar: Bool) -> [[Float]]? {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { lastReason = "veri tamponu yok"; return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let base = pointer else {
            lastReason = "bitişik olmayan blok"; return nil
        }
        let planeCount = planar ? max(1, channels) : 1
        guard length % planeCount == 0 else {
            lastReason = "blok \(length)B \(planeCount) kanala bölünmüyor"; return nil
        }
        let planeBytes = length / planeCount
        let frames = planeBytes / MemoryLayout<Float>.size
        let declared = CMSampleBufferGetNumSamples(sb)
        guard frames > 0, declared == 0 || declared == frames else {
            lastReason = "çerçeve uyuşmazlığı: numSamples=\(declared) dilim=\(frames)"; return nil
        }
        let raw = UnsafeMutableRawPointer(base)
        return (0..<planeCount).map {
            Array(UnsafeBufferPointer(start: raw.advanced(by: $0 * planeBytes)
                        .assumingMemoryBound(to: Float.self), count: frames))
        }
    }

    static func formatNote(_ sb: CMSampleBuffer, declaredRate: Int, declaredChannels: Int) -> String {
        guard let desc = CMSampleBufferGetFormatDescription(sb),
              let a = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
            return "ses biçimi okunamadı"
        }
        let planar = a.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let float = a.mFormatFlags & kAudioFormatFlagIsFloat != 0
        return String(format: "ses biçimi: %.0f Hz/%d ch/%d bit/%@/%@ (beyan: %d Hz/%d ch) yol=%@",
                      a.mSampleRate, a.mChannelsPerFrame, a.mBitsPerChannel,
                      float ? "float" : "int", planar ? "planar" : "interleaved",
                      declaredRate, declaredChannels, lastPath)
    }
}

/// float32 → int16 dönüşümü: kırpma + TPDF dither (±1 LSB üçgen dağılım). Kesmek (truncation)
/// sessiz bölümlerde ve kuyruklarda niceleme bozulması üretir; üçgen gürültü onu yayar.
/// Tam sıfır girdi (dijital sessizlik) dither'lanmaz, çıktı da tam sıfır kalır.
struct Dither {
    private var state: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func quantize(_ x: Float) -> Int16 {
        guard x.isFinite, x != 0 else { return 0 }
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27     // xorshift64*
        let r = state &* 2_685_821_657_736_338_717
        let u1 = Float(UInt32(truncatingIfNeeded: r >> 32)) * (1.0 / 4_294_967_296.0)
        let u2 = Float(UInt32(truncatingIfNeeded: r)) * (1.0 / 4_294_967_296.0)
        let v = max(-1.0, min(1.0, x)) * 32767.0 + (u1 - u2)
        return Int16(max(-32768.0, min(32767.0, v.rounded())))
    }
}
