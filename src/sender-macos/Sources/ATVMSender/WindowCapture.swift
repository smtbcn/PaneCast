import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

struct WindowInfo: Identifiable, CustomStringConvertible {
    let id: UInt32
    let app: String
    /// Sesin kaynağı: yayınlanan uygulamanın Mac'te duyulan sesini susturmak için.
    let pid: pid_t
    let title: String
    let frame: CGRect
    let onScreen: Bool
    var description: String {
        "id=\(id) app=\(app) title=\"\(title)\" frame=\(frame.integral) onScreen=\(onScreen)"
    }
}

enum CaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case windowNotFound(UInt32)
    case stream(String)
    var description: String {
        switch self {
        case .permissionDenied:
            return "Ekran Kaydı izni yok — Sistem Ayarları → Gizlilik ve Güvenlik → Ekran Kaydı"
        case .windowNotFound(let id): return "pencere bulunamadı (id=\(id))"
        case .stream(let m): return "yakalama akışı hatası: \(m)"
        }
    }
}

/// ScreenCaptureKit ile SEÇİLİ PENCERENİN yüzeyini yakalar.
/// Çıktı NV12 CVPixelBuffer → doğrudan VideoToolbox'a verilir (RGB ara tamponu yok).
final class WindowCapture: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private let windowId: UInt32
    /// Doluysa pencere yerine bu ekranın tamamı yakalanır (TV ekranı modu).
    private let displayId: CGDirectDisplayID?
    private var targetWidth: Int
    private var targetHeight: Int
    private var config: SCStreamConfiguration?
    /// SCK rengi zayıf tutar: sahipsiz bırakılırsa dolgu rengi bozulur.
    private static let black = CGColor(gray: 0, alpha: 1)
    private let fps: Int
    private let onFrame: (CVPixelBuffer, CMTime) -> Void
    /// nil ise SCK sesi yakalanmaz (tap kullanılıyor ya da ses kapalı); dolu ise yedek yol: yalnızca bu pencerenin uygulamasının PCM'i gelir.
    private let onAudio: ((CMSampleBuffer) -> Void)?

    var framesDelivered = 0
    fileprivate var lastContentDesc = ""
    var audioDelivered = 0
    var lastError: String?

    private let latLock = NSLock()
    private var captureLatencies: [Double] = []
    /// SCK karesinin compositor'dan çıkışı ile bize teslimi arasındaki süre (ms).
    /// PTS host saatindedir; `CMSampleBufferGetPTCMediaTime` ile karşılaştırılır.
    func captureLatencyPercentiles() -> (p50: Double, p95: Double, n: Int) {
        latLock.lock(); defer { latLock.unlock() }
        let l = captureLatencies.sorted()
        guard !l.isEmpty else { return (0, 0, 0) }
        return (l[l.count / 2], l[min(l.count - 1, l.count * 95 / 100)], l.count)
    }

    private let stateLock = NSLock()
    private var _fatalStopReason: String?
    /// SCK akışı kendiliğinden durduysa (pencere kapandı) neden mesajı; ana döngü bunu görüp yayını bitirir.
    var fatalStopReason: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _fatalStopReason }
        set { stateLock.lock(); _fatalStopReason = newValue; stateLock.unlock() }
    }

    init(windowId: UInt32, width: Int, height: Int, fps: Int,
         audio: Bool = false,
         onFrame: @escaping (CVPixelBuffer, CMTime) -> Void,
         onAudio: ((CMSampleBuffer) -> Void)? = nil) {
        self.windowId = windowId
        self.displayId = nil
        self.targetWidth = width
        self.targetHeight = height
        self.fps = fps
        self.onFrame = onFrame
        self.onAudio = audio ? onAudio : nil
        super.init()
    }

    /// Bir ekranın tamamını yakalar (pencere kimliği yok). Ses SCK'dan alınmaz: sahipleri tap'ten gelir.
    init(displayId: CGDirectDisplayID, width: Int, height: Int, fps: Int,
         onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.windowId = 0
        self.displayId = displayId
        self.targetWidth = width
        self.targetHeight = height
        self.fps = fps
        self.onFrame = onFrame
        self.onAudio = nil
        super.init()
    }

    /// Ekran kaydı iznini ister.
    ///
    /// DÜZELTİLEN KUSUR: yalnızca CGRequestScreenCaptureAccess() çağırıp false dönerse
    /// çıkmak, sistem onay penceresini hiç tetiklemiyordu (ölçüldü: diyalog hiç açılmadı).
    /// macOS 14+'ta asıl isteği SCShareableContent çağrısı tetikler; bu yüzden önce o denenir.
    static func ensurePermission(waitSeconds: Double = 0) async throws {
        // 1) Zaten verilmişse hemen dön.
        if await canListContent() { return }
        // 2) Sistem onay penceresini iste. Bu çağrı tek başına yetmiyor: kullanıcı
        //    yanıtlayana kadar süreç yaşıyor olmalı, aksi halde diyalog görünüp kayboluyor
        //    (ölçüldü: CLI izin isteyip anında çıktığı için diyalog hiç açılmadı).
        CGRequestScreenCaptureAccess()
        if await canListContent() { return }
        guard waitSeconds > 0 else { throw CaptureError.permissionDenied }

        FileHandle.standardError.write("""
        ┌────────────────────────────────────────────────────────────────────┐
        │  EKRAN KAYDI İZNİ BEKLENİYOR (${String(format: "%.0f", waitSeconds)} sn)                        │
        │                                                                    │
        │  1) Açılan "Ekran Kaydı" uyarısında İZİN VER'e bas.                │
        │     Uyarı görünmediyse:                                            │
        │  2) Sistem Ayarları → Gizlilik ve Güvenlik → Ekran Kaydı           │
        │     listesinde "PaneCast" anahtarını aç.             │
        │     (Listede yoksa "+" ile şuradan ekle:                           │
        │      artifacts/build/PaneCast.app)                    │
        │  3) Anahtarı açınca bu komut kendiliğinden devam eder.             │
        └────────────────────────────────────────────────────────────────────┘

        """.data(using: .utf8)!)
        let deadline = Date().addingTimeInterval(waitSeconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if await canListContent() {
                FileHandle.standardError.write("izin alındı, devam ediliyor\n".data(using: .utf8)!)
                return
            }
        }
        throw CaptureError.permissionDenied
    }

    private static func canListContent() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch let e as NSError {
            // Tanılama: "izin yok" sanılan başka hatalar gerçekten izin hatası olmayabilir.
            FileHandle.standardError.write("SCShareableContent hata: domain=\(e.domain) code=\(e.code) \(e.localizedDescription)\n".data(using: .utf8)!)
            return false
        } catch {
            FileHandle.standardError.write("SCShareableContent hata: \(error)\n".data(using: .utf8)!)
            return false
        }
    }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func shareableWindows() async throws -> [WindowInfo] {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            lastPermissionPromptShown = true
            return content.windows.map { w in
                let wid = w.windowID
                return WindowInfo(id: wid,
                                  app: w.owningApplication?.applicationName ?? "?",
                                  pid: w.owningApplication?.processID ?? -1,
                                  title: w.title ?? "",
                                  frame: w.frame,
                                  onScreen: w.isOnScreen)
            }
        } catch let e as NSError {
            if e.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain", e.code == -3801 {
                throw CaptureError.permissionDenied
            }
            throw CaptureError.stream(e.localizedDescription)
        }
    }

    private static var lastPermissionPromptShown = false

    func start() async throws {
        let filter: SCContentFilter
        if let displayId {
            filter = SCContentFilter(display: try await TvDisplay.shareableDisplay(displayId), excludingWindows: [])
        } else {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowId }) else {
                throw CaptureError.windowNotFound(windowId)
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let config = SCStreamConfiguration()
        // Boyutu çağıran (main) pencereye göre hesaplayıp verir; burada yeniden kırpma yok.
        // Önceki davranış TV'ye bildirilen çözünürlük ile gerçek kodlanan çözünürlüğün
        // farklı olmasına yol açıyordu (1920x990 stream, 1920x1080 MediaFormat) ve
        // MStar çözücü bu uyuşmazlıkta kare üretmeyi durduruyordu.
        config.width = targetWidth
        config.height = targetHeight
        // Çıktı çerçevesi pencereyle aynı orandadır (VideoGeometry); yine de SCK asla germesin:
        // oran farkı varsa (asgari boyut dolgusu) içerik ortalanır, kalan siyah kalır.
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.backgroundColor = Self.black
        // Gölge çerçeveye girerse içerik oranı pencere oranından sapar.
        config.ignoreShadowsSingleWindow = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        if onAudio != nil {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = false
        } else {
            // Ses tap'ten geliyorsa SCK ikinci kez yakalamasın (çift ses + gereksiz iş).
            config.capturesAudio = false
        }

        configuredSize = CGSize(width: config.width, height: config.height)
        self.config = config
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "atvm.sck", qos: .userInteractive))
        if onAudio != nil {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "atvm.sck.audio", qos: .userInteractive))
        }
        try await s.startCapture()
        self.stream = s
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    /// Aynı kaynakla yakalamayı taze kurar: `start()` SCShareableContent'i yeniden sorup
    /// yeni bir filtre kurar, böylece yüzey yeniden besteleniyorsa akış döner.
    /// Kare sayaçları sıfırlanmaz — donma tespiti onların monoton artmasına dayanıyor.
    func restart() async throws {
        await stop()
        try await start()
    }

    /// Akış kapanmadan çıktı boyutunu değiştirir (pencere yeniden boyutlandı).
    func resize(width: Int, height: Int) async throws {
        guard let stream, let config else { return }
        config.width = width
        config.height = height
        try await stream.updateConfiguration(config)
        targetWidth = width; targetHeight = height
        configuredSize = CGSize(width: width, height: height)
    }

    /// Yayınlanan hedef boyut (start sonrası).
    private(set) var configuredSize: CGSize?
}

private func even(_ v: Int) -> Int { v - (v % 2) }

extension WindowCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            guard sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
            audioDelivered += 1
            onAudio?(sampleBuffer)
            return
        }
        guard type == .screen, sampleBuffer.isValid,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        framesDelivered += 1
        noteContentRect(sampleBuffer, pb)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // SCK kare PTS'i host saatindedir (CMSampleBufferGetPTCMediaTime bu SDK'da yok),
        // bu yüzden doğrudan host saatiyle karşılaştırılır.
        let host = CMClockGetHostTimeClock()
        let hostNow = CMClockGetTime(host).seconds
        let media = CMTimeGetSeconds(pts)
        if media > 0 {
            let ms = (hostNow - media) * 1000.0
            if ms >= 0 && ms < 5000 {
                latLock.lock()
                if captureLatencies.count < 2000 { captureLatencies.append(ms) }
                latLock.unlock()
            }
        }
        onFrame(pb, pts)
    }
}

extension WindowCapture {
    /// Tanılama: SCK'nın bildirdiği içerik dikdörtgeni / ölçek ve gerçek tampon boyutu değişince bir satır.
    /// Gölge ya da dolgu çerçeveye girdiyse oran sapması buradan görülür.
    fileprivate func noteContentRect(_ sb: CMSampleBuffer, _ pb: CVPixelBuffer) {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = arr.first else { return }
        var desc = "tampon=\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))"
        if let r = info[.contentRect] { desc += " içerik=\(r)" }
        if let sf = info[.scaleFactor] { desc += " ölçek=\(sf)" }
        if let cs = info[.contentScale] { desc += " içerikÖlçeği=\(cs)" }
        if desc != lastContentDesc {
            lastContentDesc = desc
            FileHandle.standardError.write("yakalama çerçevesi: \(desc)\n".data(using: .utf8)!)
        }
    }
}

extension WindowCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lastError = error.localizedDescription
        fatalStopReason = error.localizedDescription
    }
}
