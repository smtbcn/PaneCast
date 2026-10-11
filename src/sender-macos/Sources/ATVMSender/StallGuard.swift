import Foundation

/// Yakalamanın sessiz durmasını yorumlayan saf durum makinesi.
///
/// İki girdi şart, çünkü kare sessizliği tek başına iki ayrı anlama geliyor (ölçüldü):
///  - pencere besteleniyor ama kare yok → içerik statik (boş editör, durmuş sayfa); bu arıza DEĞİL,
///    dokunursak sağlıklı yayını batırıyoruz (16:16'da Notlar yayını böyle düştü)
///  - pencere bestelenmiyor (ayrı Space'teki tam ekran, ya da kapatılmış) → görüntü gerçekten donuyor
///
/// Ölçülen ikinci tuzak: pencere ayrı Space'teyken `SCShareableContent(onScreenWindowsOnly: true)`
/// de onu listemez; o anda yeniden kurma denemek "pencere bulunamadı" ile başarısız oluyor.
/// Bu yüzden yoklukta hattа dokunulmaz; deneme yalnızca pencere geri gelip hâlâ kare
/// üretmiyorsa yapılır.
struct StallGuard {
    /// Bu kadar saniye kare gelmezse durumu yorumla.
    static let quietLimit: TimeInterval = 2

    enum Event {
        /// Sessizlik bitti, kareler akıyor.
        case resumed
        /// Pencere görünür değil (ayrı Space / gizli): kullanıcıya söyle, hattı kesme.
        case hidden
        /// Pencere görünür hale geldi ama kare hâlâ yok: tek taze filtre denemesi.
        case retry
        /// Pencere hiç yok (kapatılmış): yayınlanacak şey kalmadı.
        case gone
    }

    private enum Phase { case flowing, hidden, retried }

    private var lastFrames = -1
    private var lastMove = Date.distantPast
    private var phase: Phase = .flowing

    /// Son kare hareketinden bu yana geçen saniye. Çağıran pahalı yoklamayı
    /// yalnızca gerçekten sessizlik başladığında yapabilsin diye dışa açıldı.
    func quietSince(_ now: Date) -> TimeInterval {
        lastFrames < 0 ? .greatestFiniteMagnitude : now.timeIntervalSince(lastMove)
    }

    /// `present`: ScreenCaptureKit'in o anki (aktif Space) listesinde var.
    /// `exists`: WindowServer listesinde hiç değilse hâlâ var (hangi Space'te olduğu önemsiz).
    mutating func observe(frames delivered: Int, present: Bool, exists: Bool, now: Date) -> Event? {
        if delivered != lastFrames {
            lastFrames = delivered
            lastMove = now
            let troubled = phase != .flowing
            phase = .flowing
            return troubled ? .resumed : nil
        }
        guard now.timeIntervalSince(lastMove) >= Self.quietLimit else { return nil }

        if !exists { return .gone }

        if !present {
            // Ayrı Space: ilk gördüğümüzde söyle, sonra sus (her saniye log basma).
            guard phase == .flowing else { return nil }
            phase = .hidden
            return .hidden
        }

        switch phase {
        case .flowing:
            // Görünür + sessiz = statik içerik. Arıza yok; hiçbir şey yapma.
            return nil
        case .hidden:
            // Pencere geri geldi ama hâlâ kare yok: tek deneme hakkı burada anlamlı.
            phase = .retried
            return .retry
        case .retried:
            return nil
        }
    }
}
