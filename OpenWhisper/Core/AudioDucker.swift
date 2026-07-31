import Foundation

final class AudioDucker: @unchecked Sendable {

    static let shared = AudioDucker()

    private var originalVolume: Int?
    private var fadeTimer: Timer?
    private let lock = NSLock()

    private init() {}

    /// Lower system volume to target percentage (default 30%) instantly when dictation starts
    func duckVolume(targetVolume: Int = 30) {
        lock.lock()
        defer { lock.unlock() }

        // Cancel any active restoration fade timer if Fn is pressed again quickly
        DispatchQueue.main.async {
            self.fadeTimer?.invalidate()
            self.fadeTimer = nil
        }

        guard originalVolume == nil else { return } // already ducked

        let current = getCurrentVolume()
        if current > targetVolume {
            originalVolume = current
            setSystemVolume(targetVolume)
            owLog("[AudioDucker] Instant ducked volume from \(current)% to \(targetVolume)%")
        }
    }

    /// Smoothly restore system volume back to original level over ~0.35s when dictation ends
    func restoreVolume() {
        lock.lock()
        guard let target = originalVolume else {
            lock.unlock()
            return
        }
        originalVolume = nil
        lock.unlock()

        let current = getCurrentVolume()
        guard current < target else { return }

        let steps = 10
        let interval = 0.035 // 35ms per step -> ~0.35s total smooth fade-in
        let stepDelta = Double(target - current) / Double(steps)

        DispatchQueue.main.async {
            self.fadeTimer?.invalidate()
            var currentStep = 0
            var runningVolume = Double(current)

            self.fadeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
                currentStep += 1
                runningVolume += stepDelta
                let vol = min(Int(round(runningVolume)), target)
                self.setSystemVolume(vol)

                if currentStep >= steps || vol >= target {
                    timer.invalidate()
                    self.fadeTimer = nil
                    self.setSystemVolume(target)
                    owLog("[AudioDucker] Smooth fade-in completed to \(target)%")
                }
            }
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
