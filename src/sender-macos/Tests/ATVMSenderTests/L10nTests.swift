import XCTest
@testable import atvm_sender

/// İki dilli katoloğun bütünlük denetimleri.
///
/// Amaç çevirinin doğruluğunu değil **yapısal eksikliği** yakalamak: bir dilin şubesini
/// unutmak derlemeyi durduruyor, ama (a) İngilizce yazıya Türkçe kalmış bir sözcük
/// sızması, (b) iki dilde farklı sayıda/numarada biçim ögesi bulunması ve (c) anahtar
/// çakışması ancak burada görülür. (b) sessiz bozuk çıktı üretirdi: `String(format:)`
/// eksik ögede sıfır ya da çöp basar.
final class L10nTests: XCTestCase {

    /// `%1$@` → (1, "@); `%@` → numaralandırılmamış gösterici.
    private struct Specs {
        var positional: [(index: Int, type: Character)] = []
        var bare: [Character] = []

        var indices: [Int] { positional.map(\.index).sorted() }
    }

    private func specs(_ text: String) -> Specs {
        let c = Array(text)
        var out = Specs()
        var i = 0
        while i < c.count {
            guard c[i] == "%" else { i += 1; continue }
            if i + 1 < c.count, c[i + 1] == "%" { i += 2; continue }        // "%%" kaçışı
            var j = i + 1
            var digits = ""
            while j < c.count, c[j].isNumber { digits.append(c[j]); j += 1 }
            if j < c.count, c[j] == "$", !digits.isEmpty {
                j += 1
                if j < c.count {
                    out.positional.append((Int(digits)!, c[j]))
                    i = j + 1
                    continue
                }
            }
            if j < c.count, c[j].isLetter { out.bare.append(c[j]) }          // %@ / %d
            i = j
        }
        return out
    }

    /// Türkçeye özgü harfler: İngilizce yazıda hiçbiri kalmamalı.
    private static let turkishOnly = Set("ıİğĞşŞçÇöÖüÜ")

    /// İstisna: dil menüsündeki seçenek **kendi dilinde** yazılır (endonym). İngilizce
    /// arayüzde "Turkish" yazınca hangi dile geçildiği kullanıcı için belirsiz kalırdı.
    private static let endonyms: Set<TextKey> = [.uiLangTurkish]

    func testEveryKeyHasBothLanguages() {
        for key in L10n.allKeys {
            XCTAssertFalse(key.tr.trimmingCharacters(in: .whitespaces).isEmpty, "\(key.rawValue): Türkçe boş")
            XCTAssertFalse(key.en.trimmingCharacters(in: .whitespaces).isEmpty, "\(key.rawValue): İngilizce boş")
        }
    }

    func testEnglishTextHasNoTurkishLeftOver() {
        for key in L10n.allKeys where !Self.endonyms.contains(key) {
            let leaked = Set(key.en).intersection(Self.turkishOnly)
            XCTAssertTrue(leaked.isEmpty,
                          "\(key.rawValue) İngilizce yazısında Türkçe harf var: \(leaked.sorted()) — \(key.en)")
        }
    }

    func testFormatSpecifiersMatchAcrossLanguages() {
        for key in L10n.allKeys {
            let tr = specs(key.tr), en = specs(key.en)
            XCTAssertEqual(tr.bare, [], "\(key.rawValue): numaralandırılmamış gösterici var — sözcük sırası dillere göre değişiyor, %1$@ kullanılmalı (tr: \(key.tr))")
            XCTAssertEqual(en.bare, [], "\(key.rawValue): İngilizcede numaralandırılmamış gösterici var (en: \(key.en))")
            XCTAssertEqual(tr.indices, en.indices,
                           "\(key.rawValue): öge numaraları uyuşmuyor — tr \(tr.indices) / en \(en.indices)")
            let expected = tr.indices.isEmpty ? [] : Array(1...tr.indices.count)
            XCTAssertEqual(tr.indices, expected,
                           "\(key.rawValue): numaralar 1'den başlamalı ve ardışık olmalı — \(tr.indices)")
            for (a, b) in zip(tr.positional.sorted { $0.index < $1.index },
                              en.positional.sorted { $0.index < $1.index }) {
                XCTAssertEqual(a.type, b.type,
                               "\(key.rawValue): %\(a.index)$\(a.type) ↔ %\(b.index)$\(b.type) tür uyuşmuyor")
            }
        }
    }

    /// İngilizce şablonda sayıdan hemen sonra bu adlar çoğul gelmemeli: "%1$@ groups"
    /// 1 için "1 groups" üretirdi ("1 group" doğru). Türkçe çoğul ayırmadığı için kural
    /// yalnız İngilizceye bakıyor. Sayılamayacak sözcükler (birimler, "is", fiiller)
    /// listeye alınmaz; yeni bir çoğul ad eklenirse buraya da eklenmeli.
    func testEnglishDoesNotPutCountBeforePluralNoun() {
        let pluralNouns: Set<String> = [
            "groups", "rows", "issues", "packets", "lines", "copies", "events",
            "tvs", "tvs.", "seconds", "frames", "taps", "displays", "devices",
        ]
        for key in L10n.allKeys {
            let tokens = key.en.split(separator: " ")
            for (i, token) in tokens.enumerated() where token.hasPrefix("%") && token.hasSuffix("$@") {
                guard i + 1 < tokens.count else { continue }
                let next = String(tokens[i + 1]).lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;()!\"'“”"))
                XCTAssertFalse(pluralNouns.contains(next),
                               "\(key.rawValue): sayıdan sonra çoğul ad — \(key.en)")
            }
        }
    }

    func testKeyIdsAreUnique() {
        let ids = L10n.allKeys.map(\.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count, "anahtar kimliği yineleniyor")
    }

    func testLookupFollowsActiveLanguage() {
        let saved = L10n.choice
        defer { L10n.choice = saved }
        L10n.setTestLanguage(.tr)
        XCTAssertEqual(L10n.t(.chipDiscovery), "Keşif")
        L10n.setTestLanguage(.en)
        XCTAssertEqual(L10n.t(.chipDiscovery), "Discovery")
        // Sabitleme yoksa seçim izlenir.
        L10n.setTestLanguage(nil)
        L10n.choice = .en
        XCTAssertEqual(L10n.t(.tileHealthOk), "No loss")
        L10n.setTestLanguage(.tr)
    }

    /// Türkçe büyük harf "i → İ" kuralı: `uppercased()` yerel duyarsız, "KEŞIF" üretirdi.
    func testTurkishUppercasingIsLocaleAware() {
        L10n.setTestLanguage(.tr)
        XCTAssertEqual(L10n.caps(.chipDiscovery), "KEŞİF")
        L10n.setTestLanguage(.en)
        XCTAssertEqual(L10n.caps(.chipDiscovery), "DISCOVERY")
        L10n.setTestLanguage(.tr)
    }

    /// Biçimli yazı ögeleri doğru yere basmalı: Türkçede "ses X paket · Y sn",
    /// İngilizcede sıralar ters ("X audio packets · Y sn" değil "Y s").
    func testPositionalArgumentsLandCorrectly() {
        L10n.setTestLanguage(.tr)
        XCTAssertEqual(L10n.f(.tilePacketsDetail, "4.021", "12"), "ses 4.021 paket · 12 sn")
        L10n.setTestLanguage(.en)
        XCTAssertEqual(L10n.f(.tilePacketsDetail, "4,021", "12"), "audio packets: 4,021 · 12 s")
        L10n.setTestLanguage(.tr)
    }

    /// Sayı biçimi de dile bağlı: ondalık ayraç ve yüzde işareti yeri.
    func testNumberFormattingFollowsLanguage() {
        L10n.setTestLanguage(.tr)
        XCTAssertEqual(L10n.number(23.4), "23,4")
        XCTAssertEqual(L10n.int(12345), "12.345")
        XCTAssertEqual(L10n.percent(12), "%12,0")
        L10n.setTestLanguage(.en)
        XCTAssertEqual(L10n.number(23.4), "23.4")
        XCTAssertEqual(L10n.int(12345), "12,345")
        XCTAssertEqual(L10n.percent(12), "12.0%")
        L10n.setTestLanguage(.tr)
    }

    func testChoicePersistsAndSystemIsDefault() {
        let saved = L10n.choice
        defer { L10n.setTestLanguage(nil); L10n.choice = saved }
        L10n.setTestLanguage(nil)
        L10n.choice = .en
        XCTAssertEqual(L10n.active, .en)
        L10n.choice = .system
        XCTAssertEqual(L10n.active, Locale.current.language.languageCode?.identifier == "tr" ? .tr : .en)
    }

    /// Anahtarsız satır çevrilmez: uydurma çeviri yerine kaynak yazı kalır.
    func testFreeTextEventRowsAreNotTranslated() {
        L10n.setTestLanguage(.en)
        defer { L10n.setTestLanguage(.tr) }
        let row = EventRow(severity: .warn, text: "İzin verilmedi", key: nil, args: [],
                           count: 1, last: Date())
        XCTAssertEqual(row.rendered, "İzin verilmedi")
        let keyed = EventRow(severity: .info, text: "3 olay", key: .tileHealthIssues,
                             args: ["3"], count: 1, last: Date())
        XCTAssertEqual(keyed.rendered, "Issues: 3")
    }

    /// Aynı anahtarın farklı ögeleri farklı satırdır; aynı ögeler tek satırda toplanır.
    func testEventBookGroupsByKeyAndArgsNotByLanguage() {
        L10n.setTestLanguage(.tr)
        let book = EventBook()
        book.add(.tileHealthIssues, ["3"], .warn)
        book.add(.tileHealthIssues, ["7"], .warn)
        book.add(.tileHealthIssues, ["3"])
        XCTAssertEqual(book.groupCount, 2)
        XCTAssertEqual(book.lineCount, 3)

        // Dil değişince yazı yeniden çözülür, gruplama bozulmaz.
        L10n.setTestLanguage(.en)
        book.rerender()
        XCTAssertEqual(book.rows.map(\.text), ["Issues: 3", "Issues: 7"])
        book.add(.tileHealthIssues, ["3"])
        XCTAssertEqual(book.groupCount, 2, "dil değişimi aynı satırı yeni grup yapmamalı")
        L10n.setTestLanguage(.tr)
    }
}
