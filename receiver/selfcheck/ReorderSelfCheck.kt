package dev.atvm.receiver

// Kayıp kurtarma mantığının JVM öz-denetimi (JUnit bağımlılığı eklemeden). Çalıştırma:
//   scripts/test-receiver-reorder.sh
// Saat enjekte edildiği için zamanlama ms hassasiyetle ve beklemeden sınanır.

private var failures = 0
private var checks = 0

private fun check(name: String, ok: Boolean) {
    checks++
    if (!ok) { failures++; println("BAŞARISIZ: $name") }
}

private const val SSRC = 0x11223344L
private const val PT = 96

/** Tek-NAL RTP paketi: [nal] yükü (ilk bayt NAL başlığı). */
private fun rtp(seq: Int, ts: Long, marker: Boolean, nal: ByteArray): ByteArray {
    val b = ByteArray(12 + nal.size)
    b[0] = 0x80.toByte()
    b[1] = (PT or (if (marker) 0x80 else 0)).toByte()
    b[2] = (seq shr 8).toByte(); b[3] = seq.toByte()
    for (i in 0..3) b[4 + i] = (ts shr (24 - 8 * i)).toByte()
    for (i in 0..3) b[8 + i] = (SSRC shr (24 - 8 * i)).toByte()
    System.arraycopy(nal, 0, b, 12, nal.size)
    return b
}

private fun idr(seq: Int, ts: Long, marker: Boolean = true) = rtp(seq, ts, marker, byteArrayOf(0x65, 1, 2, 3))
private fun pFrame(seq: Int, ts: Long, marker: Boolean = true) = rtp(seq, ts, marker, byteArrayOf(0x41, 9, 9, 9))
private fun seqOf(p: ByteArray) = ((p[2].toInt() and 0xFF) shl 8) or (p[3].toInt() and 0xFF)

private class Harness {
    val delivered = ArrayList<Int>()
    val nacks = ArrayList<Pair<Long, List<Int>>>()      // (an, seq listesi)
    var unrecCalls = 0
    var clock = 0L
    val buf = VideoReorderBuffer(
        sink = object : VideoReorderBuffer.Sink {
            override fun deliver(pkt: ByteArray, len: Int) { delivered.add(seqOf(pkt)) }
            override fun onUnrecoverable() { unrecCalls++ }
        },
        nackOut = { b, n -> nacks.add(clock to decodeNack(b, n)) },
        senderSsrc = 0xAABBCCDDL,
        mediaSsrc = { SSRC }
    )
    fun rx(p: ByteArray) = buf.onPacket(p, p.size, clock).also { buf.service(clock) }
    fun advance(ms: Long) {
        // gerçek döngü gibi: uyanma anlarında hizmet ver
        val end = clock + ms
        while (clock < end) {
            val w = buf.nextWakeMs(clock)
            clock = if (w < 0) end else minOf(end, clock + w)
            buf.service(clock)
        }
    }
}

/** RFC 4585 NACK paketini çözer, başlık alanlarını doğrular; seq listesini döndürür. */
private fun decodeNack(b: ByteArray, n: Int): List<Int> {
    check("NACK V=2,FMT=1", (b[0].toInt() and 0xFF) == 0x81)
    check("NACK PT=205", (b[1].toInt() and 0xFF) == 205)
    val words = ((b[2].toInt() and 0xFF) shl 8) or (b[3].toInt() and 0xFF)
    check("NACK uzunluk alanı", (words + 1) * 4 == n)
    fun u32(o: Int) = (0..3).fold(0L) { a, i -> (a shl 8) or (b[o + i].toLong() and 0xFF) }
    check("NACK gönderen SSRC", u32(4) == 0xAABBCCDDL)
    check("NACK medya SSRC", u32(8) == SSRC)
    val out = ArrayList<Int>()
    var o = 12
    while (o < n) {
        val pid = ((b[o].toInt() and 0xFF) shl 8) or (b[o + 1].toInt() and 0xFF)
        val blp = ((b[o + 2].toInt() and 0xFF) shl 8) or (b[o + 3].toInt() and 0xFF)
        out.add(pid)
        for (k in 0 until 16) if ((blp shr k) and 1 == 1) out.add((pid + k + 1) and 0xFFFF)
        o += 4
    }
    return out
}

private fun testSeqDiff() {
    check("seqDiff ileri", seqDiff(5, 3) == 2)
    check("seqDiff geri", seqDiff(3, 5) == -2)
    check("seqDiff sarma ileri", seqDiff(1, 65535) == 2)
    check("seqDiff sarma geri", seqDiff(65534, 2) == -4)
}

private fun testNackEncoding() {
    val out = ByteArray(1100)
    val n = RtcpNack.build(out, 0xAABBCCDDL, SSRC, intArrayOf(100, 101, 103, 116, 117, 200), 6)
    // 100 + BLP: 101(bit0) 103(bit2) 116(bit15) ; 117 dışarıda → yeni giriş 117 ; 200 ayrı giriş
    check("NACK boyutu 12+3*4", n == 24)
    val seqs = decodeNack(out, n)
    check("NACK seq listesi", seqs == listOf(100, 101, 103, 116, 117, 200))
    // Gönderici testindeki (Swift, RetransmitTests) bayt vektörüyle birebir aynı olmalı.
    val vector = intArrayOf(0x81, 0xCD, 0x00, 0x05, 0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22, 0x33, 0x44,
        0x00, 0x64, 0x80, 0x05, 0x00, 0x75, 0x00, 0x00, 0x00, 0xC8, 0x00, 0x00)
    check("NACK baytları Swift vektörüyle aynı", n == vector.size && vector.indices.all { (out[it].toInt() and 0xFF) == vector[it] })
    val w = RtcpNack.build(out, 0xAABBCCDDL, SSRC, intArrayOf(65534, 65535, 0, 1), 4)
    check("NACK sarma tek giriş", w == 16 && decodeNack(out, w) == listOf(65534, 65535, 0, 1))
}

private fun testInOrderNoNack() {
    val h = Harness()
    for (i in 0 until 50) { h.rx(pFrame(1000 + i, 90L * i)); h.clock += 1 }
    check("sıralı: hepsi teslim", h.delivered == (1000 until 1050).toList())
    check("sıralı: NACK yok", h.nacks.isEmpty() && h.buf.nackSent == 0L && h.buf.gap == 0L)
    check("sıralı: bekleyen yok", h.buf.nextWakeMs(h.clock) < 0)
}

private fun testReorderWithinGrace() {
    val h = Harness()
    h.rx(pFrame(10, 1)); h.rx(pFrame(12, 3)); h.clock += 1
    check("12 tutuluyor, 11 bekleniyor", h.delivered == listOf(10))
    h.rx(pFrame(11, 2))
    check("sıra düzeldi", h.delivered == listOf(10, 11, 12))
    h.advance(50)
    check("tolerans içinde NACK yok", h.nacks.isEmpty() && h.buf.reordered == 1L && h.buf.unrec == 0L)
}

private fun testRecoveryByRtx() {
    val h = Harness()
    h.rx(pFrame(10, 1)); h.rx(pFrame(12, 3)); h.rx(pFrame(13, 4))
    h.advance(3)
    check("ilk NACK ~2 ms sonra", h.nacks.size == 1 && h.nacks[0].first in 2..3 && h.nacks[0].second == listOf(11))
    check("gap sayacı", h.buf.gap == 1L)
    h.advance(1)
    h.rx(pFrame(11, 2))
    check("rtx ile sıra tamam", h.delivered == listOf(10, 11, 12, 13))
    check("rtx sayacı", h.buf.rtx == 1L && h.buf.unrec == 0L && h.unrecCalls == 0)
    h.advance(100)
    check("kurtarma sonrası ek NACK yok", h.nacks.size == 1)
}

private fun testReNackThenGiveUp() {
    val h = Harness()
    h.rx(pFrame(10, 1)); h.rx(pFrame(12, 3)); h.rx(pFrame(13, 4))
    h.advance(29)
    check("30 ms dolmadan vazgeçilmedi", h.unrecCalls == 0 && h.delivered == listOf(10))
    check("iki NACK (ilk + yeniden)", h.nacks.size == 2 && h.nacks[1].first - h.nacks[0].first >= 10 &&
        h.nacks[1].second == listOf(11))
    h.advance(3)
    check("30 ms sonra vazgeçildi", h.unrecCalls == 1 && h.buf.unrec == 1L)
    check("sonrakiler sırayla teslim", h.delivered == listOf(10, 12, 13))
    h.advance(100)
    check("üçüncü NACK yok", h.nacks.size == 2)
    h.rx(pFrame(11, 2))
    check("geç gelen rtxLate", h.buf.rtxLate == 1L && h.delivered == listOf(10, 12, 13))
}

private fun testWraparound() {
    val h = Harness()
    h.rx(pFrame(65533, 1)); h.rx(pFrame(65534, 2)); h.rx(pFrame(0, 4)); h.rx(pFrame(1, 5))
    h.advance(3)
    check("sarmada NACK 65535", h.nacks.size == 1 && h.nacks[0].second == listOf(65535))
    h.rx(pFrame(65535, 3))
    check("sarmada sıra", h.delivered == listOf(65533, 65534, 65535, 0, 1))
    check("sarmada rtx", h.buf.rtx == 1L)
}

private fun testDuplicateAndMultiHole() {
    val h = Harness()
    h.rx(pFrame(1, 1)); h.rx(pFrame(1, 1))
    check("yinelenen atıldı", h.delivered == listOf(1) && h.buf.duplicates == 1L)
    h.rx(pFrame(5, 5)); h.rx(pFrame(6, 6)); h.rx(pFrame(8, 8))
    h.advance(3)
    check("çoklu delik tek NACK", h.nacks.size == 1 && h.nacks[0].second == listOf(2, 3, 4, 7))
    h.rx(pFrame(3, 3)); h.rx(pFrame(2, 2)); h.rx(pFrame(7, 7)); h.rx(pFrame(4, 4))
    check("çoklu delik sıralı teslim", h.delivered == listOf(1, 2, 3, 4, 5, 6, 7, 8))
    check("çoklu rtx", h.buf.rtx == 4L && h.buf.gap == 4L)
}

private fun testResync() {
    val h = Harness()
    h.rx(pFrame(10, 1)); h.rx(pFrame(12, 3))
    h.rx(pFrame(5000, 9))
    check("büyük sıçrama: vazgeç + yeniden eşitle", h.unrecCalls == 1 && h.delivered == listOf(10, 5000))
}

/** Depacketizer: kayıp sonrası yalnız IDR kapıyı açar; P kareleri çözücüye gitmez. */
private fun testDepacketizerGate() {
    val dp = RtpDepacketizer(SSRC, PT)
    fun push(p: ByteArray): AccessUnit? { check("kabul", dp.accepts(p, p.size)); return dp.feed(p, p.size) }
    check("başta kapı açık", !dp.needsKeyFrame)
    check("P kapı açıkken geçer", push(pFrame(1, 100)) != null)
    dp.onLoss()
    check("kayıp → kapı kapalı", dp.needsKeyFrame)
    check("kayıptan sonraki ilk AU atılır (şüpheli)", push(pFrame(5, 200)) == null)
    check("sonraki P kapıda atılır", push(pFrame(6, 300)) == null && dp.needsKeyFrame)
    val k = push(idr(7, 400))
    check("IDR kapıyı açar", k != null && k.keyFrame && !dp.needsKeyFrame)
    check("IDR sonrası P geçer", push(pFrame(8, 500)) != null)
    check("sayaçlar", dp.auGated >= 1 && dp.auLost >= 1)

    // Birikinti/çözücü kurtarması da aynı kapıyı kullanır; P ile açılmaz.
    dp.requireKeyFrame()
    check("requireKeyFrame kapatır", dp.needsKeyFrame)
    check("P kapıyı açmaz", push(pFrame(9, 600)) == null && dp.needsKeyFrame)
    check("IDR açar", push(idr(10, 700)) != null && !dp.needsKeyFrame)

    // Kayıp AU'nun ortasında: aynı ts'li kalan paketler atılır, IDR olsa bile yarım AU çıkmaz.
    dp.onLoss()
    val half = push(idr(12, 800))            // ts=800, kayıptan sonra ilk paket → şüpheli, atılır
    check("kayıptan sonraki yarım IDR çıkmaz", half == null && dp.needsKeyFrame)
    check("sonraki tam IDR açar", push(idr(13, 900)) != null && !dp.needsKeyFrame)
}

fun main() {
    testSeqDiff()
    testNackEncoding()
    testInOrderNoNack()
    testReorderWithinGrace()
    testRecoveryByRtx()
    testReNackThenGiveUp()
    testWraparound()
    testDuplicateAndMultiHole()
    testResync()
    testDepacketizerGate()
    println(if (failures == 0) "TAMAM: $checks denetim geçti" else "HATA: $failures / $checks denetim başarısız")
    if (failures != 0) kotlin.system.exitProcess(1)
}
