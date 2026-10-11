package dev.atvm.receiver

import java.io.ByteArrayOutputStream
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECFieldFp
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Eşleştirme v2 kriptosu (docs/protocol.md §3.2) — Mac'teki Pairing.swift ile bayt bayt aynı.
 *  Yalnız platform java.security/javax.crypto; Android'e bağımlı değil (JVM öz-denetimi derler). */
object PairingCrypto {
    const val ROUNDS = 20
    const val NONCE_BYTES = 16
    private val ASCII = Charsets.US_ASCII

    fun newKeyPair(random: SecureRandom): KeyPair =
        KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1"), random) }.generateKeyPair()

    /** P-256 parametreleri üretilen bir anahtardan alınır ("EC" AlgorithmParameters her sağlayıcıda yok). */
    val params: ECParameterSpec by lazy { (newKeyPair(SecureRandom()).public as ECPublicKey).params }

    /** X9.63 sıkıştırılmamış nokta: 0x04 ‖ X ‖ Y (65 bayt). */
    fun encode(pub: PublicKey): ByteArray {
        val w = (pub as ECPublicKey).w
        return byteArrayOf(4) + fixed32(w.affineX) + fixed32(w.affineY)
    }

    /** Eğri üzerinde olmayan nokta reddedilir (geçersiz eğri saldırısı); sağlayıcıya güvenilmez. */
    fun decode(raw: ByteArray): PublicKey? {
        if (raw.size != 65 || raw[0].toInt() != 4) return null
        val x = BigInteger(1, raw.copyOfRange(1, 33))
        val y = BigInteger(1, raw.copyOfRange(33, 65))
        val curve = params.curve
        val p = (curve.field as ECFieldFp).p
        if (x >= p || y >= p) return null
        val rhs = x.pow(3).add(curve.a.multiply(x)).add(curve.b).mod(p)
        if (y.multiply(y).mod(p) != rhs) return null
        return try {
            KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), params))
        } catch (e: Exception) { null }
    }

    /** Yalnız sabit test vektörü için. */
    fun privateKey(raw: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, raw), params))

    /** ECDH paylaşılan sırrı: x koordinatı, 32 bayt. */
    fun dhKey(priv: PrivateKey, pub: PublicKey): ByteArray {
        val ka = KeyAgreement.getInstance("ECDH")
        ka.init(priv)
        ka.doPhase(pub, true)
        val s = ka.generateSecret()
        return if (s.size == 32) s else fixed32(BigInteger(1, s))
    }

    fun sha256(vararg parts: ByteArray): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        for (p in parts) md.update(p)
        return md.digest()
    }

    fun hmac(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        for (p in parts) mac.update(p)
        return mac.doFinal()
    }

    /** RFC 5869 HKDF-SHA256, 32 bayt çıktı (tek blok). */
    fun hkdf(ikm: ByteArray, salt: ByteArray, info: String): ByteArray {
        val prk = hmac(salt, ikm)
        return hmac(prk, info.toByteArray(ASCII), byteArrayOf(1))
    }

    fun th0(pkMac: ByteArray, pkTv: ByteArray) = sha256("atvm-pair-v2".toByteArray(ASCII), pkMac, pkTv)
    fun commitKey(dh: ByteArray, th0: ByteArray) = hkdf(dh, th0, "atvm-pk-commit-v2")
    /** role: 'M' (Mac) / 'T' (TV). */
    fun commitment(kc: ByteArray, role: Char, round: Int, bit: Int, nonce: ByteArray) =
        hmac(kc, byteArrayOf(role.code.toByte(), round.toByte(), bit.toByte()), nonce)
    fun pairingKey(dh: ByteArray, th: ByteArray) = hkdf(dh, th, "atvm-pair-v2")
    fun confirm(key: ByteArray, role: String, th: ByteArray) =
        hmac(key, "atvm-confirm-v2|$role".toByteArray(ASCII), th)
    /** channel: "ctl" (Mac → TV 7601) / "rev" (TV → Mac 7610); role: kanıtı üreten taraf. */
    fun sessionProof(key: ByteArray, channel: String, role: String, serverNonce: ByteArray, clientNonce: ByteArray) =
        hmac(key, "atvm-auth-v2|$channel|$role".toByteArray(ASCII), serverNonce, clientNonce)
    fun fingerprint(key: ByteArray): String =
        sha256("atvm-fp-v2".toByteArray(ASCII), key).copyOf(4).joinToString("") { (it.toInt() and 0xFF).toString(16).padStart(2, '0') }
    fun bit(passkey: Int, i: Int) = (passkey shr i) and 1

    private fun fixed32(v: BigInteger): ByteArray {
        val b = v.toByteArray()
        return when {
            b.size == 32 -> b
            b.size > 32 -> b.copyOfRange(b.size - 32, b.size)
            else -> ByteArray(32 - b.size) + b
        }
    }
}

/** TV ucu: tek eşleştirme denemesi. Her yöntem bir Mac mesajını işler, TV'nin yanıt baytlarını döndürür.
 *  Sıra Bluetooth LE SC "Passkey Entry" ile aynı: her turda önce Mac taahhüt eder, TV taahhüt eder,
 *  Mac açar (TV kendi PIN bitiyle sınar), sonra TV açar. Mac'in açılışı tutmazsa Failure("pin_mismatch"). */
class PasskeyResponder(
    private val passkey: Int,
    private val keyPair: KeyPair,
    private val nonce: () -> ByteArray
) {
    class Failure(val reason: String) : Exception(reason)

    private enum class Phase { INIT, COMMIT, OPEN, CONFIRM, DONE }
    private var phase = Phase.INIT
    val pkTv: ByteArray = PairingCrypto.encode(keyPair.public)
    private var dh = ByteArray(0)
    private var kc = ByteArray(0)
    private val transcript = ByteArrayOutputStream()
    private var round = 0
    private var ca = ByteArray(0)
    private var cb = ByteArray(0)
    private var nb = ByteArray(0)

    fun onInit(pkMac: ByteArray): ByteArray {
        expect(Phase.INIT)
        if (pkMac.contentEquals(pkTv)) throw Failure("bad_key")
        val pub = PairingCrypto.decode(pkMac) ?: throw Failure("bad_key")
        dh = PairingCrypto.dhKey(keyPair.private, pub)
        val th0 = PairingCrypto.th0(pkMac, pkTv)
        kc = PairingCrypto.commitKey(dh, th0)
        transcript.write(th0)
        phase = Phase.COMMIT
        return pkTv
    }

    fun onCommit(i: Int, c: ByteArray): ByteArray {
        expect(Phase.COMMIT)
        if (i != round || c.size != 32) throw Failure("bad_message")
        ca = c
        nb = nonce()
        cb = PairingCrypto.commitment(kc, 'T', round, PairingCrypto.bit(passkey, round), nb)
        phase = Phase.OPEN
        return cb
    }

    fun onOpen(i: Int, na: ByteArray): ByteArray {
        expect(Phase.OPEN)
        if (i != round || na.size != PairingCrypto.NONCE_BYTES) throw Failure("bad_message")
        val want = PairingCrypto.commitment(kc, 'M', round, PairingCrypto.bit(passkey, round), na)
        if (!MessageDigest.isEqual(want, ca)) { phase = Phase.DONE; throw Failure("pin_mismatch") }
        transcript.write(ca); transcript.write(cb); transcript.write(na); transcript.write(nb)
        round++
        phase = if (round == PairingCrypto.ROUNDS) Phase.CONFIRM else Phase.COMMIT
        return nb
    }

    /** Döner: (eşleşme anahtarı, TV onayı). */
    fun onConfirm(mac: ByteArray): Pair<ByteArray, ByteArray> {
        expect(Phase.CONFIRM)
        val th = PairingCrypto.sha256(transcript.toByteArray())
        val key = PairingCrypto.pairingKey(dh, th)
        if (!MessageDigest.isEqual(PairingCrypto.confirm(key, "mac", th), mac)) {
            phase = Phase.DONE; throw Failure("confirm_mismatch")
        }
        phase = Phase.DONE
        return key to PairingCrypto.confirm(key, "tv", th)
    }

    private fun expect(p: Phase) { if (phase != p) throw Failure("unexpected_message") }
}
