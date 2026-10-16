import AppKit

/// Olay satırının ağırlığı: arayüzde renk noktası olarak görünür.
enum EventSeverity: Int, Comparable {
    case info, warn, error
    static func < (l: EventSeverity, r: EventSeverity) -> Bool { l.rawValue < r.rawValue }
    var color: NSColor {
        switch self {
        case .info: return .tertiaryLabelColor
        // Tema tonları: açık temada saf systemOrange/systemRed noktası beyaz kartta kayboluyor.
        case .warn: return Theme.warnText
        case .error: return Theme.badText
        }
    }
}

/// Bir olay grubu: aynı metin tekrarlanırsa `count` artar, yeni satır açılmaz.
/// Ölçülen kusur: "keşif: 1 TV bulundu" satırı 20 saniyede bir ekleniyor ve arayüz
/// okunamayacak kadar metin duvarına dönüyordu.
///
/// Satır çevrilebilir olsun diye **anahtar + biçim ögeleri** de taşınıyor (`key`/`args`).
/// Anahtarsız satırlar (işletimden gelen hata yazısı, TV'den gelen gerekçe) tek dildedir ve
/// dil değişince olduğu gibi kalır — uydurma çevirme yapılmaz.
struct EventRow {
    var severity: EventSeverity
    var text: String
    var key: TextKey?
    var args: [any CVarArg]
    var count: Int
    var last: Date

    /// Görünen yazı: anahtar varsa **şu anki** dilde çözülür.
    var rendered: String {
        guard let key else { return text }
        return L10n.f(key, args)
    }

    /// Gruplama izi: aynı anahtar **ve aynı ögeler** = aynı satır. Ögeler dile göre
    /// çözülmez; yoksa "keşif: 1 TV" ile "keşif: 2 TV" tek satırda birleşirdi.
    var identity: String {
        guard let key else { return text }
        return ([key.rawValue] + args.map { String(describing: $0) }).joined(separator: "\u{1}")
    }
}

/// Arayüzün olay defteri (ham günlük dosyaya aynen yazılmaya devam eder).
final class EventBook {
    private(set) var rows: [EventRow] = []
    private let limit: Int

    init(limit: Int = 40) { self.limit = limit }

    /// Çevrilebilir satır: anahtar + ögeler saklanır, görünen yazı dilden çözülür.
    func add(_ key: TextKey, _ args: [any CVarArg] = [], _ severity: EventSeverity = .info) {
        let row = EventRow(severity: severity, text: L10n.f(key, args), key: key, args: args,
                           count: 1, last: Date())
        merge(row)
    }

    /// Serbest yazı (işletim/TV metni): çevrilmez, olduğu gibi gösterilir.
    func add(_ text: String, _ severity: EventSeverity = .info) {
        merge(EventRow(severity: severity, text: text, key: nil, args: [], count: 1, last: Date()))
    }

    private func merge(_ row: EventRow) {
        if let i = rows.firstIndex(where: { $0.identity == row.identity }) {
            rows[i].count += 1
            rows[i].last = Date()
            rows[i].severity = max(rows[i].severity, row.severity)
            let moved = rows.remove(at: i)
            rows.insert(moved, at: 0)          // en son olan en üstte
        } else {
            rows.insert(row, at: 0)
            if rows.count > limit { rows.removeLast() }
        }
    }

    var groupCount: Int { rows.count }
    var lineCount: Int { rows.reduce(0) { $0 + $1.count } }

    /// Dil değişince yazıları yeniden çözer (anahtarsız satırlar olduğu gibi kalır).
    func rerender() {
        for i in rows.indices { rows[i].text = rows[i].rendered }
    }

    /// "Temizle": arayüz defterini boşaltır (ham günlük dosyasına dokunmaz).
    func clear() { rows.removeAll() }
}

/// Son örnekleri normalize çizgi halinde gösteren mini grafik (Apple: "zamanla değişen süreç").
final class SparkView: NSView {
    private var samples: [Double] = []
    private let capacity = 60
    var lineColor: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var showsFill = true
    /// Boş grafığın erişilebilir adı — anahtar olarak durur, dil değişince yeniden çözülür.
    var emptyKey: TextKey = .sparkWaiting

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
        guard let last = samples.last else { return L10n.t(emptyKey) }
        return L10n.f(.sparkAccessibility, String(samples.count), String(format: "%.1f", last))
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
    private let key: TextKey
    private var languageWatch: LanguageWatch?

    var state: State = .idle { didSet { tint() } }

    init(key: TextKey) {
        self.key = key
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        led.wantsLayer = true
        led.layer?.cornerRadius = 4
        keyLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        keyLabel.textColor = .secondaryLabelColor
        valueLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        valueLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(led); addSubview(keyLabel); addSubview(valueLabel)
        applyLanguage()
        tint()
        languageWatch = LanguageWatch { [weak self] in self?.applyLanguage() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Çip başlığı büyük harf ve yerel: "KEŞİF" doğru, `uppercased()` "KEŞIF" üretirdi.
    func applyLanguage() {
        keyLabel.stringValue = L10n.caps(key)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

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
        layer?.backgroundColor = Theme.chipFill.cgColor
        layer?.borderColor = Theme.cardStroke.cgColor
    }

    /// Katman zemini çözülmüş `CGColor` tutar: sistem teması değişince kendiliğinden gelmez.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { tint() }
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
    /// Genişlik **yazıdan** ölçülür, etiketin `intrinsicContentSize`'ından değil: o ölçüm
    /// değer değiştiğinde henüz tazelenmemiş olabiliyor ve çip 90 px'lik tabana düşüp
    /// "1 TV · 1 eşleşmiş" yazısını "1…iş"e kırpıyordu (ölçüldü: kurulu 0.2.12'de KEŞİF çipi).
    override var intrinsicContentSize: NSSize {
        func width(_ label: NSTextField) -> CGFloat {
            ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font as Any]).width)
        }
        let w = 10 + width(keyLabel) + 6 + width(valueLabel) + 8 + 14 + 10
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

    private let titleKey: TextKey
    /// Ölçüm gelmeden önceki yardım satırı; `detailKey` nil iken bu görünür.
    private let hintKey: TextKey
    /// Son yardımcı satırın kaynağı: dil değişince ögelerle yeniden çözülür.
    private var detailKey: TextKey?
    private var detailArgs: [any CVarArg] = []
    private var valueKey: TextKey?
    private var valueArgs: [any CVarArg] = []
    private var languageWatch: LanguageWatch?

    init(title: TextKey, hint: TextKey) {
        self.titleKey = title
        self.hintKey = hint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        paint()
        titleLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        valueLabel.font = NSFont.systemFont(ofSize: 21, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 21, weight: .semibold)
        unitLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        unitLabel.textColor = .secondaryLabelColor
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .tertiaryLabelColor
        [titleLabel, valueLabel, unitLabel, detailLabel, spark].forEach(addSubview)
        applyLanguage()
        languageWatch = LanguageWatch { [weak self] in self?.applyLanguage() }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Başlık + sayı + yardımcı satır dile bağlı; birimler ("fps", "Mbps", "ms") değil.
    func applyLanguage() {
        titleLabel.stringValue = L10n.caps(titleKey)
        if let valueKey { valueLabel.stringValue = L10n.f(valueKey, valueArgs) }
        detailLabel.stringValue = detailKey.map { L10n.f($0, detailArgs) } ?? L10n.t(hintKey)
        needsLayout = true
    }

    /// Kart zemini + kenarı; tema değişince yeniden çağrılır.
    private func paint() {
        layer?.backgroundColor = Theme.card.cgColor
        layer?.borderColor = Theme.cardStroke.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { paint() }
    }

    /// Dil değişince yeniden çözülebilmesi için yazı **anahtar + öge** olarak saklanır.
    /// Sayı gibi dilden bağımsız değerler düz `String` gelir (`valueKey` nil kalır).
    func set(_ value: String, unit: String = "", detail: TextKey? = nil,
             args: [any CVarArg] = []) {
        valueKey = nil
        valueArgs = []
        valueLabel.stringValue = value
        apply(unit: unit, detail: detail, args: args)
    }

    func set(valueKey: TextKey, valueArgs: [any CVarArg] = [], unit: String = "",
             detail: TextKey? = nil, args: [any CVarArg] = []) {
        self.valueKey = valueKey
        self.valueArgs = valueArgs
        apply(unit: unit, detail: detail, args: args)
    }

    private func apply(unit: String, detail: TextKey?, args: [any CVarArg]) {
        unitLabel.stringValue = unit
        if let detail {
            detailKey = detail
            detailArgs = args
        }
        applyLanguage()
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
    /// Çiplerin kabı: **düz NSView**, `NSStackView` değil. Çip çerçeveleri `layout()`ta
    /// elle hesaplanıyor (satıra diz + sığmayanı alt satıra indir); stack view kendi Auto
    /// Layout geçişinde o çerçeveleri ezdi ve ilk çip görünmez genişliğe düştü (ölçüldü:
    /// dar pencerede "SOURCE" çipi yalnız rozet noktası olarak çiziliyordu).
    private let chips = NSView()
    private var tiles: [MetricTile] = []
    private let summaryBar = NSView()
    private let summaryLed = NSView()
    private let summaryLabel = NSTextField(labelWithString: "")
    let eventsButton = NSButton()
    /// Olaylar artık pano içinde açılmıyor: kullanıcı isteği üzerine ayrı bir ekran oluyor
    /// (panonun içindeki katlanır liste gerçek tıklamayla açılmıyordu).
    var onOpenEvents: (() -> Void)?

    let chipSource = ChipView(key: .chipSource)
    let chipTarget = ChipView(key: .chipTarget)
    let chipChannel = ChipView(key: .chipChannel)
    let chipDiscovery = ChipView(key: .chipDiscovery)

    private(set) lazy var tileFps = MetricTile(title: .tileFps, hint: .tileFpsHint)
    private(set) lazy var tileBitrate = MetricTile(title: .tileBitrate, hint: .tileBitrateHint)
    private(set) lazy var tileLatency = MetricTile(title: .tileLatency, hint: .tileLatencyHint)
    private(set) lazy var tilePackets = MetricTile(title: .tilePackets, hint: .tilePacketsHint)
    private(set) lazy var tileHealth = MetricTile(title: .tileHealth, hint: .tileHealthHint)
    /// Ağ yükü şeridi: yayının Mbps'i + üç payda yüzdesi (kullanıcı isteği).
    let netStrip = NetStripView(frame: .zero)

    /// Elle yerleştirilen çipler (kap stack view değil, bkz. `chips`).
    private var chipViews: [ChipView] = []
    private var languageWatch: LanguageWatch?
    /// Özet satırının kaynağı: anahtarla kurulduysa dil geçişinde yeniden çözülür,
    /// serbest yazıyla (TV'den gelen gerekçe) kurulduysa olduğu gibi kalır.
    private var summaryKey: TextKey?
    private var summaryArgs: [any CVarArg] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chipViews = [chipSource, chipTarget, chipChannel, chipDiscovery]
        chipViews.forEach { chips.addSubview($0) }
        addSubview(chips)

        tiles = [tileFps, tileBitrate, tileLatency, tilePackets, tileHealth]
        // Çizgi rengi kutunun kimliğidir: mavi ölçü, yeşil akış, turuncu gecikme.
        tileFps.spark.lineColor = .systemBlue
        tileBitrate.spark.lineColor = .systemGreen
        tileLatency.spark.lineColor = .systemOrange
        tilePackets.spark.lineColor = .systemBlue
        tileHealth.spark.lineColor = .systemGreen
        tiles.forEach { addSubview($0) }
        addSubview(netStrip)

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
        eventsButton.setAccessibilityLabel(L10n.t(.eventsTitle))
        eventsButton.toolTip = L10n.t(.eventsTooltip)
        eventsButton.title = L10n.t(.eventsTitle)
        addSubview(eventsButton)

        setSummary(.summaryReady, .idle)
        languageWatch = LanguageWatch { [weak self] in self?.applyLanguage() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Panonun sabit yazıları: çip başlıkları, kutu başlıkları/yardımcı satırları, olaylar
    /// düğmesi ve özet satırı. Ölçüm kaynaklı satırlar kendi ögeleriyle yeniden çözülür,
    /// yoksa dil geçişinde ekranda Türkçe bir "12 grup" yazısı asılı kalırdı.
    func applyLanguage() {
        [chipSource, chipTarget, chipChannel, chipDiscovery].forEach { $0.applyLanguage() }
        [tileFps, tileBitrate, tileLatency, tilePackets, tileHealth].forEach { $0.applyLanguage() }
        netStrip.applyLanguage()
        eventsButton.setAccessibilityLabel(L10n.t(.eventsTitle))
        eventsButton.toolTip = L10n.t(.eventsTooltip)
        if let summaryKey {
            summaryText = L10n.f(summaryKey, summaryArgs)
            summaryLabel.stringValue = summaryText
        }
        reloadEvents(lastRows, groups: lastGroups, lines: lastLines)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Son olay sayımları: düğme yazımının kaynağı (yeniden çizimde hatırlansın).
    private var lastRows: [EventRow] = []
    private var lastGroups = 0
    private var lastLines = 0

    @objc private func openEvents() { onOpenEvents?() }

    func setStats(_ s: MirrorEngine.Stats) {
        let seconds = String(Int(s.seconds))
        tileFps.set(L10n.number(s.fps), unit: "fps", detail: .tileFpsDetail, args: [seconds])
        tileFps.push(s.fps)
        tileBitrate.set(L10n.number(s.mbps), unit: "Mbps", detail: .tileBitrateDetail)
        tileBitrate.push(s.mbps)
        tileLatency.set(L10n.number(s.encodeP50), unit: "ms",
                        detail: .tileLatencyDetail,
                        args: [L10n.number(s.encodeP95), L10n.number(s.captureP50)])
        tileLatency.push(s.encodeP50)
        tilePackets.set(Self.grouped(s.packets), unit: "RTP",
                        detail: .tilePacketsDetail,
                        args: [Self.grouped(s.audioPackets), seconds])
        let trouble = s.nackRequests + s.dropped
        tileHealth.set(valueKey: trouble == 0 ? .tileHealthOk : .tileHealthIssues,
                       valueArgs: trouble == 0 ? [] : [L10n.int(trouble)],
                       unit: "", detail: .tileHealthDetail,
                       args: [L10n.int(s.nackRequests), L10n.int(s.retransmitted),
                              L10n.int(s.dropped)])
        // Sağlık **yalnız kayıptan** hesaplanır: hareketsiz pencerede SCK kare göndermez,
        // düşük fps tek başına arıza değildir (ölçüldü: duran pencerede 0,6 fps, kayıp 0).
        tileHealth.tint(trouble == 0 ? Theme.okText : Theme.warnText)
        needsLayout = true
    }

    /// Binlik ayracı locale'den gelir: Türkçede "12.345", İngilizcede "12,345".
    /// Binlik ayracı dile göre: Türkçede "12.345", İngilizcede "12,345".
    static func grouped(_ n: Int) -> String { L10n.int(n) }

    /// Yayın durduğunda kutular "veri bekleniyor" haline döner — sıfır değeriyle yalan söylemesin.
    /// Özet satırına dokunmaz: ölçülen kusur, kırmızı hata mesajının bir sonraki 20 sn'lik
    /// yenilemede kendiliğinden kaybolmasıydı (sebep kullanıcıya görünmez kalıyordu).
    func clearStats() {
        [tileFps, tileBitrate, tileLatency, tilePackets, tileHealth].forEach {
            $0.set("—", unit: "", detail: .tileNoBroadcast)
            $0.resetValueColor()
        }
        tileFps.resetChart(); tileBitrate.resetChart(); tileLatency.resetChart()
    }

    enum Summary { case idle, ok, warn, bad }
    private var summaryState: Summary = .idle

    /// Özet satırının metni ve tonu: olay ekranı üst bilgisi de buradan okur (tek kaynak).
    private(set) var summaryText = ""
    private(set) var summaryTone: Summary = .idle

    func setSummary(_ text: String, _ state: Summary, key: TextKey? = nil,
                    args: [any CVarArg] = []) {
        summaryKey = key
        summaryArgs = args
        summaryText = text
        summaryTone = state
        summaryState = state
        summaryLabel.stringValue = text
        paintSummary()
    }

    /// Özet satırını anahtarla kur: dil değişince aynı ögelerle yeniden çözülür.
    func setSummary(_ key: TextKey, _ state: Summary, _ args: [any CVarArg] = []) {
        setSummary(L10n.f(key, args), state, key: key, args: args)
    }

    /// Dolgu ve nokta renkleri görünüme göre çözülür.
    private func paintSummary() {
        let bg: NSColor
        let led: NSColor
        switch summaryState {
        case .idle: bg = .quaternaryLabelColor; led = .tertiaryLabelColor
        case .ok: bg = .systemGreen; led = .systemGreen
        case .warn: bg = .systemOrange; led = .systemOrange
        case .bad: bg = .systemRed; led = .systemRed
        }
        summaryBar.layer?.backgroundColor = Theme.tintedFill(bg).cgColor
        summaryBar.layer?.borderColor = bg.withAlphaComponent(0.45).cgColor
        summaryBar.layer?.borderWidth = 1
        summaryLed.layer?.backgroundColor = led.cgColor
        summaryLed.layer?.cornerRadius = 4
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { paintSummary() }
    }

    /// Düğme etiketi: grup/satır sayısı tek bakışta görünsün (liste ayrı ekranda).
    /// Son çağrı hatırlanır ki dil değişince sayı Türkçe kalmasın.
    func reloadEvents(_ rows: [EventRow], groups: Int, lines: Int) {
        lastRows = rows
        lastGroups = groups
        lastLines = lines
        eventsButton.title = rows.isEmpty
            ? L10n.t(.eventsTitle)
            : L10n.f(.eventsCount, String(groups), String(lines))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        var chipY: CGFloat = 6
        var x: CGFloat = 0
        let chipHeight: CGFloat = 24
        // Çipler satıra dizilir, sığmayanı alt satıra iner (küçük pencerede iki satır olur).
        for chip in chipViews {
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
        // Ağ yükü şeridi ölçü kutularının altında sabit durur: katışık modda da görünür,
        // çünkü asıl soru ("ne kadar yük bindiriyorum") yer darken de soruluyor.
        let stripTop = max(contentBottom + 8, bounds.height - 30 - NetStripView.height - 8)
        netStrip.frame = NSRect(x: 0, y: stripTop, width: width, height: NetStripView.height)
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
    /// Ağ yükü şeridi + üstü boşluk (her modda görünür).
    static let stripRowHeight: CGFloat = NetStripView.height + 8
    static let gap: CGFloat = 8

    /// Ölçü kutularının kaç satıra dizileceği.
    static func tileRows(forWidth width: CGFloat) -> Int {
        Int(ceil(5 / Double(columns(for: width))))
    }

    /// Panonun **ihtiyaç duyduğu** yükseklik: çip sırası + kutu satırları + ağ şeridi
    /// + özet/düğme sırası. `layoutBoard` liste boyunu buradan kalan yerden hesaplar;
    /// `tileH` alçalınca grafik çizgisi düşer, `tiles = 0` (katışık) çip + şerit + özet kalır.
    static func requiredHeight(width: CGFloat, tileH: CGFloat, tiles: Int) -> CGFloat {
        let rows = tileRows(forWidth: width)
        let tileBlock = tiles > 0 ? CGFloat(rows) * (tileH + gap) : 0
        return chipRowHeight + tileBlock + stripRowHeight + summaryRowHeight
    }

    /// Çiplerin kaç satıra dizileceği: sığmayan alt satıra iner ve o satırın payı panonun
    /// yüksekliğine de girmeli (ölçülen kusur: dar pencerede ilk çip satırı kırpılıyordu).
    func chipRowsNeeded(forWidth width: CGFloat) -> Int {
        var x: CGFloat = 0, rows = 1
        for chip in chipViews {
            let w = min(chip.intrinsicContentSize.width, max(60, width))
            if x + w > width, x > 0 { rows += 1; x = 0 }
            x += w + 8
        }
        return rows
    }

    /// Bu görünüme biçilmiş genişlikte gereken yükseklik (katışık/alkaçlı mod hesaba katılır).
    func neededHeight(forWidth width: CGFloat) -> CGFloat {
        let tileH = compactTiles ? Self.shortTileHeight : Self.tileHeight
        let extraChipRows = CGFloat(max(0, chipRowsNeeded(forWidth: width) - 1)) * (24 + 6)
        return Self.requiredHeight(width: width, tileH: tileH, tiles: compact ? 0 : tiles.count)
            + extraChipRows
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
    private var severity: EventSeverity = .info

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    init(_ row: EventRow) {
        super.init(frame: .zero)
        severity = row.severity
        led.wantsLayer = true
        led.layer?.cornerRadius = 3.5
        timeLabel.stringValue = Self.time.string(from: row.last)
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        timeLabel.textColor = .tertiaryLabelColor
        textLabel.stringValue = row.rendered
        textLabel.font = NSFont.systemFont(ofSize: 11.5)
        textLabel.textColor = row.severity == .info ? .secondaryLabelColor : .labelColor
        textLabel.lineBreakMode = .byTruncatingMiddle
        countLabel.stringValue = row.count > 1 ? "×\(row.count)" : ""
        countLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        countLabel.textColor = .tertiaryLabelColor
        [led, timeLabel, textLabel, countLabel].forEach(addSubview)
        paint()
        setAccessibilityElement(true)
        setAccessibilityLabel(row.count > 1
            ? L10n.f(.eventRowRepeat, row.rendered, String(row.count)) : row.rendered)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Nokta rengi görünüme göre çözülür (açık temada bilgi tonu solda kalmasın).
    private func paint() {
        led.layer?.backgroundColor = severity.color.cgColor
        textLabel.textColor = severity == .info ? .secondaryLabelColor : .labelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { paint() }
    }

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
    let heading = NSTextField(labelWithString: L10n.t(.eventsTitle))
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
    private var languageWatch: LanguageWatch?
    /// Son içerik: dil değişince satırlar anahtarlarından yeniden çözülür.
    private var shownRows: [EventRow] = []

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
        statusLed.wantsLayer = true
        statusLed.layer?.cornerRadius = 4
        back.bezelStyle = .rounded
        back.keyEquivalent = "\u{1b}"                       // Esc
        back.target = self
        back.action = #selector(pressBack)
        clear.bezelStyle = .rounded
        clear.target = self
        clear.action = #selector(pressClear)
        openLog.bezelStyle = .rounded
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
        applyLanguage()
        languageWatch = LanguageWatch { [weak self] in self?.applyLanguage() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Başlık, düğme yazıları ve satır listesi görünen dilde yeniden çözülür.
    /// Üstteki durum/sayaç satırları App'ten gelir: App kendi dil geçişinde `show`u çağırır.
    func applyLanguage() {
        heading.stringValue = L10n.t(.eventsTitle)
        back.title = L10n.t(.eventsBack)
        clear.title = L10n.t(.eventsClear)
        openLog.title = L10n.t(.eventsOpenLog)
        stack.rebuild(shownRows.map { EventRowView($0) })
        needsLayout = true
    }

    @objc private func pressBack() { onBack?() }
    @objc private func pressClear() { onClear?() }
    @objc private func pressOpenLog() { onOpenLog?() }

    /// `status` = elzem durum cümlesi, `counts` = grup/satır sayımı.
    /// `resetScroll` yalnız ekran ilk açıldığında true: yeni olay geldikçe kullanıcının
    /// kaydırdığı yer sıfırlanmasın.
    func show(rows: [EventRow], status: String, counts: String,
              tone: DashboardView.Summary = .idle, resetScroll: Bool = false) {
        shownRows = rows
        stack.rebuild(rows.map { EventRowView($0) })
        statusLine.stringValue = status
        subtitle.stringValue = counts
        summaryTone = tone
        paintStatus()
        needsLayout = true
        if resetScroll {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private var summaryTone: DashboardView.Summary = .idle

    /// Üstteki elzem satırın tonu: tema değişince de yeniden çözülür.
    private func paintStatus() {
        let dot: NSColor
        let text: NSColor
        let fill: NSColor
        switch summaryTone {
        case .idle: dot = .tertiaryLabelColor; text = .labelColor; fill = .quaternaryLabelColor
        case .ok: dot = Theme.okText; text = Theme.okText; fill = NSColor.systemGreen
        case .warn: dot = Theme.warnText; text = Theme.warnText; fill = NSColor.systemOrange
        case .bad: dot = Theme.badText; text = Theme.badText; fill = NSColor.systemRed
        }
        statusBox.layer?.backgroundColor = Theme.tintedFill(fill).cgColor
        statusBox.layer?.borderColor = Theme.cardStroke.cgColor
        statusLed.layer?.backgroundColor = dot.cgColor
        statusLine.textColor = text
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { paintStatus() }
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
