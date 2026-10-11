package dev.atvm.receiver

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.max

/** MediaCodec tabanlı, Surface'a doğrudan render eden H.264 çözücü.
 *  bu cihazda yazılımsal H.264 1080p'de 13–19 fps → donanım zorunlu. */
class H264DecoderRenderer {
    companion object {
        private const val TAG = "ATVM-Decoder"
        private const val MIME = MediaFormat.MIMETYPE_VIDEO_AVC
        /** Kuyrukta bu sayıdan eski AU varsa düşürülür: canlı yansıtmada gecikme biriktirmeyiz. */
        private const val QUEUE_CAPACITY = 3
        /** Besleme tavanı YOK: çözücü girdi verdikçe beslenir; birikinti, son çıkan karenin
         *  gerçek gecikmesiyle (pts eşlemesi) ölçülüp GOP atlanarak temizlenir. */
        private const val LATENCY_JUMP_MS = 220.0
        /** Çıktısı beklenen (atılmamış) bu kadar AU varsa GOP atlanır. */
        private const val BACKLOG_JUMP = 24
    }

    @Volatile private var running = false
    /** Çözücü döngüsü çalışıyor mu: durum hatasıyla biterse flush isteği işlenmez, yeniden kurmak gerekir. */
    @Volatile private var loopAlive = false
    fun isAlive(): Boolean = loopAlive
    private var codec: MediaCodec? = null
    /** Çözücünün bağlı olduğu yüzey: aynı yüzeyde yeni oturum örneği korur. */
    private var codecSurface: Surface? = null
    /** Çözücü iş parçacığına flush isteği. Codec'e yalnız o iş parçacığı dokunur;
     *  başka iş parçacığından flush, elde tutulan tampon indekslerini geçersiz kılardı. */
    private class FlushRequest(val reason: String, val newSession: Boolean) { val done = CountDownLatch(1) }
    private val flushRequest = AtomicReference<FlushRequest?>(null)
    private var thread: Thread? = null
    private val queue = ArrayBlockingQueue<AccessUnit>(QUEUE_CAPACITY)

    val rendered = AtomicLong(0)
    /** Çözücüye BAŞARIYLA verilmiş AU sayısı (kuyruk dolup düşürülenler hariç). */
    val fed = AtomicLong(0)
    /** submit() çağrısı sayısı (kuyruk doluysa düşürülebilir). */
    val submitted = AtomicLong(0)
    val droppedQueueFull = AtomicLong(0)
    val decodeError = AtomicLong(0)
    val droppedNoInput = AtomicLong(0)
    /** Kuyrukta yaşlandığı için atlanan kare sayısı (taze kare tercih edildi). */
    val droppedBacklog = AtomicLong(0)
    /** İlk çıktı gecikmesi: çözücü kare alıyor ama hiç üretmiyor. */
    val stalledPastPrime = AtomicLong(0)
    /** Çözücünün "henüz çıktım yok" dediği tur sayısı (yüzey mi, çözücü motive ayırt eder). */
    val tryAgain = AtomicLong(0)
    /** GOP atlama modunda anahtar kare beklenirken düşürülen AU. */
    val droppedResync = AtomicLong(0)
    /** Soğuk çözücüye giderken düşürülen anahtar-kare-olmayan AU. */
    val droppedNotKey = AtomicLong(0)
    /** Örnek korunarak yapılan flush sayısı (kurtarma + yeni oturum). */
    val flushes = AtomicLong(0)
    /** true → kuyruk taşması sonrası bir sonraki anahtar kareye kadar her şey atılır. */
    private val awaitKey = AtomicBoolean(false)
    /** Kilitlenme kurtarma isteği: üst katman çözücüyü boşaltıp anahtar kare ister. */
    @Volatile var onStalled: (() -> Unit)? = null
    /** Çözücünün gerçek çıktı boyutu (kırpma sonrası, piksel): yerleşim kaynağı budur, `start` değil. */
    @Volatile var onVideoSize: ((Int, Int) -> Unit)? = null
    /** Çözücünün çıktı tamponları ilk SPS boyutuna ayrılır ve sonradan büyümez; sonraki bir resim
     *  bu boyutu aşarsa TV'nin görüntü yolu onu kırpıyordu (ölçüldü: hnd[608 944] Src[960 704]
     *  crop{608 704}). Aşıldığında üst katman çözücüyü yeni boyutla yeniden kurar. */
    @Volatile var onOutgrown: ((Int, Int) -> Unit)? = null
    @Volatile private var allocW = 0
    @Volatile private var allocH = 0
    /** Kuyruk doldu (gelen kare düşürüldü): GOP atlaması için anahtar kare istenir. */
    @Volatile var onBackpressure: (() -> Unit)? = null
    /** Çözücünün kendi içinde attığı kare (girdi aldı, çıktı vermedi; logcat `D:` sayacı).
     *  Ölçülen neden: TV'nin görüntü yolu kare hızını pts aralıklarından tahmin ediyor;
     *  ScreenCaptureKit'in titrek damgalarında 48 ya da 30 Hz seçip fazlasını atıyordu. */
    val droppedInDecoder = AtomicLong(0)
    /** pts'si bekleyenlerde bulunmayan çıktı: pts eşleme varsayımının bekçisi. */
    val ptsMiss = AtomicLong(0)
    /** Çözücüye verilmiş, çıktısı beklenen AU'lar: (pts µs, veriliş nanoTime).
     *  Sıra sayarak eşlemek yanlıştı: çözücünün attığı her kare birikinti sanılıyor,
     *  25 atılan karede besleme kalıcı kesiliyordu (ölçüldü: "kilitlenme" buydu).
     *  B-frame yok → çıktı pts'leri artan; çıktıdan eski bekleyenler atılmıştır. */
    private val pending = ArrayDeque<LongArray>(64)
    /** Son 240 kare için çözücü-girişi → render gecikmesi (ms). */
    private val recentLatency = ArrayDeque<Double>(241)
    private val latencyLock = Any()
    /** Son çıkan karenin gecikmesi (ms): GOP atlama kararı anlık değere bakar. */
    @Volatile private var lastLatencyMs = 0.0

    @Volatile var lastArrivalNanos = 0L
        private set
    @Volatile var selectedCodecName = "-"
    /** Arayüz şeridi için: "1920×1080@60". */
    @Volatile var lastProfile = "-"
        private set
    /** Son beslenen karenin çözücüye verilen zaman damgası (µs). */
    @Volatile var lastPtsUs = -1L
        private set
    /** Çözücüye verilen pts, beslenen her AU için tam 1/fps ilerler — RTP damgası değil.
     *  Ölçüldü: TV'nin görüntü yolu kaynak kare hızını ilk ~2,5 sn'deki pts aralıklarından
     *  çıkarıyor (`forceFrameRate 0`). ScreenCaptureKit damgaları titrek ve içerikteki 24/30p
     *  videonun kadansını taşıyor → yol 48 Hz ya da yarım hıza (≈29 fps) kilitlenip
     *  fazla kareyi atıyordu. 60 Hz ızgaraya yuvarlamak yetmedi (atlanan karenin 33 ms'lik
     *  aralığı yine 30 Hz seçtirdi); yalnız sabit adım her içerikte tam hızı verdi.
     *  Gösterim pts'ye göre bekletilmediği için (düşük gecikme kipi) kayma gecikme üretmez. */
    private var nextPtsUs = 0L
    private var frameStepUs = 16_667L

    /** Yeni oturum. Aynı yüzeyde çalışan bir örnek varsa korunur: flush + sayaç sıfırlama
     *  (pencere değişimi). Yeni örnek yalnız çözücü yoksa ya da yüzey değiştiyse kurulur. */
    fun startOrReuse(width: Int, height: Int, fps: Int, surface: Surface): Boolean {
        if (codec != null && loopAlive && codecSurface === surface && width <= 1920 && height <= 1088 &&
            width <= allocW && height <= allocH) {
            lastProfile = "${width}×$height@$fps"
            frameStepUs = 1_000_000L / max(1, fps)
            val r = FlushRequest("yeni oturum ${width}x$height", newSession = true)
            flushRequest.set(r)
            // Yeni hattın ilk IDR'si flush'tan önce kuyruğa girip silinmesin: flush bitene dek bekle.
            if (r.done.await(1, TimeUnit.SECONDS)) return true
            Log.w(TAG, "flush zamanında bitmedi → çözücü yeniden kuruluyor")
        }
        return start(width, height, fps, surface)
    }

    /** Oturum içi kurtarma: örnek korunur, boru hattı boşaltılır, sonraki anahtar kare beklenir.
     *  Ölçüldü: örneği yeniden kurmak görüntü yolunu baştan açtırıyor (siyah kare, ~2 sn). */
    fun requestFlush(reason: String): Boolean {
        if (codec == null || !loopAlive) return false
        flushRequest.set(FlushRequest(reason, newSession = false))
        return true
    }

    fun start(width: Int, height: Int, fps: Int, surface: Surface): Boolean {
        stop()
        val name = pickHardwareDecoder() ?: run {
            Log.e(TAG, "donanım H.264 çözücü bulunamadı")
            return false
        }
        selectedCodecName = name
        lastProfile = "${width}×$height@$fps"
        val format = MediaFormat.createVideoFormat(MIME, width, height).apply {
            setInteger(MediaFormat.KEY_MAX_WIDTH, max(width, 1920))
            setInteger(MediaFormat.KEY_MAX_HEIGHT, max(height, 1088))
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            // Cihaz media_codecs.xml AVC için "low-latency" feature'ını beyan ediyor
            // (artifacts/tv/media_codecs.xml:105). Bayrağın kabul edilmemesi hata değildir.
            try { setInteger("low-latency", 1) } catch (e: Exception) { Log.w(TAG, "low-latency ayarlanamadı: $e") }
        }
        return try {
            val c = MediaCodec.createDecoderByType(MIME)
            c.configure(format, surface, null, 0)
            // Çözücü, doğru oranlı yüzeyi doldurur; kırpma modu görüntüyü keserdi.
            try { c.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT) } catch (e: Exception) { Log.w(TAG, "ölçekleme kipi: $e") }
            c.start()
            codec = c
            codecSurface = surface
            allocW = width; allocH = height
            running = true
            flushRequest.set(null)
            resetSessionCounters()
            flushes.set(0)
            nextPtsUs = 0L
            frameStepUs = 1_000_000L / max(1, fps)
            loopAlive = true
            thread = Thread({ loop(c) }, "atvm-decode").apply { priority = Thread.MAX_PRIORITY; start() }
            Log.i(TAG, "çözücü başladı: $name ${width}x$height @${fps}fps low-latency denendi")
            true
        } catch (e: Exception) {
            Log.e(TAG, "çözücü kurulamadı", e)
            codec = null
            codecSurface = null
            false
        }
    }

    /** Ölçüm kusuru: fed sayacı ve varış kuyruğu sıfırlanmıyordu; ikinci oturumda
     *  "gecikme p50 16776 ms" ve "inflight 1411" gibi saçma değerler üretiyordu. */
    private fun resetSessionCounters() {
        droppedQueueFull.set(0); rendered.set(0); submitted.set(0)
        fed.set(0); droppedNoInput.set(0); decodeError.set(0); stalledPastPrime.set(0)
        droppedBacklog.set(0); droppedResync.set(0); droppedNotKey.set(0); tryAgain.set(0)
        droppedInDecoder.set(0); ptsMiss.set(0); lastLatencyMs = 0.0
        awaitKey.set(false)
        synchronized(latencyLock) { pending.clear(); recentLatency.clear() }
    }

    /** Ortak saat (§5.1): varsa AU gösterim anına göre bekletilip öyle beslenir, pts = medya µs. */
    @Volatile var avClock: AvClock? = null

    fun submit(au: AccessUnit): Boolean {
        val clk = avClock
        return (clk != null && clk.pace(au) { submitNow(it) }) || submitNow(au)
    }

    /** UDP alıcı (ya da AvClock bekletme) thread'inden çağrılır.
     *  İki kural (H.264'ün kendisinden, cihazdan değil):
     *  1) Soğuk çözücü rastgele erişim noktası ister: ilk kare çıkana dek anahtar-kare
     *     olmayan AU beslenmez (ölçüldü: GOP ortadan beslenen 8 AU → rendered=0).
     *  2) Taşıma anında sıra BOZULMAZ, GOP atlanır: kuyruk dolarsa kuyruk boşaltılır ve
     *     sonraki anahtar kareye kadar her şey düşürülür. "En yeniyi tut" politikası GOP
     *     içinde delik açtığı için çözücüyü susturuyordu. */
    private fun submitNow(au: AccessUnit): Boolean {
        submitted.incrementAndGet()
        lastArrivalNanos = System.nanoTime()
        if (rendered.get() == 0L && !au.keyFrame) {
            droppedNotKey.incrementAndGet()
            onBackpressure?.invoke()
            return false
        }
        if (awaitKey.get()) {
            if (!au.keyFrame) { droppedResync.incrementAndGet(); return false }
            queue.clear()
            awaitKey.set(false)
            return queue.offer(au)
        }
        if (!queue.offer(au)) {
            queue.clear()
            droppedQueueFull.incrementAndGet()
            awaitKey.set(true)
            onBackpressure?.invoke()
            if (au.keyFrame) { queue.offer(au); awaitKey.set(false) }
            return au.keyFrame
        }
        return true
    }

    fun stop() {
        running = false
        codecSurface = null
        queue.clear()
        thread?.let { t ->
            try { t.interrupt(); t.join(1000) } catch (e: Exception) { }
        }
        thread = null
        codec?.let { c ->
            try { c.stop() } catch (e: Exception) { Log.w(TAG, "stop: $e") }
            try { c.release() } catch (e: Exception) { Log.w(TAG, "release: $e") }
        }
        codec = null
        flushRequest.getAndSet(null)?.done?.countDown()
    }

    /** Çözücüye verilip çıktısı beklenen kare sayısı (gerçek birikinti; atılanlar hariç). */
    fun inFlight(): Long = synchronized(latencyLock) { pending.size.toLong() }

    /** Uygulama tarafı bekleme kuyruğunun doluluğu (0..QUEUE_CAPACITY). */
    fun queueSize(): Int = queue.size

    /** Son 240 karenin "çözücü girişi → render" gecikmesi, ms. */
    fun latencySummary(): String = synchronized(latencyLock) {
        if (recentLatency.isEmpty()) "n/a"
        else {
            val s = recentLatency.toList().sorted()
            String.format("p50=%.1f p95=%.1f max=%.1f ms",
                s[s.size / 2], s[(s.size * 95) / 100], s.last())
        }
    }

    private fun pickHardwareDecoder(): String? {
        val list = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos
            .filter { it.supportedTypes.any { t -> t.equals(MIME, true) } }
        // MediaCodecInfo.isSoftwareOnly / isHardwareAccelerated API 29'da geldi (minSdk 26):
        // eski sürümde addan çıkarım yapılır.
        fun softwareOnly(i: MediaCodecInfo): Boolean =
            if (android.os.Build.VERSION.SDK_INT >= 29) i.isSoftwareOnly
            else i.name.startsWith("OMX.google.", true) || i.name.startsWith("c2.android.", true) ||
                i.name.contains(".sw.", true)
        val hw = list.filter { !softwareOnly(it) }
        val chosen = hw.firstOrNull { it.name.contains(".MS.", true) }
            ?: hw.firstOrNull { !it.name.contains("google") && !it.name.contains("c2.android") }
            ?: hw.firstOrNull()
            ?: list.firstOrNull()
        chosen?.let {
            val hwAccel = if (android.os.Build.VERSION.SDK_INT >= 29) it.isHardwareAccelerated.toString() else "bilinmiyor"
            Log.i(TAG, "seçilen çözücü=${it.name} softwareOnly=${softwareOnly(it)} hwAccel=$hwAccel encoder=${it.isEncoder}")
        }
        return chosen?.name
    }

    private fun loop(c: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        val timeoutUs = 4000L
        var lastOutputNanos = System.nanoTime()
        var lastStallNanos = 0L
        var fedSinceOutput = 0
        /** Flush sonrası ilk beslenen AU anahtar kare olmalı (submit ile yarışı burada kapanır). */
        var needKey = false
        while (running) {
            try {
                flushRequest.getAndSet(null)?.let { r ->
                    awaitKey.set(true)
                    queue.clear()
                    c.flush()
                    needKey = true
                    fedSinceOutput = 0
                    lastOutputNanos = System.nanoTime()
                    flushes.incrementAndGet()
                    // pts oturumlar arasında da geri gitmez: nextPtsUs korunur.
                    if (r.newSession) resetSessionCounters()
                    else synchronized(latencyLock) { pending.clear() }
                    // Yeni oturumda anahtar kare kapısı rendered=0 şartıdır; kurtarmada awaitKey.
                    if (r.newSession) awaitKey.set(false)
                    r.done.countDown()
                    Log.i(TAG, "çözücü boşaltıldı (flush, örnek korundu): ${r.reason}")
                }
                // 1) Kuyrukta AU varsa ve çözücüde yer varsa BESLE — katı sırayla (FIFO).
                //    GOP içi kare atlamak referans zincirini kırıyor ve bu çözücü bundan
                //    sonra hiç kare üretmiyor (ölçüldü: beslenen=8 rendered=0 döngüsü).
                //    Geri kalınırsa kuyruk dolar; `submit` gelen kareyi düşürüp anahtar kare
                //    ister, böylece atlama GOP sınırında temiz olur.
                // Birikinti gecikmeye dönüştüyse temizlen: kuyruğu boşalt, taze IDR bekle.
                // Karar bir kez verilir ve ölçüm sıfırlanır; eski hâli her turda kuyruğun
                // başını (beklenen IDR dahil) atıp çözücüyü kalıcı aç bırakıyordu.
                val late = rendered.get() > 0 && !awaitKey.get() &&
                    (lastLatencyMs > LATENCY_JUMP_MS || inFlight() > BACKLOG_JUMP)
                if (late) {
                    awaitKey.set(true)
                    queue.clear()
                    droppedBacklog.incrementAndGet()
                    synchronized(latencyLock) { pending.clear() }
                    lastLatencyMs = 0.0
                    onBackpressure?.invoke()
                }
                run {
                    var au = queue.poll(4, TimeUnit.MILLISECONDS)
                    if (au != null && needKey) {
                        if (au.keyFrame) needKey = false
                        else { droppedResync.incrementAndGet(); au = null }
                    }
                    if (au != null) {
                        val inIdx = c.dequeueInputBuffer(timeoutUs)
                        if (inIdx >= 0) {
                            val ib: ByteBuffer = c.getInputBuffer(inIdx)!!
                            ib.clear(); ib.put(au.data)
                            val ptsUs = nextPtsUs
                            nextPtsUs += frameStepUs
                            // Ortak saatte medya zamanı yalnız A/V eşlemesi için; çözücüye düzenli 1/fps pts gider.
                            val mediaUs = avClock?.takeIf { it.sync }?.videoMediaUs(au.rtpTimestamp) ?: -1L
                            lastPtsUs = ptsUs
                            c.queueInputBuffer(inIdx, 0, au.data.size, ptsUs, 0)
                            val n = fed.incrementAndGet()
                            if (n <= 6) {
                                Log.i(TAG, "beslenen AU #$n key=${au.keyFrame} nal=${au.nalCount} " +
                                    "boyut=${au.data.size} ts=${au.rtpTimestamp}")
                            }
                            synchronized(latencyLock) { pending.addLast(longArrayOf(ptsUs, System.nanoTime(), mediaUs)) }
                            fedSinceOutput++
                        } else {
                            droppedNoInput.incrementAndGet()
                            queue.offer(au)     // sıra bozulmasın: AU kuyruğa geri döner
                        }
                    }
                }
                // 2) Çıktı al ve render et
                var outIdx0 = c.dequeueOutputBuffer(info, timeoutUs)
                if (outIdx0 == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    reportOutputFormat(c.outputFormat)
                    outIdx0 = c.dequeueOutputBuffer(info, 0)
                }
                if (outIdx0 == MediaCodec.INFO_TRY_AGAIN_LATER) tryAgain.incrementAndGet()
                var outIdx = outIdx0
                while (outIdx >= 0) {
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        c.releaseOutputBuffer(outIdx, false)
                    } else {
                        // Anında sunum. releaseOutputBuffer(idx, System.nanoTime()) yeniden
                        // ölçüldü: hatasız ve aynı sonuç (56 fps, p95 10 ms) — kare atma
                        // çözücünün içinde, çıkış zamanlaması onu etkilemiyor.
                        c.releaseOutputBuffer(outIdx, true)
                        // Surface'a çözmede BufferInfo.size çoğunlukla 0'dır (pikseller
                        // yüzeydedir, tamponda değil). Boyuta göre saymak kareleri
                        // gözden kaçırıyordu; CODEC_CONFIG dışındaki her çıktı sayılır.
                        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                            rendered.incrementAndGet()
                            val mediaUs = recordLatency(info.presentationTimeUs)
                            if (mediaUs != null && mediaUs >= 0) avClock?.onVideoRendered(mediaUs, System.nanoTime(), lastLatencyMs)
                            lastOutputNanos = System.nanoTime()
                            fedSinceOutput = 0
                        }
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            Log.i(TAG, "çözücü EOS gördü")
                        }
                    }
                    outIdx = c.dequeueOutputBuffer(info, 0)
                    // Bilgi bir kez döner: döngüyü bitirmeden okunmazsa boyut değişimi kaybolur.
                    if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        reportOutputFormat(c.outputFormat)
                        outIdx = c.dequeueOutputBuffer(info, 0)
                    }
                }
                // 3) Bekleyici: AU akıyor ama çözücü uzun süredir tek kare üretmiyor.
                //    Eşik 1,2 sn idi → soğuk boru hattı "kilitlenme" sanılıp yeniden kuruluyordu
                //    (ölçüldü: 8 besle/0 çıkar döngüsü). 3,5 sn ve en fazla 3 kurtarma (MainActivity).
                //    Son çıktıdan beri beslenen AU şartı: kaynak durağanken (AU gelmezken)
                //    "kilitlendi" sanılıp yayın kesiliyordu (ölçüldü: beslenen=rendered=872).
                val now = System.nanoTime()
                if (fedSinceOutput >= BACKLOG_JUMP / 2 &&
                    now - lastOutputNanos > 3_500_000_000L &&
                    now - lastStallNanos > 5_000_000_000L) {
                    lastStallNanos = now
                    stalledPastPrime.incrementAndGet()
                    Log.e(TAG, "çözücü kilitlendi: beslenen=$fed rendered=$rendered " +
                        "kuyruk=${queueSize()} → kurtarma isteniyor")
                    onStalled?.invoke()
                }
            } catch (e: IllegalStateException) {
                decodeError.incrementAndGet()
                Log.e(TAG, "çözücü durum hatası", e)
                // Döngü biterse kimse kilitlenmeyi fark etmez: üst katman yeniden kursun.
                if (running) { loopAlive = false; onStalled?.invoke() }
                break
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt(); break
            } catch (e: Exception) {
                decodeError.incrementAndGet()
                Log.e(TAG, "çözücü döngü hatası", e)
            }
        }
        if (codec === c || codec == null) loopAlive = false   // geç biten eski döngü yenisini öldürmesin
        flushRequest.getAndSet(null)?.done?.countDown()
        Log.i(TAG, "çözücü döngüsü bitti (rendered=${rendered.get()})")
    }

    /** Çıktı biçimi değişti (ilk SPS ya da pencere yeniden boyutlanınca yeni SPS): gösterim boyutu
     *  = KEY_WIDTH/HEIGHT, varsa kırpma (crop-*) sonrası. */
    private fun reportOutputFormat(f: MediaFormat) {
        fun int(k: String): Int? = if (f.containsKey(k)) f.getInteger(k) else null
        val w = int(MediaFormat.KEY_WIDTH) ?: return
        val h = int(MediaFormat.KEY_HEIGHT) ?: return
        val cl = int("crop-left"); val cr = int("crop-right")
        val ct = int("crop-top"); val cb = int("crop-bottom")
        val dw = if (cl != null && cr != null) cr - cl + 1 else w
        val dh = if (ct != null && cb != null) cb - ct + 1 else h
        Log.i(TAG, "çıktı biçimi: ${w}x$h kırpma[$cl,$ct,$cr,$cb] → gösterim ${dw}x$dh")
        if (dw > 0 && dh > 0) {
            onVideoSize?.invoke(dw, dh)
            if (dw > allocW || dh > allocH) onOutgrown?.invoke(dw, dh)
        }
    }

    /** Çıktıyı pts ile girdisine eşler; daha eski bekleyenler çözücüde atılmıştır.
     *  Eşleşen karenin medya zamanını döndürür (ortak saat yoksa -1). */
    private fun recordLatency(outPtsUs: Long): Long? {
        val entry = synchronized(latencyLock) {
            while (pending.isNotEmpty() && pending.first()[0] < outPtsUs) {
                pending.removeFirst()
                droppedInDecoder.incrementAndGet()
            }
            if (pending.isNotEmpty() && pending.first()[0] == outPtsUs) pending.removeFirst() else null
        }
        if (entry == null) { ptsMiss.incrementAndGet(); return null }
        val ms = (System.nanoTime() - entry[1]) / 1_000_000.0
        if (ms < 0 || ms > 60_000) return entry[2]
        lastLatencyMs = ms
        synchronized(latencyLock) {
            if (recentLatency.size >= 240) recentLatency.removeFirst()
            recentLatency.addLast(ms)
        }
        return entry[2]
    }

}
