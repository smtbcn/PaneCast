package dev.atvm.receiver

/** 16 bit RTP sıra numarası farkı (a - b), işaretli: -32768..32767. */
fun seqDiff(a: Int, b: Int): Int = ((((a - b) and 0xFFFF) + 0x8000) and 0xFFFF) - 0x8000

/** RFC 4585 §6.2.1 Generic NACK (RTPFB, PT=205, FMT=1): her giriş PID + sonraki 16 seq için BLP maskesi. */
object RtcpNack {
    const val PT_RTPFB = 205
    const val FMT_NACK = 1

    /** [seqs] artan sırada eksik seq'ler; paketi [out]'a yazar, bayt sayısını döndürür (en çok 12 + 4*count). */
    fun build(out: ByteArray, senderSsrc: Long, mediaSsrc: Long, seqs: IntArray, count: Int): Int {
        var off = 12
        var i = 0
        while (i < count) {
            val pid = seqs[i]
            var blp = 0
            i++
            while (i < count) {
                val d = seqDiff(seqs[i], pid)
                if (d < 1 || d > 16) break
                blp = blp or (1 shl (d - 1))
                i++
            }
            out[off] = (pid shr 8).toByte(); out[off + 1] = pid.toByte()
            out[off + 2] = (blp shr 8).toByte(); out[off + 3] = blp.toByte()
            off += 4
        }
        out[0] = (0x80 or FMT_NACK).toByte()
        out[1] = PT_RTPFB.toByte()
        val words = off / 4 - 1
        out[2] = (words shr 8).toByte(); out[3] = words.toByte()
        putU32(out, 4, senderSsrc)
        putU32(out, 8, mediaSsrc)
        return off
    }

    private fun putU32(b: ByteArray, o: Int, v: Long) {
        b[o] = (v shr 24).toByte(); b[o + 1] = (v shr 16).toByte(); b[o + 2] = (v shr 8).toByte(); b[o + 3] = v.toByte()
    }
}

/**
 * Video RTP paketleri için sıralama + NACK tamponu (yalnız UDP thread'inde kullanılır).
 *
 * - Sıradaki paket geldiyse doğrudan [Sink.deliver]'a gider (kopya yok, bekleme yok).
 * - İleri sıçrayan paket tampona yazılır; aradaki seq'ler "eksik" sayılır. Kısa bir sıralama
 *   toleransından ([REORDER_GRACE_MS]) sonra hâlâ yoksa NACK gider, [RENACK_MS] sonra bir kez daha.
 * - Eksik paket [HOLD_MS] içinde gelmezse vazgeçilir: [Sink.onUnrecoverable] çağrılır ve
 *   tamponda bekleyen sonraki paketler sırayla teslim edilir.
 * Saat dışarıdan verilir (ms, monoton); Android'e bağımlılık yoktur.
 */
class VideoReorderBuffer(
    private val sink: Sink,
    private val nackOut: (ByteArray, Int) -> Unit,
    private val senderSsrc: Long,
    private val mediaSsrc: () -> Long
) {
    interface Sink {
        fun deliver(pkt: ByteArray, len: Int)
        /** Düzeltilemeyen kayıp: o paketleri içeren erişim birimi geçersiz. */
        fun onUnrecoverable()
    }

    companion object {
        const val WINDOW = 1024
        private const val MASK = WINDOW - 1
        const val REORDER_GRACE_MS = 2L
        const val RENACK_MS = 10L
        const val HOLD_MS = 30L
        private const val MAX_PKT = 1500
        private const val MAX_NACK_PER_PACKET = 256
    }

    private var started = false
    /** Teslim edilecek sıradaki seq. */
    private var expected = 0
    /** Alınan en yüksek seq (bekleyen yoksa expected - 1). */
    private var high = 0

    private val data = arrayOfNulls<ByteArray>(WINDOW)
    private val len = IntArray(WINDOW)
    private val missAt = LongArray(WINDOW)
    private val nacks = IntArray(WINDOW)
    private val lastNackAt = LongArray(WINDOW)
    /** Vazgeçilen seq'ler: gecikmiş gelen paketi `rtxLate` diye sayabilmek için. */
    private val abandoned = IntArray(WINDOW) { -1 }
    private val nackList = IntArray(MAX_NACK_PER_PACKET)
    private val nackBuf = ByteArray(12 + 4 * MAX_NACK_PER_PACKET)

    var log: ((String) -> Unit)? = null

    // Sayaçlar yalnız UDP thread'inde yazılır, istatistik thread'i okur.
    /** İlk iletimde kaybolup NACK'lanan paket sayısı. */
    @Volatile var gap = 0L; private set
    @Volatile var nackSent = 0L; private set
    /** NACK sonrası gelip boşluğu dolduran paket. */
    @Volatile var rtx = 0L; private set
    /** Vazgeçildikten sonra gelen paket. */
    @Volatile var rtxLate = 0L; private set
    @Volatile var unrec = 0L; private set
    /** NACK'a gerek kalmadan toleransta yerine oturan (sırası bozulmuş) paket. */
    @Volatile var reordered = 0L; private set
    @Volatile var duplicates = 0L; private set

    fun onPacket(pkt: ByteArray, n: Int, now: Long) {
        val seq = ((pkt[2].toInt() and 0xFF) shl 8) or (pkt[3].toInt() and 0xFF)
        if (!started) {
            started = true
            expected = seq
            high = (seq - 1) and 0xFFFF
        }
        var d = seqDiff(seq, expected)
        if (d < 0) {
            val slot = seq and MASK
            if (abandoned[slot] == seq) { abandoned[slot] = -1; rtxLate++ } else duplicates++
            return
        }
        if (d >= WINDOW) {
            // Çok ileri sıçrama (yayıncı yeniden başladı ya da pencere taştı): bekleyenlerden vazgeç.
            resync(seq)
            d = 0
        }
        val fill = seqDiff(seq, high) <= 0
        if (!fill) {
            var s = (high + 1) and 0xFFFF
            while (s != seq) {
                val slot = s and MASK
                missAt[slot] = now; nacks[slot] = 0
                s = (s + 1) and 0xFFFF
            }
            high = seq
        }
        val slot = seq and MASK
        if (len[slot] != 0) { duplicates++; return }
        if (fill) { if (nacks[slot] > 0) rtx++ else reordered++ }
        if (d == 0) {
            sink.deliver(pkt, n)
            expected = (expected + 1) and 0xFFFF
        } else {
            var buf = data[slot]
            if (buf == null) { buf = ByteArray(MAX_PKT); data[slot] = buf }
            System.arraycopy(pkt, 0, buf, 0, n)
            len[slot] = n
        }
        drain()
    }

    /** Zamanlayıcı işleri: gecikmiş NACK'lar, yeniden NACK, vazgeçme. Her turda çağrılır. */
    fun service(now: Long) {
        while (pending()) {
            sendDueNacks(now)
            if (now - missAt[expected and MASK] < HOLD_MS) return
            abandonHead()
        }
    }

    /** Bir sonraki hizmet anına kadar ms (>= 1); bekleyen yoksa -1. */
    fun nextWakeMs(now: Long): Long {
        if (!pending()) return -1
        var due = missAt[expected and MASK] + HOLD_MS
        var s = expected
        while (s != high) {
            val slot = s and MASK
            if (len[slot] == 0) {
                val t = when (nacks[slot]) {
                    0 -> missAt[slot] + REORDER_GRACE_MS
                    1 -> lastNackAt[slot] + RENACK_MS
                    else -> Long.MAX_VALUE
                }
                if (t < due) due = t
            }
            s = (s + 1) and 0xFFFF
        }
        return maxOf(1L, due - now)
    }

    /** Teslim edilmemiş (tamponlanmış) paket var mı → baştaki boşluk açık. */
    private fun pending(): Boolean = started && seqDiff(high, expected) >= 0

    private fun drain() {
        while (true) {
            val slot = expected and MASK
            val n = len[slot]
            if (n == 0) return
            len[slot] = 0
            sink.deliver(data[slot]!!, n)
            expected = (expected + 1) and 0xFFFF
        }
    }

    private fun sendDueNacks(now: Long) {
        var count = 0
        var s = expected
        while (s != high && count < MAX_NACK_PER_PACKET) {
            val slot = s and MASK
            if (len[slot] == 0) {
                if (nacks[slot] == 0 && now - missAt[slot] >= REORDER_GRACE_MS) {
                    nackList[count++] = s; nacks[slot] = 1; lastNackAt[slot] = now; gap++
                } else if (nacks[slot] == 1 && now - lastNackAt[slot] >= RENACK_MS) {
                    nackList[count++] = s; nacks[slot] = 2; lastNackAt[slot] = now
                }
            }
            s = (s + 1) and 0xFFFF
        }
        if (count > 0) {
            val n = RtcpNack.build(nackBuf, senderSsrc, mediaSsrc(), nackList, count)
            nackSent++
            nackOut(nackBuf, n)
        }
    }

    private fun abandonHead() {
        val first = expected
        var s = expected
        var lost = 0
        while (s != high && len[s and MASK] == 0) {
            abandoned[s and MASK] = s
            lost++
            s = (s + 1) and 0xFFFF
        }
        unrec += lost
        expected = s
        log?.invoke("kayıp düzeltilemedi: seq $first..${(s - 1) and 0xFFFF} ($lost paket, ${HOLD_MS} ms içinde gelmedi)")
        sink.onUnrecoverable()
        drain()
    }

    private fun resync(seq: Int) {
        var s = expected
        var lost = 0
        while (seqDiff(s, high) <= 0) {
            val slot = s and MASK
            if (len[slot] == 0) lost++ else len[slot] = 0
            s = (s + 1) and 0xFFFF
        }
        unrec += lost
        log?.invoke("seq sıçraması: $expected → $seq, tampon boşaltıldı ($lost eksik)")
        expected = seq
        high = (seq - 1) and 0xFFFF
        sink.onUnrecoverable()
    }
}
