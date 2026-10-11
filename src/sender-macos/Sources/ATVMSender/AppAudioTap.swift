import AppKit
import CoreAudio
import Darwin
import Foundation

/// Core Audio süreç tap'i ile bir uygulamanın sesini hem yakalar hem Mac'te susturur.
///
/// Eski yol (`kAudioHardwarePropertyProcessIsAudible`, pid nitelileyicili) işe yaramıyordu:
/// nitelileyici yok sayılıp kendi sürecimizi susturuyordu, yayınlanan uygulama çalmaya devam
/// ediyordu. Tap ise ölçüldü (macOS 26): `.mutedWhenTapped` yalnız tap'lenen süreçleri, IO
/// çalıştığı sürece susturuyor; sahibi ölünce coreaudiod susturucuyu ~0,4 sn içinde kaldırıyor
/// (çökmeye karşı güvenli). Tap-yalnız özel toplu aygıt 48 kHz, 512 çerçeveli interleaved
/// float32 tamponlarla ~32 ms'de bir teslim ediyor; her çağrıda `mHostTime` var.
///
/// Sesi çıkaran süreç çoğu zaman uygulamanın ana pid'i değil (ölçüldü):
/// Firefox/QuickTime → ana pid; Chrome → `com.google.Chrome.helper` (sorumlu pid = Chrome);
/// Safari/WebKit → `com.apple.WebKit.GPU` XPC servisi (ppid 1, sorumlu pid = ana uygulama,
/// bundle id tüm WebKit uygulamalarında ortak → asla bundle id ile seçilmez).

// MARK: - Süreç kümesi çözümü (saf, test edilebilir)

struct AudioProcessRow: Equatable {
    let objectID: UInt32
    let pid: pid_t
    let ppid: pid_t
    /// `responsibility_get_pid_responsible_for_pid`; sistem çağrısı yoksa/başarısızsa nil.
    let responsiblePid: pid_t?
    let bundleID: String
}

enum AudioProcessResolver {
    /// Tüm WebKit uygulamalarının paylaştığı GPU servisi: bundle id ile seçilemez.
    static let sharedWebKitGPU = "com.apple.WebKit.GPU"

    /// Uygulamanın ses süreçleri: pid'i uygulama pid'i olan ya da sorumlu pid'i uygulama olan
    /// satırlar. Sorumlu pid bilinmiyorsa yedek: ppid eşleşmesi ya da bundle id öneki
    /// (WebKit.GPU hariç). Kendi sürecimiz her zaman dışarıda.
    static func resolve(appPid: pid_t, appBundleID: String?, ownPid: pid_t,
                        rows: [AudioProcessRow]) -> [AudioProcessRow] {
        rows.filter { row in
            guard row.pid > 0, row.pid != ownPid else { return false }
            if row.pid == appPid { return true }
            if let responsible = row.responsiblePid { return responsible == appPid }
            if row.ppid == appPid { return true }
            return bundleMatches(row.bundleID, appBundleID: appBundleID)
        }
    }

    /// macOS 26 `bundleIDs` listesi: uygulamanın kendi kimliği ile çözülen süreçlerden
    /// onunla başlayanlar. Çözülmemiş süreçlerin kimliği alınmaz (ör. Chrome Canary).
    static func bundleIDs(resolved: [AudioProcessRow], appBundleID: String?) -> [String] {
        guard let app = appBundleID, !app.isEmpty else { return [] }
        var ids: Set<String> = [app]
        for row in resolved where bundleMatches(row.bundleID, appBundleID: app) { ids.insert(row.bundleID) }
        return ids.sorted()
    }

    private static func bundleMatches(_ bundleID: String, appBundleID: String?) -> Bool {
        guard let app = appBundleID, !app.isEmpty, !bundleID.isEmpty,
              bundleID != sharedWebKitGPU else { return false }
        return bundleID == app || bundleID.hasPrefix(app + ".")
    }
}

// MARK: - Core Audio yardımcıları

@available(macOS 14.2, *)
enum AudioProcessList {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// `responsibility_get_pid_responsible_for_pid` herkese açık başlıkta yok; çalışma anında aranır.
    private static let responsibleFn: (@convention(c) (pid_t) -> pid_t)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */,
                              "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    static func rows() -> [AudioProcessRow] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap(row)
    }

    private static func row(_ object: AudioObjectID) -> AudioProcessRow? {
        var pidAddr = address(kAudioProcessPropertyPID)
        var pid = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &pidAddr, 0, nil, &size, &pid) == noErr, pid > 0 else { return nil }

        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        let ppid: pid_t = n > 0 ? pid_t(info.pbi_ppid) : -1

        var responsible: pid_t?
        if let fn = responsibleFn {
            let r = fn(pid)
            responsible = r > 0 ? r : nil
        }

        var bundleAddr = address(kAudioProcessPropertyBundleID)
        var bundle: Unmanaged<CFString>?
        var bsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var bundleID = ""
        if AudioObjectGetPropertyData(object, &bundleAddr, 0, nil, &bsize, &bundle) == noErr, let b = bundle {
            bundleID = b.takeRetainedValue() as String
        }
        return AudioProcessRow(objectID: object, pid: pid, ppid: ppid, responsiblePid: responsible, bundleID: bundleID)
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}

func fourCC(_ status: OSStatus) -> String {
    let u = UInt32(bitPattern: status)
    let chars = [24, 16, 8, 0].map { (shift: Int) -> Character in
        let c = UInt8((u >> UInt32(shift)) & 0xFF)
        return (32...126).contains(c) ? Character(UnicodeScalar(c)) : "."
    }
    return "\(status)('\(String(chars))')"
}

// MARK: - Tap

@available(macOS 14.2, *)
final class AppAudioTap: @unchecked Sendable {
    /// Tap'ten gelen bir IO tamponu; işaretçi yalnızca çağrı süresince geçerli.
    struct Frames {
        let samples: UnsafePointer<Float>
        let frameCount: Int
        let channels: Int
        /// İlk örneğin host zamanı (saniye).
        let hostSeconds: Double
    }

    enum TapError: Error, CustomStringConvertible {
        case coreAudio(String, OSStatus)
        case unsupportedRate(Double)
        var description: String {
            switch self {
            case .coreAudio(let what, let status): return "\(what) başarısız: \(fourCC(status))"
            case .unsupportedRate(let r): return "tap örnekleme hızı \(r) Hz, 48000 bekleniyordu"
            }
        }
    }

    /// Bir tap + özel toplu aygıt + IO işleyicisi. Süreç kümesi değişince yenisi kurulur.
    private final class Generation {
        let id: Int
        let objects: Set<UInt32>
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggID = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        var started = false
        var destroyed = false
        /// Devralma: yeni nesil ilk veriyi verince aktif olur, eski nesil o ana dek akıtmaya devam eder.
        var takesOver = true
        var loggedFirst = false
        var scratch: [Float] = []
        init(id: Int, objects: Set<UInt32>) { self.id = id; self.objects = objects }
    }

    private let pid: pid_t
    private let appBundleID: String?
    private let muteLocally: Bool
    private let onFrames: (Frames) -> Void
    private let log: (String) -> Void

    private let queue = DispatchQueue(label: "atvm.apptap")
    private static let queueKey = DispatchSpecificKey<Void>()
    private let ioQueueBase = "atvm.apptap.io"

    /// Teslim kilidi: hangi nesil aktif, sayaçlar ve `onFrames` çağrısı bununla serileşir.
    private let deliverLock = NSLock()
    private var activeID = 0
    private var callbackCount = 0
    private var frameTotal = 0

    // Aşağıdakiler yalnız `queue` üzerinde dokunulur.
    private var current: Generation?
    private var retiring: [Generation] = []
    private var nextGenerationID = 1
    private var stopped = false
    private var listener: AudioObjectPropertyListenerBlock?
    private var pendingRebuild: DispatchWorkItem?
    private var swaps = 0

    init(pid: pid_t, muteLocally: Bool,
         onFrames: @escaping (Frames) -> Void, log: @escaping (String) -> Void) {
        self.pid = pid
        self.appBundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        self.muteLocally = muteLocally
        self.onFrames = onFrames
        self.log = log
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit { stop() }

    var framesDelivered: Int { deliverLock.lock(); defer { deliverLock.unlock() }; return frameTotal }
    var callbacks: Int { deliverLock.lock(); defer { deliverLock.unlock() }; return callbackCount }
    var processSwaps: Int { onQueue { swaps } }

    func start() throws {
        try onQueue {
            guard !stopped, current == nil else { return }
            let rows = resolved()
            let gen = try build(rows: rows)
            current = gen
            log("uygulama sesi tap'i açıldı: \(describe(rows)) · \(muteLocally ? "Mac'te yalnız bu süreçler susturuldu" : "susturma kapalı")")
            installListener()
        }
    }

    /// Deterministik kapanış: dinleyici, bekleyen yeniden kurulum, tüm nesiller. Birden çok çağrılabilir.
    func stop() {
        onQueue {
            guard !stopped else { return }
            stopped = true
            pendingRebuild?.cancel(); pendingRebuild = nil
            if let listener {
                var addr = AudioProcessList.address(kAudioHardwarePropertyProcessObjectList)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, listener)
                self.listener = nil
            }
            deliverLock.lock(); activeID = -1; deliverLock.unlock()
            let all = ([current] + retiring).compactMap { $0 }
            current = nil; retiring = []
            for g in all { destroy(g) }
            log("uygulama sesi tap'i kapatıldı (nesil \(all.count), süreç kümesi değişimi \(swaps)); susturma kaldırıldı")
        }
    }

    // MARK: kurulum

    private func resolved() -> [AudioProcessRow] {
        AudioProcessResolver.resolve(appPid: pid, appBundleID: appBundleID, ownPid: getpid(),
                                     rows: AudioProcessList.rows())
    }

    private func describe(_ rows: [AudioProcessRow]) -> String {
        guard !rows.isEmpty else { return "ses süreci henüz yok (uygulama \(pid), ses başlayınca eklenecek)" }
        let parts = rows.map { r in
            "pid \(r.pid) \(r.bundleID.isEmpty ? "?" : r.bundleID) sorumlu=\(r.responsiblePid.map(String.init) ?? "?")"
        }
        return "\(rows.count) süreç [" + parts.joined(separator: "; ") + "]"
    }

    private func build(rows: [AudioProcessRow]) throws -> Generation {
        let gen = Generation(id: nextGenerationID, objects: Set(rows.map { $0.objectID }))
        nextGenerationID += 1

        let desc = CATapDescription(stereoMixdownOfProcesses: rows.map { AudioObjectID($0.objectID) })
        desc.name = "atvm-tap-\(gen.id)"
        desc.isPrivate = true
        desc.muteBehavior = muteLocally ? .mutedWhenTapped : .unmuted
        // `bundleIDs` / `isProcessRestoreEnabled` yalnız macOS 26 SDK'sında (Swift 6.2+) var;
        // eski SDK'lı derleyicide (ör. CI) bu blok derlenmez, kendi dinleyicimiz yeter.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // Sonradan açılan süreçleri sistem kendisi ekler (kendi dinleyicimiz yine yedekte).
            let ids = AudioProcessResolver.bundleIDs(resolved: rows, appBundleID: appBundleID)
            if !ids.isEmpty {
                desc.bundleIDs = ids
                desc.isProcessRestoreEnabled = true
            }
        }
        #endif
        var status = AudioHardwareCreateProcessTap(desc, &gen.tapID)
        guard status == noErr else { throw TapError.coreAudio("AudioHardwareCreateProcessTap", status) }

        let tapUID = AudioProcessList.string(gen.tapID, kAudioTapPropertyUID) ?? ""
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "atvm-tap-agg-\(gen.id)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: tapUID]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &gen.aggID)
        guard status == noErr else {
            destroy(gen)
            throw TapError.coreAudio("AudioHardwareCreateAggregateDevice", status)
        }

        var rateAddr = AudioProcessList.address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var rsize = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(gen.aggID, &rateAddr, 0, nil, &rsize, &rate)
        guard rate == 48_000 else {
            destroy(gen)
            throw TapError.unsupportedRate(rate)
        }

        let ioQueue = DispatchQueue(label: "\(ioQueueBase).\(gen.id)", qos: .userInteractive)
        status = AudioDeviceCreateIOProcIDWithBlock(&gen.procID, gen.aggID, ioQueue) { [weak self, gen] _, input, inputTime, _, _ in
            self?.handle(gen, input, inputTime)
        }
        guard status == noErr else {
            destroy(gen)
            throw TapError.coreAudio("AudioDeviceCreateIOProcIDWithBlock", status)
        }
        status = AudioDeviceStart(gen.aggID, gen.procID)
        guard status == noErr else {
            destroy(gen)
            throw TapError.coreAudio("AudioDeviceStart", status)
        }
        gen.started = true
        return gen
    }

    /// Sıra: AudioDeviceStop → DestroyIOProcID → DestroyAggregateDevice → DestroyProcessTap.
    private func destroy(_ g: Generation) {
        guard !g.destroyed else { return }
        g.destroyed = true
        if g.started { check(AudioDeviceStop(g.aggID, g.procID), "AudioDeviceStop") }
        if let p = g.procID { check(AudioDeviceDestroyIOProcID(g.aggID, p), "AudioDeviceDestroyIOProcID") }
        if g.aggID != kAudioObjectUnknown { check(AudioHardwareDestroyAggregateDevice(g.aggID), "AudioHardwareDestroyAggregateDevice") }
        if g.tapID != kAudioObjectUnknown { check(AudioHardwareDestroyProcessTap(g.tapID), "AudioHardwareDestroyProcessTap") }
    }

    private func check(_ status: OSStatus, _ what: String) {
        if status != noErr { log("tap kapanışı: \(what) → \(fourCC(status))") }
    }

    // MARK: süreç kümesi değişimi

    private func installListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRebuild() }
        var addr = AudioProcessList.address(kAudioHardwarePropertyProcessObjectList)
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        if status == noErr { listener = block } else { log("süreç listesi dinleyicisi kurulamadı: \(fourCC(status))") }
    }

    /// Dinleyici `queue` üzerinde çağrılır. 200 ms içindeki ardışık değişimler tek yeniden kurulumda toplanır.
    private func scheduleRebuild() {
        guard !stopped else { return }
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildIfChanged() }
        pendingRebuild = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Yeni tap ÖNCE kurulur, eskisi yeni veri verdikten sonra yıkılır: susturma hiç kesilmez.
    private func rebuildIfChanged() {
        guard !stopped, let old = current else { return }
        let rows = resolved()
        let objects = Set(rows.map { $0.objectID })
        guard objects != old.objects else { return }
        do {
            let new = try build(rows: rows)
            current = new
            retiring.append(old)
            swaps += 1
            log("ses süreç kümesi değişti → yeni tap: \(describe(rows))")
            finishSwap(old: old, new: new, deadline: Date().addingTimeInterval(1.0))
        } catch {
            log("yeni süreç kümesi için tap kurulamadı (\(error)); eskisi sürüyor")
        }
    }

    private func finishSwap(old: Generation, new: Generation, deadline: Date) {
        guard !stopped else { return }
        deliverLock.lock()
        var ready = activeID == new.id
        if !ready && new.objects.isEmpty {
            // Süreçsiz tap veri üretmez (ölçüldü: devralma tetiklenmedi); beklemeden devral.
            activeID = new.id; ready = true
        } else if !ready && Date() > deadline {
            activeID = new.id; ready = true; log("yeni tap 1 sn içinde veri vermedi; zorla devralındı")
        }
        deliverLock.unlock()
        if ready {
            retiring.removeAll { $0 === old }
            destroy(old)
            log("önceki tap yıkıldı (nesil \(old.id) → \(new.id))")
        } else {
            queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.finishSwap(old: old, new: new, deadline: deadline) }
        }
    }

    // MARK: IO

    private func handle(_ gen: Generation, _ input: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard abl.count > 0, let first = abl[0].mData else { return }

        // Çağrının ilk örneğinin host zamanı; yoksa şimdi − süre (kaba, ilk çağrıda loglanır).
        let stamp = time.pointee
        let hostValid = stamp.mFlags.contains(.hostTimeValid) && stamp.mHostTime != 0

        if abl.count == 1 {
            let channels = max(1, Int(abl[0].mNumberChannels))
            let frames = Int(abl[0].mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let host = hostValid ? HostClock.seconds(hostTicks: stamp.mHostTime)
                                 : HostClock.now() - Double(frames) / 48_000
            deliver(gen, UnsafePointer(first.assumingMemoryBound(to: Float.self)),
                    frames: frames, channels: channels, host: host, hostValid: hostValid)
        } else {
            // Planar gelirse interleaved'a çevir (tap-yalnız toplu aygıtta ölçülmedi, savunma).
            let channels = abl.count
            let frames = abl.map { Int($0.mDataByteSize) / MemoryLayout<Float>.size }.min() ?? 0
            guard frames > 0 else { return }
            if gen.scratch.count < frames * channels { gen.scratch = [Float](repeating: 0, count: frames * channels) }
            for c in 0..<channels {
                guard let d = abl[c].mData?.assumingMemoryBound(to: Float.self) else { return }
                for f in 0..<frames { gen.scratch[f * channels + c] = d[f] }
            }
            let host = hostValid ? HostClock.seconds(hostTicks: stamp.mHostTime)
                                 : HostClock.now() - Double(frames) / 48_000
            gen.scratch.withUnsafeBufferPointer {
                deliver(gen, $0.baseAddress!, frames: frames, channels: channels, host: host, hostValid: hostValid)
            }
        }
    }

    private func deliver(_ gen: Generation, _ samples: UnsafePointer<Float>,
                         frames: Int, channels: Int, host: Double, hostValid: Bool) {
        guard frames > 0 else { return }
        deliverLock.lock()
        defer { deliverLock.unlock() }
        if gen.takesOver { gen.takesOver = false; activeID = gen.id }
        guard activeID == gen.id else { return }
        callbackCount += 1
        frameTotal += frames
        if !gen.loggedFirst {
            gen.loggedFirst = true
            log("tap verisi akıyor (nesil \(gen.id)): \(channels) ch, \(frames) çerçeve/çağrı, host damgası \(hostValid ? "var" : "YOK")")
        }
        onFrames(Frames(samples: samples, frameCount: frames, channels: channels, hostSeconds: host))
    }

    // MARK: queue yardımcıları

    @discardableResult
    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }
}

/// Yayın hattının kullandığı kısa yol: uygulama tap'ini kurup kareleri ses paketleyicisine bağlar.
/// Kurulamazsa nil döner ve nedenini loglar (çağıran SCK sesine düşer; o yolda Mac'te susturma yok).
enum AppAudioSource {
    static func start(pid: pid_t, muteLocally: Bool, packetizer: PcmAudioPacketizer,
                      send: @escaping (Data) -> Void, log: @escaping (String) -> Void) -> (() -> Void)? {
        guard #available(macOS 14.2, *), pid > 0 else {
            log("süreç tap'i kullanılamıyor (macOS 14.2 öncesi ya da pencere sahibi bilinmiyor) — ScreenCaptureKit sesi; Mac'te yerel susturma YOK")
            return nil
        }
        let tap = AppAudioTap(pid: pid, muteLocally: muteLocally, onFrames: { [packetizer] f in
            for packet in packetizer.packets(interleaved: f.samples, frames: f.frameCount,
                                             channels: f.channels, hostSeconds: f.hostSeconds) {
                send(packet)
            }
        }, log: log)
        do {
            try tap.start()
            return { tap.stop() }
        } catch {
            tap.stop()
            log("uygulama ses tap'i kurulamadı: \(error) — ScreenCaptureKit sesine düşüldü; Mac'te yerel susturma YOK")
            return nil
        }
    }
}
