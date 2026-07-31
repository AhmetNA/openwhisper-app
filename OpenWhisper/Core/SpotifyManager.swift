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

    // MARK: - Command Handler

    func handleCommand(text: String) async -> Bool {
        let cleanText = text
            .lowercased()
            .components(separatedBy: CharacterSet.letters.union(.whitespaces).inverted)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Controls: Play / Pause / Resume
        let playPauseKeywords = [
            "müzik çal", "müziği çal", "müziği başlat", "müzik başlat",
            "müziği durdur", "müzik durdur", "müziği kapat", "müzik kapat",
            "müziği aç", "müzik aç", "spotify pause", "spotify play",
            "müzik oynat", "müziği oynat"
        ]

        if playPauseKeywords.contains(where: { cleanText == $0 || cleanText.hasPrefix($0) }) {
            let script = "tell application \"Spotify\" to playpause"
            _ = runAppleScript(script)
            sendNotification(title: "🎵 Spotify", body: "Müzik oynatılıyor / durduruldu")
            return true
        }

        // 2. Next track
        if cleanText.contains("sonraki") || cleanText.contains("next song") || cleanText.contains("next track") {
            let script = "tell application \"Spotify\" to next track"
            _ = runAppleScript(script)
            sendNotification(title: "🎵 Spotify", body: "Sonraki şarkıya geçildi")
            return true
        }

        // 3. Previous track
        if cleanText.contains("önceki") || cleanText.contains("previous song") || cleanText.contains("prev track") {
            let script = "tell application \"Spotify\" to previous track"
            _ = runAppleScript(script)
            sendNotification(title: "🎵 Spotify", body: "Önceki şarkıya geçildi")
            return true
        }

        // 4. Search and Play Song / Artist
        let query = extractSearchQuery(text: text)
        guard !query.isEmpty else {
            let script = "tell application \"Spotify\" to playpause"
            _ = runAppleScript(script)
            sendNotification(title: "🎵 Spotify", body: "Spotify oynatılıyor")
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

        // Give Spotify 0.6s to render search results, then navigate & play top result
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.sendPlayToSpotify()
        }

        // Secondary fallback 0.6s later
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.sendPlayToSpotify()
        }

        sendNotification(title: "🎵 Spotify", body: "\"\(query)\" çalınıyor...")
        return true
    }

    private func sendPlayToSpotify() {
        guard let spotifyApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.spotify.client" }) else {
            _ = runAppleScript("tell application \"Spotify\" to play")
            return
        }
        spotifyApp.activate()

        let tabKeyCode: CGKeyCode = 48
        let returnKeyCode: CGKeyCode = 36

        // Move focus from search bar input to top result card, then press Return
        postKey(code: tabKeyCode)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.postKey(code: returnKeyCode)
            _ = self.runAppleScript("tell application \"Spotify\" to play")
        }
    }

    private func postKey(code: CGKeyCode) {
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) {
            keyDown.flags = []
            keyUp.flags = []
            keyDown.post(tap: .cghidEventTap)
            usleep(20_000)
            keyUp.post(tap: .cghidEventTap)
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
