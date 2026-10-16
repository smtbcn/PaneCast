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

    /// Olay ekranındaki "Temizle" yalnız arayüz defterini boşaltır, sayaçlar sıfırlanır.
    func testClearEmptiesTheBook() {
        let book = EventBook()
        book.add("a"); book.add("b"); book.add("a")
        XCTAssertEqual(book.groupCount, 2)
        XCTAssertEqual(book.lineCount, 3)
        book.clear()
        XCTAssertTrue(book.rows.isEmpty)
        XCTAssertEqual(book.groupCount, 0)
        XCTAssertEqual(book.lineCount, 0)
    }

    /// Sütun kararları: dar pencerede az sütun, genişte beş kutu tek satıra sığar —
    /// 4 sütun 5. kutuyu yapayalnız bırakıyordu (orantı isteği).
    func testColumnBreakpoints() {
        XCTAssertEqual(DashboardView.columns(for: 500), 2)
        XCTAssertEqual(DashboardView.columns(for: 700), 3)
        XCTAssertEqual(DashboardView.columns(for: 1000), 5)
        XCTAssertEqual(DashboardView.columns(for: 1300), 5)
        XCTAssertEqual(DashboardView.tileRows(forWidth: 1000), 1)
        XCTAssertEqual(DashboardView.tileRows(forWidth: 700), 2)
        XCTAssertEqual(DashboardView.tileRows(forWidth: 500), 3)
    }

    /// Gerekli yükseklik, sığan yükseklikten az olmamalı: ölçüldü, tam hesaplanan
    /// yükseklikte "Olaylar" satırı kesiliyordu. Ağ şeridi her modda sayılır.
    func testNeededHeightCoversTilesAndSummaryRow() {
        let strip = DashboardView.stripRowHeight
        // 700 px → 3 sütun → 5 kutu 2 satıra dizilir.
        let full = DashboardView.requiredHeight(width: 700, tileH: DashboardView.tileHeight, tiles: 5)
        XCTAssertEqual(full, DashboardView.chipRowHeight + 2 * (104 + 8) + strip + DashboardView.summaryRowHeight,
                       accuracy: 0.01)
        // Alçak kutu (grafik çizgisi düşmüş) daha az yer ister.
        let short = DashboardView.requiredHeight(width: 700, tileH: DashboardView.shortTileHeight, tiles: 5)
        XCTAssertLessThan(short, full)
        // Katışık: çip + şerit + özet (ölçü kutuları kalkar, ağ yükü görünür kalır).
        XCTAssertEqual(DashboardView.requiredHeight(width: 700, tileH: 0, tiles: 0),
                       DashboardView.chipRowHeight + strip + DashboardView.summaryRowHeight, accuracy: 0.01)
        // Genişte tek satıra sığar → pano alçalır, listeler uzar (orantı isteği).
        XCTAssertEqual(DashboardView.tileRows(forWidth: 1300), 1)
        XCTAssertLessThan(DashboardView.requiredHeight(width: 1300, tileH: 104, tiles: 5),
                          DashboardView.requiredHeight(width: 700, tileH: 104, tiles: 5))
    }

    /// Görünümün kendi hesabı ile saf hesap aynı olmalı: `layoutContent` panoyu bu
    /// yükseklikle biçimlendiriyor, farklılık olursa son satır kesilir.
    func testInstanceNeededHeightMatchesPureFormula() {
        let dash = DashboardView(frame: .zero)
        XCTAssertEqual(dash.neededHeight(forWidth: 700),
                       DashboardView.requiredHeight(width: 700, tileH: DashboardView.tileHeight, tiles: 5),
                       accuracy: 0.01)
        dash.compactTiles = true
        XCTAssertEqual(dash.neededHeight(forWidth: 700),
                       DashboardView.requiredHeight(width: 700, tileH: DashboardView.shortTileHeight, tiles: 5),
                       accuracy: 0.01)
        dash.compact = true
        XCTAssertEqual(dash.neededHeight(forWidth: 700),
                       DashboardView.requiredHeight(width: 700, tileH: 0, tiles: 0), accuracy: 0.01)
    }
}
