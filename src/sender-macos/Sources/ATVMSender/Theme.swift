import AppKit

/// Açık/koyu tema renkleri.
///
/// AppKit'in etiket/ayıraç renkleri zaten görünüme göre çözünür, ama **CALayer zemini
/// çözülmüş `CGColor` tutar**: sistem teması değişince ya da süreç açık temada başlayınca
/// kartlar koyu temadaki renkle kalıyordu (ölçülen kusur: harita zemini açık temada beyaz
/// üstüne beyaz, kartlar ise içi geç görünür). Bu yüzden renkler `NSColor(name:dynamicProvider:)`
/// ile dinamik üretilir ve her katmanlı görünüm `viewDidChangeEffectiveAppearance` içinde
/// kendisini yeniden boyar.
enum Theme {
    /// Kart zemini: koyu temada yarı saydam açık gri, açık temada kâğıt gibi beyaz.
    static let card = NSColor(name: "panecast.card") { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.07) : NSColor.white
    }
    /// Kart kenarı: koyu temada ayıraç, açık temada tek kıl çizgi (beyaz kart ayırt edilsin).
    static let cardStroke = NSColor(name: "panecast.cardStroke") { appearance in
        appearance.isDark ? NSColor.separatorColor : NSColor.black.withAlphaComponent(0.10)
    }
    /// İçine gömülü alan (grafik zemini, ekran haritası): sayfadan bir ton içeri.
    static let well = NSColor(name: "panecast.well") { appearance in
        appearance.isDark ? NSColor.black.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.045)
    }
    /// Durum şeridi zemini: renk dolgusu açık temada biraz daha belirgin olsun.
    static func tintedFill(_ color: NSColor) -> NSColor {
        NSColor(name: "panecast.fill") { appearance in
            color.withAlphaComponent(appearance.isDark ? 0.16 : 0.14)
        }
    }
    /// Rozet/çip noktası zemini.
    static let chipFill = NSColor(name: "panecast.chip") { appearance in
        appearance.isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.035)
    }

    /// Beyaz yazı taşıyan durum dolguları: açık temada `systemGreen` beyaz 13 px yarı kalın
    /// yazıyla ~1,8:1 kalıyor (ekranda piksel örneklenerek ölçüldü). Yazı okunur olsun diye
    /// açık temada koyulaştırılır; koyu tema kullanıcıca onaylanmış canlı renklerde bırakıldı.
    static let goFill = NSColor(name: "panecast.go") { appearance in
        appearance.isDark ? .systemGreen : darker(.systemGreen, 0.28)
    }
    static let stopFill = NSColor(name: "panecast.stop") { appearance in
        appearance.isDark ? .systemRed : darker(.systemRed, 0.14)
    }

    /// Renkli **yazı** tonları: kart üstünde metin olarak kullanılıyorlar; açık temada
    /// `systemGreen` beyaz zeminde ~1,9:1 kalıyor (piksel örneklenerek ölçüldü), bu yüzden
    /// koyulaştırılır. Grafik çizgisi de aynı tonu alır — koyu çizgi beyazda daha okunur.
    static let okText = NSColor(name: "panecast.okText") { appearance in
        appearance.isDark ? .systemGreen : darker(.systemGreen, 0.34)
    }
    static let warnText = NSColor(name: "panecast.warnText") { appearance in
        appearance.isDark ? .systemOrange : darker(.systemOrange, 0.30)
    }
    static let badText = NSColor(name: "panecast.badText") { appearance in
        appearance.isDark ? .systemRed : darker(.systemRed, 0.18)
    }

    static func darker(_ color: NSColor, _ fraction: CGFloat) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        let k = 1 - fraction
        return NSColor(srgbRed: rgb.redComponent * k, green: rgb.greenComponent * k,
                       blue: rgb.blueComponent * k, alpha: rgb.alphaComponent)
    }

}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
