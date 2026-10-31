// PaneCast — Windows yayıncısı: TV'nin başlattığı yönün sunucusu (SenderServer.swift birebir
// karşılığı). TCP 7610'dan gelen bağlantıyı eşleşme anahtarıyla karşılıklı doğrular, `resume`
// isteğinde yayın motorunu o TV'ye kaldırır; `start`/`stopped`/`ping` mesajlarını sağlar.
//
// Mac'ten farklar (platform tuzağı, ölçülmediyse POSIX kuralı):
//  - SO_REUSEADDR yerine SO_EXCLUSIVEADDRUSE: Windows'ta SO_REUSEADDR kaba db port gaspına
//    izin verir; dinleyici bizim olsun diye yalnız bu seçenekle kurulur.
//  - SO_RCVTIMEO Windows'ta timeval değil DWORD milisaniye alır (Unix'ten farklı).
//  - Soketi yalnız okuma iş parçacığı kapatır: başka iş parçacığından closesocket, bloktaki
//    recv'i uyanık bırakıp tanıtıcıyı yeniden kullanılabilir yapabilir → önce shutdown(SD_BOTH).
#include "SenderServer.h"

#include "Host.h"
#include "KeyStore.h"
#include "Net.h"
#include "Pairing.h"

#include <chrono>

namespace atvm {
namespace {

std::string Wsa(const char* what) {
    char buf[80];
    snprintf(buf, sizeof(buf), "%s (WSA %d)", what, WSAGetLastError());
    return buf;
}

long long EpochMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
}

/// Eşleşme anahtarı: testler DPAPI deposuna dokunmadan kendi `keyFor`'unu verir (Mac init(keyFor:)).
bool FetchKey(const SenderServer* srv, const std::string& host, Bytes& out) {
    if (srv->keyFor) return srv->keyFor(host, out);
    return KeyStore::KeyFor(host, out);
}

}  // namespace

// --- TvSession ---------------------------------------------------------------

TvSession::TvSession(SenderServer* owner, SOCKET sock, std::string peerHost)
    : owner_(owner), sock_(sock), host_(peerHost) {}

TvSession::~TvSession() { CloseSocket(); }

void TvSession::SetRecvTimeout(int ms) {
    // Windows: bu seçenek DWORD milisaniye alır (timeval değil, ölçülü unix farkı).
    const DWORD v = static_cast<DWORD>(ms);
    setsockopt(sock_, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&v), sizeof(v));
}

void TvSession::CloseSocket() {
    SOCKET s = sock_;
    if (s == INVALID_SOCKET) { closed_ = true; return; }
    sock_ = INVALID_SOCKET;
    shutdown(s, SD_BOTH);
    closesocket(s);
    closed_ = true;
}

void TvSession::Shutdown() {
    const bool first = !closed_.exchange(true);
    // Kapatmayı okuyucu yapar; burada yalnız uyanık bırakan shutdown gelir (bkz. dosya üstü not).
    if (first && sock_ != INVALID_SOCKET) shutdown(sock_, SD_BOTH);
    {
        std::lock_guard<std::mutex> lk(startMu_);
        if (startPending_) { startPending_ = false; startResult_ = false; }
        startCv_.notify_all();
    }
}

void TvSession::ReaderLoop() {
    SetRecvTimeout(kPreAuthTimeoutMs);
    char buf[4096];
    bool drop = false;
    for (;;) {
        const int n = recv(sock_, buf, sizeof(buf), 0);
        if (n <= 0) break;                       // kapanış, hata ya da SO_RCVTIMEO
        recv_.append(buf, static_cast<size_t>(n));
        size_t pos;
        while ((pos = recv_.find('\n')) != std::string::npos) {
            std::string line = recv_.substr(0, pos);
            recv_.erase(0, pos + 1);
            if (!line.empty() && line.back() == '\r') line.pop_back();
            // §3: satır sonu gelmeden yığılan istemci belleği şişiremez → bağlantı düşer.
            if (line.size() > kMaxLineBytes) { drop = true; break; }
            auto m = ParseFlatJson(line);
            if (m) Route(*m);
        }
        if (drop || recv_.size() > kMaxLineBytes) break;
    }
    CloseSocket();                               // soketi okuyucu kapatır
    {
        std::lock_guard<std::mutex> lk(startMu_);
        if (startPending_) { startPending_ = false; startResult_ = false; }
        startCv_.notify_all();
    }
}

bool TvSession::Send(const JsonObject& obj) {
    std::string wire = obj.dump();
    wire.push_back('\n');
    std::lock_guard<std::mutex> lk(writeMu_);
    if (closed_ || sock_ == INVALID_SOCKET) return false;
    size_t off = 0;
    while (off < wire.size()) {
        const int n = send(sock_, wire.data() + off, static_cast<int>(wire.size() - off), 0);
        if (n <= 0) return false;
        off += static_cast<size_t>(n);
    }
    return true;
}

void TvSession::Reject(const std::string& reason) {
    JsonObject d;
    d.set("t", std::string("denied"));
    d.set("reason", reason);
    Send(d);
}

bool TvSession::AnnounceStart(const StartInfo& info, int timeoutMs) {
    if (!ready_) return false;
    JsonObject o;
    o.set("t", std::string("start"));
    o.set("width", static_cast<long long>(info.width));
    o.set("height", static_cast<long long>(info.height));
    o.set("fps", static_cast<long long>(info.fps));
    o.set("bitrate", info.bitrate);
    o.set("ssrc", info.ssrc);
    o.set("media_port", static_cast<long long>(info.mediaPort));
    o.set("payload_type", static_cast<long long>(info.payloadType));
    o.set("audio_ssrc", info.audioSsrc);
    o.set("audio_payload_type", static_cast<long long>(info.audioPayloadType));
    o.set("audio_sample_rate", static_cast<long long>(info.audioSampleRate));
    o.set("audio_channels", static_cast<long long>(info.audioChannels));
    // §5.1: iki akış aynı RTP tabanına bağlıysa 1 (Mac aynı alanı sayı 1 olarak yazar).
    o.set("sync", info.sync ? 1LL : 0LL);
    o.set("video_rtp_base", static_cast<long long>(info.videoRtpBase));
    o.set("audio_rtp_base", static_cast<long long>(info.audioRtpBase));

    {
        std::lock_guard<std::mutex> lk(startMu_);
        startPending_ = true;
        startResult_ = false;
    }
    if (!Send(o)) {
        std::lock_guard<std::mutex> lk(startMu_);
        startPending_ = false;
        return false;
    }
    bool ok = false;
    {
        std::unique_lock<std::mutex> lk(startMu_);
        // Okuyucu `started`/`cap_error` gelir ya da bağlantı eskir.
        startCv_.wait_for(lk, std::chrono::milliseconds(timeoutMs),
                          [&] { return !startPending_ || closed_.load(); });
        ok = startResult_;
        startPending_ = false;
    }
    return ok;
}

bool TvSession::Route(const FlatJson& m) {
    const std::string t = m.str("t");
    // Mac'te `ping` durumdan bağımsız geçerli (case ("ping", _)).
    if (t == "ping") {
        JsonObject pong;
        pong.set("t", std::string("pong"));
        pong.set("now", EpochMs());
        Send(pong);
        return true;
    }

    switch (state_) {
    case State::Idle:
        if (t == "hello") {
            name_ = m.str("name");
            if (name_.empty()) name_ = "?";
            const long long ver = m.num("ver", 0);
            if (ver != PairingConst::kVersion) {
                JsonObject d;
                d.set("t", std::string("denied"));
                d.set("reason", std::string("version"));
                d.set("ver", static_cast<long long>(PairingConst::kVersion));
                Send(d);
                owner_->Log("TV farklı protokol sürümünde: " + name_ + " (" + host_ + ") v" +
                            std::to_string(ver) + " — TV uygulamasını güncelleyin");
                CloseSocket();
                return true;
            }
            Bytes key;
            if (!FetchKey(owner_, host_, key)) {
                JsonObject d;
                d.set("t", std::string("denied"));
                d.set("reason", std::string("not_paired"));
                d.set("ver", static_cast<long long>(PairingConst::kVersion));
                d.set("hint", std::string("önce bu bilgisayar ile eşleşin"));
                Send(d);
                owner_->Log("bilinmeyen TV isteği: " + name_ + " (" + host_ + ") — eşleşme kaydı yok");
                CloseSocket();
                return true;
            }
            state_ = State::Challenged;
            nonce_ = RandomBytes(PairingConst::kNonceBytes);
            JsonObject c;
            c.set("t", std::string("challenge"));
            c.set("nonce_mac", B64Encode(nonce_));
            c.set("ver", static_cast<long long>(PairingConst::kVersion));
            Send(c);
            return true;
        }
        break;

    case State::Challenged:
        if (t == "proof") {
            const Bytes nonceTv = B64Decode(m.str("nonce_tv"));
            const Bytes got = B64Decode(m.str("proof"));
            Bytes key;
            const bool keyOk = FetchKey(owner_, host_, key);
            const Bytes expect = keyOk ? SessionProof(key, Channel::Reverse, Role::Tv, nonce_, nonceTv)
                                       : Bytes{};
            const bool ok = keyOk && nonceTv.size() == PairingConst::kNonceBytes &&
                            ConstantTimeEqual(got, expect);
            if (!ok) {
                owner_->Log("TV kanıtı doğrulanamadı: " + name_ + " (" + host_ +
                            ") keyOk=" + std::to_string(keyOk ? 1 : 0) +
                            " keyLen=" + std::to_string(keyOk ? static_cast<int>(key.size()) : 0) +
                            " nonceMac=" + B64Encode(nonce_) +
                            " nonceTv=" + B64Encode(nonceTv) +
                            " gotLen=" + std::to_string(got.size()) +
                            " want=" + B64Encode(expect.size() > 32 ? Bytes() : expect) +
                            " got=" + B64Encode(got.size() > 32 ? Bytes() : got));
                JsonObject d;
                d.set("t", std::string("denied"));
                d.set("reason", std::string("auth_failed"));
                Send(d);
                state_ = State::Idle;
                CloseSocket();
                return true;
            }
            state_ = State::Ready;
            ready_ = true;
            SetRecvTimeout(0);                   // doğrulanmış oturum süresiz sessiz kalabilir
            KeyStore::StoreName(name_, host_);   // arayüz listesi TV adını böylece öğrenir
            JsonObject r;
            r.set("t", std::string("ready"));
            r.set("proof", B64Encode(SessionProof(key, Channel::Reverse, Role::Mac,
                                                  nonce_, nonceTv)));
            Send(r);
            owner_->Log("TV yayın istedi: " + name_ + " (" + host_ + ")");
            return true;
        }
        break;

    case State::Ready:
        if (t == "resume") {
            mediaHost_ = m.str("media_host");
            mediaPort_ = static_cast<uint16_t>(m.num("media_port", 7602));
            owner_->Log("yayın istendi → " + mediaHost() + ":" + std::to_string(mediaPort_) +
                        "; pencere hazırlanıyor");
            if (owner_->onResume) {
                // shared_ptr'i vektörden buluruz: okuyucu, nesnesini yaşatmak zorunda.
                std::shared_ptr<TvSession> self;
                {
                    std::lock_guard<std::mutex> lk(owner_->mu_);
                    for (const auto& sp : owner_->sessions_)
                        if (sp.get() == this) { self = sp; break; }
                }
                if (self) owner_->onResume(self);
            }
            return true;
        }
        if (t == "started") {
            std::lock_guard<std::mutex> lk(startMu_);
            startPending_ = false;
            startResult_ = true;
            startCv_.notify_all();
            owner_->Log("TV akışı kabul etti: " + host_);
            return true;
        }
        if (t == "cap_error") {
            std::lock_guard<std::mutex> lk(startMu_);
            startPending_ = false;
            startResult_ = false;
            startCv_.notify_all();
            owner_->Log("TV akışı açamadı (" + host_ + "): " + m.str("reason"));
            return true;
        }
        if (t == "idr_request") {
            if (owner_->onIdrRequest) owner_->onIdrRequest(host_);
            return true;
        }
        if (t == "stop") {
            JsonObject st;
            st.set("t", std::string("stopped"));
            Send(st);
            if (owner_->onTvStop) owner_->onTvStop(host_);
            owner_->Log("TV yayını durdurdu");
            return true;
        }
        if (t == "stopped") {
            // TV yayını kendi başına kesti (kumanda, yüzey kaybı, çözücü hatası). Yanıt yok.
            if (owner_->onTvStop) owner_->onTvStop(host_);
            owner_->Log("TV yayını durdurdu: " + m.str("reason"));
            return true;
        }
        break;
    }

    JsonObject d;
    d.set("t", std::string("denied"));
    d.set("reason", std::string("unexpected_message"));
    d.set("gelen", t.empty() ? "?" : t);
    Send(d);
    return true;
}

// --- SenderServer ------------------------------------------------------------

SenderServer::~SenderServer() {
    if (running_) Stop();
}

void SenderServer::Log(const std::string& line) {
    if (onLog) onLog(line);
}

bool SenderServer::Start(uint16_t port, bool advertise) {
    if (running_) return true;
    error_.clear();
    EnsureWinsock();

    const SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) {
        error_ = Wsa("dinleyici soketi açılamadı");
        Log(error_);
        return false;
    }
    // DOSYANIN üstündeki not: SO_REUSEADDR Windows'ta port gaspına açar; kilit burada.
    const BOOL exclusif = TRUE;
    setsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<const char*>(&exclusif),
               sizeof(exclusif));
    sockaddr_in a = {};
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(s, reinterpret_cast<sockaddr*>(&a), sizeof(a)) != 0) {
        error_ = Wsa("port bağlanamadı — kullanımda olabilir");
        closesocket(s);
        Log(error_);
        return false;
    }
    if (listen(s, 8) != 0) {
        error_ = Wsa("listen başarısız");
        closesocket(s);
        Log(error_);
        return false;
    }
    listener_ = s;
    port_ = port;
    running_ = true;
    acceptThread_ = std::thread([this] { AcceptLoop(); });

    if (advertise) {
        if (registrar_.Publish("ATVM-" + HostName(), port)) {
            Log("bu bilgisayar TV'ye açık: ATVM-" + HostName() + " :" + std::to_string(port) +
                " — TV'den seçilebilir");
        } else {
            Log("mDNS kaydı başarısız: " + registrar_.lastError() +
                " (dinleyici yine de dinliyor)");
        }
    }
    return true;
}

void SenderServer::AcceptLoop() {
    for (;;) {
        sockaddr_in peer = {};
        int len = sizeof(peer);
        const SOCKET cfd = accept(listener_, reinterpret_cast<sockaddr*>(&peer), &len);
        if (cfd == INVALID_SOCKET) return;       // listener kapatıldı ya da hata
        const int nodelay = 1;                   // satır denetimi gecikmesiz gitsin (Mac aynısı)
        setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&nodelay),
                   sizeof(nodelay));
        char ip[INET_ADDRSTRLEN] = {};
        std::string host;
        if (inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof(ip))) host = ip;

        auto s = std::make_shared<TvSession>(this, cfd, host);
        {
            std::lock_guard<std::mutex> lk(mu_);
            sessions_.push_back(s);
        }
        SenderServer* owner = this;
        // Okuyucu, oturumu kendi shared örneğiyle yaşatır; bitişte kendini listeden çıkarır.
        std::thread([owner, self = std::move(s)]() mutable {
            self->ReaderLoop();
            owner->SessionEnded(self);
        }).detach();
    }
}

void SenderServer::Forget(const std::shared_ptr<TvSession>& s) {
    std::lock_guard<std::mutex> lk(mu_);
    for (auto it = sessions_.begin(); it != sessions_.end(); ++it)
        if (it->get() == s.get()) { sessions_.erase(it); break; }
}

void SenderServer::SessionEnded(const std::shared_ptr<TvSession>& s) {
    Forget(s);
    drained_.notify_all();
    // Doğrulanmış TV bağlantısı kapandı → izleyici yok, yayın da durmalı. SenderServer.swift'te
    // ölçülen kusur: bu bildirimin yokluğunda yayın kopuk bağlantıya 20+ sn daha aktı.
    // Doğrulanmamış bir bağlantının kapanışı yayına dokunmaz: ağdaki herkes durduramasın.
    if (s->ready_) {
        Log("TV bağlantısı kapandı: " + s->host_);
        if (onTvStop) onTvStop(s->host_);
    }
}

void SenderServer::Stop() {
    registrar_.Stop();
    running_ = false;
    if (listener_ != INVALID_SOCKET) {
        closesocket(listener_);
        listener_ = INVALID_SOCKET;
    }
    if (acceptThread_.joinable()) acceptThread_.join();

    std::vector<std::shared_ptr<TvSession>> snapshot;
    {
        std::lock_guard<std::mutex> lk(mu_);
        snapshot = sessions_;
    }
    for (auto& s : snapshot) s->Shutdown();
    // Detached okuyucular kendini listeden çıkarana dek sınırlı bekleriz: süre dolmuştursa
    // vektörde kalan oturumu ~SenderServer yıkar — okuyucusu Shutdown'la hâlâ uyanmadıysa
    // (pratikte ms mertebesi) kalan olasılık doğrultusunda imkânsız kabul edilir.
    {
        std::unique_lock<std::mutex> lk(mu_);
        drained_.wait_for(lk, std::chrono::milliseconds(3000), [&] { return sessions_.empty(); });
    }
}

}  // namespace atvm
