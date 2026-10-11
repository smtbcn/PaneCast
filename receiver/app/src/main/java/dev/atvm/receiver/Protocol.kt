package dev.atvm.receiver

import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream

/** Tel protokolünün sabitleri ve kodlama/kod çözme yardımcıları.
 *  Tek kaynak spesifikasyonu: docs/protocol.md — her iki platform aynı alan adlarını kullanır. */
object Protocol {
    /** v2: passkey eşleştirmesi + karşılıklı oturum kanıtı. v1 uçlar `denied/version` alır. */
    const val VERSION = 2

    /** TCP kontrol kanalı dinleme portu. */
    const val CONTROL_PORT = 7601

    /** UDP medya (RTP) dinleme portu. */
    const val MEDIA_PORT = 7602

    /** mDNS servis tipi (TV → Mac keşfi için yayımlanır). */
    const val SERVICE_TYPE = "_atvm._tcp"

    const val PIN_LENGTH = 6
    const val PIN_TTL_MS = 180_000L

    /** Doğrulanmamış bağlantı bu süre sessiz kalırsa düşer (tek kabul döngüsünü tutamasın). */
    const val PRE_AUTH_TIMEOUT_MS = 15_000
    /** Tek JSON satırının üst sınırı. */
    const val MAX_LINE_BYTES = 8192

    fun json(vararg fields: Pair<String, Any?>): String {
        val o = JSONObject()
        for ((k, v) in fields) if (v != null) o.put(k, v)
        return o.toString()
    }

    fun parse(line: String): JSONObject? = try {
        JSONObject(line)
    } catch (e: Exception) {
        null
    }
}

/** Uzunluğu sınırlı satır okuyucu: satır sonu göndermeden veri yığan karşı uç belleği
 *  şişiremez; sınır aşılınca IOException ile bağlantı düşer. */
class LineReader(input: InputStream, private val max: Int = Protocol.MAX_LINE_BYTES) {
    private val inp = BufferedInputStream(input)
    private val buf = ByteArrayOutputStream()

    fun readLine(): String? {
        buf.reset()
        while (true) {
            val b = inp.read()
            if (b < 0) return null
            if (b == '\n'.code) return buf.toString("UTF-8")
            if (buf.size() >= max) throw IOException("satır ${max} baytı aştı")
            buf.write(b)
        }
    }
}

/** Kontrol kanalı mesaj türleri (JSON-lines, tek satır tek mesaj). */
object Msg {
    /** JSON'da mesaj türü alanının adı. */
    const val T = "t"
    const val HELLO = "hello"                 // Mac → TV: tanıt + yetenekler
    const val PAIR_REQUIRED = "pair_required"  // TV → Mac: eşleşme yok, kod ekranda
    const val PAIR_INIT = "pair_init"          // Mac → TV: geçici ECDH açık anahtarı
    const val PAIR_KEY = "pair_key"            // TV → Mac: geçici ECDH açık anahtarı
    const val PK_COMMIT = "pk_commit"          // iki yön: tur i taahhüdü
    const val PK_OPEN = "pk_open"              // iki yön: tur i nonce'u (taahhüdü açar)
    const val PAIR_CONFIRM = "pair_confirm"    // Mac → TV: anahtar onayı
    const val PAIR_ABORT = "pair_abort"        // Mac → TV: deneme bırakıldı
    const val PAIRED = "paired"                // TV → Mac: başarılı + TV onayı
    const val CHALLENGE = "challenge"          // sunucu → istemci: zaten eşleşmiş, nonce
    const val PROOF = "proof"                  // istemci → sunucu: nonce + HMAC kanıtı
    const val READY = "ready"                  // sunucu → istemci: oturum açık + sunucu kanıtı
    const val DENIED = "denied"                // TV → Mac: eşleşme reddi (neden ile)
    const val START = "start"                  // Mac → TV: yayın parametreleri
    const val STARTED = "started"              // TV → Mac
    const val STOP = "stop"                    // Mac → TV
    const val STOPPED = "stopped"              // TV → Mac
    const val IDR_REQUEST = "idr_request"      // TV → Mac: anahtar kare zorla
    const val STATS = "stats"                  // karşılıklı ölçüm
    const val CAP_ERROR = "cap_error"          // TV → Mac: codec/çözünürlük reddi
    const val PING = "ping"
    const val PONG = "pong"
    const val UNPAIR = "unpair"                // Mac → TV: eşleştirmeyi sil
}

/**
 * `start` mesajının alanları. Uzun parametre listesi yerine tek yapı: ses eklendiğinde
 * arayüzün imzası büyümesin.
 */
data class SessionParams(
    val width: Int, val height: Int, val fps: Int, val bitrate: Int,
    val ssrc: Long, val mediaPort: Int, val payloadType: Int,
    val audioSsrc: Long, val audioPayloadType: Int, val audioSampleRate: Int, val audioChannels: Int,
    /** §5.1: true ise iki akışın RTP damgaları aynı köke bağlı; tabanlar u32. */
    val sync: Boolean = false, val videoRtpBase: Long = 0, val audioRtpBase: Long = 0
) {
    companion object {
        fun from(m: org.json.JSONObject) = SessionParams(
            m.optInt("width"), m.optInt("height"), m.optInt("fps", 60),
            m.optInt("bitrate", 12_000_000), m.optLong("ssrc"),
            m.optInt("media_port", Protocol.MEDIA_PORT), m.optInt("payload_type", 96),
            m.optLong("audio_ssrc"), m.optInt("audio_payload_type", -1),
            m.optInt("audio_sample_rate", 48_000), m.optInt("audio_channels", 2),
            m.optInt("sync", 0) == 1 && m.has("video_rtp_base") && m.has("audio_rtp_base"),
            m.optLong("video_rtp_base") and 0xFFFFFFFFL, m.optLong("audio_rtp_base") and 0xFFFFFFFFL
        )
    }
}
