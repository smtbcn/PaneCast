package dev.atvm.receiver

import android.util.Log
import java.io.BufferedWriter
import java.io.File
import java.io.OutputStreamWriter
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

/** TCP kontrol kanalı sunucusu (medya UDP, kontrol TCP/JSON-lines).
 *  Eşleştirme ve oturum kanıtı docs/protocol.md §3.2'de tanımlıdır. */
class ControlLink(storageDir: File, private val listener: Listener) {
    interface Listener {
        fun onPeerHello(name: String, version: Int)
        fun onPinShown(pin: String)
        fun onPaired(sessionId: String)
        fun onDenied(reason: String)
        fun onStartSession(p: SessionParams): Boolean
        fun onStopSession(reason: String)
        fun onClientDisconnected()

        /** Kontrol kanalı dinlenemiyor: TV, Mac'in isteklerini duyamaz. Sebep arayüzde
         *  gösterilir — sessiz kalıp "eşleşme yok" gibi görünmesindense (ölçülen kusur:
         *  accept bir kez düşünce uygulama bir daha hiç dinlemiyordu). */
        fun onControlChannelDown(reason: String) { }

        /** Kanal yeniden dinleniyor. */
        fun onControlChannelUp() { }
    }

    companion object { private const val TAG = "ATVM-Control" }

    private val pairing = Pairing(storageDir)

    private val running = AtomicBoolean(false)
    private var server: ServerSocket? = null
    private var acceptThread: Thread? = null
    @Volatile private var writer: BufferedWriter? = null
    @Volatile private var client: Socket? = null
    @Volatile private var outboundWriter: BufferedWriter? = null
    @Volatile private var outboundSocket: Socket? = null
    @Volatile private var authed = false
    @Volatile var peerName: String = "-"
        private set
    val isPaired: Boolean get() = pairing.paired

    fun start() {
        if (running.get()) return
        running.set(true)
        acceptThread = Thread({ acceptLoop() }, "atvm-control").apply { start() }
    }

    fun stop() {
        running.set(false)
        try { server?.close() } catch (e: Exception) { }
        try { client?.close() } catch (e: Exception) { }
        try { outboundSocket?.close() } catch (e: Exception) { }
        writer?.let { try { it.close() } catch (e: Exception) { } }
        outboundWriter?.let { try { it.close() } catch (e: Exception) { } }
        writer = null; client = null; authed = false
        outboundWriter = null; outboundSocket = null
        acceptThread = null
    }

    /** Alıcı UDP boşluk gördüğünde çağırır. */
    fun requestIdr() = send(Protocol.json(Msg.T to Msg.IDR_REQUEST))

    /**
     * Yayın **TV tarafında** bittiğinde Mac'e bildirir. Neden gerekli (ölçüldü, gerçek TV):
     * kullanıcı kumandadan DURDUR'a basınca ya da yüzey/çözücü düştüğünde TV yayını kesiyor,
     * Mac'e tek satır gitmiyordu — Mac sonsuza dek "Yayında" kalıp pencereyi ağa yazmayı
     * sürdürüyordu. Yalnız Mac'ten gelen `stop`/`unpair` için bildirim zaten yanıt olarak
     * gidiyordu; kendiliğinden duruşlarda hiçbir şey yoktu.
     *
     * Soket yazımı kendi iş parçacığında yapılır: duruş kararı ana iş parçacığında
     * (`stopStream`) koşuyor ve Android ana iş parçacığında ağ erişimine izin vermez —
     * ilk denemede tam da böyle sessizce düştü ("kontrol yazımı başarısız: null").
     */
    fun notifyStopped(reason: String) {
        val json = Protocol.json(Msg.T to Msg.STOPPED, "reason" to reason)
        Thread({ if (!send(json)) Log.w(TAG, "durdurma bildirisi gitmedi: uç yok ($reason)") },
               "atvm-stopped").start()
    }

    fun send(json: String): Boolean {
        // IDR isteği yalnız doğrulanmış uca gider; doğrulanmamış bir 7601 bağlantısı araya giremez.
        val w = (if (authed) writer else null) ?: outboundWriter
        if (w == null) {
            // Ölçülen tanı boşluğu: uç yoktu ve `false` sessizce dönüyordu; "neden bildirmedi"
            // sorusu logda iz bırakmıyordu.
            Log.w(TAG, "kontrol mesajı yazılamadı, açık doğrulanmış uç yok: ${json.take(48)}")
            return false
        }
        return sendOn(w, json)
    }

    private fun sendOn(w: BufferedWriter, json: String): Boolean {
        return try {
            synchronized(w) { w.write(json); w.write("\n"); w.flush() }
            true
        } catch (e: Exception) {
            // `e.message` null olabiliyor (NetworkOnMainThreadException): sınıf adını da yaz.
            Log.w(TAG, "kontrol yazımı başarısız: ${e.message ?: e.javaClass.simpleName}")
            false
        }
    }

    fun forgetPairing() {
        pairing.clear()
        displayPin(force = true)
    }

    /** Uygulama açılır açılmaz ekranda bir kod görünmesi için (kullanıcı geribildirimi).
     *  force=true → yeni kod üretir (kumanda ile "yeni PIN" isteği). */
    fun displayPin(force: Boolean = false) {
        if (pairing.paired) return
        listener.onPinShown(if (force) pairing.newPin() else pairing.pinOrNew())
    }

    fun pinSecondsLeft(): Int = pairing.pinSecondsLeft()
    fun lockSecondsLeft(): Int = ((pairing.lockMsLeft() + 999) / 1000).toInt()
    fun storedSessionKey(): ByteArray? = pairing.storedSessionKey()

    private fun acceptLoop() {
        var failures = 0
        while (running.get()) {
            try {
                // Önceki örnekten kalan soket birkaç saniye dolu olabilir: her turda yeniden
                // denenir, vazgeçilmez. Tek örnek kuralı bu yüzden gevşetilmez.
                server = ServerSocket(Protocol.CONTROL_PORT)
                failures = 0
                listener.onControlChannelUp()
                Log.i(TAG, "kontrol kanalı ${Protocol.CONTROL_PORT} üzerinde dinleniyor")
                while (running.get()) {
                    val s = server!!.accept()
                    s.tcpNoDelay = true      // Nagle kapalı: küçük kontrol mesajları için kritik
                    handle(s)
                }
            } catch (e: Exception) {
                if (!running.get()) break
                failures++
                val why = e.message ?: e.javaClass.simpleName
                Log.e(TAG, "kontrol kanalı kapandı (deneme $failures): $why", e)
                listener.onControlChannelDown("$why (deneme $failures)")
                try { server?.close() } catch (ignored: Exception) { }
                server = null; writer = null; client = null; authed = false
                // Üstel geri çekilme, 30 sn'de tavan: boştayken ağa yük bindirmeyelim.
                val wait = minOf(30_000L, 1_000L shl minOf(5, failures - 1))
                try { Thread.sleep(wait) } catch (ignored: InterruptedException) { break }
            }
        }
        try { server?.close() } catch (e: Exception) { }
        server = null; writer = null; client = null; authed = false
        listener.onClientDisconnected()
    }

    /** Tek bağlantının durumu. Kabul döngüsü bağlantıları sırayla işler; aynı anda tek oturum. */
    private inner class Conn(val s: Socket, val w: BufferedWriter) {
        val reader = LineReader(s.getInputStream())
        var helloSeen = false
        var challenge: ByteArray? = null
        var exchange: PasskeyResponder? = null

        fun reply(vararg fields: Pair<String, Any?>) = sendOn(w, Protocol.json(*fields))

        /** false → bağlantı kapatılır. */
        fun route(m: JSONObject): Boolean {
            val t = m.optString("t")
            when (t) {
                Msg.HELLO -> {
                    if (helloSeen) return unexpected(t)
                    helloSeen = true
                    peerName = m.optString("name", "?")
                    val ver = m.optInt("ver", 1)
                    listener.onPeerHello(peerName, ver)
                    if (ver != Protocol.VERSION) {
                        reply(Msg.T to Msg.DENIED, "reason" to "version", "ver" to Protocol.VERSION)
                        Log.w(TAG, "farklı protokol sürümü: $peerName v$ver (beklenen v${Protocol.VERSION})")
                        return false
                    }
                    if (pairing.paired) {
                        val n = pairing.newNonce()
                        challenge = n
                        reply(Msg.T to Msg.CHALLENGE, "nonce_tv" to pairing.b64(n), "ver" to Protocol.VERSION)
                    } else {
                        val lock = pairing.lockMsLeft()
                        if (lock > 0) return locked(lock)
                        displayPin()
                        // Kullanıcı kodu Mac'e yazarken bağlantı beklesin.
                        s.soTimeout = Protocol.PIN_TTL_MS.toInt()
                        reply(Msg.T to Msg.PAIR_REQUIRED, "pin_ttl_ms" to Protocol.PIN_TTL_MS, "ver" to Protocol.VERSION)
                    }
                }
                Msg.PAIR_INIT -> {
                    if (!helloSeen || exchange != null) return unexpected(t)
                    if (pairing.paired) {
                        reply(Msg.T to Msg.DENIED, "reason" to "already_paired"); return false
                    }
                    val lock = pairing.lockMsLeft()
                    if (lock > 0) return locked(lock)
                    val passkey = pairing.beginAttempt() ?: run {
                        displayPin(force = true)
                        reply(Msg.T to Msg.DENIED, "reason" to "pin_expired"); return false
                    }
                    s.soTimeout = Protocol.PRE_AUTH_TIMEOUT_MS
                    val ex = PasskeyResponder(passkey, PairingCrypto.newKeyPair(pairing.random), pairing::newNonce)
                    exchange = ex
                    val pk = ex.onInit(pairing.unb64(m.optString("pk")))
                    reply(Msg.T to Msg.PAIR_KEY, "pk" to pairing.b64(pk))
                }
                Msg.PK_COMMIT -> {
                    val ex = exchange ?: return unexpected(t)
                    val cb = ex.onCommit(m.optInt("i", -1), pairing.unb64(m.optString("c")))
                    reply(Msg.T to Msg.PK_COMMIT, "i" to m.optInt("i"), "c" to pairing.b64(cb))
                }
                Msg.PK_OPEN -> {
                    val ex = exchange ?: return unexpected(t)
                    val nb = ex.onOpen(m.optInt("i", -1), pairing.unb64(m.optString("n")))
                    reply(Msg.T to Msg.PK_OPEN, "i" to m.optInt("i"), "n" to pairing.b64(nb))
                }
                Msg.PAIR_CONFIRM -> {
                    val ex = exchange ?: return unexpected(t)
                    val (key, tvMac) = ex.onConfirm(pairing.unb64(m.optString("mac")))
                    exchange = null
                    pairing.endAttempt(key)
                    authed = true
                    s.soTimeout = 0
                    val sid = PairingCrypto.fingerprint(key)
                    reply(Msg.T to Msg.PAIRED, "session" to sid, "mac" to pairing.b64(tvMac))
                    listener.onPaired(sid)
                    Log.i(TAG, "eşleşme tamam, oturum parmak izi=$sid")
                }
                Msg.PAIR_ABORT -> {
                    if (exchange != null) failAttempt("aborted")
                    return false
                }
                Msg.PROOF -> {
                    val n = challenge ?: return unexpected(t)
                    challenge = null
                    val key = pairing.storedSessionKey()
                    val nonceMac = pairing.unb64(m.optString("nonce_mac"))
                    val got = pairing.unb64(m.optString("proof"))
                    if (key == null || nonceMac.size != PairingCrypto.NONCE_BYTES ||
                        !MessageDigest.isEqual(PairingCrypto.sessionProof(key, "ctl", "mac", n, nonceMac), got)) {
                        reply(Msg.T to Msg.DENIED, "reason" to "auth_failed")
                        Log.w(TAG, "oturum kanıtı doğrulanamadı: $peerName")
                        listener.onDenied("auth_failed")
                        return false
                    }
                    authed = true
                    s.soTimeout = 0
                    reply(Msg.T to Msg.READY, "session" to PairingCrypto.fingerprint(key),
                        "proof" to pairing.b64(PairingCrypto.sessionProof(key, "ctl", "tv", n, nonceMac)))
                }
                Msg.START -> {
                    if (!authed) return notPaired()
                    handleStart(m) { json -> sendOn(w, json) }
                }
                Msg.STOP -> {
                    if (!authed) return notPaired()
                    listener.onStopSession("client_stop")
                    reply(Msg.T to Msg.STOPPED)
                }
                Msg.PING -> reply(Msg.T to Msg.PONG, "now" to System.currentTimeMillis())
                Msg.UNPAIR -> {
                    if (!authed) return notPaired()
                    listener.onStopSession("unpaired")
                    forgetPairing()
                    reply(Msg.T to Msg.STOPPED, "reason" to "unpaired")
                    authed = false
                    return false
                }
                else -> Log.w(TAG, "bilinmeyen kontrol mesajı: $t")
            }
            return true
        }

        fun failAttempt(reason: String) {
            exchange = null
            pairing.endAttempt(null)
            displayPin(force = true)
            Log.w(TAG, "eşleştirme denemesi düştü: $reason")
        }

        private fun locked(ms: Long): Boolean {
            reply(Msg.T to Msg.DENIED, "reason" to "locked", "retry_after_ms" to ms, "ver" to Protocol.VERSION)
            return false
        }
        private fun notPaired(): Boolean { reply(Msg.T to Msg.DENIED, "reason" to "not_paired"); return true }
        private fun unexpected(t: String): Boolean {
            reply(Msg.T to Msg.DENIED, "reason" to "unexpected_message")
            Log.w(TAG, "sıra dışı mesaj: $t")
            return exchange == null && authed
        }
    }

    private fun handle(s: Socket) {
        client = s
        authed = false
        s.soTimeout = Protocol.PRE_AUTH_TIMEOUT_MS
        val w = BufferedWriter(OutputStreamWriter(s.getOutputStream(), Charsets.UTF_8))
        writer = w
        val c = Conn(s, w)
        var wasAuthed = false
        try {
            while (running.get()) {
                val line = c.reader.readLine() ?: break
                val m = Protocol.parse(line)
                if (m == null) {
                    c.reply(Msg.T to Msg.DENIED, "reason" to "bad_json")
                    if (!authed) break
                    continue
                }
                val keep = try { c.route(m) } catch (e: PasskeyResponder.Failure) {
                    c.reply(Msg.T to Msg.DENIED, "reason" to e.reason)
                    c.failAttempt(e.reason)
                    false
                }
                wasAuthed = wasAuthed || authed
                if (!keep) break
            }
        } catch (e: Exception) {
            Log.i(TAG, "kontrol bağlantısı koptu: ${e.message}")
        } finally {
            // Yarım kalan deneme (bağlantı koptu, zaman aşımı) de bir başarısız deneme sayılır.
            if (c.exchange != null) c.failAttempt("disconnected")
            try { s.close() } catch (e: Exception) { }
            writer = null; client = null; authed = false
            // Doğrulanmamış bir bağlantının kapanması yayını etkilemez.
            if (wasAuthed) listener.onClientDisconnected()
        }
    }

    /** TV'nin bilgisayara kendi açtığı (doğrulanmış) bağlantı. Mac `start`ı bu sokete yazar;
     *  IDR istekleri ve yayın sonlandırma da aynı soketten gider. */
    fun adoptSenderLink(s: Socket, reader: LineReader) {
        s.tcpNoDelay = true
        outboundSocket = s
        val w = BufferedWriter(OutputStreamWriter(s.getOutputStream(), Charsets.UTF_8))
        outboundWriter = w
        Thread({ senderLinkLoop(s, reader, w) }, "atvm-sender-link").start()
    }

    private fun senderLinkLoop(s: Socket, reader: LineReader, w: BufferedWriter) {
        try {
            while (running.get()) {
                val line = reader.readLine() ?: break
                val m = Protocol.parse(line) ?: continue
                when (m.optString("t")) {
                    Msg.START -> handleStart(m) { json -> sendOn(w, json) }
                    Msg.STOPPED -> listener.onStopSession("sender_stop")
                    Msg.DENIED -> listener.onDenied(m.optString("reason", "?"))
                    Msg.PONG -> { }
                    else -> Log.w(TAG, "bilgisayar bağlantısında bilinmeyen mesaj: ${m.optString("t")}")
                }
            }
        } catch (e: Exception) {
            Log.i(TAG, "bilgisayar bağlantısı koptu: ${e.message}")
        } finally {
            outboundWriter = null; outboundSocket = null
            try { s.close() } catch (e: Exception) { }
        }
    }

    private fun handleStart(m: JSONObject, reply: (String) -> Unit) {
        val p = SessionParams.from(m)
        if (listener.onStartSession(p)) {
            reply(Protocol.json(Msg.T to Msg.STARTED, "media_port" to p.mediaPort))
        } else {
            reply(Protocol.json(Msg.T to Msg.CAP_ERROR, "reason" to "decoder_or_socket_failed",
                "max_width" to 1920, "max_height" to 1088, "codecs" to "video/avc"))
        }
    }
}
