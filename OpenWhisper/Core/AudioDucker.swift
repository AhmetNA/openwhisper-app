import Foundation

final class AudioDucker: @unchecked Sendable {

    static let shared = AudioDucker()

    private var originalVolume: Int?
    private let lock = NSLock()

    private init() {}

    /// Lower system volume to target percentage (default 30%) when dictation starts
    func duckVolume(targetVolume: Int = 30) {
        lock.lock()
        defer { lock.unlock() }

        guard originalVolume == nil else { return } // already ducked

        let current = getCurrentVolume()
        if current > targetVolume {
            originalVolume = current
            setSystemVolume(targetVolume)
            owLog("[AudioDucker] Ducked volume from \(current)% to \(targetVolume)%")
        }
    }

    /// Restore system volume back to original level when dictation ends
    func restoreVolume() {
        lock.lock()
        let previous = originalVolume
        originalVolume = nil
        lock.unlock()

        if let previous = previous {
            setSystemVolume(previous)
            owLog("[AudioDucker] Restored volume to \(previous)%")
        }
    }

    private func getCurrentVolume() -> Int {
        var error: NSDictionary?
        let script = "output volume of (get volume settings)"
        guard let scriptObject = NSAppleScript(source: script) else { return 50 }
        let output = scriptObject.executeAndReturnError(&error)
        return Int(output.int32Value)
    }

    private func setSystemVolume(_ volume: Int) {
        let script = "set volume output volume \(volume)"
        guard let scriptObject = NSAppleScript(source: script) else { return }
        var error: NSDictionary?
        scriptObject.executeAndReturnError(&error)
    }
}
