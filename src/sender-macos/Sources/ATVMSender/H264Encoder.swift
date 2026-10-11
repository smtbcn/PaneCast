import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// VideoToolbox H.264 kodlayıcı sarmalayıcı.
/// Ölçülmüş taban (bu Mac, scripts/mac-encoder-probe.sh): 1080p60'ta p50 7 ms / p95 10.5 ms, 0 drop.
/// encodeFrame → callback gecikmesini ölçmek için kare-başına zaman damgası.
final class SubmitStamp { let host: CFTimeInterval; init(_ h: CFTimeInterval) { host = h } }

final class H264Encoder: @unchecked Sendable {
    struct Profile {
        let width: Int
        let height: Int
        let fps: Int
        let bitrate: Int

        static let presets: [String: Profile] = [
            "1080p60": Profile(width: 1920, height: 1080, fps: 60, bitrate: 12_000_000),
            "1080p30": Profile(width: 1920, height: 1080, fps: 30, bitrate: 8_000_000),
            "720p60": Profile(width: 1280, height: 720, fps: 60, bitrate: 6_000_000),
        ]
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case noHardwareEncoder(OSStatus)
        case sessionCreate(OSStatus)
        var description: String {
            switch self {
            case .noHardwareEncoder(let s): return "donanım H.264 kodlayıcı açılamadı (OSStatus \(s))"
            case .sessionCreate(let s): return "VTCompressionSessionCreate başarısız (OSStatus \(s))"
            }
        }
    }

    /// Kodlanmış erişim birimi çıktısı: (Annex-B baytları, PTS, keyframe mi)
    let onAccessUnit: (Data, CMTime, Bool) -> Void

    private var session: VTCompressionSession?
    private var parameterSets: [Data] = []
    private var nextIsKeyframe = true
    private let lock = NSLock()
    /// Oturum değişimi (yeniden yapılandırma) ile kare gönderimi birbirini beklemeli:
    /// Invalidate edilmiş oturuma kare vermek tanımsız davranış.
    private let sessionLock = NSLock()
    private var profile: Profile?

    // Ölçüm sayaçları
    private(set) var framesSubmitted = 0
    private(set) var framesEncoded = 0
    private(set) var bytesEncoded = 0
    private(set) var keyframes = 0
    private(set) var encodeLatencyMs: [Double] = []
    /// Oturum boyutuna uymayan kare (pencere yeniden boyutlanırken eski boyutlu kareler gelir).
    private(set) var droppedSizeMismatch = 0

    init(onAccessUnit: @escaping (Data, CMTime, Bool) -> Void) {
        self.onAccessUnit = onAccessUnit
    }

    func start(_ p: Profile) throws {
        sessionLock.lock(); defer { sessionLock.unlock() }
        try startLocked(p)
    }

    private func startLocked(_ p: Profile) throws {
        teardownLocked()
        var spec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
        ]
        _ = spec  // not: değişmiyor; ileride encoder id seçimi için tutuluyor
        var ref: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(p.width), height: Int32(p.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: vtCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &ref)
        guard st == noErr, let ref else { throw Error.sessionCreate(st) }

        let props: [String: Any] = [
            kVTCompressionPropertyKey_RealTime as String: true,
            // B-frame yok → tek yönlü gecikme yok, çözücü sıralama beklemez
            kVTCompressionPropertyKey_AllowFrameReordering as String: false,
            kVTCompressionPropertyKey_ExpectedFrameRate as String: p.fps,
            // Sabit bitrate (CBR): AverageBitRate + DataRateLimits ile ölçülen taşma
            // ~33 Mbps / 12 Mbps hedefi idi (sentetik yüksek entropi deseni, cihaz ölçümümüz.1).
            // CBR + VBV sınırının gerçek içerikteki etkisi yeniden ölçülecek.
            kVTCompressionPropertyKey_ConstantBitRate as String: p.bitrate,
            kVTCompressionPropertyKey_DataRateLimits as String: [p.bitrate / 8, 1],
            // Çözücünün kare bekletme sayısını sınırla (B-frame yok ama gecikme birikmesin).
            kVTCompressionPropertyKey_MaxFrameDelayCount as String: 1,
            kVTCompressionPropertyKey_MaxKeyFrameInterval as String: p.fps * 2,
            kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel,
        ]
        let setSt = VTSessionSetProperties(ref, propertyDictionary: props as CFDictionary)
        if setSt != noErr { FileHandle.standardError.write("uyarı: bazı kodlayıcı özellikleri kabul edilmedi (\(setSt))\n".data(using: .utf8)!) }
        VTCompressionSessionPrepareToEncodeFrames(ref)
        self.session = ref
        self.profile = p
        lock.lock(); nextIsKeyframe = true; lock.unlock()
    }

    /// Yayını kesmeden boyut değişimi: eski oturum boşaltılıp kapatılır, yenisi açılır.
    /// Yeni oturumun ilk karesi IDR'dir ve SPS/PPS'i taşır; alıcı çözücü yeni boyuta uyarlanır.
    func reconfigure(_ p: Profile) throws {
        sessionLock.lock(); defer { sessionLock.unlock() }
        if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }
        teardownLocked()
        try startLocked(p)
    }

    func forceKeyframe() {
        lock.lock(); nextIsKeyframe = true; lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard let session, let profile else { return }
        // Yeniden boyutlama sırasında eski boyutlu kare yeni oturuma girerse atılır.
        guard CVPixelBufferGetWidth(pixelBuffer) == profile.width,
              CVPixelBufferGetHeight(pixelBuffer) == profile.height else {
            lock.lock(); droppedSizeMismatch += 1; lock.unlock()
            return
        }
        lock.lock(); let force = nextIsKeyframe; nextIsKeyframe = false; framesSubmitted += 1; lock.unlock()
        var flags = VTEncodeInfoFlags()
        let props: [String: Any] = force
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] : [:]
        // Kare-başına gecikme ölçümü: gönderim anı sourceFrameRefcon ile callback'e taşınır.
        let stamp = Unmanaged.passRetained(SubmitStamp(CFAbsoluteTimeGetCurrent()))
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: CMTime(value: 1, timescale: CMTimeScale(30)),
            frameProperties: props as CFDictionary,
            sourceFrameRefcon: stamp.toOpaque(), infoFlagsOut: &flags)
    }

    func drain() {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    /// Kodlama gecikmesi yüzdelikleri (ms) —  iç ölçüm noktası.
    func latencyPercentiles() -> (p50: Double, p95: Double) {
        lock.lock(); defer { lock.unlock() }
        let l = encodeLatencyMs.sorted()
        guard !l.isEmpty else { return (0, 0) }
        return (l[l.count / 2], l[min(l.count - 1, l.count * 95 / 100)])
    }

    func teardown() {
        sessionLock.lock(); defer { sessionLock.unlock() }
        teardownLocked()
    }

    private func teardownLocked() {
        guard let session else { return }
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    fileprivate func handle(submitHost: CFTimeInterval?, status: OSStatus,
                            infoFlags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sb = sampleBuffer, CMSampleBufferIsValid(sb) else { return }
        let latency = (submitHost.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000.0 }) ?? 0
        guard let format = CMSampleBufferGetFormatDescription(sb) else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sb) else { return }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }
        var dataPointer: UnsafeMutablePointer<CChar>?
        let ptrSt = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard ptrSt == noErr, let dataPointer else { return }
        let raw = Data(bytes: dataPointer, count: length)

        // Keyframe'de SPS/PPS'i öne ekle. Sürücü zaten Annex-B veriyorsa start code dönüşümü atlanır.
        let isKey: Bool
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[String: Any]] {
            isKey = (attachments.first?["NotSync"] as? Bool) != true
        } else { isKey = true }

        let sets: [Data]
        if isKey {
            sets = H264.parameterSets(format)
            self.parameterSets = sets
        } else {
            sets = []       // ara kareler SPS/PPS taşımaz; alıcı IDR'de setleri yeniden alır
        }
        let annexB: Data
        if H264.isLengthPrefixed(raw) {
            annexB = H264.annexB(fromLengthPrefixed: raw, prepend: sets)
        } else if H264.startsWithStartCode(raw) {
            var pre = Data()
            for ps in sets { pre.append(contentsOf: H264.startCode); pre.append(ps) }
            annexB = pre + raw
        } else {
            // İkisi de değil: tahmin etmek yerine söyle — seste de sessiz düşüş böyle yakalanmıştı.
            FileHandle.standardError.write("uyarı: örnek verisi ne AVCC ne Annex-B (\(raw.count) B, ilk baytlar: \(raw.prefix(4).map { String(format: "%02x", $0) }.joined(separator: " "))\n".data(using: .utf8)!)
            var pre = Data()
            for ps in sets { pre.append(contentsOf: H264.startCode); pre.append(ps) }
            annexB = pre + raw
        }

        lock.lock()
        framesEncoded += 1; bytesEncoded += annexB.count
        if isKey { keyframes += 1 }
        if encodeLatencyMs.count < 2000 { encodeLatencyMs.append(latency) }
        lock.unlock()

        onAccessUnit(annexB, CMSampleBufferGetPresentationTimeStamp(sb), isKey)
    }
}

/// C fonksiyon işaretçisi geri çağırması — refcon üzerinden self'e ulaşır.
private func vtCallback(outputCallbackRefCon: UnsafeMutableRawPointer?,
                        sourceFrameRefCon: UnsafeMutableRawPointer?,
                        status: OSStatus,
                        infoFlags: VTEncodeInfoFlags,
                        sampleBuffer: CMSampleBuffer?) {
    guard let refcon = outputCallbackRefCon else { return }
    let encoder = Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
    let stamp: SubmitStamp? = sourceFrameRefCon.map {
        Unmanaged<SubmitStamp>.fromOpaque($0).takeRetainedValue()
    }
    encoder.handle(submitHost: stamp?.host, status: status, infoFlags: infoFlags, sampleBuffer: sampleBuffer)
}
