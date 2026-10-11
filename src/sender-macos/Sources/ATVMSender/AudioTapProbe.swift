import CoreMedia
import Foundation

/// `atvm-sender audio-tap-test --pid N [--seconds 3] [--wav yol]`: TV'ye hiçbir şey göndermeden
/// uygulama tap'ini ve ses paketleyicisini yerelde ölçer. Çıktı sayıları ölçümdür; çalan bir
/// uygulama (ör. `afplay`) hedeflenmezse RMS 0 çıkar.
enum AudioTapProbe {
    private final class Acc: @unchecked Sendable {
        let lock = NSLock()
        var pcm: [Float] = []
        var packets: [Data] = []
        var hostFirst = 0.0, hostLast = 0.0, framesTotal = 0

        func snapshot() -> (packets: [Data], pcm: [Float], frames: Int, first: Double, last: Double) {
            lock.lock(); defer { lock.unlock() }
            return (packets, pcm, framesTotal, hostFirst, hostLast)
        }
    }

    static func run(pid: pid_t, seconds: Double, wavPath: String?) async -> Int32 {
        guard #available(macOS 14.2, *) else { emit("audio-tap-test: macOS 14.2 gerekli"); return 2 }
        let epoch = SessionEpoch.now()
        let packetizer = PcmAudioPacketizer(ssrc: 1, payloadType: 97, epoch: epoch)
        packetizer.onLog = { emit($0) }
        let acc = Acc()
        let tap = AppAudioTap(pid: pid, muteLocally: true, onFrames: { f in
            let packets = packetizer.packets(interleaved: f.samples, frames: f.frameCount,
                                             channels: f.channels, hostSeconds: f.hostSeconds)
            acc.lock.lock()
            if acc.framesTotal == 0 { acc.hostFirst = f.hostSeconds }
            acc.hostLast = f.hostSeconds + Double(f.frameCount) / 48_000
            acc.framesTotal += f.frameCount
            if wavPath != nil {
                acc.pcm.append(contentsOf: UnsafeBufferPointer(start: f.samples, count: f.frameCount * f.channels))
            }
            acc.packets.append(contentsOf: packets)
            acc.lock.unlock()
        }, log: { emit($0) })

        StopSignals.install()
        do { try tap.start() } catch {
            emit("audio-tap-test: tap kurulamadı: \(error)")
            return 3
        }
        let t0 = HostClock.now()
        while HostClock.now() - t0 < seconds && !StopSignals.requested {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        tap.stop()

        let (packets, pcm, frames, first, last) = acc.snapshot()

        // Paketlerden geri oku: RTP ts ve L16 yükünün RMS'i (kuantalanmış gerçek çıktı).
        var sumSq = 0.0, count = 0, peak = 0
        var timestamps: [UInt32] = []
        for p in packets {
            let bytes = [UInt8](p)
            var ts = UInt32(0)
            for b in bytes[4..<8] { ts = ts << 8 | UInt32(b) }
            timestamps.append(ts)
            var i = PcmAudioPacketizer.headerSize
            while i + 1 < bytes.count {
                let v = Int(Int16(bitPattern: UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])))
                sumSq += Double(v * v); count += 1; peak = max(peak, abs(v))
                i += 2
            }
        }
        let rms = count > 0 ? (sumSq / Double(count)).squareRoot() : 0
        let steps = zip(timestamps.dropFirst(), timestamps).map { Int32(truncatingIfNeeded: Int64($0) - Int64($1)) }
        let irregular = steps.filter { $0 != Int32(PcmAudioPacketizer.samplesPerPacket) }.count
        emit(String(format: "audio-tap-test: tap çağrısı=%d çerçeve=%d (%.2f sn) · RTP paketi=%d (beklenen ≈ %.0f) · L16 RMS=%.1f tepe=%d (0..32767) · ts adımı düzensiz=%d/%d · yeniden çapa=%d",
                    tap.callbacks, frames, Double(frames) / 48_000, packets.count, Double(frames) / 240,
                    rms, peak, irregular, steps.count, packetizer.reanchors))
        if let firstTs = timestamps.first, let lastTs = timestamps.last {
            let offFirst = Double(Int32(truncatingIfNeeded: Int64(firstTs) - Int64(epoch.audioBase))) / 48
            let span = Double(Int32(truncatingIfNeeded: Int64(lastTs) - Int64(firstTs))) / 48
            emit(String(format: "  ilk paket kökten %+.1f ms sonra (host: %+.1f ms) · ilk→son ts aralığı %.1f ms (host aralığı %.1f ms)",
                        offFirst, (first - epoch.hostSeconds) * 1000, span, (last - first) * 1000 - 5))
        }
        // Saat tutarlılığı: CMClock host saati ile mach tabanlı HostClock aynı eksen mi?
        let cm = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let mach = HostClock.now()
        emit(String(format: "  saat: CMClock host − mach = %+.3f ms", (cm - mach) * 1000))

        if let wavPath {
            writeWav(pcm, to: wavPath)
            emit("  wav yazıldı: \(wavPath)")
        }
        return packets.isEmpty ? 4 : 0
    }

    private static func writeWav(_ samples: [Float], to path: String) {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(samples.count * 2)
        d.append(Data("RIFF".utf8)); u32(36 + bytes); d.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(2); u32(48_000); u32(48_000 * 4); u16(4); u16(16)
        d.append(Data("data".utf8)); u32(bytes)
        for v in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32767))) }
        try? d.write(to: URL(fileURLWithPath: path))
    }
}
