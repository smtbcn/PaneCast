import AppKit

/// Olay satırının ağırlığı: arayüzde renk noktası olarak görünür.
enum EventSeverity: Int, Comparable {
    case info, warn, error
    static func < (l: EventSeverity, r: EventSeverity) -> Bool { l.rawValue < r.rawValue }
    var color: NSColor {
        switch self {
        case .info: return .tertiaryLabelColor
        case .warn: return .systemOrange
        case .error: return .systemRed
        }
    }
}

/// Bir olay grubu: aynı metin tekrarlanırsa `count` artar, yeni satır açılmaz.
/// Ölçülen kusur: "keşif: 1 TV bulundu" satırı 20 saniyede bir ekleniyor ve arayüz
/// okunamayacak kadar metin duvarına dönüyordu.
struct EventRow {
    var severity: EventSeverity
    var text: String
    var count: Int
    var last: Date
}

/// Arayüzün olay defteri (ham günlük dosyaya aynen yazılmaya devam eder).
final class EventBook {
    private(set) var rows: [EventRow] = []
    private let limit: Int

    init(limit: Int = 40) { self.limit = limit }

    func add(_ text: String, _ severity: EventSeverity = .info) {
        if let i = rows.firstIndex(where: { $0.text == text }) {
            rows[i].count += 1
            rows[i].last = Date()
            rows[i].severity = max(rows[i].severity, severity)
            let moved = rows.remove(at: i)
            rows.insert(moved, at: 0)          // en son olan en üstte
        } else {
            rows.insert(EventRow(severity: severity, text: text, count: 1, last: Date()), at: 0)
            if rows.count > limit { rows.removeLast() }
        }
    }

    var groupCount: Int { rows.count }
    var lineCount: Int { rows.reduce(0) { $0 + $1.count } }
}

/// Son örnekleri normalize çizgi halinde gösteren mini grafik (Apple: "zamanla değişen süreç").
final class SparkView: NSView {
    private var samples: [Double] = []
    private let capacity = 60
    var lineColor: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var showsFill = true
    var emptyText = "veri bekleniyor"

    override var isFlipped: Bool { false }

    func push(_ v: Double) {
        samples.append(v)
        if samples.count > capacity { samples.removeFirst() }
        needsDisplay = true
    }

    func reset() { samples.removeAll(); needsDisplay = true }

    override func draw(_ dirty: NSRect) {
        guard samples.count > 1 else {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 0, y: bounds.midY))
            p.line(to: NSPoint(x: bounds.maxX, y: bounds.midY))
            p.lineWidth = 1
            p.stroke(with: .tertiaryLabelColor, width: 1)
            return
        }
        let lo = samples.min()!, hi = samples.max()!
        let span = max(hi - lo, 1e-6)
        let path = NSBezierPath()
        for (i, v) in samples.enumerated() {
            let x = bounds.width * CGFloat(i) / CGFloat(samples.count - 1)
            let y = bounds.minY + (bounds.height - 2) * CGFloat((v - lo) / span) + 1
            if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
        }
        if showsFill {
            let fill = path.copy() as! NSBezierPath
            fill.line(to: NSPoint(x: bounds.maxX, y: 0))
            fill.line(to: NSPoint(x: 0, y: 0))
            fill.close()
            lineColor.withAlphaComponent(0.16).setFill(); fill.fill()
        }
        path.stroke(with: lineColor, width: 1.7)
    }

    override func accessibilityLabel() -> String? {
        guard let last = samples.last else { return emptyText }
        return "\(samples.count) örnek, son değer \(String(format: "%.1f", last))"
    }
}

private extension NSBezierPath {
    func stroke(with color: NSColor, width: CGFloat) {
        lineWidth = width; color.setStroke(); stroke()
    }
}

/// Rozet noktası + anahtar + değer taşıyan durum çipi.
final class ChipView: NSView {
    enum State { case ok, warn, bad, idle }

    private let led = NSView()
    private let keyLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private var keyText = ""

    var state: State = .idle { didSet { tint() } }

    init(key: String) {
        super.init(frame: .zero)
        keyText = key
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        led.wantsLayer = true
        led.layer?.cornerRadius = 4
        keyLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.stringValue = key.uppercased()
        valueLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        valueLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(led); addSubview(keyLabel); addSubview(valueLabel)
        tint()
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ value: String, state: State? = nil) {
        valueLabel.stringValue = value
        if let state { self.state = state }
        invalidateIntrinsicContentSize()
    }

    private func tint() {
        let color: NSColor
        switch state {
        case .ok: color = .systemGreen
        case .warn: color = .systemOrange
        case .bad: color = .systemRed
        case .idle: color = .tertiaryLabelColor
        }
        led.layer?.backgroundColor = color.cgColor
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.10).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let keySize = keyLabel.intrinsicContentSize
        valueLabel.sizeToFit()
        let maxKeyX = bounds.width - 24
        keyLabel.frame = NSRect(x: 10, y: (bounds.height - keySize.height) / 2,
                                width: min(keySize.width, max(0, maxKeyX)), height: keySize.height)
        let valueWidth = max(30, bounds.maxX - keyLabel.frame.maxX - 22)
        valueLabel.frame = NSRect(x: keyLabel.frame.maxX + 6, y: (bounds.height - 15) / 2,
                                  width: valueWidth, height: 15)
        led.frame = NSRect(x: bounds.maxX - 14, y: bounds.midY - 4, width: 8, height: 8)
    }

    /// Çip genişliği içeriğe göre: metin kesilmesin, ama çok uzarsa pencereyi bozmasın.
    override var intrinsicContentSize: NSSize {
        valueLabel.sizeToFit()
        let w = 10 + keyLabel.intrinsicContentSize.width + 6 + ceil(valueLabel.intrinsicContentSize.width)
            + 8 + 14 + 10
        return NSSize(width: min(max(w, 90), 420), height: 24)
    }
}

/// Ad + büyük sayı + yardımcı metin + mini grafik.
final class MetricTile: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let valueLabel = NSTextField(labelWithString: "—")
    let unitLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let spark = SparkView()

    init(title: String, hint: String = "") {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        titleLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.stringValue = title.uppercased()
        valueLabel.font = NSFont.systemFont(ofSize: 21, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 21, weight: .semibold)
        unitLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        unitLabel.textColor = .secondaryLabelColor
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.stringValue = hint
        [titleLabel, valueLabel, unitLabel, detailLabel, spark].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ value: String, unit: String = "", detail: String? = nil) {
        valueLabel.stringValue = value
        unitLabel.stringValue = unit
        if let detail { detailLabel.stringValue = detail }
        needsLayout = true
    }

    /// Renk, eşik aşılınca metnin kendisini de boyar: sayıya bakmadan anlaşılsın.
    func tint(_ color: NSColor) {
        valueLabel.textColor = color
        spark.lineColor = color
    }

    /// Grafik örneği ekle (kutunun grafiği varsa).
    func push(_ v: Double) { spark.push(v) }
    func resetChart() { spark.reset() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 10, y: 8, width: bounds.width - 20, height: 13)
        valueLabel.sizeToFit()
        valueLabel.frame = NSRect(x: 10, y: 24, width: valueLabel.frame.width + 2, height: 26)
        unitLabel.frame = NSRect(x: valueLabel.frame.maxX + 3, y: 33,
                                 width: max(20, bounds.maxX - valueLabel.frame.maxX - 14), height: 14)
        // Dar kutuda grafik çizgisini kaybetmektense sayıyı göster: yardımcı satır üstüne çıkar.
        spark.isHidden = bounds.width < 132
        detailLabel.frame = NSRect(x: 10, y: 54, width: bounds.width - 20, height: 13)
        if !spark.isHidden {
            spark.frame = NSRect(x: 10, y: 70, width: bounds.width - 20, height: max(18, bounds.height - 78))
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 104) }
}

/// Pano: durum çipleri + ölçü kutuları + tek satır özet + katlanmış olaylar.
/// `layout()` genişliğe göre sütun sayısını yeniden hesaplar (responsive).
final class DashboardView: NSView {
    private let chips = NSStackView()
    private var tiles: [MetricTile] = []
    private let summaryBar = NSView()
    private let summaryLed = NSView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let toggle = NSButton()
    /// Olay satırları: kaydırma yerine panonun kalan yüksekliğine sığan kadarı elle dizilir.
    /// Ölçülen kusur: scroll içinde Auto Layout'lu NSStackView, satırları sıfır yükseklikte
    /// bırakıp listeyi görünmez yapıyordu.
    private var rowViews: [EventRowView] = []
    private var pendingRows: [EventRow] = []
    private let rowHeight: CGFloat = 18
    private var feedExpanded = false

    let chipSource = ChipView(key: "Kaynak")
    let chipTarget = ChipView(key: "Hedef")
    let chipChannel = ChipView(key: "Kanal")
    let chipDiscovery = ChipView(key: "Keşif")

    private(set) lazy var tileFps = MetricTile(title: "Kare hızı", hint: "hedef 60")
    private(set) lazy var tileBitrate = MetricTile(title: "Bit hızı", hint: "anlık")
    private(set) lazy var tileLatency = MetricTile(title: "Kodlama gecikmesi", hint: "p50 / p95")
    private(set) lazy var tilePackets = MetricTile(title: "Paketler", hint: "video / ses")
    private(set) lazy var tileHealth = MetricTile(title: "Ağ sağlığı", hint: "kayıp · yedekleme")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chips.orientation = .horizontal
        chips.spacing = 8
        chips.alignment = .centerY
        chips.distribution = .fill
        [chipSource, chipTarget, chipChannel, chipDiscovery].forEach { chips.addArrangedSubview($0) }
        addSubview(chips)

        tiles = [tileFps, tileBitrate, tileLatency, tilePackets, tileHealth]
        tiles.forEach { addSubview($0) }

        summaryBar.wantsLayer = true
        summaryBar.layer?.cornerRadius = 9
        summaryLed.wantsLayer = true
        summaryLed.layer?.cornerRadius = 4
        summaryLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryBar.addSubview(summaryLed); summaryBar.addSubview(summaryLabel)
        addSubview(summaryBar)

        // Ölçülen kusur: `.disclosure` bezelli kenarlıksız düğme görünüyordu ama erişilebilirlik
        // ağacında düğme olarak çıkmıyordu ve denenen tıklamalar eylemi tetiklemedi.
        // SF Symbol ok + başlık olan normal bir düğme: tıklama alanı tüm satır, VoiceOver okur.
        toggle.isBordered = false
        toggle.bezelStyle = .regularSquare
        toggle.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        toggle.contentTintColor = .secondaryLabelColor
        toggle.target = self
        toggle.action = #selector(toggleFeed)
        toggle.setAccessibilityLabel("Olaylar")
        toggle.imagePosition = .imageLeading
        toggle.toolTip = "Aynı satırlar tek satırda toplanır; tıklayınca ayrıntı listesi açılır."
        setChevron()
        addSubview(toggle)

        setSummary("Hazır — soldan pencere, sağdan TV seç.", .idle)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func toggleFeed() {
        feedExpanded.toggle()
        // Satırlar ancak açıldığında kurulur (kapalıyken boşuna görünüm üretme).
        reloadEvents(pendingRows, groups: pendingRows.count,
                     lines: pendingRows.reduce(0) { $0 + $1.count })
        setChevron()
        // Üst görünüm yeniden dizilsin: açıkken pano daha çok yükseklik ister.
        superview?.needsLayout = true
        needsLayout = true
    }

    /// Olay listesi açıkken panonun ek ihtiyacı — `layoutContent` pencere payını buna göre verir.
    var expandedHeight: CGFloat { feedExpanded ? CGFloat(min(pendingRows.count, 8)) * 18 + 6 : 0 }

    /// Ok işareti: kapalıyken sağa, açıkken aşağı bakar (macOS disclosure dili).
    private func setChevron() {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        toggle.image = NSImage(systemSymbolName: feedExpanded ? "chevron.down" : "chevron.right",
                               accessibilityDescription: feedExpanded ? "olayları katla" : "olayları genişlet")?
            .withSymbolConfiguration(config)
    }

    func setStats(_ s: MirrorEngine.Stats) {
        tileFps.set(String(format: "%.1f", s.fps), unit: "fps",
                    detail: "\(Int(s.seconds)) sn ortalaması")
        tileFps.push(s.fps)
        tileBitrate.set(String(format: "%.1f", s.mbps), unit: "Mbps", detail: "kodlayıcı çıkışı")
        tileBitrate.push(s.mbps)
        tileLatency.set(String(format: "%.1f", s.encodeP50), unit: "ms",
                        detail: "p95 \(String(format: "%.1f", s.encodeP95)) ms · yakalama \(String(format: "%.1f", s.captureP50)) ms")
        tileLatency.push(s.encodeP50)
        tilePackets.set(Self.grouped(s.packets), unit: "RTP",
                        detail: "ses \(Self.grouped(s.audioPackets)) paket · \(Int(s.seconds)) sn")
        let trouble = s.nackRequests + s.dropped
        tileHealth.set(trouble == 0 ? "Kayıp yok" : "\(trouble) olay", unit: "",
                       detail: "NACK \(s.nackRequests) · yedek \(s.retransmitted) · düşen \(s.dropped)")
        // Sağlık **yalnız kayıptan** hesaplanır: hareketsiz pencerede SCK kare göndermez,
        // düşük fps tek başına arıza değildir (ölçüldü: duran pencerede 0,6 fps, kayıp 0).
        tileHealth.tint(trouble == 0 ? .systemGreen : .systemOrange)
        needsLayout = true
    }

    static func grouped(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }

    /// Yayın durduğunda kutular "veri bekleniyor" haline döner — sıfır değeriyle yalan söylemesin.
    /// Özet satırına dokunmaz: ölçülen kusur, kırmızı hata mesajının bir sonraki 20 sn'lik
    /// yenilemede kendiliğinden kaybolmasıydı (sebep kullanıcıya görünmez kalıyordu).
    func clearStats() {
        [tileFps, tileBitrate, tileLatency, tilePackets, tileHealth].forEach {
            $0.set("—", unit: "", detail: "yayın yok")
            $0.tint(.labelColor)
        }
        tileFps.resetChart(); tileBitrate.resetChart(); tileLatency.resetChart()
    }

    enum Summary { case idle, ok, warn, bad }

    func setSummary(_ text: String, _ state: Summary) {
        summaryLabel.stringValue = text
        let bg: NSColor
        let led: NSColor
        switch state {
        case .idle: bg = .quaternaryLabelColor; led = .tertiaryLabelColor
        case .ok: bg = .systemGreen; led = .systemGreen
        case .warn: bg = .systemOrange; led = .systemOrange
        case .bad: bg = .systemRed; led = .systemRed
        }
        summaryBar.layer?.backgroundColor = bg.withAlphaComponent(state == .idle ? 0.14 : 0.16).cgColor
        summaryBar.layer?.borderColor = bg.withAlphaComponent(0.45).cgColor
        summaryBar.layer?.borderWidth = 1
        summaryLed.layer?.backgroundColor = led.cgColor
        summaryLed.layer?.cornerRadius = 4
    }

    private static let rowTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Olay listesini yeniden kurar. Satırlar yalnız açıkken eklenir; kapalıyken veri
    /// bekletilir (`pendingRows`) ki açınca anında görünsün.
    func reloadEvents(_ rows: [EventRow], groups: Int, lines: Int) {
        toggle.title = rows.isEmpty ? "Olaylar" : "Olaylar — \(groups) grup, \(lines) satır"
        setChevron()
        pendingRows = rows
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = feedExpanded ? rows.map { EventRowView($0, time: Self.rowTime) } : []
        rowViews.forEach { addSubview($0) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        chips.layout()
        var chipY: CGFloat = 6
        var x: CGFloat = 0
        let chipHeight: CGFloat = 24
        // Çipler satıra dizilir, sığmayanı alt satıra iner (küçük pencerede iki satır olur).
        for chip in chips.arrangedSubviews {
            var size = chip.intrinsicContentSize
            size.width = min(size.width, width)
            if x + size.width > width, x > 0 { x = 0; chipY += chipHeight + 6 }
            chip.frame = NSRect(x: x, y: chipY, width: size.width, height: chipHeight)
            x += size.width + 8
        }
        chips.frame = NSRect(x: 0, y: 0, width: width, height: chipY + chipHeight)

        let columns = Self.columns(for: width)
        let gap: CGFloat = 8
        let tileH = Self.tileHeight(for: bounds.height)
        let top = chips.frame.maxY + 8
        var contentBottom = top
        if !compact {
            let tileW = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            for (i, tile) in tiles.enumerated() {
                let row = i / columns, col = i % columns
                tile.frame = NSRect(x: CGFloat(col) * (tileW + gap), y: top + CGFloat(row) * (tileH + gap),
                                    width: tileW, height: tileH)
            }
            let tileRows = Int(ceil(Double(tiles.count) / Double(columns)))
            contentBottom = top + CGFloat(tileRows) * (tileH + gap) + 2
        }
        let summaryY = contentBottom
        summaryBar.frame = NSRect(x: 0, y: summaryY, width: width, height: 30)
        summaryLed.frame = NSRect(x: 10, y: 11, width: 8, height: 8)
        summaryLabel.frame = NSRect(x: 26, y: 7, width: width - 40, height: 16)
        toggle.sizeToFit()
        toggle.frame = NSRect(x: 0, y: summaryBar.frame.maxY + 6,
                              width: max(150, toggle.frame.width + 46), height: 18)
        // Satırlar panonun kalan yüksekliğine sığan kadarıyla dizilir.
        var y = toggle.frame.maxY + 2
        for row in rowViews {
            if y + rowHeight > bounds.maxY { row.isHidden = true; continue }
            row.isHidden = false
            row.frame = NSRect(x: 2, y: y, width: width - 4, height: rowHeight - 2)
            y += rowHeight
        }
    }

    /// Dar pencerede ölçü kutuları kalkar: çipler + özet + olaylar kalır.
    /// Sınır koymak, her şeyi sıkıştırıp okunamaz yapmaktan iyidir (kullanıcı isteği: "sınırlarımız olsun").
    var compact = false {
        didSet {
            guard compact != oldValue else { return }
            tiles.forEach { $0.isHidden = compact }
            needsLayout = true
        }
    }

    /// Genişliğe göre ölçü kutusu sütun sayısı.
    static func columns(for width: CGFloat) -> Int {
        switch width {
        case ..<620: return 2
        case ..<900: return 3
        case ..<1150: return 4
        default: return 5
        }
    }

    /// Kutu yüksekliği: yer sıkıysa grafik çizgisinden vazgeçip sayı satırına iner.
    static func tileHeight(for boxHeight: CGFloat) -> CGFloat { boxHeight < 300 ? 74 : 104 }

    /// Verilen genişlikte panonun ihtiyacı olan yükseklik — pencere kırpılmasın diye
    /// `layoutContent` bunu sorar (ölçüldü: 760×560'ta son kutu satırı görünmüyordu).
    /// Yer yoksa kutular zaten kendi `layout()` içinde alçak düzene düşer; burası üst sınırı verir.
    func neededHeight(forWidth width: CGFloat) -> CGFloat {
        if compact { return 14 + 30 + 32 + 20 + 14 }
        let columns = Self.columns(for: width)
        let rows = Int(ceil(Double(tiles.count) / Double(columns)))
        // 6 üst boşluk + 8 çip satırı + kutu araları + özet + olay satırı + 14 tampon:
        // ölçüldü, tam sığdırılan yükseklikte "Olaylar" satırı kesiliyordu.
        return 14 + 30 + CGFloat(rows) * (104 + 8) + 32 + 20 + 14
    }
}

/// Tek olay satırı: renk noktası + saat + metin + tekrar sayacı. Kendi `layout()`'u ile
/// genişliğe uyum sağlar (ölçülen kusur: iç içe Auto Layout stack'leri satırları
/// görünmez kılıyordu).
final class EventRowView: NSView {
    private let led = NSView()
    private let timeLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    init(_ row: EventRow, time: DateFormatter) {
        super.init(frame: .zero)
        led.wantsLayer = true
        led.layer?.backgroundColor = row.severity.color.cgColor
        led.layer?.cornerRadius = 3.5
        timeLabel.stringValue = time.string(from: row.last)
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        timeLabel.textColor = .tertiaryLabelColor
        textLabel.stringValue = row.text
        textLabel.font = NSFont.systemFont(ofSize: 11.5)
        textLabel.textColor = row.severity == .info ? .secondaryLabelColor : .labelColor
        textLabel.lineBreakMode = .byTruncatingMiddle
        countLabel.stringValue = row.count > 1 ? "×\(row.count)" : ""
        countLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        countLabel.textColor = .tertiaryLabelColor
        [led, timeLabel, textLabel, countLabel].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityLabel(row.count > 1 ? "\(row.text), \(row.count) kez" : row.text)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        led.frame = NSRect(x: 0, y: (bounds.height - 7) / 2, width: 7, height: 7)
        timeLabel.frame = NSRect(x: 12, y: (bounds.height - 13) / 2, width: 36, height: 13)
        countLabel.sizeToFit()
        let countWidth = countLabel.frame.width
        let countX = bounds.maxX - countWidth - 2
        textLabel.frame = NSRect(x: 52, y: (bounds.height - 15) / 2,
                                 width: max(40, countX - 58), height: 15)
        countLabel.frame = NSRect(x: countX, y: (bounds.height - countLabel.frame.height) / 2,
                                  width: countWidth, height: countLabel.frame.height)
    }
}
