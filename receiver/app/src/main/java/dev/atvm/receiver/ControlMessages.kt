package dev.atvm.receiver

/**
 * Kontrol protokolündeki makine nedenlerini kullanıcının okuyacağı satırın KİMLİĞİNE çeviren
 * saf taraf.
 *
 * Neden ayrı bir dosyada ve Android'den bağımsız: ölçülen kusur (gerçek TV) — Mac, arayüzde pencere
 * seçili olmadığı için TV'nin yayın isteğini `denied / no_window_selected_on_sender` ile reddediyor,
 * TV bunu yalnız logluyordu. Kullanıcı kumandada OK'a basıp hiçbir şey olmadan kalıyordu: red **doğru**
 * bir davranıştı ama nedeni görünmüyordu. Gerekçe → satır eşlemesi burada durunca JVM'de
 * sınanabiliyor (cihaz gerekmeden).
 *
 * Neden satır değil de anahtar: bu dosya `scripts/test-receiver-ui.sh` ile JVM'de, Android çatısı
 * olmadan derleniyor; `R.string`/`Context` buraya giremez. Görünen cümleler iki dilli katalogda
 * (res/values ile res/values-tr, `deny_*` anahtarları). Anahtar → kaynak eşlemesi etkinlikte
 * (`MainActivity.denyRes`) ve `when` önermeli olduğundan çevrilmemiş red satırı derlemeyi durdurur.
 */
object ControlMessages {
    /** Red satırının dilinden bağımsız kimliği. */
    enum class DenyKey { noWindow, notPaired, authFailed, codeUsed, codeExpired,
                         locked, version, protocol, generic, unknown }

    /**
     * Bir red satırı: anahtar + `detail`. `detail` YALNIZ `unknown`da doludur ve Mac'in ham
     * nedenini taşır (uydurulmaz); bilinmeyen neden ekrana `%1$s` ile basılır.
     */
    data class Denial(val key: DenyKey, val detail: String = "")

    /** Mac'in `denied.reason` değeri → ekranda gösterilecek satırın anahtarı. Bilinmeyen neden aynen yazılır. */
    fun denied(reason: String): Denial = when (reason) {
        "no_window_selected_on_sender" -> Denial(DenyKey.noWindow)
        "not_paired" -> Denial(DenyKey.notPaired)
        "auth_failed" -> Denial(DenyKey.authFailed)
        "already_paired" -> Denial(DenyKey.codeUsed)
        "pin_expired" -> Denial(DenyKey.codeExpired)
        "locked" -> Denial(DenyKey.locked)
        "version" -> Denial(DenyKey.version)
        "bad_json", "unexpected_message" -> Denial(DenyKey.protocol)
        else -> if (reason.isBlank() || reason == "?") Denial(DenyKey.generic)
                else Denial(DenyKey.unknown, reason)
    }

    /** Bu red, kullanıcının bir şey yapmasını gerektiriyor mu? (kırmızı tonlama için) */
    fun deniedNeedsAction(reason: String): Boolean = reason != "locked"
}
