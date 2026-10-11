package dev.atvm.receiver

import android.util.Log

/** Bir erişim birimi (access unit): Annex-B olarak çözücüye verilecek tam NAL serisi. */
data class AccessUnit(val data: ByteArray, val rtpTimestamp: Long, val keyFrame: Boolean, val nalCount: Int)

/** RFC 3550 RTP başlığı + RFC 6184 H.264 payload çözücüsü (single-NAL / STAP-A / FU-A).
 *  Yalnızca ilgili RFC'lerden yazılmıştır; başka bir projeden kod alınmamıştır.
 *  Paketler SIRALI gelir: sıralama/NACK işi [VideoReorderBuffer]'ındır, kayıp [onLoss] ile bildirilir. */
class RtpDepacketizer(private val ssrcExpected: Long, private val ptExpected: Int = 96) {
    companion object {
        private const val TAG = "ATVM-Rtp"
        private val START_CODE = byteArrayOf(0, 0, 0, 1)
        private const val TYPE_FU_A = 28
        private const val TYPE_STAP_A = 24
    }

    private val buffer = java.io.ByteArrayOutputStream(256 * 1024)
    /** ssrc=0 verildiyse ilk görülen SSRC'ye kilitlenir (kendi kendine testte üretici SSRC bildirmez). */
    private var ssrcLocked: Long = if (ssrcExpected == 0L) -1L else ssrcExpected
    private var currentTs = -1L
    private var nalInCurrent = 0
    private var keyInCurrent = false
    private var idrInCurrent = false
    /** Kayıptan sonra atılacak AU'ların zaman damgaları (kaybın hangi AU'ya düştüğü kesin bilinmez). */
    private var discardA = -1L
    private var discardB = -1L
    private var lossPending = false
    var packetsReceived = 0L; private set
    var malformed = 0L; private set
    /** `malformed` tek sayıca dört nedeni karıştırıyordu; ayrı sayılıyor (ölçüm disiplini). */
    var badShort = 0L; private set
    var badVersion = 0L; private set
    var badPayloadType = 0L; private set
    var badSsrc = 0L; private set
    var badHeaderLen = 0L; private set
    var badPayload = 0L; private set
    var unknownNalType = 0L; private set
    private var curSeq = -1L
    private var curSsrc = -1L
    private var curPt = -1
    var auEmitted = 0L; private set
    /** Kapı kapalıyken (IDR beklerken) atılan AU. */
    var auGated = 0L; private set
    /** Kayıp yüzünden atılan (yarım ya da şüpheli) AU/paket grubu. */
    var auLost = 0L; private set

    /** Kapı: [requireKeyFrame] her çağrıda sayacı artırır (herhangi bir thread); yalnız bir IDR AU'su
     *  UDP thread'inde `openedEpoch`'u o ana eşitler. Aradaki yarışta yeni istek kaybolmaz. */
    private val gateEpoch = java.util.concurrent.atomic.AtomicInteger(0)
    @Volatile private var openedEpoch = 0

    /** TRUE iken IDR dışında hiçbir AU çözücüye verilmez; çağırıcı IDR istemeli. */
    val needsKeyFrame: Boolean get() = gateEpoch.get() != openedEpoch

    /** Kayıp / çözücü kurtarma / birikinti: taze bir IDR'ye kadar AU üretme. */
    fun requireKeyFrame() { gateEpoch.incrementAndGet() }

    /** [VideoReorderBuffer]'dan: düzeltilemeyen kayıp. Yarım AU atılır, kapı kapanır. */
    fun onLoss() {
        resetAu()
        lossPending = true
        auLost++
        requireKeyFrame()
    }

    private fun resetAu() {
        buffer.reset(); nalInCurrent = 0; keyInCurrent = false; idrInCurrent = false
    }

    /** Başlık geçerli mi, PT/SSRC bizim akışımız mı? Sıralama tamponundan ÖNCE çağrılır:
     *  yabancı paketin seq'i boşluk üretmesin. Reddedilenler `malformed` ile sayılır. */
    fun accepts(pkt: ByteArray, len: Int): Boolean {
        packetsReceived++
        return parseHeader(pkt, len, true)
    }

    /** Doğrulanmış SSRC (test modunda ilk paketin SSRC'si); henüz yoksa 0. */
    val lockedSsrc: Long get() = if (ssrcLocked == -1L) 0L else ssrcLocked

    private var hdrLen = 0
    private var payloadEnd = 0
    private var hdrMarker = false
    private var hdrTs = 0L

    private fun parseHeader(pkt: ByteArray, len: Int, count: Boolean): Boolean {
        if (len < 13) { if (count) { malformed++; badShort++ }; return false }
        val b0 = pkt[0].toInt() and 0xFF
        val version = (b0 shr 6) and 3
        if (version != 2) { if (count) { malformed++; badVersion++ }; return false }
        val hasPadding = ((b0 shr 5) and 1) == 1
        val hasExt = ((b0 shr 4) and 1) == 1
        val cc = b0 and 0x0F
        val b1 = pkt[1].toInt() and 0xFF
        val pt = b1 and 0x7F
        if (pt != ptExpected) { if (count) { malformed++; badPayloadType++ }; return false }

        val seq = (((pkt[2].toInt() and 0xFF) shl 8) or (pkt[3].toInt() and 0xFF)).toLong()
        val ts = (((pkt[4].toLong() and 0xFF) shl 24) or ((pkt[5].toLong() and 0xFF) shl 16) or
            ((pkt[6].toLong() and 0xFF) shl 8) or (pkt[7].toLong() and 0xFF))
        val ssrc = (((pkt[8].toLong() and 0xFF) shl 24) or ((pkt[9].toLong() and 0xFF) shl 16) or
            ((pkt[10].toLong() and 0xFF) shl 8) or (pkt[11].toLong() and 0xFF))
        if (ssrcLocked == -1L) {
            ssrcLocked = ssrc
            Log.i(TAG, "SSRC kilidi (test modu): $ssrc")
        } else if (ssrc != ssrcLocked) {
            if (count) { malformed++; badSsrc++ }
            return false
        }

        curSeq = seq; curSsrc = ssrc; curPt = pt
        var headerLen = 12 + cc * 4
        if (hasExt) {
            if (len < headerLen + 4) { if (count) { malformed++; badHeaderLen++ }; return false }
            val extLenWords = (((pkt[headerLen + 2].toInt() and 0xFF) shl 8) or
                (pkt[headerLen + 3].toInt() and 0xFF))
            headerLen += 4 + extLenWords * 4
        }
        if (headerLen >= len) { if (count) { malformed++; badHeaderLen++ }; return false }
        var end = len
        if (hasPadding) {
            val pad = pkt[len - 1].toInt() and 0xFF
            end -= pad
            if (end <= headerLen) { if (count) { malformed++; badPayload++ }; return false }
        }
        hdrLen = headerLen; payloadEnd = end
        hdrMarker = ((b1 shr 7) and 1) == 1
        hdrTs = ts
        return true
    }

    /** [accepts]'ten geçmiş ve SIRAYA sokulmuş bir paketi işler; AU tamamlandıysa döndürür. */
    fun feed(pkt: ByteArray, len: Int): AccessUnit? {
        if (!parseHeader(pkt, len, false)) return null
        val ts = hdrTs

        if (lossPending) {
            // Kayıp, bu paketten önce oldu: AU sınırı bilinmediği için hem yarım AU'yu (currentTs)
            // hem de kayıptan sonraki ilk AU'yu (ts) at; yeniden eşitleme IDR ile olur.
            lossPending = false
            discardA = currentTs; discardB = ts
        }
        if (ts == discardA || ts == discardB) {
            currentTs = ts
            return null
        }

        if (currentTs >= 0 && ts != currentTs && buffer.size() > 0) {
            // Marker gelmeden zaman damgası değişti: yarım AU referans kaybıdır → IDR'ye kadar bekle.
            Log.w(TAG, "marker gelmeden timestamp değişti (${currentTs}→$ts), ${buffer.size()} B yarım AU atıldı")
            resetAu()
            auLost++
            requireKeyFrame()
        }
        currentTs = ts

        parsePayload(pkt, hdrLen, payloadEnd)

        if (hdrMarker && buffer.size() > 0) {
            val bytes = buffer.toByteArray()
            val au = AccessUnit(bytes, ts, keyInCurrent, nalInCurrent)
            val idr = idrInCurrent
            resetAu()
            if (needsKeyFrame) {
                // Kapı yalnız bir IDR ile açılır: P kareleri eksik referansla çözülürse görüntü bozulur.
                if (!idr) { auGated++; return null }
                openedEpoch = gateEpoch.get()
            }
            auEmitted++
            return au
        }
        return null
    }

    private fun parsePayload(p: ByteArray, from: Int, to: Int) {
        val first = p[from].toInt() and 0xFF
        val type = first and 0x1F
        when (type) {
            TYPE_STAP_A -> {
                var i = from + 1
                while (i + 2 <= to) {
                    val nalLen = (((p[i].toInt() and 0xFF) shl 8) or (p[i + 1].toInt() and 0xFF))
                    i += 2
                    if (nalLen <= 0 || i + nalLen > to) { malformed++; return }
                    appendNal(p, i, nalLen)
                    i += nalLen
                }
            }
            TYPE_FU_A -> {
                if (to - from < 2) { malformed++; return }
                val fu = p[from + 1].toInt() and 0xFF
                val startBit = (fu and 0x80) != 0
                val endBit = (fu and 0x40) != 0
                val nalType = fu and 0x1F
                val indicator = (first and 0xE0) or nalType
                if (startBit) {
                    buffer.write(START_CODE); buffer.write(indicator)
                    nalInCurrent++
                    if (nalType == 5 || nalType == 7 || nalType == 8) keyInCurrent = true
                    if (nalType == 5) idrInCurrent = true
                } else if (nalInCurrent == 0) {
                    // Parçası geldiğimiz NAL'ın başını kaybettik (boşlukta atlanmış) → bu AU geçersiz.
                    requireKeyFrame()
                    return
                }
                buffer.write(p, from + 2, to - from - 2)
                if (endBit) { /* NAL sonu: start code zaten bir sonraki NAL'dan önce yazılır */ }
            }
            in 1..23 -> {
                buffer.write(START_CODE)
                buffer.write(p, from, to - from)
                nalInCurrent++
                if (type == 5 || type == 7 || type == 8) keyInCurrent = true
                if (type == 5) idrInCurrent = true
            }
            else -> {
                malformed++; unknownNalType++
                if (unknownNalType < 6) {
                    val hex = (from until minOf(from + 8, to)).joinToString(" ") { "%02x".format(it) }
                    Log.w(TAG, "bilinmeyen NAL türü=$type pt=$curPt ssrc=$curSsrc seq=$curSeq " +
                        "yük=${to - from} ilk-baytlar=[$hex]")
                }
            }
        }
    }

    private fun appendNal(p: ByteArray, off: Int, len: Int) {
        buffer.write(START_CODE)
        buffer.write(p, off, len)
        nalInCurrent++
        val t = p[off].toInt() and 0x1F
        if (t == 5 || t == 7 || t == 8) keyInCurrent = true
        if (t == 5) idrInCurrent = true
    }
}
