import Foundation

/// Arayüz ve olay metinlerinin iki dili: **Türkçe ve İngilizce**.
///
/// Düzen klasik i18n kataloğudur: her metnin sabit bir **anahtarı** var (`TextKey`), anahtarın
/// iki dildeki yazısı zorunlu üyelerde duruyor. Bir dile şube düşürülürse derleme durur, yani
/// "çevrilmemiş satır" diye bir durum kod düzeyinde imkânsız; görünen dil yalnız `active`
/// üzerinden seçiliyor. Anahtarlar `String` ham değerli olduğu için olay ekranında/kayıtta
/// metnin kimliği okunabiliyor (`key.rawValue` = `dashboard.chip.source` gibi).
///
/// Neden Apple'ın `.xcstrings`/`.lproj` kataloğu değil: bu proje Xcode'sız kuruluyor
/// (`swift build` + `scripts/build-sender-app.sh` demeliği elle yığıyor). String catalog'larını
/// derleyen `actool` yalnız xcodebuild'de var; `.lproj` içine konan `.strings` ise `swift test`
/// çalıştırıcısının `Bundle.main`'ine hiç girmiyor, dolayısıyla birim testleri katalogu
/// göremez ve eksik satır derlemeyi durdurmazdı. Karşılığında demet, iki dili
/// `CFBundleLocalizations` ile **beyan ediyor** (`scripts/build-sender-app.sh`), böylece
/// macOS'un uygulama-dili seçeneği ve `Locale.current` çözümü standart yoldan çalışıyor.
enum L10n {
    enum Language: String, CaseIterable {
        case system, en, tr

        /// Açılır listedeki yazı. "English" ve "Türkçe" kendi dilinde yazılır (endonym —
        /// kullanıcı hangi düğmeye bastığını kendi dilinden tanır); yalnız "Sistem" seçeneği
        /// görünen dile çevrilir.
        var label: String {
            switch self {
            case .system: return L10n.active == .en ? "System" : "Sistem"
            case .en: return "English"
            case .tr: return "Türkçe"
            }
        }
    }

    /// Kullanıcının seçimi (saklanır). `system` = işletim dilini izle.
    static let defaultsKey = "language"

    static var choice: Language {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Language.init(rawValue:)) ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// Görünen dil. Testler ve görsel doğrulama için sabitlenebilir (`setTestLanguage`).
    static var override: Language?

    static var active: Language {
        if let override { return override }
        switch choice {
        case .en, .tr: return choice
        case .system: return Locale.current.language.languageCode?.identifier == "tr" ? .tr : .en
        }
    }

    static var isEnglish: Bool { active == .en }

    /// Bir metnin görünen dildeki yazısı.
    static func t(_ key: TextKey) -> String { isEnglish ? key.en : key.tr }

    /// Biçimli yazı: `L10n.f(.tileHealthIssues, 3)`.
    /// İki dildeki göstericiler de **numaralı ve aynı sırada** olmak zorunda (`%1$@`), çünkü
    /// Türkçe ve İngilizcede sözcük sırası değişiyor; sıralı `%@` yanlış ögeyi basardı.
    /// Kuralı `L10nTests` tablo üzerinden denetliyor.
    static func f(_ key: TextKey, _ args: any CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    /// Aynı `f`, çağrı yerinde dizgi hazırlanırken (AppleScript/`NSTextField` köprüleri).
    static func f(_ key: TextKey, _ args: [any CVarArg]) -> String {
        String(format: t(key), arguments: args)
    }

    /// Katalog denetimlerinin gördüğü satırlar.
    static var allKeys: [TextKey] { TextKey.allCases }
}

/// Sayı ve yüzde yazımı da dile bağlı: ölçü birimleri evrensel ama ayraçlar değil.
///
/// Türkçede "23,4 Mbps" ve "%12", İngilizcede "23.4 Mbps" and "12%". Yayıncı bundan önce
/// `String(format: "%.1f")` ve `"%\(x)"` kullanıyordu; arayüz İngilizceye alındığında ayraç
/// nokta kalıp yüzde işareti başta durmaya devam ediyordu.
extension L10n {
    private static let localeTr = Locale(identifier: "tr")
    private static let localeEn = Locale(identifier: "en")

    private static var locale: Locale { isEnglish ? localeEn : localeTr }

    /// Ondalı sayı (`23,4` / `23.4`), binlik ayracısız.
    static func number(_ value: Double, digits: Int = 1) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = locale
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    /// Tam sayı, yerel binlik ayracıyla (`12.345` / `12,345`).
    static func int(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = locale
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Yüzde: Türkçede `%12`, İngilizcede `12%`.
    static func percent(_ value: Double) -> String {
        let number = self.number(value, digits: value >= 100 ? 0 : 1)
        return isEnglish ? "\(number)%" : "%\(number)"
    }
}

/// Görünen dil değişince arayüzün yeniden yazılması gereken yerleri bilgilendirir.
/// Düğme/etiket yazıları `init`te bir kez çözüldüğü için (ölçülen kusur: tema geçişinde
/// `CGColor`'ların çözülü kalmasıydı) dil geçişi de aynı dikkati istiyor.
extension Notification.Name {
    static let paneCastLanguageChanged = Notification.Name("paneCast.languageChanged")
}

/// Anahtar: `UserDefaults`'e yaz + bildirim yayımla.
extension L10n {
    static func setChoice(_ language: Language) {
        choice = language
        NotificationCenter.default.post(name: .paneCastLanguageChanged, object: nil)
    }

    /// Test/görsel doğrulama için görünür dili sabitler; `nil` seçime döner.
    static func setTestLanguage(_ language: Language?) { override = language }
}

/// Dil geçişini görünüme ileten gözlemci. Token görünümün özelliği olduğu için görünümle
/// birlikte ölür ve kayıt sızdırmaz (AppKit etiket yazıları `init`te bir kez çözülüyor;
/// tema geçişinde `CGColor` çözülüsünün kalması aynı türevdeki kusurdu).
final class LanguageWatch {
    private let token: NSObjectProtocol

    init(_ body: @escaping () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: .paneCastLanguageChanged, object: nil, queue: .main
        ) { _ in body() }
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}
