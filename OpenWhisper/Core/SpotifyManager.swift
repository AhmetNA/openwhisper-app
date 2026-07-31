import Foundation
import AppKit
import UserNotifications

final class SpotifyManager: @unchecked Sendable {

    static let shared = SpotifyManager()

    private init() {}

    // MARK: - Shared Command Table
    //
    // Both the gate (`isSpotifyCommand`) and the handler (`handleCommand`) read from this
    // single table so they can never drift out of sync. Order matters: more specific /
    // longer phrases must come before shorter ones they contain (e.g. "müziği durdur"
    // before bare "durdur") since matching is leading-prefix based.

    private enum TransportCommand {
        case pause
        case play
        case next
        case previous
    }

    private static let transportPrefixes: [(String, TransportCommand)] = [
        ("müziği durdur", .pause),
        ("müzik durdur", .pause),
        ("müziği kapat", .pause),
        ("müzik kapat", .pause),
        ("spotify pause", .pause),
        ("spotify durdur", .pause),
        ("durdur", .pause),
        ("kapat", .pause),

        ("müziği başlat", .play),
        ("müzik başlat", .play),
        ("müziği çal", .play),
        ("müzik çal", .play),
        ("müziği aç", .play),
        ("müzik aç", .play),
        ("müziği oynat", .play),
        ("müzik oynat", .play),
        ("şarkı çal", .play),
        ("şarkı aç", .play),
        ("spotify play", .play),
        ("play music", .play),
        ("başlat", .play),

        ("sonraki şarkı", .next),
        ("sonraki parça", .next),
        ("sonraki", .next),
        ("next song", .next),
        ("next track", .next),

        ("önceki şarkı", .previous),
        ("önceki parça", .previous),
        ("önceki", .previous),
        ("previous song", .previous),
        ("prev track", .previous)
    ]

    /// Play-family prefixes whose trailing residue should be treated as a search query
    /// rather than a plain "resume playback" instruction — e.g. "müzik çal Tarkan" means
    /// search+play "Tarkan", not a bare resume. Pause/next/prev never do this: residue
    /// after those is just noise ("durdur lütfen") and is ignored.
    private static let playFamilyPrefixes: Set<String> = [
        "müziği başlat", "müzik başlat", "müziği çal", "müzik çal",
        "müziği aç", "müzik aç", "müziği oynat", "müzik oynat",
        "şarkı çal", "şarkı aç", "spotify play", "play music", "başlat"
    ]

    /// Words stripped from a search-query residue. Filtered as whole words (not substring
    /// replacement) so we don't mangle artist/song names that happen to contain these
    /// letter sequences (e.g. "açık", "ağaç").
    private static let searchJunkWords: Set<String> = [
        "spotifyda", "spotifydan", "spotifya", "spotify",
        "bana", "lütfen", "şarkısını", "şarkısı", "parçasını", "müziğini",
        "çal", "aç", "oynat", "başlat", "dinlet", "play", "adlı"
    ]

    private static let maxCommandWordCount = 8

    /// Prefix match with a word-boundary check, so "durdur" doesn't also match
    /// "durdurma şarkısını çal" or "kapat" match "kapatma...".
    private static func hasCommandPrefix(_ normalized: String, _ prefix: String) -> Bool {
        guard normalized.hasPrefix(prefix) else { return false }
        if normalized.count == prefix.count { return true }
        let indexAfterPrefix = normalized.index(normalized.startIndex, offsetBy: prefix.count)
        return normalized[indexAfterPrefix] == " "
    }

    // MARK: - Normalization

    private static func normalize(_ text: String) -> String {
        var lower = text.lowercased(with: Locale(identifier: "tr_TR"))
        lower = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = lower.unicodeScalars.last, CharacterSet(charactersIn: ".!?,;:").contains(last) {
            lower.removeLast()
        }
        lower = lower.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return lower.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Detection

    /// Check if transcribed text is a Spotify voice command. Deliberately tight: it only
    /// fires on a recognized *leading* command phrase (not "contains anywhere") and caps
    /// the sentence length, so an ordinary dictation that happens to mention "spotify" or
    /// "durdur" mid-sentence is not swallowed as a command.
    static func isSpotifyCommand(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }

        let wordCount = normalized.split(separator: " ").count
        guard wordCount <= maxCommandWordCount else { return false }

        // "spotify" is a proper noun that takes Turkish case suffixes ("spotify'da",
        // "spotifydan"), so match it as a whole leading token rather than requiring an
        // exact word boundary — a plain hasCommandPrefix would reject "spotify'da...".
        if normalized.split(separator: " ").first?.hasPrefix("spotify") == true { return true }
        return transportPrefixes.contains { hasCommandPrefix(normalized, $0.0) }
    }

    // MARK: - Command Handler

    /// Handles a transcript already identified as a Spotify command.
    ///
    /// Return contract (this is load-bearing for the caller in `AppState`, which pastes
    /// the raw transcript as normal dictation whenever this returns `false`):
    /// - `true`  — the command was actually applied (verified where practical, e.g. via
    ///             `player state`), so the transcript should be swallowed, not pasted.
    /// - `false` — nothing happened. This includes AppleScript permission errors: on a
    ///             fresh install/rebuild the *first* command always fails this way while
    ///             macOS shows the Automation consent dialog, and swallowing that
    ///             transcript would make the app look broken twice over — the command
    ///             didn't run *and* the user's words vanished. A notification about the
    ///             permission is still shown, but the text falls through to normal
    ///             dictation so it isn't lost.
    func handleCommand(text: String) async -> Bool {
        let normalized = Self.normalize(text)

        // 1. Leading transport phrase (longest/most-specific match wins per table order).
        if let (prefix, command) = Self.transportPrefixes.first(where: { Self.hasCommandPrefix(normalized, $0.0) }) {
            let residue = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)

            if command == .play, Self.playFamilyPrefixes.contains(prefix), !residue.isEmpty {
                let query = extractSearchQuery(residue)
                if !query.isEmpty {
                    return await playSearchQuery(query)
                }
            }

            return await runTransport(command)
        }

        // 2. Bare "spotify ..." with no recognized verb → remainder is a search query.
        //    Drop the whole first token (not just the "spotify" prefix) so a Turkish case
        //    suffix like "'da"/"'dan" doesn't leak into the search text.
        var tokens = normalized.split(separator: " ").map(String.init)
        if tokens.first?.hasPrefix("spotify") == true {
            tokens.removeFirst()
            let residue = tokens.joined(separator: " ")
            let query = extractSearchQuery(residue)
            if !query.isEmpty {
                return await playSearchQuery(query)
            }

            // "Spotify" said alone with nothing else — toggle playback as a safe fallback.
            switch runAppleScript("tell application \"Spotify\" to playpause") {
            case .success:
                sendNotification(title: "🎵 Spotify", body: "Spotify oynatma durumu değiştirildi")
                return true
            case .failure(let error):
                return handleScriptError(error)
            }
        }

        return false
    }

    // MARK: - Transport

    /// Runs a transport command and returns whether it actually took effect (see
    /// `handleCommand` for the return contract this feeds into).
    private func runTransport(_ command: TransportCommand) async -> Bool {
        let script: String
        let successBody: String

        switch command {
        case .pause:
            script = "tell application \"Spotify\" to pause"
            successBody = "Müzik durduruldu"
        case .play:
            script = """
                tell application "Spotify"
                    activate
                    play
                end tell
                """
            successBody = "Müzik oynatılıyor"
        case .next:
            script = "tell application \"Spotify\" to next track"
            successBody = "Sonraki şarkıya geçildi"
        case .previous:
            script = "tell application \"Spotify\" to previous track"
            successBody = "Önceki şarkıya geçildi"
        }

        switch runAppleScript(script) {
        case .success:
            // AppleScript returning success only means the command was accepted, not
            // that audio is actually flowing — e.g. "play" with nothing queued succeeds
            // but plays nothing. Verify actual playback state before claiming success.
            if command == .play {
                if await confirmPlaying() {
                    sendNotification(title: "🎵 Spotify", body: successBody)
                    return true
                } else {
                    sendNotification(
                        title: "🎵 Spotify",
                        body: "Komut kabul edildi ama Spotify çalmıyor. Çalma listesi boş olabilir."
                    )
                    return false
                }
            } else {
                sendNotification(title: "🎵 Spotify", body: successBody)
                return true
            }
        case .failure(let error):
            return handleScriptError(error)
        }
    }

    // MARK: - Search Query Extraction

    private func extractSearchQuery(_ residue: String) -> String {
        let words = residue
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !Self.searchJunkWords.contains($0) }

        return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Search and Play

    private let tabKeyCode: CGKeyCode = 48
    private let returnKeyCode: CGKeyCode = 36

    /// Searches Spotify for `query` and tries to play the top result, returning whether
    /// playback was actually confirmed (see `handleCommand` for the return contract).
    private func playSearchQuery(_ query: String) async -> Bool {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "spotify:search:\(encoded)") else {
            sendNotification(title: "🎵 Spotify", body: "\"\(query)\" için arama başlatılamadı.")
            return false
        }

        sendNotification(title: "🎵 Spotify", body: "\"\(query)\" aranıyor...")
        NSWorkspace.shared.open(url)

        guard await waitUntilSpotifyFrontmost(timeout: 3.0) else {
            sendNotification(title: "🎵 Spotify", body: "Spotify öne getirilemedi, arama sonucu çalınamadı.")
            return false
        }

        // Spotify's AppleScript dictionary has no "play top search result" verb, so this
        // falls back to UI automation: wait for the search results to render, move focus
        // to the top result, then press Return. Inherently fragile — kept honest with a
        // real playback check afterward rather than assumed to have worked.
        try? await Task.sleep(nanoseconds: 700_000_000)
        postKey(code: tabKeyCode)
        try? await Task.sleep(nanoseconds: 150_000_000)
        postKey(code: returnKeyCode)

        if await confirmPlaying() {
            sendNotification(title: "🎵 Spotify", body: "\"\(query)\" çalınıyor")
            return true
        }

        // One retry before giving up honestly.
        postKey(code: returnKeyCode)
        if await confirmPlaying() {
            sendNotification(title: "🎵 Spotify", body: "\"\(query)\" çalınıyor")
            return true
        } else {
            sendNotification(
                title: "🎵 Spotify",
                body: "\"\(query)\" otomatik oynatılamadı. Spotify'ı kontrol edin."
            )
            return false
        }
    }

    private func waitUntilSpotifyFrontmost(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        if let spotify = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.spotify.client" }) {
            spotify.activate()
        }
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.spotify.client" {
                return true
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.spotify.client"
    }

    private func confirmPlaying() async -> Bool {
        try? await Task.sleep(nanoseconds: 400_000_000)
        switch runAppleScript("tell application \"Spotify\" to player state") {
        case .success(let state):
            return state == "playing"
        case .failure:
            return false
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

    private enum SpotifyScriptError: Error {
        case permissionDenied(errorNumber: Int)
        case appNotRunning
        case other(errorNumber: Int, message: String)
    }

    private func runAppleScript(_ script: String) -> Result<String?, SpotifyScriptError> {
        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            return .failure(.other(errorNumber: -1, message: "Failed to parse AppleScript"))
        }
        let output = scriptObject.executeAndReturnError(&error)
        if let error = error {
            let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            owLog("[Spotify] AppleScript error \(number): \(message)")

            switch number {
            case -1743, -1744:
                // -1743: user denied Automation access. -1744: process couldn't even
                // prompt for consent (same root cause from the user's point of view).
                return .failure(.permissionDenied(errorNumber: number))
            case -600:
                return .failure(.appNotRunning)
            default:
                return .failure(.other(errorNumber: number, message: message))
            }
        }
        return .success(output.stringValue)
    }

    /// Shows an honest failure notification and reports whether the transcript should
    /// still be swallowed (see `handleCommand`'s doc comment for the contract). Every
    /// branch here returns `false`: nothing was actually done to Spotify in any of these
    /// cases, so the dictation falls through to normal paste rather than being lost.
    private func handleScriptError(_ error: SpotifyScriptError) -> Bool {
        switch error {
        case .permissionDenied:
            sendNotification(
                title: "🎵 Spotify",
                body: "Spotify kontrolü için izin gerekli — Sistem Ayarları > Gizlilik ve Güvenlik > Otomasyon > OpenWhisper > Spotify açık olmalı."
            )
        case .appNotRunning:
            sendNotification(title: "🎵 Spotify", body: "Spotify çalışmıyor görünüyor.")
        case .other(let number, let message):
            owLog("[Spotify] Command failed (\(number)): \(message)")
            sendNotification(title: "🎵 Spotify", body: "Spotify komutu başarısız oldu (\(number)).")
        }
        return false
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
