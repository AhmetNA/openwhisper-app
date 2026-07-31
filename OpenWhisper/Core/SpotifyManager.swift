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
        var clean = text
        let stripPhrases = [
            "spotify'da", "spotify'dan", "spotify da", "spotify dan", "spotify",
            "bana", "çal", "aç", "oynat", "başlat", "dinlet", "play"
        ]
        for phrase in stripPhrases {
            let regex = try? NSRegularExpression(pattern: "(?i)\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b", options: [])
            clean = regex?.stringByReplacingMatches(in: clean, options: [], range: NSRange(location: 0, length: clean.utf16.count), withTemplate: "") ?? clean
        }
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func playSearchQuery(_ query: String) -> Bool {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return false }

        // Open Spotify URI search & play via AppleScript
        let script = """
            tell application "Spotify"
                activate
                open location "spotify:search:\(encoded)"
            end tell
            """
        _ = runAppleScript(script)

        // Give Spotify a brief moment to open search, then issue play
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            let playScript = "tell application \"Spotify\" to play"
            _ = self.runAppleScript(playScript)
        }

        sendNotification(title: "🎵 Spotify", body: "\"\(query)\" aranıyor ve çalınıyor...")
        return true
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
