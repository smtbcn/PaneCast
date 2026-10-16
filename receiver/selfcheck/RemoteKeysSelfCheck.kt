package dev.atvm.receiver

// RemoteKeys'in JVM öz-denetimi (JUnit yok; scripts/test-receiver-ui.sh koşar).
//
// Kanıtlanan iki şey: (1) TV kumandalarının gönderdiği TÜM eşdeğer kodlar aynı anlama
// düşüyor, (2) tuş tekrarında eylem bir daha tetiklenmiyor, (3) ses/kanal tuşlarına
// el konmuyor, (4) alt rehber duruma göre tek sıra ve kısa üretiliyor.

private var failures = 0
private var checks = 0

private fun check(name: String, ok: Boolean) {
    checks++
    if (!ok) { failures++; println("BAŞARISIZ: $name") }
}

private fun cmd(k: Int, repeat: Int = 0, long: Boolean = false) = RemoteKeys.command(k, repeat, long)

fun main() {
    // 1) "Seç" tek koda bağlı değildi; kumandalar farklı kod gönderiyor.
    for (k in listOf(RemoteKeys.KEY_DPAD_CENTER, RemoteKeys.KEY_ENTER, RemoteKeys.KEY_NUM_ENTER,
                     RemoteKeys.KEY_SPACE, RemoteKeys.KEY_BUTTON_A, RemoteKeys.KEY_BUTTON_SELECT)) {
        check("seç kodu $k → SELECT", cmd(k) == RemoteKeys.Command.SELECT)
    }
    // 2) "Geri" de üç kaynaktan gelir; basılı tutma ayrı anlama düşer.
    for (k in listOf(RemoteKeys.KEY_BACK, RemoteKeys.KEY_ESCAPE, RemoteKeys.KEY_BUTTON_B)) {
        check("geri kodu $k → BACK", cmd(k) == RemoteKeys.Command.BACK)
        check("basılı $k → BACK", cmd(k, long = true) == RemoteKeys.Command.BACK)
    }
    // 3) Ayrıntı: Android TV'de INFO'dur; MENU ayar katmanını açar.
    check("INFO → DETAIL", cmd(RemoteKeys.KEY_INFO) == RemoteKeys.Command.DETAIL)
    check("MENU → MENU", cmd(RemoteKeys.KEY_MENU) == RemoteKeys.Command.MENU)
    check("SEARCH → SEARCH", cmd(RemoteKeys.KEY_SEARCH) == RemoteKeys.Command.SEARCH)
    check("medya ▶⏸ → PLAY_PAUSE", cmd(RemoteKeys.KEY_MEDIA_PLAY_PAUSE) == RemoteKeys.Command.PLAY_PAUSE)
    check("medya ⏹ → STOP", cmd(RemoteKeys.KEY_MEDIA_STOP) == RemoteKeys.Command.STOP)

    // 4) Ses/kanal/güç/kaynak: sistem tüketmeli; biz PASS deriz.
    for (k in listOf(RemoteKeys.KEY_VOLUME_UP, RemoteKeys.KEY_VOLUME_DOWN, RemoteKeys.KEY_VOLUME_MUTE,
                     RemoteKeys.KEY_POWER, RemoteKeys.KEY_CHANNEL_UP, RemoteKeys.KEY_CHANNEL_DOWN,
                     RemoteKeys.KEY_STB_INPUT, RemoteKeys.KEY_TV_INPUT_HDMI_1)) {
        check("sisteme ait $k → PASS", cmd(k) == RemoteKeys.Command.PASS)
    }

    // 5) Odak gezinme framework'e bırakılır ama tekrar EDİLEBİLİR olmalı (basılı tut → dolaş).
    check("◀ yinelemeli gezinme", cmd(RemoteKeys.KEY_DPAD_LEFT, repeat = 4) == RemoteKeys.Command.NAV_LEFT)
    check("▲▼◀▶ gezinme sayılır", RemoteKeys.isNavigation(RemoteKeys.Command.NAV_DOWN))
    check("SELECT gezinme değildir", !RemoteKeys.isNavigation(RemoteKeys.Command.SELECT))

    // 6) Tekrar koruması: basılı tutulan OK iki kez yayın başlatamaz.
    for (k in listOf(RemoteKeys.KEY_DPAD_CENTER, RemoteKeys.KEY_ENTER, RemoteKeys.KEY_SEARCH,
                     RemoteKeys.KEY_MENU, RemoteKeys.KEY_BACK)) {
        check("tekrarda eylem yok ($k)", cmd(k, repeat = 1) == RemoteKeys.Command.PASS)
    }

    // 7) Rehber: tek sıra, kısa, duruma göre farklı; bilinmeyen tuş UNKNOWN.
    val ready = RemoteKeys.hints(RemoteKeys.Screen.READY, hasComputers = true)
    check("hazır rehberi boş değil", ready.isNotEmpty())
    check("hazır rehberde OK var", ready.any { it.key == "OK" && it.action == "yayın başlat" })
    check("arama tek kez ve kısa", ready.count { it.key == "SEARCH" } <= 1)
    check("eşleşme silme rehberi bağırmıyor", ready.none { it.action.contains("sil") })
    check("rehber tek satıra sığacak kadar kısa",
          RemoteKeys.hintsLine(RemoteKeys.Screen.READY, true).length < 80)
    check("Mac yoksa OK yerine arama önerilir",
          RemoteKeys.hints(RemoteKeys.Screen.READY, hasComputers = false).none { it.key == "OK" })
    check("yayında rehberde durdur + ölçüm var",
          RemoteKeys.hints(RemoteKeys.Screen.STREAMING, true).map { it.key } == listOf("BACK", "MENU", "◀ ▶"))
    check("PIN ekranı kısa", RemoteKeys.hints(RemoteKeys.Screen.PAIRING, false).size == 2)
    check("çift kayıt yok", ready.size == ready.map { it.key + it.action }.distinct().size)
    check("bilinmeyen tuş UNKNOWN", cmd(999) == RemoteKeys.Command.UNKNOWN)

    // 5) BACK karar makinesi — gerçek cihazda ölçülen kusurun kilidi: ACTION_UP tüketilip
    //    onKeyUp'a bırakıldığı için kumandadan durdur/çık hiç koşmuyordu.
    val D = RemoteKeys.Phase.DOWN
    val U = RemoteKeys.Phase.UP
    val STOP = RemoteKeys.BackAction.STOP_STREAM
    val EXIT = RemoteKeys.BackAction.EXIT
    val TRACK = RemoteKeys.BackAction.START_TRACKING
    val DIALOG = RemoteKeys.BackAction.UNPAIR_DIALOG
    val SYSTEM = RemoteKeys.BackAction.TO_SYSTEM
    val SWALLOW = RemoteKeys.BackAction.SWALLOW
    fun back(phase: RemoteKeys.Phase, long: Boolean = false, streaming: Boolean = false,
             paired: Boolean = true, dialog: Boolean = false) =
        RemoteKeys.backAction(phase, long, streaming, paired, dialog)

    check("yayında kısa DOWN yalnız izlenir", back(D, streaming = true) == TRACK)
    check("yayında kısa UP yayını durdurur", back(U, streaming = true) == STOP)
    check("yayında değilken UP ekrandan çıkarır", back(U, streaming = false) == EXIT)
    check("basılı tutma UP kararı vermez", back(U, long = true, streaming = true) == SWALLOW)
    check("basılı tutma DOWN onay sorar", back(D, long = true) == DIALOG)
    check("eşleşme yokken basılı tutma onay sormaz",
          back(D, long = true, paired = false) == TRACK)
    check("yayında basılı tutma onay sormaz",
          back(D, long = true, streaming = true) == TRACK)
    check("diyalog açıkken tuş diyalogundur (DOWN)", back(D, dialog = true) == SYSTEM)
    check("diyalog açıkken tuş diyalogundur (UP)", back(U, dialog = true) == SYSTEM)
    check("UP asla yutulmaz: durdur/çık ikilisinden biri",
          setOf(back(U, streaming = true), back(U, streaming = false)) == setOf(STOP, EXIT))

    // 6) Mac'in red gerekçeleri ekranda okunur: ölçülen kusur — red yalnız loglanıyordu,
    //    kullanıcı OK'a basıp boş ekranda bekliyordu.
    val reasons = listOf("no_window_selected_on_sender", "not_paired", "auth_failed", "already_paired",
                         "pin_expired", "locked", "version")
    val texts = reasons.map { ControlMessages.deniedText(it) }
    val allReasons = reasons + listOf("bad_json", "unexpected_message")
    check("her bilinen gerekçe metin alıyor", allReasons.map { ControlMessages.deniedText(it) }.none { it.isBlank() })
    check("anlamı farklı gerekçeler aynı satıra düşmüyor", texts.distinct().size == reasons.size)
    check("protokol hataları tek satırda birleşiyor (bilinçli)",
          ControlMessages.deniedText("bad_json") == ControlMessages.deniedText("unexpected_message"))
    check("pencere seçili değil uyarısı çözümü de söylüyor",
          ControlMessages.deniedText("no_window_selected_on_sender").contains("pencere seç"))
    check("bilinmeyen gerekçe uydurulmuyor, aynen yazılır",
          ControlMessages.deniedText("kotu_bir_sey") == "Mac reddetti: kotu_bir_sey")
    check("boş gerekçe çökmez", ControlMessages.deniedText("") == "Mac isteği reddetti"
            && ControlMessages.deniedText("?") == "Mac isteği reddetti")
    check("tek satıra sığar", allReasons.map { ControlMessages.deniedText(it) }
            .all { it.length <= 90 && !it.contains("\n") })
    check("bekleme cezası kırmızı değil", !ControlMessages.deniedNeedsAction("locked"))
    check("pencere seçimi kırmızı", ControlMessages.deniedNeedsAction("no_window_selected_on_sender"))

    // 7) mDNS çok adres döndürünce doğru aday önce denenmeli (ölçülen kusur: TV, Mac'in
    //    sanal makine köprüsüne bağlanmaya çalıştı ve OK hiçbir şey yapmıyordu).
    //    Süsleme adresleri RFC 5737 belge aralığından: gerçek ağ değerleri depoya giremez.
    val tv = listOf("198.51.100.50")
    check("aynı ağdaki aday önce",
          SenderAddresses.order(listOf("192.0.2.5", "198.51.100.67"), tv)
              == listOf("198.51.100.67", "192.0.2.5"))
    check("tek aday korundu", SenderAddresses.order(listOf("203.0.113.9"), tv) == listOf("203.0.113.9"))
    check("yinelenen adres düşer",
          SenderAddresses.order(listOf("198.51.100.67", "198.51.100.67"), tv).size == 1)
    check("çöp değerler listeye girmiyor",
          SenderAddresses.order(listOf("", "0.0.0.0", "fe80::1", "198.51.100.67"), tv)
              == listOf("198.51.100.67"))
    check("TV adresi yoksa sıra bozulmuyor",
          SenderAddresses.order(listOf("b", "a"), emptyList()) == listOf("b", "a"))
    check("boş liste boş döner", SenderAddresses.order(emptyList(), tv).isEmpty())
    // 7b) Ad çözümlemesi aday listesini genişletir; başarısız olursa tek adrese düşer.
    check("adın tüm adresleri adaya ekleniyor",
          SenderAddresses.expand("192.0.2.5") { listOf("198.51.100.67", "192.0.2.5") }
              == listOf("192.0.2.5", "198.51.100.67"))
    check("çözümleme patlarsa mevcut adres korunuyor",
          SenderAddresses.expand("198.51.100.67") { throw java.net.UnknownHostException("yok") }
              == listOf("198.51.100.67"))
    check("genişletme + sıralama birlikte: aynı ağ kazanıyor",
          SenderAddresses.order(SenderAddresses.expand("192.0.2.5") {
              listOf("198.51.100.67", "192.0.2.5") }, tv) == listOf("198.51.100.67", "192.0.2.5"))
    check("boş adres aday üretmez", SenderAddresses.expand("") { listOf("x") }.isEmpty())

    println(if (failures == 0) "TAMAM: $checks denetim geçti" else "$failures/$checks denetim başarısız")
    if (failures > 0) kotlin.system.exitProcess(1)
}
