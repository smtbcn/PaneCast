package dev.atvm.receiver

import android.util.Log
import java.io.File
import java.security.SecureRandom
import java.util.Base64

/** TV tarafı eşleştirme durumu: ekrandaki 6 haneli kod, deneme sınırı ve eşleşme anahtarı.
 *  Kod her denemeden sonra (başarılı ya da değil) yenilenir; ardışık MAX_FAILURES başarısız
 *  deneme kilit açar (30 sn, her yeni kilitte iki katı, en çok LOCK_MAX_MS).
 *  Anahtar uygulamaya özel dizinde (filesDir, yalnız bu uygulamanın UID'si okur; allowBackup=false). */
class Pairing(dir: File, private val clock: () -> Long = System::currentTimeMillis) {
    companion object {
        private const val TAG = "ATVM-Pairing"
        const val MAX_FAILURES = 3
        const val LOCK_BASE_MS = 30_000L
        const val LOCK_MAX_MS = 480_000L
    }

    private val keyFile = File(dir, "pair_key_v2.bin")
    val random = SecureRandom()

    @Volatile var pin: String? = null
        private set
    @Volatile private var pinExpiresAt = 0L
    private var failures = 0
    private var lockMs = LOCK_BASE_MS
    @Volatile private var lockedUntil = 0L

    init {
        // v1 anahtarı ağdan düz metin giden PIN'den türetiliyordu: ele geçmiş sayılır, yeniden eşleşme gerekir.
        val legacy = File(dir, "session_key.bin")
        if (legacy.exists() && legacy.delete()) Log.w(TAG, "v1 eşleşme anahtarı silindi; yeniden eşleştirme gerekiyor")
    }

    val paired: Boolean get() = keyFile.isFile && keyFile.length() == 32L

    fun storedSessionKey(): ByteArray? = if (paired) keyFile.readBytes() else null

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

    /** Deneme başlatır: ekrandaki kodu bu denemeye bağlar. Kilitliyse ya da geçerli kod yoksa null. */
    @Synchronized
    fun beginAttempt(): Int? {
        if (lockMsLeft() > 0) return null
        val p = pin?.takeIf { pinAlive } ?: return null
        return p.toInt()
    }

    /** Deneme bitti: kod her durumda emekliye ayrılır; başarısızlık sayılır, gerekirse kilitlenir. */
    @Synchronized
    fun endAttempt(key: ByteArray?) {
        pin = null
        if (key != null) {
            saveKey(key)
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

    private fun saveKey(key: ByteArray) {
        val tmp = File(keyFile.parentFile, keyFile.name + ".tmp")
        tmp.writeBytes(key)
        if (!tmp.renameTo(keyFile)) { keyFile.writeBytes(key); tmp.delete() }
        Log.i(TAG, "eşleşme anahtarı uygulamaya özel dizine kaydedildi")
    }

    fun newNonce(): ByteArray = ByteArray(PairingCrypto.NONCE_BYTES).also { random.nextBytes(it) }

    @Synchronized
    fun clear() {
        keyFile.delete()
        pin = null
    }

    fun b64(bytes: ByteArray): String = Base64.getEncoder().encodeToString(bytes)
    /** Bozuk girdi boş dizi döndürür; uzunluk denetimi çağıranda. */
    fun unb64(s: String): ByteArray = try { Base64.getDecoder().decode(s) } catch (e: IllegalArgumentException) { ByteArray(0) }
}
