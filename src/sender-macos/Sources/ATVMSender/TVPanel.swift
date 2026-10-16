import AppKit

/// TV ekranı modunun sol sütunu: boş açıklama alanı yerine, modun gerçekten ne yaptığını
/// gösteren panel — ekranların gerçek diziliminin haritası + altında kısa metin.
///
/// Ölçülen kusur: "TV ekranı" seçilince sol sütunda yalnız düz metin blokları duruyordu,
/// "Ekranları Düzenle…" düğmesi araç sırasından bağımsız konumlandığı için kayık kalıyordu ve
/// alan boş görünüyordu. Düğme artık arama sırasıyla aynı satırda (App.swift), panel ise
/// pencere listesiyle **çerçeveçe aynı** boyutu kaplar (üst/alt kenar her boyutta hizalı).
@MainActor
final class TVScreenPanelView: NSView {
    let title = NSTextField(labelWithString: L10n.t(.tvPanelTitle))
    let map = ScreenMapView()
    let body = NSTextField(wrappingLabelWithString: "")
    let screens = NSTextField(wrappingLabelWithString: "")
    private var languageWatch: LanguageWatch?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        paint()

        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        body.font = NSFont.systemFont(ofSize: 11.5)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 4
        screens.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        screens.textColor = .secondaryLabelColor
        screens.maximumNumberOfLines = 6

        [title, map, body, screens].forEach(addSubview)
        applyLanguage()
        languageWatch = LanguageWatch { [weak self] in self?.applyLanguage() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Başlık ve açıklama bloğu görünen dilde; ekran dökümü (`screens`) sayısal, dil gerektirmez.
    func applyLanguage() {
        title.stringValue = L10n.t(.tvPanelTitle)
        body.stringValue = L10n.t(.tvPanelBody)
        needsLayout = true
    }

    /// Kart zemini/kenarı: tema değişince yeniden çözülür.
    private func paint() {
        layer?.backgroundColor = Theme.card.cgColor
        layer?.borderColor = Theme.cardStroke.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { paint() }
    }

    /// Ekran dizilimi değişince harita ve altındaki metin yenilenir.
    func setScreens(_ items: [ScreenLayout.Screen], tvName: String) {
        map.set(items, tvName: tvName)
        screens.stringValue = ScreenLayout.describe(items, tvName: tvName)
        needsLayout = true
    }

    /// Küçük pencerede panel kendi içinde kısalır: önce altındaki metin dökümü, sonra
    /// açıklama gider; harita (modun asıl cevabı) her zaman kalır.
    /// Ölçülen kusur: sabit yüksekliklerle 170 px'lik listede metinler üst üste biniyordu.
    override func layout() {
        super.layout()
        let pad: CGFloat = 14
        let w = bounds.width, h = bounds.height
        title.frame = NSRect(x: pad, y: pad, width: w - 2 * pad, height: 18)
        var y = pad + 18 + 8
        let showBody = h >= 200
        body.isHidden = !showBody
        if showBody {
            body.frame = NSRect(x: pad, y: y, width: w - 2 * pad, height: 48)
            y += 48 + 10
        }
        let screensH: CGFloat = 62
        let showScreens = h - y - screensH >= 90
        screens.isHidden = !showScreens
        let mapBottom = (showScreens ? h - screensH - pad : h - pad) - 10
        map.frame = NSRect(x: pad, y: y, width: w - 2 * pad, height: max(60, mapBottom - y))
        if showScreens {
            screens.frame = NSRect(x: pad, y: h - screensH - pad, width: w - 2 * pad, height: screensH)
        }
    }
}

/// Ekranların gerçek konum/oran küçültülmüş çizimi: kullanıcı "TV ekranı sağda mı solda mı"
/// tahmin etmesin. macOS ekran koordinatı sol-alt kökenlidir; çizimde yatay eksen korunur,
/// dikey ters çevrilir ki üstteki ekran üstte görünsün.
@MainActor
final class ScreenMapView: NSView {
    private struct Item {
        let name: String
        let frame: CGRect
        let isTV: Bool
    }

    private var items: [Item] = []
    /// Çizimdeki tek yazı TV etiketi ("· TV") olduğu için dil geçişi yalnız yeniden çizim ister.
    private var languageWatch: LanguageWatch?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        paint()
        languageWatch = LanguageWatch { [weak self] in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Gömülü alan zemini: açık temada beyaz üstüne beyaz kalmasın.
    private func paint() {
        layer?.backgroundColor = Theme.well.cgColor
    }

    /// Çizimler görünüme göre renk çözer: tema değişince yeniden çiz.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            paint()
            needsDisplay = true
        }
    }

    /// Çizim matematiği üstten hesaplı (y aşağı büyür): panelin geri kalanıyla aynı yönde olsun.
    /// Ölçülen kusur: `isFlipped` ezilmezse ekranlar dikeyde ayna görüntüsü diziliyor,
    /// "TV ekranı sağda mı solda mı" sorusunun cevabı yanlış okunuyordu.
    override var isFlipped: Bool { true }

    func set(_ screens: [ScreenLayout.Screen], tvName: String) {
        items = screens.map { Item(name: $0.name, frame: $0.frame, isTV: $0.name == tvName) }
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        let inset = bounds.insetBy(dx: 12, dy: 16)
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9),
                                                  .foregroundColor: NSColor.tertiaryLabelColor]
        guard !items.isEmpty else {
            L10n.t(.tvPanelNoScreens).draw(at: NSPoint(x: inset.minX, y: inset.midY),
                                           withAttributes: dim)
            return
        }

        var minX = items[0].frame.minX, maxX = items[0].frame.maxX
        var minY = items[0].frame.minY, maxY = items[0].frame.maxY
        for s in items {
            minX = min(minX, s.frame.minX); maxX = max(maxX, s.frame.maxX)
            minY = min(minY, s.frame.minY); maxY = max(maxY, s.frame.maxY)
        }
        let spanW = max(1, maxX - minX), spanH = max(1, maxY - minY)
        let scale = min(inset.width / spanW, inset.height / spanH)
        let ox = inset.midX - spanW * scale / 2
        let oy = inset.midY - spanH * scale / 2

        for s in items {
            let x = ox + (s.frame.minX - minX) * scale
            let y = oy + (maxY - s.frame.maxY) * scale
            let rect = NSRect(x: x, y: y, width: s.frame.width * scale, height: s.frame.height * scale)
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            // Dolgu ve kenar iki temada da seçilsin: açık temada %10 `secondaryLabelColor`
            // dolgusu gömülü alanın içinde görünmez kalıyordu.
            (s.isTV ? NSColor.controlAccentColor.withAlphaComponent(0.30)
                    : NSColor.tertiaryLabelColor).setFill()
            path.fill()
            (s.isTV ? NSColor.controlAccentColor
                    : NSColor.secondaryLabelColor.withAlphaComponent(0.55)).setStroke()
            path.lineWidth = s.isTV ? 2 : 1
            path.stroke()

            let name = shortName(s.isTV ? L10n.f(.tvPanelMapTvName, s.name) : s.name)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: s.isTV ? .semibold : .regular),
                .foregroundColor: s.isTV ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
            ]
            let size = name.size(withAttributes: attrs)
            if rect.width > size.width + 6 {
                name.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                          withAttributes: attrs)
            } else {
                name.draw(in: NSRect(x: rect.minX, y: rect.maxY + 2,
                                     width: rect.width + 90, height: size.height + 2),
                          withAttributes: attrs)
            }
            let d = "\(Int(s.frame.width))×\(Int(s.frame.height))"
            d.draw(at: NSPoint(x: rect.midX - d.size(withAttributes: dim).width / 2,
                               y: max(inset.minY, rect.minY - 13)), withAttributes: dim)
        }
    }

    private func shortName(_ s: String) -> String {
        s.count > 20 ? String(s.prefix(19)) + "…" : s
    }

    override func accessibilityLabel() -> String? {
        items.map {
            "\($0.name) \(Int($0.frame.width))×\(Int($0.frame.height))"
                + ($0.isTV ? L10n.t(.tvPanelMapTvSuffix) : "")
        }.joined(separator: " · ")
    }
}
