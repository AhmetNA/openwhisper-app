import Foundation
import AppKit
import UserNotifications

final class SpotifyManager: @unchecked Sendable {

    static let shared = SpotifyManager()

    private init() {}

    // MARK: - Shared Command Table
    //
    // NOTE: only the gate (`isSpotifyCommand`, via `hasCommandPrefix`) reads this table.
    // `handleCommand` was rewritten for MCP and now matches on its own `normalized.contains(...)`
    // checks in each numbered step below — it does NOT consult `transportPrefixes`. Adding a
    // row here only affects whether `isSpotifyCommand` accepts the utterance as a candidate;
    // it does nothing to route it once inside `handleCommand`. Order still matters here for the
    // gate's own leading-prefix matching: more specific / longer phrases must come before shorter
    // ones they contain (e.g. "müziği durdur" before bare "durdur").

    private enum TransportCommand {
        case pause
        case play
        case next
        case previous
        /// "beğenilenleri çal" and friends — play a random track from the user's Liked
        /// Songs. Listed first in `transportPrefixes` purely so the gate (`isSpotifyCommand`)
        /// accepts these phrases unambiguously. `handleCommand` does NOT read this table (see
        /// the note above `transportPrefixes`) — its own liked-songs routing lives in step 3a.
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
    // "şarkı ..." inflections are stripped as whole words too — the trade-off is that a
    // track literally titled just one of these words (e.g. "Şarkı Söylemek") would have
    // that word stripped from its own search query. Accepted trade-off per product call.
    private static let searchJunkWords: Set<String> = [
        "spotifyda", "spotifydan", "spotifya", "spotify",
        "bana", "lütfen", "şarkısını", "şarkısı", "parçasını", "müziğini",
        "çal", "aç", "oynat", "başlat", "dinlet", "play", "adlı",
        "şarkıyı", "şarkıya", "şarkısına", "şarkısıyla", "şarkı", "şarkılar",
        "şarkıları", "şarkılarını", "parçayı", "parça", "müzik", "müziği"
    ]

    /// Content-based (not prefix-based) matching for "play my Liked Songs" used by
    /// `handleCommand` step 3a. Prefix matching via `hasCommandPrefix`/`transportPrefixes`
    /// doesn't work here: `hasCommandPrefix` requires a space right after the prefix, so a
    /// prefix like "beğenilen şarkılar" never matches "beğenilen şarkıları aç" (next char is
    /// "ı", not a space). A noun (what) + verb (do) combination checked with plain
    /// `.contains` against `Self.normalize`d text sidesteps that entirely.
    private static let likedSongsNouns: Set<String> = [
        "beğenilen", "beğenilenler", "beğendiklerim", "beğenilerim", "liked songs"
    ]
    private static let likedSongsVerbs: Set<String> = ["çal", "aç", "oynat", "liste"]

    /// True for "beğenilen şarkıları aç", "beğenilerimin listesini çal", "liked songs çal",
    /// etc. Excludes anything containing "ekle" ("beğenilerime ekle" = add current track to
    /// Liked Songs, not play Liked Songs) so this can't shadow the Like branch (step 3) —
    /// e.g. "çalan şarkıyı beğenilerime ekle" contains both a liked-noun ("beğenilerim") and,
    /// incidentally, the "çal" verb substring (from "çalan"), but is clearly an add-to-liked
    /// command, not a play-liked-songs command.
    private static func isLikedSongsPlaybackCommand(_ normalized: String) -> Bool {
        guard !normalized.contains("ekle") else { return false }
        let hasNoun = likedSongsNouns.contains { normalized.contains($0) }
        let hasVerb = likedSongsVerbs.contains { normalized.contains($0) }
        return hasNoun && hasVerb
    }

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

    /// The model the user picked in Settings (AppState.ollamaModel, UserDefaults key
    /// "ollamaModel", default "qwen3:8b"). SpotifyManager is a standalone singleton with no
    /// AppState reference, so it reads the same UserDefaults key directly rather than
    /// hardcoding a model — this used to hardcode "qwen2.5:7b", a model that isn't installed
    /// (installed models are qwen3:8b, llama3.2:3b), so every classification request failed
    /// and silently fell through to the heuristic fallback. See ReminderManager's identical
    /// `selectedOllamaModel` for the same fix applied there.
    private static var selectedOllamaModel: String {
        UserDefaults.standard.string(forKey: "ollamaModel") ?? "qwen3:8b"
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
            "model": selectedOllamaModel,
            "prompt": prompt,
            "stream": false,
            // qwen3 (and other "thinking" models) emit a <think>...</think> block by default,
            // which eats the num_predict budget and leaves "response" empty before any real
            // output is produced. "think": false skips that. See ReminderManager's identical
            // fix for the same failure mode.
            "think": false,
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

        // 3a. Play Liked Songs ("beğenilenleri çal", "beğenilen şarkıları aç", "beğenilerimin
        // listesini çal", "liked songs çal"). Must be checked BEFORE the Like branch below —
        // both branches key off "beğen..." substrings, and without this ordering "beğenilen
        // şarkıları aç" would fall into the Like (single-track toggle) branch instead of
        // actually playing the Liked Songs list. See `isLikedSongsPlaybackCommand` for why
        // this is content-based rather than prefix-based matching.
        if !result && Self.isLikedSongsPlaybackCommand(normalized) {
            result = await playLikedSongs()
            alreadyNotified = true
        }

        // 3b. Like current track ("beğenilerime ekle", "beğenilenlerime ekle",
        // "beğendiklerime ekle", "şarkıyı beğen"). Sends Spotify's native ⌥⇧B "Save to Liked
        // Songs" keyboard shortcut instead of the Web API — see `likeCurrentTrack()` below for
        // why. Keyed off "ekle" (the verb in every real "add to Liked Songs" phrasing seen in
        // logs) OR the literal "şarkıyı beğen" pattern, rather than a bare `contains("beğen")`,
        // so this can't swallow the "play Liked Songs" phrasings handled by 3a above.
        if !result && (normalized.contains("ekle") || normalized.contains("şarkıyı beğen")) {
            result = await likeCurrentTrack(targetApp: activeApp)
            alreadyNotified = true
        }

        // 4. Basic Transport (pause, play, next, prev)
        if !result {
            if normalized.contains("durdur") || normalized.contains("kapat") || normalized.contains("pause") {
                // Native AppleScript `pause` via `runTransport(.pause)`, NOT
                // `LocalMCPBridge.shared.playPause()` — that's a TOGGLE, so it would
                // start playback instead of pausing whenever music is already stopped,
                // making "şarkıyı durdur" and "şarkıyı çal" the same command depending
                // on current state. Mirrors the resume branch below for the same reason.
                result = await runTransport(.pause)
                alreadyNotified = true
            } else if normalized.contains("sonraki") || normalized.contains("next") {
                notificationText = await LocalMCPBridge.shared.nextTrack()
                result = true
            } else if normalized.contains("önceki") || normalized.contains("prev") {
                notificationText = await LocalMCPBridge.shared.previousTrack()
                result = true
            } else if (normalized.contains("çal") || normalized.contains("aç") ||
                       normalized.contains("oynat") || normalized.contains("başlat") ||
                       normalized.contains("play")) && extractSearchQuery(normalized).isEmpty {
                // Bare resume ("şarkıyı çal", "müziği aç") — no search terms remain once
                // junk words (incl. "şarkı" inflections, see `searchJunkWords`) are
                // stripped. `LocalMCPBridge.shared.playPause()` is a TOGGLE, not a
                // dedicated resume, and would make this indistinguishable from the pause
                // branch above — so this uses the native AppleScript `play` command via
                // `runTransport(.play)` instead (which also verifies playback actually
                // started via `confirmPlaying()` and sends its own notification).
                // Guarded on the residue being empty so real search+play requests like
                // "tarkan çal" or "... hareketli bir müzik aç" (non-empty residue) are
                // NOT swallowed here — they fall through to step 5 as before.
                result = await runTransport(.play)
                alreadyNotified = true
            }
        }

        // 5. Fallback: Search & Play ("Tarkan'ın son şarkısını çal", "Sporda dinlemek için...",
        // "Bana arkada..."). Delegates to the already-verified `playSearchQuery` (Web API
        // search + direct AppleScript `play track` by URI) instead of the MCP Python
        // process, which has no access to the user's Spotify token and can only fall back
        // to opening the search screen without actually starting playback.
        if !result {
            let searchQuery = extractSearchQuery(normalized)
            if searchQuery.isEmpty {
                // No search terms AND step 4's guarded resume branch above didn't match
                // (e.g. no çal/aç/oynat/başlat/play verb was even present) — resume
                // playback rather than literally searching Spotify for raw junk text.
                result = await runTransport(.play)
            } else {
                result = await playSearchQuery(searchQuery)
            }
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
            fatalError("playLiked is handled by playLikedSongs(), not this switch")
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

    // Internal (not private) so the standalone Tools/main.swift harness can call it
    // directly — it's a pure function of `searchJunkWords`, safe to exercise in isolation.
    func extractSearchQuery(_ residue: String) -> String {
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
    /// user's Keychain-backed OAuth token, and was switched to the local ⌥⇧B shortcut below
    /// instead — but NOT because OAuth was broken. OAuth works fine (token exchange returns
    /// HTTP 200, refresh token persists in the Keychain); the original switch was made under
    /// a since-corrected belief that `/authorize` deterministically failed. See the comment
    /// on `SpotifyWebAPI.addTrackToLikedSongs` for the current, accurate status — it's kept
    /// unwired, not deleted, in case re-plumbing this method to call it is a deliberate
    /// choice made later (not made by this comment fix).
    ///
    /// This method still sends Spotify's native ⌥⇧B "Save to Liked Songs" keyboard shortcut
    /// via System Events. Empirically verified by the user on the current Spotify macOS
    /// client (this is undocumented — Spotify's own AppleScript dictionary and menu bar
    /// expose no like/love/save command at all, confirmed by dumping both; the shortcut is
    /// the only working local hook).
    ///
    /// IMPORTANT — this is a TOGGLE, not an idempotent "add": pressing it on an
    /// already-liked track REMOVES it from Liked Songs (also user-verified). There is no
    /// local way to read whether the current track is already liked from THIS method — it
    /// has no track ID to check with, only the frontmost-Spotify keystroke path — so it
    /// cannot know in advance which direction the toggle will go. The notification text
    /// below is deliberately non-committal ("beğeni durumu değiştirildi") instead of
    /// claiming "eklendi" (added), because half the time that claim would be false. Do not
    /// "fix" that wording to sound more confident without first solving the read side of
    /// this problem (which, now that OAuth is confirmed working, would mean wiring up
    /// `/v1/me/tracks/contains` here — a separate change, not done by this comment fix).
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

    /// "beğenilenleri çal" and its aliases: fetches a window of the user's Liked Songs,
    /// shuffles it client-side, and starts REAL queue playback of the whole list via the
    /// Web API player endpoint (`SpotifyWebAPI.startPlayback`) — next/previous/shuffle all
    /// keep working through the rest of the list afterward. Requires the user to have
    /// connected their account (Settings > Spotify) with the player scopes
    /// (`user-modify-playback-state`, `user-read-playback-state`) — a client-credentials-only
    /// setup, or a token predating those scopes, cannot do this at all, so every failure
    /// mode here is reported with a specific, actionable notification rather than a generic
    /// one (see `SpotifyWebAPI.SpotifyAPIError`).
    ///
    /// PRIOR BEHAVIOR (dead, do not resurrect): this used to call AppleScript's
    /// `play track "<uri>" in context "spotify:collection:tracks"`. Spotify's AppleScript
    /// dictionary does not support arbitrary playback contexts, so that call always played
    /// only the single named track — empirically confirmed, not a hypothesis. There is no
    /// AppleScript-only fix for "play the whole list"; the Web API player endpoint is the
    /// only way.
    private func playLikedSongs() async -> Bool {
        let tracks: [SpotifyWebAPI.TrackResult]
        do {
            tracks = try await SpotifyWebAPI.shared.fetchLikedTracksWindow(limit: 50)
        } catch let error as SpotifyWebAPI.SpotifyAPIError {
            owLog("[Spotify] Liked Songs fetch failed: \(error)")
            sendNotification(title: "🎵 Spotify", body: error.userMessage)
            return true
        } catch {
            owLog("[Spotify] Liked Songs fetch failed: \(error)")
            sendNotification(title: "🎵 Spotify", body: "Beğenilenler alınamadı: beklenmeyen hata")
            return true
        }

        // Shuffle client-side: `uris` in the player call plays back in array order, so this
        // is what makes repeated "beğenilenleri çal" commands not always start with the
        // same most-recently-liked track. No extra API/scope needed for this part.
        let shuffled = tracks.shuffled()
        let uris = shuffled.map(\.uri)

        let deviceID = await resolveActivePlaybackDevice()

        do {
            try await SpotifyWebAPI.shared.startPlayback(uris: uris, deviceID: deviceID)
            sendNotification(title: "🎵 Spotify", body: "♪ Beğenilenler çalınıyor (\(uris.count) şarkı)")
            return true
        } catch let error as SpotifyWebAPI.SpotifyAPIError {
            owLog("[Spotify] startPlayback failed: \(error)")
            if case .premiumRequired = error {
                // Honest downgrade to today's known-working behavior: a single track via
                // AppleScript. Not the "whole list" experience, but Free accounts cannot
                // get that from this API at all (player endpoints are Premium-only).
                return await playSingleLikedTrackFallback(shuffled.first, reason: error.userMessage)
            }
            sendNotification(title: "🎵 Spotify", body: error.userMessage)
            return true
        } catch {
            owLog("[Spotify] startPlayback failed: \(error)")
            sendNotification(title: "🎵 Spotify", body: "Beğenilenler çalınamadı: beklenmeyen hata")
            return true
        }
    }

    /// Finds a device to target for `startPlayback`. Prefers whichever device Spotify
    /// already reports as `is_active`; if none is active (most commonly: Spotify is open
    /// but hasn't played anything yet, or was just launched), wakes Spotify locally via
    /// AppleScript and checks the device list one more time before giving up. Returns nil
    /// if still nothing is found — `startPlayback` is called without a `device_id` in that
    /// case and will surface `SpotifyAPIError.noActiveDevice` (404) itself.
    private func resolveActivePlaybackDevice() async -> String? {
        if let deviceID = await firstUsableDevice() {
            return deviceID
        }

        owLog("[Spotify] No active device found, waking Spotify locally and retrying")
        if case .failure(let error) = runAppleScript("tell application \"Spotify\" to activate") {
            owLog("[Spotify] Could not activate Spotify to wake a device (non-fatal): \(error)")
        }
        // `activate` only foregrounds the client — it doesn't reliably register it as an
        // active Spotify Connect device. A `play` nudge is what actually does that. This
        // briefly plays whatever was last queued (if anything) for a moment before
        // `startPlayback` immediately replaces it with the shuffled Liked Songs `uris` —
        // an acceptable ~1.5s blip in exchange for not 404ing on a cold-launched client.
        if case .failure(let error) = runAppleScript("tell application \"Spotify\" to play") {
            owLog("[Spotify] Could not nudge Spotify to register as active device (non-fatal): \(error)")
        }
        // Give Spotify Connect a moment to register the freshly-launched/foregrounded
        // client as a device before asking the API about it again.
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        return await firstUsableDevice()
    }

    /// One `/v1/me/player/devices` lookup: prefers the `is_active` device, then the first
    /// `"Computer"`-type device (so a phone/speaker listed alongside an idle desktop client
    /// doesn't win playback while the user is sitting at their Mac), then whatever's first,
    /// or nil if the call fails or the list is empty. Errors here are swallowed (logged, not
    /// thrown) — this is a best-effort device pick; `startPlayback` reports the real,
    /// user-facing error itself (scope 403 / device 404 / etc.) whether or not this
    /// succeeded.
    private func firstUsableDevice() async -> String? {
        do {
            let devices = try await SpotifyWebAPI.shared.fetchAvailableDevices()
            let chosen = devices.first(where: { $0.isActive })
                ?? devices.first(where: { $0.type == "Computer" })
                ?? devices.first
            if let chosen {
                owLog("[Spotify] Chosen playback device: \(chosen.name) (type: \(chosen.type), active: \(chosen.isActive))")
            }
            return chosen?.id
        } catch {
            owLog("[Spotify] fetchAvailableDevices failed (non-fatal, startPlayback will report the real error): \(error)")
            return nil
        }
    }

    /// Premium-required fallback: plays exactly one track (the first of the shuffled
    /// window) via AppleScript's plain `play track`, matching the app's pre-existing
    /// single-track behavior for users without Premium (Web API player endpoints all
    /// require Premium; there is no way to queue a whole list without them).
    private func playSingleLikedTrackFallback(_ track: SpotifyWebAPI.TrackResult?, reason: String) async -> Bool {
        guard let track else {
            sendNotification(title: "🎵 Spotify", body: reason)
            return true
        }
        let label = track.artist.isEmpty ? track.name : "\(track.artist) — \(track.name)"
        let script = "tell application \"Spotify\" to play track \"\(track.uri)\""

        switch runAppleScript(script) {
        case .success:
            if await confirmPlaying() {
                sendNotification(title: "🎵 Spotify", body: "\(reason) — tek şarkı çalınıyor: ♪ \(label)")
            } else {
                sendNotification(title: "🎵 Spotify", body: "\(reason) — komut kabul edildi ama Spotify çalmıyor: ♪ \(label)")
            }
            return true
        case .failure(let error):
            // KORU: preserve the known-cause-notification-already-sent convention (see
            // `handleScriptError`'s doc comment and `likeCurrentTrack`'s identical pattern)
            // — `handleScriptError` always returns `false`, which here would let
            // `handleCommand` fall through to step 5 and paste/search the *original*
            // "beğenilenler listesini çal" transcript as an unrelated search query on top
            // of the failure notification this already sent.
            _ = handleScriptError(error)
            return true
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
        let text = "\(title) \(body)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let isError = [
            "error", "hata", "başarısız", "gerekli", "çalışmıyor", "çalınamadı",
            "çalmıyor", "bulunamadı", "öne getirilemedi", "zaman aşımı", "not connected"
        ].contains { text.contains($0) }
        OpenWhisperNotification.post(title: title, body: body, isError: isError, identifierPrefix: "spotify")
    }
}
