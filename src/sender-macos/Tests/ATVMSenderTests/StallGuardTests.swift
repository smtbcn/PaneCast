import XCTest
@testable import atvm_sender

/// Sessiz donmanın yorumu. Ölçülen iki vaka testin omurgası:
///  - statik pencere (Notlar): kare gelmiyor ama pencere görünüyor → hiçbir şey yapma
///    (v1'de burada yeniden kurma denendi ve sağlıklı yayın düştü)
///  - ayrı Space'te tam ekran Firefox: kare anında duruyor ve pencere listelenmiyor → uyar, kesme
final class StallGuardTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var q = StallGuard.quietLimit + 0.5

    func testFlowingSourceIsSilent() {
        var g = StallGuard()
        for i in 1...10 {
            XCTAssertNil(g.observe(frames: i * 60, present: true, exists: true, now: t0.addingTimeInterval(Double(i))),
                         "akan kaynakta hiçbir olay beklenmiyordu (tur \(i))")
        }
    }

    func testQuietBelowLimitDoesNothing() {
        var g = StallGuard()
        _ = g.observe(frames: 100, present: true, exists: true, now: t0)
        XCTAssertNil(g.observe(frames: 100, present: true, exists: true,
                               now: t0.addingTimeInterval(StallGuard.quietLimit - 0.3)))
    }

    /// Ölçülen yanlış pozitif: statik içerik = görünür + sessiz. Yeniden kurma YOK.
    func testStaticContentIsNotAFault() {
        var g = StallGuard()
        _ = g.observe(frames: 100, present: true, exists: true, now: t0)
        for s in stride(from: 2.0, through: 12.0, by: 1.0) {
            XCTAssertNil(g.observe(frames: 100, present: true, exists: true, now: t0.addingTimeInterval(s)),
                         "statik pencerede \(s) sn sonra bile olay üretilmemeli")
        }
    }

    func testHiddenWindowReportsOnceAndKeepsStream() {
        var g = StallGuard()
        _ = g.observe(frames: 300, present: true, exists: true, now: t0)
        XCTAssertEqual(g.observe(frames: 300, present: false, exists: true, now: t0.addingTimeInterval(q)), .hidden)
        XCTAssertNil(g.observe(frames: 300, present: false, exists: true, now: t0.addingTimeInterval(q + 3)),
                     "aynı yokluk durumu her saniye tekrar bildirilmemeli")
    }

    /// Pencere geri gelir de kare hâlâ yoksa tek deneme orada anlamlı.
    func testRetryOnlyAfterWindowComesBackStillQuiet() {
        var g = StallGuard()
        _ = g.observe(frames: 300, present: true, exists: true, now: t0)
        XCTAssertEqual(g.observe(frames: 300, present: false, exists: true, now: t0.addingTimeInterval(q)), .hidden)
        XCTAssertEqual(g.observe(frames: 300, present: true, exists: true, now: t0.addingTimeInterval(q + 4)), .retry)
        XCTAssertNil(g.observe(frames: 300, present: true, exists: true, now: t0.addingTimeInterval(q + 9)),
                     "deneme hakkı bir kez kullanılır")
    }

    func testFramesResumingAfterTroubleReportsRecovery() {
        var g = StallGuard()
        _ = g.observe(frames: 300, present: true, exists: true, now: t0)
        XCTAssertEqual(g.observe(frames: 300, present: false, exists: true, now: t0.addingTimeInterval(q)), .hidden)
        XCTAssertEqual(g.observe(frames: 360, present: true, exists: true, now: t0.addingTimeInterval(q + 1)), .resumed)
        XCTAssertNil(g.observe(frames: 420, present: true, exists: true, now: t0.addingTimeInterval(q + 2)),
                     "normale döndükten sonra sıradan akış olay üretmemeli")
    }

    func testClosedWindowIsGone() {
        var g = StallGuard()
        _ = g.observe(frames: 500, present: true, exists: true, now: t0)
        XCTAssertEqual(g.observe(frames: 500, present: false, exists: false, now: t0.addingTimeInterval(q)), .gone)
    }
}
