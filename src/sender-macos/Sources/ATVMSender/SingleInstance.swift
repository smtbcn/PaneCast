import Foundation
import AppKit

/// Bir cihazda aynı anda **tek** Pane Cast örneği olmasının karar tarafı.
///
/// Neden gerekli: iki örnek aynı TV kanallarını (kontrol 7601, medya 7602, geri kanal 7610,
/// yoklama 7611) ve aynı mDNS kaydını paylaşamaz; ölçülen sonuç "TV yanıt vermiyor /
/// eşleşme yok" gibi görünüyordu ve izinler hangi kopyaya verildi şaşırıyordu.
/// Eskiden yalnız uyarı veriliyordu (ölçüldü: test sırasında üç örnek birden çalıştı).
/// Artık ikinci örnek açılmıyor: birinci öne çıkarılıp ikinci süreç çıkıyor.
///
/// Yalnız TV tarafına dönük kanalları tutan komutlar kilitlenir; salt-okunur teşhis
/// komutları (`list-tvs`, `list-windows`, `selftest`, `netload`, `dns-probe` …) çalışmaya
/// devam eder — aksi hâlde arayüz açıkken teşhis yapamazdık.
enum InstanceGuard {
    static let servingCommands: Set<String> = ["", "gui", "mirror", "switch-test"]

    static func isServing(_ command: String) -> Bool { servingCommands.contains(command) }

    /// Kilit dosyasındaki pid yaşıyor mu? Yaşamıyorsa kilit eski bir çökmeden kalmıştır.
    static func isStale(lockPid: Int?, alive: (Int) -> Bool) -> Bool {
        guard let pid = lockPid else { return true }
        return !alive(pid)
    }

    /// Saf karar: devam edelim mi, yoksa hangi pid'ye boyun verelim?
    /// Aynı paketi paylaşan başka bir süreç ya da canlı bir kilit sahibi varsa ona boyun verilir;
    /// kendi pid'miz ve bayat kilit sayılmaz.
    static func yieldTo(myPid: Int, others: [Int], lockPid: Int?, alive: (Int) -> Bool) -> Int? {
        if let other = others.filter({ $0 != myPid }).sorted().first { return other }
        if let lock = lockPid, lock != myPid, !isStale(lockPid: lock, alive: alive) { return lock }
        return nil
    }

    /// Sürecin hâlâ var olup olmadığı (yalnız sinyal 0 — hiçbir şey göndermeden yoklama).
    static func processAlive(_ pid: Int) -> Bool { kill(pid_t(pid), 0) == 0 || errno == EPERM }

    static var lockURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pane-cast-instance.lock")
    }

    /// Kilit dosyasını dener: O_EXCL ile atomik yaratma. Zaten varsa içindeki pid okunur.
    /// Dönüş: kilit bizdeyse `nil`, başkasındaysa o pid.
    /// Yaşayan bir sahibin dosyası **asla silinmez veya ezilmez** — test edilebilir olsun diye
    /// yol parametrelidir; gerçek kilit `lockURL`dir.
    static func acquireLock(myPid: Int, at url: URL = lockURL) -> Int? {
        let path = url.path
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd >= 0 {
            let text = "\(myPid)\n"
            _ = text.withCString { write(fd, $0, strlen($0)) }
            close(fd)
            return nil
        }
        let held = (try? String(contentsOf: url, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if isStale(lockPid: held, alive: processAlive) || held == myPid {
            // Bayat kilit: eski sahip öldü, devral.
            try? "\(myPid)\n".write(to: url, atomically: true, encoding: .utf8)
            return nil
        }
        return held
    }

    static func releaseLock() {
        try? FileManager.default.removeItem(at: lockURL)
    }

    /// Aynı paket kimliğini paylaşan diğer **koşan** süreçler (farklı disk kopyaları dâhil).
    static func siblingPids() -> [Int] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let mine = Int(ProcessInfo.processInfo.processIdentifier)
        return NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == id && $0.processIdentifier != mine }
            .map { Int($0.processIdentifier) }
    }

    static func activate(pid: Int) {
        NSRunningApplication(processIdentifier: pid_t(pid))?.activate(options: [.activateAllWindows])
    }

    /// Serving komutlarının ortak girişi: ikinci örnekse birinciyi öne çıkarır ve çıkar.
    /// Dönüş: `nil` = devam edebiliriz.
    ///
    /// Sıra önemlidir: önce koşan örnek yoklanır, kilit **yalnız o yoksa** denenir.
    /// Aksi hâlde ikinci örnek kendi yarattığı kilidi silerken, birinci örneğin
    /// kilidini de silebiliyordu (ölçülen kusur: kilit dosyası, sahibi hâlâ koşarken
    /// kayboluyordu). Boyun verdiğimiz taraftaki kilide hiç dokunmayız.
    static func enforce(command: String, log: (String) -> Void) -> Never? {
        guard isServing(command) else { return nil }
        let mine = Int(ProcessInfo.processInfo.processIdentifier)
        let message: (Int) -> String = { holder in
            "Pane Cast zaten çalışıyor (pid \(holder)) — bir cihazda tek örnek açıktır; "
                + "birinci örnek öne çıkarıldı, bu süreç kapandı."
        }
        if let other = yieldTo(myPid: mine, others: siblingPids(), lockPid: nil, alive: processAlive) {
            log(message(other)); activate(pid: other); exit(0)
        }
        // Koşan örnek NSWorkspace'te görünmeyebilir (arayüz dışından çalışan ham CLI süreci):
        // kilit sahibi yaşıyorsa ona boyun verilir.
        if let holder = acquireLock(myPid: mine) {
            log(message(holder)); activate(pid: holder); exit(0)
        }
        return nil
    }
}
