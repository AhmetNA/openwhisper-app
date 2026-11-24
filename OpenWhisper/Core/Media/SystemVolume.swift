import Foundation

/// Spoken volume commands ("sesi 40 yap", "müziğin sesi çok kısık") act on the macOS
/// output volume, not Spotify's own slider. Levels are percentages, 0...100.
enum SystemVolume {

    /// Largest change one relative command may make, whatever the caller passes.
    static let maxStep = 40

    static func set(_ percent: Int) -> SpotifyActionResult {
        guard (0...100).contains(percent) else {
            return .failure("Geçersiz ses seviyesi: 0-100 arası olmalı")
        }
        return apply { _ in Float(percent) / 100 }
    }

    static func adjust(by delta: Int) -> SpotifyActionResult {
        // "Bayağı / çok kıs" halves the current level (100 → 50, 80 → 40, 30 → 15),
        // so a loud volume drops a lot and a quiet one only a little.
        if delta <= -30 {
            return apply { current in Float(percent(current / 2)) / 100 }
        }
        let step = max(-maxStep, min(maxStep, delta))
        return apply { current in Float(clamped(percent(current) + step)) / 100 }
    }

    /// The last change a volume command made, so a command re-run after correction can
    /// put the volume back first (see `SpotifyManager.undoLastCommand`).
    nonisolated(unsafe) static var lastChange: (from: Float, to: Float)?

    /// Set while Jarvis is about to say a reply: a lowering then waits in `pendingLowering`
    /// until `applyPendingLowering()`, so the reply isn't spoken at the new, quieter level.
    nonisolated(unsafe) static var defersLowering = false
    nonisolated(unsafe) private static var pendingLowering: Float?

    static func applyPendingLowering() {
        guard let target = pendingLowering else { return }
        pendingLowering = nil
        _ = AudioDucker.shared.applyVolumeCommand { _ in target }
    }

    private static func apply(_ transform: (Float) -> Float) -> SpotifyActionResult {
        if defersLowering, let current = AudioDucker.shared.volumeCommandBase() {
            let target = min(max(transform(current), 0), 1)
            if target < current {
                owLog("[SystemVolume] Lowering \(percent(current)) → \(percent(target)) after the reply")
                pendingLowering = target
                lastChange = (current, target)
                return .success(changeMessage(from: percent(current), to: percent(target)))
            }
        }
        guard let (from, to) = AudioDucker.shared.applyVolumeCommand(transform) else {
            return .failure("Ses seviyesi değiştirilemedi")
        }
        lastChange = (from, to)
        return .success(changeMessage(from: percent(from), to: percent(to)))
    }

    /// Sets the volume back to `from`, but only while it is still at `to`: if the user
    /// changed it by hand since, their change wins.
    static func revert(from: Float, to: Float) -> Bool {
        var reverted = false
        _ = AudioDucker.shared.applyVolumeCommand { current in
            guard abs(current - to) < 0.02 else { return current }
            reverted = true
            return from
        }
        owLog("[SystemVolume] Revert \(percent(to)) → \(percent(from)): \(reverted ? "done" : "skipped, volume changed since")")
        return reverted
    }

    static func percent(_ scalar: Float) -> Int {
        clamped(Int((scalar * 100).rounded()))
    }

    static func clamped(_ percent: Int) -> Int {
        max(0, min(100, percent))
    }

    static func changeMessage(from current: Int, to target: Int) -> String {
        current == target ? "Ses zaten %\(current)" : "Ses %\(current) → %\(target)"
    }
}
