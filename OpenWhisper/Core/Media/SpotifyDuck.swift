import AppKit
import Foundation

/// Turns Spotify's own volume well down while Jarvis speaks and while the mic listens for a
/// fix right after. Spotify's volume, not the system's: that would quiet Jarvis too. Music kept
/// playing there (or resumed under the follow-up window) reached the transcript (27 Oct 2026).
///
/// Holds are counted: a reply and the follow-up window it opens overlap. The volume comes back
/// with the last release, and only if nobody changed it meanwhile ("Spotify sesi 40 olsun").
final class SpotifyDuck: @unchecked Sendable {
    static let shared = SpotifyDuck()

    /// Share of the user's Spotify volume kept while ducked.
    static let duckedShare = 0.2

    /// Queue-confined.
    private let queue = DispatchQueue(label: "com.openwhisper.spotify-duck", qos: .userInitiated)
    private var holds = 0
    private var saved: Int?
    private var ducked: Int?

    func hold() {
        queue.async { [self] in
            holds += 1
            guard holds == 1, saved == nil, Self.spotifyRunning, let volume = Self.volume() else { return }
            let target = Self.duckedVolume(from: volume)
            guard target < volume, Self.setVolume(target) else { return }
            saved = volume
            ducked = target
            owLog("[SpotifyDuck] Spotify volume \(volume) → \(target) while Jarvis talks and listens")
        }
    }

    func release() {
        queue.async { [self] in
            holds = max(0, holds - 1)
            guard holds == 0 else { return }
            restore()
        }
    }

    /// App termination: never leave Spotify quiet.
    func restoreImmediately() {
        queue.sync { holds = 0; restore() }
    }

    static func duckedVolume(from volume: Int) -> Int {
        min(volume, max(3, Int((Double(volume) * duckedShare).rounded())))
    }

    /// Queue only.
    private func restore() {
        guard let saved, let ducked else { return }
        self.saved = nil
        self.ducked = nil
        guard Self.spotifyRunning, let current = Self.volume() else { return }
        // Spotify reports a set volume one or two off.
        guard abs(current - ducked) <= 2 else {
            owLog("[SpotifyDuck] Volume changed meanwhile (\(current)); left as it is")
            return
        }
        if Self.setVolume(saved) { owLog("[SpotifyDuck] Spotify volume back to \(saved)") }
    }

    /// Never launches Spotify: `tell application` would.
    private static var spotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: SpotifyController.spotifyBundleID).isEmpty
    }

    private static func volume() -> Int? {
        run("tell application \"Spotify\" to get sound volume").flatMap { Int($0) }
    }

    private static func setVolume(_ volume: Int) -> Bool {
        run("tell application \"Spotify\" to set sound volume to \(volume)") != nil
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: "with timeout of 2 seconds\n\(source)\nend timeout") else { return nil }
        let output = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return output.stringValue ?? ""
    }
}
