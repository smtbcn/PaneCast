import Foundation
import XCTest
@testable import atvm_sender

/// Panonun saf yanları: olay tekilleştirme ve yerleşim kararları.
/// Ölçülen kusur: keşif 20 saniyede bir aynı satırı arayüze ekliyor, panel metin duvarına
/// dönüyordu. Aynı metin artık tek satırda sayaç olarak toplanır.
final class DashboardTests: XCTestCase {
    func testRepeatedEventFoldsIntoOneRow() {
        let book = EventBook()
        for _ in 0 ..< 12 { book.add("keşif: 1 TV bulundu (1 eşleşmiş)") }
        XCTAssertEqual(book.rows.count, 1)
        XCTAssertEqual(book.rows.first?.count, 12)
        XCTAssertEqual(book.lineCount, 12)
    }

    func testNewestGroupFloatsToTop() {
        let book = EventBook()
        book.add("ilk")
        book.add("ikinci", .error)
        book.add("ilk")
        XCTAssertEqual(book.rows.map(\.text), ["ilk", "ikinci"])
        XCTAssertEqual(book.rows[1].severity, .error)
    }

    func testSeverityKeepsTheWorstOfRepeats() {
        let book = EventBook()
        book.add("yayın", .info)
        book.add("yayın", .warn)
        book.add("yayın", .info)
        XCTAssertEqual(book.rows.first?.severity, .warn)
        XCTAssertEqual(book.rows.first?.count, 3)
    }

    func testBookIsCapped() {
        let book = EventBook(limit: 5)
        for i in 0 ..< 40 { book.add("olay \(i)") }
        XCTAssertEqual(book.rows.count, 5)
        XCTAssertEqual(book.rows.first?.text, "olay 39", "en yeni üstte kalmalı")
    }

    /// Sütun kararları: dar pencerede az sütun, genişte çok — kutular okunaklı kalsın.
    func testColumnBreakpoints() {
        XCTAssertEqual(DashboardView.columns(for: 500), 2)
        XCTAssertEqual(DashboardView.columns(for: 700), 3)
        XCTAssertEqual(DashboardView.columns(for: 1000), 4)
        XCTAssertEqual(DashboardView.columns(for: 1300), 5)
    }

    /// Gerekli yükseklik, sığan yükseklikten az olmamalı: ölçüldü, tam hesaplanan
    /// yükseklikte "Olaylar" satırı kesiliyordu.
    func testNeededHeightCoversFiveTilesInTwoRows() {
        let need = DashboardView(frame: .zero).neededHeight(forWidth: 700)
        let twoRows: CGFloat = 14 + 30 + 2 * (104 + 8) + 32 + 20 + 14
        XCTAssertEqual(need, twoRows, accuracy: 0.01)
        XCTAssertGreaterThan(need, 300)
    }
}
