package dev.atvm.receiver

import android.util.Log
import java.io.File
import java.security.SecureRandom
import java.util.Base64

/** TV tarafı eşleştirme durumu: ekrandaki 6 haneli kod, deneme sınırı ve eşleşme anahtarları.
 *  Kod her denemeden sonra (başarılı ya da değil) yenilenir; ardışık MAX_FAILURES başarısız
 *  deneme kilit açar (30 sn, her yeni kilitte iki katı, en çok LOCK_MAX_MS).
 *  Anahtar **yayıncı başına bir kayıt** olarak saklanır (docs/protocol.md §3.3): aynı TV'yi
 *  hem Mac hem Windows kullanabilsin; bir bilgisayarı ezmenin yolu diğerini eşleşmeye
 *  zorlamak olmamalı. Kayıtlar uygulamaya özel dizinde (filesDir, yalnız bu uygulamanın
 *  UID'si okur; allowBackup=false). */
class Pairing(dir: File, private val clock: () -> Long = System::currentTimeMillis) {
    companion object {
        private const val TAG = "ATVM-Pairing"
        const val MAX_FAILURES = 3
        const val LOCK_BASE_MS = 30_000L
        const val LOCK_MAX_MS = 480_000L

        /** Eşzamanlı eşleşmiş bilgisayar sınırı. Daha fazlası bu ürünün hedef kitlesi için
         *  anlamsız; deneme başına sabit-zamanlı karşılaştırma sayısını da bağlı tutar. */
        const val MAX_PEERS = 4

        /** `device_id` = 12 rastgele baytın padding'siz base64url karşılığı (§3.4). */
        const val ID_LENGTH = 16
        private const val KEY_BYTES = 32L
        private const val PEERS_DIR = "pair_keys_v2"
        private const val LEGACY_STEM = "legacy"   // geçerli id olamaz: 16 karakter değil
        private const val LEGACY_FILE = "pair_key_v2.bin"
    }

    /** Bir bilgisayarın eşleşme kaydı. `id` null = eski yayıncı, kimlik göndermiyor. */
    data class Peer(val id: String?, val key: ByteArray, val name: String, val lastSeen: Long) {
        override fun equals(other: Any?): Boolean = other is Peer && other.id == id &&
            other.name == name && other.lastSeen == lastSeen && other.key.contentEquals(key)
        override fun hashCode(): Int =
            (id?.hashCode() ?: 0) * 31 + name.hashCode() * 31 + key.contentHashCode()
    }

    /** `hello`dan gelen, henüz doğrulanmamış etiket. Ağdan gelir, bu yüzden süzülmeden kullanılmaz. */
    data class Claim(val id: String?, val name: String)

    private val peersDir = File(dir, PEERS_DIR)
    private val legacyFile = File(dir, LEGACY_FILE)
    val random = SecureRandom()

    @Volatile var pin: String? = null
        private set
    @Volatile private var pinExpiresAt = 0L
    private var failures = 0
    private var lockMs = LOCK_BASE_MS
    @Volatile private var lockedUntil = 0L
    /** Devam eden denemenin kime yazılacağı (`pair_confirm` anahtarı bu kayda düşer). */
    @Volatile private var attemptClaim: Claim? = null

    init {
        // v1 anahtarı ağdan düz metin giden PIN'den türetiliyordu: ele geçmiş sayılır, yeniden eşleşme gerekir.
        val v1 = File(dir, "session_key.bin")
        if (v1.exists() && v1.delete()) Log.w(TAG, "v1 eşleşme anahtarı silindi; yeniden eşleştirme gerekiyor")
        migrateLegacy()
    }

    // ---- kayıtlar ---------------------------------------------------------------

    /** Uygulama dizinine ağdan gelen bir adı asla olduğu gibi yazmayız: `../` ve ayraç
     *  taşıyan bir `id` başka bir kaydın üzerine yazdırılabilir. Yalnız 16 karakterlik
     *  base64url geçerlidir; gerisi "kimlik yok" muamelesi görür. */
    private fun safeId(raw: String?): String? {
        if (raw == null || raw.length != ID_LENGTH) return null
        return raw.takeIf { s -> s.all { c ->
            c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9' || c == '-' || c == '_' } }
    }

    private fun binOf(stem: String) = File(peersDir, "$stem.bin")
    private fun metaOf(stem: String) = File(peersDir, "$stem.txt")

    /** Eski tek dosyalık kayıt → `legacy` girdisi. Bir kez olur; bozuksa atılır. */
    private fun migrateLegacy() {
        if (!legacyFile.isFile) return
        if (legacyFile.length() != KEY_BYTES) { legacyFile.delete(); return }
        if (binOf(LEGACY_STEM).isFile) { legacyFile.delete(); return }   // zaten taşınmış
        runCatching {
            peersDir.mkdirs()
            legacyFile.copyTo(binOf(LEGACY_STEM))
            legacyFile.delete()
            Log.i(TAG, "eski tek anahtar kaydı tabloya taşındı")
        }
    }

    private fun readPeer(stem: String): Peer? {
        val bin = binOf(stem)
        if (!bin.isFile || bin.length() != KEY_BYTES) return null
        val key = runCatching { bin.readBytes() }.getOrNull() ?: return null
        val meta = runCatching { metaOf(stem).readText().trim() }.getOrDefault("")
        val seen = meta.substringBefore(' ').toLongOrNull() ?: bin.lastModified()
        val name = meta.substringAfter(' ', "").ifBlank { "bilgisayar" }
        return Peer(safeId(stem), key, name, seen)
    }

    private fun stems(): List<String> =
        peersDir.listFiles { f -> f.isFile && f.name.endsWith(".bin") }
            ?.map { it.name.removeSuffix(".bin") }?.distinct()?.sorted() ?: emptyList()

    fun peers(): List<Peer> = stems().mapNotNull(::readPeer)

    val paired: Boolean get() = peers().isNotEmpty()

    /** Tanınmayan bir yayıncının eşleşebilmesi için boş göz var mı (§3.4). */
    val hasFreeSlot: Boolean get() = peers().size < MAX_PEERS

    fun pairedWith(claim: Claim): Boolean =
        peers().any { it.id != null && it.id == safeId(claim.id) } ||
            (claim.id == null && peers().any { it.id == null })

    /** Anahtar deneme sırası: §3.3 — doğrulama iddia edilen kimliğe güvenmez, hepsi sınanır.
     *  Sıra yalnız hız için: TV'nin kendi başlattığı yönde her deneme yeni bağlantı ister. */
    fun sessionPeers(claim: Claim? = null): List<Peer> {
        val want = safeId(claim?.id)
        val wantName = claim?.name?.lowercase()?.takeIf { it.isNotBlank() }
        return peers().sortedWith(
            compareByDescending<Peer> { want != null && it.id == want }
                .thenByDescending { wantName != null && it.name.lowercase() == wantName }
                .thenByDescending { it.lastSeen }
        )
    }

    fun sessionKeys(claim: Claim? = null): List<ByteArray> = sessionPeers(claim).map { it.key }

    /** Doğrulanmış oturumdan sonra çağrılır: düşürme sırası "en az kullanılan" kalsın. */
    @Synchronized
    fun touch(id: String?) {
        val stem = safeId(id) ?: return
        val peer = readPeer(stem) ?: return
        writeMeta(stem, peer.name)
    }

    /** Bir kaydı siler. `id` null = kimlik göndermeyen eski yayıncının kaydı; **hepsi** değil.
     *  Yıkıcı işlemin kapsamı asla ağdan gelen `unpair.id` iddiasından gelmez (§3.3): çağran,
     *  kanıtı doğrulanan kaydın id'sini verir. */
    @Synchronized
    fun remove(id: String?) {
        val stem = safeId(id) ?: LEGACY_STEM
        val gone = binOf(stem).delete()
        metaOf(stem).delete()
        Log.i(TAG, "eşleşme kaydı silindi ($stem): $gone")
    }

    @Synchronized
    fun clearAll() {
        peersDir.listFiles()?.forEach { it.delete() }
        legacyFile.delete()
        pin = null
        Log.i(TAG, "tüm eşleşme kayıtları silindi")
    }

    private fun writeMeta(stem: String, name: String) {
        runCatching { metaOf(stem).writeText("${clock()} ${name.take(64)}") }
    }

    @Synchronized
    private fun saveKey(key: ByteArray, claim: Claim?) {
        peersDir.mkdirs()
        val stem = safeId(claim?.id) ?: LEGACY_STEM
        // Dolu tablo: en eski son-görülme kaydı düşer; yeni eşleşme eskisini engellemesin.
        val existing = peers()
        if (stem != LEGACY_STEM && existing.none { it.id == stem } && existing.size >= MAX_PEERS) {
            val oldest = existing.filter { it.id != null }.minByOrNull { it.lastSeen }
            if (oldest == null) { Log.w(TAG, "tablo dolu ve düşürülebilir kayıt yok"); return }
            binOf(oldest.id!!).delete(); metaOf(oldest.id!!).delete()
            Log.i(TAG, "eşleşme tablosu dolu: ${oldest.name} kaydı düşürüldü")
        }
        // .part uzantısı: yarıda kalan yazım, stems() .bin süzerken kayıt sanılmasın.
        val tmp = File(peersDir, "$stem.part")
        runCatching {
            tmp.writeBytes(key)
            if (!tmp.renameTo(binOf(stem))) { binOf(stem).writeBytes(key); tmp.delete() }
            writeMeta(stem, claim?.name?.takeIf { it.isNotBlank() } ?: "bilgisayar")
        }.onFailure { Log.e(TAG, "eşleşme anahtarı kaydedilemedi: ${it.message}") }
    }

    // ---- PIN ve deneme sayacı ---------------------------------------------------

    @Synchronized
    fun newPin(): String {
        val p = random.nextInt(1_000_000).toString().padStart(Protocol.PIN_LENGTH, '0')
        pin = p
        pinExpiresAt = clock() + Protocol.PIN_TTL_MS
        // Otomatik cihaz testi kodu ekrandan okuyamıyor; yalnız debug derlemesi logcat'e yazar.
        if (BuildConfig.DEBUG) Log.i(TAG, "DEBUG eşleştirme kodu: $p")
        else Log.i(TAG, "yeni eşleştirme kodu üretildi (değer loglanmaz)")
        return p
    }

    val pinAlive: Boolean get() = pin != null && clock() < pinExpiresAt

    /** Ekrandaki kod süresi dolmadıysa aynısı (kullanıcı yazarken değişmesin), yoksa yenisi. */
    @Synchronized
    fun pinOrNew(): String = pin?.takeIf { pinAlive } ?: newPin()

    fun pinSecondsLeft(): Int =
        if (!pinAlive) 0 else maxOf(0, ((pinExpiresAt - clock()) / 1000).toInt())

    fun lockMsLeft(): Long = maxOf(0L, lockedUntil - clock())

    /** Deneme başlatır: ekrandaki kodu bu denemeye ve bu bilgisayara bağlar.
     *  Kilitliyse, geçerli kod yoksa ya da bilgisayar zaten eşleşmişse null. */
    @Synchronized
    fun beginAttempt(claim: Claim? = null): Int? {
        if (lockMsLeft() > 0) return null
        val p = pin?.takeIf { pinAlive } ?: return null
        attemptClaim = claim
        return p.toInt()
    }

    /** Deneme bitti: kod her durumda emekliye ayrılır; başarısızlık sayılır, gerekirse kilitlenir. */
    @Synchronized
    fun endAttempt(key: ByteArray?, claim: Claim? = attemptClaim) {
        pin = null
        attemptClaim = null
        if (key != null) {
            saveKey(key, claim)
            failures = 0
            lockMs = LOCK_BASE_MS
            return
        }
        failures++
        Log.w(TAG, "eşleştirme denemesi başarısız ($failures/$MAX_FAILURES)")
        if (failures >= MAX_FAILURES) {
            lockedUntil = clock() + lockMs
            Log.w(TAG, "eşleştirme ${lockMs / 1000} sn kilitlendi")
            lockMs = minOf(lockMs * 2, LOCK_MAX_MS)
            failures = 0
        }
    }

    fun newNonce(): ByteArray = ByteArray(PairingCrypto.NONCE_BYTES).also { random.nextBytes(it) }

    fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
    /** Bozuk girdi boş dizi döndürür; uzunluk denetimi çağıranda. */
    fun unb64(s: String): ByteArray = try { Base64.getDecoder().decode(s) }
        catch (e: IllegalArgumentException) { ByteArray(0) }
}
