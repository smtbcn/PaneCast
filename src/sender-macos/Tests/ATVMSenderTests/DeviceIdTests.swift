import Foundation
import XCTest
@testable import atvm_sender

/// Yayıncı kimliği ve ağ yoklaması gövdesi — docs/protocol.md §2.1 + §3.4.
/// Anahtar Zinciri'ne dokunmuyoruz: `DeviceID.current` üretimini değil, **biçim kuralını**
/// sınıyoruz. Alıcı bu etiketi dosya adı yapıyor, bu yüzden karakter kümesi protokol sözleşmesidir.
final class DeviceIdTests: XCTestCase {

    /// 0xFF ×12 → standart base64'te 16 adet `/` üretir; url güvenliği hepsini `_` yapmalı.
    func testEncodeStaysInsideFilesystemSafeAlphabet() {
        let raw = Data(repeating: 0xFF, count: 12)
        let id = DeviceID.encode(raw)
        XCTAssertEqual(id.count, 16, "12 bayt padding'siz base64url = tam 16 karakter (§3.4)")
        XCTAssertFalse(id.contains("/"), "ayraç: alıcı dosya adını reddeder")
        XCTAssertFalse(id.contains("+"))
        XCTAssertFalse(id.contains("="))
        XCTAssertEqual(id, String(repeating: "_", count: 16))
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertEqual(id.unicodeScalars.allSatisfy { allowed.contains($0) }, true)
        XCTAssertEqual(DeviceID.encode(raw), id, "aynı bayt → aynı etiket")
    }

    func testFindPayloadKeepsOldShapeWhenIdMissing() {
        XCTAssertEqual(String(data: Presence.findPayload(name: "Masaüstü", id: ""), encoding: .utf8),
                       #"{"t":"find","name":"Masaüstü"}"#,
                       "eski yayıncının bayt biçimi değişmemeli: eski alıcı onu olduğu gibi okur")
    }

    func testFindPayloadIsJsonTheReceiverCanParse() throws {
        let id = DeviceID.encode(Data([UInt8](1...12)))
        let data = Presence.findPayload(name: "Atolye-Mac", id: id)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["t"] as? String, "find")
        XCTAssertEqual(obj["name"] as? String, "Atolye-Mac")
        XCTAssertEqual(obj["id"] as? String, id)
    }
}
