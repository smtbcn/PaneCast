package dev.atvm.receiver

import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** UDP medya alıcısı: RTP paketlerini yük türüne göre ayırıp çözücüye/ses çıkışına besler. */
class UdpMediaReceiver(
    private val decoder: H264DecoderRenderer,
    private val audio: AudioRenderer,
    private val onNeedsKeyFrame: () -> Unit
) {
    companion object {
        private const val TAG = "ATVM-Media"
        private const val MAX_PACKET = 1500
        /** Kapı kapalıyken IDR isteği tekrarı (kayıp yolu). Birikinti (backpressure) sınırından ayrı. */
        private const val LOSS_IDR_THROTTLE_MS = 300L
        /** GOP atlama isteği pahalıdır (anahtar kare büyük gelir): en sık 2 sn'de bir. */
        private const val BACKPRESSURE_THROTTLE_MS = 2000L
        private const val IDLE_TIMEOUT_MS = 1500
        private const val RTP_HEADER = 12
    }

    @Volatile private var running = false
    /** Oturum kimliği: eski UDP thread'i yeni oturumun `running=true`'sını görüp
     *  kapalı sokette spin döngüsüne giriyordu (ölçüldü: 3778 "Socket closed" satırı). */
    private var session = AtomicBoolean(false)
    private var socket: DatagramSocket? = null
    private var thread: Thread? = null
    @Volatile private var depacketizer: RtpDepacketizer? = null
    @Volatile private var reorder: VideoReorderBuffer? = null
    /** NACK'ın gideceği uç: görüntü paketlerinin geldiği adres/port (yalnız UDP thread'i yazar). */
    private var nackAddr: java.net.InetAddress? = null
    private var nackPort = 0
    @Volatile private var audioPayloadType = -1
    @Volatile private var audioSsrc = 0L

    val bytesReceived = AtomicLong(0)
    val packetsReceived = AtomicLong(0)
    val accessUnits = AtomicLong(0)
    val audioPackets = AtomicLong(0)
    /** Bu oturuma ait olmayan (başka SSRC) ses paketi: önceki/yetim bir yayıncının sesi
     *  yalnız yük türüne bakıldığı için bu oturumun sesine karışıyordu (ölçüldü). */
    val audioForeign = AtomicLong(0)
    val keyFrameRequests = AtomicLong(0)
    /** Son IDR isteğinin anı (ms, monoton): kayıp yolundaki tekrar aralığı için. İki ayrı sınır:
     *  kayıp isteği bunu, birikinti isteği [lastBackpressureRequest]'ı kullanır. */
    @Volatile private var lastIdrRequest = Long.MIN_VALUE / 2
    @Volatile private var lastBackpressureRequest = Long.MIN_VALUE / 2

    fun start(port: Int, ssrc: Long, payloadType: Int = 96,
              audioSsrc: Long = 0, audioPt: Int = -1,
              sampleRate: Int = 48_000, channels: Int = 2): Boolean {
        stop()
        return try {
            // Belgelenmiş Java tuzağı: DatagramSocket(port) anında bind eder; bind'ten
            // SONRA setReceiveBufferSize etkisiz kalabiliyor. Önce bağsız açıp tamponu
            // ayarla, sonra bind et. (Ölçülen: video paketlerinde ~%5,5 kayıp.)
            val s = DatagramSocket(null as java.net.InetSocketAddress?)
            s.receiveBufferSize = 2 * 1024 * 1024
            s.reuseAddress = true
            s.bind(java.net.InetSocketAddress(port))
            s.soTimeout = 1500
            Log.i(TAG, "UDP tamponu istenen=2MB gerçekleşen=${s.receiveBufferSize}B")
            socket = s
            val dp = RtpDepacketizer(ssrc, payloadType)
            depacketizer = dp
            nackAddr = null; nackPort = 0
            reorder = VideoReorderBuffer(
                sink = object : VideoReorderBuffer.Sink {
                    override fun deliver(pkt: ByteArray, len: Int) {
                        val au = dp.feed(pkt, len)
                        if (au != null) {
                            accessUnits.incrementAndGet()
                            decoder.submit(au)
                        }
                    }
                    override fun onUnrecoverable() = dp.onLoss()
                },
                nackOut = { b, n -> sendNack(s, b, n) },
                senderSsrc = java.util.Random().nextInt().toLong() and 0xFFFFFFFFL,
                mediaSsrc = { dp.lockedSsrc }
            ).also { it.log = { line -> Log.w(TAG, line) } }
            audioPayloadType = audioPt
            this.audioSsrc = audioSsrc
            if (audioPt >= 0 && !audio.start(sampleRate, channels)) {
                Log.w(TAG, "ses kanalı açılamadı; yalnız görüntü sürecek")
                audioPayloadType = -1
            }
            val me = AtomicBoolean(true)
            session = me
            running = true
            bytesReceived.set(0); packetsReceived.set(0); accessUnits.set(0)
            audioPackets.set(0); audioForeign.set(0); keyFrameRequests.set(0)
            thread = Thread({ loop(s, me) }, "atvm-udp").apply { priority = Thread.MAX_PRIORITY; start() }
            Log.i(TAG, "UDP $port üzerinde dinleniyor (görüntü ssrc=$ssrc pt=$payloadType, ses pt=$audioPayloadType)")
            true
        } catch (e: Exception) {
            Log.e(TAG, "UDP soket açılamadı (port $port)", e)
            false
        }
    }

    fun stop() {
        running = false
        session.set(false)
        socket?.close()
        thread?.let { t -> try { t.join(800) } catch (e: Exception) { } }
        thread = null
        socket = null
        depacketizer = null
        reorder = null
        audioPayloadType = -1
        audio.stop()
    }

    /** Oturum anahtar karesi beklerken çağrılır; IDR isteğini tekrar tekrar göndermemek için. */
    fun waitingForKeyFrame(): Boolean = depacketizer?.needsKeyFrame ?: false

    /** Çözücü yeniden kurulduğunda çağrılır: taze bir anahtar kareye kadar AU üretilmez. */
    fun forceKeyFrameGate() { dp?.requireKeyFrame() }

    /** Kuyruk taştığında çağrılır: yarım GOP'u beslemek yerine taze anahtar kare beklenir. */
    fun reportBackpressure() {
        val now = nowMs()
        if (now - lastBackpressureRequest < BACKPRESSURE_THROTTLE_MS) return
        lastBackpressureRequest = now
        lastIdrRequest = now          // UDP döngüsü aynı isteği hemen ikinci kez yollamasın
        forceKeyFrameGate()
        keyFrameRequests.incrementAndGet()
        onNeedsKeyFrame()
    }

    private fun nowMs(): Long = System.nanoTime() / 1_000_000

    /** Kapı kapalıyken (kayıp / kurtarma) IDR iste; gelene dek [LOSS_IDR_THROTTLE_MS] aralıkla tekrarla. */
    private fun requestIdrIfGated(dp: RtpDepacketizer, now: Long) {
        if (!dp.needsKeyFrame || now - lastIdrRequest < LOSS_IDR_THROTTLE_MS) return
        lastIdrRequest = now
        keyFrameRequests.incrementAndGet()
        onNeedsKeyFrame()
    }

    private fun sendNack(s: DatagramSocket, b: ByteArray, n: Int) {
        val a = nackAddr ?: return
        try {
            s.send(DatagramPacket(b, n, a, nackPort))
        } catch (e: Exception) {
            Log.w(TAG, "NACK gönderilemedi: ${e.message}")
        }
    }

    private fun loop(s: DatagramSocket, me: AtomicBoolean) {
        val buf = ByteArray(MAX_PACKET)
        val pkt = DatagramPacket(buf, buf.size)
        val dp = depacketizer!!
        val rb = reorder!!
        var timeoutMs = IDLE_TIMEOUT_MS
        while (running && me.get()) {
            try {
                s.receive(pkt)
                packetsReceived.incrementAndGet()
                bytesReceived.addAndGet(pkt.length.toLong())
                if (pkt.length > RTP_HEADER && audioPayloadType >= 0 &&
                    (buf[1].toInt() and 0x7F) == audioPayloadType) {
                    if (audioSsrc != 0L && ssrcOf(buf) != audioSsrc) {
                        audioForeign.incrementAndGet()
                    } else {
                        audioPackets.incrementAndGet()
                        audio.offerPacket(((buf[2].toInt() and 0xFF) shl 8) or (buf[3].toInt() and 0xFF),
                            ((buf[4].toLong() and 0xFF) shl 24) or ((buf[5].toLong() and 0xFF) shl 16) or
                                ((buf[6].toLong() and 0xFF) shl 8) or (buf[7].toLong() and 0xFF),
                            buf, RTP_HEADER, pkt.length - RTP_HEADER)
                    }
                } else if (dp.accepts(buf, pkt.length)) {
                    nackAddr = pkt.address; nackPort = pkt.port
                    rb.onPacket(buf, pkt.length, nowMs())
                }
            } catch (e: java.net.SocketTimeoutException) {
                // sessizlik ya da NACK/vazgeçme zamanı geldi; ControlLink genel zaman aşımını izler
            } catch (e: java.net.SocketException) {
                // Soket kapandı → bu thread'in işi bitti. Devam etmek kapalı sokette
                // başıboş döngü üretir (ölçüldü: 3778 tekrar/saniyeye varan log).
                if (me.get()) Log.w(TAG, "udp soketi kapandı: ${e.message}")
                break
            } catch (e: Exception) {
                if (running && me.get()) Log.w(TAG, "udp döngü hatası: ${e.message}")
            }
            try {
                val now = nowMs()
                rb.service(now)
                requestIdrIfGated(dp, now)
                // Açık boşluk varken kısa bekle ki NACK/vazgeçme zamanında çalışsın; yoksa uzun bekle.
                val wake = rb.nextWakeMs(now)
                val t = if (wake < 0) IDLE_TIMEOUT_MS else minOf(wake, IDLE_TIMEOUT_MS.toLong()).toInt()
                if (t != timeoutMs) { s.soTimeout = t; timeoutMs = t }
            } catch (e: java.net.SocketException) {
                if (me.get()) Log.w(TAG, "udp soketi kapandı: ${e.message}")
                break
            } catch (e: Exception) {
                if (running && me.get()) Log.w(TAG, "udp hizmet hatası: ${e.message}")
            }
        }
        Log.i(TAG, "udp döngüsü bitti")
    }

    private fun ssrcOf(b: ByteArray): Long =
        ((b[8].toLong() and 0xFF) shl 24) or ((b[9].toLong() and 0xFF) shl 16) or
            ((b[10].toLong() and 0xFF) shl 8) or (b[11].toLong() and 0xFF)

    /** İlk iletimde kaybolan (NACK'lanan) video paketi sayısı. */
    fun gapCount(): Long = reorder?.gap ?: 0
    /** Kayıp kurtarma sayaçları (ATVM-Stats satırı için). */
    fun nackStats(): String {
        val r = reorder
        return "nack=" + (r?.nackSent ?: 0) + " rtx=" + (r?.rtx ?: 0) + " rtxLate=" + (r?.rtxLate ?: 0) +
            " unrec=" + (r?.unrec ?: 0)
    }
    fun malformedCount(): Long = dp?.malformed ?: 0
    fun badShort(): Long = dp?.badShort ?: 0
    fun badPt(): Long = dp?.badPayloadType ?: 0
    fun badSsrc(): Long = dp?.badSsrc ?: 0
    fun badHeaderLen(): Long = dp?.badHeaderLen ?: 0
    fun unknownNalType(): Long = dp?.unknownNalType ?: 0

    fun summary(): String =
        "pkt=${packetsReceived.get()} au=${accessUnits.get()} sesPkt=${audioPackets.get()} " +
            "bytes=${bytesReceived.get() / 1024}KB " +
            "gap=${gapCount()} ${nackStats()} bad=${dp?.malformed ?: 0} idrReq=${keyFrameRequests.get()}"

    private val dp: RtpDepacketizer? get() = depacketizer
}
