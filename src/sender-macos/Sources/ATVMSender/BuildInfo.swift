import Foundation

/// Uygulamanın kendi sürümü, arayüzde `v0.2.11` biçiminde.
///
/// Neden gerekiyor: sürüm ne Mac arayüzünde ne de günlük satırlarında görünüyordu; hangi
/// kopyanın koştuğunu ve TV'deki ile aynı sürüm olup olmadığını anlamak için terminal
/// gerekiyordu (`plutil -extract CFBundleShortVersionString …`). Kaynak Info.plist —
/// `scripts/build-sender-app.sh` oraya VERSION dosyasındaki değeri yazıyor, yani ekranda
/// okunan değer ile GitHub yayını aynı zincirden geliyor.
enum BuildInfo {
    static let version: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "bilinmiyor"
    /// Arayüzde görünecek etiket: `v0.2.11`.
    static var tag: String { "v\(version)" }
}
