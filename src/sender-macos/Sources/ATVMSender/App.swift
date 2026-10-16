import AppKit
import CoreGraphics

/// Pane Cast macOS arayüzü.
///
/// Düzen: sabit başlık sırası + kaydırılabilir gövde. Gövdede solda yayınlanacak pencere
/// listesi (arama sırası + liste + kalite/Başlat sırası), sağda hedef TV listesi (adres sırası +
/// liste + tarama/eşleşme sırası), altta iki sütunun da ortak kullandığı ipucu satırı ve pano.
/// İki sütun **aynı ızgarayı** paylaşır: arama sırası ile adres sırası, bölüm etiketleri,
/// listelerin üst ve alt kenarları, ikişer kontrol satırı hep hizalıdır (kullanıcı isteği:
/// "hepsi birbirine orantılsın"). TV ekranı modunda sol sütunun liste alanı aynı çerçevede
/// ekran haritası paneline dönüşür. "Olaylar" pano içinde açılmaz: ayrı bir ekrandır.
/// Pencere küçültüldüğünde gövde sabit bir alt boyutun altına inmez, dikey + yatay
/// kaydırma çubukları çıkar (kullanıcı isteği: "kullanıcı kaydıramıyor içeriği").
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
    private let statusText = NSTextField(labelWithString: L10n.t(.uiStatusReady))
    private let windowTable = NSTableView()
    private let deviceTable = NSTableView()
    private let search = NSSearchField()
    private let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let startStop = NSButton()
    private let manualIP = NSTextField(string: "")
    /// Alt bölgenin panosu: durum çipleri, ölçü kutuları + mini grafikler, tek satır özet,
    /// olaylar düğmesi. Metin duvarının yerine geçer (kullanıcı isteği + Apple "Charting data").
    private let dashboard = DashboardView(frame: .zero)
    /// Olay ekranı: panodaki düğme bunu açar; üstte elzem durum, altta tam liste.
    private let eventsPage = EventsPageView(frame: .zero)
    /// Gövdenin kaydırma kapsayıcısı ve içindeki ızgara.
    /// Bölüm etiketleri ve düğmeler: yazıları anahtardan gelir, dil geçişinde yeniden çözülür.
    private var sectionLabels: [(NSTextField, TextKey)] = []
    private var labeledButtons: [(NSButton, TextKey)] = []
    /// İpucu satırı ve keşif çipi: son değerleri anahtar/sayım olarak durur, dil
    /// geçişinde yeniden çözülür (ölçülen kusur: canlı geçişte bu iki satır İngilizce kaldı).
    private var hintKey: TextKey?
    private var lastDiscovery = (count: 0, paired: 0)
    private let bodyScroll = NSScrollView()
    private let board = LayoutView(frame: .zero)
    /// Arayüz olay defteri: aynı satır ×N olarak katlanır. Ham satırlar yine günlük dosyasına yazılır.
    private let events = EventBook()
    /// Pencere yeniden boyutlandığında çerçeveleri baştan hesaplayan kök görünüm.
    private var root: LayoutView!
    private var titleLabel = NSTextField(labelWithString: "Pane Cast")
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
    private let modeControl = NSSegmentedControl(labels: [L10n.t(.uiModeWindow), L10n.t(.uiModeTvScreen)],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    /// Tema seçimi: varsayılan "Sistem" (Açık/Koyu'yu macOS ayarından izler). Katman
    /// renkleri elle çözüldüğü için bu kutu aynı zamanda temanın canlı test edilmesini sağlar.
    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Dil seçimi: Sistem (macOS'un bu uygulama için seçtiği dil) | English | Türkçe.
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Dil geçişinde sabit yazılar yeniden çözülür.
    private var languageWatch: LanguageWatch?
    /// TV ekranı modunun sol sütunu: ekran haritası + açıklama (boş metin bloğu değil).
    private let tvPanel = TVScreenPanelView(frame: .zero)
    /// Yalnız TV ekranı modunda görünen görünümler.
    private var tvModeViews: [NSView] = []
    /// Pencere listesi modunda görünen, TV ekranı modunda gizlenen görünümler.
    private var windowModeViews: [NSView] = []
    private var tvDisplayMode: Bool { modeControl.selectedSegment == 1 }
    /// Olay ekranı açık mı (gövde o sırada gizli).
    private var showingEvents = false

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
    /// Özet satırında kullanıcıdan gelen bir hata duruyor mu? Sebep çözülene kadar kalkmamalı,
    /// çözüldüğünde kendiliğinden silinmeli (ölçülen kusur: hata 20 sn'de bir kayboluyordu).
    private var summaryIsError = false
    /// Olay ekranındaki "elzem" satırı için son ölçüm (yayın durunca sıfırlanmaz, etiket düşer).
    private var lastStats: MirrorEngine.Stats?
    /// Ağ yükü şeridinin üç paydası: RTP çıkışı, Mac kartı, modem/WAN.
    private let interfaceSampler = InterfaceSampler()
    private let modem = ModemLoad()
    private var netTimer: Timer?
    private var castMbps: Double?
    private var lastWireBytes: Int?
    private var lastWireAt: Date?
    private var wifiMbps: Double?
    /// Yayının gittiği arabirim; hedef adres değişince yeniden çözülmeli.
    private var routeInterface: String?
    private var routeHost: String?
    private var netTick = 0
    /// Son Mac kartı örneği: modem/others geri çağırması şeridi yeniden çizerken kaybolmasın.
    private var lastMacSample: (inbound: Double?, outbound: Double?)?

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
                // Arayüz de durdurulan yayının arkasından sıfırlanmalı: rozet/düğme tek
                // başına tazelenince özet satırı "Akış açık"ta kalıyordu.
                self.setSummary(.summaryReady, .idle)
                self.summaryIsError = false
                self.note(.evtStoppedByTv)
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
        // Ağ yükü şeridi 1 sn'de bir tazelenir (benzeri yoklamalar ucuz: işletim sayacı +
        // CoreWLAN). Modem yoklaması kendi ritminde koşar: `ModemPollPolicy` (tur arası en az
        // 2 sn, başarısızlıkta 5→60 sn geri çekilme) — yoksa her saniye iki HTTP isteği ve
        // modem yanıtlamadığında her saniye SSDP yayını demekti.
        netTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tickNetLoad() }
        }
        NSApp.activate(ignoringOtherApps: true)
        languageWatch = LanguageWatch { [weak self] in self?.applyLanguage() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    /// Çıkışta yayın temiz kapatılır: uygulama ses tap'i yıkılır (Mac sesi geri gelir),
    /// kodlayıcı/soketler serbest kalır, TV'ye durdurma bildirilir. Bitince çıkış onaylanır.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let tvHost = tvInitiatedHost
        Task { @MainActor in
            await engine.stop()
            if let tvHost { advertised.notifyStopped(host: tvHost) }
            InstanceGuard.releaseLock()      // tek örnek kilidi bırak: yeniden açılabilir olsun
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // ---------- arayüz ----------

    /// Izgaranın sabitleri: tek yerde dursun ki "orantısız" şikâyeti tekrar doğmasın.
    private enum Grid {
        static let pad: CGFloat = 16          // gövde kenar boşluğu
        static let gap: CGFloat = 16          // iki sütun arası
        static let maxContent: CGFloat = 1240 // bu genişlikten sonra içerik ortalanır
        static let toolbarH: CGFloat = 28
        static let sectionH: CGFloat = 16
        static let listMinH: CGFloat = 170
        static let bandRow1H: CGFloat = 30
        static let bandRow2H: CGFloat = 34
        static let hintH: CGFloat = 34
        static let headerH: CGFloat = 46
        /// Liste hariç sabit dikey maliyet: üst bloklar (76) + alt bloklar (142) + pad (16).
        static let fixedH: CGFloat = 76 + 142 + 16
        static let boardMinW: CGFloat = 700
        /// Kaydırma çubukları için ayrılan pay: çubuk çıktığında içerik çubuğun altında kalmasın.
        static let gutter: CGFloat = 16
    }

    private func buildUI() {
        let content = LayoutView(frame: NSRect(x: 0, y: 0, width: 1180, height: 760))
        root = content
        content.onLayout = { [weak self] size in self?.layoutRoot(size) }
        content.onAppearance = { [weak self] in self?.refreshRunButton() }

        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        content.addSubview(titleLabel)

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

        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        content.addSubview(modeControl)

        themePopup.addItems(withTitles: [L10n.t(.uiThemeSystem), L10n.t(.uiThemeLight), L10n.t(.uiThemeDark)])
        let saved = Self.appearanceChoice.flatMap { ["system", "aqua", "darkAqua"].firstIndex(of: $0) } ?? 0
        themePopup.selectItem(at: saved)
        themePopup.target = self
        themePopup.action = #selector(themeChanged)
        themePopup.setAccessibilityLabel(L10n.t(.uiThemeA11y))
        themePopup.toolTip = L10n.t(.uiThemeTooltip)
        content.addSubview(themePopup)
        applyAppearance()

        // Dil kutusu: tema kutusuyla aynı düzende, onun solunda. "Sistem" seçeneği
        // macOS'un uygulama-dili ayarını izler; iki seçenek dili elle sabitler.
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.setAccessibilityLabel(L10n.t(.uiLangA11y))
        languagePopup.toolTip = L10n.t(.uiLangTooltip)
        content.addSubview(languagePopup)
        reloadLanguageItems()
        applyAppearance()

        // ---------- gövde: kaydırılabilir ızgara ----------
        bodyScroll.hasVerticalScroller = true
        bodyScroll.hasHorizontalScroller = true
        bodyScroll.autohidesScrollers = true
        // Overlay çubuk yerine gerçek (legacy) çubuk: kullanıcı "kaydırma çubuğu istiyorum" dedi;
        // overlay çubuğu yalnız imleç üzerinde görünüyordu.
        bodyScroll.scrollerStyle = .legacy
        bodyScroll.borderType = .noBorder
        bodyScroll.drawsBackground = false
        bodyScroll.documentView = board
        content.addSubview(bodyScroll)

        windowSection = section(.uiSectionWindows)
        board.addSubview(windowSection)
        search.placeholderString = L10n.t(.uiSearchPlaceholder)
        search.delegate = self
        search.target = self
        search.action = #selector(filterChanged)
        board.addSubview(search)
        refreshButton = button(.uiBtnRefresh) { [weak self] in
            Task { await self?.refreshWindows(keepSelection: false) }
        }
        board.addSubview(refreshButton)

        configureTable(windowTable, column: Self.winColumn, width: 380)
        windowScroll.hasVerticalScroller = true
        windowScroll.borderType = .bezelBorder
        windowScroll.documentView = windowTable
        board.addSubview(windowScroll)
        windowModeViews = [windowSection, search, refreshButton, windowScroll]

        // TV ekranı modu: aynı çerçevede panel (harita + açıklama) + araç sırasına hizalı düğme.
        arrangeButton = button(.uiBtnArrange) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        arrangeButton.isHidden = true
        board.addSubview(arrangeButton)
        tvPanel.isHidden = true
        board.addSubview(tvPanel)
        tvModeViews = [tvPanel, arrangeButton]
        refreshScreensNote()

        deviceSection = section(.uiSectionTv)
        board.addSubview(deviceSection)
        configureTable(deviceTable, column: Self.devColumn, width: 260)
        deviceScroll.hasVerticalScroller = true
        deviceScroll.borderType = .bezelBorder
        deviceScroll.documentView = deviceTable
        board.addSubview(deviceScroll)

        findButton = button(.uiBtnFindTv) { [weak self] in
            Task { await self?.refreshTVs() }
        }
        board.addSubview(findButton)
        manualIP.placeholderString = L10n.t(.uiManualIp)
        board.addSubview(manualIP)
        addButton = button(.uiBtnAdd) { [weak self] in
            self?.addManualDevice()
        }
        board.addSubview(addButton)
        forgetButton = button(.uiBtnForget) { [weak self] in
            Task { await self?.forgetPairing() }
        }
        board.addSubview(forgetButton)
        windowHint.font = NSFont.systemFont(ofSize: 11)
        windowHint.textColor = .secondaryLabelColor
        windowHint.maximumNumberOfLines = 2
        windowHint.lineBreakMode = .byWordWrapping
        board.addSubview(windowHint)

        profilePopup.addItems(withTitles: ["1080p60 (12 Mbps)", "1080p30 (8 Mbps)", "720p60 (6 Mbps)"])
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged)
        board.addSubview(profilePopup)

        // Bezel yerine kendi zemin rengimiz: durum renk olarak anında okunsun (yeşil/kırmızı).
        startStop.isBordered = false
        startStop.bezelStyle = .regularSquare
        startStop.wantsLayer = true
        startStop.layer?.cornerRadius = 8
        startStop.keyEquivalent = "\r"
        startStop.target = self
        startStop.action = #selector(toggleRun)
        board.addSubview(startStop)
        setRunTitle(L10n.t(.uiBtnStart))

        board.addSubview(dashboard)
        dashboard.clearStats()
        dashboard.onOpenEvents = { [weak self] in self?.setEventsShown(true) }
        // Modem yoklaması: kullanıcı isteğiyle varsayılan açık, tercih hatırlanıyor.
        let probeOn = UserDefaults.standard.object(forKey: Self.modemProbeKey) as? Bool ?? true
        modem.setEnabled(probeOn)
        dashboard.netStrip.modemToggle.state = probeOn ? .on : .off
        dashboard.netStrip.onToggleModem = { [weak self] on in
            guard let self else { return }
            UserDefaults.standard.set(on, forKey: Self.modemProbeKey)
            self.modem.setEnabled(on)
            self.note(on ? L10n.t(.evtProbeOn) : L10n.t(.evtProbeOff),
                      on ? .info : .warn)
        }
        modem.onChange = { [weak self] in self?.renderNetStrip() }

        eventsPage.isHidden = true
        eventsPage.onBack = { [weak self] in self?.setEventsShown(false) }
        eventsPage.onClear = { [weak self] in
            guard let self else { return }
            self.events.clear()
            self.dashboard.reloadEvents(self.events.rows, groups: 0, lines: 0)
            self.refreshEventsPage()
        }
        eventsPage.onOpenLog = {
            // Katlamasız ham satırlar: arayüz grubunun kaynağı dosyada durur.
            NSWorkspace.shared.open(logFile)
        }
        content.addSubview(eventsPage)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Pane Cast"
        // Sürüm başlık çubuğunda: hangi kopyanın koştuğu tek bakışta görünsün
        // (izin de imzaya bağlı olduğundan "yanlış kopya" sorusu buradan cevaplanıyor).
        window.subtitle = BuildInfo.tag
        window.contentView = content
        // Gövde artık kaydırılabiliyor: pencere alt sınırı ızgaranın alt sınırından küçük olabilir,
        // böylece küçük ekranda dikey + yatay çubuklar gerçekten çıkar (kullanıcı isteği).
        window.minSize = NSSize(width: 560, height: 440)
        placeOnCursorScreen()
        window.makeKeyAndOrderFront(nil)
    }

    /// Gövde ızgarasının **inmesi gereken** en küçük yükseklik: iki sütun listesi okunur
    /// kalırken pano katışık hâle düşer (ölçü kutuları kalkar).
    private func boardMinHeight(forWidth width: CGFloat) -> CGFloat {
        let usable = max(360, min(Grid.maxContent, width) - 2 * Grid.pad)
        return Grid.fixedH + Grid.listMinH
            + DashboardView.requiredHeight(width: usable, tileH: 0, tiles: 0)
    }

    /// Başlık sırası + gövde kaydırıcısı + olay ekranı: pencere boyutundan ızgara boyutunu üretir.
    private func layoutRoot(_ size: NSSize) {
        let w = size.width, h = size.height
        let inset = max(Grid.pad, (w - Grid.maxContent) / 2)
        titleLabel.sizeToFit()
        let titleW = max(96, titleLabel.frame.width + 8)
        titleLabel.frame = NSRect(x: inset, y: 10, width: titleW, height: 26)
        // Mod düğmesi **doğal genişliğini** alır: İngilizce etiket ("TV screen (separate
        // display)") 330 px'lık paya sığmıyor ve dil kutusunun üstüne biniyordu (ölçüldü).
        // Sığışmazsa önce tema, sonra dil kutusu düşer; kırpılan taraf asla düğme olmaz.
        modeControl.sizeToFit()
        let modeW = max(180, modeControl.frame.width)
        modeControl.frame = NSRect(x: inset + titleW + 12, y: 10, width: modeW, height: 26)
        statusPill.frame = NSRect(x: w - inset - 180, y: 12, width: 180, height: 24)
        let controlW: CGFloat = 150
        let controlsRight = w - inset - 180 - 8
        let rightOfMode = inset + titleW + 12 + modeW + 12
        let langShows = controlsRight - controlW >= rightOfMode
        let themeShows = langShows && controlsRight - controlW - 8 - controlW >= rightOfMode
        themePopup.isHidden = !themeShows
        languagePopup.isHidden = !langShows
        if langShows {
            languagePopup.frame = NSRect(x: controlsRight - controlW, y: 10, width: controlW, height: 26)
        }
        if themeShows {
            themePopup.frame = NSRect(x: controlsRight - controlW - 8 - controlW, y: 10,
                                      width: controlW, height: 26)
        }

        let availW = w
        let availH = max(80, h - Grid.headerH)
        bodyScroll.frame = NSRect(x: 0, y: Grid.headerH, width: availW, height: availH)
        eventsPage.frame = bodyScroll.frame
        // Çubuk payını düşerek hesapla: çubuk çıktığında içerik onun altında kalmasın.
        let docW = max(Grid.boardMinW, availW - Grid.gutter)
        let docH = max(boardMinHeight(forWidth: docW), availH - Grid.gutter)
        board.frame = NSRect(x: 0, y: 0, width: docW, height: docH)
        layoutBoard(NSSize(width: docW, height: docH))
    }

    /// Pencere boyutuna göre tüm çerçeveleri baştan hesaplar.
    ///
    /// Ölçülen kusur: eskiden sütunlar ve satırlar ayrı ayrı sabit koordinatlarla konuyordu;
    /// arama kutusu ile sağdaki adres kutusu, iki listenin alt kenarı ve "Ekranları Düzenle…"
    /// düğmesi birbirine uymuyordu. Şimdi tek bir satır sırası iki sütuna birden uygulanır:
    /// araç sırası → bölüm etiketi → liste (eşit üst/alt) → iki kontrol satırı → ortak ipucu → pano.
    private func layoutBoard(_ size: NSSize) {
        let w = size.width, h = size.height
        let inset = max(Grid.pad, (w - Grid.maxContent) / 2)
        let usable = max(360, w - 2 * inset)
        let leftW = max(300, ((usable - Grid.gap) * 0.58).rounded())
        let rightW = max(230, usable - Grid.gap - leftW)
        let leftX = inset, rightX = inset + leftW + Grid.gap

        // Pano yüksekliği içerikten gelir; kalan yer listelere dağıtılır.
        // Sığmazsa önce grafik çizgisi düşer, sonra ölçü kutuları tamamen kalkar.
        let space = max(Grid.listMinH, h - Grid.fixedH)     // liste + pano
        let needFull = DashboardView.requiredHeight(width: usable, tileH: DashboardView.tileHeight, tiles: 5)
        let needShort = DashboardView.requiredHeight(width: usable, tileH: DashboardView.shortTileHeight, tiles: 5)
        dashboard.compact = space - Grid.listMinH < needShort
        dashboard.compactTiles = !dashboard.compact && space - Grid.listMinH < needFull
        // Yüksekliği panonun kendi hesabından al: karar ile çerçeve aynı kaynaktan gelsin.
        let dashH = dashboard.neededHeight(forWidth: usable)
        let listH = max(Grid.listMinH, space - dashH)

        let toolbarY: CGFloat = Grid.pad
        let sectionY = toolbarY + Grid.toolbarH + 10
        let listTop = sectionY + Grid.sectionH + 6
        let bandY = listTop + listH + 12
        let hintY = bandY + Grid.bandRow1H + 8 + Grid.bandRow2H + 10
        let dashY = hintY + Grid.hintH + 14

        // ---- sol sütun (pencere listesi) / TV ekranı paneli ----
        windowSection.frame = NSRect(x: leftX, y: sectionY, width: leftW, height: Grid.sectionH)
        let refreshW: CGFloat = 88
        search.frame = NSRect(x: leftX, y: toolbarY, width: max(120, leftW - refreshW - 8), height: Grid.toolbarH)
        refreshButton.frame = NSRect(x: leftX + leftW - refreshW, y: toolbarY, width: refreshW, height: Grid.toolbarH)
        windowScroll.frame = NSRect(x: leftX, y: listTop, width: leftW, height: listH)

        // TV ekranı modunda araç sırası boş kalmasın: düğme arama sırasıyla **aynı** satırda.
        arrangeButton.frame = NSRect(x: leftX, y: toolbarY, width: leftW, height: Grid.toolbarH)
        // Panel, pencere listesiyle birebir aynı çerçeveyi kaplar → kenarlar her boyutta hizalı.
        tvPanel.frame = NSRect(x: leftX, y: listTop, width: leftW, height: listH)

        profilePopup.frame = NSRect(x: leftX, y: bandY + 1, width: min(220, leftW), height: 26)
        startStop.frame = NSRect(x: leftX, y: bandY + Grid.bandRow1H + 8, width: leftW, height: Grid.bandRow2H)

        // ---- sağ sütun (hedef TV) ----
        deviceSection.frame = NSRect(x: rightX, y: sectionY, width: rightW, height: Grid.sectionH)
        let addW: CGFloat = 92
        manualIP.frame = NSRect(x: rightX, y: toolbarY + 1, width: max(110, rightW - addW - 8), height: 26)
        addButton.frame = NSRect(x: rightX + rightW - addW, y: toolbarY, width: addW, height: Grid.toolbarH)
        deviceScroll.frame = NSRect(x: rightX, y: listTop, width: rightW, height: listH)
        findButton.frame = NSRect(x: rightX, y: bandY, width: rightW, height: Grid.bandRow1H)
        forgetButton.frame = NSRect(x: rightX, y: bandY + Grid.bandRow1H + 8, width: rightW, height: Grid.bandRow2H)

        // ---- iki sütunun ortak satırları ----
        windowHint.frame = NSRect(x: leftX, y: hintY, width: usable, height: Grid.hintH)
        dashboard.frame = NSRect(x: leftX, y: dashY, width: usable, height: dashH)
    }

    // ---------- olay ekranı ----------

    private func setEventsShown(_ on: Bool) {
        showingEvents = on
        eventsPage.isHidden = !on
        bodyScroll.isHidden = on
        refreshEventsPage(resetScroll: true)
        if on { window.makeFirstResponder(window.contentView) }
    }

    /// Elzem bilgiler üstte: rozetteki durum + kanal + son ölçüm + ham günlük yolu.
    private func refreshEventsPage(resetScroll: Bool = false) {
        guard showingEvents else { return }
        let channel = profilePopup.titleOfSelectedItem ?? "—"
        let measured: String
        if let s = lastStats, engine.isRunning {
            // Ölçülen kusur: `String(format:)` içinde "%RTP" yazılıp bozuk dönüşüm olarak
            // yorumlandı ve sayılar kaydı. Sayılar önce ayrı ayrı biçimlendirilir, metin sonra
            // katalog şablonuna girer (şablondaki tek gösterici %% değil, %1$@ olabilir).
            measured = L10n.f(.eventsMeasured, L10n.number(s.fps), L10n.number(s.mbps),
                              DashboardView.grouped(s.packets),
                              L10n.int(s.nackRequests + s.dropped))
        } else {
            measured = L10n.t(.tileNoMeasurements)
        }
        let status = L10n.f(.eventsStatusLine, statusText.stringValue, channel, measured)
        let counts = L10n.f(.eventsCounts, dashboard.summaryText,
                             L10n.int(events.groupCount), L10n.int(events.lineCount), BuildInfo.tag)
        eventsPage.openLog.toolTip = L10n.f(.eventsRawLogTip, logFile.path)
        eventsPage.show(rows: events.rows, status: status, counts: counts,
                        tone: dashboard.summaryTone, resetScroll: resetScroll)
    }

    /// Alt bilgi satırının tek yazım yeri: anahtar saklanır, serbest yazıda sıfırlanır.
    private func setHint(_ key: TextKey?) {
        hintKey = key
        windowHint.stringValue = key.map { L10n.t($0) } ?? ""
    }

    private func setHint(_ text: String) {
        hintKey = nil
        windowHint.stringValue = text
    }

    /// Keşif çipi: "1 TV · 1 eşleşmiş" yazısı son sayımdan yeniden çözülür.
    private func renderDiscoveryChip() {
        let (count, paired) = lastDiscovery
        dashboard.chipDiscovery.set(count == 0 ? L10n.t(.tileNoBroadcast)
                                               : L10n.f(.chipDiscoveryCount, L10n.int(count), L10n.int(paired)),
                                    state: count == 0 ? .idle : .ok)
    }

    private func section(_ key: TextKey) -> NSTextField {
        let l = NSTextField(labelWithString: L10n.t(key))
        sectionLabels.append((l, key))
        l.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byTruncatingTail
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

    /// Pencereyi imlecin olduğu ekrana ortalar ve ekranın görünür alanına sığdırır.
    /// `window.center()` çok ekranlı düzende pencereyi görünmeyen ikincil ekrana bırakabiliyordu
    /// (ölçüldü: çerçeve x=2055, y=-250 → kullanıcı arayüzü göremedi).
    private func placeOnCursorScreen() {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let vis = screen.visibleFrame
        // Ekran küçükse pencereyi görünür alana sığdır: gövde zaten kaydırılıyor, ama
        // başlık sırası / Dock çizgisi kesilmesin.
        let size = NSSize(width: min(window.frame.width, vis.width - 32),
                          height: min(window.frame.height, vis.height - 32))
        window.setContentSize(size)
        let x = max(vis.minX, min(vis.midX - size.width / 2, vis.maxX - size.width))
        let y = max(vis.minY, min(vis.midY - size.height / 2, vis.maxY - size.height))
        window.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    private func button(_ key: TextKey, _ action: @escaping () -> Void) -> NSButton {
        let b = NSButton(frame: .zero)
        b.title = L10n.t(key)
        b.bezelStyle = .rounded
        b.setAccessibilityLabel(L10n.t(key))
        labeledButtons.append((b, key))
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
    /// Bu satırlar bilinçli olarak tek dilde (Türkçe) kalıyor: ham günlük geliştirici
    /// çıktısıdır, çeviri kaydı arayüz + olay ekranıdır (`note`). İki dilde tutulsalar
    /// satırın üretildiği andaki dile kilitlenir, sonraki çeviri dosyaya işlemezdi.
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
        refreshEventsPage()
    }

    /// Anahtarla yazılan olay: defter anahtarı saklar, satır dil değişince yeniden çözülür.
    private func note(_ key: TextKey, _ severity: EventSeverity = .info,
                      _ args: any CVarArg...) {
        emit(L10n.f(key, args))
        events.add(key, args, severity)
        dashboard.reloadEvents(events.rows, groups: events.groupCount, lines: events.lineCount)
        refreshEventsPage()
    }

    /// Özet satırının tek yazım yeri: pano + olay ekranının üst bilgisi aynı cümleyi görsün.
    private func setSummary(_ text: String, _ tone: DashboardView.Summary) {
        dashboard.setSummary(text, tone)
        refreshEventsPage()
    }

    private func setSummary(_ key: TextKey, _ tone: DashboardView.Summary,
                            _ args: any CVarArg...) {
        dashboard.setSummary(key, tone, args)
        refreshEventsPage()
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
            setStatus(L10n.t(.statusTvAddressUnknown))
            setHint(tv.online ? .hintTvNoAddress : .hintTvLooksOff)
            note(.evtPairRefusedNoAddress, .warn, tv.displayName, tv.online ? L10n.t(.wordYes) : L10n.t(.wordNo))
            return
        }
        guard tv.online else {
            setStatus(L10n.t(.statusTvOffline))
            setHint(.hintTvOpenApp)
            note(.evtPairRefusedOffline, .warn, tv.displayName)
            return
        }
        engine.setHost(tv.host)
        do {
            // Yerel kayda değil TV'nin yanıtına bakılır: eski sürümden taşınan anahtar
            // v2 TV'de geçersizdir ve TV yeniden PIN ister.
            let hs = try await engine.connectAndHello(host: tv.host)
            if hs == .paired {
                setStatus(L10n.t(.statusAlreadyPaired))
                note(.evtPairedAlready, .info, tv.displayName)
                log("eşleşme var: \(tv.displayName) — pencere seçip Başlat'a bas")
            } else {
                guard let pin = await askPin() else { await engine.stop(); return }
                try await engine.submitPin(pin)
                note(.evtPairDone, .info, tv.displayName, tv.host)
                setStatus(L10n.t(.statusPaired))
            }
            KeyStore.storeName(tv.name, for: tv.host)
            await engine.stop()
        } catch let e as ControlClient.ControlError {
            await engine.stop(); fail(L10n.t(.statusPairFailed), e.description)
        } catch {
            await engine.stop(); fail(L10n.t(.statusPairFailed), "\(error)")
        }
        refreshLists()
    }

    @objc private func filterChanged() { applyFilter() }

    /// Kalite profili değişti: çipler ve özet yeni kanalı göstersin (yayın sırasında da okunur).
    @objc private func profileChanged() {
        refreshRunButton()
        note(.evtChannelProfile, .info, profilePopup.titleOfSelectedItem ?? "—")
    }

    // ---------- tema ----------

    /// Kullanıcının seçimi: "system" (varsayılan) | "aqua" | "darkAqua".
    private static let appearanceKey = "appearance"
    private static var appearanceChoice: String? {
        UserDefaults.standard.string(forKey: appearanceKey)
    }

    /// Dil kutusunun satırları: her zaman görünen dilde ve aynı sırada (system, en, tr).
    private func reloadLanguageItems() {
        let before = L10n.choice
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: [L10n.t(.uiLangSystem), L10n.t(.uiLangEnglish),
                                            L10n.t(.uiLangTurkish)])
        languagePopup.selectItem(at: L10n.Language.allCases.firstIndex(of: before) ?? 0)
    }

    @objc private func languageChanged() {
        let pick = L10n.Language.allCases[languagePopup.indexOfSelectedItem]
        UserDefaults.standard.set(pick.rawValue, forKey: L10n.defaultsKey)
        reloadLanguageItems()
        L10n.setChoice(pick)
        note(.evtLanguageSet, .info, L10n.active.label)
    }

    /// Arayüzün sabit yazıları tek yerden yeniden çözülür: ölçümler zaten kendi tazelemesinde,
    /// karışabilir tek satırlar (ipucu/çip) de `refreshRunButton` ve 10–20 sn'lik turlarla gelir.
    private func applyLanguage() {
        for (label, key) in sectionLabels { label.stringValue = L10n.t(key) }
        for (button, key) in labeledButtons {
            button.title = L10n.t(key)
            button.setAccessibilityLabel(L10n.t(key))
            button.sizeToFit()
        }
        modeControl.setLabel(L10n.t(.uiModeWindow), forSegment: 0)
        modeControl.setLabel(L10n.t(.uiModeTvScreen), forSegment: 1)
        search.placeholderString = L10n.t(.uiSearchPlaceholder)
        manualIP.placeholderString = L10n.t(.uiManualIp)
        themePopup.removeAllItems()
        themePopup.addItems(withTitles: [L10n.t(.uiThemeSystem), L10n.t(.uiThemeLight), L10n.t(.uiThemeDark)])
        themePopup.selectItem(at: Self.appearanceChoice.flatMap { ["system", "aqua", "darkAqua"].firstIndex(of: $0) } ?? 0)
        themePopup.setAccessibilityLabel(L10n.t(.uiThemeA11y))
        themePopup.toolTip = L10n.t(.uiThemeTooltip)
        languagePopup.setAccessibilityLabel(L10n.t(.uiLangA11y))
        languagePopup.toolTip = L10n.t(.uiLangTooltip)
        dashboard.applyLanguage()
        eventsPage.applyLanguage()
        tvPanel.applyLanguage()
        reloadLanguageItems()
        windowTable.reloadData()
        deviceTable.reloadData()
        renderDiscoveryChip()
        if let hintKey { windowHint.stringValue = L10n.t(hintKey) }
        refreshRunButton()
        refreshEventsPage()
        root?.needsLayout = true
        window.contentView?.needsLayout = true
    }

    @objc private func themeChanged() {
        let pick = ["system", "aqua", "darkAqua"][themePopup.indexOfSelectedItem]
        UserDefaults.standard.set(pick, forKey: Self.appearanceKey)
        applyAppearance()
        note(.evtThemeSet, .info, themePopup.titleOfSelectedItem ?? pick)
    }

    /// Seçim uygulama görünümüne işlenir; "system" seçiliyken macOS ayarı izlenir.
    /// AppKit etkin görünüm değişen her görünüme `viewDidChangeEffectiveAppearance` çağırır;
    /// burada yalnız App'in kendi boyadığı katmanlar (rozet, Başlat düğmesi) tazelenir.
    private func applyAppearance() {
        let pick = ["system", "aqua", "darkAqua"][max(0, themePopup.indexOfSelectedItem)]
        NSApp.appearance = pick == "system" ? nil : NSAppearance(named: pick == "aqua" ? .aqua : .darkAqua)
        refreshRunButton()
    }


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
            note(.evtStopped)
            setSummary(.summaryReady, .idle)
            summaryIsError = false
            refreshRunButton()
        }
    }

    @objc private func modeChanged() {
        let tv = tvDisplayMode
        windowModeViews.forEach { $0.isHidden = tv }
        tvModeViews.forEach { $0.isHidden = !tv }
        setHint(tv ? nil : .hintPickWindow)
        refreshScreensNote()
        // Kaynak çipi moda göre değişiyor ("TV ekranı (ayrı ekran)"): yenilemezse çip eski
        // pencereyi göstermeye devam ediyordu (ölçüldü).
        refreshRunButton()
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
            setStatus(L10n.t(.statusNoTv))
            setHint(.hintNoTv)
            setSummary(.sumStartNoTv, .bad)
            summaryIsError = true
            note(.evtStartRefusedNoTv, .error)
            return
        }
        let row = windowTable.selectedRow
        guard tvDisplayMode || (row >= 0 && row < shown.count) else {
            setStatus(L10n.t(.statusNoWindow))
            setHint(.hintNoWindow)
            setSummary(.sumStartNoWindow, .bad)
            summaryIsError = true
            note(.evtStartRefusedNoWindow, .error)
            return
        }
        let source: MirrorEngine.CastSource = tvDisplayMode ? .tvDisplay : .window(shown[row])
        let profile = H264Encoder.Profile.presets[["1080p60", "1080p30", "720p60"][profilePopup.indexOfSelectedItem]]!
        engine.setHost(host)
        refreshRunButton()
        let what: String
        if case .window(let win) = source { what = win.displayName } else { what = TvDisplay.name }
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
            note(.evtStarted, .info, what, host, String(profile.width), String(profile.height), String(profile.fps))
        } catch let e as ControlClient.ControlError {
            await engine.stop(); fail(L10n.t(.statusStartFailed), e.description)
        } catch let e as CaptureError {
            await engine.stop(); fail(L10n.t(.statusCaptureProblem), e.description)
        } catch {
            await engine.stop(); fail(L10n.t(.statusError), "\(error)")
        }
        refreshLists()
    }

    /// TV'den gelen "yayına başla" isteği: arayüzde SEÇİLİ pencere yoksa başlatmaz.
    /// (Seçim yapmadan rastgele bir pencereyi ağa vermek istemediğimiz için kasıtlı red.)
    private func startForTV(_ session: SenderServer.TvSession) async {
        guard !engine.isRunning else { log("yayın zaten sürüyor; yeni istek yok sayıldı"); return }
        let row = windowTable.selectedRow
        guard tvDisplayMode || (row >= 0 && row < shown.count) else {
            note(.evtTvWantsNoWindow, .warn)
            setHint(.hintTvWantsWindow)
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
        setHint(detail)
        setSummary("\(title): \(detail)", .bad)
        summaryIsError = true
        note("\(title): \(detail)", .error)
        refreshRunButton()
    }

    private func addManualDevice() {
        let host = manualIP.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        if TVs.first(where: { $0.host == host }) == nil {
            TVs.append(DiscoveredTV(name: KeyStore.names()[host] ?? L10n.t(.statusUnknownTv), host: host,
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
            setHint(.hintForgetNoTarget)
            note(.evtForgetNoTarget, .warn)
            return
        }
        let name = selectedDevice()?.displayName ?? host
        log("eşleşme kaldırılıyor: \(name) · \(host)" + (manual.isEmpty ? "" : " (adres kutusundaki değer)"))
        // TV'nin kontrol sunucusu tek oturumlu: yayın sürerken aynı adrese açılan ikinci bağlantı
        // bekler. Ölçülen kusur: düğme hiçbir şey yapmadan asılı kalıyor, kayıt silinmiyordu.
        if engine.isRunning, engine.streamingHost == host || tvInitiatedHost == host {
            note(.evtForgetStoppedCast)
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
            note(.evtForgetUnreachable, .warn, "\(error)")
        }
        KeyStore.remove(host)     // Anahtar + ad kaydı; yarımkalır eşleşme bırakmamak için
        note(tvForgetful
             ? L10n.f(.evtForgetBothEnds, host)
             : L10n.f(.evtForgetLocalOnly, host))
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
        lastDiscovery = (found.count, paired)
        renderDiscoveryChip()
        if found.isEmpty {
            log("keşif: ağda alıcı yayını yok — TV'de uygulamayı açık tut ya da TV'den bu bilgisayarı seç")
            if !warnedNoTv {
                warnedNoTv = true
                note(.evtNoReceiver, .warn)
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
            note(.evtOrphanPairing, .warn, tv.displayName)
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
            setHint(engine.isRunning ? nil : .hintPickWindow)
        } catch let e as CaptureError {
            windows = []; shown = []
            windowTable.reloadData()
            log(e.description)
            setHint(.hintPermissionNeeded)
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
            log("izlenen pencere listeden düştü → aynı uygulamanın penceresine geçiliyor: \(twin.displayName)")
            do { try await self?.engine.switchWindow(twin) }
            catch { log("geçiş başarısız: \(error)") }
        }
    }

    private func refreshLists() {
        if shown.isEmpty && !windows.isEmpty { setHint(.hintNoSearchHits) }
    }

    /// Düğme etiketi her durum değişiminde yenilenir. Ölçülen kusur: Mac'ten başlatılan yayında
    /// `run()` başarı yolunda bu fonksiyon hiç çağrılmıyordu, düğme "Başlat" yazmaya devam edip
    /// basınca yayını durduruyordu (TV'den başlatılan akışta `startForTV` çağırdığı için görülmedi).
    private func refreshRunButton() {
        setRunTitle(engine.isRunning ? L10n.t(.uiBtnStop) : L10n.t(.uiBtnStart))
        if !engine.isRunning { streamNotice = nil; lastStats = nil; dashboard.clearStats() }
        setStatus(streamNotice ?? (engine.isRunning ? L10n.t(.statusOnAir) : L10n.t(.uiStatusReady)))
        modeControl.isEnabled = !engine.isRunning
        syncChips()
        // Kullanıcı sebebi giderdi (TV + pencere seçildi) ve yayın başlamadıysa kırmızı
        // özet kendiliğinden kalkar: uyarı çözümsüz bir gerçek gibi asılı kalmasın.
        if summaryIsError, !engine.isRunning, selectedHost() != nil,
           tvDisplayMode || windowTable.selectedRow >= 0 {
            setSummary(.summaryReady, .idle)
            summaryIsError = false
        }
    }

    /// Durum çipleri seçime ve yayına göre tek yerden doldurulur: kullanıcı "neyi, nereye,
    /// hangi kanalla" yayınladığını satır satır okumadan görebilsin.
    private func syncChips() {
        let source: String
        var sourceState: ChipView.State = .ok
        if tvDisplayMode {
            source = L10n.t(.uiModeTvScreen)
        } else if let win = shown[safe: windowTable.selectedRow] {
            source = win.displayName
        } else {
            source = L10n.t(.chipSourceNoWindow)
            sourceState = .warn
        }
        dashboard.chipSource.set(source, state: sourceState)

        let target: String
        var targetState: ChipView.State = .ok
        if let manual = selectedHost(), !manual.isEmpty {
            target = manual
        } else if let tv = selectedDevice() {
            target = L10n.f(.chipTargetLine, tv.displayName, tv.host.isEmpty ? L10n.t(.chipTargetNoAddress) : tv.host)
            if tv.host.isEmpty { targetState = .warn }
        } else {
            target = L10n.t(.statusNoTv)
            targetState = .warn
        }
        dashboard.chipTarget.set(target, state: targetState)

        let profile = profilePopup.titleOfSelectedItem ?? "1080p60"
        dashboard.chipChannel.set(L10n.f(.chipChannelLine, profile,
                                        engine.isRunning ? L10n.t(.chipChannelOnAir) : L10n.t(.chipChannelIdle)),
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
        startStop.effectiveAppearance.performAsCurrentDrawingAppearance {
            startStop.layer?.backgroundColor = (engine.isRunning ? Theme.stopFill : Theme.goFill).cgColor
        }
    }

    /// Ekran dizilimini canlı yazar: sanal ekran açıldıkça konumu değişebiliyor.
    private func refreshScreensNote() {
        let screens = NSScreen.screens.map { ScreenLayout.Screen(name: $0.localizedName, frame: $0.frame) }
        tvPanel.setScreens(screens, tvName: TvDisplay.name)
    }

    private func render(_ s: MirrorEngine.Stats) {
        lastStats = s
        dashboard.setStats(s)
        if tvDisplayMode { refreshScreensNote() }
        setStatus(streamNotice ?? L10n.t(.statusOnAir))
        refreshEventsPage()
        guard engine.isRunning else { return }
        summaryIsError = false
        if let notice = streamNotice {
            setSummary(notice, .warn)
        } else {
            let trouble = s.nackRequests + s.dropped
            // "sağlam" demiyoruz: hareketsiz pencerede kare gelmez, bu arıza değil. Yalnız
            // kayıp sayısı hüküm verir.
            setSummary(.sumStreamRunning, trouble == 0 ? .ok : .warn,
                       L10n.int(Int(s.seconds)), DashboardView.grouped(s.packets),
                       L10n.int(trouble), L10n.number(s.fps))
        }
    }

    // ---------- ağ yükü ----------

    private static let modemProbeKey = "modemProbe"

    /// 1 sn'lik yoklama turu: RTP çıkışı, Mac kartı, Wi-Fi hızı ve (açıksa) modem sayacı.
    private func tickNetLoad() async {
        netTick += 1
        // Yayının RTP hızı: motor sayacı farkından. Yayın yoksa değer nil kalır ("—" gösterilir).
        if engine.isRunning, let stats = lastStats {
            let now = Date()
            if let previous = lastWireBytes, let at = lastWireAt {
                let dt = now.timeIntervalSince(at)
                castMbps = NetMath.mbps(previous: UInt64(previous), current: UInt64(stats.wireBytes),
                                        seconds: dt)
            }
            lastWireBytes = stats.wireBytes
            lastWireAt = now
        } else {
            castMbps = nil; lastWireBytes = nil; lastWireAt = nil
        }
        // Arabirim adı tahmin edilmez: yayın yapılan adrese giden yol sorulur. Hedef
        // seçili değilken varsayılan yol aynı yöntemle çözülür (paket gitmez).
        // Ölçülen kusur: koşul `host != routeHost` idi → hedef yokken `nil != nil` false
        // kalıyor ve şerit hiç dolmuyordu.
        let host = engine.streamingHost ?? selectedHost()
        // Hedef değiştiyse yeniden çöz; henüz hiç çözülmediyse 5 turda bir tekrar dene.
        if host != routeHost || (routeInterface == nil && netTick % 5 == 0) {
            routeHost = host
            routeInterface = InterfaceSampler.routeInterface(to: host ?? InterfaceSampler.defaultRouteProbe)
        }
        lastMacSample = interfaceSampler.sample(interface: routeInterface)
        // Değer yoksa her turda, varsa 10 turda bir sor: ilk yoklama boş dönebiliyor.
        if wifiMbps == nil || netTick % 10 == 0 { wifiMbps = WifiLink.rateMbps() }
        renderNetStrip()
        if modem.isEnabled { await modem.poll() }
    }

    /// Şeridin tek çizim yeri: her kaynak kendi alanında durur, modem geri çağırması
    /// Mac hücresini nil ile ezmesin (ölçülen kusur: "bu Mac'in kartı" sürekli "—" kalıyordu).
    private func renderNetStrip() {
        var r = NetStripView.Reading()
        r.castMbps = castMbps
        r.wifiMbps = wifiMbps
        r.macIn = lastMacSample?.inbound
        r.macOut = lastMacSample?.outbound
        r.interface = interfaceSampler.interfaceName ?? routeInterface
        r.wanIn = modem.wanDownMbps
        r.wanOut = modem.wanUpMbps
        r.capDown = modem.capacityDownMbps
        r.capUp = modem.capacityUpMbps
        r.accessType = modem.accessType
        r.modemState = modem.state
        dashboard.netStrip.set(r)
    }

    /// Rozet rengi **yayın durumundan** gelir, metinden değil: metin geçici uyarıları da
    /// gösterebildiği için ("Akış takıldı" gibi) renk yalan söylemesin — yeşil = yayında,
    /// kırmızı = yayında değil.
    ///
    /// Renk, rozetin kendi görünüm bağlamında çözülür: `NSApp.appearance` atandıktan hemen
    /// sonra çağrıldığında süreç hâlâ eski temayı görüyordu (ölçüldü: açık temaya geçince
    /// rozet koyu temanın kırmızısıyla kaldı).
    private func setStatus(_ text: String) {
        statusText.stringValue = text
        let fill = engine.isRunning ? Theme.goFill : Theme.stopFill
        statusPill.effectiveAppearance.performAsCurrentDrawingAppearance {
            statusPill.layer?.backgroundColor = fill.cgColor
        }
        refreshEventsPage()
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
                note(.evtPermissionGranted)
                await refreshWindows(keepSelection: true)
                return
            }
            note(.evtPermissionWaitingPath, .warn)
            setSummary(.sumPermissionWaiting, .warn)
            if await WindowCapture.wait(forGrant: 240) {
                note(.evtPermissionTaken)
                setSummary(.summaryReady, .idle)
                await refreshWindows(keepSelection: true)
            } else {
                note(.evtPermissionMissing, .error)
            }
        }
    }

    /// Aynı paket kimliğiyle diskte birden çok kopya ya da çalışıyor ikinci örnek var mı?
    /// Ölçülen kusur: geliştirme kopyası (`artifacts/build`) ile kurulu kopya aynı anda
    /// kayıtlıyken Ekran Kaydı izni hangisine verildi şaşıyor, TV'nin geri kanalı (7610) ve
    /// yoklama kanalı (7611) çakışıyor; kullanıcı "verdiğim izni okumuyor" durumuna düşüyordu.
    /// Kaç kopya var ve hangisi koşuyor — izin tekrarının gerçek kaynağı buradan okunsun.
    ///
    /// İki ölçülen tuzak: (1) LaunchServices kayıtları bağlı olmayan DMG bağlama
    /// noktalarını ve silinmiş geçici kopyaları da listeliyor (ölçüldü: 19 kayıt, diskte
    /// yalnız 4'ü vardı) — sayan kişi sahte "kopya" uyarısı görüyordu. (2) Ekran Kaydı
    /// izni paket kimliği + **imza gereksinimiyle** hatırlanıyor; farklı sertifika ile
    /// imzalanmış bir kopya macOS'a göre yabancı uygulamadır ve izni yeniden sorar.
    private func warnAboutCopies() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let here = Bundle.main.bundlePath
        let live = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id)
            .map(\.path).filter { FileManager.default.fileExists(atPath: $0) }.sorted()
        if live.count > 1 {
            note(.evtCopiesCount, .warn, L10n.int(live.count), here)
        } else if live.first != here {
            note(.evtRunningNotInstalled, .warn, here)
        }
        // Koşan ikinci örnek artık mümkün değil: InstanceGuard servisi açılışta tek örnek
        // kilitlerini denetler ve ikinci örneği kapatır.
    }

    // ---------- diyaloglar ----------

    private func askPin() async -> String? {
        let a = NSAlert()
        a.messageText = L10n.t(.dlgPinTitle)
        a.informativeText = L10n.t(.dlgPinInfo)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 26))
        field.placeholderString = "123456"
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        a.accessoryView = field
        a.addButton(withTitle: L10n.t(.dlgPair))
        a.addButton(withTitle: L10n.t(.dlgCancel))
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
        // Ölçülen kusur: `byTruncatingHead` uzun tarayıcı başlığında **uygulama adını**
        // tamamen yutuyordu ("…in En Etkileyici Mağaralarından…"). Ortadan kesme hem
        // uygulama adını hem belgenin/site adının sonunu korur.
        primary.lineBreakMode = .byTruncatingMiddle
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
        primary.stringValue = w.displayName
        let boyut = "\(Int(w.frame.width))×\(Int(w.frame.height))"
        secondary.stringValue = streaming ? L10n.f(.cellOnAir, boyut) : boyut
        secondary.textColor = streaming ? .controlAccentColor : .secondaryLabelColor
        icon.image = NSWorkspace.shared.runningApplications
            .first { $0.localizedName == w.app }?.icon
            ?? NSImage(named: NSImage.multipleDocumentsName)
        // İpucu ham başlığı saklar: satır kırpıldığında veya sayaç/gürültü atıldığında
        // tam metne ulaşmak mümkün kalsın.
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
            secondary.stringValue = L10n.t(.cellAddressUnresolved)
            renk = .systemRed
        } else if paired {
            secondary.stringValue = L10n.f(.cellPairedLine, tv.host, String(tv.controlPort),
                    tv.online ? L10n.f(.cellOnline, tv.source.label)
                             : liveTwin ? L10n.t(.cellStaleAddress)
                                        : L10n.t(.cellAppClosed))
            renk = tv.online ? .systemGreen : (liveTwin ? .systemOrange : .secondaryLabelColor)
        } else if tv.tvReportsPaired {
            // TV kendi tarafında eşleşmiş sayıyor (anahtar onun da üzerinde); Mac'te yoksa
            // akış sessizce PIN turuna düşer — nedeni satırda yazılı durur.
            secondary.stringValue = L10n.f(.cellTvThinksPaired, tv.host, String(tv.controlPort))
            renk = .systemOrange
        } else {
            secondary.stringValue = L10n.f(.cellUnpairedLine, tv.host, String(tv.controlPort),
                    tv.online ? L10n.f(.cellOnlinePairHint, tv.source.label) : L10n.t(.cellOffline))
            renk = tv.online ? .systemRed : .secondaryLabelColor
        }
        baseSecondaryColor = renk
        secondary.textColor = backgroundStyle == .emphasized ? .white : renk
    }
}

/// İçeriği taşıyan kök / ızgara görünümü: yeniden boyutlandığında çerçevelerin baştan
/// hesaplanması için geri çağırma verir ve üstten hesaplı koordinat kullanır (flipped),
/// böylece satır sırası yukarıdan aşağıya okunur.
final class LayoutView: NSView {
    var onLayout: ((NSSize) -> Void)?
    /// Sistem teması değişince katman zeminlerini yeniden boyamak için (renkler `CGColor`
    /// olarak çözüldüğünden AppKit bunları kendiliğinden güncellemiyor).
    var onAppearance: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        onLayout?(bounds.size)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearance?()
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
