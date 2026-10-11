#!/bin/bash
# macOS VideoToolbox donanım kodlayıcı envanteri + 1080p60 H.264 kodlama hızı/gecikme ölçümü.
# EKRAN KAYDI IZNİ GEREKTİRMEZ: kareleri kendimiz üretiyoruz (NV12 test deseni).
# Kullanım: ./scripts/mac-encoder-probe.sh [kareSayısı]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/artifacts/probe"
mkdir -p "$BUILD"
SRC="$BUILD/vtprobe.swift"
BIN="$BUILD/vtprobe"

cat > "$SRC" <<'SWIFT'
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

let FRAMES = Int(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "300") ?? 300
let W = 1920, H = 1080, FPS = 60

func k(_ s: CFString) -> String { s as String }

print("=== VTCopyVideoEncoderList ===")
var arr: CFArray?
if VTCopyVideoEncoderList(nil, &arr) == noErr, let list = arr as? [[AnyHashable: Any]] {
    for e in list {
        let codec = e[k(kVTVideoEncoderList_CodecName)] as? String ?? "?"
        let name  = e[k(kVTVideoEncoderList_EncoderName)] as? String ?? "?"
        let id    = e[k(kVTVideoEncoderList_EncoderID)] as? String ?? "?"
        let hw    = (e[k(kVTVideoEncoderList_IsHardwareAccelerated)] as? Bool).map { $0 ? "HW" : "sw" } ?? "?"
        let reord = (e[k(kVTVideoEncoderList_SupportsFrameReordering)] as? Bool).map { $0 ? "B-frame" : "no-B" } ?? "?"
        let perf  = e[k(kVTVideoEncoderList_PerformanceRating)] as? Int ?? -1
        let qual  = e[k(kVTVideoEncoderList_QualityRating)] as? Int ?? -1
        print("  codec=\(codec)  \(hw)  \(name)  reorder=\(reord)  perf=\(perf) qual=\(qual)  id=\(id)")
    }
} else { print("  encoder listesi alınamadı") }

func makeBuffer(_ seed: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as Any]
    let r = CVPixelBufferCreate(kCFAllocatorDefault, W, H,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb)
    precondition(r == kCVReturnSuccess && pb != nil, "CVPixelBufferCreate \(r)")
    let buf = pb!
    CVPixelBufferLockBaseAddress(buf, [])
    let yb = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!
    let ys = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
    let cb = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!
    let cs = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
    for row in 0..<H {
        let p = (yb + row * ys).assumingMemoryBound(to: UInt8.self)
        for col in 0..<W { p[col] = UInt8((col &+ row &* 3 &+ seed) & 0xFF) }
    }
    for row in 0..<(H / 2) {
        let p = (cb + row * cs).assumingMemoryBound(to: UInt8.self)
        for col in 0..<cs { p[col] = UInt8(((col &+ row &+ seed) & 0x7F) + 64) }
    }
    CVPixelBufferUnlockBaseAddress(buf, [])
    return buf
}

final class FrameCtx { let submit: Double; init(_ t: Double) { submit = t } }
final class Sink {
    var count = 0, bytes = 0, keyframes = 0, dropped = 0
    var lat: [Double] = []
    var firstOut: Double = 0, lastOut: Double = 0
    let lock = NSLock()
}
let sink = Sink()
let t0 = CFAbsoluteTimeGetCurrent()

let callback: VTCompressionOutputCallback = { _, srcRefCon, status, infoFlags, sb in
    guard let srcRefCon = srcRefCon else { return }
    let ctx = Unmanaged<FrameCtx>.fromOpaque(srcRefCon).takeRetainedValue()
    let now = CFAbsoluteTimeGetCurrent()
    sink.lock.lock()
    if status == noErr, let sb = sb {
        if sink.count == 0 { sink.firstOut = now }
        sink.count += 1
        sink.lat.append((now - ctx.submit) * 1000.0)
        sink.bytes += CMSampleBufferGetTotalSampleSize(sb)
        if infoFlags.contains(.frameDropped) { sink.dropped += 1 }
        // kCMSampleAttachmentKey_NotSync == true  => kare bağımsız çözülemez (inter/P-frame).
        // Dolayısıyla sync (keyframe) sayısı = NotSync OLMAYAN kareler.
        let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [[String: Any]])?.first
        if (att?["NotSync"] as? Bool) != true { sink.keyframes += 1 }
    } else if status != noErr {
        print("  CALLBACK HATA: \(status)")
    }
    sink.lastOut = now
    sink.lock.unlock()
}

let spec: [String: Any] = [
    kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
    kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
]
var session: VTCompressionSession?
let crt = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(W), height: Int32(H),
    codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
    imageBufferAttributes: nil, compressedDataAllocator: nil,
    outputCallback: callback, refcon: nil, compressionSessionOut: &session)
if crt != noErr { print("!!! donanım kodlayıcı açılamadı: OSStatus \(crt)"); exit(1) }
let sess = session!

let props: [String: Any] = [
    kVTCompressionPropertyKey_RealTime as String: true,
    kVTCompressionPropertyKey_AllowFrameReordering as String: false,
    kVTCompressionPropertyKey_ExpectedFrameRate as String: FPS,
    kVTCompressionPropertyKey_AverageBitRate as String: 12_000_000,
    kVTCompressionPropertyKey_DataRateLimits as String: [12_000_000 / 8, 1],
    kVTCompressionPropertyKey_MaxKeyFrameInterval as String: 300,
    kVTCompressionPropertyKey_ProfileLevel as String: kVTProfileLevel_H264_High_AutoLevel,
]
let setr = VTSessionSetProperties(sess, propertyDictionary: props as CFDictionary)
if setr != noErr { print("  (uyarı: kodlayıcı özellikleri tam kabul edilmedi: \(setr))") }
VTCompressionSessionPrepareToEncodeFrames(sess)

let bufs = (0..<3).map { makeBuffer($0 * 37) }
var pacingOverrun = 0.0
for i in 0..<FRAMES {
    let target = t0 + Double(i) / Double(FPS)
    let now = CFAbsoluteTimeGetCurrent()
    if target > now { Thread.sleep(forTimeInterval: target - now) } else { pacingOverrun += now - target }
    let pts = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(FPS))
    let ctx = Unmanaged.passRetained(FrameCtx(CFAbsoluteTimeGetCurrent()))
    let r = VTCompressionSessionEncodeFrame(sess, imageBuffer: bufs[i % bufs.count],
        presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: CMTimeScale(FPS)),
        frameProperties: nil, sourceFrameRefcon: ctx.toOpaque(), infoFlagsOut: nil)
    if r != noErr { print("  encodeFrame hata \(r) @\(i)") }
}
VTCompressionSessionCompleteFrames(sess, untilPresentationTimeStamp: CMTime.invalid)
let wall = CFAbsoluteTimeGetCurrent() - t0
VTCompressionSessionInvalidate(sess)

sink.lock.lock()
let lat = sink.lat.sorted()
func pct(_ p: Double) -> Double { lat.isEmpty ? -1 : lat[min(lat.count - 1, Int(Double(lat.count) * p))] }
print("\n=== 1080p60 H.264 VideoToolbox sonucu (gerçek zamanlı pacing) ===")
print("  config: requireHW=1, RealTime=1, AllowFrameReordering=0, 12 Mbps, High profile, GOP 300")
print("  gönderilen=\(FRAMES)  çıkan=\(sink.count)  drop=\(sink.dropped)  sync(keyframe)=\(sink.keyframes)  inter=\(sink.count - sink.keyframes)")
print("  duvar süresi=\(String(format: "%.2f", wall)) s  ->  fps=\(String(format: "%.1f", Double(sink.count) / wall))")
print("  bitrate=\(String(format: "%.2f", Double(sink.bytes) * 8 / wall / 1_000_000)) Mbps")
print(String(format: "  submit->callback gecikmesi: p50=%.2f ms  p95=%.2f ms  max=%.2f ms",
             pct(0.5), pct(0.95), lat.last ?? 0))
print("  ilk kare çıkışı=\(String(format: "%.1f", (sink.firstOut - t0) * 1000)) ms")
print("  pacing taşması=\(String(format: "%.2f", pacingOverrun)) s")
sink.lock.unlock()
SWIFT

rm -f "$BIN"
if ! swiftc -O "$SRC" -o "$BIN" -framework VideoToolbox -framework CoreMedia -framework CoreVideo; then
  echo "derleme başarısız"; exit 1
fi
"$BIN" "${1:-300}"
