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

    // MARK: çoklu kök (TV ekranı modu)

    func testMultipleRootsResolveToUnionWithoutDuplicates() {
        let rows = [
            row(1, pid: 500, responsible: 500, bundle: "org.mozilla.firefox"),
            row(2, pid: 700, responsible: 700, bundle: "com.google.Chrome"),
            row(3, pid: 710, ppid: 700, responsible: 700, bundle: "com.google.Chrome.helper"),
            row(4, pid: 600, responsible: 600, bundle: "com.example.other"),
        ]
        let roots = [AudioRoot(pid: 500, bundleID: "org.mozilla.firefox"),
                     AudioRoot(pid: 700, bundleID: "com.google.Chrome"),
                     AudioRoot(pid: 500, bundleID: "org.mozilla.firefox")]   // yinelenen kök
        let got = AudioProcessResolver.resolve(roots: roots, ownPid: own, rows: rows)
        XCTAssertEqual(got.map { $0.objectID }, [1, 2, 3])
        XCTAssertEqual(AudioProcessResolver.bundleIDs(resolved: got, appBundleIDs: roots.map { $0.bundleID }),
                       ["com.google.Chrome", "com.google.Chrome.helper", "org.mozilla.firefox"])
    }

    func testRootLeavingTheSetShrinksTheResolvedSet() {
        let rows = [
            row(1, pid: 500, responsible: 500, bundle: "org.mozilla.firefox"),
            row(2, pid: 700, responsible: 700, bundle: "com.google.Chrome"),
        ]
        let both = AudioProcessResolver.resolve(roots: [AudioRoot(pid: 500, bundleID: nil), AudioRoot(pid: 700, bundleID: nil)],
                                                ownPid: own, rows: rows)
        let one = AudioProcessResolver.resolve(roots: [AudioRoot(pid: 700, bundleID: nil)], ownPid: own, rows: rows)
        XCTAssertEqual(both.map { $0.objectID }, [1, 2])
        XCTAssertEqual(one.map { $0.objectID }, [2])
        XCTAssertTrue(AudioProcessResolver.resolve(roots: [], ownPid: own, rows: rows).isEmpty)
    }

    func testOwnPidExcludedEvenAsOneOfManyRoots() {
        let rows = [row(1, pid: own, responsible: own, bundle: "app.panecast.sender"),
                    row(2, pid: 500, responsible: 500, bundle: "org.mozilla.firefox")]
        let got = AudioProcessResolver.resolve(roots: [AudioRoot(pid: own, bundleID: "app.panecast.sender"),
                                                       AudioRoot(pid: 500, bundleID: nil)],
                                               ownPid: own, rows: rows)
        XCTAssertEqual(got.map { $0.objectID }, [2])
    }

    func testTvDisplayWindowOwnersByCenterLayerAndOwnPid() {
        let tv = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let c: [TvDisplayWindows.Candidate] = [
            .init(pid: 10, frame: tv, layer: 0),                                         // tam ekran pencere
            .init(pid: 11, frame: CGRect(x: 1700, y: 100, width: 800, height: 600), layer: 0),
            .init(pid: 11, frame: CGRect(x: 2000, y: 200, width: 300, height: 300), layer: 0),   // aynı uygulama, yinelenmez
            .init(pid: 12, frame: CGRect(x: 100, y: 100, width: 800, height: 600), layer: 0),    // ana ekranda
            .init(pid: 13, frame: tv, layer: 25),                                        // menü çubuğu gibi üst katman
            .init(pid: 900, frame: tv, layer: 0),                                        // kendi sürecimiz
            .init(pid: 14, frame: CGRect(x: 1000, y: 0, width: 1000, height: 600), layer: 0),    // merkezi ana ekranda (x=1500)
        ]
        XCTAssertEqual(TvDisplayWindows.ownerPids(c, displayFrame: tv, ownPid: 900), [10, 11])
    }
}
