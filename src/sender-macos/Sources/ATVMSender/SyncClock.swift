import CoreMedia
import Darwin
import Foundation

/// Mac'in host saati (mach absolute time) — ScreenCaptureKit video PTS'i ve Core Audio
/// `mHostTime` aynı saatte olduğu için görüntü ile ses tek eksende buluşur.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// mach tik sayısı → saniye.
    static func seconds(hostTicks: UInt64) -> Double {
        Double(hostTicks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    static func now() -> Double { seconds(hostTicks: mach_absolute_time()) }
}

/// Oturumun ortak saat kökü: görüntü ve ses RTP zaman damgaları aynı an için iki taban
/// seçer. `start` mesajı `video_rtp_base` ve `audio_rtp_base` olarak bunları TV'ye bildirir;
/// alıcı iki taban farkını sıfır kabul edip akışları hizalayabilir.
struct SessionEpoch: Sendable {
    static let videoClockRate = 90_000.0
    static let audioClockRate = 48_000.0

    /// Kök anı (host saati, saniye).
    let hostSeconds: Double
    let videoBase: UInt32
    let audioBase: UInt32

    static func now() -> SessionEpoch {
        SessionEpoch(hostSeconds: HostClock.now(),
                     videoBase: UInt32.random(in: 0...UInt32.max),
                     audioBase: UInt32.random(in: 0...UInt32.max))
    }

    /// Kökten önceki bir an negatif sapma verir; mod 2^32 sarılır.
    func videoTimestamp(hostSeconds t: Double) -> UInt32 {
        videoBase &+ UInt32(truncatingIfNeeded: Int64(((t - hostSeconds) * Self.videoClockRate).rounded()))
    }

    /// Bir anın kökten beri örnek indeksi (48 kHz).
    func audioIndex(hostSeconds t: Double) -> Int64 {
        Int64(((t - hostSeconds) * Self.audioClockRate).rounded())
    }

    func audioTimestamp(index: Int64) -> UInt32 {
        audioBase &+ UInt32(truncatingIfNeeded: index)
    }
}

/// Ses RTP zaman damgasının saf matematiği (test edilebilsin diye paketleyiciden ayrı).
/// Örnek sayacı süreklidir; ama sayaçtan türeyen an ile cihazın bildirdiği host zamanı
/// 20 ms'den fazla ayrışırsa host zamanına yeniden çapalanır.
struct AudioTimeline {
    static let reanchorThresholdSeconds = 0.020

    enum Placement: Equatable {
        case anchored
        case continuous(driftMs: Double)
        case reanchored(driftMs: Double)
    }

    let epoch: SessionEpoch
    /// Henüz paketlenmemiş ilk örneğin kökten beri indeksi; ilk parçaya kadar nil.
    private(set) var nextIndex: Int64?
    private(set) var reanchors = 0

    init(epoch: SessionEpoch) { self.epoch = epoch }

    /// Yeni gelen parçanın ilk örneğinin host zamanı `hostSeconds`; `pendingFrames` önceki
    /// parçadan paketlenmeyi bekleyen örnek sayısı. `.reanchored` dönerse bekleyenler atılmalı.
    mutating func place(hostSeconds: Double, pendingFrames: Int) -> Placement {
        let observed = epoch.audioIndex(hostSeconds: hostSeconds)
        guard let next = nextIndex else {
            nextIndex = observed
            return .anchored
        }
        let drift = observed - (next + Int64(pendingFrames))
        let driftMs = Double(drift) / SessionEpoch.audioClockRate * 1000
        if abs(Double(drift) / SessionEpoch.audioClockRate) > Self.reanchorThresholdSeconds {
            nextIndex = observed
            reanchors += 1
            return .reanchored(driftMs: driftMs)
        }
        return .continuous(driftMs: driftMs)
    }

    var currentTimestamp: UInt32 { epoch.audioTimestamp(index: nextIndex ?? 0) }

    mutating func advance(frames: Int) {
        if let n = nextIndex { nextIndex = n + Int64(frames) }
    }
}
