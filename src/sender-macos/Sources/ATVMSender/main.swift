import Foundation
import AppKit
import CoreMedia
import CoreVideo

// PaneCast macOS yayıncısı — komut satırı arayüzü.
// GUI (M5) bu çekirdeğin üstüne oturur; CLI gerçek testler için kasıtlı olarak tutuluyor.

let args = CommandLine.arguments

/// SkyLight/WindowServer bağlantısını kurar. Bu olmadan SCContentFilter(desktopIndependentWindow:)
/// içinde SLSGetDisplaysWithRect assert edip süreci düşürüyor (crash raporu: atvm-sender-*.ips).
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

/// `open --args` ile başlatıldığında stdout geri gelmediği için dosyaya da yazılır.
let logPath = (args.firstIndex(of: "--log").map { $0 + 1 < args.count ? args[$0 + 1] : "" }
    .flatMap { $0.isEmpty ? nil : $0 })
    ?? ProcessInfo.processInfo.environment["ATVM_LOG"]
let logFile = logPath.map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.temporaryDirectory.appendingPathComponent("atvm-sender.log")
func emit(_ line: String) {
    print(line)
    if let h = try? FileHandle(forWritingTo: logFile) {
        h.seekToEndOfFile(); h.write((line + "\n").data(using: .utf8)!); try? h.close()
    } else {
        try? (line + "\n").write(to: logFile, atomically: true, encoding: .utf8)
    }
}
try? "".write(to: logFile, atomically: true, encoding: .utf8)

func flag(_ name: String, _ def: String? = nil) -> String? {
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return def
}
func num<T: LosslessStringConvertible>(_ name: String, _ def: T) -> T {
    guard let s = flag(name) else { return def }
    return T(s) ?? def
}
func die(_ msg: String) -> Never {
    emit("HATA: " + msg)
    exit(2)
}

func usage() -> Never {
    emit("komut yok veya hatalı; argümanlar: \(args.joined(separator: " "))")
    print("""
    PaneCast yayıncısı

      atvm-sender gui                        # arayüzü aç (çift tıklamayla da açılır)
      atvm-sender list-tvs
      atvm-sender list-windows [--app SÜZGEÇ]
      atvm-sender selftest [--profile 1080p60] [--frames 300]
      atvm-sender audio-tap-test --pid <süreç> [--seconds 3] [--wav yol]   # uygulama sesi tap'i, TV'siz
      atvm-sender mirror --tv <ip> [--window <id> | --app <ad> | --title <parça>]
                         [--profile 1080p60|1080p30|720p60] [--duration 30]
                         [--pin 123456] [--media-port 7602] [--tcp-fallback]
      atvm-sender switch-test --tv <ip> --windows <id1,id2> [--every 10] [--duration 40]   # yayını kesmeden pencere değişimi
      atvm-sender unpair --tv <ip>           # eşleşmeyi TV'de (doğrulanmış oturumla) ve bu Mac'te sil

      Not: ekran kaydı izni yalnızca .app bundle içinde sorulur → scripts/build-sender-app.sh
    """)
    exit(0)
}

let command = args.count > 1 ? args[1] : ""
emit("başlatıldı: komut=\(command.isEmpty ? "(yok)" : command) argümanlar=\(args.dropFirst().joined(separator: " "))")

switch command {

case "gui", "":
    // Arayüz: TV seç → pencere seç → Başlat → PIN gir.
    runGUI()

case "unpair":
    guard let tvHost = flag("--tv") else { die("--tv <ip> gerekli") }
    let c = ControlClient(host: tvHost)
    do {
        try await c.connect()
        if try await c.beginHello() == .paired {
            try await c.unpair()
            emit("TV eşleşmeyi sildi")
        } else {
            emit("TV zaten eşleşmesiz")
        }
    } catch {
        emit("TV'de silinemedi: \(error)")
    }
    c.disconnect()
    KeyStore.remove(tvHost)
    emit("bu Mac'teki anahtar silindi: \(tvHost)")
    exit(0)

case "list-tvs":
    let tvs = await TvDiscovery.browse(seconds: Double(num("--seconds", 3)))
    if tvs.isEmpty { print("yerel ağda PaneCast alıcısı bulunamadı (TV'de uygulamayı açın)") }
    for t in tvs { print(t) }
    exit(0)

case "audio-tap-test":
    // TV'ye bir şey göndermeden: uygulama tap'i + ses paketleyicisi yerelde ölçülür.
    guard let pidArg = flag("--pid").flatMap({ pid_t($0) }) else { die("--pid <süreç> gerekli") }
    let code = await AudioTapProbe.run(pid: pidArg, seconds: num("--seconds", 3.0), wavPath: flag("--wav"))
    exit(code)

case "meter":
    await AudioMeter.run(seconds: Int(num("--seconds", 12)))

case "list-windows":
    do {
        try await WindowCapture.ensurePermission(waitSeconds: num("--wait-permission", 120.0))
        let filter = flag("--app")
        let wins = try await WindowCapture.shareableWindows()
        for w in wins where !w.title.isEmpty && w.onScreen {
            if let f = filter, !w.app.contains(f) { continue }
            print(w)
        }
    } catch let e as CaptureError { die(e.description) }
    catch { die("\(error)") }
    exit(0)

case "selftest":
    // Ekran kaydı izni gerektirmeden kodlama + bitstream dönüşümünü doğrular.
    let profile = H264Encoder.Profile.presets[flag("--profile", "720p60")!] ?? H264Encoder.Profile.presets["720p60"]!
    let frames = num("--frames", 120)
    let packetizer = RtpPacketizer(ssrc: UInt32.random(in: 1...UInt32.max), payloadType: 96,
                                   epoch: SessionEpoch(hostSeconds: 0, videoBase: 0, audioBase: 0))
    var auCount = 0, keyCount = 0, firstAuPreview = ""
    let encoder = H264Encoder { annexB, pts, isKey in
        auCount += 1
        if isKey { keyCount += 1 }
        if auCount == 1 {
            let n = min(24, annexB.count)
            firstAuPreview = annexB.prefix(n).map { String(format: "%02x", $0) }.joined(separator: " ")
        }
        _ = packetizer.packets(annexB: annexB, pts: pts)
    }
    do { try encoder.start(profile) } catch { die("kodlayıcı açılamadı: \(error)") }
    let bufs = (0..<2).map { syntheticFrame(width: profile.width, height: profile.height, seed: $0 * 51) }
    let t0 = CFAbsoluteTimeGetCurrent()
    for i in 0..<frames {
        encoder.encode(bufs[i % bufs.count], presentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(profile.fps)))
    }
    encoder.drain()
    let wall = CFAbsoluteTimeGetCurrent() - t0
    print("profil: \(profile.width)x\(profile.height)@\(profile.fps) bitrate=\(profile.bitrate)")
    print("gönderilen kare=\(frames)  kodlanan AU=\(auCount)  keyframe=\(keyCount)")
    print("süre=\(String(format: "%.2f", wall))s  fps=\(String(format: "%.1f", Double(auCount) / max(wall, 0.001)))  (gerçek zamanlı pacing YOK, ham hız)")
    print("RTP paketi=\(packetizer.packetsSent) bayt=\(packetizer.bytesSent)")
    print("ilk AU baytları: \(firstAuPreview)")
    let startsWithStartCode = firstAuPreview.hasPrefix("00 00 00 01")
    print(startsWithStartCode ? "ANNEX-B DÖNÜŞÜMÜ: DOĞRULANDI (start code ile başlıyor)"
                              : "ANNEX-B DÖNÜŞÜMÜ: BAŞARISIZ — start code yok")
    exit(startsWithStartCode ? 0 : 1)

case "switch-test":
    // Yayını kesmeden pencere değişimi, arayüzün kullandığı MirrorEngine yoluyla:
    // her --every saniyede bir sonraki pencereye geçilir (TV aynı bağlantıda yeni `start` alır).
    guard let tvHost = flag("--tv") else { die("--tv <ip> gerekli") }
    let ids = (flag("--windows") ?? "").split(separator: ",").compactMap { UInt32($0) }
    guard ids.count >= 2 else { die("--windows <id1,id2[,...]> gerekli") }
    let swProfile = H264Encoder.Profile.presets[flag("--profile", "1080p60")!] ?? H264Encoder.Profile.presets["1080p60"]!
    let every = num("--every", 10.0), swDuration = num("--duration", 40.0)
    do { try await WindowCapture.ensurePermission(waitSeconds: 0) } catch { die("\(error)") }
    let shareable = (try? await WindowCapture.shareableWindows()) ?? []
    let wins = ids.compactMap { id in shareable.first { $0.id == id } }
    guard wins.count == ids.count else { die("pencere bulunamadı: \(ids)") }
    let engine = MirrorEngine()
    engine.onLog = { emit($0) }
    engine.setHost(tvHost)
    do {
        if try await engine.connectAndHello(host: tvHost) == .needsPin {
            guard let pin = flag("--pin") else { die("TV PIN istiyor: --pin <kod>") }
            try await engine.submitPin(pin)
        }
        try await engine.beginStream(window: wins[0], profile: swProfile)
        let t0 = Date()
        var n = 0
        while Date().timeIntervalSince(t0) + every <= swDuration {
            try await Task.sleep(nanoseconds: UInt64(every * 1e9))
            n += 1
            try await engine.switchWindow(wins[n % wins.count])
        }
        let rest = swDuration - Date().timeIntervalSince(t0)
        if rest > 0 { try await Task.sleep(nanoseconds: UInt64(rest * 1e9)) }
    } catch {
        await engine.stop()
        die("\(error)")
    }
    await engine.stop()
    exit(0)

case "mirror":
    guard let tvHost = flag("--tv") else { die("--tv <ip> gerekli (list-tvs ile bul)") }
    let profileKey = flag("--profile", "1080p60")!
    guard let profile = H264Encoder.Profile.presets[profileKey] else { die("bilinmeyen profil \(profileKey)") }
    let duration = num("--duration", 30.0)
    let mediaPort = UInt16(num("--media-port", 7602))
    let pinArg = flag("--pin")

    let sourceKind = flag("--source", "window")!

    // 1) pencereyi çöz (sentetik kaynakta ekran kaydı izni gerekmez)
    if sourceKind != "synthetic" {
        do { try await WindowCapture.ensurePermission(waitSeconds: num("--wait-permission", 120.0)) }
        catch let e as CaptureError { die(e.description) }
        catch { die("\(error)") }
    }
    let windows: [WindowInfo]
    do { windows = sourceKind == "synthetic" ? [] : try await WindowCapture.shareableWindows() }
    catch let e as CaptureError {
        die(e.description + "\n→ Sistem Ayarları → Gizlilik ve Güvenlik → Ekran Kaydı → 'PaneCast'")
    }
    catch { die("\(error)") }

    var chosen: WindowInfo?
    if sourceKind == "synthetic" {
        chosen = WindowInfo(id: 0, app: "sentetik", pid: -1, title: "test deseni",
                            frame: CGRect(x: 0, y: 0, width: profile.width, height: profile.height),
                            onScreen: true)
    } else if let widStr = flag("--window"), let wid = UInt32(widStr) {
        chosen = windows.first { $0.id == wid }
    } else if let appFilter = flag("--app") {
        chosen = windows.first { $0.app.localizedCaseInsensitiveContains(appFilter) && !$0.title.isEmpty }
    } else if let titleFilter = flag("--title") {
        chosen = windows.first { $0.title.localizedCaseInsensitiveContains(titleFilter) }
    }
    if chosen == nil, let w = windows.first(where: { !$0.title.isEmpty && $0.onScreen }) {
        emit("belirtme yok, ilk pencere seçildi: \(w)")
        chosen = w
    }
    guard let window = chosen else {
        emit("seçilebilir pencere yok. örnek çıktı:")
        for w in windows.prefix(15) where !w.title.isEmpty { emit("  \(w)") }
        die("pencere bulunamadı")
    }
    emit("kaynak: \(window)")

    // Kodlanacak boyut: pencerenin gerçek piksel boyutu (nokta × ekran ölçeği), profil kutusuna
    // oranı bozmadan sığdırılmış. TV'ye bildirilen çözünürlük ile akışın çözünürlüğü BİREBİR aynı
    // olmalı; farklıysa MStar çözücü kare üretmeyi durduruyor (ölçüldü: 1197 AU → 22 render).
    let windowPixels = VideoGeometry.windowPixelSize(windowId: window.id) ?? VideoGeometry.pixelSize(points: window.frame)
    let encodeProfile: H264Encoder.Profile = sourceKind == "synthetic" ? profile
        : VideoGeometry.encodeProfile(pixelSize: windowPixels, base: profile)
    let encodeWidth = encodeProfile.width, encodeHeight = encodeProfile.height
    if sourceKind != "synthetic" {
        emit("pencere \(Int(windowPixels.width))x\(Int(windowPixels.height)) piksel → \(encodeWidth)x\(encodeHeight) kodlanacak (profil kutusu \(profile.width)x\(profile.height))")
    }

    // 2) kodlayıcı + paketleyici + UDP
    let epoch = SessionEpoch.now()
    let ssrc = UInt32.random(in: 1...UInt32.max)
    let packetizer = RtpPacketizer(ssrc: ssrc, payloadType: 96, epoch: epoch)
    let audioSsrc = UInt32.random(in: 1...UInt32.max)
    let audioPacketizer = PcmAudioPacketizer(ssrc: audioSsrc, payloadType: 97, epoch: epoch)
    audioPacketizer.onLog = { emit($0) }
    let sender = MediaUdpSender(host: tvHost, port: mediaPort, videoSsrc: ssrc, videoBitrate: profile.bitrate)
    let stats = SessionStats()

    let videoTap: FileHandle? = ProcessInfo.processInfo.environment["ATVM_VIDEO_TAP"].flatMap { path -> FileHandle? in
        FileManager.default.createFile(atPath: path, contents: Data())
        return FileHandle(forWritingAtPath: path)
    }

    // Annex-B girişi de tap'lenir: paketleyici mi bozuyor, kodlayıcı mı sorusunun cevabı.
    let annexbTap: FileHandle? = ProcessInfo.processInfo.environment["ATVM_ANNEXB_TAP"].flatMap { path -> FileHandle? in
        FileManager.default.createFile(atPath: path, contents: Data())
        return FileHandle(forWritingAtPath: path)
    }

    let encoder = H264Encoder { [packetizer, sender, stats, videoTap, annexbTap] annexB, pts, isKey in
        if let tap = annexbTap {
            var l = UInt32(annexB.count).bigEndian
            withUnsafeBytes(of: &l) { tap.write(Data($0)) }
            tap.write(annexB)
        }
        let packets = packetizer.packets(annexB: annexB, pts: pts)
        sender.sendVideo(packets)
        if let tap = videoTap {
            for p in packets {
                // Uzunluk öneki: RTP kendi sınırını taşımaz, ham akış ayrıştırılamıyor.
                var len = UInt32(p.count).bigEndian
                withUnsafeBytes(of: &len) { tap.write(Data($0)) }
                tap.write(p)
            }
        }
        stats.noteFrame(bytes: annexB.count, key: isKey, packets: packets.count, sendErrors: sender.sendErrors)
    }
    do { try encoder.start(encodeProfile) } catch { die("kodlayıcı açılamadı: \(error)") }
    // Pacer kuyruğu taşıp kareler atılırsa referans zinciri kopar: kendimize IDR iste.
    sender.onVideoDrop = { [encoder, stats] p, a in
        encoder.forceKeyframe(); stats.noteIdrRequest()
        emit("pacer kuyruğu taştı: \(a) kare / \(p) paket atıldı → IDR istendi")
    }
    if sender.dropPercent > 0 { emit("SINAMA: ATVM_DROP_VIDEO_PCT=\(sender.dropPercent) — ilk iletimdeki video paketleri düşürülüyor") }

    // 3) kontrol kanalı + eşleşme
    let control = ControlClient(host: tvHost)
    do {
        try await control.connect()
        control.onMessage = { (msg: [String: Any]) in
            if (msg["t"] as? String) == "idr_request" { encoder.forceKeyframe(); stats.noteIdrRequest() }
        }
        try await control.pairOrAuth(pinProvider: { pinArg })
        emit("eşleştirme tamam (oturum: \(control.sessionId ?? "?"))")
        try await control.requestStart(MirrorEngine.StartInfo(
            width: encodeProfile.width, height: encodeProfile.height,
            fps: encodeProfile.fps, bitrate: encodeProfile.bitrate,
            ssrc: ssrc, mediaPort: mediaPort, payloadType: 96,
            audioSsrc: audioSsrc, audioPayloadType: 97,
            audioSampleRate: audioPacketizer.sampleRate, audioChannels: audioPacketizer.channelCount,
            videoRtpBase: epoch.videoBase, audioRtpBase: epoch.audioBase))
        emit("TV yayını kabul etti → \(tvHost):\(mediaPort)/udp \(encodeProfile.width)x\(encodeProfile.height)@\(encodeProfile.fps) + ses")
    } catch {
        die("\(error)")
    }

    // Ses denetimi: ATVM_AUDIO_TAP=<dosya> verilirse RTP ses paketleri ham olarak yazılır.
    // Böylece RFC 3640 çerçevesi ve AAC geçerliliği ağa/TV'ye gerek kalmadan doğrulanabilir.
    let audioTap: FileHandle? = ProcessInfo.processInfo.environment["ATVM_AUDIO_TAP"].flatMap { path -> FileHandle? in
        FileManager.default.createFile(atPath: path, contents: Data())
        return FileHandle(forWritingAtPath: path)
    }

    StopSignals.install()          // ^C / SIGTERM: döngüden çık, tap dahil her şey temiz kapansın

    // 4) yakalama başlat. Ses: önce uygulama tap'i (yakalar + Mac'te susturur), kurulamazsa SCK yedeği.
    var stopTap: (() -> Void)?
    if sourceKind != "synthetic" {
        stopTap = AppAudioSource.start(pid: window.pid, muteLocally: true, packetizer: audioPacketizer,
                                       send: { [sender, audioTap] p in sender.sendAudio(p); audioTap?.write(p) },
                                       log: { emit($0) })
    }
    let capture = WindowCapture(windowId: window.id, width: encodeProfile.width, height: encodeProfile.height,
                                fps: encodeProfile.fps, audio: stopTap == nil,
                                onFrame: { [encoder, stats] pb, pts in
        stats.noteCapture()
        encoder.encode(pb, presentationTime: pts)
    }, onAudio: { [audioPacketizer, sender, audioTap] sb in
        for p in audioPacketizer.packets(from: sb) {
            sender.sendAudio(p)
            audioTap?.write(p)
        }
    })
    var syntheticTimer: DispatchSourceTimer?
    if sourceKind == "synthetic" {
        // Ekran kaydı izni gerektirmeyen kaynak: yayıncının kendi taşıma yolunu
        // (kodlayıcı → RTP → UDP → TV) doğrulamak için.
        let frames = (0..<4).map { syntheticFrame(width: encodeProfile.width, height: encodeProfile.height, seed: $0 * 61) }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "atvm.synthetic", qos: .userInteractive))
        var i = 0
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(1000 / profile.fps))
        timer.setEventHandler { [encoder, stats] in
            let pts = CMClockGetTime(CMClockGetHostTimeClock())      // ortak saat köküyle uyumlu: host saati
            i += 1
            stats.noteCapture()
            encoder.encode(frames[i % frames.count], presentationTime: pts)
        }
        timer.resume()
        syntheticTimer = timer
        emit("sentetik kaynak başladı \(encodeProfile.width)x\(encodeProfile.height)@\(encodeProfile.fps) — \(duration) sn")
    } else {
        do { try await capture.start() } catch let e as CaptureError { stopTap?(); die(e.description) } catch { stopTap?(); die("\(error)") }
        emit("yakalama başladı \(capture.configuredSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?") — \(duration) sn")
    }

    // 5) süre boyunca durum yaz, sonra temiz kapat
    let clock = DateFormatter()
    clock.dateFormat = "HH:mm:ss"          // TV logcat'i ile hizalamak için duvar saati
    let sinceStart = Date()
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline && !StopSignals.requested {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let s = stats.snapshot()
        let lat = encoder.latencyPercentiles()
        let cap = capture.captureLatencyPercentiles()
        let net = sender.counters()
        emit(String(format: "  %@ yakalanan=%d kodlanan=%d key=%d Mbps=%.1f RTP pkt=%d sesPkt=%d hata=%d IDR istek=%d yakalama p50=%.1fms kodlama p50=%.1fms p95=%.1fms nackRx=%d rtxTx=%d rtxSkip=%d injDrop=%d paceDrop=%d",
                   clock.string(from: Date()), s.frames, s.encoded, s.keyframes,
                   Double(s.bytes) * 8.0 / max(1, Date().timeIntervalSince(sinceStart)) / 1_000_000,
                   s.packets, audioPacketizer.packetsSent, s.sendErrors, s.idrRequests,
                   cap.p50, lat.p50, lat.p95, net.nackRx, net.rtxTx, net.rtxSkip, net.injDrop, net.paceDrop))
        if let fatal = capture.fatalStopReason {
            // Pencere kapandı / yakalama düştü: yayını beklemeden temiz kapat.
            emit("yakalama durdu: \(fatal) → yayın sonlandırılıyor")
            break
        }
    }

    syntheticTimer?.cancel()
    stopTap?()
    await capture.stop()
    encoder.drain()
    encoder.teardown()
    try? await control.stop()
    control.disconnect()
    sender.cancel()
    let s = stats.snapshot()
    let endLat = encoder.latencyPercentiles()
    emit("bitti: yakalanan=\(s.frames) kodlanan=\(s.encoded) RTP paketi=\(s.packets) "
          + "kodlama gecikmesi p50=\(String(format: "%.1f", endLat.p50)) ms p95=\(String(format: "%.1f", endLat.p95)) ms")
    exit(0)

default:
    usage()
}

/// Basit sayaç/istatistik toplayıcı.
final class SessionStats: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0, encoded = 0, keyframes = 0, bytes = 0, packets = 0, idr = 0

    func noteFrame(bytes b: Int, key: Bool, packets p: Int, sendErrors e: Int) {
        lock.lock(); encoded += 1; bytes += b; packets += p; sendErrorCount = e
        if key { keyframes += 1 }
        lock.unlock()
    }
    private var sendErrorCount = 0
    func noteCapture() { lock.lock(); frames += 1; lock.unlock() }
    func noteIdrRequest() { lock.lock(); idr += 1; lock.unlock() }

    struct Snapshot { var frames, encoded, keyframes, bytes, packets, sendErrors, idrRequests: Int }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(frames: frames, encoded: encoded, keyframes: keyframes, bytes: bytes,
                        packets: packets, sendErrors: sendErrorCount, idrRequests: idr)
    }
}

/// Sentetik NV12 kare (selftest için; ekran kaydı izni gerektirmez).
func syntheticFrame(width: Int, height: Int, seed: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as Any]
    let st = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                 kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                 attrs as CFDictionary, &pb)
    guard st == kCVReturnSuccess, let buf = pb else { fatalError("CVPixelBufferCreate \(st)") }
    CVPixelBufferLockBaseAddress(buf, [])
    let yb = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!
    let ys = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
    let cb = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!
    let cs = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
    for row in 0..<height {
        let p = yb.advanced(by: row * ys).assumingMemoryBound(to: UInt8.self)
        for col in 0..<width { p[col] = UInt8((col &+ row &* 3 &+ seed) & 0xFF) }
    }
    for row in 0..<(height / 2) {
        let p = cb.advanced(by: row * cs).assumingMemoryBound(to: UInt8.self)
        for col in 0..<cs { p[col] = UInt8(((col &+ row &+ seed) & 0x7F) + 64) }
    }
    CVPixelBufferUnlockBaseAddress(buf, [])
    return buf
}
