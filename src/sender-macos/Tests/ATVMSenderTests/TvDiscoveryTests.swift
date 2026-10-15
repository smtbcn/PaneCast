import Foundation
import XCTest
@testable import atvm_sender

/// Keşif listesinin birleştirme sınırları. `TvDiscovery.merge` ve `staleHosts` saf olduğu için
/// bu testler ağa çıkmaz: yayın adları, canlı yoklama yanıtları ve eşleşmiş kayıtlar bellekte
/// kurulur. Adresler RFC 5737 belgeleme aralığındadır (192.0.2.0/24) — gerçek kiralamalar değil.
///
/// Ölçülen kusur (crash 2026-10-15 22:27, PaneCast 0.2.0): `paired_names.json`'da iki adres
/// aynı TV adını gösterirken eski kod ad → adres sözlüğünü `Dictionary(uniqueKeysWithValues:)`
/// ile kuruyordu; çakışma süreci anında düşürüyordu (SIGTRAP, `Fatal error: Duplicate values
/// for key`) ve uygulama bir daha açılmıyordu.
final class TvDiscoveryTests: XCTestCase {
    private func reply(_ name: String, _ host: String, cport: UInt16 = TvDiscovery.defaultControlPort,
                       mport: UInt16 = TvDiscovery.defaultMediaPort, paired: Bool = false) -> TvPresence.Reply {
        TvPresence.Reply(name: name, host: host, controlPort: cport, mediaPort: mport, paired: paired)
    }

    /// Ad benzersiz değildir (alıcı yayını adını modelden üretiyor): iki adres tek ad artık çökmez,
    /// ikisi de satır olur.
    func testDuplicateStoredNamesDoNotTrap() {
        let stored = ["192.0.2.113": "Vestel Google TV", "192.0.2.114": "Vestel Google TV"]
        let rows = TvDiscovery.merge(live: [], broadcast: [], stored: stored)
        XCTAssertEqual(rows.map(\.host), ["192.0.2.113", "192.0.2.114"])
        XCTAssertTrue(rows.allSatisfy { !$0.online }, "yayın da yoklama da yok → ikisi de kapalı")
    }

    /// Canlı adres TV'nin kendi bildirdiği portlarla ve açık olarak listelenir; aynı ada sahip
    /// eski adres kapalı satır olarak kalır (ki eşleşme oradan yönetilebilsin).
    func testLivePresenceCarriesOwnPortsAndKeepsOldAddressOffline() {
        let stored = ["192.0.2.113": "Vestel Google TV", "192.0.2.114": "Vestel Google TV"]
        let rows = TvDiscovery.merge(live: [reply("Vestel Google TV", "192.0.2.114",
                                                  cport: 8601, mport: 8602, paired: true)],
                                     broadcast: [], stored: stored)
        XCTAssertEqual(rows.count, 2)
        let live = rows.first { $0.host == "192.0.2.114" }
        XCTAssertEqual(live?.controlPort, 8601)
        XCTAssertEqual(live?.mediaPort, 8602)
        XCTAssertEqual(live?.online, true)
        XCTAssertEqual(live?.tvReportsPaired, true)
        XCTAssertEqual(rows.first { $0.host == "192.0.2.113" }?.online, false)
        XCTAssertEqual(Set(rows.map(\.host)).count, rows.count, "aynı adres iki satır olmaz")
    }

    /// Yayını alınıp yoklamada yanıt vermeyen TV'nin adresi eşleşmiş kayıttan bulunur;
    /// mDNS'in makine adı yerine TV'nin bildirdiği ad gösterilir.
    func testBroadcastResolvesAddressFromStoredName() {
        let rows = TvDiscovery.merge(live: [], broadcast: ["ATVM-Vestel_Google_TV"],
                                     stored: ["192.0.2.5": "Vestel Google TV"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.host, "192.0.2.5")
        XCTAssertEqual(rows.first?.name, "Vestel Google TV")
        XCTAssertEqual(rows.first?.online, true)
        XCTAssertEqual(rows.first?.controlPort, TvDiscovery.defaultControlPort)
    }

    /// Adresi hiç bilinmeyen yayın da listelenir: TV yayında ama Mac daha önce eşleştirmemiş.
    func testBroadcastWithoutStoredAddressHasNoHost() {
        let rows = TvDiscovery.merge(live: [], broadcast: ["ATVM-Yeni_TV"], stored: [:])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.host, "")
        XCTAssertEqual(rows.first?.reachable, false)
        XCTAssertEqual(rows.first?.online, true, "yayın var → TV'de uygulama açık")
    }

    /// Aynı adres iki satır olmaz: canlı satırın adı farklı olsa bile yayını ikinci satıra
    /// dönüşmez (ölçülen kusur: tek TV iki satır listeleniyordu).
    func testHostNeverGetsTwoRows() {
        let rows = TvDiscovery.merge(live: [reply("Salon", "192.0.2.7")],
                                     broadcast: ["ATVM-Vestel_Google_TV"],
                                     stored: ["192.0.2.7": "Vestel Google TV"])
        XCTAssertEqual(rows.map(\.host), ["192.0.2.7"])
        XCTAssertEqual(rows.first?.name, "Salon")
    }

    /// Ad → aday adres listesi sayısal sırayla kurulur: sözlükte "192.0.2.10" < "192.0.2.9",
    /// ama kiralama ilerledikçe büyüyen adres daha olasıdır.
    func testHostCandidatesOrderIsNumericNotLexicographic() {
        let c = TvDiscovery.hostCandidates(stored: ["192.0.2.9": "Salon TV", "192.0.2.10": "Salon TV"])
        XCTAssertEqual(c["salon tv"], ["192.0.2.10", "192.0.2.9"])
    }

    /// `newerHost` dar bir sıralama: aynı girdi kendini geçmez, IPv4 olmayan adlar IPv4'ten
    /// sonra ve kendi içinde sözlük sırasıyla kararlı kalır.
    func testNewerHostIsStrictWeakOrdering() {
        XCTAssertFalse(TvDiscovery.newerHost("192.0.2.5", "192.0.2.5"))
        XCTAssertFalse(TvDiscovery.newerHost("tv.local", "tv.local"))
        XCTAssertFalse(TvDiscovery.newerHost("192.0.2.9", "192.0.2.10"))
        XCTAssertTrue(TvDiscovery.newerHost("192.0.2.10", "192.0.2.9"))
        XCTAssertTrue(TvDiscovery.newerHost("tv.local", "uce.local"))
        XCTAssertTrue(TvDiscovery.newerHost("192.0.2.4", "tv.local"), "sayısal adres önce gelir")
        XCTAssertEqual(["192.0.2.9", "tv.local", "192.0.2.10"].sorted(by: TvDiscovery.newerHost),
                       ["192.0.2.10", "192.0.2.9", "tv.local"])
    }

    /// Eskimiş kayıt yalnız **kanıtla** silinir: TV adresini ağ yoklamasında canlı bildirdiyse
    /// ve o eski adresin eşleşmesi yoksa. Kanıt yoksa (TV kapalı) ya da anahtar varsa hiçbir şey
    /// silinmez — `isPaired` her hatada false döndürdüğü için "eşleşmesiz" varsaymak yanıltıcı olurdu.
    func testStaleHostsPruneOnlyProvenMoves() {
        let stored = ["192.0.2.113": "Vestel Google TV", "192.0.2.114": "Vestel Google TV"]
        let live = [reply("Vestel Google TV", "192.0.2.114")]
        XCTAssertEqual(TvDiscovery.staleHosts(live: live, stored: stored, isPaired: { _ in false }),
                       ["192.0.2.113"])
        XCTAssertEqual(TvDiscovery.staleHosts(live: [], stored: stored, isPaired: { _ in false }), [],
                       "TV kapalıyken hiçbir kayıt silinmez")
        XCTAssertEqual(TvDiscovery.staleHosts(live: live, stored: stored,
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
