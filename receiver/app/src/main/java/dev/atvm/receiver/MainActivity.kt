package dev.atvm.receiver

import android.app.Activity
import android.content.Context
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
        screen = TvScreen(this, ui)
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
            renderNote(ControlMessages.deniedText(reason), isError = ControlMessages.deniedNeedsAction(reason))
        }
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

    /** Önizleme modunda gerçek yerine tasarım verisi çizilir (yalnız hata-ayıklama sürümü). */
    private fun previewState(kind: RemoteKeys.Screen): TvScreen.State {
        val cards = listOf(
            TvScreen.Card("Masaüstü-Mac", "192.0.2.10:7601", TvScreen.CardState.READY),
            TvScreen.Card("Dizüstü-Mac", "192.0.2.11:7601", TvScreen.CardState.OFFLINE),
        )
        return TvScreen.State(
            screen = kind,
            headline = if (kind == RemoteKeys.Screen.READY) "Yayına hazır" else "Yayında",
            subline = if (kind == RemoteKeys.Screen.READY) "eşleşilen: Masaüstü-Mac" else "",
            note = if (kind == RemoteKeys.Screen.READY) "OK seçtiğin bilgisayarı çağırır" else "",
            noteIsError = false,
            pin = "123456", pinSecondsLeft = 120,
            cards = if (kind == RemoteKeys.Screen.READY) cards else emptyList(),
            stats = "● YAYINDA  1920x1080@60  ·  fps 59,8  ·  giriş→render 112 ms",
            detail = "çözücü: c2.vc.h264.decoder  ·  kareler: render=12.480 düşen=0\nağ: 412.907 paket  kayıp 0  yedek 3\n",
            showDetail = showDebug,      // MENU/INFO gerçekten katmanı açsın ki tasarım sınanabilsin
            version = "ön izleme", addresses = "192.0.2.20",   // sürüm etiketi değil: hata-ayıklama karesi
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
                headline = "Yayında"; subline = ""
                teknik.append("çözücü: ${decoder.selectedCodecName}  giriş→render: ${decoder.latencySummary()}\n")
                teknik.append("kareler: render=${decoder.rendered.get()} çözücüde=${decoder.inFlight()} "
                    + "gelen=${decoder.submitted.get()} düşen=${decoder.droppedQueueFull.get()} "
                    + "hata=${decoder.decodeError.get()}\n")
                teknik.append("ağ: ${media.summary()}\nses: ${audio.summary()}\n")
                avClock?.let { teknik.append("senkron: görüntü ofseti ${it.displayOffsetMs} ms (◀ ▶ ile 10 ms)\n") }
            }
            RemoteKeys.Screen.READY -> {
                headline = if (computers.isEmpty()) "Mac aranıyor" else "Yayına hazır"
                subline = if (control.peerName == "-") "eşleşme kayıtlı · bağlantı bekleniyor"
                          else "eşleşilen: ${control.peerName}"
                if (computers.isEmpty() && note.isEmpty()) note = "SEARCH ile yeniden ara · Mac'te bu TV'yi seçersen akış oradan da başlar"
                teknik.append("eşleşme: ${control.peerName}  ·  kontrol tcp/${Protocol.CONTROL_PORT}  "
                    + "medya udp/${Protocol.MEDIA_PORT}\n")
                teknik.append("BACK tuşuna BASILI TUT: eşleşmeyi sil (onay sorulur)\n")
            }
            RemoteKeys.Screen.PAIRING -> {
                headline = "Eşleşme bekleniyor"
                subline = "bu kodu Mac'teki Pane Cast penceresine gir"
                if (pinLock > 0) note = "Çok fazla hatalı deneme · $pinLock sn sonra yeniden"
                teknik.append("kod ${pinLeft} sn geçerli · OK: yeni kod\n")
            }
        }
        teknik.append("Pane Cast ${packageInfoVersion()}  ·  IP ${local.ifEmpty { listOf("(yok)") }.joinToString(", ")}\n")
        teknik.append("mDNS ${Protocol.SERVICE_TYPE}\n")

        screen.render(
            TvScreen.State(
                screen = kind,
                headline = headline,
                subline = subline,
                note = channelDown?.let { "kontrol kanalı kapalı: $it — yeniden deneniyor" } ?: note,
                noteIsError = channelDown != null || statusNoteIsError,
                pin = currentPin ?: "······",
                pinSecondsLeft = pinLeft,
                cards = computers.map { c ->
                    TvScreen.Card(
                        name = c.name.removePrefix("ATVM-").replace('_', ' '),
                        detail = "${c.address}:${c.port}",
                        state = if (resuming) TvScreen.CardState.BUSY else TvScreen.CardState.READY)
                },
                stats = if (streaming) "● YAYINDA  ${decoder.lastProfile}  ·  "
                        + "fps ${String.format("%.1f", lastFps)}  ·  ${decoder.latencySummary()}" else "",
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
            .setTitle("Eşleşme silinsin mi?")
            .setMessage("Bu TV ile Mac arasındaki eşleşme kaldırılır. Yayına devam etmek için TV ekranındaki kodu Mac'e yeniden girmen gerekir.")
            .setPositiveButton("Sil") { _, _ ->
                control.forgetPairing()
                renderStatus()
            }
            .setNegativeButton("Vazgeç", null)
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
                control.isPaired && computers.isEmpty() -> rescan("liste boş — yeniden aranıyor")
                else -> { control.displayPin(force = true); renderStatus() }
            }
            RemoteKeys.Command.MENU, RemoteKeys.Command.DETAIL -> { showDebug = !showDebug; renderStatus() }
            RemoteKeys.Command.SEARCH -> rescan("yeniden taranıyor…")
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
        val key = control.storedSessionKey() ?: run { renderNote("eşleşme anahtarı yok"); return }
        resuming = true
        renderNote("${c.name} çağrılıyor…")
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
                if (err == null) renderNote("${c.name} çağrıldı — akış parametreleri bekleniyor")
                else renderNote("başlatılamadı: $err", isError = true)
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
