import CryptoKit
import XCTest
@testable import atvm_sender

/// Ortak test vektörü: receiver/selfcheck/PairingSelfCheck.kt aynı girdilerden aynı baytları bekler.
/// Değerler, CryptoKit'ten bağımsız bir saf tamsayı P-256 uygulamasıyla üretildi.
enum PairingVector {
    static let skMac = hex("de92ec869fe292bd368bebc32e7472160442cfe548ceadffd7e380acaa5bb08f")
    static let skTv = hex("f3d293324e8e251b17e4b79dda9f6b1d41b2726f155c76364baedea757cdd9c4")
    static let pkMac = hex("04b5dc2d415217c4db1cc346507fe5dfd2be6af8a9e69c04860532507f29a1514f5228c17094d5917ef0d9e767ac8040bac6105e0838191882796d9a81f590a392")
    static let pkTv = hex("04708fbeb90a5c6a27f0925857d960e3a83015433e02dd490a168514bd96e9251091e92e0b922cb32da1de8e1984b0065cf639b3b52dc2338f78ccdd5c73d0ec45")
    static let dhKey = hex("51762f9b40260d8d4a400dc059afa9f82bc8973834481838a1ceee59cb93e5ba")
    static let th0 = hex("1c797718f49979b81785313301940e3cdd3b951bf60bd183186093587e75cd49")
    static let kc = hex("283fb2404f85d4a898ab71c170f82f246a1262908341cdb8140483ec61f22b57")
    static let ca0 = hex("d619532b95a21a87dd9f3e880d873097aed0d5868d048171e264dba6a0f0fe6e")
    static let cb0 = hex("0e27ce33e57858cfcfe8228129e88150965ec822919cb6fa08c54e71bdd0f083")
    static let ca19 = hex("0fefa362b7d9e94e1a856f745085aaaf070d30e328902258fdf714c0ebecc1d5")
    static let cb19 = hex("c9f4139a16709c0b7ccc66ab10708b1718dad906cfbaa96a2d9f7b2f20576668")
    static let th = hex("ef4afb7e5f3b2dd6c17cff89d0df5be078b1be1babd95c9c974cf68a46e84428")
    static let pairKey = hex("a6259fd659ea4f8be90ec535f2e1cc2aa2d6ebed915e0653eabff080201f2f37")
    static let confirmMac = hex("e5cc88e276c2f36b997be89d296fe1977eff40db5aab3a81fc3b6f31ab1626ad")
    static let confirmTv = hex("d581de5b0e6563481b50d96f3eb282e8406ab1c4057efcd5c98fedff5ce4b4fc")
    static let ctlMac = hex("46247813686802f958220348b31afbc5dd9eb347e021b8221d2b5dfb5974b246")
    static let ctlTv = hex("5a0ae43bf13160151895abb6c06a6b11320eabacf0a620050e39177c1f3578d7")
    static let revTv = hex("e7461be6ae7053c5ac6ab19689763d6d7acc27e764d3c4c12946097dd25cd124")
    static let revMac = hex("50836ac6b8cb43c5e16546184fb85a92b31d3df2c68d7f40dcb0deac2b42d6bd")
    static let fingerprint = "37cd082d"
    static let passkey: UInt32 = 123456
    static let nonceTv = Data(repeating: 0x11, count: 16)
    static let nonceMac = Data(repeating: 0x22, count: 16)
    static func na(_ i: Int) -> Data { PairingCrypto.sha256(Data("atvm-test-na".utf8), Data([UInt8(i)])).prefix(16) }
    static func nb(_ i: Int) -> Data { PairingCrypto.sha256(Data("atvm-test-nb".utf8), Data([UInt8(i)])).prefix(16) }

    static func hex(_ s: String) -> Data {
        var d = Data(), i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return d
    }
}

/// TV rolü (receiver PasskeyPairing.kt'nin Swift aynası): durum makinesini bellek içinde sınamak için.
struct TestResponder {
    struct Reject: Error { let reason: String }
    let priv: P256.KeyAgreement.PrivateKey
    let passkey: UInt32
    var nonce: () -> Data = PairingCrypto.randomNonce
    /// Saldırgan/bozuk TV taklidi: açılışı bu tur için ters bitle üretir.
    var flipOpenAt: Int? = nil
    private var dh = Data(), kc = Data(), transcript = Data(), th = Data()
    private var round = 0, ca = Data(), cb = Data(), nb = Data()
    private(set) var key: Data?
    var pk: Data { priv.publicKey.x963Representation }

    init(priv: P256.KeyAgreement.PrivateKey = .init(), passkey: UInt32) { self.priv = priv; self.passkey = passkey }

    mutating func handle(_ m: [String: Any]) throws -> [String: Any] {
        func b64(_ k: String) -> Data { Data(base64Encoded: m[k] as? String ?? "") ?? Data() }
        switch m["t"] as? String {
        case "pair_init":
            let pkMac = b64("pk")
            guard pkMac != pk, let pub = try? P256.KeyAgreement.PublicKey(x963Representation: pkMac) else {
                throw Reject(reason: "bad_key")
            }
            dh = try priv.sharedSecretFromKeyAgreement(with: pub).withUnsafeBytes { Data($0) }
            let t0 = PairingCrypto.th0(pkMac: pkMac, pkTv: pk)
            kc = PairingCrypto.commitKey(dhKey: dh, th0: t0)
            transcript = t0
            return ["t": "pair_key", "pk": pk.base64EncodedString()]
        case "pk_commit":
            ca = b64("c"); nb = nonce()
            cb = PairingCrypto.commitment(kc, .tv, round: round, bit: PairingCrypto.bit(passkey, round), nonce: nb)
            return ["t": "pk_commit", "i": round, "c": cb.base64EncodedString()]
        case "pk_open":
            let na = b64("n")
            let want = PairingCrypto.commitment(kc, .mac, round: round, bit: PairingCrypto.bit(passkey, round), nonce: na)
            guard PairingCrypto.equal(want, ca) else { throw Reject(reason: "pin_mismatch") }
            transcript += ca + cb + na + nb
            var open = nb
            if flipOpenAt == round {
                // Ters bitle yeniden taahhüt edemeyiz (cb gitti); yalnız açılışı bozmak, Mac'in reddini sınar.
                open = PairingCrypto.randomNonce()
            }
            round += 1
            return ["t": "pk_open", "i": round - 1, "n": open.base64EncodedString()]
        case "pair_confirm":
            th = PairingCrypto.sha256(transcript)
            let k = PairingCrypto.pairingKey(dhKey: dh, th: th)
            guard PairingCrypto.equal(b64("mac"), PairingCrypto.confirm(k, .mac, th: th)) else {
                throw Reject(reason: "confirm_mismatch")
            }
            key = k
            return ["t": "paired", "session": PairingCrypto.fingerprint(k),
                    "mac": PairingCrypto.confirm(k, .tv, th: th).base64EncodedString()]
        default:
            throw Reject(reason: "unexpected")
        }
    }
}

final class PairingTests: XCTestCase {
    typealias V = PairingVector

    /// Mac ile TV'yi bellek içinde konuşturur. Mac'in gönderdiği mesaj sayısını da döndürür.
    @discardableResult
    func run(_ ini: inout PasskeyInitiator, _ tv: inout TestResponder) throws -> Int {
        var out: [String: Any]? = ini.initMessage
        var sent = 0
        while let m = out {
            sent += 1
            let reply: [String: Any]
            do { reply = try tv.handle(m) } catch let r as TestResponder.Reject {
                reply = ["t": "denied", "reason": r.reason]
            }
            out = try ini.handle(reply)
        }
        return sent
    }

    func testCrossLanguageVector() throws {
        let mac = try P256.KeyAgreement.PrivateKey(rawRepresentation: V.skMac)
        let tv = try P256.KeyAgreement.PrivateKey(rawRepresentation: V.skTv)
        XCTAssertEqual(mac.publicKey.x963Representation, V.pkMac)
        XCTAssertEqual(tv.publicKey.x963Representation, V.pkTv)
        let dh = try mac.sharedSecretFromKeyAgreement(with: tv.publicKey).withUnsafeBytes { Data($0) }
        XCTAssertEqual(dh, V.dhKey)
        XCTAssertEqual(PairingCrypto.th0(pkMac: V.pkMac, pkTv: V.pkTv), V.th0)
        XCTAssertEqual(PairingCrypto.commitKey(dhKey: dh, th0: V.th0), V.kc)
        XCTAssertEqual(PairingCrypto.commitment(V.kc, .mac, round: 0, bit: PairingCrypto.bit(V.passkey, 0), nonce: V.na(0)), V.ca0)
        XCTAssertEqual(PairingCrypto.commitment(V.kc, .tv, round: 0, bit: PairingCrypto.bit(V.passkey, 0), nonce: V.nb(0)), V.cb0)
        XCTAssertEqual(PairingCrypto.commitment(V.kc, .mac, round: 19, bit: PairingCrypto.bit(V.passkey, 19), nonce: V.na(19)), V.ca19)
        XCTAssertEqual(PairingCrypto.commitment(V.kc, .tv, round: 19, bit: PairingCrypto.bit(V.passkey, 19), nonce: V.nb(19)), V.cb19)
        XCTAssertEqual(PairingCrypto.pairingKey(dhKey: dh, th: V.th), V.pairKey)
        XCTAssertEqual(PairingCrypto.confirm(V.pairKey, .mac, th: V.th), V.confirmMac)
        XCTAssertEqual(PairingCrypto.confirm(V.pairKey, .tv, th: V.th), V.confirmTv)
        XCTAssertEqual(PairingCrypto.sessionProof(V.pairKey, .control, .mac, serverNonce: V.nonceTv, clientNonce: V.nonceMac), V.ctlMac)
        XCTAssertEqual(PairingCrypto.sessionProof(V.pairKey, .control, .tv, serverNonce: V.nonceTv, clientNonce: V.nonceMac), V.ctlTv)
        XCTAssertEqual(PairingCrypto.sessionProof(V.pairKey, .reverse, .tv, serverNonce: V.nonceMac, clientNonce: V.nonceTv), V.revTv)
        XCTAssertEqual(PairingCrypto.sessionProof(V.pairKey, .reverse, .mac, serverNonce: V.nonceMac, clientNonce: V.nonceTv), V.revMac)
        XCTAssertEqual(PairingCrypto.fingerprint(V.pairKey), V.fingerprint)
    }

    /// Durum makinesi vektördeki dökümü birebir üretiyor mu: sabit anahtar ve nonce'larla
    /// tüm turlar koşulur; çıkan anahtar ve Mac onayı vektörle aynı olmalı.
    func testInitiatorReproducesVectorTranscript() throws {
        var naIndex = 0
        var ini = PasskeyInitiator(passkey: V.passkey,
                                   privateKey: try P256.KeyAgreement.PrivateKey(rawRepresentation: V.skMac),
                                   nonce: { defer { naIndex += 1 }; return V.na(naIndex) })
        var nbIndex = 0
        var tv = TestResponder(priv: try P256.KeyAgreement.PrivateKey(rawRepresentation: V.skTv), passkey: V.passkey)
        tv.nonce = { defer { nbIndex += 1 }; return V.nb(nbIndex) }
        var confirmSeen = Data()
        var out: [String: Any]? = ini.initMessage
        while let m = out {
            if m["t"] as? String == "pk_commit", m["i"] as? Int == 0 {
                XCTAssertEqual(Data(base64Encoded: m["c"] as! String), V.ca0)
            }
            if m["t"] as? String == "pair_confirm" { confirmSeen = Data(base64Encoded: m["mac"] as! String)! }
            out = try ini.handle(try tv.handle(m))
        }
        XCTAssertEqual(confirmSeen, V.confirmMac)
        XCTAssertEqual(ini.pairingKey, V.pairKey)
        XCTAssertEqual(tv.key, V.pairKey)
    }

    func testHonestPairingAgreesOnKey() throws {
        var ini = PasskeyInitiator(passkey: 4711)
        var tv = TestResponder(passkey: 4711)
        // pair_init + 20 × (pk_commit + pk_open) + pair_confirm
        XCTAssertEqual(try run(&ini, &tv), 2 + 2 * PairingCrypto.rounds)
        XCTAssertNotNil(ini.pairingKey)
        XCTAssertEqual(ini.pairingKey, tv.key)
    }

    func testPinNeverAppearsInMessages() throws {
        let pin = "908172"
        var ini = PasskeyInitiator(passkey: PairingCrypto.passkey(from: pin)!)
        var tv = TestResponder(passkey: PairingCrypto.passkey(from: pin)!)
        var wire = ""
        var out: [String: Any]? = ini.initMessage
        while let m = out {
            wire += String(data: try JSONSerialization.data(withJSONObject: m), encoding: .utf8)!
            let r = try tv.handle(m)
            wire += String(data: try JSONSerialization.data(withJSONObject: r), encoding: .utf8)!
            out = try ini.handle(r)
        }
        XCTAssertFalse(wire.contains(pin))
        XCTAssertNotNil(ini.pairingKey)
    }

    /// Yanlış PIN: TV ilk farklı bitte açılışı reddeder; Mac onay göndermez, anahtar oluşmaz.
    func testWrongPinIsRejectedAtFirstDifferingBit() throws {
        let real: UInt32 = 0b1011_0000_0000_0000_0110    // 720902
        let typed = real ^ (1 << 5)
        var ini = PasskeyInitiator(passkey: typed)
        var tv = TestResponder(passkey: real)
        var opens = 0
        var out: [String: Any]? = ini.initMessage
        do {
            while let m = out {
                if m["t"] as? String == "pair_confirm" { XCTFail("yanlış PIN'de onay gitmemeli") }
                if m["t"] as? String == "pk_open" { opens += 1 }
                let reply: [String: Any]
                do { reply = try tv.handle(m) } catch let r as TestResponder.Reject {
                    reply = ["t": "denied", "reason": r.reason]
                }
                out = try ini.handle(reply)
            }
            XCTFail("eşleşme reddedilmeliydi")
        } catch let f as PasskeyInitiator.Failure {
            XCTAssertEqual(f, .pinRejected)
        }
        XCTAssertEqual(opens, 6)          // bit 0…5 açıldı, 5. bitte durdu
        XCTAssertNil(ini.pairingKey)
        XCTAssertNil(tv.key)
    }

    /// TV rolündeki taraf açılışını bizim bitimizle tutturamazsa Mac durur (araya giren belirtisi).
    func testPeerOpeningMismatchStopsMac() throws {
        var ini = PasskeyInitiator(passkey: 123)
        var tv = TestResponder(passkey: 123)
        tv.flipOpenAt = 3
        XCTAssertThrowsError(try run(&ini, &tv)) { XCTAssertEqual($0 as? PasskeyInitiator.Failure, .peerProofInvalid) }
        XCTAssertNil(ini.pairingKey)
    }

    /// Araya giren her iki uçla ayrı ECDH yapar. Mac'in taahhüdünü TV'ye aktarmak işe yaramaz
    /// (taahhüt anahtarı oturuma özgü); PIN'i bilmeden TV'yi geçmek her tur için bir bit tahmini ister.
    func testMitmCannotRelayCommitmentsOrSkipGuessing() throws {
        let passkey: UInt32 = 555_555
        var mac = PasskeyInitiator(passkey: passkey)
        var tv = TestResponder(passkey: passkey)
        var attackerToMac = TestResponder(passkey: 0)            // Mac'e TV gibi görünür, PIN'i bilmez
        let attackerKey = P256.KeyAgreement.PrivateKey()
        let attackerToTv = PasskeyInitiator(passkey: 0, privateKey: attackerKey)

        // Anahtar değişimi iki ayrı oturum.
        var macMsg = mac.initMessage
        var fromMac = try attackerToMac.handle(macMsg)
        macMsg = try mac.handle(fromMac)!                        // Mac'in tur 0 taahhüdü (oturum 1)
        _ = try tv.handle(attackerToTv.initMessage)
        // Saldırgan Mac'in taahhüdünü olduğu gibi TV'ye aktarır.
        _ = try tv.handle(macMsg)
        fromMac = try attackerToMac.handle(macMsg)
        let macOpen = try mac.handle(fromMac)!                   // Mac açılışı saldırgana verir
        XCTAssertThrowsError(try tv.handle(macOpen)) { XCTAssertEqual(($0 as? TestResponder.Reject)?.reason, "pin_mismatch") }
        XCTAssertNil(tv.key)
    }

    func testRejectsInvalidAndReflectedPeerKeys() throws {
        var ini = PasskeyInitiator(passkey: 1)
        var bad = Data(repeating: 0, count: 65); bad[0] = 4
        XCTAssertThrowsError(try ini.handle(["t": "pair_key", "pk": bad.base64EncodedString()])) {
            XCTAssertEqual($0 as? PasskeyInitiator.Failure, .badPeerKey)
        }
        var ini2 = PasskeyInitiator(passkey: 1)
        XCTAssertThrowsError(try ini2.handle(["t": "pair_key", "pk": ini2.pkMac.base64EncodedString()])) {
            XCTAssertEqual($0 as? PasskeyInitiator.Failure, .badPeerKey)
        }
    }

    func testCommitmentBindsBitRoleAndRound() {
        let kc = Data(repeating: 7, count: 32), n = Data(repeating: 9, count: 16)
        let c = PairingCrypto.commitment(kc, .mac, round: 4, bit: 1, nonce: n)
        XCTAssertNotEqual(c, PairingCrypto.commitment(kc, .mac, round: 4, bit: 0, nonce: n))
        XCTAssertNotEqual(c, PairingCrypto.commitment(kc, .tv, round: 4, bit: 1, nonce: n))
        XCTAssertNotEqual(c, PairingCrypto.commitment(kc, .mac, round: 5, bit: 1, nonce: n))
        XCTAssertNotEqual(c, PairingCrypto.commitment(Data(repeating: 8, count: 32), .mac, round: 4, bit: 1, nonce: n))
    }

    func testSessionProofsAreDomainSeparated() {
        let k = Data(repeating: 1, count: 32), a = V.nonceTv, b = V.nonceMac
        let proofs = [
            PairingCrypto.sessionProof(k, .control, .mac, serverNonce: a, clientNonce: b),
            PairingCrypto.sessionProof(k, .control, .tv, serverNonce: a, clientNonce: b),
            PairingCrypto.sessionProof(k, .reverse, .mac, serverNonce: a, clientNonce: b),
            PairingCrypto.sessionProof(k, .reverse, .tv, serverNonce: a, clientNonce: b),
        ]
        XCTAssertEqual(Set(proofs).count, 4)
    }

    func testPasskeyParsing() {
        XCTAssertEqual(PairingCrypto.passkey(from: "012345"), 12345)
        XCTAssertEqual(PairingCrypto.passkey(from: "999999"), 999_999)
        XCTAssertNil(PairingCrypto.passkey(from: "12345"))
        XCTAssertNil(PairingCrypto.passkey(from: "1234567"))
        XCTAssertNil(PairingCrypto.passkey(from: "12a456"))
        XCTAssertNil(PairingCrypto.passkey(from: "１２３４５６"))      // tam genişlikli rakam kabul edilmez
        XCTAssertEqual(PairingCrypto.bit(999_999, 19), 1)      // 999999 ≥ 2¹⁹: 20 tur gerekir
        XCTAssertEqual(PairingCrypto.bit(524_287, 19), 0)
        XCTAssertEqual(PairingCrypto.bit(1 << 19, 19), 1)
    }

    func testDeniedRepliesMapToFailures() {
        var a = PasskeyInitiator(passkey: 1)
        XCTAssertThrowsError(try a.handle(["t": "denied", "reason": "locked", "retry_after_ms": 30000])) {
            XCTAssertEqual($0 as? PasskeyInitiator.Failure, .locked(retryAfterMs: 30000))
        }
        var b = PasskeyInitiator(passkey: 1)
        XCTAssertThrowsError(try b.handle(["t": "pk_open", "i": 0, "n": ""])) {
            XCTAssertEqual($0 as? PasskeyInitiator.Failure, .unexpected("pk_open"))
        }
    }
}
