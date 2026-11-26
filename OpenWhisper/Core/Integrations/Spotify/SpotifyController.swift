import Foundation
import os
import AppKit

struct SpotifyActionResult: Sendable, Equatable {
    let succeeded: Bool
    let message: String

    static func success(_ message: String) -> SpotifyActionResult {
        SpotifyActionResult(succeeded: true, message: message)
    }

    static func failure(_ message: String) -> SpotifyActionResult {
        SpotifyActionResult(succeeded: false, message: message)
    }
}

/// Executes Spotify actions for intents that `SpotifyManager.explicitIntent(in:)` has already
/// validated. Callers must not reach these methods with anything less: they have real side
/// effects (playback, volume, Liked Songs) and perform no intent checks of their own.
///
/// Every action tries the Spotify Web API first (when the user connected their account in
/// Settings > Spotify), then falls back to controlling the local Spotify app over
/// AppleScript. The AppleScript path needs an Apple Events temporary-exception entitlement
/// the Mac App Store will not grant for Spotify, so `APP_STORE` builds compile it out and
/// rely on the Web API alone (which requires Spotify Premium for player commands).
///
/// Replaces the former `spotify_smart_mcp.py` stdio server: that process only wrapped
/// `osascript` and `urllib`, and a sandboxed app cannot launch `/usr/bin/python3` anyway.
final class SpotifyController: @unchecked Sendable {

    static let shared = SpotifyController()

    #if APP_STORE
    static let appleScriptFallbackEnabled = false
    #else
    static let appleScriptFallbackEnabled = true
    #endif

    static let spotifyBundleID = "com.spotify.client"

    private init() {}

    /// Without a stored refresh token every player call would just throw `.notConnected`,
    /// so the Web API is skipped entirely instead of adding a guaranteed-failed round trip.
    private var webAPIConnected: Bool {
        SpotifyCredentialsStore.hasRefreshToken()
    }

    private var isSpotifyRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.spotifyBundleID }
    }

    // MARK: - Transport

    func play() async -> SpotifyActionResult {
        await perform(
            "Oynatma",
            web: {
                try await self.withDeviceFallback { try await SpotifyWebAPI.shared.resumePlayback(deviceID: $0) }
                return L("Müzik oynatılıyor", "Music playing")
            },
            appleScript: { self.runSpotifyCommand("play").map { _ in L("Müzik oynatılıyor", "Music playing") } }
        )
    }

    func pause() async -> SpotifyActionResult {
        await perform(
            "Durdurma",
            web: {
                try await SpotifyWebAPI.shared.pausePlayback()
                return L("Müzik durduruldu", "Music paused")
            },
            appleScript: {
                self.runAppleScript(Self.pauseScript).flatMap { output in
                    guard let message = Self.pauseMessage(output) else {
                        return .failure(.other(errorNumber: -1, message: "Pause was not confirmed"))
                    }
                    return .success(message)
                }
            }
        )
    }

    static func pauseMessage(_ state: String?) -> String? {
        switch state {
        case "alreadyPaused": return L("Müzik zaten duraklatılmış", "The music is already paused")
        case "paused": return L("Müzik durduruldu", "Music paused")
        default: return nil
        }
    }

    static let pauseScript = """
        tell application "Spotify"
            if player state is not playing then return "alreadyPaused"
            pause
            repeat 10 times
                if player state is not playing then return "paused"
                delay 0.05
            end repeat
            return "failed"
        end tell
        """

    func nextTrack() async -> SpotifyActionResult {
        await perform(
            "Sonraki şarkı",
            web: {
                try await SpotifyWebAPI.shared.skipToNext()
                return L("Sonraki şarkıya geçildi", "Next song")
            },
            appleScript: { self.runSpotifyCommand("next track").map { _ in L("Sonraki şarkıya geçildi", "Next song") } }
        )
    }

    func previousTrack() async -> SpotifyActionResult {
        await perform(
            "Önceki şarkı",
            web: {
                try await SpotifyWebAPI.shared.skipToPrevious()
                return L("Önceki şarkıya geçildi", "Previous song")
            },
            appleScript: { self.runSpotifyCommand("previous track").map { _ in L("Önceki şarkıya geçildi", "Previous song") } }
        )
    }

    func setVolume(_ volume: Int) async -> SpotifyActionResult {
        guard (0...100).contains(volume) else {
            return .failure(L("Geçersiz ses seviyesi: 0-100 arası olmalı", "Invalid volume: it must be 0-100"))
        }
        return await perform(
            "Ses ayarı",
            web: {
                try await SpotifyWebAPI.shared.setVolume(volume)
                return L("Spotify sesi %\(volume) yapıldı", "Spotify volume \(volume)%")
            },
            appleScript: {
                self.runSpotifyCommand("set sound volume to \(volume)").map { _ in L("Spotify sesi %\(volume) yapıldı", "Spotify volume \(volume)%") }
            }
        )
    }

    /// "Karışık çal" in Settings › Spotify; on unless turned off.
    static let likedSongsShuffleKey = "spotifyLikedSongsShuffle"
    static var likedSongsShuffle: Bool {
        UserDefaults.standard.object(forKey: likedSongsShuffleKey) as? Bool ?? true
    }

    /// "Şarkı aç", "beğendiğim şarkıları çal" and developer mode: the Liked Songs context,
    /// shuffled from a random liked track unless "Karışık çal" is off (then newest first),
    /// with Spotify launched in the background if it was closed. A freshly launched client
    /// takes a few seconds to appear as a Connect device, so the device list is polled.
    /// Spotify answers 204 even when nothing starts, so success means the player state
    /// shows it playing. Otherwise the Liked Songs page is at least opened in the background.
    func playLikedSongs() async -> SpotifyActionResult {
        let wasRunning = isSpotifyRunning
        let started = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        if !wasRunning {
            await launchInBackground()
            owLog("[SpotifyController] Spotify was closed; launched in \(ms()) ms")
        }
        if webAPIConnected {
            do {
                let shuffle = Self.likedSongsShuffle
                async let userID = SpotifyWebAPI.shared.fetchUserID()
                async let availableDevice = waitForDevice(timeout: wasRunning ? 2 : 8)
                async let currentPlayer = try? SpotifyWebAPI.shared.fetchCurrentlyPlaying()
                async let randomStart = likedSongsStart(shuffle: shuffle)
                let context = SpotifyWebAPI.likedSongsContextURI(userID: try await userID)
                let deviceID = try await availableDevice
                owLog("[SpotifyController] Device ready at \(ms()) ms")
                let before = await currentPlayer
                // Step times, to see which call holds "başlat" up (1.2–1.5 s, 27 Nov 2026).
                var steps = "player \(ms())"
                // Setting it again could drop the user's Smart Shuffle.
                if before?.shuffle != shuffle {
                    do {
                        try await SpotifyWebAPI.shared.setShuffle(shuffle, deviceID: deviceID)
                    } catch {
                        owLog("[SpotifyController] Liked songs shuffle \(shuffle) not set: \(error)")
                    }
                    steps += ", shuffle set \(ms())"
                }
                // A shuffled context still opens on its first track; start somewhere random.
                let start = await randomStart
                steps += ", start track \(ms())"
                try await SpotifyWebAPI.shared.startPlayback(contextURI: context, offsetURI: start, deviceID: deviceID)
                steps += ", play request \(ms())"
                if let polls = await waitForLikedSongs(context: context, before: before, timeout: wasRunning ? 4 : 10) {
                    owLog("[SpotifyController] Playing liked songs\(shuffle ? ", shuffled" : "") at \(ms()) ms (\(steps), confirmed after \(polls) checks)")
                    return .success(L("beğenilen şarkılar çalıyor", "playing your liked songs"))
                }
                owLog("[SpotifyController] Liked songs accepted but Spotify is not playing them")
            } catch {
                owLog("[SpotifyController] Liked songs playback failed: \(error)")
            }
        }
        openLikedSongsPage()
        return .failure(L("beğenilen şarkılar açıldı ama çalınamadı", "liked songs opened but couldn't play"))
    }

    private func likedSongsStart(shuffle: Bool) async -> String? {
        guard shuffle else { return nil }
        return (try? await SpotifyWebAPI.shared.fetchLikedTrackURIs(limit: 50))?.randomElement()
    }

    /// Polls immediately, then at 500 ms intervals; never reports success from an HTTP ack alone.
    /// Returns how many checks it took, or nil when the deadline passed.
    private func waitForLikedSongs(context: String, before: SpotifyWebAPI.CurrentlyPlaying?, timeout: TimeInterval = 4) async -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        var checks = 0
        repeat {
            if Task.isCancelled { return nil }
            checks += 1
            if let after = try? await SpotifyWebAPI.shared.fetchCurrentlyPlaying(),
               Self.likedSongsStarted(context: context, before: before, after: after) {
                return checks
            }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return nil }
        } while Date() < deadline
        return nil
    }

    /// Whether the player moved to Liked Songs. With Smart Shuffle on, Spotify swaps the
    /// collection for a generated `spotify:playlist:37i9…` context, so any change from
    /// what played before counts; music that was already playing and didn't change doesn't.
    static func likedSongsStarted(
        context: String,
        before: SpotifyWebAPI.CurrentlyPlaying?,
        after: SpotifyWebAPI.CurrentlyPlaying
    ) -> Bool {
        guard after.isPlaying else { return false }
        guard let before, before.isPlaying else { return true }
        return after.contextURI == context
            || after.contextURI != before.contextURI
            || after.track.uri != before.track.uri
    }

    private func launchInBackground() async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.spotifyBundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// The device to play on: the active one, else this Mac, else any. Polls until one
    /// shows up or `timeout` seconds pass.
    private func waitForDevice(timeout: TimeInterval) async throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let devices = (try? await SpotifyWebAPI.shared.fetchAvailableDevices()) ?? []
            if let device = devices.first(where: { $0.isActive })
                ?? devices.first(where: { $0.type == "Computer" })
                ?? devices.first {
                return device.id
            }
            guard Date() < deadline else { throw SpotifyWebAPI.SpotifyAPIError.noActiveDevice }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func openLikedSongsPage() {
        guard let url = URL(string: "spotify:collection:tracks") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            if let error { owLog("[SpotifyController] Opening Liked Songs failed: \(error)") }
        }
    }

    /// Whether the Spotify app on this Mac is running and playing right now. Natural
    /// phrasing ("bu şarkıdan sıkıldım") only counts as a command while this holds, so
    /// the same sentence is still dictation when no music is on. Requires the local app
    /// so that music playing on a phone doesn't turn Mac dictation into commands.
    func isPlayingLocally() async -> Bool {
        guard isSpotifyRunning else { return false }
        if Self.appleScriptFallbackEnabled {
            if case .success(let state) = runSpotifyCommand("return player state as text") {
                return state == "playing"
            }
        }
        guard webAPIConnected else { return false }
        return (try? await SpotifyWebAPI.shared.fetchCurrentlyPlaying())?.isPlaying ?? false
    }

    // MARK: - Undo

    /// What the local Spotify app was playing, so a command re-run after correction can
    /// undo the first one. AppleScript only: it can jump to a track and a second directly.
    struct PlayerSnapshot: Equatable {
        let trackURI: String
        let position: Double
        let isPlaying: Bool
    }

    func playerSnapshot() -> PlayerSnapshot? {
        guard Self.appleScriptFallbackEnabled, isSpotifyRunning,
              case .success(let output) = runSpotifyCommand(
                "return (player state as text) & linefeed & (id of current track) & linefeed & (player position as text)"
              ) else { return nil }
        let lines = (output ?? "").components(separatedBy: "\n")
        guard lines.count == 3, Self.isValidTrackURI(lines[1]),
              let position = Double(lines[2].replacingOccurrences(of: ",", with: ".")) else { return nil }
        return PlayerSnapshot(trackURI: lines[1], position: position, isPlaying: lines[0] == "playing")
    }

    /// Puts Spotify back to `snapshot`: the same track at the same second, playing or paused.
    func restore(_ snapshot: PlayerSnapshot) -> Bool {
        guard Self.isValidTrackURI(snapshot.trackURI), let current = playerSnapshot() else { return false }
        if current.trackURI != snapshot.trackURI {
            guard case .success = runSpotifyCommand("play track \"\(snapshot.trackURI)\""),
                  case .success = runSpotifyCommand("set player position to \(Int(snapshot.position))") else { return false }
        }
        let command = snapshot.isPlaying ? "play" : "pause"
        guard case .success = runSpotifyCommand(command) else { return false }
        owLog("[SpotifyController] Restored \(snapshot.trackURI) at \(Int(snapshot.position))s, \(command)")
        return true
    }

    // MARK: - Current track

    func getCurrentTrack() async -> SpotifyActionResult {
        await perform(
            "Çalan şarkı bilgisi",
            readOnly: true,
            web: {
                guard let current = try await SpotifyWebAPI.shared.fetchCurrentlyPlaying() else {
                    throw SpotifyWebAPI.SpotifyAPIError.noResults
                }
                return Self.describe(
                    name: current.track.name,
                    artist: current.track.artist,
                    album: current.album,
                    isPlaying: current.isPlaying
                )
            },
            appleScript: {
                // Checked first: `tell application "Spotify"` would otherwise cold-launch
                // Spotify just to answer "what's playing" with nothing.
                guard self.isSpotifyRunning else { return .failure(.appNotRunning) }
                let script = """
                    tell application "Spotify" to return (player state as text) & linefeed & \
                    (name of current track) & linefeed & (artist of current track) & linefeed & \
                    (album of current track)
                    """
                return self.runAppleScript(script).flatMap { output in
                    let lines = (output ?? "").components(separatedBy: "\n")
                    guard lines.count >= 3, !lines[1].isEmpty else {
                        return .failure(.other(errorNumber: 0, message: "no current track"))
                    }
                    return .success(Self.describe(
                        name: lines[1],
                        artist: lines[2],
                        album: lines.count > 3 ? lines[3] : nil,
                        isPlaying: lines[0] == "playing"
                    ))
                }
            }
        )
    }

    private static func describe(name: String, artist: String, album: String?, isPlaying: Bool) -> String {
        let label = artist.isEmpty ? name : "\(artist) — \(name)"
        let albumPart = album.map { $0.isEmpty ? "" : " (\($0))" } ?? ""
        return "\(isPlaying ? L("Çalıyor", "Playing") : L("Duraklatıldı", "Paused")): ♪ \(label)\(albumPart)"
    }

    // MARK: - Search & play

    /// Resolves `request` in its catalog (song, artist, album or playlist) and plays the
    /// best match, trying its queries from most to least specific. An artist, album or
    /// playlist that can't be found falls back to a song search of the whole request.
    /// When nothing can be played, opens Spotify's own search (or item) screen instead of
    /// starting whatever happens to be queued — never plays something unrelated.
    func searchAndPlay(_ request: SpotifySearchRequest) async -> SpotifyActionResult {
        let started = Date()
        defer { owLog(String(format: "[SpotifyLatency] search/play total %.0f ms", Date().timeIntervalSince(started) * 1000)) }
        let queries = request.searchQueries
        guard !queries.isEmpty else {
            return .failure(L("Arama sorgusu boş olamaz", "The search can't be empty"))
        }
        if request.kind == .playlist || request.kind == .freeText,
           SpotifyRequestParser.namesLikedSongs("\(request.title) \(request.freeText)") {
            owLog("[SpotifyController] '\(request.displayText)' means Liked Songs → own collection")
            return await playLikedSongs()
        }

        // "Spotify'da Tarkan çal": the words alone can't say whether "Tarkan" is an artist
        // or a song. If Spotify has an artist with exactly that name, play the artist.
        var prefetchedTrack: SpotifyWebAPI.TrackResult?
        if request.kind == .freeText {
            // These are read-only catalog lookups. Preserve exact-artist precedence, but
            // don't make every song search wait for the artist lookup first.
            let candidates = await Self.searchCandidates(
                artist: { try? await SpotifyWebAPI.shared.searchTopItem(query: request.freeText, type: .artist) },
                track: { await self.firstSearchHit(queries: queries, type: .track) }
            )
            prefetchedTrack = candidates.track
            if let artist = candidates.artist,
               SpotifyRequestParser.foldedWords(artist.name) == SpotifyRequestParser.foldedWords(request.freeText) {
                owLog("[SpotifyController] '\(request.freeText)' is an artist name → artist context")
                let result = await playContext(artist, type: .artist)
                if result.succeeded { return result }
            }
        }

        var type = request.catalogType
        var item = request.kind == .freeText ? prefetchedTrack
            : type == .playlist ? await variedPlaylistHit(queries: queries, title: request.title)
            : await firstSearchHit(queries: queries, type: type)
        if item == nil, type != .track, !request.freeText.isEmpty {
            type = .track
            item = await firstSearchHit(queries: [request.freeText], type: .track)
        }

        guard let item else {
            let shown = request.displayText.isEmpty ? queries[queries.count - 1] : request.displayText
            return openInSpotify(
                "spotify:search:\(shown)",
                message: L("Otomatik çalma yapılamadı. \"\(shown)\" için arama ekranı açıldı.", "Couldn't play it automatically. Opened the search for \"\(shown)\".")
            )
        }

        if type == .playlist, SpotifyRequestParser.namesLikedSongs(item.name) {
            owLog("[SpotifyController] Found playlist '\(item.name)' is a Liked Songs copy → own collection")
            return await playLikedSongs()
        }

        let result = type == .track ? await playTrack(item) : await playContext(item, type: type, shuffled: type == .playlist)
        if result.succeeded {
            if type == .playlist { Self.rememberPlaylist(item.uri) }
            return result
        }
        return openInSpotify(
            item.uri,
            message: "\(result.message). " + L("Spotify'da açıldı: ", "Opened in Spotify: ") + Self.label(for: item)
        )
    }

    static func searchCandidates(
        artist: @Sendable () async -> SpotifyWebAPI.TrackResult?,
        track: @Sendable () async -> SpotifyWebAPI.TrackResult?
    ) async -> (artist: SpotifyWebAPI.TrackResult?, track: SpotifyWebAPI.TrackResult?) {
        async let artistResult = artist()
        async let trackResult = track()
        return await (artistResult, trackResult)
    }

    /// "Sakin bir şeyler aç" searches the playlist catalog for "sakin". Spotify's first hit
    /// is the same every time, so pick at random among the top ones, skipping the lists
    /// played recently. A result named exactly like the request ("Türkçe Pop listesi") wins.
    private func variedPlaylistHit(queries: [String], title: String) async -> SpotifyWebAPI.TrackResult? {
        for query in queries {
            do {
                let items = try await SpotifyWebAPI.shared.searchItems(query: query, type: .playlist, limit: 10)
                guard let item = Self.pickPlaylist(items, title: title, recent: Self.recentPlaylists) else { continue }
                owLog("[SpotifyController] playlist '\(query)' → \(Self.label(for: item)) (of \(items.count))")
                return item
            } catch SpotifyWebAPI.SpotifyAPIError.noResults {
                owLog("[SpotifyController] No playlist results for '\(query)'")
            } catch {
                owLog("[SpotifyController] playlist search failed: \(error)")
                return nil
            }
        }
        return nil
    }

    static let recentPlaylistsKey = "spotifyRecentMoodPlaylists"
    static var recentPlaylists: [String] {
        UserDefaults.standard.stringArray(forKey: recentPlaylistsKey) ?? []
    }

    static func rememberPlaylist(_ uri: String) {
        UserDefaults.standard.set(rememberedPlaylists(adding: uri, to: recentPlaylists), forKey: recentPlaylistsKey)
    }

    /// The last five played, newest first.
    static func rememberedPlaylists(adding uri: String, to recent: [String]) -> [String] {
        Array(([uri] + recent.filter { $0 != uri }).prefix(5))
    }

    static func pickPlaylist(_ items: [SpotifyWebAPI.TrackResult], title: String, recent: [String]) -> SpotifyWebAPI.TrackResult? {
        let wanted = SpotifyRequestParser.foldedWords(title)
        if !wanted.isEmpty, let exact = items.first(where: { SpotifyRequestParser.foldedWords($0.name) == wanted }) {
            return exact
        }
        let fresh = items.filter { !recent.contains($0.uri) }
        return (fresh.isEmpty ? items : fresh).randomElement()
    }

    /// First result across `queries`. Stops early on errors other than "no results":
    /// credentials or network problems won't be fixed by a different query string.
    private func firstSearchHit(queries: [String], type: SpotifyWebAPI.SearchType) async -> SpotifyWebAPI.TrackResult? {
        let started = Date()
        defer { owLog(String(format: "[SpotifyLatency] %@ lookup %.0f ms", type.rawValue, Date().timeIntervalSince(started) * 1000)) }
        for query in queries {
            do {
                let item = type == .track
                    ? try await SpotifyWebAPI.shared.searchTopTrack(query: query)
                    : try await SpotifyWebAPI.shared.searchTopItem(query: query, type: type)
                owLog("[SpotifyController] \(type.rawValue) '\(query)' → \(Self.label(for: item))")
                return item
            } catch SpotifyWebAPI.SpotifyAPIError.noResults {
                owLog("[SpotifyController] No \(type.rawValue) results for '\(query)'")
            } catch {
                owLog("[SpotifyController] \(type.rawValue) search failed: \(error)")
                return nil
            }
        }
        return nil
    }

    /// Plays one already-resolved track so that playback carries on afterwards:
    /// - Something is loaded in Spotify: the track is added to the queue and skipped to,
    ///   so the previous context (playlist, album…) continues once it ends.
    /// - Nothing is loaded: the track is started inside its album, which continues.
    /// The URI is validated before it is interpolated into AppleScript, so a malformed
    /// search result cannot inject script. AppleScript has no queue, so that fallback
    /// plays the single track (Spotify's own Autoplay setting decides what follows).
    func playTrack(_ track: SpotifyWebAPI.TrackResult) async -> SpotifyActionResult {
        guard Self.isValidTrackURI(track.uri) else {
            return .failure(L("Geçersiz Spotify şarkı adresi", "Invalid Spotify song address"))
        }
        let message = "♪ \(Self.label(for: track))"
        return await perform(
            "Şarkı çalma",
            web: { try await self.queueAndPlay(track, message: message) },
            appleScript: { self.runSpotifyCommand("play track \"\(track.uri)\"").map { _ in message } }
        )
    }

    private func queueAndPlay(_ track: SpotifyWebAPI.TrackResult, message: String) async throws -> String {
        let current = try? await SpotifyWebAPI.shared.fetchCurrentlyPlaying()
        guard current != nil else {
            try await withDeviceFallback { deviceID in
                if let album = track.albumURI, Self.isValidContextURI(album) {
                    try await SpotifyWebAPI.shared.startPlayback(contextURI: album, offsetURI: track.uri, deviceID: deviceID)
                } else {
                    try await SpotifyWebAPI.shared.startPlayback(uris: [track.uri], deviceID: deviceID)
                }
            }
            return message
        }

        try await SpotifyWebAPI.shared.addToQueue(uri: track.uri)

        // Items the user queued earlier play first, and skipping past them would throw
        // them away. Skip when the new track is next (or the queue can't be read, the
        // common case of an empty user queue); otherwise just report its position.
        var position = await queuePosition(of: track.uri)
        if position == nil {
            // The queue endpoint can lag the add by a moment.
            try? await Task.sleep(nanoseconds: 300_000_000)
            position = await queuePosition(of: track.uri)
        }
        switch position {
        case 0?, nil:
            try await SpotifyWebAPI.shared.skipToNext()
            return message
        case let ahead?:
            return L("Sıraya eklendi, önünde \(ahead) şarkı var: ", "Queued, \(ahead) songs ahead of it: ") + message
        }
    }

    private func queuePosition(of uri: String) async -> Int? {
        (try? await SpotifyWebAPI.shared.fetchQueueURIs())?.firstIndex(of: uri)
    }

    /// Plays an artist, album or playlist as a context, so Spotify keeps going through it.
    /// `shuffled` (mood playlists) turns shuffle on and starts at a random track, so the
    /// same list doesn't open on the same song.
    func playContext(_ item: SpotifyWebAPI.TrackResult, type: SpotifyWebAPI.SearchType, shuffled: Bool = false) async -> SpotifyActionResult {
        guard Self.isValidContextURI(item.uri) else {
            return .failure(L("Geçersiz Spotify adresi", "Invalid Spotify address"))
        }
        let message: String
        switch type {
        case .artist: message = "♪ \(item.name) — " + L("popüler şarkılar", "popular songs")
        case .album: message = "💿 \(Self.label(for: item))"
        case .playlist, .track: message = "📃 \(item.name)"
        }
        return await perform(
            "Çalma",
            web: {
                try await self.withDeviceFallback { deviceID in
                    var start: Int?
                    if shuffled {
                        do {
                            try await SpotifyWebAPI.shared.setShuffle(true, deviceID: deviceID)
                        } catch {
                            owLog("[SpotifyController] Playlist shuffle not set: \(error)")
                        }
                        if let count = item.trackCount, count > 1 { start = Int.random(in: 0..<count) }
                    }
                    try await SpotifyWebAPI.shared.startPlayback(contextURI: item.uri, offsetPosition: start, deviceID: deviceID)
                }
                return message
            },
            appleScript: { self.runSpotifyCommand("play track \"\(item.uri)\"").map { _ in message } }
        )
    }

    static func isValidContextURI(_ uri: String) -> Bool {
        uri.range(of: #"^spotify:(album|artist|playlist):[A-Za-z0-9]+$"#, options: .regularExpression) != nil
    }

    static func isValidTrackURI(_ uri: String) -> Bool {
        uri.range(of: #"^spotify:track:[A-Za-z0-9]+$"#, options: .regularExpression) != nil
    }

    private static func label(for track: SpotifyWebAPI.TrackResult) -> String {
        track.artist.isEmpty ? track.name : "\(track.artist) — \(track.name)"
    }

    /// Opening a `spotify:` URL only navigates the Spotify app; it works in the sandbox and
    /// needs no Automation permission.
    private func openInSpotify(_ spotifyURI: String, message: String) -> SpotifyActionResult {
        guard let encoded = spotifyURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: encoded),
              NSWorkspace.shared.open(url) else {
            return .failure(L("Spotify açılamadı", "Couldn't open Spotify"))
        }
        return .success(message)
    }

    // MARK: - Like

    /// Adds the current track to Liked Songs. Always needs the Web API (Spotify's
    /// AppleScript dictionary has no like command); AppleScript is only used, when
    /// allowed, to find out which track is playing if the Web API can't say.
    func likeCurrentTrack() async -> SpotifyActionResult {
        guard webAPIConnected else {
            return .failure(SpotifyWebAPI.SpotifyAPIError.notConnected.userMessage)
        }

        var trackURI: String?
        var trackName: String?
        do {
            if let current = try await SpotifyWebAPI.shared.fetchCurrentlyPlaying() {
                trackURI = current.track.uri
                trackName = current.track.name
            }
        } catch {
            owLog("[SpotifyController] playback state failed: \(error)")
        }

        if trackURI == nil, Self.appleScriptFallbackEnabled, isSpotifyRunning,
           case .success(let output) = runSpotifyCommand("return (id of current track) & linefeed & (name of current track)") {
            let lines = (output ?? "").components(separatedBy: "\n")
            if let uri = lines.first, Self.isValidTrackURI(uri) {
                trackURI = uri
                trackName = lines.count > 1 ? lines[1] : nil
            }
        }

        guard let trackURI, Self.isValidTrackURI(trackURI) else {
            return .failure(L("Şu an çalan bir şarkı bulunamadı", "No song is playing right now"))
        }

        do {
            try await SpotifyWebAPI.shared.saveToLibrary(uri: trackURI)
            let name = trackName.map { "\"\($0)\"" } ?? L("Çalan şarkı", "The current song")
            return .success(L("\(name) Beğenilen Şarkılar'a eklendi ❤️", "\(name) added to Liked Songs ❤️"))
        } catch {
            return .failure(L("Beğenilenlere eklenemedi: ", "Couldn't add it to Liked Songs: ") + Self.reason(for: error))
        }
    }

    // MARK: - Web API → AppleScript fallback

    /// Set once a player call reports that the account isn't Premium, so later commands in
    /// this session skip a Web API round trip that is known to fail. Races are harmless:
    /// the worst case is one extra failed request.
    private var webAPIPlayerUnavailable = false

    /// - Parameter readOnly: the action has no side effects, so falling back after an
    ///   ambiguous Web API failure can't run it twice.
    private func perform(
        _ action: String,
        readOnly: Bool = false,
        web: () async throws -> String,
        appleScript: () -> Result<String, SpotifyScriptError>
    ) async -> SpotifyActionResult {
        let started = Date()
        defer { owLog(String(format: "[SpotifyLatency] %@ action %.0f ms", action, Date().timeIntervalSince(started) * 1000)) }
        var webFailure: String?
        if webAPIConnected, readOnly || !webAPIPlayerUnavailable {
            do {
                return .success(try await web())
            } catch {
                owLog("[SpotifyController] Web API '\(action)' failed: \(error)")
                webFailure = Self.reason(for: error)
                if case SpotifyWebAPI.SpotifyAPIError.premiumRequired = error {
                    webAPIPlayerUnavailable = true
                }
                // A timeout or unexpected status may mean Spotify already executed the
                // command and only the response was lost. Repeating it over AppleScript
                // could then skip two tracks, so only fall back when it surely didn't run.
                if !readOnly, !Self.definitelyNotExecuted(error) {
                    return .failure(L("\(action) başarısız: ", "\(action) failed: ") + webFailure!)
                }
            }
        } else if webAPIPlayerUnavailable, !readOnly {
            webFailure = SpotifyWebAPI.SpotifyAPIError.premiumRequired.userMessage
        }

        guard Self.appleScriptFallbackEnabled else {
            let reason = webFailure ?? SpotifyWebAPI.SpotifyAPIError.notConnected.userMessage
            return .failure(L("\(action) başarısız: ", "\(action) failed: ") + reason)
        }

        switch appleScript() {
        case .success(let message):
            return .success(message)
        case .failure(let error):
            return .failure(error.userMessage)
        }
    }

    /// The Web API reports "no active device" whenever the Spotify client is open but idle.
    /// Retrying once against an explicit device (preferring this Mac) avoids that 404
    /// without touching AppleScript, so it also works in the App Store build.
    private func withDeviceFallback(_ body: (String?) async throws -> Void) async throws {
        // Idle is the usual case (all 4 play commands on 15 Oct 2026 got the 404), and the
        // failed call costs ~0.4 s; the device list costs ~0.08 s, so check it first.
        if let devices = try? await SpotifyWebAPI.shared.fetchAvailableDevices(),
           !devices.contains(where: { $0.isActive }),
           let device = devices.first(where: { $0.type == "Computer" }) ?? devices.first {
            owLog("[SpotifyController] No active device; playing on \(device.name) (\(device.type))")
            try await body(device.id)
            return
        }
        do {
            try await body(nil)
        } catch SpotifyWebAPI.SpotifyAPIError.noActiveDevice {
            let devices = try await SpotifyWebAPI.shared.fetchAvailableDevices()
            guard let device = devices.first(where: { $0.isActive })
                    ?? devices.first(where: { $0.type == "Computer" })
                    ?? devices.first else {
                throw SpotifyWebAPI.SpotifyAPIError.noActiveDevice
            }
            owLog("[SpotifyController] Retrying on device \(device.name) (\(device.type))")
            try await body(device.id)
        }
    }

    /// Errors Spotify returns before acting on a command (auth, scope, Premium, device,
    /// rate limit). Network errors and unexpected statuses are deliberately excluded.
    private static func definitelyNotExecuted(_ error: Error) -> Bool {
        guard let apiError = error as? SpotifyWebAPI.SpotifyAPIError else { return false }
        switch apiError {
        case .missingCredentials, .invalidCredentials, .notConnected, .rateLimited,
             .scopeInsufficient, .noActiveDevice, .premiumRequired, .playerRestricted:
            return true
        case .network, .noResults, .authorizationFailed, .alreadyInProgress, .unexpected:
            return false
        }
    }

    private static func reason(for error: Error) -> String {
        (error as? SpotifyWebAPI.SpotifyAPIError)?.userMessage ?? error.localizedDescription
    }

    // MARK: - AppleScript

    enum SpotifyScriptError: Error {
        case disabled
        case permissionDenied(errorNumber: Int)
        case appNotRunning
        case other(errorNumber: Int, message: String)

        var userMessage: String {
            switch self {
            case .disabled:
                return SpotifyWebAPI.SpotifyAPIError.notConnected.userMessage
            case .permissionDenied:
                return L("Spotify kontrolü için izin gerekli — Sistem Ayarları > Gizlilik ve Güvenlik > Otomasyon > Jarvis > Spotify açık olmalı.", "Spotify control needs permission — System Settings > Privacy & Security > Automation > Jarvis > Spotify must be on.")
            case .appNotRunning:
                return L("Spotify çalışmıyor görünüyor.", "Spotify doesn't seem to be running.")
            case .other(let number, _):
                return L("Spotify komutu başarısız oldu (\(number)).", "The Spotify command failed (\(number)).")
            }
        }
    }

    /// `command` must be a fixed string or contain only validated values (see
    /// `isValidTrackURI`, `setVolume`) — it is interpolated into AppleScript source.
    private func runSpotifyCommand(_ command: String) -> Result<String?, SpotifyScriptError> {
        runAppleScript("tell application \"Spotify\" to \(command)")
    }

    /// NSAppleScript blocks until the default ~2 minute Apple Event timeout if Spotify
    /// hangs or is slow to cold-launch; the old Python path capped this at 5 seconds.
    private static func withTimeout(_ script: String) -> String {
        "with timeout of 5 seconds\n\(script)\nend timeout"
    }

    private func runAppleScript(_ script: String) -> Result<String?, SpotifyScriptError> {
        guard Self.appleScriptFallbackEnabled else {
            return .failure(.disabled)
        }
        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: Self.withTimeout(script)) else {
            return .failure(.other(errorNumber: -1, message: "Failed to parse AppleScript"))
        }
        let output = scriptObject.executeAndReturnError(&error)
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            owLog("[SpotifyController] AppleScript error \(number): \(message)")
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
}

// MARK: - Playback modes, library, devices and questions

extension SpotifyController {
    /// "1 dakika 30 saniye", "45 saniye", "2 saat".
    static func spokenDuration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        var parts: [String] = []
        let english = CommandLanguage.isEnglish
        if h > 0 { parts.append(english ? "\(h) hour\(h == 1 ? "" : "s")" : "\(h) saat") }
        if m > 0 { parts.append(english ? "\(m) minute\(m == 1 ? "" : "s")" : "\(m) dakika") }
        if s > 0 || parts.isEmpty { parts.append(english ? "\(s) second\(s == 1 ? "" : "s")" : "\(s) saniye") }
        return parts.joined(separator: " ")
    }

    func setShuffle(_ on: Bool) async -> SpotifyActionResult {
        let message = on ? L("Karışık çalma açıldı", "Shuffle on") : L("Karışık çalma kapatıldı", "Shuffle off")
        return await perform(
            "Karışık çalma",
            web: {
                // Setting it again could drop the user's Smart Shuffle.
                if let state = try? await SpotifyWebAPI.shared.fetchCurrentlyPlaying(), state.shuffle == on {
                    return on ? L("Karışık çalma zaten açık", "Shuffle is already on") : L("Karışık çalma zaten kapalı", "Shuffle is already off")
                }
                try await SpotifyWebAPI.shared.setShuffle(on, deviceID: nil)
                return message
            },
            appleScript: { self.runSpotifyCommand("set shuffling to \(on)").map { _ in message } }
        )
    }

    func setRepeat(_ mode: SpotifyRepeatMode) async -> SpotifyActionResult {
        let message: String
        switch mode {
        case .track: message = L("Bu şarkı tekrar edecek", "This song will repeat")
        case .context: message = L("Liste tekrar edecek", "The list will repeat")
        case .off: message = L("Tekrar kapatıldı", "Repeat off")
        }
        return await perform(
            "Tekrar",
            web: {
                try await SpotifyWebAPI.shared.setRepeat(mode)
                return message
            },
            appleScript: {
                // AppleScript has one on/off switch; it can't repeat a single song.
                guard mode != .track else {
                    return .failure(.other(errorNumber: 0, message: L("Tek şarkıyı tekrar için Spotify hesabını bağlaman gerekiyor", "Repeating one song needs your Spotify account connected")))
                }
                return self.runSpotifyCommand("set repeating to \(mode == .context)").map { _ in message }
            }
        )
    }

    func seek(_ seek: SpotifySeek) async -> SpotifyActionResult {
        let message: String
        switch seek {
        case .to(0): message = L("Başa sarıldı", "Back to the start")
        case .to(let s): message = L("\(Self.spokenDuration(s)) noktasına gidildi", "Jumped to \(Self.spokenDuration(s))")
        case .by(let d): message = L("\(Self.spokenDuration(abs(d))) \(d > 0 ? "ileri" : "geri") sarıldı", "\(d > 0 ? "Forward" : "Back") \(Self.spokenDuration(abs(d)))")
        }
        return await perform(
            "Sarma",
            web: {
                var target: Int
                switch seek {
                case .to(let s):
                    target = s * 1000
                case .by(let d):
                    guard let state = try await SpotifyWebAPI.shared.fetchCurrentlyPlaying(),
                          let progress = state.progressMs else { throw SpotifyWebAPI.SpotifyAPIError.noActiveDevice }
                    target = progress + d * 1000
                }
                if case .by = seek, let state = try? await SpotifyWebAPI.shared.fetchCurrentlyPlaying(),
                   let duration = state.durationMs {
                    target = min(target, max(0, duration - 1000))
                }
                try await SpotifyWebAPI.shared.seek(toMs: max(0, target))
                return message
            },
            appleScript: {
                let command: String
                switch seek {
                case .to(let s): command = "set player position to \(s)"
                case .by(let d): command = "set player position to (player position + \(d))"
                }
                return self.runSpotifyCommand(command).map { _ in message }
            }
        )
    }

    /// Finds the song and adds it to the queue; what plays now keeps playing.
    func queue(_ request: SpotifySearchRequest) async -> SpotifyActionResult {
        guard webAPIConnected else { return .failure(SpotifyWebAPI.SpotifyAPIError.notConnected.userMessage) }
        let queries = request.kind == .track || request.kind == .freeText ? request.searchQueries : [request.freeText]
        guard let track = await firstSearchHit(queries: queries.filter { !$0.isEmpty }, type: .track) else {
            return .failure(L("\(request.displayText) bulunamadı", "\(request.displayText) not found"))
        }
        do {
            try await SpotifyWebAPI.shared.addToQueue(uri: track.uri)
            return .success(L("Sıraya eklendi: ", "Queued: ") + Self.label(for: track))
        } catch {
            return .failure(L("Sıraya eklenemedi: ", "Couldn't queue it: ") + Self.reason(for: error))
        }
    }

    func unlikeCurrentTrack() async -> SpotifyActionResult {
        guard webAPIConnected else { return .failure(SpotifyWebAPI.SpotifyAPIError.notConnected.userMessage) }
        do {
            guard let current = try await SpotifyWebAPI.shared.fetchCurrentlyPlaying() else {
                return .failure(L("Şu an çalan bir şarkı yok", "No song is playing right now"))
            }
            try await SpotifyWebAPI.shared.removeFromLibrary(uri: current.track.uri)
            return .success(L("\(current.track.name) beğenilenlerden çıkarıldı", "\(current.track.name) removed from Liked Songs"))
        } catch {
            return .failure(L("Beğenilenlerden çıkarılamadı: ", "Couldn't remove it from Liked Songs: ") + Self.reason(for: error))
        }
    }

    // MARK: Playlists

    private static let playlistCache = OSAllocatedUnfairLock<(date: Date, items: [SpotifyWebAPI.Playlist])?>(initialState: nil)

    /// The user's playlist named `name` (see `matchPlaylist`). `writable`: only playlists the
    /// user owns or that are collaborative.
    func findPlaylist(named name: String, writable: Bool) async throws -> SpotifyWebAPI.Playlist? {
        let playlists: [SpotifyWebAPI.Playlist]
        if let cached = Self.playlistCache.withLock({ $0 }), Date().timeIntervalSince(cached.date) < 300 {
            playlists = cached.items
        } else {
            playlists = try await SpotifyWebAPI.shared.fetchPlaylists()
            Self.playlistCache.withLock { $0 = (Date(), playlists) }
        }
        let userID = writable ? try await SpotifyWebAPI.shared.fetchUserID() : ""
        let candidates = playlists.filter { !writable || $0.ownerID == userID || $0.collaborative }
        return Self.matchPlaylist(named: name, in: candidates)
    }

    /// Same folded words wins. Otherwise the one playlist whose words include every word
    /// asked for ("spor" → "Spor 2024"), never a substring ("spor" is not "Esports"); two
    /// such playlists are ambiguous, so none.
    static func matchPlaylist(named name: String, in playlists: [SpotifyWebAPI.Playlist]) -> SpotifyWebAPI.Playlist? {
        // Folding keeps the dotless ı, so "çalışma" would miss a playlist typed "Calisma".
        func words(_ text: String) -> [String] {
            SpotifyRequestParser.foldedWords(text).map { $0.replacingOccurrences(of: "ı", with: "i") }
        }
        let wanted = words(name)
        guard !wanted.isEmpty else { return nil }
        if let exact = playlists.first(where: { words($0.name) == wanted }) { return exact }
        let containing = playlists.filter { Set(words($0.name)).isSuperset(of: wanted) }
        return containing.count == 1 ? containing[0] : nil
    }

    func ownPlaylist(named name: String, writable: Bool) async -> SpotifyWebAPI.Playlist? {
        guard webAPIConnected else { return nil }
        do {
            return try await findPlaylist(named: name, writable: writable)
        } catch {
            owLog("[SpotifyController] Playlists not readable: \(error)")
            return nil
        }
    }

    func playOwnPlaylist(named name: String) async -> SpotifyActionResult {
        guard webAPIConnected else { return .failure(SpotifyWebAPI.SpotifyAPIError.notConnected.userMessage) }
        do {
            guard let playlist = try await findPlaylist(named: name, writable: false) else {
                return .failure(L("\(name) adında bir listen bulunamadı", "No playlist of yours named \(name) found"))
            }
            return await playContext(SpotifyWebAPI.TrackResult(uri: playlist.uri, name: playlist.name, artist: ""), type: .playlist)
        } catch {
            return .failure(L("Listelerin okunamadı: ", "Couldn't read your playlists: ") + Self.reason(for: error))
        }
    }

    func addCurrentTrack(toPlaylistNamed name: String) async -> SpotifyActionResult {
        guard webAPIConnected else { return .failure(SpotifyWebAPI.SpotifyAPIError.notConnected.userMessage) }
        do {
            guard let current = try await SpotifyWebAPI.shared.fetchCurrentlyPlaying() else {
                return .failure(L("Şu an çalan bir şarkı yok", "No song is playing right now"))
            }
            guard let playlist = try await findPlaylist(named: name, writable: true) else {
                return .failure(L("\(name) adında sana ait bir liste bulunamadı", "No playlist of yours named \(name) found"))
            }
            try await SpotifyWebAPI.shared.addToPlaylist(id: playlist.id, uri: current.track.uri)
            return .success("\(current.track.name), \(playlist.name) listesine eklendi")
        } catch {
            return .failure("Listeye eklenemedi: \(Self.reason(for: error))")
        }
    }

    // MARK: Library

    func playSavedAlbum() async -> SpotifyActionResult {
        await playRandom(from: { try await SpotifyWebAPI.shared.fetchSavedAlbums() }, type: .album, empty: L("Kaydedilmiş albümün yok", "You have no saved albums"))
    }

    func playFollowedArtist() async -> SpotifyActionResult {
        await playRandom(from: { try await SpotifyWebAPI.shared.fetchFollowedArtists() }, type: .artist, empty: L("Takip ettiğin sanatçı yok", "You follow no artists"))
    }

    private func playRandom(
        from fetch: () async throws -> [SpotifyWebAPI.TrackResult],
        type: SpotifyWebAPI.SearchType,
        empty: String
    ) async -> SpotifyActionResult {
        guard webAPIConnected else { return .failure(SpotifyWebAPI.SpotifyAPIError.notConnected.userMessage) }
        do {
            guard let item = try await fetch().randomElement() else { return .failure(empty) }
            return await playContext(item, type: type)
        } catch {
            return .failure(Self.reason(for: error))
        }
    }

    /// The most recently played song that isn't the one playing now.
    func playRecentTrack() async -> SpotifyActionResult {
        guard webAPIConnected else { return .failure(SpotifyWebAPI.SpotifyAPIError.notConnected.userMessage) }
        do {
            let current = (try? await SpotifyWebAPI.shared.fetchCurrentlyPlaying())?.track.uri
            guard let track = try await SpotifyWebAPI.shared.fetchRecentTracks().first(where: { $0.uri != current }) else {
                return .failure(L("Son dinlenen bir şarkı bulunamadı", "No recently played song found"))
            }
            return await playTrack(track)
        } catch {
            return .failure(Self.reason(for: error))
        }
    }

    // MARK: Devices

    func transferPlayback(to kind: SpotifyDeviceKind) async -> SpotifyActionResult {
        guard webAPIConnected else { return .failure(SpotifyWebAPI.SpotifyAPIError.notConnected.userMessage) }
        do {
            let devices = try await SpotifyWebAPI.shared.fetchAvailableDevices()
            let matching = devices.filter { kind.connectTypes.contains($0.type.lowercased()) }
            guard let device = matching.first(where: { !$0.isActive }) ?? matching.first else {
                return .failure(L("Spotify'da bir \(kind.spokenName) görünmüyor; o cihazda Spotify'ı açıp tekrar dene", "Spotify shows no \(kind.spokenName); open Spotify on it and try again"))
            }
            if device.isActive { return .success(L("Müzik zaten \(device.name) cihazında çalıyor", "The music is already playing on \(device.name)")) }
            try await SpotifyWebAPI.shared.transferPlayback(toDevice: device.id)
            owLog("[SpotifyController] Playback moved to \(device.name) (\(device.type))")
            return .success(L("Müzik \(device.name) cihazına geçti", "The music moved to \(device.name)"))
        } catch {
            return .failure(L("Müzik taşınamadı: ", "Couldn't move the music: ") + Self.reason(for: error))
        }
    }

    // MARK: Questions

    func answer(_ question: SpotifyQuestion) async -> SpotifyActionResult {
        await perform(
            "Spotify bilgisi",
            readOnly: true,
            web: {
                if question == .nextUp {
                    guard let next = try await SpotifyWebAPI.shared.fetchQueue().first else {
                        return L("Sırada şarkı görünmüyor", "There is no song in the queue")
                    }
                    return L("Sıradaki şarkı: ", "Up next: ") + Self.label(for: next)
                }
                guard let state = try await SpotifyWebAPI.shared.fetchCurrentlyPlaying() else {
                    return L("Şu an Spotify'da bir şey çalmıyor", "Nothing is playing on Spotify right now")
                }
                switch question {
                case .device:
                    guard state.isPlaying else { return L("Şu an Spotify'da bir şey çalmıyor", "Nothing is playing on Spotify right now") }
                    return L("Şu an \(state.deviceName ?? "bilinmeyen bir cihaz") cihazında çalıyor", "Playing on \(state.deviceName ?? "an unknown device")")
                case .album:
                    guard let album = state.album, !album.isEmpty else { return L("Bu şarkının albüm bilgisi yok", "There is no album info for this song") }
                    return L("Bu şarkı \(album) albümünden", "This song is from \(album)")
                case .timeLeft:
                    guard let duration = state.durationMs, let progress = state.progressMs else {
                        return L("Kalan süreyi bilemiyorum", "I can't tell the time left")
                    }
                    return L("Şarkının bitmesine \(Self.spokenDuration(max(0, duration - progress) / 1000)) var", "\(Self.spokenDuration(max(0, duration - progress) / 1000)) left in the song")
                case .nextUp:
                    return ""
                }
            },
            appleScript: {
                guard self.isSpotifyRunning else { return .failure(.appNotRunning) }
                switch question {
                case .album:
                    return self.runAppleScript("tell application \"Spotify\" to return album of current track")
                        .map { L("Bu şarkı \($0 ?? "") albümünden", "This song is from \($0 ?? "")") }
                case .timeLeft:
                    return self.runAppleScript("tell application \"Spotify\" to return ((duration of current track) / 1000 - player position) as integer")
                        .map { L("Şarkının bitmesine \(Self.spokenDuration(Int($0 ?? "") ?? 0)) var", "\(Self.spokenDuration(Int($0 ?? "") ?? 0)) left in the song") }
                case .device, .nextUp:
                    return .failure(.other(errorNumber: 0, message: SpotifyWebAPI.SpotifyAPIError.notConnected.userMessage))
                }
            }
        )
    }
}
