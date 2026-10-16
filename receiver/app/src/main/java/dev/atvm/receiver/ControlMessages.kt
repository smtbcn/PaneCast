package dev.atvm.receiver

/**
 * Kontrol protokolündeki makine nedenlerini kullanıcının okuyacağı tek satıra çeviren saf taraf.
 *
 * Neden ayrı bir dosyada ve Android'den bağımsız: ölçülen kusur (gerçek TV) — Mac, arayüzde pencere
 * seçili olmadığı için TV'nin yayın isteğini `denied / no_window_selected_on_sender` ile reddediyor,
 * TV bunu yalnız logluyordu. Kullanıcı kumandada OK'a basıp hiçbir şey olmadan kalıyordu: red **doğru**
 * bir davranıştı ama nedeni görünmüyordu. Metin burada durunca JVM'de sınanabiliyor.
 */
object ControlMessages {
    /** Mac'in `denied.reason` değeri → ekranda gösterilecek satır. Bilinmeyen neden aynen yazılır. */
    fun deniedText(reason: String): String = when (reason) {
        "no_window_selected_on_sender" ->
            "Mac'te yayınlanacak pencere seçili değil — Mac arayüzünden bir pencere seç, sonra OK"
        "not_paired" -> "Mac bu TV ile eşleşmiş saymıyor — TV'deki kodu Mac'e yeniden girin"
        "auth_failed" -> "Mac eşleşme anahtarını doğrulayamadı — eşleştirmeyi silip yeniden eşleşin"
        "already_paired" -> "Bu kod daha önce kullanıldı — OK ile yeni kod alın"
        "pin_expired" -> "Kodun süresi doldu — OK ile yeni kod alın"
        "locked" -> "Çok fazla hatalı deneme — biraz bekleyip yeniden deneyin"
        "version" -> "Mac ile sürümler uyumsuz — iki tarafı da güncelleyin"
        "bad_json", "unexpected_message" -> "Mac beklenmeyen bir yanıt aldı — yayını yeniden deneyin"
        else -> if (reason.isBlank() || reason == "?") "Mac isteği reddetti" else "Mac reddetti: $reason"
    }

    /** Bu red, kullanıcının bir şey yapmasını gerektiriyor mu? (kırmızı tonlama için) */
    fun deniedNeedsAction(reason: String): Boolean = reason != "locked"
}
