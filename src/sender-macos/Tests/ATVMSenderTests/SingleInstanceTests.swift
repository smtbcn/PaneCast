import Foundation
import XCTest
@testable import atvm_sender

/// Tek örnek kuralının saf tarafı: hangi komutlar kilitlenir, kimi içeri alır.
/// Ölçülen kusur: ikinci örnek yalnız uyarı alıyordu ve gerçekten çalışıyordu
/// (test sırasında üç örnek birden; aynı TV kanalları çakıştı).
final class SingleInstanceTests: XCTestCase {
    func testOnlyServingCommandsAreLocked() {
        for c in ["", "gui", "mirror", "switch-test"] {
            XCTAssertTrue(InstanceGuard.isServing(c), "\(c) TV kanallarını tutar")
        }
        for c in ["list-tvs", "list-windows", "selftest", "netload", "dns-probe", "list-pairs", "unpair"] {
            XCTAssertFalse(InstanceGuard.isServing(c), "\(c) salt-okunur teşhistir, arayüz açıkken koşabilmeli")
        }
    }

    func testNoSiblingMeansNoYield() {
        XCTAssertNil(InstanceGuard.yieldTo(myPid: 100, others: [], lockPid: nil, alive: { _ in false }))
    }

    func testOtherProcessWins() {
        XCTAssertEqual(InstanceGuard.yieldTo(myPid: 100, others: [77, 55], lockPid: nil,
                                             alive: { _ in true }), 55, "en küçük pid seçilir (kararlılık)")
    }

    /// Kilit sahibi yaşıyorsa içeri alınmaz; kendi pid'miz sayılmaz.
    func testLiveLockBlocksButOwnLockDoesNot() {
        XCTAssertEqual(InstanceGuard.yieldTo(myPid: 100, others: [], lockPid: 90, alive: { _ in true }), 90)
        XCTAssertNil(InstanceGuard.yieldTo(myPid: 100, others: [], lockPid: 100, alive: { _ in true }))
    }

    /// Çökmeden kalan kilit (sahibi ölmüş) engellememeli: aksi hâlde uygulama bir daha açılmaz.
    func testStaleLockIsIgnored() {
        XCTAssertNil(InstanceGuard.yieldTo(myPid: 100, others: [], lockPid: 90, alive: { _ in false }))
        XCTAssertTrue(InstanceGuard.isStale(lockPid: nil, alive: { _ in true }), "okunamayan kilit bayattır")
        XCTAssertFalse(InstanceGuard.isStale(lockPid: 90, alive: { _ in true }))
    }

    /// Süreç yoklaması gerçekten işletim sistemine sorulur: uydurma yüksek pid ölü döner.
    func testProcessAliveProbe() {
        XCTAssertTrue(InstanceGuard.processAlive(Int(ProcessInfo.processInfo.processIdentifier)))
        XCTAssertFalse(InstanceGuard.processAlive(999_999))
    }

    func testSiblingProbeExcludesSelf() {
        let mine = Int(ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(InstanceGuard.siblingPids().contains(mine), "kendi pid'miz rakip sayılmaz")
    }

    /// Yaşayan sahibin kilidine dokunulmaz: ikinci örnek dosyayı ne ezer ne siler.
    /// Ölçülen kusur: `enforce` hem kilidi yaratıp sonra `releaseLock()` çağırıyordu —
    /// yani boyuna giden süreç, birinci örneğin kilidini siliyordu.
    func testLiveHolderKeepsItsLockFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("panecast-lock-test-\(UUID().uuidString)")
        let holder = Int(getppid())                 // koşan, yaşayan, bize ait olmayan süreç
        XCTAssertTrue(InstanceGuard.processAlive(holder), "ölçüm için yaşayan bir pid gerekiyor")
        try "\(holder)\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let mine = Int(ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(InstanceGuard.acquireLock(myPid: mine, at: url), holder)
        XCTAssertEqual(try? String(contentsOf: url, encoding: .utf8), "\(holder)\n", "sahip değişmedi")

        // Kuralın diğer yarısı: koşan örnek varsa kilit zaten denenmez (enforce sırası).
        XCTAssertNotNil(InstanceGuard.yieldTo(myPid: mine, others: [holder], lockPid: nil,
                                              alive: InstanceGuard.processAlive),
                        "karar kilitsiz de verilebiliyor; kilide hiç dokunulmuyor")
    }

    /// Ölmüş sahibin kilidi devralınır (çökme artığı uygulama açılmazda kalmasın).
    func testDeadHolderLockIsTakenOver() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("panecast-lock-test-\(UUID().uuidString)")
        try "999999\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let mine = Int(ProcessInfo.processInfo.processIdentifier)
        XCTAssertNil(InstanceGuard.acquireLock(myPid: mine, at: url), "bayat kilit devralınır")
        XCTAssertEqual(try? String(contentsOf: url, encoding: .utf8), "\(mine)\n")
    }
}
