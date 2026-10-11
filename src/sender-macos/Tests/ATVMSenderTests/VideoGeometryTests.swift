import XCTest
@testable import atvm_sender

final class VideoGeometryTests: XCTestCase {
    private let boxW = 1920, boxH = 1080

    private func fit(_ w: Double, _ h: Double, scale: Double = 1) -> VideoGeometry.Size {
        VideoGeometry.encodeSize(pixelWidth: w * scale, pixelHeight: h * scale, boxWidth: boxW, boxHeight: boxH)
    }

    private func aspectError(_ s: VideoGeometry.Size, _ w: Double, _ h: Double) -> Double {
        let a = w / h
        return abs(Double(s.width) / Double(s.height) - a) / a
    }

    private func assertSane(_ s: VideoGeometry.Size, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(s.width, boxW, file: file, line: line)
        XCTAssertLessThanOrEqual(s.height, boxH, file: file, line: line)
        XCTAssertEqual(s.width % 2, 0, file: file, line: line)
        XCTAssertEqual(s.height % 2, 0, file: file, line: line)
    }

    /// Ölçülen kusur: 1072×944 pencere nokta boyutuyla kodlanıp TV'de 1920×1080'e gerildi.
    /// Retina'da piksel boyutu 2144×1888'dir ve profil kutusuna oranla sığar.
    func testLandscapeRetina() {
        let s = fit(1072, 944, scale: 2)
        assertSane(s)
        XCTAssertLessThanOrEqual(aspectError(s, 2144, 1888), 0.01)
        XCTAssertGreaterThanOrEqual(s.height, 1056, "kutuyu doldurmalı: \(s)")
    }

    func testPortraitNotStretched() {
        let s = fit(1080, 1920)
        assertSane(s)
        XCTAssertLessThan(s.width, s.height)
        XCTAssertLessThanOrEqual(aspectError(s, 1080, 1920), 0.01)
        XCTAssertEqual(s.height, boxH)
    }

    func testUltrawide() {
        let s = fit(3440, 1440)
        assertSane(s)
        XCTAssertLessThanOrEqual(aspectError(s, 3440, 1440), 0.01)
        XCTAssertGreaterThanOrEqual(s.width, 1700)
    }

    /// Küçük pencere: asgari boyuta oranla büyütülür, esnetilmez.
    func testTinyWindowScalesUpUniformly() {
        let s = fit(300, 200)
        assertSane(s)
        XCTAssertLessThanOrEqual(aspectError(s, 300, 200), 0.01)
        XCTAssertGreaterThanOrEqual(s.width, VideoGeometry.minLong)
        XCTAssertGreaterThanOrEqual(s.height, VideoGeometry.minShort)
    }

    func testExactProfileSize() {
        XCTAssertEqual(fit(1920, 1080), VideoGeometry.Size(width: 1920, height: 1080))
    }

    func testOversizedSameAspectFillsBox() {
        XCTAssertEqual(fit(3840, 2160), VideoGeometry.Size(width: 1920, height: 1080))
        XCTAssertEqual(fit(2560, 1440), VideoGeometry.Size(width: 1920, height: 1080))
    }

    /// Geniş aralıkta tarama: her boyut kutuda, çift ve oran hatası ≤ %1 (asgari dolgu durumu hariç).
    func testSweepAspectErrorBounded() {
        var worst = 0.0
        for w in stride(from: 1000.0, through: 4200.0, by: 137.0) {
            for h in stride(from: 800.0, through: 2600.0, by: 113.0) {
                let s = fit(w, h)
                assertSane(s)
                worst = max(worst, aspectError(s, w, h))
            }
        }
        XCTAssertLessThanOrEqual(worst, 0.01, "en kötü oran hatası \(worst)")
    }

    /// Asgariye yetişmeyen aşırı en-boy: çerçeve asgariye doldurulur (dolgu), içerik esnetilmez.
    func testExtremeAspectIsPaddedNotStretched() {
        let s = fit(3000, 100)
        assertSane(s)
        XCTAssertGreaterThanOrEqual(s.height, VideoGeometry.minShort)
        XCTAssertEqual(s.width, 1920, "içerik genişliği kutuyu doldurur: \(s)")
    }

    func testBoundsRespectSmallerProfileBox() {
        let s = VideoGeometry.encodeSize(pixelWidth: 2144, pixelHeight: 1888, boxWidth: 1280, boxHeight: 720)
        XCTAssertLessThanOrEqual(s.width, 1280)
        XCTAssertLessThanOrEqual(s.height, 720)
        XCTAssertLessThanOrEqual(abs(Double(s.width) / Double(s.height) - 2144.0 / 1888.0) / (2144.0 / 1888.0), 0.01)
    }
}
