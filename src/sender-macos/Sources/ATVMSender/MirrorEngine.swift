import Foundation
import CoreMedia
import AppKit

/// Yayın hattının yeniden kullanılabilir çekirdeği: CLI ve GUI aynı şeyi çağırır.
/// Akış: bağlan → hello → (PIN istenirse kullanıcıya sor) → start → yakala/kodla/gönder.
@MainActor
final class MirrorEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notConnected, noWindow, alreadyRunning, tvRejected
        var description: String {
            switch self {
            case .notConnected: return "TV ile kontrol kanalı açık değil"
            case .noWindow: return "yayınlanacak pencere seçilmedi"
            case .alreadyRunning: return "yayın zaten çalışıyor"
            case .tvRejected: return "TV akışı açamadı ya da bağlantı kapandı"
            }
        }
    }

    var onLog: ((String) -> Void)?
    /// Arayüzün durum şeridi için yapılandırılmış sayılar (log metni ayrıştırılmaz).
    var onStats: ((Stats) -> Void)?
    /// Yakalama sessizce durduğunda arayüzün tek satırlık uyarısı; nil = temizle.
    var onStatusNote: ((String?) -> Void)?
    struct Stats {
        let seconds: Double
        let fps: Double
        let mbps: Double
        let packets: Int
        let captureP50: Double
        let encodeP50: Double
        let encodeP95: Double
        let audioPackets: Int
        /// Ağ sayıları: panonun "ağ sağlığı" kutusu bunlarla dolar. Ölçülen eksik: sayaçlar
        /// yalnız günlük satırında duruyor, arayüzde hiç görünmüyordu.
        let nackRequests: Int
        let retransmitted: Int
        let dropped: Int
        /// Ağ yığınına verilen toplam RTP baytı (video + ses + yedek gönderim).
        let wireBytes: Int
    }
    /// Yakalanan pencerenin uygulamasının sesi de TV'ye gönderilsin mi?
    var capturesAudio = true
    /// Yayınlanan uygulamanın Mac'te duyulan sesini sustur (ses yalnız TV'de çalsın).
    /// Yalnız süreç tap'i yolunda mümkün; ScreenCaptureKit yedeğinde susturma yoktur.
    var mutesLocalAppAudio = true
    /// Açık uygulama tap'ini kapatır (nil: tap yok, ses SCK yedeğinden).
    private var stopAppTap: (() -> Void)?
    private(set) var isRunning = false

    private var control: ControlClient?
    private var encoder: H264Encoder?
    private var packetizer: RtpPacketizer?
    private var audioPacketizer: PcmAudioPacketizer?
    private var udp: MediaUdpSender?
    private var capture: WindowCapture?
    private var statsTimer: Timer?
    private var startedAt = Date()
    private var frameCount = 0
    /// Kare akışının sessiz durmasını izler; her oturumda sıfırlanır.
    private var stall = StallGuard()

    func log(_ line: String) { onLog?(line) }

    /// TV'ye bağlanır ve el sıkışır. .needsPin dönerse UI PIN sormalı, sonra beginStream() çağrılır.
    func connectAndHello(host: String, mediaPort: UInt16 = 7602) async throws -> ControlClient.Handshake {
        await stop()
        let c = ControlClient(host: host)
        try await c.connect()
        let hs = try await c.beginHello()
        // TV çözücüsünü yeniden kurduğunda (resim boyutu büyüyünce) anahtar kare ister;
        // yanıtsız kalırsa bir sonraki periyodik IDR'a (≈2 sn) kadar görüntü donuyordu.
        c.onMessage = { [weak self] msg in
            guard (msg["t"] as? String) == "idr_request" else { return }
            Task { @MainActor in self?.requestKeyFrame() }
        }
        self.control = c
        self.mediaPort = mediaPort
        log(hs == .paired ? "TV ile oturum açık (önceden eşlenmiş)" : "TV eşleştirme PIN'i gösteriyor")
        return hs
    }

    private var mediaPort: UInt16 = 7602

    func submitPin(_ pin: String) async throws {
        guard let control else { throw EngineError.notConnected }
        try await control.submitPin(pin)
        log("eşleşme tamam (oturum: \(control.sessionId ?? "?"))")
    }

    /// TV'ye bildirilen akış parametreleri (her iki yönde de aynı sözlük).
    struct StartInfo {
        let width: Int, height: Int, fps: Int, bitrate: Int
        let ssrc: UInt32, mediaPort: UInt16, payloadType: UInt8
        let audioSsrc: UInt32, audioPayloadType: UInt8, audioSampleRate: Int, audioChannels: Int
        /// Ortak saat kökü: iki taban da aynı ana karşılık gelir (`sync`).
        let videoRtpBase: UInt32, audioRtpBase: UInt32
    }

    /// Seçili pencereyi yayınlar. connectAndHello() (ve gerekirse submitPin()) sonrasında çağrılır.
    func beginStream(window: WindowInfo, profile: H264Encoder.Profile) async throws {
        try await beginStream(source: .window(window), profile: profile)
    }

    func beginStream(source: CastSource, profile: H264Encoder.Profile) async throws {
        guard let control else { throw EngineError.notConnected }
        try await runPipeline(source: source, profile: profile, host: controlHost, mediaPort: mediaPort) { info in
            try await control.requestStart(info)
        }
    }

    /// TV kendi bağlantısıyla yayını başlattığında Mac tarafında kontrol kanalı yoktur;
    /// `start` aynı sokete yazılır ve yanıt oradan beklenir.
    func beginForTv(window: WindowInfo, profile: H264Encoder.Profile, host: String, mediaPort: UInt16,
                    announce: @escaping (StartInfo) async -> Bool) async throws {
        try await beginForTv(source: .window(window), profile: profile, host: host, mediaPort: mediaPort, announce: announce)
    }

    func beginForTv(source: CastSource, profile: H264Encoder.Profile, host: String, mediaPort: UInt16,
                    announce: @escaping (StartInfo) async -> Bool) async throws {
        try await runPipeline(source: source, profile: profile, host: host, mediaPort: mediaPort) { info in
            guard await announce(info) else { throw EngineError.tvRejected }
        }
    }

    /// Yayının kaynağı: tek pencere ya da Mac'te açılan sanal "TV ekranı"nın tamamı.
    enum CastSource {
        case window(WindowInfo)
        case tvDisplay
    }

    /// TV ekranı modundaki sanal ekran: oturum boyunca (pencere geçişleri dahil) tutulur, `stop()` bırakır.
    private var tvDisplay: TvDisplay?
    private var tvTracker: TvDisplayAppTracker?
    private(set) var currentSource: CastSource?

    private func runPipeline(source: CastSource, profile: H264Encoder.Profile,
                             host: String, mediaPort: UInt16,
                             announce: @escaping (StartInfo) async throws -> Void) async throws {
        guard !isRunning else { throw EngineError.alreadyRunning }
        self.announce = announce
        self.mediaHost = host

        // Kodlama çerçevesi: kaynağın PİKSEL boyutu (pencere: nokta × ekran ölçeği; TV ekranı: sabit 1920x1080),
        // profil kutusuna oranı bozmadan sığdırılmış (VideoGeometry). `profile` özgün profildir; geçişte yine ondan hesaplanır.
        let pixels: CGSize
        let window: WindowInfo?
        switch source {
        case .window(let w):
            window = w
            pixels = VideoGeometry.windowPixelSize(windowId: w.id) ?? VideoGeometry.pixelSize(points: w.frame)
        case .tvDisplay:
            window = nil
            if tvDisplay == nil { tvDisplay = try TvDisplay.create(onProbe: log) }
            pixels = tvDisplay!.pixelSize
        }
        let p = VideoGeometry.encodeProfile(pixelSize: pixels, base: profile)
        log("\(window == nil ? "TV ekranı" : "pencere") \(Int(pixels.width))x\(Int(pixels.height)) piksel → \(p.width)x\(p.height) kodlanacak (profil kutusu \(profile.width)x\(profile.height))")

        let epoch = SessionEpoch.now()
        let ssrc = UInt32.random(in: 1...UInt32.max)
        let pkt = RtpPacketizer(ssrc: ssrc, payloadType: 96, epoch: epoch)
        let out = MediaUdpSender(host: host, port: mediaPort, videoSsrc: ssrc, videoBitrate: p.bitrate)
        let enc = H264Encoder { [pkt, out] annexB, pts, isKey in
            out.sendVideo(pkt.packets(annexB: annexB, pts: pts))
        }
        do { try enc.start(p) } catch {
            out.cancel()
            log("kodlayıcı açılamadı: \(error)")
            throw error
        }
        // Pacer kuyruğu taşıp kareler atılırsa referans zinciri kopar: kendimize IDR iste.
        out.onVideoDrop = { [weak self, weak enc] packets, aus in
            enc?.forceKeyframe()
            Task { @MainActor in self?.log("pacer kuyruğu taştı: \(aus) kare / \(packets) paket atıldı → IDR istendi") }
        }
        if out.dropPercent > 0 { log("SINAMA: ATVM_DROP_VIDEO_PCT=\(out.dropPercent) — ilk iletimdeki video paketleri düşürülüyor") }

        let audioSsrc = UInt32.random(in: 1...UInt32.max)
        let audioPkt = PcmAudioPacketizer(ssrc: audioSsrc, payloadType: 97, epoch: epoch)
        audioPkt.onLog = { [weak self] line in
            Task { @MainActor in self?.log(line) }
        }

        try await announce(StartInfo(width: p.width, height: p.height, fps: p.fps, bitrate: p.bitrate,
                                     ssrc: ssrc, mediaPort: mediaPort, payloadType: 96,
                                     audioSsrc: audioSsrc, audioPayloadType: 97,
                                     audioSampleRate: audioPkt.sampleRate,
                                     audioChannels: audioPkt.channelCount,
                                     videoRtpBase: epoch.videoBase, audioRtpBase: epoch.audioBase))
        log("TV akışı onayladı → \(host):\(mediaPort)/udp  \(p.width)x\(p.height)@\(p.fps) + ses")

        // Ses: önce uygulamanın süreç tap'i (yakalar + Mac'te susturur); kurulamazsa SCK yedeği.
        // TV ekranı modunda kaynak, ekrandaki pencerelerin sahiplerinin birleşimidir (saniyede bir yenilenir);
        // SCK yedeği orada yok (ekran sesi Mac'in tüm sesini taşırdı).
        let tapLog: (String) -> Void = { [weak self] line in Task { @MainActor in self?.log(line) } }
        var tracker: TvDisplayAppTracker?
        let stopTap: (() -> Void)?
        if !capturesAudio {
            stopTap = nil
        } else if let window {
            stopTap = AppAudioSource.start(pid: window.pid, muteLocally: mutesLocalAppAudio, packetizer: audioPkt,
                                           send: { [out] in out.sendAudio($0) }, log: tapLog)
        } else {
            let t = TvDisplayAppTracker(displayID: tvDisplay!.displayID, log: tapLog)
            await t.start()
            tracker = t
            stopTap = AppAudioSource.start(roots: { [t] in t.roots() }, pollInterval: 1.0,
                                           muteLocally: mutesLocalAppAudio, packetizer: audioPkt,
                                           send: { [out] in out.sendAudio($0) }, log: tapLog)
        }

        let onFrame: (CVPixelBuffer, CMTime) -> Void = { [enc] pb, pts in enc.encode(pb, presentationTime: pts) }
        let cap: WindowCapture
        if let window {
            cap = WindowCapture(windowId: window.id, width: p.width, height: p.height, fps: p.fps,
                                audio: capturesAudio && stopTap == nil,
                                onFrame: onFrame,
                                onAudio: { [audioPkt, out] sb in
                                    for packet in audioPkt.packets(from: sb) { out.sendAudio(packet) }
                                })
        } else {
            cap = WindowCapture(tvDisplay: tvDisplay!, width: p.width, height: p.height, fps: p.fps,
                                onFrame: onFrame)
        }
        do { try await cap.start() } catch {
            stopTap?()
            tracker?.stop()
            throw error
        }

        self.tvTracker = tracker
        self.stopAppTap = stopTap
        self.currentSource = source
        self.encoder = enc
        self.packetizer = pkt
        self.audioPacketizer = audioPkt
        self.udp = out
        self.capture = cap
        self.isRunning = true
        self.startedAt = Date()
        self.frameCount = 0
        self.stall = StallGuard()
        self.stallLastFrames = -1
        self.stallProbedAt = nil
        self.onStatusNote?(nil)
        self.currentWindow = window
        self.baseProfile = profile
        self.currentProfile = p
        self.appliedPixels = pixels
        self.pipelineGeneration += 1
        if let window {
            log("yakalama başladı: \(window.displayName)")
            startResizeWatcher()
        } else {
            log("yakalama başladı: \(TvDisplay.name) (displayID \(tvDisplay!.displayID))")
        }

        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.emitStats() }
        }
    }

    /// Şu an yayında olan pencere ve gerçek kodlama profili (geçişte yeniden kullanılır).
    private(set) var currentWindow: WindowInfo?
    private(set) var currentProfile: H264Encoder.Profile?
    /// Kullanıcının seçtiği özgün profil: pencere geçişinde boyut BUNDAN hesaplanır
    /// (eskiden küçültülmüş boyut tavan sayılıyor, boyutlar yalnız küçülüyordu).
    private var baseProfile: H264Encoder.Profile?
    /// `start` bildiriminin nasıl yapıldığı: Mac başlattıysa kontrol kanalı,
    /// TV başlattıysa TV'nin kendi TCP bağlantısı. Pencere değişiminde aynı yol kullanılır.
    private var announce: ((StartInfo) async throws -> Void)?

    /// Aynı TV'ye, yayını kesmeden pencere değiştirme: yalnızca yakalama/kodlama/UDP
    /// hattı yeniden kurulur, kontrol kanalı açık kalır ve TV'ye yeni `start` yazılır.
    func switchWindow(_ window: WindowInfo) async throws {
        guard isRunning, let announce else { throw EngineError.notConnected }
        guard window.id != currentWindow?.id else { return }
        let profile = baseProfile ?? H264Encoder.Profile.presets["1080p60"]!
        let host = mediaHost
        let port = mediaPort
        let previous = currentSource
        isRunning = false
        await teardownMedia()
        do {
            try await runPipeline(source: .window(window), profile: profile, host: host,
                                  mediaPort: port, announce: announce)
            tvDisplay = nil
            log("yayın penceresi değişti → \(window.displayName)")
        } catch {
            // Ölçülen kusur: yeni pencere kurulamazsa yayın ölü kalıyordu.
            // Eski pencereye dön, kullanıcı en azından izlemeye devam etsin.
            log("pencere değiştirilemedi (\(error)) — önceki pencereye dönülüyor")
            if let previous {
                isRunning = false
                await teardownMedia()
                try? await runPipeline(source: previous, profile: profile, host: host,
                                       mediaPort: port, announce: announce)
                if isRunning { log("yayın önceki kaynakta sürüyor") }
            }
            if !isRunning { await stop() }
            throw error
        }
    }

    // MARK: pencere yeniden boyutlanması

    private var resizeTask: Task<Void, Never>?
    /// Yeniden yapılandırma sırasında hattın değişmediğini doğrulamak için (geçiş/durdurma yarışı).
    private var pipelineGeneration = 0
    /// Son uygulanan pencere piksel boyutu (eşik karşılaştırması buna göre).
    private var appliedPixels = CGSize.zero
    private(set) var resizeCount = 0
    /// Yoklama aralığı ve sabitlenme süresi: canlı sürüklemede her ara boyutta yeniden kurulmaz.
    private let resizePollNs: UInt64 = 120_000_000
    private let resizeDebounce: TimeInterval = 0.3

    private func startResizeWatcher() {
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            var pending: CGSize?
            var pendingSince = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.resizePollNs ?? 120_000_000)
                guard let self, !Task.isCancelled, self.isRunning, let window = self.currentWindow,
                      let now = VideoGeometry.windowPixelSize(windowId: window.id) else { continue }
                guard self.isSignificant(now, from: self.appliedPixels) else { pending = nil; continue }
                if pending != now { pending = now; pendingSince = Date(); continue }
                guard Date().timeIntervalSince(pendingSince) >= self.resizeDebounce else { continue }
                pending = nil
                await self.applyResize(pixels: now)
            }
        }
    }

    /// Boyut ya da oran küçük eşiğin üstünde değiştiyse true (1 piksellik titreşim yok sayılır).
    private func isSignificant(_ a: CGSize, from b: CGSize) -> Bool {
        guard b.width >= 1, b.height >= 1 else { return false }
        let dw = abs(a.width - b.width) / b.width, dh = abs(a.height - b.height) / b.height
        return dw > 0.02 || dh > 0.02
    }

    /// Oturumu kapatmadan: kodlayıcıyı yeni boyutla yeniden kur (yeni SPS/PPS + IDR), sonra SCK çıktısını güncelle.
    /// Eski boyutlu kareler kodlayıcı girişinde atılır; alıcı çözücü yeni SPS ile uyarlanır.
    private func applyResize(pixels: CGSize) async {
        guard let base = baseProfile, let cur = currentProfile, let enc = encoder, let cap = capture else { return }
        let gen = pipelineGeneration
        let next = VideoGeometry.encodeProfile(pixelSize: pixels, base: base)
        appliedPixels = pixels
        guard next.width != cur.width || next.height != cur.height else { return }
        let t0 = Date()
        do {
            try enc.reconfigure(next)
            try await cap.resize(width: next.width, height: next.height)
        } catch {
            log("yeniden boyutlama başarısız: \(error)")
            return
        }
        guard gen == pipelineGeneration else { return }
        currentProfile = next
        resizeCount += 1
        log(String(format: "pencere boyutu değişti → %dx%d piksel: kodlama %dx%d → %dx%d (yeniden yapılandırma %.0f ms, #%d)",
                   Int(pixels.width), Int(pixels.height), cur.width, cur.height, next.width, next.height,
                   Date().timeIntervalSince(t0) * 1000, resizeCount))
    }

    /// Medya hattını kapatır; kontrol kanalı ve oturum anahtarı korunur.
    private func teardownMedia() async {
        resizeTask?.cancel(); resizeTask = nil
        pipelineGeneration += 1
        statsTimer?.invalidate(); statsTimer = nil
        stopAppTap?(); stopAppTap = nil
        tvTracker?.stop(); tvTracker = nil
        await capture?.stop()
        encoder?.drain(); encoder?.teardown()
        udp?.cancel()
        capture = nil; encoder = nil; packetizer = nil; audioPacketizer = nil; udp = nil
    }

    /// UDP boşluğu/alıcı hatası bildirimi: sonraki kare IDR olsun.
    func requestKeyFrame() {
        encoder?.forceKeyframe()
        log("IDR isteği → kodlayıcı ana kare zorladı")
    }

    private var controlHost: String = ""
    /// Medyanın gönderildiği uç: Mac başlattıysa TV adresi, TV başlattıysa `resume`deki uç.
    private var mediaHost: String = ""

    func setHost(_ h: String) { controlHost = h }
    /// Şu anki/açılan yayın hedefi: TV'nin kontrol sunucusu tek oturumlu olduğu için bu adrese
    /// yönelik işlemler (ör. eşleşmeyi unut) yayını önce durdurmalı.
    var streamingHost: String? { controlHost.isEmpty ? nil : controlHost }

    private func emitStats() {
        guard let capture, let encoder, let packetizer else { return }
        frameCount = capture.framesDelivered
        watchForStall(now: Date())
        let secs = max(0.001, Date().timeIntervalSince(startedAt))
        let mbps = Double(encoder.bytesEncoded) * 8 / secs / 1_000_000
        let lat = encoder.latencyPercentiles()
        let cap = capture.captureLatencyPercentiles()
        let audioPackets = audioPacketizer?.packetsSent ?? 0
        let net = udp?.counters() ?? MediaUdpSender.Counters()
        onStats?(Stats(seconds: secs, fps: Double(frameCount) / secs, mbps: mbps,
                      packets: packetizer.packetsSent, captureP50: cap.p50,
                      encodeP50: lat.p50, encodeP95: lat.p95, audioPackets: audioPackets,
                      nackRequests: net.nackRx, retransmitted: net.rtxTx,
                      dropped: net.injDrop + net.paceDrop + encoder.droppedSizeMismatch,
                      wireBytes: net.wireBytes))
        log(String(format: "%.0f sn  kare=%d (%.1f fps)  %.1f Mbps  RTP=%d  ses=%d  yakalama p50=%.1f ms  kodlama p50=%.1f/%.1f ms  nackRx=%d rtxTx=%d rtxSkip=%d injDrop=%d paceDrop=%d boyutDüşen=%d",
                   secs, frameCount, Double(frameCount) / secs, mbps, packetizer.packetsSent,
                   audioPackets, cap.p50, lat.p50, lat.p95, net.nackRx, net.rtxTx, net.rtxSkip, net.injDrop, net.paceDrop, encoder.droppedSizeMismatch))
    }

    func stop() async {
        guard isRunning || control != nil || tvDisplay != nil else { return }
        isRunning = false
        await teardownMedia()
        tvDisplay = nil
        try? await control?.stop()
        control?.disconnect()
        control = nil
        currentWindow = nil
        currentSource = nil
        announce = nil
        onStatusNote?(nil)
        log("yayın durduruldu, kaynaklar serbest bırakıldı")
    }

    /// Donma yorumu: kare hareketini görmek için son sayac ve pahalı ScreenCaptureKit
    /// sorgusunu gazlamak için son yoklama anı.
    private var stallLastFrames = -1
    private var stallProbedAt: Date?

    /// Kare sessizliğini "pencere şu an besteleniyor mu?" bilgisiyle birlikte yorumlar.
    /// Bu ayrım şart: statik içerik = görünür+sessiz (arıza değil; v1 burada yeniden kurup
    /// sağlıklı yayını düşürdü), ayrı Space'teki tam ekran = listelenmiyor (gerçek donma).
    private func watchForStall(now: Date) {
        guard isRunning else { return }
        if frameCount != stallLastFrames {
            stallLastFrames = frameCount
            stallProbedAt = nil
            applyStall(stall.observe(frames: frameCount, present: true, exists: true, now: now))
            return
        }
        guard stall.quietSince(now) >= StallGuard.quietLimit else { return }
        // TV ekranı modu zaten her zaman bestelenen bir ekranı kaynak alıyor; sorgu gerekmez.
        guard case .window(let window) = currentSource else {
            applyStall(stall.observe(frames: frameCount, present: true, exists: true, now: now))
            return
        }
        let sinceProbe = stallProbedAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard sinceProbe >= 2 else { return }
        stallProbedAt = now
        let id = window.id
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            let exists = WindowCapture.windowExists(id)
            let present = exists ? await WindowCapture.windowIsPresent(id) : false
            self.applyStall(self.stall.observe(frames: self.frameCount, present: present,
                                               exists: exists, now: Date()))
        }
    }

    private func applyStall(_ ev: StallGuard.Event?) {
        guard let ev else { return }
        switch ev {
        case .resumed:
            log("kaynak yeniden kare üretiyor")
            onStatusNote?(nil)
            requestKeyFrame()
        case .hidden:
            log(String(format: "kaynak %.0f sn kare üretmiyor ve pencere artık bestelenmiyor",
                       StallGuard.quietLimit))
            onStatusNote?("Pencere artık görünür değil (ayrı Space'te tam ekran olabilir) — TV ekranı modu bu durumda donmaz")
        case .retry:
            log("pencere geri geldi ama kare hâlâ yok → yakalama yeniden kuruluyor")
            onStatusNote?("Kaynak kare üretmiyor — yeniden deneniyor")
            Task { @MainActor [weak self] in await self?.restartCapture() }
        case .gone:
            log("pencere kapatıldı → yayın sonlandırılıyor")
            onStatusNote?("Pencere kapatıldı — yayın durduruldu")
            Task { @MainActor [weak self] in await self?.stop() }
        }
    }

    /// Yalnızca pencere yeniden görünür olduğunda anlamlı tek deneme. Başarısız olursa yayını
    /// DÜŞÜRMÜYOR: ölçülen vaka, yoklukta yapılan denemenin "pencere bulunamadı" ile bitmesiydi.
    private func restartCapture() async {
        guard isRunning, let cap = capture else { return }
        do {
            try await cap.restart()
            log("yakalama yeniden kuruldu")
        } catch {
            log("yakalama yeniden kurulamadı (\(error)) — yayın açık bırakıldı")
            onStatusNote?("Kaynak yeniden yakalanamadı — pencereyi geri getir ya da TV ekranı modunu kullan")
        }
    }
}
