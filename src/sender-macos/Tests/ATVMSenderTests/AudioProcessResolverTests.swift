import XCTest
@testable import atvm_sender

final class AudioProcessResolverTests: XCTestCase {
    private func row(_ obj: UInt32, pid: pid_t, ppid: pid_t = 1, responsible: pid_t?, bundle: String) -> AudioProcessRow {
        AudioProcessRow(objectID: obj, pid: pid, ppid: ppid, responsiblePid: responsible, bundleID: bundle)
    }

    private let own: pid_t = 900

    func testFirefoxMainPidIsTheAudioProcess() {
        let rows = [
            row(1, pid: 500, responsible: 500, bundle: "org.mozilla.firefox"),
            row(2, pid: 600, responsible: 600, bundle: "com.example.other"),
        ]
        let got = AudioProcessResolver.resolve(appPid: 500, appBundleID: "org.mozilla.firefox", ownPid: own, rows: rows)
        XCTAssertEqual(got.map { $0.objectID }, [1])
    }

    func testChromeHelperIsFoundByResponsiblePid() {
        let rows = [
            row(1, pid: 700, responsible: 700, bundle: "com.google.Chrome"),
            row(2, pid: 710, ppid: 700, responsible: 700, bundle: "com.google.Chrome.helper"),
            row(3, pid: 720, ppid: 1, responsible: 720, bundle: "com.google.Chrome.canary.helper"),   // başka uygulama
        ]
        let got = AudioProcessResolver.resolve(appPid: 700, appBundleID: "com.google.Chrome", ownPid: own, rows: rows)
        XCTAssertEqual(got.map { $0.objectID }, [1, 2])
        XCTAssertEqual(AudioProcessResolver.bundleIDs(resolved: got, appBundleID: "com.google.Chrome"),
                       ["com.google.Chrome", "com.google.Chrome.helper"])
    }

    func testWebKitGpuServiceBelongsToItsResponsibleHostOnly() {
        // İki WebKit uygulaması aynı bundle id'li GPU servisini paylaşır; sorumlu pid ayırır.
        let rows = [
            row(1, pid: 800, responsible: 800, bundle: "com.apple.Safari"),
            row(2, pid: 810, ppid: 1, responsible: 800, bundle: "com.apple.WebKit.GPU"),
            row(3, pid: 820, ppid: 1, responsible: 830, bundle: "com.apple.WebKit.GPU"),
            row(4, pid: 830, responsible: 830, bundle: "com.example.webkitapp"),
        ]
        let safari = AudioProcessResolver.resolve(appPid: 800, appBundleID: "com.apple.Safari", ownPid: own, rows: rows)
        XCTAssertEqual(safari.map { $0.objectID }, [1, 2])
        let other = AudioProcessResolver.resolve(appPid: 830, appBundleID: "com.example.webkitapp", ownPid: own, rows: rows)
        XCTAssertEqual(other.map { $0.objectID }, [3, 4])
        // Ortak GPU kimliği asla bundleIDs listesine girmez.
        XCTAssertEqual(AudioProcessResolver.bundleIDs(resolved: safari, appBundleID: "com.apple.Safari"),
                       ["com.apple.Safari"])
    }

    func testOwnPidIsAlwaysExcluded() {
        let rows = [
            row(1, pid: own, responsible: own, bundle: "dev.atvm.sender"),
            row(2, pid: 950, ppid: own, responsible: own, bundle: "dev.atvm.sender.helper"),
        ]
        // Uygulama pid'i kendimiz olsa bile (savunma): kendi sesimizi tap'leyip döngü kurmayız.
        XCTAssertTrue(AudioProcessResolver.resolve(appPid: own, appBundleID: "dev.atvm.sender", ownPid: own, rows: rows)
            .allSatisfy { $0.pid != own })
        // Kendi sürecimiz başka bir uygulamanın sorumluluğunda görünse de dışarıda.
        let foreign = [row(3, pid: own, responsible: 500, bundle: "dev.atvm.sender")]
        XCTAssertTrue(AudioProcessResolver.resolve(appPid: 500, appBundleID: "org.mozilla.firefox", ownPid: own, rows: foreign).isEmpty)
    }

    func testFallbackWithoutResponsiblePidUsesParentOrBundlePrefix() {
        let rows = [
            row(1, pid: 500, responsible: nil, bundle: "org.example.app"),
            row(2, pid: 510, ppid: 500, responsible: nil, bundle: ""),
            row(3, pid: 520, ppid: 1, responsible: nil, bundle: "org.example.app.renderer"),
            row(4, pid: 530, ppid: 1, responsible: nil, bundle: "org.example.application"),      // önek ama nokta sınırı yok
            row(5, pid: 540, ppid: 1, responsible: nil, bundle: "com.apple.WebKit.GPU"),
        ]
        let got = AudioProcessResolver.resolve(appPid: 500, appBundleID: "org.example.app", ownPid: own, rows: rows)
        XCTAssertEqual(got.map { $0.objectID }, [1, 2, 3])
    }

    func testResponsiblePidOverridesBundlePrefix() {
        // Sorumlu pid biliniyorsa başka uygulamaya aitse bundle öneki yetmez.
        let rows = [row(1, pid: 610, responsible: 999, bundle: "org.example.app.helper")]
        XCTAssertTrue(AudioProcessResolver.resolve(appPid: 600, appBundleID: "org.example.app", ownPid: own, rows: rows).isEmpty)
    }
}
