import Foundation

/// Pencere satırının tek isimlendirme kuralı: **uygulama adı — içerik adı**.
///
/// Neden gerekli (ölçüldü): satır zaten ` "\(app) — \(title)"` kuruyordu ama etiket
/// `byTruncatingHead` ile **baştan** kırpıyordu; uzun tarayıcı başlığında uygulama adı
/// tamamen kayboluyor, kullanıcı "…in En Etkileyici Mağaralarından…" gibi ortasından
/// başlayan bir metin görüyordu. Ayrıca başlıkların kendinde taşıma gereksiz var:
/// okunmamış sayacı `(1131) ` ve uygulamanın kendi adını tekrar eden son ek ` - Slack`.
///
/// Kural burada, Android/AppKit'ten bağımsız duruyor ki birim testiyle kilitlenebilsin.
enum WindowNaming {
    /// Başlıktan taşıma gereği gürültüyü atar: öndeki okunmamış sayacı ve sondaki
    /// uygulamayı tekrar eden son ek. Geriye bir şey kalmazsa orijinal başlık döner.
    static func clean(_ title: String, app: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // "(1131) ", "(99+)" gibi bildirim sayaçları — içerik adı değil.
        while let m = leadingCounter(t) { t = m }
        let seps = ["-", "–", "—"]
        let appName = app.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appName.isEmpty else { return t }
        // "… - Slack - Slack" gibi tekrarlarda hepsini düşür; en sonda kalansa uygulamayı
        // iki kere yazmamış oluruz (satır zaten uygulama adıyla başlıyor).
        var changed = true
        while changed {
            changed = false
            for sep in seps {
                for suffix in [" \(sep) \(appName)", " \(sep)\(appName)", " \(appName)"] where
                    t.count > suffix.count && t.lowercased().hasSuffix(suffix.lowercased()) {
                    t = String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
            }
        }
        // Sondaki uygulama adı düşürülünce "Belge -" gibi yarım bir ayraç kalabilir: o da gider.
        while let last = t.last, last == "-" || last == "–" || last == "—" {
            t = String(t.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : t
    }

    /// "(42) X" → "X"; sayaç yoksa nil.
    private static func leadingCounter(_ text: String) -> String? {
        guard text.hasPrefix("(") else { return nil }
        guard let close = text.firstIndex(of: ")") else { return nil }
        let inner = text[text.index(after: text.startIndex)..<close]
        guard !inner.isEmpty,
              inner.allSatisfy({ $0.isNumber || $0 == "+" || $0 == "…" }) else { return nil }
        let rest = text[text.index(after: close)...]
        return rest.hasPrefix(" ") ? String(rest.dropFirst()) : nil
    }

    /// Satırda görünecek tek satırlık ad: `Uygulama — içerik`. İçerik uygulama adıyla
    /// aynıysa (veya boşsa) yalnız uygulama yazılır — "Qoder — Qoder" gürültüsü yerine.
    static func rowText(app: String, title: String) -> String {
        let content = clean(title, app: app)
        if content.isEmpty { return app }
        if content.compare(app, options: .caseInsensitive) == .orderedSame { return app }
        return "\(app) — \(content)"
    }
}
