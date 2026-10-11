package dev.atvm.receiver

import android.util.Log
import org.json.JSONObject
import java.io.BufferedWriter
import java.io.OutputStreamWriter
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

/** TV'den bilgisayara doğru kontrol bağlantısı: eşleşmiş cihazı seçip yayını ORADAN başlatmak için.
 *  Mac tarafı (SenderServer) aynı protokolün sunucu ucudur. İki taraf da eşleşme anahtarıyla
 *  kanıt verir: TV, `ready` içindeki Mac kanıtı tutmazsa akış parametrelerini kabul etmez. */
object SenderConnector {
    private const val TAG = "ATVM-Connector"
    private val random = SecureRandom()

    /** Sonuç: null = başarılı, değilse hata mesajı.
     *  Başarıda soket ControlLink'e devredilir: Mac akış parametrelerini (`start`) o sokete yazar,
     *  IDR istekleri ve yayın sonlandırma da oradan gider. */
    fun resume(host: String, port: Int, tvName: String, tvIp: String, mediaPort: Int,
               sessionKey: ByteArray, link: ControlLink): String? {
        val s = java.net.Socket()
        return try {
            s.connect(java.net.InetSocketAddress(host, port), 4000)
            s.tcpNoDelay = true
            s.soTimeout = Protocol.PRE_AUTH_TIMEOUT_MS
            val r = LineReader(s.getInputStream())
            val w = BufferedWriter(OutputStreamWriter(s.getOutputStream(), Charsets.UTF_8))

            fun send(o: JSONObject) { w.write(o.toString()); w.write("\n"); w.flush() }
            fun recv(): JSONObject = JSONObject(r.readLine() ?: throw IllegalStateException("kapandı"))
            fun fail(msg: String): String { s.close(); return msg }
            fun b64(v: String): ByteArray = try { Base64.getDecoder().decode(v) } catch (e: IllegalArgumentException) { ByteArray(0) }

            send(JSONObject().put("t", Msg.HELLO).put("role", "receiver")
                .put("name", tvName).put("ver", Protocol.VERSION))
            val m = recv()
            when (m.optString("t")) {
                Msg.CHALLENGE -> {}
                Msg.DENIED -> return fail(
                    if (m.optString("reason") == "version") "bilgisayardaki uygulama farklı protokol sürümünde — güncelleyin"
                    else "bilgisayar reddetti: " + m.optString("reason"))
                else -> return fail("beklenmeyen yanıt: ${m.optString("t")}")
            }
            if (m.optInt("ver", 1) != Protocol.VERSION) return fail("bilgisayardaki uygulama eski sürüm — güncelleyin")
            val nonceMac = b64(m.optString("nonce_mac"))
            if (nonceMac.size != PairingCrypto.NONCE_BYTES) return fail("bozuk challenge")
            val nonceTv = ByteArray(PairingCrypto.NONCE_BYTES).also { random.nextBytes(it) }
            val proof = PairingCrypto.sessionProof(sessionKey, "rev", "tv", nonceMac, nonceTv)
            send(JSONObject().put("t", Msg.PROOF)
                .put("nonce_tv", Base64.getEncoder().encodeToString(nonceTv))
                .put("proof", Base64.getEncoder().encodeToString(proof)))
            val ready = recv()
            if (ready.optString("t") != Msg.READY) return fail("bilgisayar reddetti: " + ready.optString("reason", ready.optString("t")))
            val want = PairingCrypto.sessionProof(sessionKey, "rev", "mac", nonceMac, nonceTv)
            if (!MessageDigest.isEqual(want, b64(ready.optString("proof")))) {
                return fail("bilgisayarın kimliği doğrulanamadı (eşleşmiş Mac değil)")
            }

            s.soTimeout = 0       // doğrulanmış oturum: yayın boyunca sessiz kalabilir
            send(JSONObject().put("t", "resume").put("media_host", tvIp)
                .put("media_port", mediaPort).put("name", tvName))
            Log.i(TAG, "yayın isteği gönderildi → $host:$port; yanıt bu bağlantıdan bekleniyor")
            link.adoptSenderLink(s, r)
            null
        } catch (e: Exception) {
            Log.w(TAG, "resume başarısız: ${e.message}")
            try { s.close() } catch (ignored: Exception) { }
            e.message ?: "bağlantı hatası"
        }
    }
}
