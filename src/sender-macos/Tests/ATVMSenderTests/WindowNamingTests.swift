import XCTest
@testable import atvm_sender

/// Pencere satırının isimlendirme kuralı: `Uygulama — içerik`.
/// Ölçülen kusur: etiket baştan kırpıldığı için uzun tarayıcı başlığında uygulama adı
/// kayboluyordu; ayrıca başlıklar okunmamış sayacı `(1131) ` ve uygulamanın kendi adını
/// tekrar eden son ek ` - Slack` taşıyordu. (Süslemeler gerçek hesap/şirket adı içermez.)
final class WindowNamingTests: XCTestCase {
    func testLeadingUnreadCounterIsDropped() {
        XCTAssertEqual(WindowNaming.clean("(1131) Video Başlığı | Kanal - YouTube", app: "Firefox"),
                       "Video Başlığı | Kanal - YouTube")
        XCTAssertEqual(WindowNaming.clean("(99+) Gelen Kutusu - Gmail", app: "Safari"),
                       "Gelen Kutusu - Gmail")
    }

    /// Parantezli kısaltma sayaç değildir: "(DM)" yerinde kalmalı.
    func testParenthesisedWordIsNotACounter() {
        XCTAssertEqual(WindowNaming.clean("Toplantı (DM) - Ekip - Slack", app: "Slack"),
                       "Toplantı (DM) - Ekip")
    }

    /// Sayaçtan sonra boşluk yoksa dokunulmaz: "(1)Bir" bir başlığın parçası olabilir.
    func testCounterNeedsASpace() {
        XCTAssertEqual(WindowNaming.clean("(1)Bir", app: "Firefox"), "(1)Bir")
    }

    func testTrailingAppNameIsDroppedForEverySeparator() {
        for sep in ["-", "–", "—"] {
            XCTAssertEqual(WindowNaming.clean("Belge - Ekip \(sep) Slack", app: "Slack"),
                           "Belge - Ekip", "ayraç: \(sep)")
        }
    }

    /// Uygulamayı anlatmayan son ek korunduğu gibi kalır: "YouTube" tarayıcının adı değil.
    func testForeignSuffixSurvives() {
        XCTAssertEqual(WindowNaming.clean("Video Başlığı - YouTube", app: "Firefox"),
                       "Video Başlığı - YouTube")
    }

    /// Tüm temizlik başlığı boşaltırsa orijinal geri gelir — asla boş satır çizmeyiz.
    func testEmptiedTitleFallsBackToOriginal() {
        XCTAssertEqual(WindowNaming.clean("Slack", app: "Slack"), "Slack")
        XCTAssertEqual(WindowNaming.clean(" - slack", app: "Slack"), "- slack")
    }

    /// Son uygulama adı düşürülünce ortada yarım ayraç bırakılmaz.
    func testDanglingSeparatorIsTrimmed() {
        XCTAssertEqual(WindowNaming.clean("Proje Taslağı - Slack", app: "Slack"), "Proje Taslağı")
        XCTAssertEqual(WindowNaming.clean("A - B - slack", app: "Slack"), "A - B")
    }

    func testRowTextPairsAppWithContent() {
        XCTAssertEqual(WindowNaming.rowText(app: "Firefox", title: "(42) Video Başlığı - YouTube"),
                       "Firefox — Video Başlığı - YouTube")
    }

    /// "Qoder — Qoder" gürültüsü: içerik uygulama adıyla aynıysa yalnız uygulama yazılır.
    func testRowTextDoesNotRepeatTheAppName() {
        XCTAssertEqual(WindowNaming.rowText(app: "Qoder", title: "Qoder"), "Qoder")
        XCTAssertEqual(WindowNaming.rowText(app: "qoder", title: "QODER"), "qoder")
    }

    func testRowTextHandlesEmptyAndBlankTitles() {
        XCTAssertEqual(WindowNaming.rowText(app: "Claude", title: ""), "Claude")
        XCTAssertEqual(WindowNaming.rowText(app: "Claude", title: "   "), "Claude")
    }

    /// Uzun başlıkta satırın başı uygulama adı olmalı: kesme ortada olur (etiket
    /// `.byTruncatingMiddle`), yani kural başı asla yutmuyor.
    func testRowTextKeepsTheAppNameFirst() {
        let long = String(repeating: "içerik ", count: 40)
        let row = WindowNaming.rowText(app: "Firefox", title: long)
        XCTAssertTrue(row.hasPrefix("Firefox — "), "satır uygulama adıyla başlamalı: \(row.prefix(20))")
    }
}
