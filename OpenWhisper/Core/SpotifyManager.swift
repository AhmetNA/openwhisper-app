import Foundation
import AppKit
import UserNotifications

final class SpotifyManager: @unchecked Sendable {

    static let shared = SpotifyManager()

    private init() {}

    // MARK: - Detection

    /// Check if transcribed text is a Spotify voice command.
    static func isSpotifyCommand(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let triggers = [
            "spotify",
            "müzik çal",
            "müziği başlat",
            "müziği durdur",
            "müziği kapat",
            "müzik aç",
            "şarkı çal",
            "şarkı aç",
            "sonraki şarkı",
            "önceki şarkı",
            "next song",
            "play music"
        ]
        return triggers.contains(where: { lower.contains($0) })
    }

    // MARK: - Command Handler

    func handleCommand(text: String) async -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Controls: Play/Pause/Resume
        if lower == "müzik çal" || lower == "müziği başlat" || lower == "müziği durdur" || lower == "müziği kapat" || lower == "spotify pause" || lower == "spotify play" {
            let script = "tell application \"Spotify\" to playpause"
            _ = runAppleScript(script)
            sendNotification(title: "🎵 Spotify", body: "Müzik oynatılıyor / durduruldu")
            return true
        }

        // 2. Next track
        if lower.contains("sonraki şarkı") || lower.contains("next song") {
            let script = "tell application \"Spotify\" to next track"
            _ = runAppleScript(script)
            sendNotification(title: "🎵 Spotify", body: "Sonraki şarkıya geçildi")
            return true
        }

        // 3. Previous track
        if lower.contains("önceki şarkı") || lower.contains("previous song") {
            let script = "tell application \"Spotify\" to previous track"
            _ = runAppleScript(script)
            sendNotification(title: "🎵 Spotify", body: "Önceki şarkıya geçildi")
            return true
        }

        // 4. Search and Play Song / Artist
        let query = extractSearchQuery(text: text)
        guard !query.isEmpty else {
            // Default to opening/playing Spotify if no query extracted
            let script = "tell application \"Spotify\" to play"
            _ = runAppleScript(script)
            sendNotification(title: "🎵 Spotify", body: "Spotify başlatıldı")
            return true
        }

        return playSearchQuery(query)
    }

    // MARK: - Search Query Extraction

    private func extractSearchQuery(text: String) -> String {
        var lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let junk = [
            "spotify'da", "spotify'dan", "spotify'a", "spotifyda", "spotifydan",
            "spotify", "bana", "lütfen", "şarkısını", "parçasını", "müziğini",
            "çal", "aç", "oynat", "başlat", "dinlet", "play"
        ]

        for word in junk {
            lower = lower.replacingOccurrences(of: word, with: " ")
        }

        // Clean out stray apostrophes or special punctuation left behind
        let cleaned = lower
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }

    private func playSearchQuery(_ query: String) -> Bool {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "spotify:search:\(encoded)") else { return false }

        // Open Spotify search view
        NSWorkspace.shared.open(url)

        // Give Spotify 0.6s to focus search results, then send Return key via CGEvent to play top result
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.sendReturnKeyToSpotify()
        }

        // Additional fallback tap 0.5s later if needed
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            self.sendReturnKeyToSpotify()
        }

        sendNotification(title: "🎵 Spotify", body: "\"\(query)\" çalınıyor...")
        return true
    }

    private func sendReturnKeyToSpotify() {
        guard let spotifyApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.spotify.client" }) else {
            return
        }
        spotifyApp.activate()

        let returnKeyCode: CGKeyCode = 36
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: returnKeyCode, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: returnKeyCode, keyDown: false) {
            keyDown.flags = []
            keyUp.flags = []
            keyDown.post(tap: .cghidEventTap)
            usleep(30_000)
            keyUp.post(tap: .cghidEventTap)
            owLog("[Spotify] Posted Return key CGEvent to Spotify")
        }
    }

    // MARK: - AppleScript Execution

    private func runAppleScript(_ script: String) -> String? {
        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else { return nil }
        let output = scriptObject.executeAndReturnError(&error)
        if let error = error {
            owLog("[Spotify] AppleScript error: \(error)")
            return nil
        }
        return output.stringValue
    }

    // MARK: - Notification

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "spotify-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
