package dev.atvm.receiver

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Alıcının ekranı: üç bant — üstte durum, ortada o anın tek sorusu, altta TEK SIRA kumanda rehberi.
 *
 * Neden elle çizilmiş kartlar ve odak? Cihaz AndroidX/Leanback taşımıyor (AGENTS kuralı:
 * gereksiz bağımlılık yok). Leanback'in yaptığı şeyin özü şu üç kuraldır ve burada onları
 * framework API'siyle kuruyoruz:
 *  - Odaktaki öğe ANINDA belli olur (kenarlık + zemin + hafif ölçek), çünkü kumanda imleçsizdir.
 *  - ▲▼◀▶ framework'in odak aramasına bırakılır; kendi tuş haritamızı gezinmeye yazmayız.
 *  - Ekranın altındaki yardım satırı duruma göre ÜRETİLİR, elle yazılmaz (yalan söylemez).
 *
 * Yayın sırasında tüm katmanlar gizlenir: görüntü temiz kalsın. MENU ölçüm katmanını açar,
 * ölçüm şeridi 4 sn dokunulmazınca kendiliğinden kaybolur.
 */
class TvScreen(private val context: Context, private val ui: Handler) {
    // Kullanıcı isteği: yayın sırasında ekrana gelen durum/ölçüm/kısayol katmanı 5 sn
    // dokunulmazsa kendiliğinden kaybolur; herhangi bir tuş geri getirir.
    private companion object { const val STATS_VISIBLE_MS = 5_000L }

    /** Bir bilgisayar kartının çizimi için gerekli en küçük veri. */
    data class Card(val name: String, val detail: String, val state: CardState)
    enum class CardState { READY, BUSY, OFFLINE }

    /** Ekranın içinde bulunduğu durum. */
    data class State(
        val screen: RemoteKeys.Screen,
        val headline: String,
        val subline: String,
        val note: String,
        val noteIsError: Boolean = false,
        val pin: String,
        val pinSecondsLeft: Int,
        val cards: List<Card>,
        val stats: String,
        val detail: String,
        val showDetail: Boolean,
        val version: String,
        val addresses: String,
    )

    private val density = context.resources.displayMetrics.density
    private fun dp(v: Int): Int = (v * density).toInt()

    val legend = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
    }
    private val wordmark = label(22f, Color.WHITE, Typeface.create("sans-serif-medium", Typeface.BOLD)).apply {
        // Ölçülen kusur: etiket oluşturulup metni unutulmuş, üst solda yalnız mavi nokta duruyordu.
        text = "Pane Cast"
    }
    private val stateChip = TextView(context).apply {
        textSize = 15f; setTextColor(Color.WHITE); setPadding(dp(14), dp(5), dp(14), dp(5))
        gravity = Gravity.CENTER
    }
    private val techChip = label(13f, 0xFF8FA3BF.toInt())
    private val headline = label(38f, Color.WHITE, Typeface.create("sans-serif-medium", Typeface.BOLD))
    private val subline = label(19f, 0xFFAFC4DE.toInt())
    private val noteLine = label(17f, 0xFFFFC46B.toInt())
    private val pinLabel = label(19f, 0xFFAFC4DE.toInt()).apply {
        text = "Bu kodu Mac'teki Pane Cast penceresine girin"
        gravity = Gravity.CENTER
    }
    private val pinValue = TextView(context).apply {
        textSize = 104f; letterSpacing = 0.14f; typeface = Typeface.MONOSPACE
        setTextColor(Color.WHITE); gravity = Gravity.CENTER; includeFontPadding = false
        maxLines = 1; setSingleLine(true)
    }
    private val pinTimer = label(16f, 0xFF7F93AE.toInt()).apply { gravity = Gravity.CENTER }
    // Odaklı kart %3 büyüyor + 3dp halka taşıyor: satırda yer açılmaz ve çocuk kesilmezse
    // kartın sol/üst kenarı kırpılıyor (ölçüldü: odaklı kartın sol kenarında mavi halka
    // tamamen kayboluyor, siyahtan direkt doluya geçiliyordu).
    private val cardRow = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER
        setPadding(dp(14), dp(14), dp(14), dp(14))
        clipChildren = false
        clipToPadding = false
    }
    private val statsStrip = label(15f, 0xFFDCE9F7.toInt()).apply {
        setPadding(dp(14), dp(6), dp(14), dp(6)); gravity = Gravity.CENTER
    }
    private val detailBox = TextView(context).apply {
        textSize = 13f; setTextColor(0xFFBFD3E8.toInt()); setPadding(dp(16), dp(12), dp(16), dp(12))
        // Şerit yüksekliği sınırlı olsun: uzun ölçüm satırları küçültülüp tek satıra düşürülür.
        maxLines = 6; ellipsize = android.text.TextUtils.TruncateAt.END
        maxWidth = dp(620)
        visibility = View.GONE
        background = round(0xE6060A12.toInt(), 14, 0x33FFFFFF, 1)
    }
    private val heroPairing = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER; visibility = View.GONE
    }
    private val heroReady = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER; visibility = View.GONE
        clipChildren = false
    }
    private val middle = FrameLayout(context).apply { clipChildren = false }
    private val topBar = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
    }
    private val layer = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(48), dp(30), dp(48), dp(24))
        clipChildren = false
    }

    private var lastLegendKey = ""
    private var lastCardKey = ""
    private var hideStats: Runnable? = null
    private var lastScreen: RemoteKeys.Screen? = null

    /** Kart odak değişiminde tıklama eylemi; MainActivity kendi fiilini bağlar. */
    var onCardSelected: ((Int) -> Unit)? = null

    init {
        val dot = View(context).apply {
            background = round(0xFF4C8DFF.toInt(), 20)
        }
        topBar.addView(wordmark, LinearLayout.LayoutParams(-2, -2))
        topBar.addView(dot, LinearLayout.LayoutParams(dp(10), dp(10)).apply { marginStart = dp(10) })
        topBar.addView(stateChip, LinearLayout.LayoutParams(-2, -2).apply { marginStart = dp(14) })
        topBar.addView(View(context), LinearLayout.LayoutParams(0, 1, 1f))
        topBar.addView(techChip, LinearLayout.LayoutParams(-2, -2))

        val pinCard = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
            setPadding(dp(56), dp(34), dp(56), dp(34))
            // Kod bir kartın içinde dursun: siyah zeminde havada duran rakamlar okunmuyordu.
            background = round(0xFF0F1A2B.toInt(), 22, 0xFF24344D.toInt(), 1)
            addView(pinLabel)
            addView(pinValue, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(10) })
            addView(pinTimer, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(10) })
        }
        heroPairing.addView(pinCard)

        val readyTexts = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL; gravity = Gravity.CENTER
            // Ölçülen kusur (gerçek TV, 0.2.4): düşey LinearLayout'un çocukları varsayılan
            // olarak MATCH_PARENT genişlik alır; başlık bloğu böylece kart satırının genişliğine
            // (480 px) sıkışıyor ve alt satır "… bağlantı"da kırpılıyordu. Her iki sıra da
            // artık içeriğinin genişliğini ister.
            addView(headline, LinearLayout.LayoutParams(-2, -2))
            addView(subline, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(6) })
        }
        heroReady.addView(readyTexts, LinearLayout.LayoutParams(-2, -2))
        heroReady.addView(cardRow, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(26) })

        middle.addView(heroPairing, center())
        middle.addView(heroReady, center())
        middle.addView(statsStrip, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.CENTER_HORIZONTAL)
            .apply { topMargin = dp(4) })

        layer.addView(topBar, LinearLayout.LayoutParams(-1, -2))
        layer.addView(middle, LinearLayout.LayoutParams(-1, 0, 1f))
        // Not satırı DURUMDAN BAĞIMSIZ: ölçülen kusur, uyarı yalnız hazır/yayında
        // çiziliyor; yeni bir TV'de (PIN ekranında) "kontrol kanalı kapalı" hiç görünmüyordu.
        layer.addView(noteLine, LinearLayout.LayoutParams(-2, -2).apply {
            gravity = Gravity.CENTER_HORIZONTAL; bottomMargin = dp(10)
        })
        // Ayrıntı katmanı KENDİ sırasında durur: köşeye sabitliydi ve ortadaki kart satırının
        // üstüne biniyordu (ölçülen kusur, gerçek TV). Şerit olarak ortayı daraltır, üstüne çıkmaz.
        layer.addView(detailBox, LinearLayout.LayoutParams(-2, -2).apply {
            gravity = Gravity.CENTER_HORIZONTAL; topMargin = dp(2); bottomMargin = dp(8)
        })
        layer.addView(legend, LinearLayout.LayoutParams(-2, -2).apply { gravity = Gravity.CENTER_HORIZONTAL })
    }

    private fun center() = FrameLayout.LayoutParams(-2, -2, Gravity.CENTER)

    private fun label(size: Float, color: Int, tf: Typeface = Typeface.DEFAULT) = TextView(context).apply {
        textSize = size; setTextColor(color); typeface = tf; maxLines = 2
    }

    private fun round(fill: Int, radiusDp: Int, stroke: Int = 0, strokeDp: Int = 0) =
        GradientDrawable().apply {
            setColor(fill)
            cornerRadius = radiusDp * density
            if (stroke != 0) setStroke(dp(if (strokeDp == 0) 1 else strokeDp), stroke)
        }

    /** Üst durum çipi ve alt rehber gibi zeminleri duruma göre boyar. */
    private fun toneOf(screen: RemoteKeys.Screen): Int = when (screen) {
        RemoteKeys.Screen.PAIRING -> 0xFFFF8A3D.toInt()
        RemoteKeys.Screen.READY -> 0xFF4C8DFF.toInt()
        RemoteKeys.Screen.STREAMING -> 0xFF3DDC84.toInt()
    }

    /**
     * Tek giriş noktası: durumu çizer. Kart satırı ve rehber yalnız İÇERİK değişince
     * yeniden kurulur (her saniye yeniden çizim, odaklanan kartı odağından ediyordu).
     */
    fun render(s: State) {
        val streaming = s.screen == RemoteKeys.Screen.STREAMING
        val tone = toneOf(s.screen)

        stateChip.text = when (s.screen) {
            RemoteKeys.Screen.PAIRING -> "EŞLEŞME BEKLENİYOR"
            RemoteKeys.Screen.READY -> "HAZIR"
            RemoteKeys.Screen.STREAMING -> "YAYINDA"
        }
        stateChip.background = round((tone and 0x00FFFFFF) or 0x33000000, 20, tone, 1)
        techChip.text = if (streaming) "" else "Pane Cast ${s.version}  ·  ${s.addresses}"

        heroPairing.visibility = if (s.screen == RemoteKeys.Screen.PAIRING) View.VISIBLE else View.GONE
        heroReady.visibility = if (streaming) View.GONE else View.VISIBLE
        if (s.screen == RemoteKeys.Screen.PAIRING) {
            pinValue.text = s.pin
            pinTimer.text = if (s.pinSecondsLeft > 0) "bu kod ${s.pinSecondsLeft} sn geçerli · OK: yeni kod"
                            else "kodun süresi doldu · OK: yeni kod"
        } else {
            headline.text = s.headline
            subline.text = s.subline
        }

        val cardKey = s.cards.joinToString("|") { "${it.name}${it.detail}${it.state}" }
        if (cardKey != lastCardKey) { lastCardKey = cardKey; rebuildCards(s.cards) }
        cardRow.visibility = if (s.screen == RemoteKeys.Screen.READY && s.cards.isNotEmpty()) View.VISIBLE else View.GONE

        if (streaming) {
            statsStrip.text = s.stats
            statsStrip.background = round(0xCC060A12.toInt(), 18, 0x33FFFFFF.toInt(), 1)
            // Yalnızca yayına yeni geçildiğinde göster ve saymayı başlat: renderStatus
            // her saniye koştuğu için burada her seferinde zamanlansaydı şerit hiç
            // kaybolmazdı (ölçülen tasarım hatası).
            if (lastScreen != RemoteKeys.Screen.STREAMING) {
                statsStrip.visibility = View.VISIBLE
                layer.visibility = View.VISIBLE
                scheduleStatsHide()
            }
        } else {
            hideStats?.let { ui.removeCallbacks(it) }
            hideStats = null
            statsStrip.visibility = View.GONE
        }
        lastScreen = s.screen

        detailBox.text = s.detail
        // Ayrıntı katmanı kendi sırasında (not ile rehber arasında): öncesinde köşeye
        // sabitti ve ortadaki kartların üstüne biniyordu — artık hiçbir durumla çakışmaz,
        // bu yüzden eşleşme ekranında da çizilebilir.
        detailBox.visibility = if (s.showDetail) View.VISIBLE else View.GONE

        noteLine.text = s.note
        noteLine.setTextColor(if (s.noteIsError) 0xFFFF6B6B.toInt() else 0xFFFFC46B.toInt())
        noteLine.visibility = if (s.note.isEmpty()) View.GONE else View.VISIBLE

        val legendKey = RemoteKeys.hintsLine(s.screen, s.cards.isNotEmpty())
        if (legendKey != lastLegendKey) { lastLegendKey = legendKey; rebuildLegend(s.screen, s.cards.isNotEmpty(), tone) }
        if (!streaming) layer.visibility = View.VISIBLE
    }

    /** Kartlar: odaklanınca kenarlık + zemin + hafif ölçek. Tıklama OK ile gelir ( onItemClick ). */
    private fun rebuildCards(cards: List<Card>) {
        // Liste her yenilendiğinde odak ilk karta sıçramasın: yalnız hiç odak yoksa verilir.
        val rootFocus = cardRow.rootView.findFocus()
        cardRow.removeAllViews()
        cards.forEachIndexed { index, c ->
            val base = when (c.state) {
                CardState.READY -> 0xFF3DDC84.toInt()
                CardState.BUSY -> 0xFFFFB74D.toInt()
                CardState.OFFLINE -> 0xFF6B7A93.toInt()
            }
            val card = LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                // Yükseklik kısaltıldı (kullanıcı isteği): dikey dolgu 18→12dp ve durum
                // noktası başlığın sağına taşınınca altına ayrılan 10dp + 8dp'lik sıra kalktı.
                setPadding(dp(22), dp(12), dp(22), dp(12))
                isFocusable = true
                isFocusableInTouchMode = false
                // Başlık sırası: ad solda kalan genişliği alır, durum noktası SAĞ ÜSTTE durur.
                // Nokta alt alta değil yan yana: kart böylece bir satıra yakın kısalıyor.
                addView(LinearLayout(context).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    // Ölçülen kusur: `maxLines = 1` tek başına yetmiyor, uzun ad ellipsis
                    // olmadan kesiliyordu → setSingleLine + MIDDLE.
                    addView(label(21f, Color.WHITE, Typeface.create("sans-serif-medium", Typeface.BOLD)).apply {
                        text = c.name; setSingleLine(true); ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
                    }, LinearLayout.LayoutParams(-2, -2, 1f))
                    addView(View(context).apply { background = round(base, 10) },
                            LinearLayout.LayoutParams(dp(8), dp(8)).apply {
                                gravity = Gravity.TOP; topMargin = dp(5); marginStart = dp(10)
                            })
                }, LinearLayout.LayoutParams(-1, -2))
                addView(label(14f, 0xFF9FB4CE.toInt()).apply {
                    text = c.detail; setSingleLine(true); ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
                }, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(2) })
                setOnClickListener { onCardSelected?.invoke(index) }
                setOnFocusChangeListener { v, has ->
                    v.background = if (has) round(0xFF17263D.toInt(), 18, 0xFF6FA8FF.toInt(), 3)
                                   else round(0xFF0F1A2B.toInt(), 18, 0xFF24344D.toInt(), 1)
                    // Ölçek 1,04'te kart yuvasından ~9 px taşıyordu; 1,03 + gölge, halkayı
                    // kesmeden aynı "önde durma" hissini veriyor.
                    v.scaleX = if (has) 1.03f else 1.0f
                    v.scaleY = if (has) 1.03f else 1.0f
                    v.elevation = if (has) dp(10).toFloat() else 0f
                }
            }
            card.background = round(0xFF0F1A2B.toInt(), 18, 0xFF24344D.toInt(), 1)
            card.clipChildren = false
            cardRow.addView(card, LinearLayout.LayoutParams(-2, -2, 0f).apply {
                // Yalnız marginEnd verilmişti: grup sağa kayık duruyor ve ilk kartın solu
                // kesik görünüyordu. Boşluk artık iki yanda eşit.
                marginStart = dp(8)
                marginEnd = dp(8)
                width = dp(232)          // eşit kart genişliği: odak çerçevesi de eşit görünsün
            })
            if (index == 0 && rootFocus == null) card.requestFocus()
        }
    }

    /** Alt rehber: tek sıra, her hücre [tuş] + tek fiil. */
    private fun rebuildLegend(screen: RemoteKeys.Screen, hasComputers: Boolean, tone: Int) {
        legend.removeAllViews()
        RemoteKeys.hints(screen, hasComputers).forEach { h ->
            val cell = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(12), dp(6), dp(12), dp(6))
                background = round(0x14FFFFFF.toInt(), 16)
                addView(label(14f, 0xFFFFFFFF.toInt(), Typeface.create("sans-serif-medium", Typeface.BOLD)).apply {
                    text = h.key
                })
                addView(label(14f, 0xFF9FB4CE.toInt()).apply { text = h.action },
                        LinearLayout.LayoutParams(-2, -2).apply { marginStart = dp(7) })
            }
            legend.addView(cell, LinearLayout.LayoutParams(-2, -2).apply { marginEnd = dp(10) })
        }
    }

    /**
     * Ölçüm şeridi, ayrıntı katmanı ve kısayol sırası 5 sn hareketsiz kalınca **hep birlikte**
     * kaybolur: yayın görüntüsü temiz kalsın. Eskiden ayrıntı katmanı açıkken katman hiç
     * gizlenmiyordu ve kullanıcı MENU'yu kapayana kadar şeridi üstünde taşıyordu (kullanıcı
     * isteği: "5 sn sonra otomatik kapansın ya da bi şekilde ben kapatabilmeliyim").
     */
    private fun scheduleStatsHide() {
        hideStats?.let { ui.removeCallbacks(it) }
        hideStats = Runnable {
            statsStrip.visibility = View.GONE
            layer.visibility = View.INVISIBLE
        }.also { ui.postDelayed(it, STATS_VISIBLE_MS) }
    }

    /**
     * Kullanıcı bir tuşa bastı: kaplama geri gelir ve sayma yeniden başlar. MENU ile açılan
     * ölçüm katmanı da bu yolla görünür olur; tuşa basılmayınca o da 5 sn sonra kaybolur.
     */
    fun wakeStats() {
        if (hideStats == null) return
        layer.visibility = View.VISIBLE
        statsStrip.visibility = View.VISIBLE
        scheduleStatsHide()
    }

    fun view(): View = layer

    /** Yayın başlamadan önce katmanları kaldırır: siyah bantlar hariç her şey temiz. */
    fun setLayerVisible(on: Boolean) {
        layer.visibility = if (on) View.VISIBLE else View.GONE
    }
}
