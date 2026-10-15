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

    /// "Temizle": arayüz defterini boşaltır (ham günlük dosyasına dokunmaz).
    func clear() { rows.removeAll() }
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

    /// Yalnız sayı rengini nötrle; grafiğin kendi rengi kalıcıdır (ölçülen kusur:
    /// yayın durdurulunca tüm çizgiler griye dönüyordu ve grafikler anlamsızlaşıyordu).
    func resetValueColor() { valueLabel.textColor = .labelColor }

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
        // Yer daraldığında grafik çizgisini kaybetmektense sayıyı göster: iki satır sığmaz.
        spark.isHidden = bounds.width < 132 || bounds.height < 96
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
    let eventsButton = NSButton()
    /// Olaylar artık pano içinde açılmıyor: kullanıcı isteği üzerine ayrı bir ekran oluyor
    /// (panonun içindeki katlanır liste gerçek tıklamayla açılmıyordu).
    var onOpenEvents: (() -> Void)?

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
        // Çizgi rengi kutunun kimliğidir: mavi ölçü, yeşil akış, turuncu gecikme.
        tileFps.spark.lineColor = .systemBlue
        tileBitrate.spark.lineColor = .systemGreen
        tileLatency.spark.lineColor = .systemOrange
        tilePackets.spark.lineColor = .systemBlue
        tileHealth.spark.lineColor = .systemGreen
        tiles.forEach { addSubview($0) }

        summaryBar.wantsLayer = true
        summaryBar.layer?.cornerRadius = 9
        summaryLed.wantsLayer = true
        summaryLed.layer?.cornerRadius = 4
        summaryLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryBar.addSubview(summaryLed); summaryBar.addSubview(summaryLabel)
        addSubview(summaryBar)

        // Olaylar ayrı bir ekran: pano içindeki katlanır liste gerçek tıklamayla açılmıyordu
        // ve açılınca panonun yüksekliği yetmiyordu. Normal, kenarlıklı düğme = güvenilir tıklama.
        eventsButton.bezelStyle = .rounded
        eventsButton.setButtonType(.momentaryPushIn)
        eventsButton.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        eventsButton.target = self
        eventsButton.action = #selector(openEvents)
        eventsButton.setAccessibilityLabel("Olaylar")
        eventsButton.toolTip = "Aynı satırlar tek satırda toplanır; tam liste ayrı açılır."
        eventsButton.title = "Olaylar"
        addSubview(eventsButton)

        setSummary("Hazır — soldan pencere, sağdan TV seç.", .idle)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func openEvents() { onOpenEvents?() }

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
            $0.resetValueColor()
        }
        tileFps.resetChart(); tileBitrate.resetChart(); tileLatency.resetChart()
    }

    enum Summary { case idle, ok, warn, bad }

    /// Özet satırının metni ve tonu: olay ekranı üst bilgisi de buradan okur (tek kaynak).
    private(set) var summaryText = ""
    private(set) var summaryTone: Summary = .idle

    func setSummary(_ text: String, _ state: Summary) {
        summaryText = text
        summaryTone = state
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

    /// Düğme etiketi: grup/satır sayısı tek bakışta görünsün (liste ayrı ekranda).
    func reloadEvents(_ rows: [EventRow], groups: Int, lines: Int) {
        eventsButton.title = rows.isEmpty ? "Olaylar" : "Olaylar — \(groups) grup, \(lines) satır"
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
        let tileH = self.tileHeight
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
            contentBottom = top + CGFloat(tileRows) * (tileH + gap)
        }
        // Özet satırı ile "Olaylar" düğmesi alta yapışık tek sırada: pano büyüdükçe boşluk
        // birikmesin, ama kutularla da çakışmasın.
        let rowY = max(contentBottom + 8, bounds.height - 30)
        eventsButton.sizeToFit()
        let buttonW = max(160, eventsButton.frame.width + 26)
        eventsButton.frame = NSRect(x: width - buttonW, y: rowY, width: buttonW, height: 30)
        let barW = max(160, width - buttonW - 8)
        summaryBar.frame = NSRect(x: 0, y: rowY, width: barW, height: 30)
        summaryLed.frame = NSRect(x: 10, y: 11, width: 8, height: 8)
        summaryLabel.frame = NSRect(x: 26, y: 7, width: max(60, barW - 40), height: 16)
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

    /// Kısa panoda kutular alçalır (grafik çizgisi düşer) ki listeler okunaklı kalsın.
    var compactTiles = false {
        didSet { if compactTiles != oldValue { needsLayout = true } }
    }

    private var tileHeight: CGFloat { compactTiles ? Self.shortTileHeight : Self.tileHeight }

    /// Genişliğe göre ölçü kutusu sütun sayısı. Beş kutu ya tek satıra sığar ya 2-3 satıra
    /// dağılır; 4 sütun 5. kutuyu yapayalnız bırakıyordu.
    static func columns(for width: CGFloat) -> Int {
        switch width {
        case ..<620: return 2
        case ..<820: return 3
        default: return 5
        }
    }

    static let tileHeight: CGFloat = 104
    /// Grafik çizgisi düşürülmüş kutu: yer sıkışıkken sayı + yardımcı satır sığsın.
    static let shortTileHeight: CGFloat = 78
    static let chipRowHeight: CGFloat = 38
    static let summaryRowHeight: CGFloat = 38
    static let gap: CGFloat = 8

    /// Ölçü kutularının kaç satıra dizileceği.
    static func tileRows(forWidth width: CGFloat) -> Int {
        Int(ceil(5 / Double(columns(for: width))))
    }

    /// Panonun **ihtiyaç duyduğu** yükseklik: çip sırası + kutu satırları + özet/düğme sırası.
    /// `layoutBoard` liste boyunu buradan kalan yerden hesaplar; `tileH` alçalınca grafik çizgisi düşer,
    /// `tiles = 0` (katışık) yalnız çip + özet kalır.
    static func requiredHeight(width: CGFloat, tileH: CGFloat, tiles: Int) -> CGFloat {
        guard tiles > 0 else { return chipRowHeight + summaryRowHeight }
        let rows = Int(ceil(Double(tiles) / Double(max(1, columns(for: width)))))
        return chipRowHeight + CGFloat(rows) * (tileH + gap) + summaryRowHeight
    }

    /// Bu görünüme biçilmiş genişlikte gereken yükseklik (katışık/alkaçlı mod hesaba katılır).
    func neededHeight(forWidth width: CGFloat) -> CGFloat {
        let tileH = compactTiles ? Self.shortTileHeight : Self.tileHeight
        return Self.requiredHeight(width: width, tileH: tileH, tiles: compact ? 0 : tiles.count)
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

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    init(_ row: EventRow) {
        super.init(frame: .zero)
        led.wantsLayer = true
        led.layer?.backgroundColor = row.severity.color.cgColor
        led.layer?.cornerRadius = 3.5
        timeLabel.stringValue = Self.time.string(from: row.last)
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

/// Olay satırlarını taşıyan düz kap: yüksekliği satır sayısından, satır genişliği
/// kendi genişliğinden hesaplanır. (Denenen `NSStackView` + scroll kombinasyonu
/// satırları sıfır yükseklikte bırakıyordu.)
private final class EventRowStack: NSView {
    private var rows: [EventRowView] = []
    static let rowHeight: CGFloat = 22

    override var isFlipped: Bool { true }

    func rebuild(_ rows: [EventRowView]) {
        subviews.forEach { $0.removeFromSuperview() }
        self.rows = rows
        rows.forEach(addSubview)
        frame.size.height = CGFloat(rows.count) * Self.rowHeight
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 4, y: CGFloat(i) * Self.rowHeight,
                               width: max(120, bounds.width - 22), height: Self.rowHeight - 2)
        }
    }
}

/// Olay ekranı: üstte elzem özet (durum + sayaçlar), altta tam yükseklikte kaydırılabilir
/// liste. Pano içinde katlanır liste gerçek tıklamayla açılmıyordu ve açılınca sığmıyordu
/// — kullanıcı isteği üzerine ayrı ekran.
final class EventsPageView: NSView {
    let heading = NSTextField(labelWithString: "Olaylar")
    /// Elzem satır: rozetteki durumun tamamı (yayın/kanal/kayıp) — pano görünmeden de okunsun.
    let statusLine = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    private let statusLed = NSView()
    private let statusBox = NSView()
    let back = NSButton()
    let clear = NSButton()
    /// Ham günlük dosyası (satır satır, katlamasız) — arayüzdeki grupların kaynağı.
    let openLog = NSButton()
    private let scroll = NSScrollView()
    private let stack = EventRowStack()
    var onBack: (() -> Void)?
    var onClear: (() -> Void)?
    var onOpenLog: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        heading.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        statusLine.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        statusBox.wantsLayer = true
        statusBox.layer?.cornerRadius = 8
        statusBox.layer?.borderWidth = 1
        statusBox.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.14).cgColor
        statusBox.layer?.borderColor = NSColor.separatorColor.cgColor
        statusLed.wantsLayer = true
        statusLed.layer?.cornerRadius = 4
        statusLed.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        back.bezelStyle = .rounded
        back.title = "Geri"
        back.keyEquivalent = "\u{1b}"                       // Esc
        back.target = self
        back.action = #selector(pressBack)
        clear.bezelStyle = .rounded
        clear.title = "Temizle"
        clear.target = self
        clear.action = #selector(pressClear)
        openLog.bezelStyle = .rounded
        openLog.title = "Ham günlüğü aç"
        openLog.target = self
        openLog.action = #selector(pressOpenLog)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        scroll.documentView = stack
        [heading, back, clear, openLog, statusBox, statusLed, subtitle, scroll].forEach {
            addSubview($0)
        }
        // Durum yazısı kutunun İÇİNDE: ölçülen kusur, etiket sayfaya eklenince kutunun
        // üstüne (sayfanın en üstüne) düşüyor ve başlıkla çakışıyordu.
        statusBox.addSubview(statusLine)
        statusBox.addSubview(statusLed)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func pressBack() { onBack?() }
    @objc private func pressClear() { onClear?() }
    @objc private func pressOpenLog() { onOpenLog?() }

    /// `status` = elzem durum cümlesi, `counts` = grup/satır sayımı.
    /// `resetScroll` yalnız ekran ilk açıldığında true: yeni olay geldikçe kullanıcının
    /// kaydırdığı yer sıfırlanmasın.
    func show(rows: [EventRow], status: String, counts: String,
              tone: DashboardView.Summary = .idle, resetScroll: Bool = false) {
        stack.rebuild(rows.map { EventRowView($0) })
        statusLine.stringValue = status
        subtitle.stringValue = counts
        let color: NSColor
        switch tone {
        case .idle: color = .tertiaryLabelColor
        case .ok: color = .systemGreen
        case .warn: color = .systemOrange
        case .bad: color = .systemRed
        }
        statusLed.layer?.backgroundColor = color.cgColor
        statusLine.textColor = tone == .idle ? .labelColor : color
        needsLayout = true
        if resetScroll {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        back.sizeToFit(); clear.sizeToFit(); openLog.sizeToFit()
        let backW = max(84, back.frame.width + 24)
        let clearW = max(84, clear.frame.width + 24)
        let logW = max(120, openLog.frame.width + 24)
        back.frame = NSRect(x: w - backW - 12, y: 12, width: backW, height: 26)
        clear.frame = NSRect(x: back.frame.minX - clearW - 8, y: 12, width: clearW, height: 26)
        openLog.frame = NSRect(x: clear.frame.minX - logW - 8, y: 12, width: logW, height: 26)
        heading.frame = NSRect(x: 12, y: 12, width: max(80, openLog.frame.minX - 24), height: 22)
        statusBox.frame = NSRect(x: 12, y: 46, width: w - 24, height: 30)
        statusLed.frame = NSRect(x: 12, y: 11, width: 8, height: 8)
        statusLine.frame = NSRect(x: 28, y: 7, width: max(60, w - 52), height: 16)
        subtitle.frame = NSRect(x: 12, y: 82, width: w - 24, height: 15)
        let listY: CGFloat = 102
        scroll.frame = NSRect(x: 12, y: listY, width: w - 24, height: max(60, bounds.height - listY - 12))
        stack.frame = NSRect(x: 0, y: 0, width: max(120, scroll.contentSize.width),
                             height: stack.frame.height)
    }
}
