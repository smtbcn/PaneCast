package dev.atvm.receiver

import android.util.Log
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max

/**
 * Ortak saat (docs/protocol.md §5.1): gönderenin medya zamanı `m` (µs) yerelde
 * `m·1000 + P` (System.nanoTime) anında duyulur/görünür. P tek değerdir, ses ve görüntü paylaşır.
 *
 * P = max(sesin en erken çalabildiği, görüntünün en erken gösterebildiği), canlı ölçülür:
 * - ses: en erken varış (5 sn taban) + iz/HAL gecikmesi + boşalma payı + titreşim payı
 * - görüntü: en erken varış + çözme p95 + bırakma→ekran
 * Bu TV'de ses yolu ~100 ms HAL gecikmesi taşıdığı için P'yi ses belirler ve görüntü bekletilir.
 * Bekletme çözücü GİRİŞİNDE yapılır: çıkışı gelecek damgayla bırakmak (`releaseOutputBuffer(i, ns)`)
 * bu çözücüde 80 ms'den itibaren kare üretimini çökertiyor (ölçüldü: 57 → 0–20 fps, drop_q artıyor).
 */
class AvClock(val sync: Boolean, videoRtpBase: Long, audioRtpBase: Long) {
    companion object {
        private const val TAG = "ATVM-Sync"
        /** Görüntüyü P'ye göre bekletme (dudak senkronu). Ölçüldü (40 sn, flaş/bip klibi): avErr p50 ≈ −1 ms,
         *  |p95| 4–8 ms, 57–59 fps, cdrop 0; bedeli görüntüde ~160 ms ek gecikme. false → görüntü anında. */
        const val PACE_VIDEO = true
        /** Bırakma → yüzeyde gösterim, p50 (ölçüldü: OnFrameRendered, 60 Hz panel, ~10 ms). */
        private const val PRESENT_LAG_NS = 10_000_000L
        private const val VIDEO_MARGIN_NS = 3_000_000L
        /** Bu kadarlık P farkı süzülmez, tek seferde atlanır (ses çapraz geçişle hizalanır). */
        const val JUMP_NS = 80_000_000L
        /** P'nin süzülme hızı: 4 ms/sn; ses paket başına ≤2 örnekle (8,3 ms/sn) izleyebilir. */
        private const val SLEW_PER_NS = 0.004
        private const val VIDEO_STALE_NS = 10_000_000_000L
        /** Bekletmede bu süreyi aşan kare bekletilmez (P bozuksa görüntü donmasın). */
        private const val MAX_HOLD_NS = 600_000_000L
        private const val MAX_HELD = 90
        private const val ERR_WINDOW_NS = 2_000_000_000L
    }

    private val video = RtpTimeline(videoRtpBase, 90_000)
    private val audio = RtpTimeline(audioRtpBase, 48_000)
    private val audioFloor = Floor()
    private val videoFloor = Floor()

    /** Ses yolunun "paket hazır → duyulur" asgari süresi (HAL + boşalma payı), ns; bilinmiyorsa MIN. */
    private var audioPathNs = Long.MIN_VALUE
    private var jitterNs = 0L
    private val decodeNs = Ring(120)
    private var lastVideoNs = 0L
    private var p = Long.MIN_VALUE
    private var lastUpdateNs = 0L
    @Volatile var playoutNs = Long.MIN_VALUE
        private set
    /** İnsan kalibrasyonu: panelin görüntüye eklediği tahmini gecikme (ms). Görüntü bu kadar erken beslenir. */
    @Volatile var displayOffsetMs = 0
    /** Ses çıkışının bir medya anını yerelde çaldığı an (ns) — AudioRenderer sağlar. */
    @Volatile var audioTimeOf: ((Long) -> Long)? = null

    private val errNs = LongArray(512)
    private val errAt = LongArray(512)
    private var errN = 0
    private var holdSumNs = 0L
    private var holdN = 0
    private var holdMaxNs = 0L
    val jumps = java.util.concurrent.atomic.AtomicLong(0)

    fun videoMediaUs(rtpTs: Long): Long = video.us(rtpTs)
    fun audioMediaUs(rtpTs: Long): Long = audio.us(rtpTs)

    @Synchronized fun onAudioArrival(mediaUs: Long, nowNs: Long) {
        audioFloor.add(nowNs - mediaUs * 1000, nowNs)
    }

    @Synchronized fun setAudioPath(pathNs: Long, jitter: Long) {
        audioPathNs = pathNs; jitterNs = jitter
    }

    /** Ses pompası her blokta çağırır; güncel P'yi döner (henüz yoksa Long.MIN_VALUE). */
    @Synchronized fun update(nowNs: Long): Long {
        val af = audioFloor.get()
        if (audioPathNs == Long.MIN_VALUE || af == Long.MAX_VALUE) return Long.MIN_VALUE
        var target = af + audioPathNs + jitterNs
        val vf = videoFloor.get()
        if (sync && vf != Long.MAX_VALUE && nowNs - lastVideoNs < VIDEO_STALE_NS) {
            target = max(target, vf + videoPathNs(95) + displayOffsetMs * 1_000_000L + VIDEO_MARGIN_NS)
        }
        if (p == Long.MIN_VALUE || abs(target - p) > JUMP_NS) {
            if (p != Long.MIN_VALUE) {
                jumps.incrementAndGet()
                Log.i(TAG, String.format(Locale.ROOT, "P atladı %+.1f ms (D=%.1f ms)", (target - p) / 1e6, (target - af) / 1e6))
            }
            p = target
        } else {
            val step = ((nowNs - lastUpdateNs) * SLEW_PER_NS).toLong()
            p += (target - p).coerceIn(-step, step)
        }
        lastUpdateNs = nowNs
        playoutNs = p
        return p
    }

    private fun videoPathNs(pct: Int): Long = decodeNs.pct(pct, 12_000_000L) + PRESENT_LAG_NS

    // ---- görüntü: çözücü girişinde bekletme ----

    private class Held(val au: AccessUnit, val mediaUs: Long, val arrivalNs: Long, val sink: (AccessUnit) -> Unit)
    private val held = ArrayDeque<Held>()
    private val heldLock = java.lang.Object()
    private var pacer: Thread? = null
    @Volatile private var running = true

    /**
     * true → AU bekletmeye alındı, zamanı gelince `sink` ile çözücüye verilecek.
     * false → hemen beslenmeli (senkron kapalı, P yok veya kare zaten geç).
     */
    fun pace(au: AccessUnit, sink: (AccessUnit) -> Unit): Boolean {
        if (!sync || !PACE_VIDEO) return false
        val now = System.nanoTime()
        val m = video.us(au.rtpTimestamp)
        synchronized(this) { videoFloor.add(now - m * 1000, now); lastVideoNs = now }
        synchronized(heldLock) {
            if (held.isEmpty() && feedAtNs(m) <= now) return false
            if (held.size >= MAX_HELD) {
                Log.w(TAG, "görüntü bekletme taştı (${held.size}) — bekleyenler hemen besleniyor")
                flushHeld()
            }
            held.addLast(Held(au, m, now, sink))
            if (pacer == null) {
                pacer = Thread({ pacerLoop() }, "atvm-vpace").apply { priority = Thread.MAX_PRIORITY; start() }
            }
            heldLock.notifyAll()
        }
        return true
    }

    /** Karenin çözücüye verilme anı: gösterim hedefi − çözme p50 − bırakma→ekran − kalibrasyon. */
    private fun feedAtNs(mediaUs: Long): Long {
        val pp = playoutNs
        if (pp == Long.MIN_VALUE) return Long.MIN_VALUE
        return mediaUs * 1000 + pp - synchronized(this) { videoPathNs(50) } - displayOffsetMs * 1_000_000L
    }

    private fun flushHeld() {
        while (held.isNotEmpty()) { val h = held.removeFirst(); h.sink(h.au) }
    }

    private fun pacerLoop() {
        while (running) {
            val h = synchronized(heldLock) { nextDue() } ?: continue
            h.sink(h.au)
        }
    }

    /** heldLock tutulurken: zamanı gelmiş baş kareyi çıkarır, yoksa kısa bekleyip null döner. */
    private fun nextDue(): Held? {
        while (running && held.isEmpty()) heldLock.wait(200)
        if (!running || held.isEmpty()) return null
        val head = held.first()
        val now = System.nanoTime()
        val wait = feedAtNs(head.mediaUs) - now
        if (wait > 500_000L && now - head.arrivalNs < MAX_HOLD_NS) {
            val w = minOf(wait, 20_000_000L)
            heldLock.wait(w / 1_000_000L, (w % 1_000_000L).toInt())
            return null
        }
        held.removeFirst()
        synchronized(this) {
            val d = now - head.arrivalNs
            holdSumNs += d; holdN++; if (d > holdMaxNs) holdMaxNs = d
        }
        return head
    }

    /** Çözücü bir kareyi yüzeye bıraktı. `decodeMs`: çözücü girişi → çıkış. */
    fun onVideoRendered(mediaUs: Long, releaseNs: Long, decodeMs: Double) {
        if (!sync) return
        val audioNs = audioTimeOf?.invoke(mediaUs) ?: Long.MIN_VALUE
        synchronized(this) {
            if (decodeMs in 0.0..500.0) decodeNs.add((decodeMs * 1e6).toLong())
            if (audioNs == Long.MIN_VALUE) return
            val i = errN % errNs.size
            errNs[i] = audioNs - (releaseNs + PRESENT_LAG_NS + displayOffsetMs * 1_000_000L)
            errAt[i] = releaseNs
            errN++
        }
    }

    fun stop() {
        running = false
        synchronized(heldLock) { held.clear(); heldLock.notifyAll() }
        pacer?.let { try { it.join(300) } catch (e: Exception) { } }
        pacer = null
    }

    /** Ölçüm satırı: avErr = ses − görüntü (ms; p50 / |·| p95, son 2 sn), D = ses varışı → çalma. */
    @Synchronized fun stats(): String {
        val now = System.nanoTime()
        val n = minOf(errN, errNs.size)
        val win = ArrayList<Long>(n)
        for (k in 0 until n) if (now - errAt[k] <= ERR_WINDOW_NS) win.add(errNs[k])
        val err = if (win.isEmpty()) "na" else {
            win.sort()
            val absSorted = win.map { abs(it) }.sorted()
            String.format(Locale.ROOT, "%.1f/%.1f", win[win.size / 2] / 1e6, absSorted[(absSorted.size * 95) / 100] / 1e6)
        }
        val af = audioFloor.get()
        val d = if (p == Long.MIN_VALUE || af == Long.MAX_VALUE) "na" else String.format(Locale.ROOT, "%.0f", (p - af) / 1e6)
        val hold = if (holdN == 0) "na" else String.format(Locale.ROOT, "%.0f/%.0f", holdSumNs / holdN / 1e6, holdMaxNs / 1e6)
        holdSumNs = 0; holdN = 0; holdMaxNs = 0
        return "avErr=$err D=$d vHold=$hold vDec=" + String.format(Locale.ROOT, "%.1f", decodeNs.pct(50, 0) / 1e6) +
            " pJump=${jumps.get()} avOfs=$displayOffsetMs"
    }

    /** 32 bit RTP damgasını tabana göre işaretli, sarmasız µs'ye açar (iki iş parçacığı okuyabilir). */
    private class RtpTimeline(private val base: Long, private val rate: Int) {
        private var lastTs = -1L
        private var lastExt = 0L
        @Synchronized fun us(ts: Long): Long {
            if (lastTs < 0) { lastTs = ts; lastExt = (ts - base).toInt().toLong() }
            val step = (ts - lastTs).toInt().toLong()
            val ext = lastExt + step
            if (step > 0) { lastTs = ts; lastExt = ext }
            return ext * 1_000_000L / rate
        }
    }

    /** 5 × 1 sn kutulu kayan en küçük değer: varış gecikmesinin tabanı, saat kaymasını izler. */
    private class Floor {
        private val mins = LongArray(5) { Long.MAX_VALUE }
        private var idx = 0
        private var binStart = Long.MIN_VALUE
        fun add(v: Long, now: Long) {
            if (binStart == Long.MIN_VALUE || now - binStart >= 1_000_000_000L) {
                idx = (idx + 1) % mins.size; mins[idx] = Long.MAX_VALUE; binStart = now
            }
            if (v < mins[idx]) mins[idx] = v
        }
        fun get(): Long = mins.minOrNull() ?: Long.MAX_VALUE
    }

    private class Ring(size: Int) {
        private val v = LongArray(size)
        private var n = 0
        fun add(x: Long) { v[n % v.size] = x; n++ }
        fun pct(p: Int, default: Long): Long {
            val k = minOf(n, v.size)
            if (k == 0) return default
            val s = v.copyOf(k); s.sort()
            return s[minOf(k - 1, (k * p) / 100)]
        }
    }
}
