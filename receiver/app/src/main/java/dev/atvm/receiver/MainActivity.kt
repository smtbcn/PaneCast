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
    private lateinit var statusText: TextView
    private lateinit var headerText: TextView
    private lateinit var debugText: TextView
    private var showDebug = false
    private lateinit var pinText: TextView
    private lateinit var pinLabel: TextView
    private lateinit var pinTimer: TextView
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
    private lateinit var devicePanel: android.widget.LinearLayout
    private lateinit var deviceList: android.widget.ListView
    private val computers = arrayListOf<SenderBrowser.Computer>()
    private lateinit var deviceAdapter: android.widget.ArrayAdapter<SenderBrowser.Computer>
    @Volatile private var resuming = false
    private var streaming = false
    private var currentPin: String? = null
    private lateinit var pinPanel: android.view.View

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
                computers.clear(); computers.addAll(list); deviceAdapter.notifyDataSetChanged()
                updatePanels()
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
            setOnFocusChangeListener { _, has -> if (has) renderStatus() }
        }
        statusText = TextView(this).apply {
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 16f
            setBackgroundColor(0xB0000000.toInt())
            setPadding(24, 16, 24, 16)
        }
        // Üst şerit: ne olduğu net okunsun; teknik sayaçlar MENU ile açılan katmanın içinde.
        headerText = TextView(this).apply {
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 20f
            setBackgroundColor(0xB0000000.toInt())
            setPadding(24, 14, 24, 14)
            maxLines = 2
        }
        debugText = TextView(this).apply {
            setTextColor(0xFFBFD0E8.toInt())
            textSize = 14f
            setBackgroundColor(0xC0000000.toInt())
            setPadding(24, 16, 24, 16)
            visibility = android.view.View.GONE
        }
        // Ekran görüntüsüyle doğrulanan kusur: başlık + kod tek TextView'de 64sp ile
        // satırlara sarıyor ve PIN kodu kutudan taşıp görünmüyordu.
        // Şimdi başlık küçük, kod ayrı ve tek satırda, ekranın ortasında.
        pinLabel = TextView(this).apply {
            setTextColor(0xFFB6C2D9.toInt())
            textSize = 26f
            gravity = android.view.Gravity.CENTER
            text = "Eşleştirme PIN'i — bu kodu Mac'teki uygulamaya girin"
            visibility = android.view.View.GONE
        }
        pinTimer = TextView(this).apply {
            setTextColor(0xFF8A97AE.toInt())
            textSize = 22f
            gravity = android.view.Gravity.CENTER
            maxLines = 1
            visibility = android.view.View.GONE
        }
        pinText = TextView(this).apply {
            setTextColor(0xFFFFFFFF.toInt())
            textSize = 132f
            letterSpacing = 0.12f
            typeface = android.graphics.Typeface.MONOSPACE
            gravity = android.view.Gravity.CENTER
            includeFontPadding = false
            maxLines = 1
            setSingleLine(true)
            visibility = android.view.View.GONE
        }
        root.addView(surfaceView, FrameLayout.LayoutParams(-1, -1))
        root.addView(headerText, FrameLayout.LayoutParams(-2, -2, android.view.Gravity.TOP or android.view.Gravity.START))
        root.addView(statusText, FrameLayout.LayoutParams(-2, -2, android.view.Gravity.BOTTOM or android.view.Gravity.START))
        root.addView(debugText, FrameLayout.LayoutParams(-2, -2, android.view.Gravity.END or android.view.Gravity.TOP))
        val pinStack = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            gravity = android.view.Gravity.CENTER
            setBackgroundColor(0xCC05070D.toInt())
            setPadding(64, 48, 64, 48)
            addView(pinLabel, android.widget.LinearLayout.LayoutParams(-2, -2))
            addView(pinText, android.widget.LinearLayout.LayoutParams(-2, -2).apply { topMargin = 18 })
            addView(pinTimer, android.widget.LinearLayout.LayoutParams(-2, -2).apply { topMargin = 14 })
            visibility = android.view.View.GONE
        }
        pinPanel = pinStack
        root.addView(pinStack, FrameLayout.LayoutParams(-2, -2, android.view.Gravity.CENTER))

        // Eşleşme yapıldıysa: TV tarafından bilgisayarı seçip yayını BURADAN başlatabilirsin.
        // Satır iki satırdır: ad büyük, adres+kılavuz soluk (tek satır okunaksız görünüyordu).
        deviceAdapter = object : android.widget.ArrayAdapter<SenderBrowser.Computer>(this,
            android.R.layout.simple_list_item_activated_1, computers) {
            override fun getView(position: Int, convertView: android.view.View?,
                                 parent: android.view.ViewGroup): android.view.View {
                val c = getItem(position) ?: return super.getView(position, convertView, parent)
                return android.widget.LinearLayout(context).apply {
                    orientation = android.widget.LinearLayout.VERTICAL
                    setPadding(28, 18, 28, 18)
                    addView(TextView(context).apply {
                        text = c.name.removePrefix("ATVM-").replace('_', ' ')
                        setTextColor(0xFFFFFFFF.toInt()); textSize = 24f; maxLines = 1
                    })
                    addView(TextView(context).apply {
                        text = "${c.address}:${c.port}  ·  OK: yayını başlat"
                        // Satır odaklıyken turuncu vurgu üstünde soluk mavi okunmuyordu.
                        setTextColor(0xFFE8F0FA.toInt()); textSize = 15f
                    })
                }
            }
        }
        devicePanel = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setBackgroundColor(0xE60B1220.toInt())
            setPadding(36, 28, 36, 20)
            visibility = android.view.View.GONE
        }
        devicePanel.addView(TextView(this).apply {
            text = "Yayın başlatmak için bilgisayarı seç"
            setTextColor(0xFFFFFFFF.toInt()); textSize = 26f
        }, android.widget.LinearLayout.LayoutParams(-2, -2))
        devicePanel.addView(TextView(this).apply {
            text = "Arama tuşu: yeniden tara · Geri: kapat"
            setTextColor(0xFF8A97AE.toInt()); textSize = 18f
        }, android.widget.LinearLayout.LayoutParams(-2, -2).apply { topMargin = 6 })
        deviceList = android.widget.ListView(this).apply {
            adapter = deviceAdapter
            choiceMode = android.widget.AbsListView.CHOICE_MODE_SINGLE
            isFocusable = true
            setOnItemClickListener { _, _, pos, _ -> startFromSelectedDevice(pos) }
        }
        devicePanel.addView(deviceList, android.widget.LinearLayout.LayoutParams(620, 420).apply { topMargin = 14 })
        root.addView(devicePanel, FrameLayout.LayoutParams(-2, -2, android.view.Gravity.CENTER))
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
        ui.post {
            pinText.text = pin
            // pinText/pinLabel başta GONE; görünür yapılmazsa kod ekranda hiç belirmez
            // (ekran görüntüsüyle doğrulanan kusur).
            pinLabel.visibility = android.view.View.VISIBLE
            pinText.visibility = android.view.View.VISIBLE
            pinTimer.visibility = android.view.View.VISIBLE
            pinPanel.visibility = android.view.View.VISIBLE
            renderStatus()
        }
        Log.i(TAG, "PIN ekranda gösteriliyor (değer loglanmaz)")
    }

    override fun onPaired(sessionId: String) {
        Log.i(TAG, "eşleşme tamam session=$sessionId")
        ui.post {
            pinPanel.visibility = android.view.View.GONE
            pinTimer.visibility = android.view.View.GONE
            currentPin = null
            renderStatus()
        }
    }

    override fun onDenied(reason: String) {
        Log.w(TAG, "reddedildi: $reason")
        ui.post { renderStatus() }
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
        ui.post {
            pinPanel.visibility = android.view.View.GONE
            devicePanel.visibility = android.view.View.GONE
            renderStatus()
        }
        return true
    }

    override fun onStopSession(reason: String) {
        ui.post { stopStream(reason) }
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
            if (streaming) stopStream("istemci koptu")
            renderStatus()
        }
    }

    private fun stopStream(reason: String) {
        streaming = false
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
            renderStatus()
            if (!streaming && pinPanel.visibility == android.view.View.VISIBLE) {
                val left = control.pinSecondsLeft()
                val lock = control.lockSecondsLeft()
                if (lock > 0) pinTimer.text = "Çok fazla hatalı deneme · $lock sn sonra yeniden denenebilir"
                else if (left <= 0) { control.displayPin(force = true) }
                else pinTimer.text = "Bu kod $left saniye geçerli · yenisi için SELECT"
            }
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

    private fun renderStatus() {
        val local = localIpv4s()
        val baslik = StringBuilder()
        val alt = StringBuilder()
        val teknik = StringBuilder()

        if (streaming) {
            baslik.append("● YAYINDA  ${decoder.lastProfile}\n")
            baslik.append("fps ${String.format("%.1f", lastFps)}  gecikme ${decoder.latencySummary()}")
            alt.append("BACK: durdur  ·  MENU: ölçüm detayı")
            teknik.append("çözücü: ${decoder.selectedCodecName}  giriş→render: ${decoder.latencySummary()}\n")
            teknik.append("kareler: render=${decoder.rendered.get()} çözücüde=${decoder.inFlight()} gelen=${decoder.submitted.get()} düşen=${decoder.droppedQueueFull.get()} hata=${decoder.decodeError.get()}\n")
            teknik.append("ağ: ${media.summary()}\n")
            teknik.append("ses: ${audio.summary()}\n")
            avClock?.let { teknik.append("senkron: görüntü ofseti ${it.displayOffsetMs} ms (◀ ▶ ile 10 ms)\n") }
        } else if (control.isPaired) {
            val es = if (control.peerName == "-") "eşleşme kayıtlı · bağlantı yok" else "eşleşili: ${control.peerName}"
            baslik.append("HAZIR  ·  $es\n")
            baslik.append("${computers.size} bilgisayar listeleniyor")
            alt.append("OK: bilgisayarı seç ve yayını başlat  ·  SEARCH: yeniden tara  ·  BACK: çık (basılı tut: eşleştirmeyi sil)")
        } else {
            baslik.append("EŞLEŞME BEKLENİYOR\n")
            baslik.append("bu kodu Mac'teki Pane Cast penceresine gir")
            alt.append("SELECT: yeni PIN  ·  BACK: çık")
        }
        if (!streaming) {
            teknik.append("Pane Cast ${packageInfoVersion()}  ·  IP ${local.ifEmpty { listOf("(yok)") }.joinToString(", ")}\n")
            teknik.append("kontrol tcp/${Protocol.CONTROL_PORT}  medya udp/${Protocol.MEDIA_PORT}  mDNS ${Protocol.SERVICE_TYPE}\n")
        }
        if (statusNote.isNotEmpty()) alt.append("\n").append(statusNote)

        // Kullanıcı isteği: yayındayken ekranın üstünde metin katmanı olmasın — temiz görüntü.
        // Ölçüm gerektiğinde MENU ile teknik katman açılır.
        headerText.visibility = if (streaming && !showDebug) android.view.View.GONE else android.view.View.VISIBLE
        statusText.visibility = if (streaming && !showDebug) android.view.View.GONE else android.view.View.VISIBLE
        headerText.text = baslik.toString()
        statusText.text = alt.toString()
        debugText.text = teknik.toString()
        debugText.visibility = if (showDebug) android.view.View.VISIBLE else android.view.View.GONE
        updatePanels()
    }

    private fun packageInfoVersion(): String = try {
        packageManager.getPackageInfo(packageName, 0).versionName ?: "?"
    } catch (e: Exception) { "?" }

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

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_BACK -> {
                if (unpairDialog?.isShowing == true) return super.onKeyDown(keyCode, event)
                if (streaming) { stopStream("kullanıcı DURDUR"); return true }
                if (control.isPaired) {
                    event.startTracking()      // uzun basış onKeyLongPress'e düşer
                    return true
                }
                return super.onKeyDown(keyCode, event)
            }
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER -> {
                if (!streaming) {
                    if (control.isPaired) { startFromSelectedDevice(deviceList.checkedItemPosition.coerceAtLeast(0)) }
                    else { control.displayPin(force = true); renderStatus() }
                    return true
                }
            }
            KeyEvent.KEYCODE_MENU -> { showDebug = !showDebug; renderStatus(); return true }
            // İnsan kalibrasyonu (flaş/bip klibiyle): panelin görüntüye eklediği gecikme ölçülemiyor.
            KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT -> {
                val c = avClock
                if (streaming && c != null) {
                    c.displayOffsetMs += if (keyCode == KeyEvent.KEYCODE_DPAD_RIGHT) 10 else -10
                    Log.i(TAG, "görüntü ofseti ${c.displayOffsetMs} ms")
                    renderStatus(); return true
                }
            }
            KeyEvent.KEYCODE_SEARCH -> {
                browser?.stop(); browser?.start(); renderNote("yeniden taranıyor…"); return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    /// BACK'a basılı tutulunca eşleşme silme onayı sorulur.
    override fun onKeyLongPress(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_BACK && !streaming && control.isPaired && unpairDialog?.isShowing != true) {
            confirmUnpair()
            return true
        }
        return super.onKeyLongPress(keyCode, event)
    }

    /// Kısa BACK uygulamadan çıkar; uzun basış eşleşme silme onayı sorar (onKeyLongPress).
    /// Çıkış onDestroy'i çalıştırır: mDNS kaydı, soketler, çözücü ve ses hattı serbest kalır.
    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_BACK && !streaming && unpairDialog?.isShowing != true) {
            if (!event.isLongPress) finish()
            return true
        }
        return super.onKeyUp(keyCode, event)
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
            val err = SenderConnector.resume(c.address, c.port, Build.MODEL,
                localIpv4s().firstOrNull() ?: "", Protocol.MEDIA_PORT, key, control)
            runOnUiThread {
                resuming = false
                if (err == null) renderNote("${c.name} çağrıldı — akış parametreleri bekleniyor")
                else renderNote("başlatılamadı: $err")
            }
        }.start()
    }

    private fun renderNote(t: String) { statusNote = t; renderStatus() }
    private var statusNote: String = ""

    /** Hangi panelin görüneceği: eşleşme yoksa PIN, eşleşme varsa bilgisayar listesi. */
    private fun updatePanels() {
        if (streaming) {
            devicePanel.visibility = android.view.View.GONE
            return
        }
        if (control.isPaired) {
            pinPanel.visibility = android.view.View.GONE
            devicePanel.visibility = android.view.View.VISIBLE
            devicePanel.requestFocus()
        } else {
            devicePanel.visibility = android.view.View.GONE
            if (currentPin != null) pinPanel.visibility = android.view.View.VISIBLE
        }
    }

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
