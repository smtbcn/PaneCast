import Foundation
import XCTest
@testable import atvm_sender

/// Ağ yükü şeridinin saf matematiği. Ölçüm kaynakları (işletim sayacı, UPnP) burada
/// test edilmez; ama "okunamayan payda %0 olur mu" sorusunun cevabı burada kilitlenir:
/// hayır, nil kalır ve arayüz "—" gösterir.
final class NetLoadTests: XCTestCase {
    func testFirstSampleHasNoRate() {
        XCTAssertNil(NetMath.mbps(previous: nil, current: 5_000_000, seconds: 1))
    }

    func testRateFromCounterDelta() {
        // 1,25 MB / 1 sn = 10 Mbps
        let v = NetMath.mbps(previous: 1_000_000, current: 2_250_000, seconds: 1)
        XCTAssertEqual(v ?? 0, 10, accuracy: 0.001)
    }

    /// Sayaç geriye düşerse (modem yeniden başlar, arayız sıfırlanır) uydurma hız yerine nil.
    func testCounterResetYieldsNoRate() {
        XCTAssertNil(NetMath.mbps(previous: 9_000_000, current: 100, seconds: 1))
    }

    func testVeryShortIntervalYieldsNoRate() {
        XCTAssertNil(NetMath.mbps(previous: 0, current: 1_000_000, seconds: 0.01))
    }

    func testShareNeedsARealDenominator() {
        XCTAssertEqual(NetMath.share(part: 12, of: 216) ?? 0, 5.555, accuracy: 0.01)
        XCTAssertNil(NetMath.share(part: 12, of: nil), "payda yoksa % yok")
        XCTAssertNil(NetMath.share(part: nil, of: 216), "pay yoksa % yok")
        XCTAssertNil(NetMath.share(part: 12, of: 0), "sıfır paydaya bölünmez")
        XCTAssertNil(NetMath.share(part: 12, of: 0.01), "anlamsız derecede küçük payda")
    }

    func testShareIsClippedNotWrapped() {
        XCTAssertEqual(NetMath.share(part: 500, of: 4) ?? 0, 999, accuracy: 0.01)
        XCTAssertEqual(NetMath.share(part: -1, of: 100) ?? 0, 0, accuracy: 0.01)
    }

    func testTotalHandlesMissingDirection() {
        XCTAssertEqual(NetMath.total(3, 4) ?? 0, 7, accuracy: 0.001)
        XCTAssertEqual(NetMath.total(nil, 4) ?? 0, 4, accuracy: 0.001)
        XCTAssertEqual(NetMath.total(3, nil) ?? 0, 3, accuracy: 0.001)
        XCTAssertNil(NetMath.total(nil, nil))
    }

    /// UPnP yanıtının gerçek biçiminden alan okuma (ağ gitmeden, metin üzerinden).
    func testSoapResponseParsing() {
        let text = """
        <s:Envelope><s:Body><u:GetTotalBytesSentResponse>\
        <NewTotalBytesSent>48219033</NewTotalBytesSent>\
        </u:GetTotalBytesSentResponse></s:Body></s:Envelope>
        """
        let v = UpnpIgd.tag(text, "NewTotalBytesSent")
        XCTAssertEqual(v, "48219033")
        XCTAssertNil(UpnpIgd.tag(text, "NewTotalBytesReceived"))
    }

    /// Cihaz tanımı farklı satır/ses biçimlerinde de servis bloğunu bulmalı;
    /// TV gibi IGD olmayan cihazlar elenir.
    func testServiceBlockSelection() {
        let modem = """
        <root><device><deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
        <service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType>
        <controlURL>/ctl/L3F</controlURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType>
        <controlURL>/ctl/CmnIfCfg</controlURL></service></device></root>
        """
        let block = UpnpIgd.serviceBlock(modem, "WANCommonInterfaceConfig")
        XCTAssertNotNil(block)
        XCTAssertTrue(block?.contains("/ctl/CmnIfCfg") == true)
        XCTAssertNil(UpnpIgd.serviceBlock("<root><deviceType>MediaRenderer</deviceType></root>",
                                          "WANCommonInterfaceConfig"))
    }

    /// Modem yoklaması arayüz ritmiyle (1 sn) koşmaz: her tur iki HTTP isteği demek.
    func testModemRoundsAreSpaced() {
        let t = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(ModemPollPolicy.canPoll(now: t, lastRoundAt: nil, retryAt: .distantPast),
                      "ilk tur bekler")
        XCTAssertFalse(ModemPollPolicy.canPoll(now: t.addingTimeInterval(1), lastRoundAt: t,
                                               retryAt: .distantPast), "1 sn sonra ikinci tur yok")
        XCTAssertTrue(ModemPollPolicy.canPoll(now: t.addingTimeInterval(ModemPollPolicy.interval),
                                              lastRoundAt: t, retryAt: .distantPast))
    }

    /// Modem UPnP yanıtlamıyorsa SSDP yayını her saniye tekrarlanmaz: ardışık başarısızlık
    /// 5 sn'den başlayıp katlanarak 60 sn'de tavan yapar.
    func testFailedDiscoveryBacksOff() {
        XCTAssertEqual(ModemPollPolicy.retryDelay(afterFailures: 0), 0, accuracy: 0.001)
        XCTAssertEqual(ModemPollPolicy.retryDelay(afterFailures: 1), 5, accuracy: 0.001)
        XCTAssertEqual(ModemPollPolicy.retryDelay(afterFailures: 2), 10, accuracy: 0.001)
        XCTAssertEqual(ModemPollPolicy.retryDelay(afterFailures: 4), 40, accuracy: 0.001)
        XCTAssertEqual(ModemPollPolicy.retryDelay(afterFailures: 40), 60, accuracy: 0.001, "tavan 60 sn")
        let t = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(ModemPollPolicy.canPoll(now: t, lastRoundAt: nil, retryAt: t.addingTimeInterval(5)),
                       "geri çekilme bitmeden yeni deneme yok")
    }
}
