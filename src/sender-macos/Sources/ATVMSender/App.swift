import AppKit
import CoreGraphics

/// PaneCast macOS arayüzü.
///
/// Düzen: solda yayınlanacak pencereler (arama + simge listesi), sağda hedef TV'ler
/// (kayıtlı/eşleşmiş), altta kalite + Başlat/Durdur + canlı ölçüm şeridi, en altta günlük.
/// Pencere seçimi yayın sırasında değişirse akış kesilmeden yeni pencereye geçer.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var window: NSWindow!
    private let engine = MirrorEngine()
    private let advertised = SenderServer()

    /// Durum rozetinin kapsayıcısı: arka plan + köşe yuvarlaklığı burada, yazı alt etikette.
    /// Ölçülen kusur: rozet tek başına NSTextField idi, 24 px yükseklikte metin dikey olarak
    /// tam ortalanmıyordu (NSTextField yüksek çerçevede içeriği üst/köşe hizalar).
    private let statusPill = NSView()
    private let statusText = NSTextField(labelWithString: "Hazır")
    private let windowTable = NSTableView()
    private let deviceTable = NSTableView()
    private let search = NSSearchField()
    private let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let startStop = NSButton()
    private let manualIP = NSTextField(string: "")
    /// Alt bölgenin panosu: durum çipleri, ölçü kutuları + mini grafikler, tek satır özet,
    /// katlanmış olaylar. Metin duvarının yerine geçer (kullanıcı isteği + Apple "Charting data").
    private let dashboard = DashboardView(frame: .zero)
    /// Arayüz olay defteri: aynı satır ×N olarak katlanır. Ham satırlar yine günlük dosyasına yazılır.
    private let events = EventBook()
    /// Pencere yeniden boyutlandığında çerçeveleri baştan hesaplayan kök görünüm.
    private var root: RootView!
    private var titleLabel = NSTextField(labelWithString: "PaneCast")
    private var windowSection = NSTextField(labelWithString: "")
    private var deviceSection = NSTextField(labelWithString: "")
    private var refreshButton = NSButton()
    private var findButton = NSButton()
    private var addButton = NSButton()
    private var forgetButton = NSButton()
    private var arrangeButton = NSButton()
    private var windowScroll = NSScrollView()
    private var deviceScroll = NSScrollView()
    private let windowHint = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl(labels: ["Pencere", "TV ekranı (ayrı ekran)"],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private let tvModeNote = NSTextField(wrappingLabelWithString:
        "Mac'te TV boyutunda AYRI bir ekran açılır; oraya taşıdığın pencereler ve sesler TV'de oynar. "
        + "Kendi ekranlarında ne açarsan aç, TV yayını kopmaz.\n\n"
        + "Sistem Ayarları → Masaüstü ve Dock → \"Ekranların ayrı Space'leri var\" açık kalmalı.")
    /// TV ekranı modunda Mac'teki ekranların gerçek dizilimi: "yeni ekran sağda mı solda mı"
    /// kullanıcı tahmin etmesin.
    private let screensNote = NSTextField(wrappingLabelWithString: "")
    /// Yalnız TV ekranı modunda görünen görünümler.
    private var tvModeViews: [NSView] = []
    /// Pencere listesi modunda görünen, TV ekranı modunda gizlenen görünümler.
    private var windowModeViews: [NSView] = []
    private var tvDisplayMode: Bool { modeControl.selectedSegment == 1 }

    private var TVs: [DiscoveredTV] = []
    private var windows: [WindowInfo] = []
    private var shown: [WindowInfo] = []
    private var discoveryTimer: Timer?
    private var windowTimer: Timer?
    private var switching = false
    /// Liste yenilerken yapılan programatik seçimi kullanıcı seçiminden ayırır.
    private var applyingSelection = false
    /// Yayın TV'den başlatıldıysa TV'nin host'u: Mac durdurunca aynı bağlantıdan bildirilir.
    private var tvInitiatedHost: String?
    /// Yakalama takıldığında durum şeridindeki tek satır; nil = normal durum adı.
    private var streamNotice: String?
    /// "TV eşleşmiş diyor ama Mac'te anahtar yok" uyarısı her adres için yalnız bir kez yazılır.
    private var orphanWarnings: Set<String> = []
    /// "Ağda alıcı yok" uyarısı da bir kez yazılır; keşif 20 sn'de bir tekrarlıyor.
    private var warnedNoTv = false

    private static let winColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("win"))
    private static let devColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("dev"))

    // ---------- yaşam döngüsü ----------

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildUI()
        log("Hoş geldin. Soldan pencere, sağdan TV seç — yayın sırasında pencere değişirse akış yerinde değişir.")
        Task { await refreshTVs() }
        Task { await refreshWindows(keepSelection: true) }
        WindowCapture.permissionNote = { [weak self] in self?.append($0) }
        checkPermission()
        warnAboutCopies()
        refreshRunButton()

        advertised.onLog = { [weak self] in self?.append($0) }
        advertised.onResume = { [weak self] session in
            Task { @MainActor in
                self?.comeToFront(reason: "\(session.name) bu bilgisayardan yayın istedi")
                await self?.startForTV(session)
            }
        }
        advertised.onIdrRequest = { [weak self] _ in
            Task { @MainActor in self?.engine.requestKeyFrame() }
        }
        advertised.onTvStop = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.engine.isRunning else { return }
                await self.engine.stop()          // TV bağlantısı zaten kapandı; bildirim gereksiz
                self.tvInitiatedHost = nil
                self.refreshRunButton()
            }
        }
        advertised.start()
        if let note = KeyStore.prepare() { append(note) }

        engine.onStats = { [weak self] s in self?.render(s) }
        // Donma uyarısı düğmeyi de tazeler: motor kendi kendine durursa etiket eskisi gibi kalmıyor.
        engine.onStatusNote = { [weak self] note in
            Task { @MainActor in self?.streamNotice = note; self?.refreshRunButton() }
        }

        // TV uygulaması açıkken liste kendiliğinden dolsun; yeni pencereler de görünsün.
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self, !self.engine.isRunning else { return }; await self.refreshTVs() }
        }
        windowTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshWindows(keepSelection: true) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    /// Çıkışta yayın temiz kapatılır: uygulama ses tap'i yıkılır (Mac sesi geri gelir),
    /// kodlayıcı/soketler serbest kalır, TV'ye durdurma bildirilir. Bitince çıkış onaylanır.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let tvHost = tvInitiatedHost
        Task { @MainActor in
            await engine.stop()
            if let tvHost { advertised.notifyStopped(host: tvHost) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // ---------- arayüz ----------

    private func buildUI() {
        let content = RootView(frame: NSRect(x: 0, y: 0, width: 900, height: 760))
        root = content
        content.onLayout = { [weak self] size in self?.layoutContent(size) }

        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        content.addSubview(titleLabel)

        statusPill.frame = NSRect(x: 700, y: 622, width: 180, height: 24)
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 12
        statusText.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        statusText.textColor = .white
        statusText.alignment = .center
        statusText.translatesAutoresizingMaskIntoConstraints = false
        statusPill.addSubview(statusText)
        // centerY anchörü: metin rozetin içine tam ortalanır (çerçeve yüksekliğinden bağımsız).
        NSLayoutConstraint.activate([
            statusText.centerXAnchor.constraint(equalTo: statusPill.centerXAnchor),
            statusText.centerYAnchor.constraint(equalTo: statusPill.centerYAnchor),
            statusText.leadingAnchor.constraint(greaterThanOrEqualTo: statusPill.leadingAnchor, constant: 8),
            statusText.trailingAnchor.constraint(lessThanOrEqualTo: statusPill.trailingAnchor, constant: -8),
        ])
        content.addSubview(statusPill)

        modeControl.frame = NSRect(x: 140, y: 619, width: 340, height: 26)
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        content.addSubview(modeControl)

        windowSection = section("Yayınlanacak pencere", x: 20, y: 588, w: 400)
        content.addSubview(windowSection)
        search.frame = NSRect(x: 20, y: 552, width: 424, height: 26)
        search.placeholderString = "uygulama veya pencere ara"
        search.delegate = self
        search.target = self
        search.action = #selector(filterChanged)
        content.addSubview(search)
        refreshButton = button("Yenile", x: 452, y: 550, w: 88) { [weak self] in
            Task { await self?.refreshWindows(keepSelection: false) }
        }
        content.addSubview(refreshButton)

        configureTable(windowTable, column: Self.winColumn, width: 520)
        windowScroll.hasVerticalScroller = true
        windowScroll.borderType = .bezelBorder
        windowScroll.documentView = windowTable
        content.addSubview(windowScroll)
        windowModeViews = [windowSection, search, refreshButton, windowScroll]

        tvModeNote.frame = NSRect(x: 20, y: 400, width: 520, height: 130)
        tvModeNote.font = NSFont.systemFont(ofSize: 13)
        tvModeNote.textColor = .secondaryLabelColor
        tvModeNote.isHidden = true
        content.addSubview(tvModeNote)

        screensNote.frame = NSRect(x: 20, y: 288, width: 520, height: 104)
        screensNote.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        screensNote.textColor = .secondaryLabelColor
        screensNote.isHidden = true
        content.addSubview(screensNote)
        arrangeButton = button("Ekranları Düzenle…", x: 20, y: 252, w: 200) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        arrangeButton.isHidden = true
        content.addSubview(arrangeButton)
        tvModeViews = [tvModeNote, screensNote, arrangeButton]
        refreshScreensNote()

        deviceSection = section("Hedef TV — ağdaki cihazlar · çift tıkla: PIN ile eşleştir", x: 560, y: 588, w: 320)
        content.addSubview(deviceSection)
        configureTable(deviceTable, column: Self.devColumn, width: 300)
        deviceScroll.hasVerticalScroller = true
        deviceScroll.borderType = .bezelBorder
        deviceScroll.documentView = deviceTable
        content.addSubview(deviceScroll)

        findButton = button("TV'yi bul / yeniden tara", x: 560, y: 368, w: 320) { [weak self] in
            Task { await self?.refreshTVs() }
        }
        content.addSubview(findButton)
        manualIP.frame = NSRect(x: 560, y: 334, width: 216, height: 24)
        manualIP.placeholderString = "TV adresi (192.168.·)"
        content.addSubview(manualIP)
        addButton = button("Ekle", x: 784, y: 332, w: 96) { [weak self] in
            self?.addManualDevice()
        }
        content.addSubview(addButton)
        forgetButton = button("Eşleştirmeyi unut", x: 560, y: 298, w: 320, h: 26) { [weak self] in
            Task { await self?.forgetPairing() }
        }
        content.addSubview(forgetButton)
        windowHint.frame = NSRect(x: 560, y: 250, width: 320, height: 44)
        windowHint.font = NSFont.systemFont(ofSize: 11)
        windowHint.textColor = .secondaryLabelColor
        windowHint.maximumNumberOfLines = 3
        windowHint.lineBreakMode = .byWordWrapping
        content.addSubview(windowHint)

        profilePopup.frame = NSRect(x: 20, y: 208, width: 200, height: 26)
        profilePopup.addItems(withTitles: ["1080p60 (12 Mbps)", "1080p30 (8 Mbps)", "720p60 (6 Mbps)"])
        content.addSubview(profilePopup)


        startStop.frame = NSRect(x: 236, y: 202, width: 304, height: 38)
        // Bezel yerine kendi zemin rengimiz: durum renk olarak anında okunsun (yeşil/kırmızı).
        startStop.isBordered = false
        startStop.bezelStyle = .regularSquare
        startStop.wantsLayer = true
        startStop.layer?.cornerRadius = 8
        startStop.keyEquivalent = "\r"
        startStop.target = self
        startStop.action = #selector(toggleRun)
        content.addSubview(startStop)
        setRunTitle("Başlat")

        content.addSubview(dashboard)
        dashboard.clearStats()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "PaneCast"
        window.contentView = content
        // Sınırlar: 780×600'nin altına inmez — o boyutta pano iki satıra düşer ve listeler
        // hâlâ okunur; üst sınır yok, `layoutContent` 1240 px'ten sonra içeriği ortalar.
        window.minSize = NSSize(width: 780, height: 600)
        placeOnCursorScreen()
        window.makeKeyAndOrderFront(nil)
    }

    /// Pencere boyutuna göre tüm çerçeveleri baştan hesaplar.
    ///
    /// Ölçülen kusur: eskiden tek bir `autoresizingMask` dışında bir düzen kuralı yoktu; pencere
    /// büyütülünce listeler yerinde kalıp sağda/altta kullanılmayan boşluk oluşuyordu,
    /// küçültülünce de öğeler taşabiliyordu. Şimdi her boyutta iki sütun + kontrol satırı + pano
    /// yeniden hesaplanır; 1240 px'ten geniş pencerede içerik ortalanır (uzayıp seyrelmesin).
    private func layoutContent(_ size: NSSize) {
        let w = size.width, h = size.height
        let inset = max(20, (w - 1240) / 2)
        let gap: CGFloat = 16
        let usable = max(360, w - 2 * inset)
        let leftW = max(280, (usable - gap) * 0.58)
        let rightW = max(220, usable - gap - leftW)
        let leftX = inset, rightX = inset + leftW + gap

        // Pano yüksekliği içerikten hesaplanır. 640 px'ın altında ölçü kutuları kalkar
        // (çipler + özet + olaylar kalır): her şeyi sıkıştırmaktansa sınır koymak okunur kalıyor.
        let compact = h < 640
        dashboard.compact = compact
        let want = dashboard.neededHeight(forWidth: usable)
        let dashH = min(max(compact ? 96 : 150, want), max(96, h - 296))
        let dashY: CGFloat = 14
        let controlH: CGFloat = 38
        let controlsY = dashY + dashH + 12
        let listsBottom = controlsY + controlH + 12
        let listsTop = h - 100

        dashboard.frame = NSRect(x: inset, y: dashY, width: usable, height: dashH)

        titleLabel.frame = NSRect(x: leftX, y: h - 40, width: 110, height: 26)
        statusPill.frame = NSRect(x: w - inset - 180, y: h - 38, width: 180, height: 24)
        modeControl.frame = NSRect(x: leftX + 118, y: h - 39, width: min(340, max(180, usable - 340)), height: 26)

        windowSection.frame = NSRect(x: leftX, y: h - 68, width: leftW, height: 16)
        let searchW = max(120, leftW - 96)
        search.frame = NSRect(x: leftX, y: listsTop, width: searchW, height: 26)
        refreshButton.frame = NSRect(x: leftX + searchW + 8, y: listsTop - 2, width: 88, height: 28)
        windowScroll.frame = NSRect(x: leftX, y: listsBottom, width: leftW,
                                    height: max(70, listsTop - 30 - listsBottom))

        profilePopup.frame = NSRect(x: leftX, y: controlsY + 6, width: 200, height: 26)
        startStop.frame = NSRect(x: leftX + 216, y: controlsY, width: max(160, leftW - 216), height: controlH)

        // Sağ sütun alta doğru kurulur: ipucu → eşleştirmeyi unut → adres+ekle → tara → liste.
        var ry = controlsY
        windowHint.frame = NSRect(x: rightX, y: ry, width: rightW, height: 40); ry += 44
        forgetButton.frame = NSRect(x: rightX, y: ry, width: rightW, height: 26); ry += 30
        manualIP.frame = NSRect(x: rightX, y: ry + 1, width: max(110, rightW - 104), height: 24)
        addButton.frame = NSRect(x: rightX + rightW - 92, y: ry - 1, width: 92, height: 28); ry += 32
        findButton.frame = NSRect(x: rightX, y: ry, width: rightW, height: 28); ry += 32
        deviceSection.frame = NSRect(x: rightX, y: h - 68, width: rightW, height: 16)
        // Liste üstü soldaki listeyle aynı hizada; yükseklik artan yerden hesaplanır.
        // Ölçülen kusur: sabit "en az 70 px" kuralı dar pencerede listeyi bölüm etiketinin üstüne çıkarıyordu.
        let rightListTop = listsTop - 30
        let rightListBottom = max(listsBottom, min(ry, rightListTop - 44))
        deviceScroll.frame = NSRect(x: rightX, y: rightListBottom, width: rightW,
                                    height: max(0, rightListTop - rightListBottom))

        tvModeNote.frame = NSRect(x: leftX, y: listsBottom + 96, width: leftW, height: 130)
        screensNote.frame = NSRect(x: leftX, y: listsBottom, width: leftW, height: 88)
        arrangeButton.frame = NSRect(x: leftX, y: listsBottom - 32, width: 200, height: 28)
    }

    private func section(_ s: String, x: CGFloat, y: CGFloat, w: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: x, y: y, width: w, height: 16)
        return l
    }

    private func configureTable(_ table: NSTableView, column: NSTableColumn, width: CGFloat) {
        column.width = width
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
        table.intercellSpacing = NSSize(width: 4, height: 4)
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(tableDoubleClicked)
        table.style = .plain
    }

    /// Pencereyi imlecin olduğu ekrana ortalar. `window.center()` çok ekranlı
    /// düzende pencereyi görünmeyen ikincil ekrana bırakabiliyordu
    /// (ölçüldü: çerçeve x=2055, y=-250 → kullanıcı arayüzü göremedi).
    private func placeOnCursorScreen() {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let vis = screen.visibleFrame
        let size = window.frame.size
        let x = max(vis.minX, min(vis.midX - size.width / 2, vis.maxX - size.width))
        let y = max(vis.minY, min(vis.midY - size.height / 2, vis.maxY - size.height))
        window.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    private func button(_ title: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat = 28,
                        _ action: @escaping () -> Void) -> NSButton {
        let b = NSButton(frame: NSRect(x: x, y: y, width: w, height: h))
        b.title = title
        b.bezelStyle = .rounded
        b.setAccessibilityLabel(title)
        let box = ActionBox(action)
        b.target = box
        b.action = #selector(ActionBox.fire)
        retainers.append(box)
        return b
    }

    /// NSTarget-action için küçük yardımcı (closure saklamak için).
    final class ActionBox: NSObject {
        let action: () -> Void
        init(_ a: @escaping () -> Void) { action = a }
        @objc func fire() { action() }
    }
    private var retainers: [ActionBox] = []

    /// Tanılama satırı: **yalnız** günlük dosyasına yazılır, arayüzde görünmez.
    /// Arayüz metin duvarı olmaktan kurtarıldı; teşhis gerektiğinde dosya okunur.
    private func log(_ s: String) {
        engine.onLog = { [weak self] in self?.append($0) }
        append(s)
    }

    private func append(_ s: String) {
        // `open` ile başlatılan GUI'nin stdout'u yoktur; tanılamayı dosyaya da yaz.
        emit(s)
    }

    /// Arayüzde görünen olay. Aynı metin tekrarlanırsa yeni satır açılmaz, sayaç artar
    /// (ölçülen kusur: "keşif:" satırı 20 sn'de bir eklenip paneli dolduruyordu).
    private func note(_ s: String, _ severity: EventSeverity = .info) {
        emit(s)
        events.add(s, severity)
        dashboard.reloadEvents(events.rows, groups: events.groupCount, lines: events.lineCount)
    }

    // ---------- tablolar ----------

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === windowTable ? shown.count : TVs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === windowTable { return windowCell(row) }
        return deviceCell(row)
    }

    private func windowCell(_ row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("winCell")
        guard let cell = windowTable.makeView(withIdentifier: id, owner: self) as? WindowCell,
              row < shown.count else {
            let fresh = WindowCell()
            fresh.identifier = id
            fresh.fill(w: shown[row], streaming: engine.currentWindow?.id == shown[row].id)
            return fresh
        }
        cell.fill(w: shown[row], streaming: engine.currentWindow?.id == shown[row].id)
        return cell
    }

    private func deviceCell(_ row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("devCell")
        let tv = TVs[row]
        // Aynı TV'nin eski adresi mi? (Ad aynı, şu anda canlı olan başka bir satır var.)
        let liveTwin = TVs.contains { $0.online && $0.host != tv.host && $0.displayName == tv.displayName }
        guard let cell = deviceTable.makeView(withIdentifier: id, owner: self) as? DeviceCell,
              row < TVs.count else {
            let fresh = DeviceCell()
            fresh.identifier = id
            fresh.fill(tv: tv, liveTwin: liveTwin)
            return fresh
        }
        cell.fill(tv: tv, liveTwin: liveTwin)
        return cell
    }

    func tableViewSelectionDidChange(_ note: Notification) {
        if let table = note.object as? NSTableView, table === windowTable {
            // Programatik seçim yayını kaçırmasın: ölçülen kusur akışın Dock penceresine
            // geçmesiydi. Yalnız kullanıcının gerçekten seçtiği satır yayını taşır.
            guard !applyingSelection else { return }
            Task { @MainActor in await self.windowSelectionChanged() }
        } else {
            refreshRunButton()
        }
    }

    @objc private func tableDoubleClicked() {
        guard !engine.isRunning else { return }
        let devRow = deviceTable.clickedRow
        if devRow >= 0, devRow < TVs.count {
            // TV satırına çift tıklamak eşleştirme penceresini açar (PIN), yayını değil.
            Task { @MainActor in await self.pairDevice(row: devRow) }
            return
        }
        if windowTable.clickedRow >= 0 { toggleRun() }
    }

    /// Yalnızca eşleşme: kontrol kanalı kurulur, TV PIN isterse sorulur, yayın başlatılmaz.
    private func pairDevice(row: Int) async {
        let tv = TVs[row]
        guard !tv.host.isEmpty else {
            // Yayın alınıyor ama adres yok: Mac bu TV'yle hiç eşleşmedi ve ağ yoklaması da
            // yanıt vermedi. Eski mesaj ("TV'nin uygulamasını aç") yanıltıcıydı: uygulama açıktı.
            setStatus("TV adresi bilinmiyor")
            windowHint.stringValue = tv.online
                ? "TV yayında ama adresi elimizde değil: TV'yi bul / yeniden tara'ya bas; yine de gelmezse adresi kutuya yazıp Ekle'ye bas."
                : "Bu TV kapalı görünüyor; TV'de uygulamayı aç ve yeniden tara."
            note("Eşleşme reddi: \(tv.displayName) adresi bilinmiyor (yayın: \(tv.online ? "var" : "yok"))", .warn)
            return
        }
        guard tv.online else {
            setStatus("TV kapalı")
            windowHint.stringValue = "Bu TV'nin uygulamasını aç; sonra yeniden tara."
            note("Eşleşme reddi: \(tv.displayName) kapalı", .warn)
            return
        }
        engine.setHost(tv.host)
        do {
            // Yerel kayda değil TV'nin yanıtına bakılır: eski sürümden taşınan anahtar
            // v2 TV'de geçersizdir ve TV yeniden PIN ister.
            let hs = try await engine.connectAndHello(host: tv.host)
            if hs == .paired {
                setStatus("Zaten eşleşmiş")
                note("\(tv.displayName) zaten eşleşmiş — pencere seçip Başlat'a bas")
                log("eşleşme var: \(tv.displayName) — pencere seçip Başlat'a bas")
            } else {
                guard let pin = await askPin() else { await engine.stop(); return }
                try await engine.submitPin(pin)
                note("Eşleşme tamamlandı: \(tv.displayName) · \(tv.host)")
                setStatus("Eşleşti")
            }
            KeyStore.storeName(tv.name, for: tv.host)
            await engine.stop()
        } catch let e as ControlClient.ControlError {
            await engine.stop(); fail("Eşleşme başarısız", e.description)
        } catch {
            await engine.stop(); fail("Eşleşme başarısız", "\(error)")
        }
        refreshLists()
    }

    @objc private func filterChanged() { applyFilter() }


    // ---------- eylemler ----------

    @objc private func toggleRun() {
        if engine.isRunning { stopStreaming() ; return }
        Task { await run() }
    }

    /// Yayını durdur ve TV'ye bildir: bildirilmezse TV "yayın alınıyor" ekranında asılı kalıyor.
    private func stopStreaming() {
        let tvHost = tvInitiatedHost
        Task {
            await engine.stop()                                  // Mac başlattıysa kontrol kanalından `stop` gider
            if let tvHost { advertised.notifyStopped(host: tvHost) }   // TV başlattıysa TV'nin kendi bağlantısından
            tvInitiatedHost = nil
            note("Yayın durduruldu, kaynaklar serbest bırakıldı")
            refreshRunButton()
        }
    }

    @objc private func modeChanged() {
        let tv = tvDisplayMode
        windowModeViews.forEach { $0.isHidden = tv }
        tvModeViews.forEach { $0.isHidden = !tv }
        windowHint.stringValue = tv ? "" : "Bir pencere seç; seçtiğin an yayına geçer."
        refreshScreensNote()
    }

    /// Yayın sırasında pencere değişti: akışı kesmeden yeni pencereye geç.
    private func windowSelectionChanged() async {
        guard !tvDisplayMode else { return }
        let row = windowTable.selectedRow
        guard row >= 0, row < shown.count else { return }
        let win = shown[row]
        guard engine.isRunning else { return }
        guard engine.currentWindow?.id != win.id, !switching else { return }
        switching = true
        defer { switching = false }
        do {
            try await engine.switchWindow(win)
        } catch {
            log("pencere değiştirilemedi: \(error)")
            refreshRunButton()
        }
    }

    private func selectedDevice() -> DiscoveredTV? {
        let i = deviceTable.selectedRow
        return i >= 0 && i < TVs.count ? TVs[i] : nil
    }

    private func selectedHost() -> String? {
        let manual = manualIP.stringValue.trimmingCharacters(in: .whitespaces)
        if !manual.isEmpty { return manual }
        guard let d = selectedDevice() else { return nil }
        return d.host.isEmpty ? nil : d.host
    }

    private func run() async {
        log("Başlat: tv satırı=\(deviceTable.selectedRow) pencere satırı=\(windowTable.selectedRow)")
        guard let host = selectedHost() else {
            setStatus("TV seçilmedi")
            windowHint.stringValue = "Sağdaki listeden bir TV seç; listesi boşsa TV'yi bul ya da adresi elle yazıp Ekle'ye bas."
            dashboard.setSummary("Başlatılamadı: hedef TV seçili değil.", .bad)
            note("Başlat reddedildi: hedef TV yok (satır seçili değil ya da adresi bilinmiyor)", .error)
            return
        }
        let row = windowTable.selectedRow
        guard tvDisplayMode || (row >= 0 && row < shown.count) else {
            setStatus("Pencere seçilmedi")
            windowHint.stringValue = "Soldaki listeden yayınlanacak pencereyi seç."
            dashboard.setSummary("Başlatılamadı: yayınlanacak pencere seçili değil.", .bad)
            note("Başlat reddedildi: pencere seçimi yok", .error)
            return
        }
        let source: MirrorEngine.CastSource = tvDisplayMode ? .tvDisplay : .window(shown[row])
        let profile = H264Encoder.Profile.presets[["1080p60", "1080p30", "720p60"][profilePopup.indexOfSelectedItem]]!
        engine.setHost(host)
        refreshRunButton()
        let what: String
        if case .window(let win) = source { what = "\(win.app) — \(win.title)" } else { what = TvDisplay.name }
        log("hedef: \(host) ← \(what) · profil \(profile.width)x\(profile.height)@\(profile.fps)")
        do {
            let hs = try await engine.connectAndHello(host: host)
            if hs == .needsPin {
                guard let pin = await askPin() else { await engine.stop(); refreshRunButton(); return }
                try await engine.submitPin(pin)
            }
            if let name = selectedDevice()?.name { KeyStore.storeName(name, for: host) }
            try await engine.beginStream(source: source, profile: profile)
            // Başarı yolunda düğmeyi ve durumu yenile: aksine "Başlat" yazılı kalıyor.
            streamNotice = nil
            refreshRunButton()
            note("Yayın başladı · \(what) → \(host) · \(profile.width)x\(profile.height)@\(profile.fps)")
        } catch let e as ControlClient.ControlError {
            await engine.stop(); fail("Başlatılamadı", e.description)
        } catch let e as CaptureError {
            await engine.stop(); fail("Yakalama izni/pencere", e.description)
        } catch {
            await engine.stop(); fail("Hata", "\(error)")
        }
        refreshLists()
    }

    /// TV'den gelen "yayına başla" isteği: arayüzde SEÇİLİ pencere yoksa başlatmaz.
    /// (Seçim yapmadan rastgele bir pencereyi ağa vermek istemediğimiz için kasıtlı red.)
    private func startForTV(_ session: SenderServer.TvSession) async {
        guard !engine.isRunning else { log("yayın zaten sürüyor; yeni istek yok sayıldı"); return }
        let row = windowTable.selectedRow
        guard tvDisplayMode || (row >= 0 && row < shown.count) else {
            note("TV yayın istedi ama arayüzde pencere seçili değil — bir pencere seçmen yeterli", .warn)
            windowHint.stringValue = "TV yayın istedi: soldan bir pencere seç, akış hemen o pencereye geçer."
            session.reject("no_window_selected_on_sender")
            return
        }
        let source: MirrorEngine.CastSource = tvDisplayMode ? .tvDisplay : .window(shown[row])
        KeyStore.storeName(session.name, for: session.host)
        refreshRunButton()
        do {
            tvInitiatedHost = session.host
            try await engine.beginForTv(source: source,
                                        profile: H264Encoder.Profile.presets["1080p60"]!,
                                        host: session.mediaHost, mediaPort: session.mediaPort) { info in
                await self.advertised.announceStart(session, info)
            }
        } catch {
            await engine.stop()
            log("TV isteği başlatılamadı: \(error)")
        }
        refreshRunButton()
    }

    /// TV'den gelen istekte pencereyi öne çıkar: kullanıcı TV kumandasındayken
    /// Mac'te uygulamanın açık olup olmadığını aramak zorunda kalmasın.
    private func comeToFront(reason: String) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        log("öne alındı: \(reason)")
    }

    /// Hata modalı arayüzü kilitliyordu: durum rozeti + ipucu satırı + günlük kullanılıyor.
    private func fail(_ title: String, _ detail: String) {
        setStatus(title)
        windowHint.stringValue = detail
        dashboard.setSummary("\(title): \(detail)", .bad)
        note("\(title): \(detail)", .error)
        refreshRunButton()
    }

    private func addManualDevice() {
        let host = manualIP.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        if TVs.first(where: { $0.host == host }) == nil {
            TVs.append(DiscoveredTV(name: KeyStore.names()[host] ?? "Bilinmeyen TV", host: host,
                                    controlPort: 7601, mediaPort: 7602))
            deviceTable.reloadData()
        }
        manualIP.stringValue = ""
        deviceTable.selectRowIndexes(IndexSet(integer: TVs.count - 1), byExtendingSelection: false)
        log("elle TV eklendi: \(host)")
    }

    private func forgetPairing() async {
        let manual = manualIP.stringValue.trimmingCharacters(in: .whitespaces)
        guard let host = selectedHost() else {
            windowHint.stringValue = "Sağdaki listeden eşleşmeyi kaldırmak istediğin TV'yi seç."
            note("Eşleşme unutulmadı: hedef yok (liste satırı seçili değil ya da adresi boş)", .warn)
            return
        }
        let name = selectedDevice()?.displayName ?? host
        log("eşleşme kaldırılıyor: \(name) · \(host)" + (manual.isEmpty ? "" : " (adres kutusundaki değer)"))
        // TV'nin kontrol sunucusu tek oturumlu: yayın sürerken aynı adrese açılan ikinci bağlantı
        // bekler. Ölçülen kusur: düğme hiçbir şey yapmadan asılı kalıyor, kayıt silinmiyordu.
        if engine.isRunning, engine.streamingHost == host || tvInitiatedHost == host {
            note("Eşleşme kaldırılıyor: yayın durduruldu (kontrol kanalı boşalmadan kaldırılamıyor)")
            await engine.stop()
            tvInitiatedHost = nil
            refreshRunButton()
        }
        // İki uç ayrı işler: TV'ye ulaşmak *denenir*, ama ulaşılamıyorsa bu Mac'teki kayıt
        // yine de silinmelidir. Ölçülen kusur: adres değişmiş/eski satırda `connect()` patlıyor,
        // `KeyStore.remove` hiç çağrılmıyor ve kullanıcı ölü eşleşme kaydını silemiyordu.
        var tvForgetful = false
        do {
            let c = ControlClient(host: host)
            try await c.connect()
            // `unpair` yalnız doğrulanmış oturumda kabul edilir; TV PIN istiyorsa zaten eşleşmesizdir.
            if try await c.beginHello() == .paired { try await c.unpair() }
            c.disconnect()
            tvForgetful = true
        } catch {
            note("TV'ye ulaşılamadı (kapalı, adres değişmiş ya da kanal meşgul) — kayıt yalnız bu Mac'ten siliniyor: \(error)", .warn)
        }
        KeyStore.remove(host)     // Anahtar + ad kaydı; yarımkalır eşleşme bırakmamak için
        note(tvForgetful
             ? "Eşleşme iki uçtan da kaldırıldı: \(host)"
             : "Eşleşme bu Mac'ten silindi: \(host) — TV tarafı hâlâ hatırlıyor olabilir: TV'de uygulamayı açıp eşleşmeyi oradan da unut")
        await refreshTVs()
    }

    private func refreshTVs() async {
        let selectedHostNow = selectedDevice()?.host
        let found = await TvDiscovery.browse(seconds: 3)
        TVs = found
        deviceTable.reloadData()
        if let h = selectedHostNow, let i = TVs.firstIndex(where: { $0.host == h }) {
            deviceTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        }
        let paired = found.filter { KeyStore.isPaired($0.host) }.count
        // Keşif tek yerde durur: çip. Her 20 saniyede bir satır eklenmesi paneli okunamaz
        // yapıyordu (kullanıcı isteği: "keşif sürekli gelmesin, tek bir yerde bulundu/bulunmadı").
        dashboard.chipDiscovery.set(found.isEmpty ? "yayın yok" : "\(found.count) TV · \(paired) eşleşmiş",
                                    state: found.isEmpty ? .idle : .ok)
        if found.isEmpty {
            log("keşif: ağda alıcı yayını yok — TV'de uygulamayı açık tut ya da TV'den bu bilgisayarı seç")
            if !warnedNoTv {
                warnedNoTv = true
                note("Ağda alıcı yayını yok — TV'de uygulamayı açık tut ya da TV'den bu bilgisayarı seç", .warn)
            }
        } else {
            warnedNoTv = false
            log("keşif: \(found.count) TV bulundu (\(paired) eşleşmiş)")
        }
        // TV kendi eşleşmesini hatırlıyor ama Mac'te anahtarı yok: tipik neden TV'nin adresinin
        // değişmesidir, anahtar eski adreste kalır. Keşif 20 sn'de bir tekrarlandığı için uyarı
        // başına bir kez yazılır.
        for tv in found where tv.tvReportsPaired && !KeyStore.isPaired(tv.host)
            && !orphanWarnings.contains(tv.host) {
            orphanWarnings.insert(tv.host)
            note("\(tv.displayName) TV'de eşleşmiş görünüyor ama bu Mac'te anahtarı yok — satıra çift tıkla, PIN'i yeniden gir", .warn)
        }
        refreshRunButton()
    }

    private func refreshWindows(keepSelection: Bool) async {
        let selectedId = keepSelection ? shown[safe: windowTable.selectedRow]?.id : nil
        do {
            try await WindowCapture.ensurePermission(waitSeconds: 0)
            windows = (try await WindowCapture.shareableWindows())
                .filter { !$0.title.isEmpty && $0.onScreen && $0.frame.width >= 160 && $0.frame.height >= 120 }
            applyFilter(restoring: selectedId)
            windowHint.stringValue = engine.isRunning ? "" : "Bir pencere seç; seçtiğin an yayına geçer."
        } catch let e as CaptureError {
            windows = []; shown = []
            windowTable.reloadData()
            log(e.description)
            windowHint.stringValue = "Ekran Kaydı izni gerekiyor: Sistem Ayarları → Gizlilik ve Güvenlik → Ekran Kaydı → PaneCast."
        } catch {
            log("pencereler alınamadı: \(error)")
        }
    }

    private func applyFilter(restoring: UInt32? = nil) {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        shown = q.isEmpty ? windows : windows.filter {
            $0.app.lowercased().contains(q) || $0.title.lowercased().contains(q)
        }
        let keep = restoring ?? shown[safe: windowTable.selectedRow]?.id
        // Programatik seçimi kullanıcı seçimi gibi gösteren tuzak: `reloadData` +
        // `selectRowIndexes` → tableViewSelectionDidChange → switchWindow. Yayın sırasında
        // izlenen pencere listeden düşünce (tam ekran yeni kimlik üretiyor) satır 0'a
        // düşüyordu ve akış Dock penceresine geçiyordu (ölçüldü).
        applyingSelection = true
        windowTable.reloadData()
        if let keep, let i = shown.firstIndex(where: { $0.id == keep }) {
            windowTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        } else if !shown.isEmpty, !engine.isRunning {
            // Yalnız yayın YOKKEN ilk satırı seç: TV'den gelen "yayına başla" isteği
            // seçimsiz geldiğinde reddediliyordu (ölçüldü: "pencere seçili değil").
            windowTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        applyingSelection = false
        followLostWindow()
        refreshLists()
    }

    /// İzlenen pencere listeden düştüyse yayını rastgele bir satıra değil, AYNI uygulamanın
    /// en büyük penceresine taşı (tarayıcıda tam ekrana geçiş yeni pencere kimliği üretir).
    private func followLostWindow() {
        guard !switching, engine.isRunning, let cur = engine.currentWindow,
              !shown.contains(where: { $0.id == cur.id }) else { return }
        guard let twin = shown.filter({ $0.pid == cur.pid }).max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else {
            log("izlenen pencere artık listede değil; aynı uygulamanın yedek penceresi de yok — akış mevcut kaynakta bırakıldı")
            return
        }
        switching = true
        Task { @MainActor [weak self] in
            defer { self?.switching = false }
            log("izlenen pencere listeden düştü → aynı uygulamanın penceresine geçiliyor: \(twin.app) — \(twin.title)")
            do { try await self?.engine.switchWindow(twin) }
            catch { log("geçiş başarısız: \(error)") }
        }
    }

    private func refreshLists() {
        windowHint.stringValue = shown.isEmpty && !windows.isEmpty
            ? "Aramana uygun pencere yok — arama kutusunu temizle." : windowHint.stringValue
    }

    /// Düğme etiketi her durum değişiminde yenilenir. Ölçülen kusur: Mac'ten başlatılan yayında
    /// `run()` başarı yolunda bu fonksiyon hiç çağrılmıyordu, düğme "Başlat" yazmaya devam edip
    /// basınca yayını durduruyordu (TV'den başlatılan akışta `startForTV` çağırdığı için görülmedi).
    private func refreshRunButton() {
        setRunTitle(engine.isRunning ? "Durdur" : "Başlat")
        if !engine.isRunning { streamNotice = nil; dashboard.clearStats() }
        setStatus(streamNotice ?? (engine.isRunning ? "Yayında" : "Hazır"))
        modeControl.isEnabled = !engine.isRunning
        syncChips()
    }

    /// Durum çipleri seçime ve yayına göre tek yerden doldurulur: kullanıcı "neyi, nereye,
    /// hangi kanalla" yayınladığını satır satır okumadan görebilsin.
    private func syncChips() {
        let source: String
        var sourceState: ChipView.State = .ok
        if tvDisplayMode {
            source = "TV ekranı (ayrı ekran)"
        } else if let win = shown[safe: windowTable.selectedRow] {
            source = "\(win.app) — \(win.title)"
        } else {
            source = "pencere seçilmedi"
            sourceState = .warn
        }
        dashboard.chipSource.set(source, state: sourceState)

        let target: String
        var targetState: ChipView.State = .ok
        if let manual = selectedHost(), !manual.isEmpty {
            target = manual
        } else if let tv = selectedDevice() {
            target = "\(tv.displayName) · \(tv.host.isEmpty ? "adres bilinmiyor" : tv.host)"
            if tv.host.isEmpty { targetState = .warn }
        } else {
            target = "TV seçilmedi"
            targetState = .warn
        }
        dashboard.chipTarget.set(target, state: targetState)

        let profile = profilePopup.titleOfSelectedItem ?? "1080p60"
        dashboard.chipChannel.set("\(profile) · \(engine.isRunning ? "yayında" : "boşta")",
                                  state: engine.isRunning ? .ok : .idle)
    }

    /// Düğmenin etiketi ve zemini tek yerden: yayın YOKKEN yeşil "Başlat", VARken kırmızı "Durdur".
    /// Zeminsiz (isBordered=false) düğmede başlık rengi varsayılan koyu kalabildiği için beyaz
    /// ve ortalanmış bir atfedilmiş başlık kullanılır.
    private func setRunTitle(_ text: String) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        startStop.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .paragraphStyle: style,
        ])
        startStop.layer?.backgroundColor = (engine.isRunning ? NSColor.systemRed : NSColor.systemGreen).cgColor
    }

    /// Ekran dizilimini canlı yazar: sanal ekran açıldıkça konumu değişebiliyor.
    private func refreshScreensNote() {
        let screens = NSScreen.screens.map { ScreenLayout.Screen(name: $0.localizedName, frame: $0.frame) }
        screensNote.stringValue = ScreenLayout.describe(screens, tvName: TvDisplay.name)
    }

    private func render(_ s: MirrorEngine.Stats) {
        dashboard.setStats(s)
        if tvDisplayMode { refreshScreensNote() }
        setStatus(streamNotice ?? "Yayında")
        guard engine.isRunning else { return }
        if let notice = streamNotice {
            dashboard.setSummary(notice, .warn)
        } else {
            let trouble = s.nackRequests + s.dropped
            // "sağlam" demiyoruz: hareketsiz pencerede kare gelmez, bu arıza değil. Yalnız
            // kayıp sayısı hüküm verir.
            dashboard.setSummary("Akış açık · \(Int(s.seconds)) sn · \(DashboardView.grouped(s.packets)) paket ·"
                                 + " kayıp \(trouble) · \(String(format: "%.1f", s.fps)) fps",
                                 trouble == 0 ? .ok : .warn)
        }
    }

    /// Rozet rengi **yayın durumundan** gelir, metinden değil: metin geçici uyarıları da
    /// gösterebildiği için ("Akış takıldı" gibi) renk yalan söylemesin — yeşil = yayında,
    /// kırmızı = yayında değil.
    private func setStatus(_ text: String) {
        statusText.stringValue = text
        statusPill.layer?.backgroundColor = (engine.isRunning ? NSColor.systemGreen : NSColor.systemRed).cgColor
    }

    /// Ekran Kaydı iznini bekler ve verildiği anda listeyi tazeler.
    ///
    /// Ölçülen kusur: tek atışlık kontrol, kullanıcı Sistem Ayarları'nda anahtarı **açtıktan
    /// sonra da** "izin yok" diyordu (macOS anahtar değişiminde uygulamayı kapattığı için
    /// süreç zaten ölüyordu; açık kaldığında da yeniden bakılmıyordu). Şimdi istek tetiklenir,
    /// sonra veriliş yoklanır.
    private func checkPermission() {
        Task { @MainActor in
            if await WindowCapture.isGranted() { return }
            // Sistem izni isteği bloklayan bir çağrıdır ve pencere arkada kalabiliyor:
            // kullanıcıya önce ne beklendiği söylenir (ölçüldü: log satırsız bekleyiş
            // "uygulama izni okumuyor" gibi görünüyordu).
            log("Ekran Kaydı izni isteniyor: sistem penceresi ekranda bekleyebilir, arkaya düşmüşse Sistem Ayarları → Gizlilik ve Güvenlik → Ekran Kaydı.")
            WindowCapture.requestFromSystem()
            if await WindowCapture.isGranted() {
                note("Ekran Kaydı izni verildi — pencere listesi yenileniyor")
                await refreshWindows(keepSelection: true)
                return
            }
            note("Ekran Kaydı izni bekleniyor: Sistem Ayarları → Gizlilik ve Güvenlik → Ekran Kaydı → PaneCast", .warn)
            dashboard.setSummary("Ekran Kaydı izni bekleniyor — anahtarı açınca liste kendiliğinden dolar.", .warn)
            if await WindowCapture.wait(forGrant: 240) {
                note("Ekran Kaydı izni alındı — pencere listesi yenileniyor")
                dashboard.setSummary("Hazır — soldan pencere, sağdan TV seç.", .idle)
                await refreshWindows(keepSelection: true)
            } else {
                note("Ekran Kaydı izni hâlâ yok. Anahtarı açtıysan PaneCast'ı kapatıp yeniden aç (macOS izin değişimde uygulamayı yeniden başlatmak isteyebiliyor).", .error)
            }
        }
    }

    /// Aynı paket kimliğiyle diskte birden çok kopya ya da çalışıyor ikinci örnek var mı?
    /// Ölçülen kusur: geliştirme kopyası (`artifacts/build`) ile kurulu kopya aynı anda
    /// kayıtlıyken Ekran Kaydı izni hangisine verildi şaşıyor, TV'nin geri kanalı (7610) ve
    /// yoklama kanalı (7611) çakışıyor; kullanıcı "verdiğim izni okumuyor" durumuna düşüyordu.
    private func warnAboutCopies() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let paths = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).map(\.path)
        if paths.count > 1 {
            note("\(paths.count) PaneCast kopyası kayıtlı — izin ve TV kanalları karışır. Tek kopyayı kullan; diğerini klasörden çıkar.", .warn)
        }
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == id && $0.processIdentifier != mine
        }
        if !others.isEmpty {
            note("PaneCast zaten çalışıyor (pid \(others.map { String($0.processIdentifier) }.joined(separator: ", "))) — iki örnek aynı TV kanallarını paylaşamaz.", .warn)
        }
    }

    // ---------- diyaloglar ----------

    private func askPin() async -> String? {
        let a = NSAlert()
        a.messageText = "TV ekranındaki PIN"
        a.informativeText = "Android TV'de görünen 6 haneli kodu gir. Kod ağ üzerinden gönderilmez, yalnız sen yazarsın."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 26))
        field.placeholderString = "123456"
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        a.accessoryView = field
        a.addButton(withTitle: "Eşleştir")
        a.addButton(withTitle: "Vazgeç")
        window.makeKeyAndOrderFront(nil)
        field.stringValue = ""
        window.makeFirstResponder(field)
        let r = a.runModal()
        guard r == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespaces)
    }

    private func alert(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: "Tamam")
        a.runModal()
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Satır: simge + uygulama — başlık + boyut/durum.
@MainActor
final class WindowCell: NSTableCellView {
    private let icon = NSImageView()
    private let primary = NSTextField(labelWithString: "")
    private let secondary = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        primary.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        primary.lineBreakMode = .byTruncatingHead
        primary.translatesAutoresizingMaskIntoConstraints = false
        secondary.font = NSFont.systemFont(ofSize: 10)
        secondary.textColor = .secondaryLabelColor
        secondary.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon); addSubview(primary); addSubview(secondary)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            primary.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            primary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            primary.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            secondary.leadingAnchor.constraint(equalTo: primary.leadingAnchor),
            secondary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            secondary.topAnchor.constraint(equalTo: primary.bottomAnchor, constant: 2),
        ])
        self.imageView = icon
        self.textField = primary
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Seçim mavi vurgu üstünde soluk ikincil satır okunmuyor: AppKit'in verdiği
    /// arka plan stiline göre renk değişir.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { secondary.textColor = backgroundStyle == .emphasized ? .white : .secondaryLabelColor }
    }

    func fill(w: WindowInfo, streaming: Bool) {
        primary.stringValue = "\(w.app) — \(w.title)"
        let boyut = "\(Int(w.frame.width))×\(Int(w.frame.height))"
        secondary.stringValue = streaming ? "● YAYINDA · \(boyut)" : boyut
        secondary.textColor = streaming ? .controlAccentColor : .secondaryLabelColor
        icon.image = NSWorkspace.shared.runningApplications
            .first { $0.localizedName == w.app }?.icon
            ?? NSImage(named: NSImage.multipleDocumentsName)
        toolTip = "\(w.app)\n\(w.title)\n\(boyut)"
    }
}

/// Satır: TV adı + adres + eşleşme durumu.
@MainActor
final class DeviceCell: NSTableCellView {
    private let primary = NSTextField(labelWithString: "")
    private let secondary = NSTextField(labelWithString: "")
    private var baseSecondaryColor: NSColor = .secondaryLabelColor

    init() {
        super.init(frame: .zero)
        primary.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        primary.lineBreakMode = .byTruncatingTail
        primary.translatesAutoresizingMaskIntoConstraints = false
        secondary.font = NSFont.systemFont(ofSize: 10)
        secondary.textColor = .secondaryLabelColor
        secondary.translatesAutoresizingMaskIntoConstraints = false
        addSubview(primary); addSubview(secondary)
        NSLayoutConstraint.activate([
            primary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            primary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            primary.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            secondary.leadingAnchor.constraint(equalTo: primary.leadingAnchor),
            secondary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            secondary.topAnchor.constraint(equalTo: primary.bottomAnchor, constant: 3),
        ])
        self.textField = primary
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { secondary.textColor = backgroundStyle == .emphasized ? .white : baseSecondaryColor }
    }

    func fill(tv: DiscoveredTV, liveTwin: Bool = false) {
        let paired = KeyStore.isPaired(tv.host)
        primary.stringValue = (paired ? "✓ " : "○ ") + tv.displayName
        let renk: NSColor
        if tv.host.isEmpty {
            secondary.stringValue = "adres çözümlenemedi — TV'yi bul / yeniden tara'ya bas ya da adresi elle gir"
            renk = .systemRed
        } else if paired {
            secondary.stringValue = "\(tv.host):\(tv.controlPort) · eşleşmiş · "
                + (tv.online ? "açık (\(tv.source.label))"
                             : liveTwin ? "eski adres — bu TV başka adreste açık, temizlemek için seç ve 'Eşleştirmeyi unut'a bas"
                                        : "TV'de uygulama kapalı")
            renk = tv.online ? .systemGreen : (liveTwin ? .systemOrange : .secondaryLabelColor)
        } else if tv.tvReportsPaired {
            // TV kendi tarafında eşleşmiş sayıyor (anahtar onun da üzerinde); Mac'te yoksa
            // akış sessizce PIN turuna düşer — nedeni satırda yazılı durur.
            secondary.stringValue = "\(tv.host):\(tv.controlPort) · TV eşleşmiş sayıyor, bu Mac'te anahtar yok · çift tıkla: PIN"
            renk = .systemOrange
        } else {
            secondary.stringValue = "\(tv.host):\(tv.controlPort) · EŞLEŞMEMİŞ · "
                + (tv.online ? "açık (\(tv.source.label)) — çift tıkla: PIN gir" : "kapalı")
            renk = tv.online ? .systemRed : .secondaryLabelColor
        }
        baseSecondaryColor = renk
        secondary.textColor = backgroundStyle == .emphasized ? .white : renk
    }
}

/// İçeriği taşıyan kök görünüm: pencere yeniden boyutlandığında çerçevelerin yeniden
/// hesaplanması için bir geri çağırma verir (`layout()` AppKit'te her boyut değişiminde koşar).
private final class RootView: NSView {
    var onLayout: ((NSSize) -> Void)?
    override func layout() {
        super.layout()
        onLayout?(bounds.size)
    }
}

@MainActor
func runGUI() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    StopSignals.install { DispatchQueue.main.async { NSApp.terminate(nil) } }     // SIGINT/SIGTERM de aynı temiz kapanış
    app.run()
}
