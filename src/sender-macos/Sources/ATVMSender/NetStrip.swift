import AppKit

/// Yayının ağ yükü şeridi: üç payda yan yana, hepsi **değer + yüzde + dolgu çubuğu**.
///
/// 1. Yayın (RTP)  → paydası Wi-Fi eşleşmiş hızı: yayın gerçekten bu havayolunu kullanıyor.
/// 2. Bu Mac'in kartı → paydası işletim sayacı: yayının Mac trafiğindeki payı.
/// 3. İnternet (modem) → UPnP sayacı: **yerel yayın buraya girmez**, bu yüzden ayrı satırda
///    ve ayrı etiketle durur; modem kapasiteyi ölçülen yükten küçük raporlarsa "tutarsız" yazılır.
@MainActor
final class NetStripView: NSView {
    struct Reading {
        var castMbps: Double?
        var wifiMbps: Double?
        var macIn: Double?
        var macOut: Double?
        var interface: String?
        var wanIn: Double?
        var wanOut: Double?
        var capDown: Double?
        var capUp: Double?
        var accessType: String = "-"
        var modemState: ModemLoad.State = .off
    }

    private let castCell = NetCell(captionKey: .netCellCast)
    private let macCell = NetCell(captionKey: .netCellMac)
    private let wanCell = NetCell(captionKey: .netCellWan)
    /// Modem yoklaması: kullanıcı isteğiyle varsayılan açık, tek dokunuşla kapanır.
    let modemToggle = NSButton(checkboxWithTitle: L10n.t(.netModemToggle), target: nil, action: nil)
    var onToggleModem: ((Bool) -> Void)?
    /// Son okuma: dil değişince payda yazıları anahtarlardan yeniden çözülür.
    private var lastReading: Reading?
    private var languageWatch: LanguageWatch?

    /// Şeridin toplam yüksekliği: üstte 18 px yoklama kutusu sırası, altta 60 px hücre.
    /// Ölçülen kusur: 64 px verilmişti, hücreler 46 px'e sıkışıp alt satırı kırpıyordu.
    static let height: CGFloat = 78
    static let toggleRow: CGFloat = 18

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        [castCell, macCell, wanCell, modemToggle].forEach(addSubview)
        modemToggle.state = .on
        modemToggle.target = self
        modemToggle.action = #selector(toggled)
        modemToggle.font = NSFont.systemFont(ofSize: 10.5)
        applyLanguage()
        languageWatch = LanguageWatch { [weak self] in self?.applyLanguage() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Hücre başlıkları + yoklama kutusu ve son okumanın payda satırları yeniden çözülür.
    func applyLanguage() {
        [castCell, macCell, wanCell].forEach { $0.applyLanguage() }
        modemToggle.title = L10n.t(.netModemToggle)
        modemToggle.toolTip = L10n.t(.netModemTooltip)
        if let lastReading { set(lastReading) }
        needsLayout = true
    }

    @objc private func toggled() { onToggleModem?(modemToggle.state == .on) }

    func set(_ r: Reading) {
        lastReading = r
        // 1) Yayın: Wi-Fi hava süresine göre.
        let castShare = NetMath.share(part: r.castMbps, of: r.wifiMbps)
        castCell.set(value: r.castMbps, unit: "Mbps",
                     percent: castShare,
                     denominator: r.wifiMbps.map { L10n.f(.netCastWifi, Self.number($0)) }
                        ?? L10n.t(.netCastWifiUnknown),
                     fill: castShare, loadMetric: true)

        // 2) Bu Mac'in kartı: yayının kart toplamındaki payı (bileşim, doluluk değil).
        let macTotal = NetMath.total(r.macIn, r.macOut)
        let macShare = NetMath.share(part: r.castMbps, of: macTotal)
        macCell.set(value: macTotal, unit: "Mbps",
                    percent: macShare,
                    denominator: L10n.f(.netMacTraffic, Self.number(r.macIn), Self.number(r.macOut),
                                                  r.interface ?? "?"),
                    fill: macShare, loadMetric: false)

        // 3) Modem/WAN: kapasite raporu ölçülenle çelişirse "tutarsız" denir, % uydurulmaz.
        let wanTotal = NetMath.total(r.wanIn, r.wanOut)
        let cap = NetMath.total(r.capDown, r.capUp)
        let inconsistent = wanTotal != nil && cap != nil && (wanTotal ?? 0) > cap! * 1.25
        let wanShare = inconsistent ? nil : NetMath.share(part: wanTotal, of: cap)
        switch r.modemState {
        case .off:
            wanCell.set(value: nil, unit: "Mbps", percent: nil,
                        denominator: L10n.t(.netWanProbeOff), fill: nil, loadMetric: true)
        case .searching:
            wanCell.set(value: nil, unit: "Mbps", percent: nil,
                        denominator: L10n.t(.netWanSearching), fill: nil, loadMetric: true)
        case .unreachable:
            wanCell.set(value: nil, unit: "Mbps", percent: nil,
                        denominator: L10n.t(.netWanNoAnswer), fill: nil, loadMetric: true)
        case .ready:
            let down = Self.number(r.capDown), up = Self.number(r.capUp)
            wanCell.set(value: wanTotal, unit: "Mbps", percent: wanShare,
                        denominator: inconsistent
                            ? L10n.f(.netWanInconsistent, down, up, r.accessType)
                            : L10n.f(.netWanCapacity, down, up, r.accessType),
                        fill: wanShare, loadMetric: true)
        }
        modemToggle.state = r.modemState == .off ? .off : .on
        needsLayout = true
    }

    static func number(_ v: Double?) -> String {
        guard let v else { return "—" }
        return L10n.number(v, digits: v >= 100 ? 0 : 1)
    }

    override func layout() {
        super.layout()
        modemToggle.sizeToFit()
        let toggleW = modemToggle.frame.width + 6
        modemToggle.frame = NSRect(x: bounds.maxX - toggleW, y: 0, width: toggleW, height: 16)
        let gap: CGFloat = 8
        let cells: CGFloat = 3
        let cellW = (bounds.width - gap * (cells - 1)) / cells
        let top = NetStripView.toggleRow
        let h = max(48, bounds.height - top)
        for (i, cell) in [castCell, macCell, wanCell].enumerated() {
            cell.frame = NSRect(x: bounds.minX + CGFloat(i) * (cellW + gap), y: top,
                                width: cellW, height: h)
        }
    }
}

/// Şeridin tek hücresi: başlık, büyük değer, sağda yüzde, altta paydanın adı ve dolgu çubuğu.
@MainActor
final class NetCell: NSView {
    private let caption = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "—")
    private let unit = NSTextField(labelWithString: "")
    private let percent = NSTextField(labelWithString: "")
    private let denominator = NSTextField(labelWithString: "")
    private let bar = NSView()
    private let fill = NSView()
    private var ratio: Double?
    private let captionKey: TextKey

    init(captionKey: TextKey) {
        self.captionKey = captionKey
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        caption.font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        value.font = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        unit.font = NSFont.systemFont(ofSize: 10)
        unit.textColor = .secondaryLabelColor
        percent.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        percent.alignment = .right
        denominator.font = NSFont.systemFont(ofSize: 9.5)
        denominator.textColor = .tertiaryLabelColor
        denominator.lineBreakMode = .byTruncatingTail
        bar.wantsLayer = true
        fill.wantsLayer = true
        bar.layer?.cornerRadius = 2
        fill.layer?.cornerRadius = 2
        [caption, value, unit, percent, denominator, bar, fill].forEach(addSubview)
        paint()
        applyLanguage()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func applyLanguage() {
        caption.stringValue = L10n.t(captionKey)
    }

    /// `loadMetric` true ise yüzde bir **doluluk** oranıdır (Wi-Fi/modem kapasitesi):
    /// eşiği aşınca turuncu/kırmızı boyanır. False ise oran bir bileşim ölçüsüdür
    /// ("Mac'in trafiğinin ne kadarı yayın") — yüksek olması arıza değil, uyarı rengi yalan söylemesin.
    func set(value: Double?, unit: String, percent: Double?, denominator: String,
             fill ratio: Double?, loadMetric: Bool) {
        self.value.stringValue = value.map { L10n.number($0, digits: $0 >= 100 ? 0 : 1) } ?? "—"
        self.unit.stringValue = value == nil ? "" : unit
        if let percent {
            self.percent.stringValue = L10n.percent(percent)
            self.percent.textColor = loadMetric
                ? (percent > 85 ? Theme.badText : (percent > 60 ? Theme.warnText : .secondaryLabelColor))
                : .secondaryLabelColor
        } else {
            self.percent.stringValue = "—"
            self.percent.textColor = .tertiaryLabelColor
        }
        self.denominator.stringValue = denominator
        self.ratio = ratio.map { min(1.0, max(0.0, $0 / 100)) }
        needsLayout = true
        needsDisplay = true
    }

    private func paint() {
        layer?.backgroundColor = Theme.card.cgColor
        layer?.borderColor = Theme.cardStroke.cgColor
        bar.layer?.backgroundColor = Theme.well.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        // Dolgu oranı tema bağlamında çizilir: koyu/açık geçişte renk çözülmüş kalmasın.
        guard let ratio else { return }
        let r = NSRect(x: bar.frame.minX, y: bar.frame.minY,
                       width: max(2, bar.frame.width * CGFloat(ratio)), height: bar.frame.height)
        let color = ratio > 0.85 ? NSColor.systemRed : (ratio > 0.6 ? NSColor.systemOrange : NSColor.controlAccentColor)
        color.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        caption.frame = NSRect(x: 8, y: 5, width: w - 16, height: 12)
        value.sizeToFit()
        value.frame = NSRect(x: 8, y: 19, width: value.frame.width + 2, height: 20)
        unit.frame = NSRect(x: value.frame.maxX + 3, y: 25, width: 34, height: 12)
        percent.frame = NSRect(x: w - 62, y: 22, width: 54, height: 15)
        denominator.frame = NSRect(x: 8, y: 42, width: w - 16, height: 11)
        bar.frame = NSRect(x: 8, y: bounds.height - 7, width: w - 16, height: 4)
        needsDisplay = true
    }
}
