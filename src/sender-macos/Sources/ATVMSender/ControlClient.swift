import Foundation
import Network
import Security

/// TV ile eşleşme ve kontrol kanalı (TCP, satır başına JSON).
/// Eşleştirme: PasskeyInitiator (Pairing.swift) — PIN yalnız TV ekranında, ağdan geçmez.
/// Yeniden bağlantı: TV'nin ve Mac'in nonce'ları üzerinden karşılıklı HMAC kanıtı.
final class ControlClient: @unchecked Sendable {
    /// Bir satırın üst sınırı: sınırı aşan karşı uç bağlantıyı belleği şişirerek tutamaz.
    static let maxLineBytes = 8192
    enum ControlError: Error, CustomStringConvertible {
        case notConnected, protocolError(String), pairingDenied(String), timeout
        case version(tv: Int?), badPinFormat, pinRejected, locked(seconds: Int)
        case peerNotAuthentic, keychain(OSStatus)
        var description: String {
            switch self {
            case .notConnected: return "kontrol kanalı bağlı değil"
            case .protocolError(let m): return "protokol hatası: \(m)"
            case .pairingDenied(let r): return "eşleşme reddedildi: \(r)"
            case .timeout: return "zaman aşımı"
            case .version(let tv):
                return "TV uygulaması farklı protokol sürümünde (TV v\(tv.map(String.init) ?? "1"), "
                    + "Mac v\(PairingCrypto.version)): iki ucu da güncelleyin"
            case .badPinFormat: return "PIN 6 rakam olmalı"
            case .pinRejected: return "PIN tutmadı — TV'de görünen YENİ kodu girin"
            case .locked(let s): return "çok fazla hatalı deneme: TV \(s) sn kilitli"
            case .peerNotAuthentic:
                return "karşı taraf TV'nin kanıtını veremedi (yanlış cihaz ya da araya giren olabilir); eşleşme kaydedilmedi"
            case .keychain(let s): return "anahtar Anahtar Zinciri'ne yazılamadı (OSStatus \(s))"
            }
        }
    }

    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "atvm.control")
    private var buffer = Data()

    /// TV'den gelen idr_request gibi mesajlar için geri çağırma.
    var onMessage: (([String: Any]) -> Void)?
    private(set) var sessionId: String?
    private(set) var paired = false

    init(host: String, port: UInt16 = 7601) {
        self.host = host; self.port = port
    }

    // ---------- bağlantı ----------

    /// TCP bağlantısı. **Zaman aşımı zorunlu**: TV'nin kontrol sunucusu tek oturumlu ve kabul
    /// döngüsü yayındayken meşgul; yeni bağlantı `.waiting` durumunda süresiz bekleyebiliyor
    /// (ölçüldü: "Eşleştirmeyi unut" yayın sürerken hiçbir şey yapmadan asılı kalıyordu —
    /// `beginHello`'nun 8 sn zaman aşımı hiç devreye giremiyordu).
    func connect(timeout: TimeInterval = 8) async throws {
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: .tcp)
        connection = conn
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var done = false
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !done { done = true; conn.stateUpdateHandler = nil; cont.resume() }
                case .failed(let e):
                    if !done { done = true; cont.resume(throwing: e) }
                case .cancelled:
                    if !done { done = true; cont.resume(throwing: ControlError.notConnected) }
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if !done {
                    done = true
                    conn.stateUpdateHandler = nil
                    conn.cancel()
                    cont.resume(throwing: ControlError.timeout)
                }
            }
        }
        readLoop()
    }

    func disconnect() { connection?.cancel(); connection = nil }

    private func readLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                while let nl = self.buffer.firstIndex(of: 0x0A) {
                    let line = self.buffer.subdata(in: self.buffer.startIndex..<nl)
                    self.buffer.removeSubrange(self.buffer.startIndex...nl)
                    if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        self.deliver(obj)
                    }
                }
                if self.buffer.count > Self.maxLineBytes { self.disconnect(); return }
            }
            if error != nil || isComplete { return }
            self.readLoop()
        }
    }

    private func deliver(_ msg: [String: Any]) {
        if let s = msg["session"] as? String { sessionId = s }
        onMessage?(msg)
    }

    // ---------- mesaj alışverişi ----------

    func send(_ fields: [String: Any?]) async throws {
        guard let conn = connection else { throw ControlError.notConnected }
        var obj: [String: Any] = [:]
        for (k, v) in fields { if let v { obj[k] = v } }
        let data = try JSONSerialization.data(withJSONObject: obj)
        var line = data
        line.append(0x0A)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: line, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    private func sendObject(_ obj: [String: Any]) async throws {
        try await send(obj.mapValues { Optional($0) })
    }

    // ---------- arayüzün kullandığı iki adımlı el sıkışma ----------

    enum Handshake { case paired, needsPin }

    /// hello gönderir; TV ya zaten eşleşmiş (karşılıklı kanıt otomatik) ya da PIN ister.
    func beginHello() async throws -> Handshake {
        try await send(["t": "hello", "name": HostName.current, "ver": PairingCrypto.version])
        let first = try await expectAny(timeout: 8)
        let t = first["t"] as? String
        // v1 TV sürüm alanı göndermiyordu; yeni mesajlarımızı tanımayıp sessiz kalırdı.
        if (t == "denied" && first["reason"] as? String == "version") || first["ver"] as? Int != PairingCrypto.version {
            throw ControlError.version(tv: first["ver"] as? Int)
        }
        switch t {
        case "pair_required":
            return .needsPin
        case "challenge":
            try await authenticate(first)
            return .paired
        case "denied":
            if first["reason"] as? String == "locked" {
                throw ControlError.locked(seconds: ((first["retry_after_ms"] as? Int) ?? 0) / 1000)
            }
            throw ControlError.pairingDenied(first["reason"] as? String ?? "?")
        default:
            throw ControlError.protocolError("beklenmeyen ilk mesaj: \(first)")
        }
    }

    /// Kayıtlı anahtarla karşılıklı kanıt: önce Mac kanıtlar, TV `ready` içinde kendi kanıtını verir.
    private func authenticate(_ challenge: [String: Any]) async throws {
        guard let nonceTv = (challenge["nonce_tv"] as? String).flatMap({ Data(base64Encoded: $0) }),
              nonceTv.count == PairingCrypto.nonceBytes else { throw ControlError.protocolError("challenge nonce yok") }
        guard let key = KeyStore.key(for: host) else {
            throw ControlError.pairingDenied("TV eşleşmiş ama bu Mac'te anahtarı yok — TV'de BACK ile eşleşmeyi silip yeniden eşleştirin")
        }
        let nonceMac = PairingCrypto.randomNonce()
        let proof = PairingCrypto.sessionProof(key, .control, .mac, serverNonce: nonceTv, clientNonce: nonceMac)
        try await send(["t": "proof", "nonce_mac": nonceMac.base64EncodedString(), "proof": proof.base64EncodedString()])
        let r = try await expectAny(timeout: 8)
        guard (r["t"] as? String) == "ready" else { throw ControlError.pairingDenied(r["reason"] as? String ?? "\(r)") }
        let want = PairingCrypto.sessionProof(key, .control, .tv, serverNonce: nonceTv, clientNonce: nonceMac)
        guard let got = (r["proof"] as? String).flatMap({ Data(base64Encoded: $0) }),
              PairingCrypto.equal(got, want) else { disconnect(); throw ControlError.peerNotAuthentic }
        paired = true
    }

    /// Kullanıcının TV ekranından okuduğu PIN ile eşleştirir. PIN gönderilmez; 20 turluk
    /// taahhüt/açılış alışverişinde yalnız kendi bitlerimizle hesap yapılır.
    func submitPin(_ pin: String) async throws {
        guard let passkey = PairingCrypto.passkey(from: pin.trimmingCharacters(in: .whitespaces)) else {
            throw ControlError.badPinFormat
        }
        var initiator = PasskeyInitiator(passkey: passkey)
        do {
            var next: [String: Any]? = initiator.initMessage
            while let out = next {
                try await sendObject(out)
                next = try initiator.handle(try await expectAny(timeout: 10))
            }
        } catch let f as PasskeyInitiator.Failure {
            let error: ControlError
            switch f {
            case .pinRejected: error = .pinRejected
            case .locked(let ms): error = .locked(seconds: ms / 1000)
            case .denied(let r): error = .pairingDenied(r)
            case .badPeerKey, .peerProofInvalid: error = .peerNotAuthentic
            case .unexpected(let m): error = .protocolError("eşleştirmede beklenmeyen mesaj: \(m)")
            }
            try? await send(["t": "pair_abort"])
            disconnect()
            throw error
        }
        guard let key = initiator.pairingKey else { throw ControlError.protocolError("eşleşme anahtarı yok") }
        let status = KeyStore.store(host: host, key: key)
        guard status == errSecSuccess else {
            try? await send(["t": "unpair"])     // TV tek taraflı eşleşmiş kalmasın
            throw ControlError.keychain(status)
        }
        sessionId = PairingCrypto.fingerprint(key)
        paired = true
    }

    // ---------- CLI akışı ----------

    /// hello → (pair_required → PIN → passkey turları → paired) | (challenge → proof → ready)
    func pairOrAuth(pinProvider: (() -> String?)?) async throws {
        if try await beginHello() == .needsPin {
            try await submitPin(pinProvider?() ?? readPinFromUser())
        }
    }

    private func expectAny(timeout: TimeInterval) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            let lock = NSLock()
            var settled = false
            let previous = onMessage
            onMessage = { msg in
                previous?(msg)
                lock.lock()
                if settled { lock.unlock(); return }
                settled = true
                self.onMessage = previous
                lock.unlock()
                cont.resume(returning: msg)
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                lock.lock()
                if settled { lock.unlock(); return }
                settled = true
                self.onMessage = previous
                lock.unlock()
                cont.resume(throwing: ControlError.timeout)
            }
        }
    }

    func requestStart(_ info: MirrorEngine.StartInfo) async throws {
        try await send(["t": "start", "width": info.width, "height": info.height, "fps": info.fps,
                        "bitrate": info.bitrate, "ssrc": Int(info.ssrc), "media_port": Int(info.mediaPort),
                        "payload_type": Int(info.payloadType),
                        "audio_ssrc": Int(info.audioSsrc), "audio_payload_type": Int(info.audioPayloadType),
                        "audio_sample_rate": info.audioSampleRate, "audio_channels": info.audioChannels,
                        "sync": 1, "video_rtp_base": Int(info.videoRtpBase), "audio_rtp_base": Int(info.audioRtpBase)])
        let r = try await expectAny(timeout: 10)
        let t = r["t"] as? String
        if t == "cap_error" {
            throw ControlError.protocolError("TV kabul etmedi: \(r["reason"] ?? "?") (max \(r["max_width"] ?? "?")x\(r["max_height"] ?? "?"))")
        }
        guard t == "started" else { throw ControlError.protocolError("start yanıtı: \(r)") }
    }

    func stop() async throws { try await send(["t": "stop"]) }
    /// Yalnız doğrulanmış oturumda kabul edilir; TV `stopped/unpaired` ile onaylar.
    func unpair() async throws {
        try await send(["t": "unpair"])
        let r = try await expectAny(timeout: 5)
        guard r["t"] as? String == "stopped" else { throw ControlError.pairingDenied(r["reason"] as? String ?? "\(r)") }
    }

    private func readPinFromUser() -> String {
        FileHandle.standardError.write("TV ekranındaki 6 haneli PIN'i yaz: ".data(using: .utf8)!)
        return readLine(strippingNewline: true) ?? ""
    }
}

enum HostName {
    static var current: String {
        let h = Host.current().localizedName ?? "Mac"
        return h.isEmpty ? "Mac" : h
    }
}
