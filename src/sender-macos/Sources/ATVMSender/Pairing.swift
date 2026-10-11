import Foundation
import CryptoKit

/// Eşleştirme v2 (docs/protocol.md §3.2). Yapı Bluetooth LE Secure Connections "Passkey Entry":
/// geçici ECDH P-256 + PIN'in 20 bitinin her biri için taahhüt/açılış turu. PIN yalnız TV
/// ekranında görünür; ne kendisi ne özeti ağdan geçer. Taahhüt HMAC'i ECDH'den türeyen anahtarla
/// alınır, böylece pasif dinleyici açılan nonce'larla PIN bitlerini sınayamaz. Etkin araya giren,
/// her biti karşı taraf açmadan önce tahmin etmek zorundadır: deneme başına başarı ≤ 10⁻⁶.
/// Bayt düzeni Android tarafındaki PasskeyPairing.kt ile birebir aynıdır.
enum PairingCrypto {
    static let version = 2
    static let rounds = 20
    static let nonceBytes = 16

    enum Role: String { case mac, tv
        var tag: UInt8 { self == .mac ? 0x4D : 0x54 }      // "M" / "T"
    }
    /// ctl: Mac → TV 7601, rev: TV → Mac 7610. Kanal etiketi kanıtların kanallar arasında
    /// yansıtılmasını engeller (v1'de iki yön aynı biçimi kullanıyordu).
    enum Channel: String { case control = "ctl", reverse = "rev" }

    static func randomNonce() -> Data {
        SymmetricKey(size: .init(bitCount: nonceBytes * 8)).withUnsafeBytes { Data($0) }
    }

    /// "012345" → 12345. Tam 6 ASCII rakam değilse nil.
    static func passkey(from text: String) -> UInt32? {
        let u = Array(text.utf8)
        guard u.count == 6, u.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return u.reduce(0) { $0 * 10 + UInt32($1 - 0x30) }
    }

    static func bit(_ passkey: UInt32, _ i: Int) -> UInt8 { UInt8((passkey >> UInt32(i)) & 1) }

    static func sha256(_ parts: Data...) -> Data {
        var h = SHA256()
        for p in parts { h.update(data: p) }
        return Data(h.finalize())
    }

    static func hmac(_ key: Data, _ parts: Data...) -> Data {
        var h = HMAC<SHA256>(key: SymmetricKey(data: key))
        for p in parts { h.update(data: p) }
        return Data(h.finalize())
    }

    static func hkdf(_ ikm: Data, salt: Data, info: String) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt,
                               info: Data(info.utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
    }

    static func th0(pkMac: Data, pkTv: Data) -> Data { sha256(Data("atvm-pair-v2".utf8), pkMac, pkTv) }
    static func commitKey(dhKey: Data, th0: Data) -> Data { hkdf(dhKey, salt: th0, info: "atvm-pk-commit-v2") }
    static func commitment(_ kc: Data, _ role: Role, round: Int, bit: UInt8, nonce: Data) -> Data {
        hmac(kc, Data([role.tag, UInt8(round), bit]), nonce)
    }
    static func pairingKey(dhKey: Data, th: Data) -> Data { hkdf(dhKey, salt: th, info: "atvm-pair-v2") }
    static func confirm(_ key: Data, _ role: Role, th: Data) -> Data {
        hmac(key, Data("atvm-confirm-v2|\(role.rawValue)".utf8), th)
    }
    static func sessionProof(_ key: Data, _ channel: Channel, _ role: Role,
                             serverNonce: Data, clientNonce: Data) -> Data {
        hmac(key, Data("atvm-auth-v2|\(channel.rawValue)|\(role.rawValue)".utf8), serverNonce, clientNonce)
    }
    /// Oturumu insanca ayırt etmek için; anahtarın kendi baytlarını göstermez.
    static func fingerprint(_ key: Data) -> String {
        sha256(Data("atvm-fp-v2".utf8), key).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}

/// Mac ucunun eşleştirme durum makinesi: TV mesajını alır, gönderilecek sonrakini döndürür.
/// Ağdan bağımsızdır; birim testleri TV rolünü bellek içinde oynatır.
struct PasskeyInitiator {
    enum Failure: Error, Equatable {
        case pinRejected                 // TV, bizim açtığımız biti kendi PIN'iyle tutturamadı
        case locked(retryAfterMs: Int)
        case denied(String)
        case badPeerKey
        case peerProofInvalid            // TV'nin açılışı/onayı tutmadı: araya giren olabilir
        case unexpected(String)
    }

    private enum Phase { case awaitingKey, awaitingCommit, awaitingOpen, awaitingPaired, done }

    private let priv: P256.KeyAgreement.PrivateKey
    private let passkey: UInt32
    private let nextNonce: () -> Data
    let pkMac: Data
    private var phase = Phase.awaitingKey
    private var dh = Data(), kc = Data(), transcript = Data(), th = Data(), key = Data()
    private var round = 0
    private var na = Data(), ca = Data(), cb = Data()
    private(set) var pairingKey: Data?

    init(passkey: UInt32, privateKey: P256.KeyAgreement.PrivateKey = .init(),
         nonce: @escaping () -> Data = PairingCrypto.randomNonce) {
        self.passkey = passkey
        self.priv = privateKey
        self.nextNonce = nonce
        self.pkMac = privateKey.publicKey.x963Representation
    }

    var initMessage: [String: Any] { ["t": "pair_init", "pk": pkMac.base64EncodedString()] }

    /// Bitince (TV onayı doğrulandı) nil döner ve `pairingKey` dolar.
    mutating func handle(_ m: [String: Any]) throws -> [String: Any]? {
        let t = m["t"] as? String ?? ""
        if t == "denied" {
            phase = .done
            switch m["reason"] as? String ?? "?" {
            case "pin_mismatch", "pin_expired": throw Failure.pinRejected
            case "locked": throw Failure.locked(retryAfterMs: m["retry_after_ms"] as? Int ?? 0)
            case let r: throw Failure.denied(r)
            }
        }
        switch (phase, t) {
        case (.awaitingKey, "pair_key"):
            guard let raw = b64(m["pk"]), raw != pkMac,
                  let pub = try? P256.KeyAgreement.PublicKey(x963Representation: raw),
                  let secret = try? priv.sharedSecretFromKeyAgreement(with: pub) else { throw Failure.badPeerKey }
            dh = secret.withUnsafeBytes { Data($0) }
            let th0 = PairingCrypto.th0(pkMac: pkMac, pkTv: raw)
            kc = PairingCrypto.commitKey(dhKey: dh, th0: th0)
            transcript = th0
            round = 0
            return commitMessage()

        case (.awaitingCommit, "pk_commit"):
            guard m["i"] as? Int == round, let c = b64(m["c"]), c.count == 32 else {
                throw Failure.unexpected("pk_commit \(round)")
            }
            cb = c
            phase = .awaitingOpen
            return ["t": "pk_open", "i": round, "n": na.base64EncodedString()]

        case (.awaitingOpen, "pk_open"):
            guard m["i"] as? Int == round, let nb = b64(m["n"]), nb.count == PairingCrypto.nonceBytes else {
                throw Failure.unexpected("pk_open \(round)")
            }
            let want = PairingCrypto.commitment(kc, .tv, round: round,
                                                bit: PairingCrypto.bit(passkey, round), nonce: nb)
            guard PairingCrypto.equal(want, cb) else { phase = .done; throw Failure.peerProofInvalid }
            transcript += ca + cb + na + nb
            round += 1
            if round < PairingCrypto.rounds { return commitMessage() }
            th = PairingCrypto.sha256(transcript)
            key = PairingCrypto.pairingKey(dhKey: dh, th: th)
            phase = .awaitingPaired
            // Kullanıcı PIN'i girmeden bu noktaya gelinmez: Mac'in onayı ancak şimdi gider.
            return ["t": "pair_confirm", "mac": PairingCrypto.confirm(key, .mac, th: th).base64EncodedString()]

        case (.awaitingPaired, "paired"):
            guard let mac = b64(m["mac"]),
                  PairingCrypto.equal(mac, PairingCrypto.confirm(key, .tv, th: th)) else {
                phase = .done; throw Failure.peerProofInvalid
            }
            phase = .done
            pairingKey = key
            return nil

        default:
            throw Failure.unexpected(t)
        }
    }

    private mutating func commitMessage() -> [String: Any] {
        na = nextNonce()
        ca = PairingCrypto.commitment(kc, .mac, round: round, bit: PairingCrypto.bit(passkey, round), nonce: na)
        phase = .awaitingCommit
        return ["t": "pk_commit", "i": round, "c": ca.base64EncodedString()]
    }

    private func b64(_ v: Any?) -> Data? { (v as? String).flatMap { Data(base64Encoded: $0) } }
}
