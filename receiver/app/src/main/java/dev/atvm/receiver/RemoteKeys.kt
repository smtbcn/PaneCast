package dev.atvm.receiver

/**
 * Kumanda girdisinin tek kaynağı: bir `KeyEvent` verisini uygulamaya anlamına çevirir.
 *
 * Neden tablo hâlinde ve Android'den bağımsız (saf Kotlin)?
 * 1. TV kumandaları aynı iş için farklı kodlar gönderiyor (BLE/RF/IR/CEC/oyun kolu):
 *    "seç" demek DPAD_CENTER da olabilir ENTER, NUM_ENTER, SPACE veya BUTTON_A da.
 *    Tek koda bakmak, o kumandalarda tuşun ölü kalması demekti — "kafamıza göre" olan buydu.
 * 2. Sınıflandırma saf olduğu için JVM'de sınanabiliyor (cihaz, emülatör, ekran gerekmiyor).
 * 3. Aynı nedenlerle burada hiç görünen metin yok: ekrana yazılan her satır iki dilli katalogda
 *    (res/values ile res/values-tr) duruyor, bu dosya yalnız metnin ANAHTARINI üretiyor.
 *
 * Sabitler `android.view.KeyEvent` ile birebir aynıdır; yorumda karşılığı yazılıdır.
 * Framework'e ait olması gereken tuşlara (ses, kanal, güç) HİÇBİR zaman el konmaz:
 * `Command.PASS` döner ve olay sistem tarafından tüketilir.
 */
object RemoteKeys {
    // android.view.KeyEvent sabitlerinin karşılıkları.
    const val KEY_BACK = 4
    const val KEY_DPAD_UP = 19
    const val KEY_DPAD_DOWN = 20
    const val KEY_DPAD_LEFT = 21
    const val KEY_DPAD_RIGHT = 22
    const val KEY_DPAD_CENTER = 23
    const val KEY_VOLUME_UP = 24
    const val KEY_VOLUME_DOWN = 25
    const val KEY_POWER = 26
    const val KEY_MENU = 82
    const val KEY_SEARCH = 84
    const val KEY_MEDIA_PREVIOUS = 88
    const val KEY_MEDIA_NEXT = 87
    const val KEY_MEDIA_PLAY_PAUSE = 126
    const val KEY_MEDIA_STOP = 127
    const val KEY_ENTER = 66
    const val KEY_SPACE = 62
    const val KEY_ESCAPE = 111
    const val KEY_VOLUME_MUTE = 164
    const val KEY_INFO = 165
    const val KEY_CHANNEL_UP = 192
    const val KEY_CHANNEL_DOWN = 193
    const val KEY_NUM_ENTER = 160
    const val KEY_BUTTON_A = 96
    const val KEY_BUTTON_B = 97
    const val KEY_BUTTON_X = 99
    const val KEY_BUTTON_Y = 100
    const val KEY_BUTTON_SELECT = 109
    const val KEY_BUTTON_START = 108
    const val KEY_GAMEPAD_DPAD_UP = 409
    const val KEY_GAMEPAD_DPAD_DOWN = 410
    const val KEY_GAMEPAD_DPAD_LEFT = 411
    const val KEY_GAMEPAD_DPAD_RIGHT = 412
    const val KEY_STB_INPUT = 178            // HDMI/CEC kaynak seçimi: sisteme bırakılır
    const val KEY_TV_INPUT_HDMI_1 = 243      // CEC: sisteme bırakılır

    /** Bir tuşun uygulama anlamı. `PASS` = bize ait değil, sisteme bırak. */
    enum class Command {
        SELECT, BACK, MENU, DETAIL, SEARCH,
        NAV_UP, NAV_DOWN, NAV_LEFT, NAV_RIGHT,
        PLAY_PAUSE, STOP, SKIP_NEXT, SKIP_PREVIOUS,
        PASS, UNKNOWN
    }

    /**
     * Tuşu anlama çevirir.
     *
     * `repeatCount` koruması: TV kumandalarında tuş basılı tutulunca olay tekrarlanır.
     * Odak gezinme (NAV_*) için tekrar istenir — kullanıcı ok tuşunu basılı tutup
     * listede dolaşabilir. Eylem tuşlarında (SELECT/SEARCH/MENU/…) ise tekrar TEHLİKELİDİR:
     * tek "yayını başlat" iki kez tetiklenir, eşleşme silme onayı kendiliğinden basılır.
     * Bu yüzden eylemler yalnız `repeatCount == 0` iken döner, aksi hâlde PASS.
     */
    fun command(keyCode: Int, repeatCount: Int = 0, longPress: Boolean = false): Command {
        val discrete = repeatCount == 0
        return when (keyCode) {
            KEY_DPAD_CENTER, KEY_ENTER, KEY_NUM_ENTER, KEY_SPACE,
            KEY_BUTTON_A, KEY_BUTTON_SELECT -> if (discrete) Command.SELECT else Command.PASS

            KEY_BACK, KEY_ESCAPE, KEY_BUTTON_B ->
                if (longPress) Command.BACK else if (discrete) Command.BACK else Command.PASS

            KEY_MENU -> if (discrete) Command.MENU else Command.PASS
            KEY_INFO, KEY_BUTTON_Y -> if (discrete) Command.DETAIL else Command.PASS
            KEY_SEARCH, KEY_BUTTON_X -> if (discrete) Command.SEARCH else Command.PASS

            KEY_DPAD_UP, KEY_GAMEPAD_DPAD_UP -> Command.NAV_UP
            KEY_DPAD_DOWN, KEY_GAMEPAD_DPAD_DOWN -> Command.NAV_DOWN
            KEY_DPAD_LEFT, KEY_GAMEPAD_DPAD_LEFT -> Command.NAV_LEFT
            KEY_DPAD_RIGHT, KEY_GAMEPAD_DPAD_RIGHT -> Command.NAV_RIGHT

            KEY_MEDIA_PLAY_PAUSE -> if (discrete) Command.PLAY_PAUSE else Command.PASS
            KEY_MEDIA_STOP -> if (discrete) Command.STOP else Command.PASS
            KEY_MEDIA_NEXT -> if (discrete) Command.SKIP_NEXT else Command.PASS
            KEY_MEDIA_PREVIOUS -> if (discrete) Command.SKIP_PREVIOUS else Command.PASS

            // Ses / kanal / güç / kaynak: TV'nin kendi işi. El koymak, kumandanın
            // ses tuşlarını uygulamada ölü bırakırdı.
            KEY_VOLUME_UP, KEY_VOLUME_DOWN, KEY_VOLUME_MUTE, KEY_POWER,
            KEY_CHANNEL_UP, KEY_CHANNEL_DOWN, KEY_STB_INPUT, KEY_TV_INPUT_HDMI_1 -> Command.PASS

            else -> Command.UNKNOWN
        }
    }

    /** Odak gezinme framework'e bırakılır: kendi tuş yolumuz yok, listede duran öğe gider. */
    fun isNavigation(command: Command): Boolean = when (command) {
        Command.NAV_UP, Command.NAV_DOWN, Command.NAV_LEFT, Command.NAV_RIGHT -> true
        else -> false
    }

    // ---- BACK'in karar makinesi ----

    /** Olayın dönemi: basma / bırakma. */
    enum class Phase { DOWN, UP }

    /** BACK tuşunun yapılabilir tek karşılığı. `SWALLOW` = olay tüketildi, eylem yok. */
    enum class BackAction { TO_SYSTEM, START_TRACKING, UNPAIR_DIALOG, STOP_STREAM, EXIT, SWALLOW }

    /**
     * BACK kararının TEK kaynağı. Neden MainActivity'nin içinde değil de burada:
     * ölçülen kusur (gerçek Vestel TV, 0.2.4) — `dispatchKeyEvent`, ACTION_UP olayını
     * kendisi tüketip `return true` diyordu; bu yüzden `onKeyUp` hiç koşmuyordu ve
     * kumandadan **yayını durdur / ekrandan çık** çalışmıyordu. Karar saf olunca bu
     * sınıf hata JVM'de yakalanabiliyor.
     *
     * Kurallar: onay diyaloğu açıksa tuş diyalogundur; uzun basış kararı DOWN'da verilir
     * (eşleşme silme onayı), UP yalnız yutulur; kısa UP yayında ise yayını durdurur,
     * değilse ekrandan çıkarır (onDestroy kaynakları serbest bırakır).
     */
    fun backAction(phase: Phase, longPress: Boolean, streaming: Boolean,
                   paired: Boolean, dialogOpen: Boolean): BackAction {
        if (dialogOpen) return BackAction.TO_SYSTEM
        return when (phase) {
            Phase.DOWN -> when {
                longPress && !streaming && paired -> BackAction.UNPAIR_DIALOG
                else -> BackAction.START_TRACKING          // startTracking() + tüket
            }
            Phase.UP -> when {
                longPress -> BackAction.SWALLOW            // karar DOWN'da verildi
                streaming -> BackAction.STOP_STREAM
                else -> BackAction.EXIT
            }
        }
    }

    // ---- alt rehber (tek sıra, kısa) ----

    /** Ekranda hangi durumun geçerli olduğu; rehber bundan üretilir, elle yazılmaz. */
    enum class Screen { PAIRING, READY, STREAMING }

    /**
     * Bir rehber hücresinin FİİLİNİN kimliği. Yazı burada durmuyor: bu dosya JVM'de, Android
     * çatısı olmadan derlenip sınanıyor (`scripts/test-receiver-ui.sh`) ve `R.string`/`Context`
     * taşıyamaz. Görünen satır `values`/`values-tr` kataloglarındaki `hint_*` anahtarlarındadır;
     * anahtar → kaynak eşlemesi görünümde (`TvScreen.stringResOf`) ve `when` önermeli olduğu için
     * çevrilmemiş ipucu derlemeyi durdurur.
     */
    enum class HintKey { okNewCode, okStart, backExit, backStop, lrSelect, lrSync,
                         menuDetail, menuStats, searchMac }

    /** Bir rehber hücresi: tuş etiketi + fiilin anahtarı. Metin kısa tutulur (kullanıcı isteği).
     *  `key` çevrilmez: kumandanın üstündeki harf, yani veri. */
    data class Hint(val key: String, val action: HintKey)

    /**
     * Alt şeridin tek sırası. Uzun cümle yok: kumanda tuşunun ADI ve tek fiil.
     *
     * Ölçülen kusur: eski şerit "OK: bilgisayarı seç ve yayını başlat · SEARCH: yeniden tara ·
     * BACK: çık (basılı tut: eşleştirmeyi sil)" gibi üç satıra taşan bir paragraftı ve
     * nadir bir işlem (eşleşme silme) her zaman bağırıyordu. Eşleşme silme artık
     * MENU'nun açtığı ayrıntı katmanında duruyor; BACK basılı tutulunca çalışmaya devam eder.
     */
    fun hints(screen: Screen, hasComputers: Boolean): List<Hint> = when (screen) {
        Screen.PAIRING -> listOf(
            Hint("OK", HintKey.okNewCode),
            Hint("BACK", HintKey.backExit),
        )
        Screen.READY -> buildList {
            if (hasComputers) {
                add(Hint("OK", HintKey.okStart))
                add(Hint("◀▶", HintKey.lrSelect))
            } else {
                add(Hint("SEARCH", HintKey.searchMac))
            }
            add(Hint("MENU", HintKey.menuDetail))
            add(Hint("BACK", HintKey.backExit))
        }.distinctBy { it.key + it.action }
        Screen.STREAMING -> listOf(
            Hint("BACK", HintKey.backStop),
            Hint("MENU", HintKey.menuStats),
            Hint("◀ ▶", HintKey.lrSync),
        )
    }

    /**
     * Rehberin KİMLİK satırı (görünüme çizilen metin değil): TvScreen şeridin değişip
     * değişmediğini bundan anlıyor. Dile bağlı yazı taşımadığı için iki dilde de aynı
     * kareyi verir — çeviriler için uzunluk sınırı artık katalogda (res/values, res/values-tr).
     */
    fun hintsLine(screen: Screen, hasComputers: Boolean): String =
        hints(screen, hasComputers).joinToString("   ") { "${it.key} · ${it.action.name}" }
}
