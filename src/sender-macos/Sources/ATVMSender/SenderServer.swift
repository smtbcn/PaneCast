import Foundation
import Network

/// Mac'i TV'nin seçebileceği hale getirir:
///  - `_atvm-sender._tcp` yayımlar (TV bu listeden bilgisayarı seçer)
///  - TCP 7610'da TV'den gelen kontrol bağlantısını eşleşme anahtarıyla karşılıklı doğrular
///  - `resume` isterse yayını o TV'ye başlatır
@MainActor
final class SenderServer {
    static let serviceType = "_atvm-sender._tcp"
    static let defaultPort: UInt16 = 7610

    var onLog: ((String) -> Void)?
    /// TV bu bilgisayarı seçti ve doğrulandı; yayın motoru bu oturumu başlatır.
    var onResume: ((SenderServer.TvSession) -> Void)?
    var onIdrRequest: ((String) -> Void)?
    var onTvStop: ((String) -> Void)?

    private let listener = Tcp4Listener()
    private var bonjour: NetService?
    /// TV host'u → eşleşme anahtarı (testler Anahtar Zinciri'ne dokunmadan verir).
    private let keyFor: (String) -> Data?

    init(keyFor: @escaping (String) -> Data? = { KeyStore.key(for: $0) }) { self.keyFor = keyFor }
    private var pendingStart: [ObjectIdentifier: CheckedContinuation<Bool, Never>] = [:]
    /// TV'nin kendi açtığı, hâlâ açık olan bağlantılar (yayın bittiğinde bildirim için).
    private var liveSessions: [String: TvSession] = [:]

    /// Doğrulanmış TV bağlantısı: `start` bu sokete yazılır, IDR/stop oradan gelir.
    struct TvSession {
        let conn: Tcp4Connection
        let host: String
        let name: String
        let mediaHost: String
        let mediaPort: UInt16

        /// Yayın açılamayınca TV'ye gerekçe bildirilir; boşuna akış beklenmez.
        func reject(_ reason: String) { conn.send(["t": "denied", "reason": reason]) }
    }

    func start(port: UInt16 = SenderServer.defaultPort, advertise: Bool = true) {
        do { try listener.start(port: port) }
        catch { onLog?("TV'nin seçebileceği dinleyici açılamadı: \(error)"); return }

        listener.onClient = { [weak self] conn in
            guard let self else { return }
            Task { @MainActor in
                var state = State.idle
                for await msg in conn.messages() { self.route(msg, conn, &state) }
                self.connectionClosed(conn)
                // Doğrulanmış TV bağlantısı kapandı → izleyici yok, yayın da durmalı (ölçüldü:
                // bu satır olmadan pencere yayını kopuk bağlantıya 20+ sn daha aktı). Doğrulanmamış
                // bir bağlantının kapanması yayına dokunmaz: ağdaki herhangi biri yayını kesemesin.
                if case .ready = state { self.onTvStop?(conn.peerHost) }
            }
        }
        guard advertise else { return }
        let ns = NetService(domain: "local.", type: Self.serviceType,
                            name: "ATVM-" + HostName.current, port: Int32(port))
        ns.publish()
        bonjour = ns
        onLog?("bu bilgisayar TV'ye açık: \(HostName.current) :\(port) — TV'den seçilebilir")
    }

    func stop() {
        bonjour?.stop(); bonjour = nil; listener.stop()
        pendingStart.values.forEach { $0.resume(returning: false) }
        pendingStart.removeAll()
    }

    private enum State {
        case idle
        case challenged(nonce: Data, host: String, name: String)
        case ready(host: String, name: String)
    }

    private func route(_ m: [String: Any], _ conn: Tcp4Connection, _ state: inout State) {
        let t = m["t"] as? String ?? ""
        switch (t, state) {

        case ("hello", .idle):
            let host = conn.peerHost
            let name = m["name"] as? String ?? "?"
            guard m["ver"] as? Int == PairingCrypto.version else {
                conn.send(["t": "denied", "reason": "version", "ver": PairingCrypto.version])
                onLog?("TV farklı protokol sürümünde: \(name) (\(host)) v\(m["ver"] as? Int ?? 0) — TV uygulamasını güncelleyin")
                conn.close()
                return
            }
            guard keyFor(host) != nil else {
                conn.send(["t": "denied", "reason": "not_paired", "ver": PairingCrypto.version,
                           "hint": "önce Mac'ten bu TV ile eşleşin"])
                onLog?("bilinmeyen TV isteği: \(name) (\(host)) — eşleşme kaydı yok")
                conn.close()
                return
            }
            let nonce = PairingCrypto.randomNonce()
            state = .challenged(nonce: nonce, host: host, name: name)
            conn.send(["t": "challenge", "nonce_mac": nonce.base64EncodedString(), "ver": PairingCrypto.version])

        case ("proof", .challenged(let nonce, let host, let name)):
            let nonceTv = Data(base64Encoded: m["nonce_tv"] as? String ?? "") ?? Data()
            let got = Data(base64Encoded: m["proof"] as? String ?? "") ?? Data()
            guard let key = keyFor(host), nonceTv.count == PairingCrypto.nonceBytes,
                  PairingCrypto.equal(got, PairingCrypto.sessionProof(key, .reverse, .tv,
                                                                      serverNonce: nonce, clientNonce: nonceTv)) else {
                conn.send(["t": "denied", "reason": "auth_failed"])
                onLog?("TV kanıtı doğrulanamadı: \(name) (\(host))")
                state = .idle
                conn.close()
                return
            }
            state = .ready(host: host, name: name)
            conn.authenticated()
            KeyStore.storeName(name, for: host)     // arayüz listesi TV adını böylece öğrenir
            conn.send(["t": "ready", "proof": PairingCrypto.sessionProof(
                key, .reverse, .mac, serverNonce: nonce, clientNonce: nonceTv).base64EncodedString()])
            onLog?("TV yayın istedi: \(name) (\(host))")

        case ("resume", .ready(let host, let name)):
            let mp = UInt16((m["media_port"] as? Int) ?? 7602) ?? 7602
            let tvHost = (m["media_host"] as? String) ?? host
            onLog?("yayın istendi → \(tvHost):\(mp); pencere hazırlanıyor")
            let session = TvSession(conn: conn, host: host, name: name, mediaHost: tvHost, mediaPort: mp)
            liveSessions[host] = session
            onResume?(session)

        case ("started", .ready(let host, _)):
            replyStart(conn, ok: true)
            onLog?("TV akışı kabul etti: \(host)")

        case ("cap_error", .ready(let host, _)):
            replyStart(conn, ok: false)
            onLog?("TV akışı açamadı (\(host)): \(m["reason"] as? String ?? "?")")

        case ("idr_request", .ready(let host, _)):
            onIdrRequest?(host)

        case ("stop", .ready(let host, _)):
            conn.send(["t": "stopped"])
            onTvStop?(host)
            onLog?("TV yayını durdurdu")

        // TV yayını **kendi başına** kesti (kumandadan DURDUR, yüzey kaybı, çözücü hatası).
        // Ölçülen kusur: bu mesaj hiç gelmediği için Mac "Yayında" etiketiyle pencereyi ağa
        // yazmayı sürdürüyordu. Yanıt beklenmez; bağlantı açık, yayın kapanır.
        case ("stopped", .ready(let host, _)):
            onTvStop?(host)
            onLog?("TV yayını durdurdu: \(m["reason"] as? String ?? "bildirim yok")")

        case ("ping", _):
            conn.send(["t": "pong", "now": Int(Date().timeIntervalSince1970 * 1000)])

        default:
            conn.send(["t": "denied", "reason": "unexpected_message", "gelen": m["t"] ?? "?"])
        }
    }

    /// Akış parametrelerini TV'nin kendi bağlantısına yazar ve `started`/`cap_error`
    /// yanıtını bekler. Bağlantı kapanırsa false döner — bekleyen istek askıda kalmaz.
    func announceStart(_ session: TvSession, _ info: MirrorEngine.StartInfo) async -> Bool {
        await withCheckedContinuation { cont in
            pendingStart[ObjectIdentifier(session.conn)] = cont
            session.conn.send(["t": "start", "width": info.width, "height": info.height,
                               "fps": info.fps, "bitrate": info.bitrate, "ssrc": info.ssrc,
                               "media_port": info.mediaPort, "payload_type": info.payloadType,
                               "audio_ssrc": info.audioSsrc, "audio_payload_type": info.audioPayloadType,
                               "audio_sample_rate": info.audioSampleRate, "audio_channels": info.audioChannels,
                               "sync": 1, "video_rtp_base": info.videoRtpBase, "audio_rtp_base": info.audioRtpBase])
        }
    }

    /// Mac yayını kendisi bitirdiğinde TV'nin listeye dönmesi için aynı bağlantıya yazılır.
    func notifyStopped(host: String, reason: String = "sender_stop") {
        guard let session = liveSessions[host] else { return }
        session.conn.send(["t": "stopped", "reason": reason])
        onLog?("TV'ye durdurma bildirildi: \(host)")
    }

    private func replyStart(_ conn: Tcp4Connection, ok: Bool) {
        pendingStart.removeValue(forKey: ObjectIdentifier(conn))?.resume(returning: ok)
    }

    private func connectionClosed(_ conn: Tcp4Connection) {
        replyStart(conn, ok: false)
        if liveSessions[conn.peerHost]?.conn === conn { liveSessions[conn.peerHost] = nil }
    }
}
