package dev.atvm.receiver

import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.content.Context
import android.util.Log
import java.net.InetAddress

/** Yerel ağdaki PaneCast yayıncılarını (Mac/Windows bilgisayarlarını) tarar.
 *  TV'nin "eşleşili bilgisayarları seç" akışı buna dayanır. */
class SenderBrowser(context: Context, private val onUpdate: (List<Computer>) -> Unit) {
    data class Computer(val name: String, val address: String, val port: Int) {
        /** ListView varsayılan toString()'i ham veri sınıfını basıyordu (ekranda okunaksız). */
        override fun toString(): String =
            name.removePrefix("ATVM-") + "  ·  " + address
    }

    companion object { private const val TAG = "ATVM-Browser"; const val TYPE = "_atvm-sender._tcp." }

    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var listener: NsdManager.DiscoveryListener? = null
    private val found = LinkedHashMap<String, Computer>()

    fun start() {
        stop()
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(t: String) { Log.i(TAG, "tarama başladı: $t") }
            override fun onServiceFound(info: NsdServiceInfo) {
                if (!info.serviceType.endsWith(TYPE) && info.serviceType != TYPE) return
                resolve(info)
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                found.remove(info.serviceName); publish()
            }
            override fun onDiscoveryStopped(t: String) { }
            override fun onStartDiscoveryFailed(t: String, e: Int) { Log.w(TAG, "tarama başlatılamadı code=$e") }
            override fun onStopDiscoveryFailed(t: String, e: Int) { }
        }
        listener = l
        try {
            nsd.discoverServices(TYPE, NsdManager.PROTOCOL_DNS_SD, l)
        } catch (e: Exception) {
            Log.w(TAG, "NsdManager tarama başlatılamadı: ${e.message}")
        }
    }

    private fun resolve(info: NsdServiceInfo) {
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(s: NsdServiceInfo, e: Int) { Log.w(TAG, "çözümleme hatası $e") }
            override fun onServiceResolved(s: NsdServiceInfo) {
                val host: InetAddress = s.host ?: return
                // Tek adres geliyor; çok arayüzlü bilgisayarda hangisinin döneceği keyfi.
                // Adayların tam listesi bağlantı anında üretilir (bkz. SenderAddresses.expand).
                found[s.serviceName] = Computer(s.serviceName, host.hostAddress ?: return, s.port)
                publish()
            }
        })
    }

    private fun publish() = onUpdate(found.values.sortedBy { it.name })

    fun stop() {
        listener?.let { try { nsd.stopServiceDiscovery(it) } catch (e: Exception) { } }
        listener = null
    }
}
