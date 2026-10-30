// PaneCast — Windows yayıncısı: TV'nin bilgisayarı seçip yayını ORADAN başlatması (§2, §7).
//
// İki işi var, ikisi de Mac'in SenderServer.swift'iyle birebir:
//  1. `_atvm-sender._tcp` kaydını yayımlar (TV'nin "bilgisayar seç" listesi bu taramadır)
//  2. TCP 7610'da TV'den gelen bağlantıyı eşleşme anahtarıyla karşılıklı doğrular ve
//     `resume` isteğinde yayını o TV'ye başlatır
//
// Yalnız IPv4: TV ile konuşan kanal IPv4 olmak zorunda (Mac tarafında ölçüldü: IPv6 yuvası
// TV'nin SYN'lerini sessizce düşürüyordu). Bağlantı başına bir okuyucu iş parçacığı koşar;
// satır çerçevesi ve 8192 bayt tavanı ControlClient ile aynıdır.
#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "Crypto.h"
#include "Discover.h"
#include "Json.h"

namespace atvm {

/// `start` mesajının alanları (alıcıdaki SessionParams.from ile aynı adlar).
struct StartInfo {
    int width = 0;
    int height = 0;
    int fps = 60;
    long long bitrate = 12000000;
    long long ssrc = 0;
    int mediaPort = 7602;
    int payloadType = 96;
    long long audioSsrc = 0;
    int audioPayloadType = -1;
    int audioSampleRate = 48000;
    int audioChannels = 2;
    /// §5.1: iki akışın RTP damgaları aynı köke bağlıysa 1; tabanlar u32.
    bool sync = false;
    uint32_t videoRtpBase = 0;
    uint32_t audioRtpBase = 0;
};

class SenderServer;

/// Doğrulanmış TV bağlantısı: `start` bu sokete yazılır, IDR/stop oradan gelir.
class TvSession {
public:
    static constexpr int kMaxLineBytes = 8192;        // §3 — aşan satır bağlantıyı düşürür
    static constexpr int kPreAuthTimeoutMs = 15000;   // §3 — doğrulanmamış sessiz bağlantı

    TvSession(SenderServer* owner, SOCKET sock, std::string peerHost);
    ~TvSession();
    TvSession(const TvSession&) = delete;
    TvSession& operator=(const TvSession&) = delete;

    const std::string& host() const { return host_; }
    const std::string& name() const { return name_; }
    /// TV'nin `resume` içinde bildirdiği medya hedefi (yoksa bağlantının geldiği adres).
    const std::string& mediaHost() const { return mediaHost_.empty() ? host_ : mediaHost_; }
    uint16_t mediaPort() const { return mediaPort_; }
    bool ready() const { return ready_; }

    bool Send(const JsonObject& obj);
    /// Yayın açılamayınca TV'ye gerekçe bildirilir; boşuna akış beklenmez.
    void Reject(const std::string& reason);

    /// Akış parametrelerini TV'nin kendi bağlantısına yazar, `started`/`cap_error` bekler.
    /// Bağlantı kapanır ya da süre dolarsa false — bekleyen istek askıda kalmaz.
    bool AnnounceStart(const StartInfo& info, int timeoutMs = 8000);

    /// Okuyucuyu uyandırır ve soketi kapatır (Stop ve hata yolları).
    void Shutdown();

private:
    friend class SenderServer;
    void ReaderLoop();
    bool Route(const FlatJson& m);
    void CloseSocket();
    void SetRecvTimeout(int ms);

    SenderServer* owner_;
    SOCKET sock_;
    std::string host_;
    std::string name_;
    std::string mediaHost_;
    uint16_t mediaPort_ = 7602;
    std::string recv_;
    std::mutex writeMu_;
    std::atomic<bool> ready_{false};
    std::atomic<bool> closed_{false};

    // `start` el sıkışması: yanıt okuyucu iş parçacığında gelir, bekleyen yayın iş parçacığı.
    std::mutex startMu_;
    std::condition_variable startCv_;
    bool startPending_ = false;
    bool startResult_ = false;

    // hello → challenge → ready (Mac'teki State enum'u)
    enum class State { Idle, Challenged, Ready };
    State state_ = State::Idle;
    Bytes nonce_;
};

class SenderServer {
public:
    static constexpr uint16_t kDefaultPort = 7610;

    SenderServer() = default;
    ~SenderServer();
    SenderServer(const SenderServer&) = delete;
    SenderServer& operator=(const SenderServer&) = delete;

    /// Geri çağrılar Start'tan ÖNCE kurulmalı (koşarken atama yarışır).
    std::function<void(const std::string&)> onLog;
    /// TV bu bilgisayarı seçti ve doğrulandı; yayın motoru bu oturumu başlatır.
    std::function<void(const std::shared_ptr<TvSession>&)> onResume;
    std::function<void(const std::string& host)> onIdrRequest;
    std::function<void(const std::string& host)> onTvStop;
    /// Eşleşme anahtarı (testler DPAPI deposuna dokunmadan verebilsin).
    std::function<bool(const std::string& host, Bytes& out)> keyFor;

    bool Start(uint16_t port = kDefaultPort, bool advertise = true);
    void Stop();
    bool listening() const { return running_; }
    uint16_t port() const { return port_; }
    const std::string& lastError() const { return error_; }
    /// mDNS kaydı yayında mı (TV listesinde görünmenin koşulu).
    bool advertised() const { return registrar_.active(); }

private:
    friend class TvSession;
    void AcceptLoop();
    void Forget(const std::shared_ptr<TvSession>& s);
    void SessionEnded(const std::shared_ptr<TvSession>& s);
    void Log(const std::string& line);

    SenderRegistrar registrar_;
    SOCKET listener_ = INVALID_SOCKET;
    uint16_t port_ = 0;
    std::atomic<bool> running_{false};
    std::string error_;

    std::thread acceptThread_;
    std::mutex mu_;
    std::vector<std::shared_ptr<TvSession>> sessions_;
    std::condition_variable drained_;
    int live_ = 0;
};

}  // namespace atvm
