package dev.atvm.receiver

import android.app.Activity
import android.content.Context
import android.content.res.Configuration
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.util.Log
import android.view.KeyEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.TextView
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.Locale

/** PaneCast TV alıcısı.
 *  Durum makinesi: HAZIR → (eşleşme) PIN → YAYIN → HAZIR.
 *  Leanback-only cihazlarda telefon UI'ı çalışmaz; sadece D-pad ile kontrol edilir
 *  (android.software.leanback_only). */
class MainActivity : Activity(), ControlLink.Listener {
    companion object {
        private const val TAG = "ATVM-Main"
        private const val STATS_INTERVAL_MS = 1000L
        private const val MAX_RECOVERIES = 3
    }

    private lateinit var surfaceView: SurfaceView
    private lateinit var rootView: FrameLayout
    /** Yerleşimi hesaplanan son görüntü boyutu (gereksiz layout'u önlemek için). */
    private var fittedW = 0
    private var fittedH = 0
    /// Ekranın tamamı tek yerden çizilir: durum → TvScreen.State → render.
    private lateinit var screen: TvScreen
    private var showDebug = false
    private var surface: Surface? = null
    private lateinit var control: ControlLink
    private lateinit var decoder: H264DecoderRenderer
    private lateinit var media: UdpMediaReceiver
    /** Kurtarma için gereken son oturum parametreleri. */
    @Volatile private var session: SessionParams? = null
    private var recoveries = 0
    private lateinit var audio: AudioRenderer
    /** Oturumun ortak saati (§5.1); yayın yokken null. */
    @Volatile private var avClock: AvClock? = null
    private var wakeLock: android.os.PowerManager.WakeLock? = null
    private lateinit var presence: PresenceResponder
    private val ui = Handler(Looper.getMainLooper())
    private var nsdRegistration: NsdManager.RegistrationListener? = null
    private var browser: SenderBrowser? = null
    private val computers = arrayListOf<SenderBrowser.Computer>()
    @Volatile private var resuming = false
    private var streaming = false
    private var currentPin: String? = null
    /// PIN sayacı: statsRunnable doldurur, ekran State üzerinden okur.
    private var pinLeft = 0
    private var pinLock = 0
    /// Arayüz metinlerinin okunduğu bağlam: `onCreate`de kurulur, `--es lang` ile dili değişir.
    private lateinit var texts: Context

    /** Görünen dildeki metin. Biçimli satırlarda göstericiler numaralı (`%1$s`), çünkü Türkçe ve
     *  İngilizcede sözcük sırası farklı; kataloğun iki kopyası da aynı sırayı taşımak zorunda. */
    private fun text(res: Int, vararg args: Any): String =
        if (args.isEmpty()) texts.getString(res) else texts.getString(res, *args)

    /** Ondalı sayıda ayraç da görünen dile ait: Türkçede "59,8", İngilizcede "59.8". Yalnız arayüz
     *  satırları bundan geçer; `logStats`/`Log.*` sayıları makine-okunur kalsın diye dokunulmuyor.
     *  Ölçüm dilimleyicileri (`p50=` gibi) çözücünün kendi biçimlendirmesinden geliyor (§ raporda). */
    private fun number(value: Double, digits: Int = 1): String =
        String.format(texts.resources.configuration.locales.get(0), "%.${digits}f", value)

    /**
     * Yalnız hata-ayıklama: `am start --es lang tr|en …` ile GÖRÜNÜR dil sabitlenir ki iki dil
     * TV'nin sistem ayarına dokunmadan ekran görüntülenebilsin.
     *
     * Neden "debug-only": uygulamanın kendi yolu bu extra'yı HİÇ göndermez (tek kaynak `am start`)
     * ve değer hiçbir yere saklanmaz — her açılışta intent'ten okunur, sistem ayarı değişmez.
     * `preview` bayrağının aksine derleme türüne göre süzülmüyor: sürüm derlemesinde de etkisiz
     * kalmasının nedeni aynı şey, yani onu gönderen hiçbir arayüz düğmesi olmaması.
     *
     * Kullanıcı için dil Android'in standart davranışıyla SİSTEM YERELİNDEN gelir; TV'de ayrı bir
     * dil anahtarı bilinçli olarak yok. `attachBaseContext` değil de burada: `Activity.attach()`
     * `attachBaseContext`i `mIntent` atanmadan ÖNCE çağırıyor, orada intent okunamaz.
     * Tuzak (`preview` bayrağıyla aynı): activity `singleTask`, koşan örnek yeniden kullanılır ve
     * onCreate bir daha koşmaz → dili değiştirmeden önce `am force-stop app.panecast.receiver`.
     */
    private fun localizedContext(baseline: Context): Context {
        val cfg = Configuration(baseline.resources.configuration)
        when (intent?.getStringExtra("lang")?.lowercase(Locale.ROOT)) {
            "tr" -> cfg.setLocale(Locale.forLanguageTag("tr"))
            "en" -> cfg.setLocale(Locale.forLanguageTag("en"))
            else -> return baseline
        }
        return baseline.createConfigurationContext(cfg)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        texts = localizedContext(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        buildUi()

        decoder = H264DecoderRenderer()
        audio = AudioRenderer()
        // Boşalma payı HAL'in okuma parçasına göre kurulur (bu TV: 864 çerçeve = 18 ms).
        audio.outputPeriodFrames = (getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager)
            .getProperty(android.media.AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)?.toIntOrNull() ?: 960
        media = UdpMediaReceiver(decoder, audio) { control.requestIdr() }
        // Kilitlenme kurtarması: çözücü kendini toplamıyorsa önce boşaltılır (flush), son çare
        // yeniden kurulur; her kademede anahtar kare istenir. UI iş parçacığında yapılır —
        // çözücü döngüsünün kendi thread'i kendini join edemez.
        decoder.onStalled = { ui.post { recoverDecoder() } }
        // Çözücünün gerçek çıktı boyutu yerleşimin kaynağıdır (pencere yeniden boyutlanınca değişir).
        decoder.onVideoSize = { w, h -> ui.post { fitVideo(w, h) } }
        decoder.onOutgrown = { w, h -> ui.post { rebuildDecoder(w, h) } }
        // Kuyruk taşıması: yarım GOP'u zorla çözmek yerine taze anahtar kare beklenir.
        decoder.onBackpressure = { media.reportBackpressure() }
        control = ControlLink(filesDir, this)
        control.start()
        publishMdns()
        // Uygulama açılır açılmaz: eşleşme yoksa PIN ekranı hemen görünür
        // (eskiden yalnızca Mac bağlanınca üretiliyordu; kullanıcı boşta kalıyordu).
        if (!control.isPaired) control.displayPin()
        // Eşleşme olmasa da bulunabilelim: Mac'in ağ yoklamasına adresimizi geri yazarız.
        presence = PresenceResponder({ localIpv4s() }, { control.isPaired })
        browser = SenderBrowser(applicationContext) { list ->
            runOnUiThread {
                computers.clear(); computers.addAll(list)
                renderStatus()
            }
        }
        browser?.start()
        renderStatus()
    }

    private fun buildUi() {
        val root = FrameLayout(this)
        rootView = root
        root.setBackgroundColor(0xFF000000.toInt())     // letterbox/pillarbox bantları siyah
        surfaceView = SurfaceView(this).apply {
            holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(h: SurfaceHolder) {
                    surface = h.surface
                    Log.i(TAG, "surface hazır")
                    renderStatus()
                }
                override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, hgt: Int) {
                    Log.i(TAG, "surface boyutu ${w}x$hgt")
                }
                override fun surfaceDestroyed(h: SurfaceHolder) {
                    surface = null
                    ui.post { stopStream("surface yok edildi") }
                }
            })
        }
        // Yalnız hata-ayıklama sürümünde çalışan önizleme bağlantısı: READY ve YAYINDA
        // ekranlarının tasarımı, gerçek eşleşme/ağ olmadan da ekranda görünebilsin
        // (emülatör/cihazda `am start --ei preview 1|2`). Sürüm derlemesinde bayrak yok.
        // `singleTask` olduğu için koşan örnek yeniden kullanılır ve onCreate bir daha koşmaz:
        // önizlemeyi değiştirmeden önce `am force-stop app.panecast.receiver` gerekir.
        preview = if (isDebugBuild) intent?.getIntExtra("preview", 0) ?: 0 else 0
        // Ekran metinleri yerelleştirilmiş bağlamdan okunsun (`--es lang` oradan görünsün).
        screen = TvScreen(texts, ui)
        // Kart seçimi = OK: framework odak araması ◀▶▲▼'yi kendisi yönetir.
        screen.onCardSelected = { pos -> startFromSelectedDevice(pos) }
        root.addView(surfaceView, FrameLayout.LayoutParams(-1, -1))
        root.addView(screen.view(), FrameLayout.LayoutParams(-1, -1))
        setContentView(root)
    }

    /** Videoyu ekrana en-boy oranını bozmadan sığdırır: oranı koruyan en büyük dikdörtgen, ortada;
     *  kalan siyah. SurfaceView'ı LayoutParams ile boyutlandırmak yüzeyi yeniden yaratmaz
     *  (surfaceCreated/Destroyed sayacı loglarda izlenir). UI iş parçacığında çağrılır. */
    private fun fitVideo(w: Int, h: Int) {
        if (w <= 0 || h <= 0) return
        val dm = resources.displayMetrics
        val sw = if (rootView.width > 0) rootView.width else dm.widthPixels
        val sh = if (rootView.height > 0) rootView.height else dm.heightPixels
        val scale = minOf(sw.toDouble() / w, sh.toDouble() / h)
        val fw = Math.round(w * scale).toInt().coerceIn(1, sw)
        val fh = Math.round(h * scale).toInt().coerceIn(1, sh)
        if (fw == fittedW && fh == fittedH) return
        fittedW = fw; fittedH = fh
        surfaceView.layoutParams = FrameLayout.LayoutParams(fw, fh, android.view.Gravity.CENTER)
        val l = (sw - fw) / 2; val t = (sh - fh) / 2
        Log.i(TAG, "video yerleşimi: kaynak ${w}x$h ekran ${sw}x$sh → rect($l,$t,${l + fw},${t + fh}) ${fw}x$fh")
    }

    // ---- ControlLink.Listener ----

    override fun onPeerHello(name: String, version: Int) {
        Log.i(TAG, "eş bağlandı: $name (protokol v$version)")
        ui.post { renderStatus() }
    }

    override fun onPinShown(pin: String) {
        currentPin = pin
        // Görünürlük kararı renderStatus'un içinde: eski yolda etiket/kod GONE kalıp
        // ekranda hiç belirmiyordu (ekran görüntüsüyle doğrulanmıştı).
        ui.post { renderStatus() }
        Log.i(TAG, "PIN ekranda gösteriliyor (değer loglanmaz)")
    }

    override fun onPaired(sessionId: String) {
        Log.i(TAG, "eşleşme tamam session=$sessionId")
        ui.post {
            currentPin = null
            renderStatus()
        }
    }

    /** Kontrol kanalı dinlenemiyor ya da yeniden dinlenmeye geçti: ekranda yazılı durur. */
    private var channelDown: String? = null

    override fun onControlChannelDown(reason: String) {
        Log.e(TAG, "kontrol kanalı iniyor: $reason")
        channelDown = reason
        ui.post { renderStatus() }
    }

    override fun onControlChannelUp() {
        if (channelDown != null) Log.i(TAG, "kontrol kanalı yeniden dinleniyor")
        channelDown = null
        ui.post { renderStatus() }
    }

    override fun onDenied(reason: String) {
        Log.w(TAG, "reddedildi: $reason")
        // Ölçülen kusur: red yalnız loglanıyordu; kullanıcı OK'a basıp ekranda hiçbir şey
        // görmeden bekliyordu. Gerekçe artık tek satırda ekranda. (Çağrı okuma iş
        // parçacığından gelir: çizim ana iş parçacığına taşınır.)
        ui.post {
            renderNote(denialText(ControlMessages.denied(reason)),
                isError = ControlMessages.deniedNeedsAction(reason))
        }
    }

    /**
     * `DenyKey` → kaynak. Eşlemenin TEK yeri burası ve `when` önermeli: yeni bir red anahtarı
     * eklenip yazısı unutulursa derleme durur. `unknown` dışında hiçbir anahtar `detail` almaz,
     * dolayısıyla `%1$s`li satır yalnız Mac'in ham nedenini basar.
     */
    private fun denyRes(k: ControlMessages.DenyKey): Int = when (k) {
        ControlMessages.DenyKey.noWindow -> R.string.deny_no_window
        ControlMessages.DenyKey.notPaired -> R.string.deny_not_paired
        ControlMessages.DenyKey.authFailed -> R.string.deny_auth_failed
        ControlMessages.DenyKey.codeUsed -> R.string.deny_code_used
        ControlMessages.DenyKey.codeExpired -> R.string.deny_code_expired
        ControlMessages.DenyKey.locked -> R.string.deny_locked
        ControlMessages.DenyKey.version -> R.string.deny_version
        ControlMessages.DenyKey.protocol -> R.string.deny_protocol
        ControlMessages.DenyKey.generic -> R.string.deny_generic
        ControlMessages.DenyKey.unknown -> R.string.deny_unknown
    }

    private fun denialText(d: ControlMessages.Denial): String =
        if (d.detail.isEmpty()) text(denyRes(d.key)) else text(denyRes(d.key), d.detail)

    /**
     * Yayın davetinin kurulum nedeninin ekrandaki satırı. Neden kodları `SenderConnector.ConnectFail`
     * tarafında, yazılar katalogda; `when` önermeli olduğu için çevrilmemiş neden derlemeyi durdurur.
     * Mac'in kendi gerekçesi (`detail`) uydurulmaz, `%1$s` ile aynen basılır.
     */
    private fun connectText(f: SenderConnector.Failure): String = when (f.kind) {
        SenderConnector.ConnectFail.unresolved -> text(R.string.cast_fail_unresolved)
        SenderConnector.ConnectFail.protoMismatch -> text(R.string.cast_fail_proto)
        SenderConnector.ConnectFail.oldApp -> text(R.string.cast_fail_old_app)
        SenderConnector.ConnectFail.badChallenge -> text(R.string.cast_fail_bad_challenge)
        SenderConnector.ConnectFail.identity -> text(R.string.cast_fail_identity)
        SenderConnector.ConnectFail.denied -> text(R.string.cast_fail_denied, f.detail)
        SenderConnector.ConnectFail.unexpected -> text(R.string.cast_fail_unexpected, f.detail)
        SenderConnector.ConnectFail.network -> text(R.string.cast_fail_network, f.detail)
    }

    /**
     * Yayın sırasında ekranın kararmasını/ekran koruyucunun yüzeyi ele geçirmesini
     * engeller. FLAG_KEEP_SCREEN_ON bu cihazda yetmiyor: ölçüldü, DreamX katmanı
     * yayının ortasında yüzeyi kapattı ve donanım çözücü 6-8 kare sonra durdu
     * (yüzey tamponları geri gelmiyor).
     */
    private fun acquireScreenWakeLock() {
        try {
            if (wakeLock?.isHeld == true) return
            val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            @Suppress("DEPRECATION")
            wakeLock = pm.newWakeLock(
                android.os.PowerManager.SCREEN_BRIGHT_WAKE_LOCK or android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "atvm:stream"
            ).apply { setReferenceCounted(false); acquire(10 * 60 * 1000L) }
        } catch (e: Exception) { Log.w(TAG, "ekran kilidi alınamadı: ${e.message}") }
    }

    private fun releaseScreenWakeLock() {
        try { wakeLock?.let { if (it.isHeld) it.release() } } catch (e: Exception) { }
        wakeLock = null
    }

    /** Yayın sürerken gelen yeni `start` pencere değişimidir: çözücü örneği korunur
     *  (flush + yeni SPS/PPS/IDR, KEY_MAX_WIDTH/HEIGHT 1920×1088 ile uyarlanır). */
    override fun onStartSession(p: SessionParams): Boolean {
        val s = surface ?: run { Log.e(TAG, "surface henüz hazır değil"); return false }
        val switching = streaming
        val okDec = if (switching) decoder.startOrReuse(p.width, p.height, p.fps, s)
                    else decoder.start(p.width, p.height, p.fps, s)
        if (!okDec) return false
        session = p
        recoveries = 0
        // İlk tahmin `start` parametreleri; çözücü gerçek boyutu bildirince düzeltilir.
        ui.post { fitVideo(p.width, p.height) }
        val clock = AvClock(p.sync, p.videoRtpBase, p.audioRtpBase)
        avClock?.stop()
        avClock = clock
        decoder.avClock = clock
        audio.avClock = clock
        val okMed = media.start(p.mediaPort, p.ssrc, p.payloadType, p.audioSsrc,
            p.audioPayloadType, p.audioSampleRate, p.audioChannels)
        if (!okMed) { decoder.avClock = null; clock.stop(); avClock = null; decoder.stop(); return false }
        streaming = true
        acquireScreenWakeLock()
        Log.i(TAG, (if (switching) "pencere değişti, çözücü korundu: " else "yayın başladı ") +
            "${p.width}x${p.height}@${p.fps} ${p.bitrate / 1_000_000}Mbps " +
            "ssrc=${p.ssrc} port=${p.mediaPort} ses=${if (p.audioPayloadType >= 0) "${p.audioSampleRate}Hz/${p.audioChannels}ch pt=${p.audioPayloadType}" else "yok"} " +
            "ortak saat=${if (p.sync) "var" else "yok"}")
        // Bu geri çağırma kontrol bağlantısının iş parçacığında çalışır: view'lara yalnızca UI iş parçacığında dokunulur.
        ui.post { renderStatus() }
        return true
    }

    override fun onStopSession(reason: String) {
        // Bu üç yol zaten Mac'ten geldi (`stop`/`unpair` yanıtları ControlLink'te yazılıyor):
        // geri bildirim göndermek mesajı iki katına çıkarır.
        ui.post { stopStream(reason, notifySender = false) }
    }

    /** Çözücü kare alıyor ama üretmiyor.
     *  Kademeler, ucuzdan pahalıya: 1) anahtar kare iste (referans bekleyen çözücü çoğu
     *  zaman bununla açılır); 2) örneği koruyup flush + anahtar kare; 3) son çare yeniden
     *  kur; sonrası yayını durdur. Ölçüldü: yeniden kurmak görüntü yolunu baştan açtırıyor
     *  (yeni katman, ~2 sn ilk kare); flush'ta kare hızı ve gecikme olduğu gibi kalıyor.
     *  Döngüsü ölmüş çözücü flush'ı işleyemez → doğrudan yeniden kurulur. */
    private fun recoverDecoder() {
        val p = session ?: return
        val s = surface ?: return
        if (!streaming) return
        if (recoveries == 0 && decoder.isAlive()) {
            recoveries++
            media.forceKeyFrameGate()
            control.requestIdr()
            Log.i(TAG, "çözücü çıktı vermiyor → anahtar kare istendi (kademe 1)")
            return
        }
        if (recoveries >= MAX_RECOVERIES) {
            Log.e(TAG, "çözücü $MAX_RECOVERIES kurtarmaya yanıt vermedi — yayın durduruluyor")
            stopStream("decoder_wedged")
            return
        }
        recoveries++
        if (recoveries == 2 && decoder.requestFlush("kurtarma ($recoveries/$MAX_RECOVERIES)")) {
            media.forceKeyFrameGate()
            control.requestIdr()
            Log.i(TAG, "çözücü boşaltıldı, örnek korundu ($recoveries/$MAX_RECOVERIES)")
            return
        }
        val ok = decoder.start(p.width, p.height, p.fps, s)
        media.forceKeyFrameGate()
        control.requestIdr()
        Log.i(TAG, "çözücü yeniden kuruldu ($recoveries/$MAX_RECOVERIES) ok=$ok")
    }

    /** Resim, çözücünün tampon boyutunu aştı (pencere büyüdü): çözücü yeni boyutla yeniden kurulur,
     *  yeni anahtar kare istenir. Yeniden kurmanın bedeli kısa bir kesinti (kurtarma ile aynı yol). */
    private fun rebuildDecoder(w: Int, h: Int) {
        val p = session ?: return
        val s = surface ?: return
        if (!streaming) return
        val ok = decoder.start(w, h, p.fps, s)
        media.forceKeyFrameGate()
        control.requestIdr()
        Log.i(TAG, "resim tampon boyutunu aştı → çözücü ${w}x$h ile yeniden kuruldu ok=$ok")
    }

    override fun onClientDisconnected() {
        ui.post {
            // Bağlantı kapandı: bildirimin gideceği bir uç artık yok.
            if (streaming) stopStream("istemci koptu", notifySender = false)
            renderStatus()
        }
    }

    /**
     * Yayını keser.
     *
     * `notifySender`: yayın **bizim tarafımızdan** bittiğinde Mac'e `stopped` yazılır. Mac,
     * kendi başlattığı duruşlarda (stop/unpair) yanıtı zaten aldığı için orada sessiz kalınır —
     * aksi hâlde mesaj bir tur daha dönüp gereksiz `sender_stop` üretirdi. Bildirim olmadan
     * ölçülen kusur: TV'de BACK ile yayın duruyor, Mac "Yayında" etiketiyle pencereyi ağa
     * yazmayı sürdürüyordu.
     */
    private fun stopStream(reason: String, notifySender: Boolean = true) {
        if (!streaming) return
        streaming = false
        if (notifySender) control.notifyStopped(reason)
        releaseScreenWakeLock()
        media.stop()
        decoder.stop()
        decoder.avClock = null
        avClock?.stop(); avClock = null
        Log.i(TAG, "yayın durdu: $reason")
        renderStatus()
    }

    // ---- durum çizimi ----

    private var lastRendered = 0L
    private var lastStatsAt = 0L
    private var lastFps = 0.0
    /// "AU geliyor ama çözücü kare üretmiyor" bekçisi: mevcut kilitlenme dedektörü
    /// çözücüye besleme ilerlerken çıktı durduğunu varsayıyor; boyut değişimi kaynaklı
    /// kilitlenmede besleme de durduğu için hiç tetiklenmiyordu (ölçüldü).
    private var lastAuObserved = 0L
    private var lastRenderProgress = 0L
    private var wedgedTicks = 0

    private val statsRunnable = object : Runnable {
        override fun run() {
            // PIN sayacı tek yerde tutulur: ekran bunu State üzerinden okur.
            if (!streaming && !control.isPaired) {
                pinLeft = control.pinSecondsLeft()
                pinLock = control.lockSecondsLeft()
                if (pinLock == 0 && pinLeft <= 0 && currentPin != null) control.displayPin(force = true)
            }
            renderStatus()
            if (streaming) logStats()
            ui.postDelayed(this, STATS_INTERVAL_MS)
        }
    }

    /** Ölçüm noktaları (görev §8): tek satırlık, makine-okunur istatistik. Sır içermez. */
    private fun logStats() {
        val now = System.currentTimeMillis()
        val r = decoder.rendered.get()
        val dt = if (lastStatsAt == 0L) STATS_INTERVAL_MS.toDouble() else (now - lastStatsAt).toDouble()
        // Pencere değişiminde sayaçlar sıfırlanır: önceki değer büyükse taban sıfırdır.
        val fpsDelta = if (dt > 0) (r - (if (r < lastRendered) 0L else lastRendered)) * 1000.0 / dt else 0.0
        lastRendered = r; lastStatsAt = now; lastFps = fpsDelta
        Log.i("ATVM-Stats", "fps_render=" + String.format("%.1f", fpsDelta) +
            " render=" + decoder.rendered.get() +
            " submit=" + decoder.submitted.get() +
            " drop_q=" + decoder.droppedQueueFull.get() +
            " err=" + decoder.decodeError.get() +
            " noinput=" + decoder.droppedNoInput.get() +
            " backlog=" + decoder.droppedBacklog.get() + " tryagain=" + decoder.tryAgain.get() + " stall=" + decoder.stalledPastPrime.get() + " ptsSn=" + decoder.lastPtsUs +
            " kisa=" + media.badShort() + " pt=" + media.badPt() + " ssrc=" + media.badSsrc() + " hdr=" + media.badHeaderLen() + " nal=" + media.unknownNalType() +
            " pkt=" + media.packetsReceived.get() +
            " au=" + media.accessUnits.get() +
            " sesPkt=" + media.audioPackets.get() + " sesYabanci=" + media.audioForeign.get() +
            " sesKB=" + audio.bytesWritten.get() / 1024 +
            " gap=" + media.gapCount() + " " + media.nackStats() +
            " malformed=" + media.malformedCount() +
            " idr=" + media.keyFrameRequests.get() +
            " inflight=" + decoder.inFlight() + " cdrop=" + decoder.droppedInDecoder.get() + " flush=" + decoder.flushes.get() + " ptsMiss=" + decoder.ptsMiss.get() + " queue=" + decoder.queueSize() +
            " latency=" + decoder.latencySummary() +
            " " + audio.stats() + " " + (avClock?.stats() ?: ""))

        // Bekçi: access unit'ler gelmeye devam ederken çözücü kare üretmiyorsa örnek
        // kilitlenmiştir (boyut değişimi ölçülen neden). 3 sn bekleyip kurtarmaya giriyoruz;
        // kurtarma zinciri kademe kademe flush → anahtar kare → yeniden kurma deniyor.
        val auNow = media.accessUnits.get()
        if (r != lastRenderProgress) {
            lastRenderProgress = r
            wedgedTicks = 0
            if (r > 0) recoveries = 0        // tekrar kare üretmeye başladı: bütçeyi tazele
        } else if (auNow > lastAuObserved) {
            wedgedTicks++
        }
        lastAuObserved = auNow
        if (wedgedTicks >= 3) {
            wedgedTicks = 0
            Log.e(TAG, "AU geliyor ama çözücü 3 sn kare üretmedi (au=$auNow rendered=$r) → kurtarma zinciri")
            recoverDecoder()
        }
    }

    override fun onResume() {
        super.onResume()
        presence.start()
        ui.post(statsRunnable)
    }

    override fun onPause() {
        super.onPause()
        presence.stop()
        ui.removeCallbacks(statsRunnable)
    }

    private val isDebugBuild: Boolean
        get() = (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
    private var preview = 0

    /** Önizleme modunda gerçek yerine tasarım verisi çizilir (yalnız hata-ayıklama sürümü).
     *  Metinler gerçek ekranların anahtarlarından gelir ki iki dil de ön izlemede sınanabilsin.
     *  Bilgisayar ADLARI örnek veridir: gerçek listede ad mDNS'ten gelir ve hiç çevrilmez. */
    private fun previewState(kind: RemoteKeys.Screen): TvScreen.State {
        val cards = listOf(
            TvScreen.Card("Masaüstü-Mac", "192.0.2.10:7601", TvScreen.CardState.READY),
            TvScreen.Card("Dizüstü-Mac", "192.0.2.11:7601", TvScreen.CardState.OFFLINE),
        )
        return TvScreen.State(
            screen = kind,
            headline = text(if (kind == RemoteKeys.Screen.READY) R.string.home_headline_ready
                            else R.string.cast_headline_live),
            subline = if (kind == RemoteKeys.Screen.READY) text(R.string.home_subline_paired, "Masaüstü-Mac") else "",
            note = if (kind == RemoteKeys.Screen.READY) text(R.string.home_note_ok_calls_selected) else "",
            noteIsError = false,
            pin = "123456", pinSecondsLeft = 120,
            cards = if (kind == RemoteKeys.Screen.READY) cards else emptyList(),
            stats = text(R.string.cast_stats_strip, "1920x1080@60",
                number(59.8), text(R.string.preview_sample_latency)),
            detail = text(R.string.preview_detail_sample),
            showDetail = showDebug,      // MENU/INFO gerçekten katmanı açsın ki tasarım sınanabilsin
            version = text(R.string.preview_version_label),   // sürüm etiketi değil: hata-ayıklama karesi
            addresses = "192.0.2.20",
        )
    }

    private fun renderStatus() {
        if (preview in 1..2) {
            screen.render(previewState(if (preview == 1) RemoteKeys.Screen.READY else RemoteKeys.Screen.STREAMING))
            return
        }
        val local = localIpv4s()
        val kind = when {
            streaming -> RemoteKeys.Screen.STREAMING
            control.isPaired -> RemoteKeys.Screen.READY
            else -> RemoteKeys.Screen.PAIRING
        }
        val teknik = StringBuilder()
        val headline: String; val subline: String; var note = statusNote

        when (kind) {
            RemoteKeys.Screen.STREAMING -> {
                headline = text(R.string.cast_headline_live); subline = ""
                teknik.append(text(R.string.cast_detail_decoder,
                    decoder.selectedCodecName, decoder.latencySummary()))
                teknik.append(text(R.string.cast_detail_frames, decoder.rendered.get(), decoder.inFlight(),
                    decoder.submitted.get(), decoder.droppedQueueFull.get(), decoder.decodeError.get()))
                teknik.append(text(R.string.cast_detail_network, media.summary(), audio.summary(texts)))
                avClock?.let { teknik.append(text(R.string.cast_detail_sync_offset, it.displayOffsetMs)) }
            }
            RemoteKeys.Screen.READY -> {
                headline = text(if (computers.isEmpty()) R.string.home_headline_searching
                                else R.string.home_headline_ready)
                subline = if (control.peerName == "-") text(R.string.home_subline_waiting)
                          else text(R.string.home_subline_paired, control.peerName)
                if (computers.isEmpty() && note.isEmpty()) note = text(R.string.home_note_rescan_hint)
                teknik.append(text(R.string.home_detail_session, control.peerName,
                    Protocol.CONTROL_PORT, Protocol.MEDIA_PORT))
                teknik.append(text(R.string.home_detail_hold_back))
            }
            RemoteKeys.Screen.PAIRING -> {
                headline = text(R.string.pair_headline)
                subline = text(R.string.pair_subline)
                if (pinLock > 0) note = text(R.string.pair_note_locked, pinLock)
                teknik.append(text(R.string.pair_detail_code_valid, pinLeft))
            }
        }
        teknik.append(text(R.string.common_detail_identity, packageInfoVersion(),
            local.ifEmpty { listOf(text(R.string.common_detail_no_address)) }.joinToString(", ")))
        teknik.append(text(R.string.common_detail_mdns, Protocol.SERVICE_TYPE))

        screen.render(
            TvScreen.State(
                screen = kind,
                headline = headline,
                subline = subline,
                note = channelDown?.let { text(R.string.common_note_channel_down, it) } ?: note,
                noteIsError = channelDown != null || statusNoteIsError,
                pin = currentPin ?: "······",
                pinSecondsLeft = pinLeft,
                cards = computers.map { c ->
                    TvScreen.Card(
                        name = c.name.removePrefix("ATVM-").replace('_', ' '),
                        detail = "${c.address}:${c.port}",
                        state = if (resuming) TvScreen.CardState.BUSY else TvScreen.CardState.READY)
                },
                stats = if (streaming) text(R.string.cast_stats_strip, decoder.lastProfile,
                        number(lastFps), decoder.latencySummary()) else "",
                detail = teknik.toString(),
                showDetail = showDebug,
                version = packageInfoVersion(),
                addresses = local.joinToString(", "),
            )
        )
    }

    /// Arayüzde görünen sürüm etiketi: `v0.2.11`. GitHub yayını ile aynı zincir (VERSION →
    /// gradle versionName), böylece ekranda okunan numara ile kurulu APK aynı olduğunu kanıtlar.
    private fun packageInfoVersion(): String = "v" + (try {
        packageManager.getPackageInfo(packageName, 0).versionName
    } catch (e: Exception) { null } ?: "?")

    private fun localIpv4s(): List<String> = try {
        NetworkInterface.getNetworkInterfaces().asSequence()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.asSequence() }
            .filterIsInstance<Inet4Address>()
            .map { it.hostAddress ?: "?" }
            .toList()
    } catch (e: Exception) { emptyList() }

    // ---- kumanda ----

    /// Eşleşme silme onayı. Tek basışla silme geri alınamaz: kullanıcı yeniden kod girmek
    /// zorunda kalıyordu. Artık BACK'e basılı tutuluyor, sonra "Sil" seçiliyor.
    private var unpairDialog: android.app.AlertDialog? = null

    private fun confirmUnpair() {
        unpairDialog?.dismiss()
        unpairDialog = android.app.AlertDialog.Builder(this)
            .setTitle(text(R.string.home_unpair_title))
            .setMessage(text(R.string.home_unpair_message))
            .setPositiveButton(text(R.string.home_unpair_confirm)) { _, _ ->
                control.forgetPairing()
                renderStatus()
            }
            .setNegativeButton(text(R.string.home_unpair_cancel), null)
            .show()
    }

    /**
     * Kumanda girdisinin tek yolu.
     *
     * Neden `onKeyDown` değil de `dispatchKeyEvent`: TV'de odak bir kartta değilken de
     * (yayın sırasında, PIN ekranında, liste boşken) tuşların çalışması gerekir — "global"
     * olan bu. Öte yandan ◀▶▲▼ ve odaklı kartın SELECT'i framework'e kalmalı: odak araması
     * ve tıklama Android TV'nin standart yoludur, kendimiz yazmayız.
     *
     * Kural: `RemoteKeys` PASS derse (ses, kanal, güç, CEC, gezinme, odaklıyken SELECT)
     * `super`e bırakılır. Eylemler yalnız ACTION_DOWN'da ve `repeatCount == 0` iken koşar:
     * tuşu basılı tutmak iki kez "yayın başlat" üretemez.
     *
     * BACK'in kararı `RemoteKeys.backAction`dadır ve DOWN+UP iki dönemi de burada tüketilir:
     * kısa basma yayını durdurur, yayında değilse ekrandan çıkar (çıkış onDestroy'i çalıştırır:
     * mDNS kaydı, soketler, çözücü ve ses hattı serbest kalır); basılı tutma eşleşme silme
     * onayını açar. Ölçülen kusur (gerçek TV, 0.2.4): UP olayı tüketilip `onKeyUp`a bırakıldığı
     * için durdur/çık hiç koşmuyordu.
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val cmd = RemoteKeys.command(event.keyCode, event.repeatCount, event.isLongPress)
        if (cmd == RemoteKeys.Command.PASS || cmd == RemoteKeys.Command.UNKNOWN) {
            return super.dispatchKeyEvent(event)
        }
        // Odakta kart varsa SELECT framework'ün tıklamasına ait (çift tetikleme olmasın).
        if (cmd == RemoteKeys.Command.SELECT && !streaming && control.isPaired && computers.isNotEmpty()) {
            return super.dispatchKeyEvent(event)
        }
        // Hata-ayıklama sürümünde tek satır tuş izi: kumanda sorunu "tuş mu gelmiyor,
        // biz mi işlemiyoruz" ayrımı cihaz başında olmadan çözülebilsin.
        if (isDebugBuild && event.action == KeyEvent.ACTION_DOWN && !RemoteKeys.isNavigation(cmd)) {
            Log.i(TAG, "tuş " + event.keyCode + " → " + cmd + " (tekrar " + event.repeatCount + ")")
        }
        screen.wakeStats()
        val phase = if (event.action == KeyEvent.ACTION_DOWN) RemoteKeys.Phase.DOWN else RemoteKeys.Phase.UP
        if (cmd == RemoteKeys.Command.BACK) {
            when (RemoteKeys.backAction(phase, event.isLongPress, streaming,
                                        control.isPaired, unpairDialog?.isShowing == true)) {
                RemoteKeys.BackAction.TO_SYSTEM -> return super.dispatchKeyEvent(event)
                RemoteKeys.BackAction.START_TRACKING -> { event.startTracking(); return true }
                RemoteKeys.BackAction.UNPAIR_DIALOG -> { confirmUnpair(); return true }
                RemoteKeys.BackAction.STOP_STREAM -> { if (phase == RemoteKeys.Phase.UP) stopStream("kullanıcı DURDUR"); return true }
                RemoteKeys.BackAction.EXIT -> { if (phase == RemoteKeys.Phase.UP) finish(); return true }
                RemoteKeys.BackAction.SWALLOW -> return true
            }
        }
        if (event.action != KeyEvent.ACTION_DOWN) return super.dispatchKeyEvent(event)
        when (cmd) {
            // BACK yukarıda `RemoteKeys.backAction` ile iki dönemi birden tüketir; buraya düşmez.
            RemoteKeys.Command.SELECT -> when {
                streaming -> Unit
                control.isPaired && computers.isEmpty() -> rescan(text(R.string.home_note_list_empty))
                else -> { control.displayPin(force = true); renderStatus() }
            }
            RemoteKeys.Command.MENU, RemoteKeys.Command.DETAIL -> { showDebug = !showDebug; renderStatus() }
            RemoteKeys.Command.SEARCH -> rescan(text(R.string.home_note_rescanning))
            RemoteKeys.Command.STOP, RemoteKeys.Command.PLAY_PAUSE ->
                if (streaming) stopStream("kumanda")
                else if (!control.isPaired) { control.displayPin(force = true); renderStatus() }
            RemoteKeys.Command.NAV_LEFT, RemoteKeys.Command.NAV_RIGHT -> {
                // Yayında ◀ ▶ senkron kalibrasyonudur (insan kulağı/flaş klibi ile ölçülüyor).
                val c = avClock
                if (streaming && c != null) {
                    c.displayOffsetMs += if (cmd == RemoteKeys.Command.NAV_RIGHT) 10 else -10
                    Log.i(TAG, "görüntü ofseti ${c.displayOffsetMs} ms")
                    renderStatus()
                } else return super.dispatchKeyEvent(event)
            }
            else -> return super.dispatchKeyEvent(event)
        }
        return true
    }

    private fun rescan(why: String) {
        browser?.stop(); browser?.start(); renderNote(why)
    }

    // ---- mDNS yayını (Mac'in TV'yi port/sabit IP girmeden bulması için) ----

    private fun publishMdns() {
        try {
            val nsd = getSystemService(Context.NSD_SERVICE) as NsdManager
            val info = NsdServiceInfo().apply {
                serviceName = "ATVM-${android.os.Build.MODEL.replace(' ', '_')}"
                serviceType = Protocol.SERVICE_TYPE
                port = Protocol.CONTROL_PORT
                setAttribute("ver", Protocol.VERSION.toString())
                setAttribute("cport", Protocol.CONTROL_PORT.toString())
                setAttribute("mport", Protocol.MEDIA_PORT.toString())
                // Mac tarafı `.service` uç noktasını TCP açmadan çözümlüyemiyor; IPv4'ü TXT
                // kaydında yayımlayınca keşif bağlantı kurmadan tamamlanıyor.
                localIpv4s().firstOrNull()?.let { setAttribute("addr", it) }
            }
            val listener = object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(r: NsdServiceInfo) { Log.i(TAG, "mDNS yayımlandı: ${r.serviceName}") }
                override fun onRegistrationFailed(r: NsdServiceInfo, e: Int) { Log.w(TAG, "mDNS yayın başarısız code=$e") }
                override fun onServiceUnregistered(r: NsdServiceInfo) { Log.i(TAG, "mDNS yayını kaldırıldı") }
                override fun onUnregistrationFailed(r: NsdServiceInfo, e: Int) { Log.w(TAG, "mDNS kaldırma başarısız code=$e") }
            }
            nsdRegistration = listener
            nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (e: Exception) {
            Log.w(TAG, "mDNS yayını başlatılamadı: ${e.message}")
        }
    }

    private fun startFromSelectedDevice(pos: Int) {
        if (resuming || pos !in computers.indices) return
        val c = computers[pos]
        val key = control.storedSessionKey() ?: run { renderNote(text(R.string.home_note_no_key)); return }
        resuming = true
        renderNote(text(R.string.home_note_calling, c.name))
        Thread {
            // Çok arayüzlü bilgisayarda mDNS tek ve keyfi bir adres döndürüyor (ölçüldü: TV,
            // Mac'in sanal makine köprüsüne bağlanmaya çalıştı). Adın tüm adresleri çözülür,
            // TV'nin kendi ağındaki aday önce denenir.
            val mine = localIpv4s()
            val targets = SenderAddresses.order(
                SenderAddresses.expand(c.address) { name ->
                    java.net.InetAddress.getAllByName(name).mapNotNull { a -> a.hostAddress }
                }, mine)
            Log.i(TAG, "yayın adayı ${targets.size} adres: ${targets.joinToString { it.substringBeforeLast('.') + ".*" }}")
            val err = SenderConnector.resume(targets, c.port, Build.MODEL,
                mine.firstOrNull() ?: "", Protocol.MEDIA_PORT, key, control)
            runOnUiThread {
                resuming = false
                if (err == null) renderNote(text(R.string.home_note_called, c.name))
                else renderNote(connectText(err), isError = true)
            }
        }.start()
    }

    /** Geçici satıraltı not: 8 sn sonra kendiliğinden söner (kalıcı durum sanılmasın). */
    private var clearNote: Runnable? = null

    private fun renderNote(t: String, isError: Boolean = false) {
        statusNote = t
        statusNoteIsError = isError
        renderStatus()
        clearNote?.let { ui.removeCallbacks(it) }
        clearNote = Runnable {
            if (statusNote == t) { statusNote = ""; statusNoteIsError = false; renderStatus() }
        }.also { ui.postDelayed(it, 8_000) }
    }

    private var statusNote: String = ""
    /// Not satırının tonu: kırmızı yalnız kullanıcı bir şey yapması gerektiğinde.
    private var statusNoteIsError = false


    override fun onDestroy() {
        super.onDestroy()
        browser?.stop(); browser = null
        try {
            nsdRegistration?.let { (getSystemService(Context.NSD_SERVICE) as NsdManager).unregisterService(it) }
        } catch (e: Exception) { }
        streaming = false
        lastRendered = 0L; lastStatsAt = 0L
        media.stop(); decoder.stop(); control.stop()
        avClock?.stop(); avClock = null
    }
}
