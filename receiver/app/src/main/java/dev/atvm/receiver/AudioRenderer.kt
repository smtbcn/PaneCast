package dev.atvm.receiver

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.util.Log
import java.util.Locale
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos

/**
 * RTP/L16 PCM (PT=97, 48 kHz, 5 ms paketler) sesini çalar ve ortak saate (AvClock) hizalar.
 *
 * - Titreşim tamponu RTP sıra numarasıyla anahtarlıdır; çift paket atılır. Eksik paket,
 *   iz boşalmak üzereyken (HAL periyodu + 1 paket kala) gizlenir: son çıkışın ters-düz
 *   tekrarı 15 ms'de sessizliğe söner, gerçek ses dönünce çapraz geçişle bağlanır — sınırda
 *   basamak (tık) oluşmaz. Geç gelip gizlenmiş paket titreşim payını büyütür.
 * - Zamanlama: `getTimestamp` ile sıradaki yazılacak örneğin duyulacağı an bilinir; olması
 *   gereken an (medya zamanı + P) ile fark ≤80 ms ise paket başına ≤2 örnek doğrusal yeniden
 *   örneklemeyle (%0,8 hız, duyulmaz) kapatılır, daha büyükse sönümlü sessizlik eklenir ya da
 *   paket atılıp çapraz geçilir. Saat kayması ve gönderenin yeniden çapalaması böyle emilir.
 * - Bu TV düşük gecikmeli (FAST) izi veriyor ama HAL yolu ~107 ms (ölçüldü); eski 160 ms'lik
 *   normal iz + 60 ms ön-dolum toplamda ~215 ms'ye çıkıyordu.
 * - Yazım KENDİ iş parçacığında: UDP döngüsünde bloklanan yazım görüntüyü 1–2 fps'ye düşürmüştü.
 *
 * AAC denendi ve geri alındı: macOS tarafında `AVAudioCompressedBuffer` AAC biçimleriyle
 * SIGSEGV üretiyor, `AudioConverterFillComplexBuffer` 'what' hatası veriyor (ölçüldü).
 */
class AudioRenderer {
    companion object {
        private const val TAG = "ATVM-Audio"
        private const val SLOTS = 128               // 640 ms
        private const val MAX_FRAMES = 960          // paket başına en çok 20 ms
        private const val BLOCK = 240               // 5 ms
        private const val BUFFER_PERIODS = 3
        private const val MAX_BUFFER_PERIODS = 6
        private const val JITTER_START_MS = 20
        private const val JITTER_MIN_MS = 10
        private const val JITTER_MAX_MS = 60
        /** Gizleme bu kadar blokta (15 ms) sessizliğe söner. */
        private const val DECAY_FRAMES = 3 * BLOCK
        /** Tampon boşken bu kadar ardışık gizlemeden sonra (100 ms) akış durmuş sayılır. */
        private const val IDLE_AFTER = 20
        private const val MAP = 128
        private const val REAL = 0
        private const val PLC = 1
        private const val IDLE = 2
    }

    @Volatile var avClock: AvClock? = null
    /** HAL'in bir okumada çektiği çerçeve (AudioManager PROPERTY_OUTPUT_FRAMES_PER_BUFFER). */
    @Volatile var outputPeriodFrames = 960

    @Volatile private var running = false
    private var thread: Thread? = null
    private var firstTrack: AudioTrack? = null
    private var rate = 48_000
    private var ch = 2

    // ---- titreşim tamponu (jb kilidiyle) ----
    private val jb = java.lang.Object()
    private val slotSeq = IntArray(SLOTS) { -1 }
    private val slotUs = LongArray(SLOTS)
    private val slotFrames = IntArray(SLOTS)
    private val slotData = Array(SLOTS) { ShortArray(MAX_FRAMES * 2) }
    @Volatile private var jbCount = 0
    private var expected = -1
    private var firstSeq = -1
    private val concealed = IntArray(16) { -1 }
    private var concealedIdx = 0
    @Volatile private var lateFlag = false

    val bytesWritten = AtomicLong(0)
    val writes = AtomicLong(0)
    val packets = AtomicLong(0)
    val dup = AtomicLong(0)
    val late = AtomicLong(0)
    val plc = AtomicLong(0)
    val resyncs = AtomicLong(0)
    val restarts = AtomicLong(0)
    val idles = AtomicLong(0)
    val jumps = AtomicLong(0)
    /** Küçük düzeltmelerle net atılan (+) / eklenen (−) örnek: iki ses saati arasındaki kayma. */
    val trimmed = AtomicLong(0)
    /** En büyük |örnek| — gerçekten ses mi akıyor, sessizlik mi. */
    val peakSample = AtomicLong(0)
    private val underrunsDone = AtomicLong(0)
    @Volatile private var curTrack: AudioTrack? = null
    @Volatile private var jitterMs = JITTER_START_MS
    @Volatile private var halNs = Long.MIN_VALUE
    @Volatile private var aqSum = 0L
    @Volatile private var aqN = 0L

    // ---- pompa durumu (yalnız pompa iş parçacığı) ----
    private var written = 0L
    private val ats = AudioTimestamp()
    private var tsNs = 0L
    private var tsFp = -1L
    private var lastTsPoll = 0L
    private var lastUnder = 0
    private var guardFrames = 0
    private var period = 960
    private val work = ShortArray(MAX_FRAMES * 2)
    private val tmp = ShortArray(MAX_FRAMES * 2)
    private val out = ShortArray((MAX_FRAMES + 8) * 2)
    private val src = ShortArray((MAX_FRAMES + 8) * 2)
    private val zeros = ShortArray(BLOCK * 2)
    private val hist = FloatArray(2)
    private var srcFrames = 0
    private var contPos = 0
    private var decaying = false
    private var smooth = false
    private var hardAlign = true
    private var plcRun = 0
    private var curUs = 0L
    private var curFrames = BLOCK
    private var nextUs = 0L
    private var lastFrames = BLOCK
    private var lastLateNs = 0L
    private var lastDecayNs = 0L
    private var playStartNs = 0L

    // ---- medya zamanı → çıkış çerçevesi eşlemesi (avErr ölçümü; mapLock ile) ----
    private val mapLock = Object()
    private val mapUs = LongArray(MAP)
    private val mapW = LongArray(MAP)
    private val mapOut = IntArray(MAP)
    private val mapIn = IntArray(MAP)
    private var mapN = 0
    private var pubTsNs = 0L
    private var pubTsFp = -1L

    fun start(sampleRate: Int, channels: Int): Boolean {
        stop()
        rate = sampleRate
        ch = if (channels == 1) 1 else 2
        val t = openTrack() ?: return false
        firstTrack = t
        synchronized(jb) { clearSlots(); expected = -1; firstSeq = -1; lateFlag = false }
        bytesWritten.set(0); writes.set(0); packets.set(0); dup.set(0); late.set(0); plc.set(0)
        resyncs.set(0); restarts.set(0); idles.set(0); jumps.set(0); trimmed.set(0); peakSample.set(0); underrunsDone.set(0)
        jitterMs = JITTER_START_MS; halNs = Long.MIN_VALUE; aqSum = 0; aqN = 0
        avClock?.audioTimeOf = { audioTimeOf(it) }
        running = true
        thread = Thread({ pump() }, "atvm-audio").apply { start() }
        Log.i(TAG, "ses açıldı ${sampleRate}Hz/${ch}ch L16, titreşim payı ${JITTER_START_MS} ms")
        return true
    }

    /** UDP alım döngüsünden: yükü (büyük uçlu L16) tampona koyar; asla bloklamaz. */
    fun offerPacket(seq: Int, rtpTs: Long, data: ByteArray, off: Int, len: Int) {
        if (!running) return
        val frames = len / (2 * ch)
        if (frames <= 0 || frames > MAX_FRAMES) return
        val now = System.nanoTime()
        val clock = avClock
        val us = clock?.audioMediaUs(rtpTs) ?: (rtpTs * 1000 / 48)
        clock?.onAudioArrival(us, now)
        packets.incrementAndGet()
        synchronized(jb) {
            if (expected >= 0) {
                val d = seqDiff(seq, expected)
                if (d < 0) {
                    if (concealed.contains(seq)) { late.incrementAndGet(); lateFlag = true } else dup.incrementAndGet()
                    return
                }
                if (d >= SLOTS) {
                    Log.w(TAG, "ses sırası $d paket sıçradı — baştan hizalanıyor")
                    clearSlots(); expected = -1; firstSeq = -1
                }
            }
            val i = seq and (SLOTS - 1)
            if (slotSeq[i] == seq) { dup.incrementAndGet(); return }
            if (slotSeq[i] < 0) jbCount++
            val dst = slotData[i]
            var peak = 0
            for (k in 0 until frames * ch) {
                val s = ((data[off + 2 * k].toInt() shl 8) or (data[off + 2 * k + 1].toInt() and 0xFF)).toShort()
                dst[k] = s
                val a = abs(s.toInt())
                if (a > peak) peak = a
            }
            if (peak > peakSample.get()) peakSample.set(peak.toLong())
            slotSeq[i] = seq; slotUs[i] = us; slotFrames[i] = frames
            if (expected < 0 && firstSeq < 0) firstSeq = seq
            jb.notifyAll()
        }
    }

    private fun seqDiff(a: Int, b: Int): Int = ((a - b) shl 16) shr 16

    private fun clearSlots() { slotSeq.fill(-1); jbCount = 0 }

    private fun openTrack(): AudioTrack? = try {
        val mask = if (ch == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        val minBuf = AudioTrack.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT)
        period = outputPeriodFrames.coerceIn(64, 4096)
        // Kullanım/tür belirtilmezse TV'de yönlendirme belirsizleşiyor.
        val t = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
            .setAudioFormat(AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(rate).setChannelMask(mask).build())
            .setBufferSizeInBytes(maxOf(minBuf, (MAX_BUFFER_PERIODS + 2) * period * 2 * ch))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .build()
        if (t.state != AudioTrack.STATE_INITIALIZED) {
            Log.e(TAG, "AudioTrack başlatılamadı state=${t.state}")
            t.release(); null
        } else {
            val fast = t.performanceMode == AudioTrack.PERFORMANCE_MODE_LOW_LATENCY
            // Normal karıştırıcı daha büyük parçalarla okur: boşalma payı iki periyot.
            guardFrames = (if (fast) period else 2 * period) + BLOCK
            t.setBufferSizeInFrames(BUFFER_PERIODS * period + BLOCK)
            Log.i(TAG, "iz: düşük gecikme=${if (fast) "verildi" else "VERİLMEDİ"} kapasite=${t.bufferCapacityInFrames} " +
                "etkin=${t.bufferSizeInFrames} çerçeve, HAL periyodu=$period, boşalma payı=$guardFrames")
            t
        }
    } catch (e: Exception) {
        Log.e(TAG, "AudioTrack kurulamadı", e)
        null
    }

    private fun pump() {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)
        var t = firstTrack
        firstTrack = null
        while (running) {
            if (t == null) {
                t = openTrack()
                if (t == null) { pause(500); continue }
            }
            try {
                play(t)
            } catch (e: Exception) {
                Log.e(TAG, "ses hattı hatası — iz yeniden kuruluyor", e)
            }
            closeTrack(t)
            t = null
            if (running) { restarts.incrementAndGet(); pause(100) }
        }
        t?.let { closeTrack(it) }
    }

    private fun pause(ms: Long) { try { Thread.sleep(ms) } catch (e: InterruptedException) { } }

    private fun closeTrack(t: AudioTrack) {
        underrunsDone.addAndGet(try { t.underrunCount.toLong() } catch (e: Exception) { 0L })
        curTrack = null
        try { t.pause() } catch (e: Exception) { }
        try { t.flush() } catch (e: Exception) { }
        try { t.release() } catch (e: Exception) { }
    }

    private fun play(t: AudioTrack) {
        written = 0; tsFp = -1L; lastTsPoll = 0L; lastUnder = 0; halNs = Long.MIN_VALUE
        srcFrames = 0; contPos = 0; decaying = false; smooth = true; hardAlign = true; plcRun = 0
        hist.fill(0f)
        synchronized(mapLock) { mapN = 0; pubTsFp = -1L }
        synchronized(jb) { if (expected >= 0) { firstSeq = expected; expected = -1 } }
        t.play()
        playStartNs = System.nanoTime()
        curTrack = t
        while (running) {
            if (!step(t)) {
                Log.w(TAG, "ses izine yazılamadı — yeniden kuruluyor")
                return
            }
        }
    }

    /** Bir blok üretip yazar; yazım hatasında false. */
    private fun step(t: AudioTrack): Boolean {
        val now = System.nanoTime()
        pollTimestamp(t, now)
        adaptJitter(now)
        // Zaman damgası gelene dek (ilk ~50–100 ms) sessizlik: paketler tamponda bekler, hizalı başlanır.
        if (tsFp < 0 && now - playStartNs < 500_000_000L) return writeOut(t, zeros, BLOCK)
        val queued = queuedFrames(t)
        aqSum += (queued - guardFrames) * 1000 / rate + jbCount * 5L; aqN++
        val clock = avClock
        val p = if (tsFp >= 0 && clock != null) {
            val hal = playTimeOf(written) - now - queued * 1_000_000_000L / rate
            halNs = if (halNs == Long.MIN_VALUE) hal else halNs + (hal - halNs) / 32
            clock.setAudioPath(halNs + guardFrames * 1_000_000_000L / rate, jitterMs * 1_000_000L)
            clock.update(now)
        } else Long.MIN_VALUE

        val kind = nextBlock(t)
        if (kind == IDLE) return writeOut(t, zeros, BLOCK)
        val frames = if (kind == REAL) curFrames else lastFrames
        val us = if (kind == REAL) curUs else nextUs
        var k = 0
        if (p != Long.MIN_VALUE) {
            val e = playTimeOf(written) - (us * 1000 + p)
            val blockNs = frames * 1_000_000_000L / rate
            if (hardAlign || abs(e) > AvClock.JUMP_NS) {
                hardAlign = false
                if (e > blockNs / 2 && kind == REAL) {
                    // Ses geride: e kadar medyayı at, sonraki gerçek paketle çapraz geç.
                    val dropped = 1 + dropBlocks((e / blockNs).toInt() - 1)
                    resyncs.incrementAndGet()
                    Log.i(TAG, String.format(Locale.ROOT, "ses hizalandı: %+.1f ms geride → %d paket atıldı", e / 1e6, dropped))
                    nextUs = us + dropped * frames * 1_000_000L / rate
                    if (srcFrames > 0) smooth = true
                    return true
                }
                if (e < -blockNs / 2) {
                    if (!insertSilence(t, -e)) return false
                    resyncs.incrementAndGet()
                    Log.i(TAG, String.format(Locale.ROOT, "ses hizalandı: %.1f ms önde → sönümlü sessizlik eklendi", -e / 1e6))
                }
            } else {
                k = when {
                    e > 10_000_000L -> 2
                    e > 1_000_000L -> 1
                    e < -10_000_000L -> -2
                    e < -1_000_000L -> -1
                    else -> 0
                }
            }
        }

        if (kind == REAL) {
            if (smooth) crossfadeIn(frames)
            smooth = false
            plcRun = 0
        } else {
            decaying = true
            continuation(work, frames)
            plcRun++
            plc.incrementAndGet()
            smooth = true
        }
        val m = frames - k
        if (k != 0) trimmed.addAndGet(k.toLong())
        resample(frames, m)
        val w0 = written
        if (!writeOut(t, out, m)) return false
        record(us, w0, m, frames)
        if (kind == REAL) {
            System.arraycopy(out, 0, src, 0, m * ch)
            srcFrames = m; contPos = 0; decaying = false
        }
        nextUs = us + frames * 1_000_000L / rate
        lastFrames = frames
        return true
    }

    /** Sıradaki bloğu bekler: gerçek paket (work'e kopyalanır), gizleme ya da boşta. */
    private fun nextBlock(t: AudioTrack): Int {
        synchronized(jb) {
            while (running) {
                if (expected < 0) {
                    if (firstSeq < 0) return IDLE
                    expected = firstSeq; firstSeq = -1
                    hardAlign = true; plcRun = 0
                    srcFrames = 0; contPos = 0; decaying = false; smooth = true
                }
                val i = expected and (SLOTS - 1)
                if (slotSeq[i] == expected) {
                    val n = slotFrames[i]
                    System.arraycopy(slotData[i], 0, work, 0, n * ch)
                    curUs = slotUs[i]; curFrames = n
                    slotSeq[i] = -1; jbCount--
                    expected = (expected + 1) and 0xFFFF
                    return REAL
                }
                val slack = queuedFrames(t) - guardFrames
                if (slack <= 0) {
                    if (jbCount == 0 && plcRun >= IDLE_AFTER) {
                        expected = -1; firstSeq = -1
                        idles.incrementAndGet()
                        Log.i(TAG, "ses akışı durdu (${plcRun * 5} ms veri yok) — sessizlikte bekleniyor")
                        return IDLE
                    }
                    concealed[concealedIdx] = expected
                    concealedIdx = (concealedIdx + 1) % concealed.size
                    expected = (expected + 1) and 0xFFFF
                    return PLC
                }
                jb.wait((slack * 1000 / rate).coerceIn(1L, 4L))
            }
            return IDLE
        }
    }

    private fun dropBlocks(n: Int): Int {
        var real = 0
        synchronized(jb) {
            repeat(maxOf(0, n)) {
                val i = expected and (SLOTS - 1)
                if (slotSeq[i] == expected) { slotSeq[i] = -1; jbCount--; real++ }
                else if (jbCount == 0) return real
                expected = (expected + 1) and 0xFFFF
            }
        }
        return real
    }

    private fun queuedFrames(t: AudioTrack): Long =
        (written - (t.playbackHeadPosition.toLong() and 0xFFFFFFFFL)) and 0xFFFFFFFFL

    private fun playTimeOf(frame: Long): Long = tsNs + (frame - tsFp) * 1_000_000_000L / rate

    private fun pollTimestamp(t: AudioTrack, now: Long) {
        val u = t.underrunCount
        if (u != lastUnder) {
            lastUnder = u
            if (t.bufferSizeInFrames < minOf(t.bufferCapacityInFrames, MAX_BUFFER_PERIODS * period + BLOCK)) {
                t.setBufferSizeInFrames(t.bufferSizeInFrames + period)
                Log.w(TAG, "iz boşaldı (toplam $u) — tampon ${t.bufferSizeInFrames} çerçeveye büyütüldü")
            }
        }
        if (tsFp >= 0 && now - lastTsPoll < 20_000_000L) return
        lastTsPoll = now
        if (t.getTimestamp(ats) && ats.framePosition > 0 && ats.framePosition != tsFp) {
            if (tsFp < 0) Log.i(TAG, String.format(Locale.ROOT, "iz zaman damgası geçerli: yazılan→duyulan %.1f ms",
                (ats.nanoTime + (written - ats.framePosition) * 1e9 / rate - now) / 1e6))
            tsFp = ats.framePosition; tsNs = ats.nanoTime
            synchronized(mapLock) { pubTsFp = tsFp; pubTsNs = tsNs }
        }
    }

    private fun adaptJitter(now: Long) {
        if (lateFlag) {
            lateFlag = false
            lastLateNs = now
            if (jitterMs < JITTER_MAX_MS) {
                jitterMs = minOf(JITTER_MAX_MS, jitterMs + 10)
                Log.i(TAG, "geç paket gizlendi → titreşim payı $jitterMs ms")
            }
        } else if (jitterMs > JITTER_MIN_MS && now - lastLateNs > 10_000_000_000L && now - lastDecayNs > 5_000_000_000L) {
            jitterMs--
            lastDecayNs = now
        }
    }

    /** Süreklilik kaynağı: son gerçek çıkışın ters-düz tekrarı; ilk örneği son yazılanla aynı. */
    private fun continuation(dst: ShortArray, n: Int) {
        val sf = srcFrames
        if (sf == 0) { dst.fill(0, 0, n * ch); contPos += n; return }
        for (j in 0 until n) {
            val pos = contPos + j
            val seg = pos / sf
            val o = pos % sf
            val fi = if (seg % 2 == 0) sf - 1 - o else o
            val g = if (decaying) maxOf(0f, 1f - pos.toFloat() / DECAY_FRAMES) else 1f
            for (c in 0 until ch) dst[j * ch + c] = (src[fi * ch + c] * g).toInt().toShort()
        }
        contPos += n
    }

    /** Yükseltilmiş kosinüsle süreklilikten gerçek sese geçiş (work yerinde). */
    private fun crossfadeIn(n: Int) {
        continuation(tmp, n)
        for (j in 0 until n) {
            val w = (0.5 - 0.5 * cos(PI * (j + 0.5) / n)).toFloat()
            for (c in 0 until ch) {
                val i = j * ch + c
                work[i] = (work[i] * w + tmp[i] * (1f - w)).toInt().toShort()
            }
        }
    }

    /** Sönümlü kapanış + sessizlik: çıkış `ns` kadar ileri itilir. */
    private fun insertSilence(t: AudioTrack, ns: Long): Boolean {
        var frames = ns * rate / 1_000_000_000L
        if (srcFrames > 0) {
            val n = minOf(BLOCK.toLong(), frames).toInt()
            continuation(out, n)
            for (j in 0 until n) {
                val w = (0.5 + 0.5 * cos(PI * (j + 0.5) / n)).toFloat()
                for (c in 0 until ch) out[j * ch + c] = (out[j * ch + c] * w).toInt().toShort()
            }
            if (!writeOut(t, out, n)) return false
            frames -= n
        }
        while (frames > 0) {
            val n = minOf(BLOCK.toLong(), frames).toInt()
            if (!writeOut(t, zeros, n)) return false
            frames -= n
        }
        srcFrames = 0; contPos = 0; decaying = false; smooth = true
        return true
    }

    /** work[0..n) → out[0..m): doğrusal yeniden örnekleme; son çıkış örneği geçmiş olarak kullanılır,
     *  son çıkış örneği girdinin son örneğine denk gelir (bloklar arası sürekli). m == n ise kopya. */
    private fun resample(n: Int, m: Int) {
        if (m == n) { System.arraycopy(work, 0, out, 0, n * ch); return }
        for (j in 0 until m) {
            val pos = -1.0 + (j + 1).toDouble() * n / m
            var i0 = pos.toInt()
            if (pos < 0) i0 = -1
            val f = (pos - i0).toFloat()
            for (c in 0 until ch) {
                val a = if (i0 < 0) hist[c] else work[minOf(i0, n - 1) * ch + c].toFloat()
                val b = work[minOf(i0 + 1, n - 1) * ch + c].toFloat()
                out[j * ch + c] = (a + (b - a) * f).toInt().coerceIn(-32768, 32767).toShort()
            }
        }
    }

    private fun writeOut(t: AudioTrack, buf: ShortArray, frames: Int): Boolean {
        val total = frames * ch
        countJump(buf, frames)
        var o = 0
        while (o < total) {
            val r = t.write(buf, o, total - o)
            if (r < 0) { Log.w(TAG, "AudioTrack.write=$r"); return false }
            if (r == 0 && !running) return true
            o += r
        }
        written += frames
        bytesWritten.addAndGet(total * 2L)
        writes.incrementAndGet()
        for (c in 0 until ch) hist[c] = buf[(frames - 1) * ch + c].toFloat()
        return true
    }

    /** Tık bekçisi: blok sınırındaki sıçrama, bloğun kendi en büyük örnek adımının 2 katını ve
     *  tam ölçeğin %6'sını aşıyorsa sayılır (1 kHz/−6 dBFS sinüste adım ~2100, kesik ~16000). */
    private fun countJump(buf: ShortArray, frames: Int) {
        for (c in 0 until ch) {
            var inner = 0
            for (j in 1 until frames) {
                val d = abs(buf[j * ch + c] - buf[(j - 1) * ch + c])
                if (d > inner) inner = d
            }
            if (abs(buf[c] - hist[c]) > maxOf(2 * inner, 2000)) { jumps.incrementAndGet(); return }
        }
    }

    private fun record(us: Long, w0: Long, outFrames: Int, inFrames: Int) {
        synchronized(mapLock) {
            val i = mapN % MAP
            mapUs[i] = us; mapW[i] = w0; mapOut[i] = outFrames; mapIn[i] = inFrames
            mapN++
        }
    }

    /** Medya anı `mediaUs` yerelde hangi anda duyulur (ns); son ~640 ms dışında Long.MIN_VALUE. */
    fun audioTimeOf(mediaUs: Long): Long {
        synchronized(mapLock) {
            if (pubTsFp < 0) return Long.MIN_VALUE
            val n = minOf(mapN, MAP)
            for (k in 0 until n) {
                val i = (mapN - 1 - k) % MAP
                val durUs = mapIn[i] * 1_000_000L / rate
                val d = mediaUs - mapUs[i]
                if (d in 0 until durUs) {
                    val w = mapW[i] + d * mapOut[i] / durUs
                    return pubTsNs + (w - pubTsFp) * 1_000_000_000L / rate
                }
            }
            return Long.MIN_VALUE
        }
    }

    fun stop() {
        running = false
        synchronized(jb) { jb.notifyAll() }
        thread?.let { th ->
            try { th.join(600) } catch (e: Exception) { }
            if (th.isAlive) {
                Log.w(TAG, "ses iş parçacığı yazımda takıldı — iz dışarıdan kapatılıyor")
                curTrack?.let { try { it.pause(); it.flush() } catch (e: Exception) { } }
                try { th.join(300) } catch (e: Exception) { }
            }
        }
        thread = null
        firstTrack?.let { try { it.release() } catch (e: Exception) { } }
        firstTrack = null
        avClock?.audioTimeOf = null
        synchronized(jb) { clearSlots(); expected = -1; firstSeq = -1 }
    }

    private fun underruns(): Long =
        underrunsDone.get() + (try { curTrack?.underrunCount?.toLong() ?: 0L } catch (e: Exception) { 0L })

    /** ATVM-Stats parçası: aq = gizlemeye kalan süre (iz + tampon − boşalma payı, ms, aralık ort.),
     *  jt = hedef titreşim payı (ms). */
    fun stats(): String {
        val aq = if (aqN == 0L) 0.0 else aqSum.toDouble() / aqN
        aqSum = 0; aqN = 0
        val hal = halNs
        return String.format(Locale.ROOT, "aq=%.0f jt=%d plc=%d late=%d dup=%d aUnder=%d aResync=%d aIdle=%d aRestart=%d aJump=%d aTrim=%d aHal=%s",
            aq, jitterMs, plc.get(), late.get(), dup.get(), underruns(), resyncs.get(), idles.get(), restarts.get(), jumps.get(), trimmed.get(),
            if (hal == Long.MIN_VALUE) "na" else String.format(Locale.ROOT, "%.0f", hal / 1e6))
    }

    /**
     * Ses sayacının **ekranda görünen** satırı: etiketler katalogda, iki dilde. `context`
     * MainActivity'nin yerelleştirilmiş bağlamıdır. Makine okuması (logcat) `stats()`te durur.
     */
    fun summary(context: android.content.Context): String =
        context.getString(
            R.string.audio_summary,
            bytesWritten.get() / 1024, packets.get(), plc.get(), late.get(),
            peakSample.get(), underruns(), resyncs.get(), jitterMs,
        )
}
