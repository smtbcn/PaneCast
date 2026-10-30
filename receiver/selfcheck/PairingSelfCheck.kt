package dev.atvm.receiver

// Eşleştirme v2'nin JVM öz-denetimi (JUnit bağımlılığı eklemeden). Çalıştırma:
//   scripts/test-receiver-pairing.sh
// Test vektörü Mac tarafındaki PairingTests.swift ile aynıdır; iki dil aynı baytları üretmeli.

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.security.KeyPair

private var failures = 0
private var checks = 0

private fun check(name: String, ok: Boolean) {
    checks++
    if (!ok) { failures++; println("BAŞARISIZ: $name") }
}

private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(2 * it, 2 * it + 2).toInt(16).toByte() }
private fun eq(name: String, got: ByteArray, want: String) = check(name, got.contentEquals(hex(want)))

private object V {
    const val skMac = "de92ec869fe292bd368bebc32e7472160442cfe548ceadffd7e380acaa5bb08f"
    const val skTv = "f3d293324e8e251b17e4b79dda9f6b1d41b2726f155c76364baedea757cdd9c4"
    const val pkMac = "04b5dc2d415217c4db1cc346507fe5dfd2be6af8a9e69c04860532507f29a1514f5228c17094d5917ef0d9e767ac8040bac6105e0838191882796d9a81f590a392"
    const val pkTv = "04708fbeb90a5c6a27f0925857d960e3a83015433e02dd490a168514bd96e9251091e92e0b922cb32da1de8e1984b0065cf639b3b52dc2338f78ccdd5c73d0ec45"
    const val dhKey = "51762f9b40260d8d4a400dc059afa9f82bc8973834481838a1ceee59cb93e5ba"
    const val th0 = "1c797718f49979b81785313301940e3cdd3b951bf60bd183186093587e75cd49"
    const val kc = "283fb2404f85d4a898ab71c170f82f246a1262908341cdb8140483ec61f22b57"
    const val ca0 = "d619532b95a21a87dd9f3e880d873097aed0d5868d048171e264dba6a0f0fe6e"
    const val cb0 = "0e27ce33e57858cfcfe8228129e88150965ec822919cb6fa08c54e71bdd0f083"
    const val ca19 = "0fefa362b7d9e94e1a856f745085aaaf070d30e328902258fdf714c0ebecc1d5"
    const val cb19 = "c9f4139a16709c0b7ccc66ab10708b1718dad906cfbaa96a2d9f7b2f20576668"
    const val th = "ef4afb7e5f3b2dd6c17cff89d0df5be078b1be1babd95c9c974cf68a46e84428"
    const val pairKey = "a6259fd659ea4f8be90ec535f2e1cc2aa2d6ebed915e0653eabff080201f2f37"
    const val confirmMac = "e5cc88e276c2f36b997be89d296fe1977eff40db5aab3a81fc3b6f31ab1626ad"
    const val confirmTv = "d581de5b0e6563481b50d96f3eb282e8406ab1c4057efcd5c98fedff5ce4b4fc"
    const val ctlMac = "46247813686802f958220348b31afbc5dd9eb347e021b8221d2b5dfb5974b246"
    const val ctlTv = "5a0ae43bf13160151895abb6c06a6b11320eabacf0a620050e39177c1f3578d7"
    const val revTv = "e7461be6ae7053c5ac6ab19689763d6d7acc27e764d3c4c12946097dd25cd124"
    const val revMac = "50836ac6b8cb43c5e16546184fb85a92b31d3df2c68d7f40dcb0deac2b42d6bd"
    const val fingerprint = "37cd082d"
    const val passkey = 123456
    val nonceTv = ByteArray(16) { 0x11 }
    val nonceMac = ByteArray(16) { 0x22 }
    fun na(i: Int) = PairingCrypto.sha256("atvm-test-na".toByteArray(), byteArrayOf(i.toByte())).copyOf(16)
    fun nb(i: Int) = PairingCrypto.sha256("atvm-test-nb".toByteArray(), byteArrayOf(i.toByte())).copyOf(16)
}

private fun vector() {
    val pubMac = PairingCrypto.decode(hex(V.pkMac))!!
    val pubTv = PairingCrypto.decode(hex(V.pkTv))!!
    check("açık anahtar kodlaması geri dönüşlü", PairingCrypto.encode(pubMac).contentEquals(hex(V.pkMac)))
    eq("ECDH (TV özel × Mac açık)", PairingCrypto.dhKey(PairingCrypto.privateKey(hex(V.skTv)), pubMac), V.dhKey)
    eq("ECDH (Mac özel × TV açık)", PairingCrypto.dhKey(PairingCrypto.privateKey(hex(V.skMac)), pubTv), V.dhKey)
    eq("th0", PairingCrypto.th0(hex(V.pkMac), hex(V.pkTv)), V.th0)
    eq("taahhüt anahtarı", PairingCrypto.commitKey(hex(V.dhKey), hex(V.th0)), V.kc)
    val kc = hex(V.kc)
    eq("Ca0", PairingCrypto.commitment(kc, 'M', 0, PairingCrypto.bit(V.passkey, 0), V.na(0)), V.ca0)
    eq("Cb0", PairingCrypto.commitment(kc, 'T', 0, PairingCrypto.bit(V.passkey, 0), V.nb(0)), V.cb0)
    eq("Ca19", PairingCrypto.commitment(kc, 'M', 19, PairingCrypto.bit(V.passkey, 19), V.na(19)), V.ca19)
    eq("Cb19", PairingCrypto.commitment(kc, 'T', 19, PairingCrypto.bit(V.passkey, 19), V.nb(19)), V.cb19)
    eq("eşleşme anahtarı", PairingCrypto.pairingKey(hex(V.dhKey), hex(V.th)), V.pairKey)
    val k = hex(V.pairKey)
    eq("Mac onayı", PairingCrypto.confirm(k, "mac", hex(V.th)), V.confirmMac)
    eq("TV onayı", PairingCrypto.confirm(k, "tv", hex(V.th)), V.confirmTv)
    eq("ctl/mac kanıtı", PairingCrypto.sessionProof(k, "ctl", "mac", V.nonceTv, V.nonceMac), V.ctlMac)
    eq("ctl/tv kanıtı", PairingCrypto.sessionProof(k, "ctl", "tv", V.nonceTv, V.nonceMac), V.ctlTv)
    eq("rev/tv kanıtı", PairingCrypto.sessionProof(k, "rev", "tv", V.nonceMac, V.nonceTv), V.revTv)
    eq("rev/mac kanıtı", PairingCrypto.sessionProof(k, "rev", "mac", V.nonceMac, V.nonceTv), V.revMac)
    check("parmak izi", PairingCrypto.fingerprint(k) == V.fingerprint)
}

private fun vectorTv(): PasskeyResponder {
    var n = 0
    val kp = KeyPair(PairingCrypto.decode(hex(V.pkTv)), PairingCrypto.privateKey(hex(V.skTv)))
    return PasskeyResponder(V.passkey, kp) { V.nb(n++) }
}

/** TV durum makinesi, Mac rolündeki vektör mesajlarıyla tam akışı birebir üretmeli. */
private fun responderReproducesVector() {
    val tv = vectorTv()
    check("pair_key TV açık anahtarı", tv.onInit(hex(V.pkMac)).contentEquals(hex(V.pkTv)))
    val kc = hex(V.kc)
    for (i in 0 until PairingCrypto.ROUNDS) {
        val bit = PairingCrypto.bit(V.passkey, i)
        val cb = tv.onCommit(i, PairingCrypto.commitment(kc, 'M', i, bit, V.na(i)))
        if (i == 0) eq("TV Cb0", cb, V.cb0)
        if (i == 19) eq("TV Cb19", cb, V.cb19)
        check("TV açılışı tur $i", tv.onOpen(i, V.na(i)).contentEquals(V.nb(i)))
    }
    val (key, tvMac) = tv.onConfirm(hex(V.confirmMac))
    eq("TV eşleşme anahtarı", key, V.pairKey)
    eq("TV onay MAC'i", tvMac, V.confirmTv)
}

private fun failureReason(block: () -> Unit): String? =
    try { block(); null } catch (e: PasskeyResponder.Failure) { e.reason }

private fun responderRejects() {
    // Yanlış PIN: Mac 3. turda farklı bitle taahhüt eder → TV açılışı reddeder.
    val tv = vectorTv()
    tv.onInit(hex(V.pkMac))
    val kc = hex(V.kc)
    for (i in 0 until 3) {
        tv.onCommit(i, PairingCrypto.commitment(kc, 'M', i, PairingCrypto.bit(V.passkey, i), V.na(i)))
        tv.onOpen(i, V.na(i))
    }
    tv.onCommit(3, PairingCrypto.commitment(kc, 'M', 3, 1 - PairingCrypto.bit(V.passkey, 3), V.na(3)))
    check("ters bit reddedilir", failureReason { tv.onOpen(3, V.na(3)) } == "pin_mismatch")
    check("ret sonrası durum kapanır", failureReason { tv.onCommit(4, ByteArray(32)) } == "unexpected_message")

    // Tur sırası atlanamaz, onay turlar bitmeden kabul edilmez.
    val t2 = vectorTv(); t2.onInit(hex(V.pkMac))
    check("tur atlama reddedilir", failureReason { t2.onCommit(1, ByteArray(32)) } == "bad_message")
    val t3 = vectorTv(); t3.onInit(hex(V.pkMac))
    check("erken onay reddedilir", failureReason { t3.onConfirm(ByteArray(32)) } == "unexpected_message")

    // Eğri dışı nokta ve TV'nin kendi anahtarının yansıtılması.
    val bad = ByteArray(65).also { it[0] = 4; it[64] = 1 }
    check("eğri dışı nokta reddedilir", failureReason { vectorTv().onInit(bad) } == "bad_key")
    check("yansıtılan anahtar reddedilir", failureReason { vectorTv().onInit(hex(V.pkTv)) } == "bad_key")
    check("eğri dışı nokta decode=null", PairingCrypto.decode(bad) == null)
}

private fun lockout() {
    val dir = File(System.getProperty("java.io.tmpdir"), "atvm-pairing-selfcheck-${System.nanoTime()}").apply { mkdirs() }
    File(dir, "session_key.bin").writeBytes(ByteArray(32))
    var now = 1_000_000L
    val p = Pairing(dir) { now }
    check("v1 anahtar dosyası silindi", !File(dir, "session_key.bin").exists() && !p.paired)

    p.newPin()
    for (n in 1..Pairing.MAX_FAILURES) {
        check("deneme $n başlar", p.beginAttempt() != null)
        p.endAttempt(null)
        check("kod deneme sonrası emekli ($n)", p.pin == null)
        p.newPin()
    }
    check("3 hatadan sonra 30 sn kilit", p.lockMsLeft() == Pairing.LOCK_BASE_MS)
    check("kilitliyken deneme yok", p.beginAttempt() == null)
    now += Pairing.LOCK_BASE_MS
    check("kilit bitince deneme var", p.beginAttempt() != null)
    repeat(Pairing.MAX_FAILURES) { p.endAttempt(null); p.newPin() }
    check("ikinci kilit iki katı", p.lockMsLeft() == 2 * Pairing.LOCK_BASE_MS)
    now += 2 * Pairing.LOCK_BASE_MS
    p.newPin()
    p.beginAttempt()
    p.endAttempt(ByteArray(32) { 7 })
    check("başarı anahtarı kaydeder", p.paired && p.sessionKeys().first().contentEquals(ByteArray(32) { 7 }))
    p.newPin()
    repeat(Pairing.MAX_FAILURES) { p.endAttempt(null); p.newPin() }
    check("başarı kilit süresini sıfırlar", p.lockMsLeft() == Pairing.LOCK_BASE_MS)
    now += Protocol.PIN_TTL_MS + Pairing.LOCK_BASE_MS
    check("süresi dolan kodla deneme yok", p.beginAttempt() == null)
    dir.deleteRecursively()
}

/** Yayıncı başına kayıt tablosu (docs/protocol.md §3.3-3.4): aynı TV'de iki bilgisayar. */
private fun peersTable() {
    val dir = File(System.getProperty("java.io.tmpdir"), "atvm-peers-${System.nanoTime()}").apply { mkdirs() }
    var now = 2_000_000L
    val p = Pairing(dir) { now }
    // device_id: 16 karakterlik base64url (12 rastgele bayt).
    val a = Pairing.Claim("AAAAAAAAAAAAAAAA", "Masaustu-A")
    val b = Pairing.Claim("BBBBBBBBBBBBBBBB", "Dizustu-B")
    val k1 = ByteArray(32) { 1 }
    val k2 = ByteArray(32) { 2 }

    p.newPin(); now += 1000; p.beginAttempt(a); p.endAttempt(k1, a)
    check("ilk bilgisayar kaydedildi", p.paired && p.peers().size == 1)
    check("ikinci bilgisayar icin bos goz var", p.hasFreeSlot)
    check("A esleşmiş sayılır", p.pairedWith(a))
    check("B henuz esleşmemiş", !p.pairedWith(b))

    p.newPin(); now += 1000; p.beginAttempt(b); p.endAttempt(k2, b)
    check("iki bilgisayar birlikte esleşik", p.peers().size == 2 && p.pairedWith(a) && p.pairedWith(b))
    check("A'nin kaniti kendi anahtariyla dogrulanir", p.sessionKeys(a).first().contentEquals(k1))
    check("B'nin kaniti kendi anahtariyla dogrulanir", p.sessionKeys(b).first().contentEquals(k2))
    check("deneme siralamasi anahtar sayisini asamaz", p.sessionKeys(a).size == 2)

    // Agdan gelen id dosya adi olur: yol ziplamasina izin verilmemeli.
    val evil = Pairing.Claim("../../escape", "Saldirmen")
    p.newPin(); now += 1000; p.beginAttempt(evil); p.endAttempt(ByteArray(32) { 3 }, evil)
    check("gecersiz id ayri kimlik acmaz", p.peers().any { it.id == null })
    val inner = File(dir, "pair_keys_v2").listFiles()?.toList() ?: emptyList()
    check("dizin ağacında kaçak dosya yok",
        (dir.listFiles()?.toList() ?: emptyList()).none { it.name.indexOf("escape") >= 0 } &&
            inner.none { it.name.indexOf("escape") >= 0 } &&
            !File(dir.parentFile, "escape.bin").exists())

    val c = Pairing.Claim("CCCCCCCCCCCCCCCC", "Ucuncu-C")
    p.newPin(); now += 1000; p.beginAttempt(c); p.endAttempt(ByteArray(32) { 4 }, c)
    check("dort kayit dolu", p.peers().size == Pairing.MAX_PEERS && !p.hasFreeSlot)

    val d = Pairing.Claim("DDDDDDDDDDDDDDDD", "Dorduncu-D")
    p.newPin(); now += 1000; p.beginAttempt(d); p.endAttempt(ByteArray(32) { 5 }, d)
    check("besinciden sonra tablo dortte kalir", p.peers().size == Pairing.MAX_PEERS)
    check("en az kullanilan kayit dustu", !p.pairedWith(a) && p.pairedWith(d))

    // Tek kaydi silmek digerlerine dokunmamali; idsiz silme YALNIZ kimliksiz (eski yayinci)
    // kayidini siler — tabloyu bosaltmak insan karari olan kumanda eylemidir.
    val removed = p.peers().first { it.id != null }
    val before = p.peers().size
    p.remove(removed.id)
    check("id ile silinen kayit gitti, digerler kaldi",
        !p.pairedWith(Pairing.Claim(removed.id!!, "")) && p.peers().size == before - 1)
    val ided = p.peers().count { it.id != null }
    p.remove(null)
    check("idsiz silme sadece kimliksiz kaydi siler",
        p.peers().size == ided && p.peers().none { it.id == null })
    p.clearAll()
    check("clearAll tabloyu bosaltir", !p.paired && p.peers().isEmpty())

    // Eski surumden gelen tek dosya: id'siz bir kayit olarak okunur, kaybolmaz.
    val old = File(System.getProperty("java.io.tmpdir"), "atvm-peers-legacy-${System.nanoTime()}").apply { mkdirs() }
    File(old, "pair_key_v2.bin").writeBytes(ByteArray(32) { 9 })
    val p2 = Pairing(old) { now }
    check("eski tek anahtar tabloya tasindi", p2.paired && p2.peers().single().id == null)
    check("eski dosya artik yok", !File(old, "pair_key_v2.bin").exists())
    File(File(old, "pair_keys_v2"), "EEEEEEEEEEEEEEEE.bin").writeBytes(ByteArray(31))
    check("bozuk (32 bayt degil) kayit sayilmaz", p2.peers().size == 1)
    // Son gorulme yenilenir: dogrulanmis oturum dusurulme sirasini kendine lehine cevirir.
    now += 5000
    p2.touch("EEEEEEEEEEEEEEEE")
    check("touch gecersiz/eksik kayitta sessiz kalsin", p2.peers().size == 1)

    dir.deleteRecursively(); old.deleteRecursively()
}

private fun lineCap() {
    val ok = LineReader(ByteArrayInputStream("{\"t\":\"hello\"}\n{}\n".toByteArray()))
    check("satır okunur", ok.readLine() == "{\"t\":\"hello\"}" && ok.readLine() == "{}" && ok.readLine() == null)
    val big = LineReader(ByteArrayInputStream(ByteArray(Protocol.MAX_LINE_BYTES + 10) { 'a'.code.toByte() }))
    check("sınırı aşan satır bağlantıyı düşürür", try { big.readLine(); false } catch (e: IOException) { true })
}

private fun section(name: String, block: () -> Unit) =
    try { block() } catch (e: Exception) { check("$name: beklenmeyen istisna $e", false) }

fun main() {
    section("vektör") { vector() }
    section("TV akışı") { responderReproducesVector() }
    section("ret yolları") { responderRejects() }
    section("kilit") { lockout() }
    section("tablo") { peersTable() }
    section("satır sınırı") { lineCap() }
    if (failures == 0) println("eşleştirme öz-denetimi: $checks/$checks GEÇTİ")
    else { println("eşleştirme öz-denetimi: $failures/$checks BAŞARISIZ"); kotlin.system.exitProcess(1) }
}
