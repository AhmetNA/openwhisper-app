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
        let step = max(-maxStep, min(maxStep, delta))
        return apply { current in Float(clamped(percent(current) + step)) / 100 }
    }

    private static func apply(_ transform: (Float) -> Float) -> SpotifyActionResult {
        guard let (from, to) = AudioDucker.shared.applyVolumeCommand(transform) else {
            return .failure("Ses seviyesi değiştirilemedi")
        }
        return .success(changeMessage(from: percent(from), to: percent(to)))
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
