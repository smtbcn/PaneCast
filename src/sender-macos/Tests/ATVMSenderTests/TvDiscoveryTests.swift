import Foundation
import XCTest
@testable import atvm_sender

/// Keşif listesinin birleştirme sınırları. `TvDiscovery.merge` ve `staleHosts` saf olduğu için
/// bu testler ağa çıkmaz: mDNS çözümlemeleri, canlı yoklama yanıtları, yayın adları ve eşleşmiş
/// kayıtlar bellekte kurulur. Adresler RFC 5737 belgeleme aralığındadır (192.0.2.0/24).
///
/// Ölçülen kusurlar (crash 2026-10-15 22:27, PaneCast 0.2.0):
/// 1) Ad → adres sözlüğü `Dictionary(uniqueKeysWithValues:)` ile kuruluyordu; iki adres aynı adı
///    gösterince trap süreci düşürdü (SIGTRAP) ve uygulama bir daha açılmadı.
/// 2) Adresi eşleşme kaydından seçerken sayısal olarak büyük adres tercih ediliyordu; canlı
///    ölçümde o adres ölü, yaşayan adres daha küçük numaralıydı → "açık" görünen ölü adrese
///    bağlanılıyordu. Artık adres kanıttan gelir; kanıt yoksa adres **uydurulmaz**.
final class TvDiscoveryTests: XCTestCase {
    private func reply(_ name: String, _ host: String, cport: UInt16 = TvDiscovery.defaultControlPort,
                       mport: UInt16 = TvDiscovery.defaultMediaPort, paired: Bool = false) -> TvPresence.Reply {
        TvPresence.Reply(name: name, host: host, controlPort: cport, mediaPort: mport, paired: paired)
    }
    private func entry(_ instance: String, _ host: String, port: UInt16 = 7601) -> DnsSdBrowser.Entry {
        DnsSdBrowser.Entry(instance: instance, host: host, port: port)
    }

    /// Ad benzersiz değildir (alıcı yayın adını modelden üretiyor): iki adres tek ad artık çökmez.
    func testDuplicateStoredNamesDoNotTrap() {
        let stored = ["192.0.2.113": "Vestel Google TV", "192.0.2.114": "Vestel Google TV"]
        let rows = TvDiscovery.merge(resolved: [], live: [], broadcast: [], stored: stored)
        XCTAssertEqual(rows.map(\.host), ["192.0.2.113", "192.0.2.114"])
        XCTAssertTrue(rows.allSatisfy { !$0.online }, "yayın da yoklama da yok → ikisi de kapalı")
    }

    /// mDNS çözümlemesi adresin birincil kaynağıdır: TV'nin kendi portu ve güncel adresi gelir,
    /// eşleşmiş kayıttaki okunaklı ad korunur, aynı ada sahip eski adres kapalı satıra düşer.
    func testResolvedEntryWinsAndKeepsOldAddressOffline() {
        let stored = ["192.0.2.113": "Vestel Google TV", "192.0.2.114": "Vestel Google TV"]
        let rows = TvDiscovery.merge(resolved: [entry("ATVM-Vestel_Google_TV", "192.0.2.114", port: 8601)],
                                     live: [reply("Vestel Google TV", "192.0.2.114", cport: 8601,
                                                  mport: 8602, paired: true)],
                                     broadcast: ["ATVM-Vestel_Google_TV"], stored: stored)
        XCTAssertEqual(rows.count, 2)
        let live = rows.first { $0.host == "192.0.2.114" }
        XCTAssertEqual(live?.controlPort, 8601, "TV'nin bildirdiği port kullanılmalı")
        XCTAssertEqual(live?.name, "Vestel Google TV")
        XCTAssertEqual(live?.source, .resolved)
        XCTAssertEqual(live?.online, true)
        XCTAssertEqual(live?.tvReportsPaired, true)
        XCTAssertEqual(rows.first { $0.host == "192.0.2.113" }?.online, false)
        XCTAssertEqual(Set(rows.map(\.host)).count, rows.count, "aynı adres iki satır olmaz")
    }

    /// Yoklama yanıtı (TV'nin kendi bildirimi) mDNS yoksa adresi taşır.
    func testPresenceProvidesAddressWhenMdnsSilent() {
        let rows = TvDiscovery.merge(resolved: [], live: [reply("Salon", "192.0.2.9", paired: true)],
                                     broadcast: [], stored: [:])
        XCTAssertEqual(rows.map(\.host), ["192.0.2.9"])
        XCTAssertEqual(rows.first?.source, .presence)
        XCTAssertEqual(rows.first?.tvReportsPaired, true)
    }

    /// Yayını çözümlenememiş TV'nin adresi eşleşmiş kayıttan bulunur; mDNS makine adı yerine
    /// TV'nin bildirdiği ad gösterilir.
    func testBroadcastResolvesAddressFromSingleStoredName() {
        let rows = TvDiscovery.merge(resolved: [], live: [], broadcast: ["ATVM-Vestel_Google_TV"],
                                     stored: ["192.0.2.5": "Vestel Google TV"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.host, "192.0.2.5")
        XCTAssertEqual(rows.first?.name, "Vestel Google TV")
        XCTAssertEqual(rows.first?.source, .broadcast)
        XCTAssertEqual(rows.first?.online, true)
    }

    /// Kanıt yoksa adres uydurulmaz: aynı ada sahip iki eşleşmiş adres varsa satır adresiz kalır
    /// (ölçülen kusur: uydurulan adres ölü çıktı ve bağlantı kurulamadı).
    func testAmbiguousStoredAddressesAreNotGuessed() {
        let stored = ["192.0.2.113": "Vestel Google TV", "192.0.2.114": "Vestel Google TV"]
        let rows = TvDiscovery.merge(resolved: [], live: [], broadcast: ["ATVM-Vestel_Google_TV"],
                                     stored: stored)
        let announced = rows.filter { $0.source == .broadcast }
        XCTAssertEqual(announced.count, 1)
        XCTAssertEqual(announced.first?.host, "", "belirsizlikte adres boş kalmalı")
        XCTAssertTrue(announced.first?.online ?? false, "yayın var → TV'de uygulama açık")
        XCTAssertEqual(Set(rows.map(\.host)).count, rows.count)
    }

    /// Adresi hiç bilinmeyen yayın da listelenir: TV yayında ama Mac onu hiç eşleştirmemiş.
    func testBroadcastWithoutStoredAddressHasNoHost() {
        let rows = TvDiscovery.merge(resolved: [], live: [], broadcast: ["ATVM-Yeni_TV"], stored: [:])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.host, "")
        XCTAssertEqual(rows.first?.reachable, false)
        XCTAssertEqual(rows.first?.online, true)
    }

    /// Aynı adres iki satır olmaz: canlı satırın adı farklı olsa bile yayın ikinci satıra dönüşmez.
    func testHostNeverGetsTwoRows() {
        let rows = TvDiscovery.merge(resolved: [], live: [reply("Salon", "192.0.2.7")],
                                     broadcast: ["ATVM-Vestel_Google_TV"],
                                     stored: ["192.0.2.7": "Vestel Google TV"])
        XCTAssertEqual(rows.map(\.host), ["192.0.2.7"])
        XCTAssertEqual(rows.first?.name, "Salon")
    }

    /// Ad → aday adres listesi kararlı (artan sözlük) sırada kurulur; sayısal "büyük adres önce"
    /// sezgisi kaldırıldı, çünkü ölçümde yaşayan adres daha küçük numaralıydı.
    func testHostCandidatesAreDeterministicLists() {
        let c = TvDiscovery.hostCandidates(stored: ["192.0.2.9": "Salon TV", "192.0.2.10": "Salon TV"])
        XCTAssertEqual(c["salon tv"], ["192.0.2.10", "192.0.2.9"])
        XCTAssertEqual(c["salon tv"]?.count, 2, "ad benzersiz değil: liste tutulur")
    }

    /// Eskimiş kayıt yalnız **kanıtla** silinir: TV adresini mDNS ya da yoklamada canlı bildirdiyse
    /// ve o eski adresin eşleşmesi yoksa. Kanıt yoksa (TV kapalı) ya da anahtar varsa hiçbir şey
    /// silinmez — `isPaired` her hatada false döndürdüğü için "eşleşmesiz" varsaymak yanıltıcı olurdu.
    func testStaleHostsPruneOnlyProvenMoves() {
        let stored = ["192.0.2.113": "Vestel Google TV", "192.0.2.114": "Vestel Google TV"]
        let live = [reply("Vestel Google TV", "192.0.2.114")]
        let resolved = [entry("ATVM-Vestel_Google_TV", "192.0.2.114")]
        XCTAssertEqual(TvDiscovery.staleHosts(live: live, resolved: [], stored: stored,
                                              isPaired: { _ in false }), ["192.0.2.113"])
        XCTAssertEqual(TvDiscovery.staleHosts(live: [], resolved: resolved, stored: stored,
                                              isPaired: { _ in false }), ["192.0.2.113"],
                       "adres kanıtı mDNS'ten de gelir")
        XCTAssertEqual(TvDiscovery.staleHosts(live: [], resolved: [], stored: stored,
                                              isPaired: { _ in false }), [],
                       "TV kapalıyken hiçbir kayıt silinmez")
        XCTAssertEqual(TvDiscovery.staleHosts(live: live, resolved: [], stored: stored,
                                              isPaired: { $0 == "192.0.2.113" }), [],
                       "eşleşmiş adres silinmez: kullanıcı adres yazmadan kaldırmak isteyebilir")
    }

    /// Normalize etki alanı: mDNS makine adı ile TV'nin bildirdiği ad arasındaki biçim farkı
    /// eşleşmeyi bozmamalı (ölçüldü: ikisi farklı geliyordu).
    func testNormalizeMatchesBroadcastToReportedName() {
        XCTAssertEqual(TvDiscovery.normalize("ATVM-Vestel_Google_TV"),
                       TvDiscovery.normalize("  Vestel Google TV "))
    }
}
