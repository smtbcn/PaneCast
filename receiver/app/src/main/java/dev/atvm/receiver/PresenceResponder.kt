package dev.atvm.receiver

import android.os.Build
import android.util.Log
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Keşif yoklamasına cevap verir (UDP 7611).
 *
 * Neden gerekli: Mac, TV'nin adresini eşleşme kaydından alıyordu. Eşleşme silinince
 * adres de silindi ve yeniden eşleşmek imkânsız hale geldi (tavuk-yumurta). Artık Mac
 * ağa `find` yayını yapar; açık olan her alıcı kendi adresini tek-seferlik geri yazar.
 */
class PresenceResponder(private val localIpv4s: () -> List<String>,
                        private val paired: () -> Boolean) {
    companion object {
        private const val TAG = "ATVM-Presence"
        const val PORT = 7611
        private const val MAX_PACKET = 1024
    }

    private var socket: DatagramSocket? = null
    private var thread: Thread? = null
    private val running = AtomicBoolean(false)
    private var queries = 0L

    fun start() {
        if (running.getAndSet(true)) return
        thread = Thread({ loop() }, "atvm-presence").apply { isDaemon = true; start() }
    }

    fun stop() {
        running.set(false)
        socket?.close()
        try { thread?.join(400) } catch (e: Exception) { }
        thread = null; socket = null
    }

    private fun loop() {
        val s = try {
            DatagramSocket(null as InetSocketAddress?).apply {
                reuseAddress = true
                broadcast = true
                bind(InetSocketAddress(PORT))
            }
        } catch (e: Exception) {
            Log.w(TAG, "$PORT dinlenemiyor: ${e.message}")
            running.set(false)
            return
        }
        socket = s
        val buf = ByteArray(MAX_PACKET)
        val pkt = DatagramPacket(buf, buf.size)
        while (running.get()) {
            try {
                s.receive(pkt)
                val text = String(buf, 0, pkt.length, Charsets.UTF_8)
                if (!text.contains("\"find\"")) continue
                queries++
                val ip = localIpv4s().firstOrNull() ?: continue
                val reply = JSONObject()
                    .put("t", "tv")
                    .put("name", Build.MODEL)
                    .put("ip", ip)
                    .put("cport", Protocol.CONTROL_PORT)
                    .put("mport", Protocol.MEDIA_PORT)
                    .put("paired", paired())
                    .toString()
                val out = DatagramPacket(reply.toByteArray(Charsets.UTF_8), reply.length,
                    pkt.address, pkt.port)
                s.send(out)
                if (queries % 10 == 1L) Log.i(TAG, "yoklama yanıtlandı (#$queries) → $ip")
            } catch (e: Exception) {
                if (running.get()) { Log.w(TAG, "yoklama döngüsü: ${e.message}"); return }
            }
        }
    }
}
