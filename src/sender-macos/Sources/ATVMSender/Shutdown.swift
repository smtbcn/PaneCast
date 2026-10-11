import Dispatch
import Foundation

/// SIGINT/SIGTERM'i yakalar: süreç aniden ölmez, çağıran temiz kapanışa (tap, kodlayıcı, soket) girer.
enum StopSignals {
    private static let lock = NSLock()
    private static var flag = false
    private static var sources: [DispatchSourceSignal] = []

    static var requested: Bool { lock.lock(); defer { lock.unlock() }; return flag }

    /// `onSignal` sinyal kuyruğunda çağrılır (GUI burada `NSApp.terminate` tetikler).
    static func install(onSignal: (@Sendable () -> Void)? = nil) {
        guard sources.isEmpty else { return }
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue(label: "atvm.signal.\(sig)"))
            src.setEventHandler {
                lock.lock(); flag = true; lock.unlock()
                onSignal?()
            }
            src.resume()
            sources.append(src)
        }
    }
}
