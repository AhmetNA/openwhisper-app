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
        /// "beğenilenleri çal" and friends — play a random track from the user's Liked
        /// Songs. Listed first in `transportPrefixes` (see that table's ordering note):
        /// none of these phrases start with "spotify" or share a prefix with the
        /// play-family entries below, but placing them first keeps this command
        /// unambiguous against the generic play-family residue-as-search-query path
        /// (step 1 in `handleCommand` always wins over step 2's bare "spotify ..." search
        /// fallback, and these are checked as part of step 1).
        case playLiked
    }

    private static let transportPrefixes: [(String, TransportCommand)] = [
        ("spotify'da beğenilenleri çal", .playLiked),
        ("spotifyda beğenilenleri çal", .playLiked),
        ("spotify'da beğendiklerimi çal", .playLiked),
        ("spotifyda beğendiklerimi çal", .playLiked),
        ("spotify'da beğenilen şarkılar", .playLiked),
        ("spotifyda beğenilen şarkılar", .playLiked),
        ("spotify'da beğenilenler", .playLiked),
        ("spotifyda beğenilenler", .playLiked),
        ("spotify'da beğendiklerim", .playLiked),
        ("spotifyda beğendiklerim", .playLiked),
        ("beğenilenleri çal", .playLiked),
        ("beğendiklerimi çal", .playLiked),
        ("beğenilen şarkılar", .playLiked),
        ("beğenilenler", .playLiked),
        ("beğendiklerim", .playLiked),
        ("liked songs", .playLiked),

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

    // MARK: - Detection & LLM Intent Classification

    /// Check if transcribed text is a Spotify voice command.
    /// When Ollama is available, uses local LLM intent classification to verify
    /// whether the user truly intended to trigger music playback vs regular dictation.
    static func isSpotifyCommand(_ text: String, ollamaAvailable: Bool = false) async -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return false }

        let wordCount = normalized.split(separator: " ").count
        guard wordCount <= maxCommandWordCount else { return false }

        // Fast candidate pre-check: must start with "spotify" or contain music-related keywords
        let musicKeywords = ["spotify", "müzik", "muzik", "şarkı", "sarki", "parça", "playlist", "albüm", "beğenilen", "beğendik", "çal", "cal", "çalıyor", "caliyor", "oynat", "başlat", "durdur", "kapat", "sesi", "ses ", "dinlemek", "liste"]
        let isCandidate = (normalized.split(separator: " ").first?.hasPrefix("spotify") == true) ||
                          musicKeywords.contains(where: { normalized.contains($0) }) ||
                          transportPrefixes.contains { hasCommandPrefix(normalized, $0.0) }

        guard isCandidate else { return false }

        // If Ollama is available, perform LLM intent classification
        if ollamaAvailable {
            if let llmVerdict = await verifyIntentWithOllama(text: text) {
                owLog("[Spotify] Ollama intent classification for '\(text)': \(llmVerdict)")
                return llmVerdict
            }
        }

        // Strict heuristic fallback (when Ollama is unavailable or times out)
        return isStrictSpotifyCommand(normalized)
    }

    /// Strict heuristic matching used as a fallback when Ollama is not available.
    /// Excludes bare ambiguous single words like "başlat", "kapat", "durdur", "sonraki", "önceki"
    /// unless accompanied by explicit music context.
    private static func isStrictSpotifyCommand(_ normalized: String) -> Bool {
        let explicitKeywords = ["spotify", "müzik", "şarkı", "beğenilen", "beğendik", "parça", "playlist", "albüm", "liked songs", "sesi", "çalıyor", "liste", "dinlemek"]
        if explicitKeywords.contains(where: { normalized.contains($0) }) {
            return true
        }

        let ambiguousPrefixes: Set<String> = ["başlat", "kapat", "durdur", "sonraki", "önceki"]
        if let (prefix, _) = transportPrefixes.first(where: { hasCommandPrefix(normalized, $0.0) }) {
            if !ambiguousPrefixes.contains(prefix) {
                return true
            }
        }

        return false
    }

    /// Uses local Ollama LLM to classify whether the voice transcript is an intentional
    /// command to play music or control Spotify, rather than general dictation.
    private static func verifyIntentWithOllama(text: String) async -> Bool? {
        guard let url = URL(string: "http://localhost:11434/api/generate") else { return nil }

        let prompt = """
            You are a voice command intent classifier for a Mac speech-to-text application.
            Determine whether the following spoken transcript is an INTENTIONAL VOICE COMMAND to play music, search for a song, query currently playing track, change volume, or control Spotify/music playback.

            CRITICAL RULES:
            - If the transcript is normal spoken prose, dictation, a general question, or general conversation that merely happens to contain common verbs or words, answer false.
            - Answer true ONLY if the primary intent of the user is to trigger music playback or control music playback.

            EXAMPLES:
            - "spotify'da tarkan çal" -> {"is_music_command": true}
            - "müziği durdur" -> {"is_music_command": true}
            - "sonraki şarkıya geç" -> {"is_music_command": true}
            - "sesi yüzde 50 yap" -> {"is_music_command": true}
            - "şu an ne çalıyor" -> {"is_music_command": true}
            - "çalan şarkıyı beğenilenlerime ekle" -> {"is_music_command": true}
            - "sporda dinlemek için hareketli bir müzik aç" -> {"is_music_command": true}
            - "bana arkada çalacak dinlendirici bir liste aç" -> {"is_music_command": true}
            - "bu projeyi bugün başlatacağız" -> {"is_music_command": false}
            - "kapıyı kapat lütfen" -> {"is_music_command": false}
            - "durdur şu işlemi" -> {"is_music_command": false}

            Respond ONLY with a JSON object: {"is_music_command": true} or {"is_music_command": false}.
            Transcript: "\(text)"
            """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3

        let body: [String: Any] = [
            "model": "qwen2.5:7b",
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.0,
                "num_predict": 30
            ]
        ]

        guard let requestData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = requestData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else { return nil }

            let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("\"is_music_command\": true") || trimmed.contains("\"is_music_command\":true") {
                return true
            } else if trimmed.contains("\"is_music_command\": false") || trimmed.contains("\"is_music_command\":false") {
                return false
            }
        } catch {
            return nil
        }
        return nil
    }

    // MARK: - Command Handler

    /// Handles a transcript already identified as a Spotify command via LocalMCPBridge.
    func handleCommand(text: String, targetApp: NSRunningApplication? = nil) async -> Bool {
        let activeApp = targetApp ?? NSWorkspace.shared.frontmostApplication
        let normalized = Self.normalize(text)
        owLog("[SpotifyManager] Handling command via LocalMCPBridge: '\(text)'")

        var result = false
        var notificationText = ""
        // Set by branches (like, search & play) that already send their own notification
        // via the verified-working `SpotifyWebAPI`/AppleScript path below, so the shared
        // `sendNotification` call at the bottom doesn't double up on them.
        var alreadyNotified = false

        // 1. Volume commands ("sesi yüzde 50 yap", "sesi 80 yap", "ses %50")
        if normalized.contains("sesi") || normalized.contains("volume") || normalized.contains("ses ") {
            let digits = normalized.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let vol = Int(digits), vol >= 0, vol <= 100 {
                notificationText = await LocalMCPBridge.shared.setVolume(vol)
                result = true
            }
        }

        // 2. Currently playing info ("şu an ne çalıyor", "hangi şarkı çalıyor")
        if !result && (normalized.contains("ne çalıyor") || normalized.contains("hangi şarkı") || normalized.contains("şu an ne")) {
            notificationText = await LocalMCPBridge.shared.getCurrentTrack()
            result = true
        }

        // 3. Like current track ("beğenilenlerime ekle", "beğendiklerime ekle", "şarkıyı beğen").
        // Sends Spotify's native ⌥⇧B "Save to Liked Songs" keyboard shortcut instead of the
        // Web API — see `likeCurrentTrack()` below for why.
        if !result && (normalized.contains("beğenilenlerime") || normalized.contains("beğendiklerime") || normalized.contains("beğen")) {
            result = await likeCurrentTrack(targetApp: activeApp)
            alreadyNotified = true
        }

        // 4. Basic Transport (pause, play, next, prev)
        if !result {
            if normalized.contains("durdur") || normalized.contains("kapat") || normalized.contains("pause") {
                notificationText = await LocalMCPBridge.shared.playPause()
                result = true
            } else if normalized.contains("sonraki") || normalized.contains("next") {
                notificationText = await LocalMCPBridge.shared.nextTrack()
                result = true
            } else if normalized.contains("önceki") || normalized.contains("prev") {
                notificationText = await LocalMCPBridge.shared.previousTrack()
                result = true
            }
        }

        // 5. Fallback: Search & Play ("Tarkan'ın son şarkısını çal", "Sporda dinlemek için...",
        // "Bana arkada..."). Delegates to the already-verified `playSearchQuery` (Web API
        // search + direct AppleScript `play track` by URI) instead of the MCP Python
        // process, which has no access to the user's Spotify token and can only fall back
        // to opening the search screen without actually starting playback.
        if !result {
            let searchQuery = extractSearchQuery(normalized)
            let q = searchQuery.isEmpty ? text : searchQuery
            result = await playSearchQuery(q)
            alreadyNotified = true
        }

        if result {
            if !alreadyNotified {
                sendNotification(title: "🎵 Spotify (MCP)", body: notificationText)
            }
            keepInBackground(targetApp: activeApp)
        }

        return result
    }

    private func keepInBackground(targetApp: NSRunningApplication?) {
        // Only if Spotify actually stole focus (e.g. cold launch) do we restore focus to targetApp.
        // Plain background AppleScript commands to a running Spotify do not steal focus,
        // so avoiding unnecessary activate() calls eliminates the Alt+Tab flicker completely!
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.spotify.client" {
            let hideScript = "tell application \"System Events\" to set visible of process \"Spotify\" to false"
            _ = runAppleScript(hideScript)
            if let targetApp = targetApp, targetApp.bundleIdentifier != "com.spotify.client" {
                targetApp.activate()
            }
        }
    }

    // MARK: - Transport

    /// Runs a transport command and returns whether it actually took effect (see
    /// `handleCommand` for the return contract this feeds into).
    private func runTransport(_ command: TransportCommand) async -> Bool {
        if command == .previous {
            return await runPreviousTrack()
        }

        let script: String
        let successBody: String

        switch command {
        case .pause:
            script = "tell application \"Spotify\" to pause"
            successBody = "Müzik durduruldu"
        case .play:
            script = "tell application \"Spotify\" to play"
            successBody = "Müzik oynatılıyor"
        case .next:
            script = "tell application \"Spotify\" to next track"
            successBody = "Sonraki şarkıya geçildi"
        case .previous:
            fatalError("previous track is handled by runPreviousTrack(), not this switch")
        case .playLiked:
            fatalError("playLiked is handled by playRandomLikedTrack(), not this switch")
        }

        switch runAppleScript(script) {
        case .success:
            // AppleScript returning success only means the command was accepted, not
            // that audio is actually flowing — e.g. "play" with nothing queued succeeds
            // but plays nothing. Verify actual playback state before claiming success.
            if command == .play {
                if await confirmPlaying() {
                    sendNotification(title: "🎵 Spotify", body: successBody)
                } else {
                    // The AppleScript itself succeeded (so this isn't a permission issue) —
                    // a real command was sent to Spotify, we just couldn't confirm playback
                    // started. Still counts as "something happened": don't also paste the
                    // command text as dictation on top of it.
                    sendNotification(
                        title: "🎵 Spotify",
                        body: "Komut kabul edildi ama Spotify çalmıyor. Çalma listesi boş olabilir."
                    )
                }
                return true
            } else {
                sendNotification(title: "🎵 Spotify", body: successBody)
                return true
            }
        case .failure(let error):
            return handleScriptError(error)
        }
    }

    /// "previous track" is sent twice with a short gap: a single call usually just
    /// rewinds the current track to its start instead of moving to the prior track.
    private func runPreviousTrack() async -> Bool {
        let script = "tell application \"Spotify\" to previous track"

        if case .failure(let error) = runAppleScript(script) {
            return handleScriptError(error)
        }

        try? await Task.sleep(nanoseconds: 250_000_000)

        switch runAppleScript(script) {
        case .success:
            sendNotification(title: "🎵 Spotify", body: "Önceki şarkıya geçildi")
            return true
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

    /// Searches for `query` via the Spotify Web API and plays the top result directly by
    /// URI through AppleScript — no UI automation, no window focus tricks. Falls back to
    /// opening the old `spotify:search:` URL (just opening the search screen, not trying
    /// to auto-play) when credentials are missing or the API call fails, and is honest in
    /// the notification about what actually happened either way.
    private func playSearchQuery(_ query: String) async -> Bool {
        sendNotification(title: "🎵 Spotify", body: "\"\(query)\" aranıyor...")

        do {
            let track = try await SpotifyWebAPI.shared.searchTopTrack(query: query)
            return await playTrack(uri: track.uri, name: track.name, artist: track.artist)
        } catch let error as SpotifyWebAPI.SpotifyAPIError {
            owLog("[Spotify] Web API search failed: \(error)")
            return await fallBackToSearchScreen(query: query, reason: error.userMessage)
        } catch {
            owLog("[Spotify] Web API search failed: \(error)")
            return await fallBackToSearchScreen(query: query, reason: "Beklenmeyen hata")
        }
    }

    /// Plays a specific track URI via Spotify's AppleScript `play track` command and
    /// confirms playback actually started before reporting success.
    private func playTrack(uri: String, name: String, artist: String) async -> Bool {
        let script = "tell application \"Spotify\" to play track \"\(uri)\""
        switch runAppleScript(script) {
        case .success:
            let label = artist.isEmpty ? name : "\(artist) — \(name)"
            if await confirmPlaying() {
                sendNotification(title: "🎵 Spotify", body: "♪ \(label)")
            } else {
                sendNotification(
                    title: "🎵 Spotify",
                    body: "Komut kabul edildi ama Spotify çalmıyor: ♪ \(label)"
                )
            }
            return true
        case .failure(let error):
            return handleScriptError(error)
        }
    }

    /// Honest fallback when the Web API path can't be used: opens Spotify's search screen
    /// (not attempting to auto-play, since there's no reliable non-UI-automation way to do
    /// that) and tells the user why the automatic version didn't happen.
    private func fallBackToSearchScreen(query: String, reason: String) async -> Bool {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "spotify:search:\(encoded)") else {
            sendNotification(title: "🎵 Spotify", body: "\"\(query)\" için arama başlatılamadı: \(reason)")
            return false
        }

        NSWorkspace.shared.open(url)
        sendNotification(
            title: "🎵 Spotify",
            body: "Otomatik çalma başarısız (\(reason)). \"\(query)\" için arama ekranı açıldı."
        )
        return true
    }

    // MARK: - Like Current Track ("şarkıyı beğen")

    /// "beğenilenlerime ekle" / "şarkıyı beğen".
    ///
    /// This used to PUT the track ID to `SpotifyWebAPI.addTrackToLikedSongs` using the
    /// user's Keychain-backed OAuth token. That path is now dead: on this user's account,
    /// Spotify's `/authorize` endpoint deterministically returns `error=server_error`
    /// before a `code` is ever issued — reproduced across browsers, a re-verified Web API
    /// dashboard registration, and a brand-new Spotify app from scratch. There is no
    /// Keychain token to refresh into existence, so `SpotifyWebAPI.addTrackToLikedSongs`
    /// cannot work here regardless of what this method does. See the comment on
    /// `SpotifyWebAPI.addTrackToLikedSongs` — it's kept, not deleted, for if OAuth ever
    /// gets unblocked independently of this method.
    ///
    /// Instead this sends Spotify's native ⌥⇧B "Save to Liked Songs" keyboard shortcut via
    /// System Events. Empirically verified by the user on the current Spotify macOS client
    /// (this is undocumented — Spotify's own AppleScript dictionary and menu bar expose no
    /// like/love/save command at all, confirmed by dumping both; the shortcut is the only
    /// working local hook).
    ///
    /// IMPORTANT — this is a TOGGLE, not an idempotent "add": pressing it on an
    /// already-liked track REMOVES it from Liked Songs (also user-verified). There is no
    /// local way to read whether the current track is already liked — that too would
    /// require the same dead Web API token — so this method cannot know in advance which
    /// direction the toggle will go. The notification text below is deliberately
    /// non-committal ("beğeni durumu değiştirildi") instead of claiming "eklendi"
    /// (added), because half the time that claim would be false. Do not "fix" that wording
    /// to sound more confident without first solving the read side of this problem.
    private func likeCurrentTrack(targetApp: NSRunningApplication?) async -> Bool {
        // Check Spotify is actually running before doing anything — `activate` below would
        // otherwise cold-launch Spotify just to toggle a track that was never playing,
        // which is a much more confusing failure than an honest "not running" message.
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) else {
            sendNotification(title: "🎵 Spotify", body: "Spotify çalışmıyor görünüyor.")
            return true
        }

        guard case .success(let idOutput) = runAppleScript("tell application \"Spotify\" to return id of current track"),
              let uri = idOutput, !uri.isEmpty else {
            sendNotification(title: "🎵 Spotify", body: "Şu an çalan bir şarkı bulunamadı.")
            return true
        }
        owLog("[Spotify] Toggling Liked Songs status for \(uri) via ⌥⇧B")

        // The keystroke goes to whichever app is frontmost, so Spotify has to actually be
        // in front for this to land. `activate` alone doesn't guarantee that's already true
        // by the time the next AppleScript line runs, so poll briefly for it rather than
        // trusting a blind delay.
        guard case .success = runAppleScript("tell application \"Spotify\" to activate") else {
            sendNotification(title: "🎵 Spotify", body: "Spotify öne getirilemedi.")
            return true
        }

        var becameFrontmost = false
        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.spotify.client" {
                becameFrontmost = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !becameFrontmost {
            // Didn't get a positive confirmation within ~1s, but `activate` itself didn't
            // error — fall through with the fixed 0.3s delay the user's manual test used
            // successfully, rather than giving up on a command that likely still works.
            owLog("[Spotify] Could not confirm Spotify became frontmost, falling back to fixed delay")
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        switch runAppleScript("tell application \"System Events\" to keystroke \"b\" using {option down, shift down}") {
        case .success:
            sendNotification(title: "🎵 Spotify", body: "Beğeni durumu değiştirildi ❤️ (şarkı zaten beğeniliyse kaldırılmış olabilir)")
        case .failure(let error):
            owLog("[Spotify] Like toggle keystroke failed: \(error)")
            _ = handleScriptError(error)
        }

        keepInBackground(targetApp: targetApp)
        return true
    }

    // MARK: - Liked Songs ("beğenilenleri çal")

    /// "beğenilenleri çal" and its aliases: fetches the user's Liked Songs via the Web
    /// API and plays a random one. Requires the user to have connected their account
    /// (Settings > Spotify) — a client-credentials-only setup cannot read `/v1/me/tracks`
    /// at all, so this is reported honestly rather than silently falling back to search.
    private func playRandomLikedTrack() async -> Bool {
        do {
            let track = try await SpotifyWebAPI.shared.fetchRandomLikedTrack()
            return await playLikedTrack(uri: track.uri, name: track.name, artist: track.artist)
        } catch let error as SpotifyWebAPI.SpotifyAPIError {
            owLog("[Spotify] Liked Songs fetch failed: \(error)")
            sendNotification(title: "🎵 Spotify", body: error.userMessage)
            // A recognized command that was declined for a known, already-explained
            // reason (not connected, rate limited, etc.) — not a miss. Returning `true`
            // here (matching `fallBackToSearchScreen`'s convention) keeps the transcript
            // from also being pasted as dictation on top of the notification we just sent.
            return true
        } catch {
            owLog("[Spotify] Liked Songs fetch failed: \(error)")
            sendNotification(title: "🎵 Spotify", body: "Beğenilenler alınamadı: beklenmeyen hata")
            return true
        }
    }

    /// Plays a Liked Songs track within the "spotify:collection:tracks" context so
    /// Spotify's next/previous/shuffle keep moving through the rest of the library —
    /// unverified against a live account whether Spotify's AppleScript dictionary
    /// actually accepts this context string (its docs don't list valid context URIs).
    /// Falls back to the exact same track with a plain, context-less `play track` in two
    /// distinct failure modes, since an unsupported context could plausibly show up as
    /// either one: the AppleScript command itself erroring, OR "succeeding" while Spotify
    /// silently plays nothing. Either way the fallback notification is explicit that only
    /// that one track — not the whole library — ended up playing.
    private func playLikedTrack(uri: String, name: String, artist: String) async -> Bool {
        // Best-effort, applied before the context play below: if Spotify accepts the
        // "spotify:collection:tracks" context, this makes next/previous continue shuffling
        // through Liked Songs rather than playing in saved order. Not fatal if rejected —
        // the single chosen track still plays either way, this only affects what happens
        // to playback *after* it.
        if case .failure(let error) = runAppleScript("tell application \"Spotify\" to set shuffling to true") {
            owLog("[Spotify] Could not enable shuffle (non-fatal): \(error)")
        }

        let label = artist.isEmpty ? name : "\(artist) — \(name)"

        let contextScript = "tell application \"Spotify\" to play track \"\(uri)\" in context \"spotify:collection:tracks\""

        switch runAppleScript(contextScript) {
        case .success:
            if await confirmPlaying() {
                sendNotification(title: "🎵 Spotify", body: "♪ Beğenilenlerden: \(label)")
                return true
            }
            owLog("[Spotify] Liked Songs context play accepted but not confirmed playing, retrying without context")
        case .failure(let contextError):
            owLog("[Spotify] Liked Songs context play failed, retrying without context: \(contextError)")
        }

        let plainScript = "tell application \"Spotify\" to play track \"\(uri)\""

        switch runAppleScript(plainScript) {
        case .success:
            if await confirmPlaying() {
                sendNotification(
                    title: "🎵 Spotify",
                    body: "♪ \(label) (yalnızca bu şarkı çalınıyor, beğenilenler bağlamı desteklenmedi)"
                )
            } else {
                sendNotification(
                    title: "🎵 Spotify",
                    body: "Komut kabul edildi ama Spotify çalmıyor: ♪ \(label)"
                )
            }
            return true
        case .failure(let error):
            return handleScriptError(error)
        }
    }

    /// Polls playback state instead of checking once: a cold-launched Spotify (or one
    /// asked to play a freshly-resolved track URI) can still be starting up a moment
    /// after the AppleScript command returns, and a single too-early check would report
    /// a false "not playing" for something that succeeds a second later.
    private func confirmPlaying() async -> Bool {
        let delaysNanoseconds: [UInt64] = [400_000_000, 600_000_000, 600_000_000]
        for delay in delaysNanoseconds {
            try? await Task.sleep(nanoseconds: delay)
            // `player state` is an AppleScript enum, not a string — NSAppleScript's
            // `.stringValue` on an enumerated descriptor is unreliable (often nil).
            // Coercing explicitly with `as text` gets a real string back for comparison.
            if case .success(let state) = runAppleScript("tell application \"Spotify\" to return player state as text"),
               state == "playing" {
                return true
            }
        }
        return false
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
