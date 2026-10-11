import Foundation
import CoreGraphics

/// Kodlama çerçevesi hesabı: pencere piksel boyutu → profil kutusuna ORANI BOZMADAN sığan,
/// 16'ya hizalı boyut. TV görüntüyü panele olduğu gibi gerer (ölçüldü: Src[1072 944] →
/// dst{0 0 1920 1080}); bu yüzden en-boy oranı kaynakta doğru olmak zorundadır.
enum VideoGeometry {
    struct Size: Equatable {
        let width: Int
        let height: Int
    }

    /// Önce bu hatayla, bulunamazsa `tolerance` ile aranır (oran hatası, göreli).
    static let tightTolerance = 0.0025
    static let tolerance = 0.01
    /// Alt sınır: daha küçük çerçevede donanım çözücü kare üretmiyordu (ölçüldü: 320×144 → render=0).
    /// Sınır yönelime göre döner; boyutu küçük pencere esnetilmez, oranla büyütülür.
    static let minLong = 640, minShort = 360
    /// Yukarı yuvarlamada kaynağın piksel boyutunu aşabilecek pay (bir 16'lık blok iki katı).
    private static let overshoot = 32

    /// `pw`×`ph`: pencerenin piksel boyutu. `boxWidth`×`boxHeight`: profilin yatay kutusu.
    /// Dikey pencere de yatay kutuya sığdırılır (TV yataydır).
    static func encodeSize(pixelWidth pw: Double, pixelHeight ph: Double,
                           boxWidth: Int, boxHeight: Int) -> Size {
        guard pw >= 1, ph >= 1 else { return Size(width: boxWidth, height: boxHeight) }
        let aspect = pw / ph
        let landscape = pw >= ph
        let minW = landscape ? minLong : minShort
        let minH = landscape ? minShort : minLong

        // Tek tip ölçek: yalnız küçült, kutuya sığdır.
        let down = min(1.0, Double(boxWidth) / pw, Double(boxHeight) / ph)
        var cw = pw * down, ch = ph * down
        // Çok küçük pencere: oranı koruyarak büyüt (kutu aşılmadan).
        if cw < Double(minW) || ch < Double(minH) {
            let up = max(Double(minW) / cw, Double(minH) / ch)
            let cap = min(Double(boxWidth) / cw, Double(boxHeight) / ch)
            let k = min(up, cap)
            cw *= k; ch *= k
        }

        // Aşırı en-boy (örn. 3000×100): içerik asgariye yetişmez → çerçeve asgariye doldurulur,
        // ScreenCaptureKit içeriği oranını koruyarak ortalar (esnetme yok, siyah dolgu).
        let padW = cw < Double(minW) - 0.5, padH = ch < Double(minH) - 0.5
        if padW || padH {
            return Size(width: padW ? minW : min(boxWidth, roundUp16(cw)),
                        height: padH ? minH : min(boxHeight, roundUp16(ch)))
        }

        let maxW = min(boxWidth, max(minW, Int(cw.rounded(.up)) + overshoot))
        let maxH = min(boxHeight, max(minH, Int(ch.rounded(.up)) + overshoot))

        struct Candidate { let w: Int, h: Int, err: Double, aligned: Bool }
        var cands: [Candidate] = []
        func consider(_ w: Int, _ h: Int) {
            guard w >= minW, w <= maxW, h >= minH, h <= maxH, w % 2 == 0, h % 2 == 0 else { return }
            let err = abs(Double(w) / Double(h) - aspect) / aspect
            let al = isAligned(w, box: boxWidth, min: minW) && isAligned(h, box: boxHeight, min: minH)
            cands.append(Candidate(w: w, h: h, err: err, aligned: al))
        }
        // Her genişlik için en yakın yükseklik ve her yükseklik için en yakın genişlik:
        // dikey pencerede biri, yatayda öteki ince ızgarayı verir.
        for w in stride(from: minW, through: maxW, by: 2) {
            let h = evenRound(Double(w) / aspect)
            consider(w, h); consider(w, h - 2); consider(w, h + 2)
        }
        for h in stride(from: minH, through: maxH, by: 2) {
            let w = evenRound(Double(h) * aspect)
            consider(w, h); consider(w - 2, h); consider(w + 2, h)
        }

        func best(_ pool: [Candidate]) -> Candidate? {
            pool.max { a, b in
                let aa = a.w * a.h, ab = b.w * b.h
                return aa != ab ? aa < ab : a.err > b.err
            }
        }
        let pick = best(cands.filter { $0.aligned && $0.err <= tightTolerance })
            ?? best(cands.filter { $0.aligned && $0.err <= tolerance })
            ?? best(cands.filter { $0.err <= tolerance })
            ?? cands.min { $0.err < $1.err }
        if let p = pick { return Size(width: p.w, height: p.h) }
        return Size(width: min(boxWidth, evenRound(cw)), height: min(boxHeight, evenRound(ch)))
    }

    /// Profilin kutusu içinde, pencerenin gerçek piksel boyutuna göre kodlama profili.
    static func encodeProfile(pixelSize: CGSize, base: H264Encoder.Profile) -> H264Encoder.Profile {
        let s = encodeSize(pixelWidth: Double(pixelSize.width), pixelHeight: Double(pixelSize.height),
                           boxWidth: base.width, boxHeight: base.height)
        return H264Encoder.Profile(width: s.width, height: s.height, fps: base.fps, bitrate: base.bitrate)
    }

    private static func isAligned(_ v: Int, box: Int, min: Int) -> Bool {
        v % 16 == 0 || v == box || v == min
    }
    private static func evenRound(_ v: Double) -> Int { Int((v / 2).rounded()) * 2 }
    private static func roundUp16(_ v: Double) -> Int { Int((v / 16).rounded(.up)) * 16 }

    // MARK: pencere ölçümü

    /// Pencerenin piksel boyutu: sınırlar (nokta) × penceredeki ekranın destek ölçeği.
    /// Nokta boyutu kullanmak Retina pencerelerini yarı çözünürlükte kodlatıyordu.
    /// CGWindowList sınırları ucuzdur (izin istemez): yeniden boyutlama yoklaması da bunu kullanır.
    static func windowPixelSize(windowId: UInt32) -> CGSize? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowId)) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              rect.width >= 1, rect.height >= 1 else { return nil }
        return pixelSize(points: rect)
    }

    /// Nokta cinsinden çerçeveyi (küresel, sol-üst orijinli) piksele çevirir.
    static func pixelSize(points rect: CGRect) -> CGSize {
        let scale = backingScale(of: rect)
        return CGSize(width: rect.width * scale, height: rect.height * scale)
    }

    /// Çerçeveyle en çok kesişen ekranın piksel/nokta oranı (kesişen yoksa 1).
    static func backingScale(of rect: CGRect) -> CGFloat {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var n: UInt32 = 0
        guard CGGetDisplaysWithRect(rect, 8, &ids, &n) == .success, n > 0 else { return 1 }
        var bestId = ids[0], bestArea: CGFloat = -1
        for id in ids.prefix(Int(n)) {
            let i = CGDisplayBounds(id).intersection(rect)
            let area = i.isNull ? 0 : i.width * i.height
            if area > bestArea { bestArea = area; bestId = id }
        }
        guard let mode = CGDisplayCopyDisplayMode(bestId), mode.width > 0 else { return 1 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }
}
