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
    //    Hücrelerin FİİLİ artık anahtar (`HintKey`): görünen cümle iki dilli katalogda
    //    (res/values ile res/values-tr), JVM tarafında ölçülebileni anahtarın kimliği ve hücre sayısı.
    val ready = RemoteKeys.hints(RemoteKeys.Screen.READY, hasComputers = true)
    check("hazır rehberi boş değil", ready.isNotEmpty())
    check("hazır rehberde OK var", ready.any { it.key == "OK" && it.action == RemoteKeys.HintKey.okStart })
    check("arama tek kez ve kısa", ready.count { it.key == "SEARCH" } <= 1)
    // Ölçülen tasarım kuralı: nadir bir işlem (eşleşme silme) şeritte hiç bağırmamalı.
    // Eskiden "sil" sözcüğü aranuyordu; sözcük kataloga taşındığı için artık anahtar aranıyor.
    check("eşleşme silme rehberi bağırmıyor",
          ready.none { it.action.name.contains("unpair", ignoreCase = true) })
    // Şerit TEK SIRA: hücre sayısı dilinden bağımsız üst sınır (yazı uzunluğu artık katalogda,
    // iki dilin en uzun satırı res/values ile res/values-tr karşılaştırmasında ölçülüyor).
    check("rehber tek satıra sığacak kadar kısa",
          RemoteKeys.hints(RemoteKeys.Screen.READY, true).size <= 4 &&
          RemoteKeys.hintsLine(RemoteKeys.Screen.READY, true).length < 80)
    check("Mac yoksa OK yerine arama önerilir",
          RemoteKeys.hints(RemoteKeys.Screen.READY, hasComputers = false).none { it.key == "OK" })
    check("yayında rehberde durdur + ölçüm var",
          RemoteKeys.hints(RemoteKeys.Screen.STREAMING, true).map { it.key } == listOf("BACK", "MENU", "◀ ▶"))
    check("PIN ekranı kısa", RemoteKeys.hints(RemoteKeys.Screen.PAIRING, false).size == 2)
    check("çift kayıt yok", ready.size == ready.map { it.key + it.action }.distinct().size)
    check("bilinmeyen tuş UNKNOWN", cmd(999) == RemoteKeys.Command.UNKNOWN)
    // Her `HintKey` gerçekten bir ekran tarafından üretilmeli (katalogda ölü satır kalmasın) ve
    // üretilen her anahtarın görünen yazısı `TvScreen.stringResOf`daki önermeli `when`te duruyor:
    // Kotlin önermeli enum `when`inde eksik dal DERLEMEYİ durdurur, yani "çevrilmemiş ipucu"
    // burada koşarken değil, derlerken yakalanır — bunu taklit eden bir runtime denetim yazılmadı.
    val producedHints = buildSet {
        for (s in RemoteKeys.Screen.values())
            for (has in listOf(true, false)) addAll(RemoteKeys.hints(s, has).map { it.action })
    }
    check("ipucu anahtarları tükenmiş: üretilen küme = HintKey",
          producedHints == RemoteKeys.HintKey.values().toSet())

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
    //    kullanıcı OK'a basıp boş ekranda bekliyordu. Satırın yazısı katalogda (`deny_*`),
    //    burada ayırt edilen GEREKÇE → ANAHTAR eşlemesinin kendisi.
    val reasons = listOf("no_window_selected_on_sender", "not_paired", "auth_failed", "already_paired",
                         "pin_expired", "locked", "version")
    val keys = reasons.map { ControlMessages.denied(it).key }
    val allReasons = reasons + listOf("bad_json", "unexpected_message")
    check("her bilinen gerekçe kendi satırını alıyor",
          allReasons.map { ControlMessages.denied(it).key }
              .none { it == ControlMessages.DenyKey.unknown || it == ControlMessages.DenyKey.generic })
    check("anlamı farklı gerekçeler aynı satıra düşmüyor", keys.distinct().size == reasons.size)
    check("protokol hataları tek satırda birleşiyor (bilinçli)",
          ControlMessages.denied("bad_json") == ControlMessages.denied("unexpected_message"))
    // "çözümü de söylüyor" artık cümlenin özelliği: deny_no_window iki dilde de çözüm fiilini
    // taşıyor (katalog denetimi). Burada ayırt edilen, uyarının KENDİ anahtarına düşmesi —
    // anahtar düşerse satır da yanlış okunur.
    check("pencere seçili değil uyarısı çözümü de söylüyor",
          ControlMessages.denied("no_window_selected_on_sender").key == ControlMessages.DenyKey.noWindow)
    check("bilinmeyen gerekçe uydurulmuyor, aynen yazılır",
          ControlMessages.denied("kotu_bir_sey") ==
              ControlMessages.Denial(ControlMessages.DenyKey.unknown, "kotu_bir_sey"))
    check("boş gerekçe çökmez", ControlMessages.denied("").key == ControlMessages.DenyKey.generic
            && ControlMessages.denied("?").key == ControlMessages.DenyKey.generic)
    // Tek satır sınırı: Mac'ten gelen ham neden olduğu gibi ekrana basıldığı için içinde
    // satır sonu bulunamaz (cümle uzunluğu artık katalogda denetleniyor).
    check("tek satıra sığar", (allReasons + listOf("kotu_bir_sey", "")).map { ControlMessages.denied(it).detail }
            .all { !it.contains("\n") })
    check("bekleme cezası kırmızı değil", !ControlMessages.deniedNeedsAction("locked"))
    check("pencere seçimi kırmızı", ControlMessages.deniedNeedsAction("no_window_selected_on_sender"))
    // Her `DenyKey` bir yoldan üretilebiliyor (katalogda ölü satır yok); anahtar → kaynak
    // eşlemesi `MainActivity.denyRes`deki önermeli `when`te ve eksik dal derlemeyi durdurur —
    // önermelliliği taklit eden bir runtime denetim bilinçli olarak yazılmadı.
    val producedDenials = (allReasons + listOf("", "?", "kotu_bir_sey"))
        .map { ControlMessages.denied(it).key }.toSet()
    check("red anahtarları tükenmiş: üretilen küme = DenyKey",
          producedDenials == ControlMessages.DenyKey.values().toSet())

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

    // Yeğlenen adres: eşleşme yoklamasında TV'ye ulaşan paketin kaynağı. Çok arayüzlü Mac'te
    // mDNS A kaydı TV ile aynı /24'te olan ama ulaşılabilir OLMAYAN adresi verebiliyor
    // (ölçüldü: en0 .67 ulaşılabilir, en1 .112 %100 kayıp) — ağ-önceliği kuralı bu ikisini
    // ayırt edemez, yüzden kaynak adres açıkça öne konmalı.
    val sameNet = listOf("198.51.100.99")
    check("yeğlenen adres aynı /24'teki ulaşılamaz adayın önüne geçer",
          SenderAddresses.order(listOf("198.51.100.67", "198.51.100.5"), sameNet,
                                preferred = "198.51.100.5")
              == listOf("198.51.100.5", "198.51.100.67"))
    check("yeğlenen adres listede zaten varsa tekilleşir",
          SenderAddresses.order(listOf("198.51.100.5", "192.0.2.7"), sameNet,
                                preferred = "198.51.100.5")
              == listOf("198.51.100.5", "192.0.2.7"))
    check("yeğlenen yoksa ağ-önceliği kuralı aynen çalışıyor",
          SenderAddresses.order(listOf("192.0.2.5", "198.51.100.67"), sameNet, preferred = null)
              == listOf("198.51.100.67", "192.0.2.5"))
    check("boş yeğlenen elemeyle düşer, sırayı bozmaz",
          SenderAddresses.order(listOf("192.0.2.5", "198.51.100.67"), sameNet, preferred = "")
              == listOf("198.51.100.67", "192.0.2.5"))

    println(if (failures == 0) "TAMAM: $checks denetim geçti" else "$failures/$checks denetim başarısız")
    if (failures > 0) kotlin.system.exitProcess(1)
}
