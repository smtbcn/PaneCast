import Foundation

/// Yakalamanın sessizce durmasını izleyen saf durum makinesi.
/// ScreenCaptureKit ayrı Space'teki tam ekran pencerede hata üretmeden susabiliyor
/// (ölçülen kusur: YouTube tam ekranda, kullanıcı başka uygulamaya geçince TV'de görüntü donuyor,
/// iki tarafta da hata yok). `didStopWithError` yalnız gerçek hatada geldiği için tek işaret
/// kare sayacının hareket etmemesidir.
struct StallGuard {
    /// Bu kadar saniye yeni kare gelmezse yakalamayı bir kez yeniden kur.
    static let quietLimit: TimeInterval = 2
    /// Yeniden kurmadan sonra bu kadar saniye de geçerse vazgeçmiş say ve kullanıcıya söyle.
    static let giveUpLimit: TimeInterval = 6

    enum Event {
        /// Sayacı tekrar hareket etti; önceki sıkışma geçti.
        case resumed
        /// Eşiği aştık: tek yeniden kurma denemesi zamanı.
        case retry
        /// Denemeye rağmen hâlâ kare yok.
        case stalled
    }

    private var lastFrames = -1
    private var lastMove = Date.distantPast
    private var retried = false

    /// `delivered` = WindowCapture.framesDelivered (monoton artan sayaç).
    /// Söyleyecek bir şey yoksa nil döner; böylece çağıran her saniye log basmaz.
    mutating func observe(_ delivered: Int, now: Date) -> Event? {
        if delivered != lastFrames {
            lastFrames = delivered
            lastMove = now
            let hadRetried = retried
            retried = false
            return hadRetried ? .resumed : nil
        }
        let quiet = now.timeIntervalSince(lastMove)
        if !retried {
            guard quiet >= Self.quietLimit else { return nil }
            // Deneme hakkını harca: aksi halde her saniye yeniden kurma tetiklenir.
            retried = true
            return .retry
        }
        return quiet >= Self.giveUpLimit ? .stalled : nil
    }
}
