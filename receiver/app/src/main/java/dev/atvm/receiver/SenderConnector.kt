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
     *  IDR istekleri ve yayın sonlandırma da oradan gider.
     *
     *  `hosts` bir aday listesidir: aynı servis adının birden çok arayüz adresi olabilir ve
     *  yanlış adaya düşmek "OK'a basınca hiçbir şey olmaması" demekti (ölçüldü). Adaylar
     *  sırayla denenir; ilki tutunca durulur. */
    /**
     * Bağlantıyı kuramama nedeninin kimliği. Cümle burada durmuyor: kullanıcıya gösterilen
     * yazı iki dilli katalogda (`res/values`, `res/values-tr`), eşleme `MainActivity.connectText`
     * içinde ve `when` önermeli — yeni bir neden eklenip yazısı unutulursa derleme durur.
     */
    enum class ConnectFail { unresolved, protoMismatch, denied, unexpected, oldApp, badChallenge,
                                      identity, network }

    /** `detail` yalnız Mac'in kendi gerekçesini aynen taşımak gerektiğinde doludur. */
    data class Failure(val kind: ConnectFail, val detail: String = "")

    fun resume(hosts: List<String>, port: Int, tvName: String, tvIp: String, mediaPort: Int,
               sessionKey: ByteArray, link: ControlLink): Failure? {
        var last = Failure(ConnectFail.unresolved)
        for (host in hosts) {
            last = attempt(host, port, tvName, tvIp, mediaPort, sessionKey, link) ?: return null
        }
        return last
    }

    private fun attempt(host: String, port: Int, tvName: String, tvIp: String, mediaPort: Int,
                        sessionKey: ByteArray, link: ControlLink): Failure? {
        val s = java.net.Socket()
        return try {
            s.connect(java.net.InetSocketAddress(host, port), 4000)
            s.tcpNoDelay = true
            s.soTimeout = Protocol.PRE_AUTH_TIMEOUT_MS
            val r = LineReader(s.getInputStream())
            val w = BufferedWriter(OutputStreamWriter(s.getOutputStream(), Charsets.UTF_8))

            fun send(o: JSONObject) { w.write(o.toString()); w.write("\n"); w.flush() }
            fun recv(): JSONObject = JSONObject(r.readLine() ?: throw IllegalStateException("kapandı"))
            fun fail(kind: ConnectFail, detail: String = ""): Failure { s.close(); return Failure(kind, detail) }
            fun b64(v: String): ByteArray = try { Base64.getDecoder().decode(v) } catch (e: IllegalArgumentException) { ByteArray(0) }

            send(JSONObject().put("t", Msg.HELLO).put("role", "receiver")
                .put("name", tvName).put("ver", Protocol.VERSION))
            val m = recv()
            when (m.optString("t")) {
                Msg.CHALLENGE -> {}
                Msg.DENIED -> return if (m.optString("reason") == "version")
                    fail(ConnectFail.protoMismatch)
                else fail(ConnectFail.denied, m.optString("reason"))
                else -> return fail(ConnectFail.unexpected, m.optString("t"))
            }
            if (m.optInt("ver", 1) != Protocol.VERSION) return fail(ConnectFail.oldApp)
            val nonceMac = b64(m.optString("nonce_mac"))
            if (nonceMac.size != PairingCrypto.NONCE_BYTES) return fail(ConnectFail.badChallenge)
            val nonceTv = ByteArray(PairingCrypto.NONCE_BYTES).also { random.nextBytes(it) }
            val proof = PairingCrypto.sessionProof(sessionKey, "rev", "tv", nonceMac, nonceTv)
            send(JSONObject().put("t", Msg.PROOF)
                .put("nonce_tv", Base64.getEncoder().encodeToString(nonceTv))
                .put("proof", Base64.getEncoder().encodeToString(proof)))
            val ready = recv()
            if (ready.optString("t") != Msg.READY)
                return fail(ConnectFail.denied, ready.optString("reason", ready.optString("t")))
            val want = PairingCrypto.sessionProof(sessionKey, "rev", "mac", nonceMac, nonceTv)
            if (!MessageDigest.isEqual(want, b64(ready.optString("proof")))) {
                return fail(ConnectFail.identity)
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
            Failure(ConnectFail.network, e.message ?: e.javaClass.simpleName)
        }
    }
}
