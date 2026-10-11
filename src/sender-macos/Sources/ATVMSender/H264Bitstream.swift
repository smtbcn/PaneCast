import Foundation
import CoreMedia
import VideoToolbox

/// VideoToolbox H.264 çıktısı uzunluk-önekli (AVCC benzeri, 4 bayt big-endian) NAL birimleridir;
/// TV tarafındaki MediaCodec Annex-B (00 00 00 01 start code) bekler.
/// Bu dosya dönüşümü yapar ve keyframe öncesi SPS/PPS'i ekler.
/// Yalnızca VideoToolbox çıktısının biçiminden yazılmıştır; başka bir projeden kod alınmamıştır.
enum H264 {
    static let startCode: [UInt8] = [0, 0, 0, 1]

    /// CMVideoFormatDescription'dan SPS/PPS (ve varsa SEI/alt katman) setlerini çıkarır.
    static func parameterSets(_ format: CMFormatDescription) -> [Data] {
        var count: Int = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        ) == noErr, count > 0 else { return [] }

        var out: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if st == noErr, let ptr = ptr, size > 0 {
                out.append(Data(bytes: ptr, count: size))
            }
        }
        return out
    }

    /// Uzunluk-önekli örnek verisini Annex-B erişim birimine çevirir.
    /// - Parameter lengthPrefixed: CMBlockBuffer'dan okunmuş ham baytlar
    /// - Returns: Annex-B baytları (start code + NAL ...)
    static func annexB(fromLengthPrefixed data: Data, prepend parameterSets: [Data]) -> Data {
        var out = Data()
        out.reserveCapacity(data.count + 64)
        for ps in parameterSets {
            out.append(contentsOf: startCode)
            out.append(ps)
        }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var off = 0
            while off + 4 <= n {
                let nalLen = (UInt32(bytes[off]) << 24) | (UInt32(bytes[off + 1]) << 16)
                    | (UInt32(bytes[off + 2]) << 8) | UInt32(bytes[off + 3])
                off += 4
                let len = Int(nalLen)
                if len <= 0 || off + len > n { break }
                out.append(contentsOf: startCode)
                out.append(bytes.baseAddress!.advanced(by: off), count: len)
                off += len
            }
        }
        return out
    }

    /// Zaten Annex-B mi? Tahmin etmeyiz: uzunluk-önekli zincirin tam çözülmesine bakarız.
    ///
    /// Ölçülen kusur: eski kısayol `d[2]==1 || d[3]==1` kuralıydı. AVCC örnekte ilk NAL
    /// 256–511 bayt ise önek `00 00 01 xx` oluyor ve Annex-B sanılıyordu; ham AVCC gönderilince
    /// TV `00 00 01` sonrası `xx`'i NAL başlığı sayıp "bilinmeyen NAL türü" görüyordu
    /// (ölçüldü: ~490 AU'nun 35'inde bozuk NAL — paketleyicinin GİRİŞİ bozuktu, ağ değil).
    static func isLengthPrefixed(_ d: Data) -> Bool {
        let b = [UInt8](d)
        guard b.count > 5 else { return false }
        var off = 0
        var nalCount = 0
        while off + 4 < b.count {
            let len = (UInt32(b[off]) << 24) | (UInt32(b[off + 1]) << 16)
                | (UInt32(b[off + 2]) << 8) | UInt32(b[off + 3])
            guard len > 0, len < UInt32(b.count), off + 4 + Int(len) <= b.count else { return false }
            let header = b[off + 4]
            guard header & 0x80 == 0, header & 0x1F != 0 else { return false }
            off += 4 + Int(len)
            nalCount += 1
        }
        return nalCount > 0 && off == b.count
    }

    /// Buffer bir start code ile mi başlıyor (00 00 01 ya da 00 00 00 01)?
    static func startsWithStartCode(_ d: Data) -> Bool {
        let b = [UInt8](d)
        guard b.count > 4 else { return false }
        if b[0] == 0, b[1] == 0, b[2] == 1 { return true }
        return b[0] == 0 && b[1] == 0 && b[2] == 0 && b[3] == 1
    }

    static func nalType(_ annexB: Data) -> Int {
        // ilk start code'dan sonraki baytın 0x1F maskesi
        var i = annexB.startIndex
        while i < annexB.endIndex, annexB[i] == 0 { i = annexB.index(after: i) }
        i = annexB.index(after: i)
        guard i < annexB.endIndex else { return -1 }
        return Int(annexB[i] & 0x1F)
    }
}
