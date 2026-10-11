import Foundation
import CoreGraphics
import ScreenCaptureKit
import CVirtualDisplay

/// "TV ekranı" modu: Mac'te TV boyutunda sanal bir ekran açılır; oraya taşınan pencereler TV'de oynar.
/// macOS'ta sanal ekran için herkese açık API yok → CoreGraphics'in özel sınıfları (CVirtualDisplay köprüsü).
/// Nesne yaşadıkça ekran vardır; bırakılınca (ya da süreç ölünce) kaybolur.
/// @MainActor: sanal ekran kurulumu ve kip yeniden uygulama WindowServer ile ana iş parçasından
/// konuşulur; ayrıca günlük AppKit'e dokunuyor (ana iş parçası dışında çöküyor — ölçüldü).
@MainActor
final class TvDisplay {
    static let name = "PaneCast TV"
    static let width = 1920, height = 1080

    private let virtual: PCVirtualDisplay
    let displayID: CGDirectDisplayID
    /// Yoklama gözlemleri yayın günlüğüne yazılır; hata olursa neden tek tek okunur.
    private let onProbe: (String) -> Void

    static func create(onProbe: @escaping (String) -> Void = { _ in }) throws -> TvDisplay {
        var reason: NSString?
        guard let v = PCVirtualDisplay.create(withName: name, width: UInt32(width), height: UInt32(height),
                                              refreshRate: 60, error: &reason) else {
            throw CaptureError.stream("TV ekranı açılamadı: \(reason as String? ?? "bilinmeyen neden")")
        }
        let t = TvDisplay(virtual: v, onProbe: onProbe)
        onProbe("sanal ekran kuruldu: \(t.setupState)")
        return t
    }

    private init(virtual: PCVirtualDisplay, onProbe: @escaping (String) -> Void) {
        self.virtual = virtual
        self.displayID = virtual.displayID
        self.onProbe = onProbe
    }

    var pixelSize: CGSize { CGSize(width: Self.width, height: Self.height) }
    /// Kurulum anındaki WindowServer durumu (applySettings/deneme/çevrimiçi/kip).
    var setupState: String { virtual.lastState ?? "-" }

    /// ScreenCaptureKit yeni ekranı hemen listelemeyebilir: kısa süre yoklanır.
    /// Yoklama sırasında ekran çevrimiçi düştüyse kip yeniden uygulanır (uygulama içinde
    /// tek seferlik bağlama CLI'daki kadar kalıcı olmuyor — ölçüldü: isOnline=0).
    func shareable(attempts: Int = 40) async throws -> SCDisplay {
        var sonDurum = "-"
        var sckKimlikleri = "-"
        for deneme in 0..<attempts {
            if deneme > 0, !virtual.reapply() {
                onProbe("yoklama \(deneme): ekran çevrimiçi değil → kip yeniden uygulandı")
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let d = content.displays.first(where: { $0.displayID == displayID }) {
                if deneme > 0 { onProbe("TV ekranı yoklama \(deneme) sonra SCK'de göründü") }
                return d
            }
            sckKimlikleri = content.displays.map { "\($0.displayID)" }.joined(separator: ",")
            sonDurum = PCVirtualDisplay.stateOf(displayID: displayID) as String
            if deneme % 5 == 0 {
                onProbe("yoklama \(deneme): SCK listesi [\(sckKimlikleri)] · \(sonDurum)")
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw CaptureError.stream("TV ekranı (displayID \(displayID)) ScreenCaptureKit'te görünmedi · " +
                                  "SCK listesi: [\(sckKimlikleri)] · kurulumda: \(setupState) · son: \(sonDurum)")
    }
}

/// Hangi uygulamaların TV ekranında pencere tuttuğu (saf, test edilebilir).
enum TvDisplayWindows {
    struct Candidate {
        let pid: pid_t
        let frame: CGRect
        let layer: Int
    }

    /// Normal katmandaki (0) pencerelerden merkezi ekranın içinde olanların sahipleri; kendi sürecimiz hariç.
    static func ownerPids(_ candidates: [Candidate], displayFrame: CGRect, ownPid: pid_t) -> [pid_t] {
        let pids = candidates.filter { c in
            c.pid > 0 && c.pid != ownPid && c.layer == 0
                && displayFrame.contains(CGPoint(x: c.frame.midX, y: c.frame.midY))
        }.map { $0.pid }
        return Array(Set(pids)).sorted()
    }
}

/// Saniyede bir TV ekranındaki pencere sahiplerini yeniler; ses tap'i kök kümesini buradan okur.
final class TvDisplayAppTracker: @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let lock = NSLock()
    private var pids: [pid_t] = []
    private var task: Task<Void, Never>?
    private let log: (String) -> Void

    init(displayID: CGDirectDisplayID, log: @escaping (String) -> Void) {
        self.displayID = displayID
        self.log = log
    }

    /// Tap kurulmadan önce ilk küme hazır olsun diye bir kez beklenir, sonra döngü başlar.
    func start() async {
        await refresh()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.refresh()
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    func roots() -> [AudioRoot] {
        lock.lock(); defer { lock.unlock() }
        return pids.map { AudioRoot(pid: $0, bundleID: NSRunningApplication(processIdentifier: $0)?.bundleIdentifier) }
    }

    private func refresh() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
        let candidates = content.windows.compactMap { w -> TvDisplayWindows.Candidate? in
            guard let pid = w.owningApplication?.processID else { return nil }
            return TvDisplayWindows.Candidate(pid: pid, frame: w.frame, layer: w.windowLayer)
        }
        let next = TvDisplayWindows.ownerPids(candidates, displayFrame: display.frame, ownPid: getpid())
        if update(next) { log("TV ekranındaki uygulamalar (pid): \(next)") }
    }

    private func update(_ next: [pid_t]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let changed = next != pids
        pids = next
        return changed
    }
}

/// "Yeni ekran sağda mı solda mı?" — cevabı ekranların gerçek diziliminden okunur, uydurulmaz.
enum ScreenLayout {
    struct Screen {
        let name: String
        let frame: CGRect
    }

    static func describe(_ screens: [Screen], tvName: String) -> String {
        let soldanSaga = screens.sorted { $0.frame.minX < $1.frame.minX }
        let liste = soldanSaga.map { "\($0.name) \(Int($0.frame.width))×\(Int($0.frame.height))" }
            .joined(separator: " · ")
        guard let tv = soldanSaga.first(where: { $0.name == tvName }) else {
            return "Ekranlar soldan sağa: \(liste)\n\(tvName) ŞU AN KAPALI — Başlat'a bastığında Mac'te ayrı "
                + "1920×1080 bir ekran açılır; buraya düşdüğü konum yazılır."
        }
        let digerleri = soldanSaga.filter { $0.name != tvName }
        let kenar: String
        if let sag = digerleri.map({ $0.frame.maxX }).max(), tv.frame.minX >= sag - 1 {
            kenar = "tüm ekranların SAĞINDA"
        } else if let sol = digerleri.map({ $0.frame.minX }).min(), tv.frame.maxX <= sol + 1 {
            kenar = "tüm ekranların SOLUNDA"
        } else if let ust = digerleri.map({ $0.frame.maxY }).max(), tv.frame.minY >= ust - 1 {
            kenar = "tüm ekranların ÜSTÜNDE"
        } else if let alt = digerleri.map({ $0.frame.minY }).min(), tv.frame.maxY <= alt + 1 {
            kenar = "tüm ekranların ALTINDA"
        } else {
            kenar = "ekranların arasında (x=\(Int(tv.frame.minX)), y=\(Int(tv.frame.minY)))"
        }
        return "Ekranlar soldan sağa: \(liste)\n\(tvName) AÇIK — \(kenar). Pencereyi o ekrana sürükle "
            + "(tam ekran da olur); Mac'te ne açarsan aç TV yayını kesilmez."
    }
}
