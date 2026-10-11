import CoreMedia
import Foundation
import ScreenCaptureKit

/// Mac'in kendi hoparlörüne giden sesin seviyesini ölçer: ekran sesi yakalaması,
/// sistemin çaldığı karışımı verir. Uygulama-özel susturmanın gerçekten işe yarayıp
/// yaramadığını kulak olmadan doğrulamak için — susturma penceresinde RMS düşüyorsa
/// Mac susuyor; düşmüyorsa yazılan özelliğin karşılığı yok demektir.
enum AudioMeter {
    final class Sink: NSObject, SCStreamOutput, @unchecked Sendable {
        private let lock = NSLock()
        private var sum = 0.0
        private var count = 0

        func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .audio, sb.isValid,
                  let desc = CMSampleBufferGetFormatDescription(sb),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
                  asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32,
                  let block = CMSampleBufferGetDataBuffer(sb) else { return }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                  let base = pointer else { return }
            let floats = length / MemoryLayout<Float>.size
            let p = UnsafeMutableRawPointer(base).assumingMemoryBound(to: Float.self)
            var acc = 0.0
            for i in 0..<floats { acc += Double(p[i]) * Double(p[i]) }
            lock.lock(); sum += acc; count += floats; lock.unlock()
        }

        /// Son biriken ortalama seviye, 16-bit tepesi cinsinden (0..32767).
        func drain() -> Double {
            lock.lock(); defer { lock.unlock() }
            guard count > 0 else { return 0 }
            return (sum / Double(count)).squareRoot() * 32767.0
        }
    }

    static func run(seconds: Int) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first else {
            print("ölçüm: ekran bulunamadı — Ekran Kaydı izni gerekiyor")
            return
        }
        let config = SCStreamConfiguration()
        config.width = 128
        config.height = 72
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = false
        let sink = Sink()
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: config, delegate: nil)
        do {
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: DispatchQueue(label: "atvm.meter"))
            try await stream.startCapture()
        } catch {
            print("ekran sesi yakalanamadı: \(error)")
            return
        }
        print("ekran sesi ölçümü: \(seconds) sn")
        for _ in 0..<seconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            print(String(format: "RMS=%.0f", sink.drain()))
        }
        _ = try? await stream.stopCapture()
    }
}
