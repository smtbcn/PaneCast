import Foundation
import CoreGraphics
import ScreenCaptureKit
import CVirtualDisplay

/// "TV ekranı" modu: Mac'te TV boyutunda sanal bir ekran açılır; oraya taşınan pencereler TV'de oynar.
/// macOS'ta sanal ekran için herkese açık API yok → CoreGraphics'in özel sınıfları (CVirtualDisplay köprüsü).
/// Nesne yaşadıkça ekran vardır; `release()` ya da süreç ölümüyle kaybolur.
final class TvDisplay {
    static let name = "PaneCast TV"
    static let width = 1920, height = 1080

    private var virtual: PCVirtualDisplay?
    let displayID: CGDirectDisplayID

    static func create() throws -> TvDisplay {
        var reason: NSString?
        guard let v = PCVirtualDisplay.create(withName: name, width: UInt32(width), height: UInt32(height),
                                              refreshRate: 60, error: &reason) else {
            throw CaptureError.stream("TV ekranı açılamadı: \(reason as String? ?? "bilinmeyen neden")")
        }
        return TvDisplay(virtual: v)
    }

    private init(virtual: PCVirtualDisplay) {
        self.virtual = virtual
        self.displayID = virtual.displayID
    }

    var pixelSize: CGSize { CGSize(width: Self.width, height: Self.height) }

    /// Ekranı kaldırır (strong referansı bırakır).
    func release() { virtual = nil }

    /// ScreenCaptureKit yeni ekranı hemen listelemeyebilir: kısa süre yoklanır.
    static func shareableDisplay(_ id: CGDirectDisplayID, attempts: Int = 25) async throws -> SCDisplay {
        for _ in 0..<attempts {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let d = content.displays.first(where: { $0.displayID == id }) { return d }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw CaptureError.stream("TV ekranı (displayID \(id)) ScreenCaptureKit'te görünmedi")
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
