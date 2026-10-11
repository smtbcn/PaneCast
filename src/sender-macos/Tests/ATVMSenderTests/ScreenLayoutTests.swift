import XCTest
@testable import atvm_sender

/// Kullanıcının "yeni ekran nereye açıldı?" sorusu. Cevap uydurulmaz: ölçülen dizilimden üretilir.
/// Ölçülen vaka: monitör 1 (0,0 1920×1080) · monitör 2 (1920,-257 1080×1920) · PaneCast TV (3000,60 1920×1080)
final class ScreenLayoutTests: XCTestCase {
    private func screen(_ name: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> ScreenLayout.Screen {
        ScreenLayout.Screen(name: name, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    func testTvClosedSaysSoAndListsPhysicalScreens() {
        let text = ScreenLayout.describe([screen("Monitör 1", 0, 0, 1920, 1080),
                                          screen("Monitör 2", 1920, -257, 1080, 1920)],
                                         tvName: "PaneCast TV")
        XCTAssertTrue(text.contains("ŞU AN KAPALI"), text)
        XCTAssertTrue(text.contains("Monitör 1 1920×1080 · Monitör 2 1080×1920"), text)
    }

    func testMeasuredArrangementReadsAsRightSide() {
        let text = ScreenLayout.describe([screen("Monitör 1", 0, 0, 1920, 1080),
                                          screen("Monitör 2", 1920, -257, 1080, 1920),
                                          screen("PaneCast TV", 3000, 60, 1920, 1080)],
                                         tvName: "PaneCast TV")
        XCTAssertTrue(text.contains("AÇIK"), text)
        XCTAssertTrue(text.contains("tüm ekranların SAĞINDA"), text)
    }

    func testScreenAboveAndBelowAreNamedNotGuessed() {
        let above = ScreenLayout.describe([screen("Monitör 1", 0, 0, 1920, 1080),
                                           screen("PaneCast TV", 0, 1080, 1920, 1080)],
                                          tvName: "PaneCast TV")
        XCTAssertTrue(above.contains("tüm ekranların ÜSTÜNDE"), above)
        let below = ScreenLayout.describe([screen("Monitör 1", 0, 0, 1920, 1080),
                                           screen("PaneCast TV", 0, -1080, 1920, 1080)],
                                          tvName: "PaneCast TV")
        XCTAssertTrue(below.contains("tüm ekranların ALTINDA"), below)
        let left = ScreenLayout.describe([screen("PaneCast TV", -1920, 0, 1920, 1080),
                                          screen("Monitör 1", 0, 0, 1920, 1080)],
                                         tvName: "PaneCast TV")
        XCTAssertTrue(left.contains("tüm ekranların SOLUNDA"), left)
    }

    func testOverlappingArrangementReportsCoordinates() {
        let text = ScreenLayout.describe([screen("Monitör 1", 0, 0, 1920, 1080),
                                          screen("PaneCast TV", 1000, 500, 1920, 1080)],
                                         tvName: "PaneCast TV")
        XCTAssertTrue(text.contains("ekranların arasında (x=1000, y=500)"), text)
    }
}
