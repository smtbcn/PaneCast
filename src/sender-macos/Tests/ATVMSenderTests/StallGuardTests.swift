import XCTest
@testable import atvm_sender

/// Sessiz donmanın tespiti: SCK hata vermeden kare vermeyi kesiyor, tek işaret sayaç durması.
final class StallGuardTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testNoEventWhileFramesFlow() {
        var g = StallGuard()
        for i in 1...10 {
            XCTAssertNil(g.observe(i * 60, now: t0.addingTimeInterval(Double(i))),
                         "akan kaynakta hiçbir olay beklenmiyordu (tur \(i))")
        }
    }

    func testQuietBelowLimitIsSilent() {
        var g = StallGuard()
        _ = g.observe(100, now: t0)
        XCTAssertNil(g.observe(100, now: t0.addingTimeInterval(StallGuard.quietLimit - 0.2)),
                     "eşik altındaki sessizlik uyandırmamalı")
    }

    func testRetryFiresExactlyOnce() {
        var g = StallGuard()
        _ = g.observe(100, now: t0)
        XCTAssertEqual(g.observe(100, now: t0.addingTimeInterval(StallGuard.quietLimit)), .retry)
        XCTAssertNil(g.observe(100, now: t0.addingTimeInterval(StallGuard.quietLimit + 1)),
                     "ikinci kez yeniden kurma denemesi olmamalı")
    }

    func testGivesUpOnlyAfterRetryFailed() {
        var g = StallGuard()
        _ = g.observe(100, now: t0)
        XCTAssertEqual(g.observe(100, now: t0.addingTimeInterval(2)), .retry)
        XCTAssertEqual(g.observe(100, now: t0.addingTimeInterval(StallGuard.giveUpLimit)), .stalled)
        XCTAssertEqual(g.observe(100, now: t0.addingTimeInterval(30)), .stalled,
                       "vazgeçme durumu tekrar söylenebilir; çağıran tek sefer loglar")
    }

    func testResumeClearsStateAndCanTriggerAgain() {
        var g = StallGuard()
        _ = g.observe(100, now: t0)
        XCTAssertEqual(g.observe(100, now: t0.addingTimeInterval(2)), .retry)
        XCTAssertEqual(g.observe(160, now: t0.addingTimeInterval(2.5)), .resumed,
                       "kare hareket edince iyileşme bildirilmeli")
        XCTAssertNil(g.observe(160, now: t0.addingTimeInterval(3)))
        XCTAssertEqual(g.observe(160, now: t0.addingTimeInterval(6)), .retry,
                       "yeni sıkışma için deneme hakkı sıfırlanmalı")
    }

    func testCounterJumpAloneIsEnough() {
        var g = StallGuard()
        XCTAssertNil(g.observe(0, now: t0), "ilk gözlem sayacı henüz bilmiyor, olay yok")
        XCTAssertEqual(g.observe(0, now: t0.addingTimeInterval(StallGuard.quietLimit)), .retry,
                       "hiç kare gelmemişse eşikten sonra deneme başlar")
    }
}
