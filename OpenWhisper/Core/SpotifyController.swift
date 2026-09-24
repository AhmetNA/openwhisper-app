import Foundation
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
                return "Müzik oynatılıyor"
            },
            appleScript: { self.runSpotifyCommand("play").map { _ in "Müzik oynatılıyor" } }
        )
    }

    func pause() async -> SpotifyActionResult {
        await perform(
            "Durdurma",
            web: {
                try await SpotifyWebAPI.shared.pausePlayback()
                return "Müzik durduruldu"
            },
            appleScript: { self.runSpotifyCommand("pause").map { _ in "Müzik durduruldu" } }
        )
    }

    func nextTrack() async -> SpotifyActionResult {
        await perform(
            "Sonraki şarkı",
            web: {
                try await SpotifyWebAPI.shared.skipToNext()
                return "Sonraki şarkıya geçildi"
            },
            appleScript: { self.runSpotifyCommand("next track").map { _ in "Sonraki şarkıya geçildi" } }
        )
    }

    func previousTrack() async -> SpotifyActionResult {
        await perform(
            "Önceki şarkı",
            web: {
                try await SpotifyWebAPI.shared.skipToPrevious()
                return "Önceki şarkıya geçildi"
            },
            appleScript: { self.runSpotifyCommand("previous track").map { _ in "Önceki şarkıya geçildi" } }
        )
    }

    func setVolume(_ volume: Int) async -> SpotifyActionResult {
        guard (0...100).contains(volume) else {
            return .failure("Geçersiz ses seviyesi: 0-100 arası olmalı")
        }
        return await perform(
            "Ses ayarı",
            web: {
                try await SpotifyWebAPI.shared.setVolume(volume)
                return "Spotify sesi %\(volume) yapıldı"
            },
            appleScript: {
                self.runSpotifyCommand("set sound volume to \(volume)").map { _ in "Spotify sesi %\(volume) yapıldı" }
            }
        )
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
        return "\(isPlaying ? "Çalıyor" : "Duraklatıldı"): ♪ \(label)\(albumPart)"
    }

    // MARK: - Search & play

    /// Resolves `request` in its catalog (song, artist, album or playlist) and plays the
    /// best match, trying its queries from most to least specific. An artist, album or
    /// playlist that can't be found falls back to a song search of the whole request.
    /// When nothing can be played, opens Spotify's own search (or item) screen instead of
    /// starting whatever happens to be queued — never plays something unrelated.
    func searchAndPlay(_ request: SpotifySearchRequest) async -> SpotifyActionResult {
        let queries = request.searchQueries
        guard !queries.isEmpty else {
            return .failure("Arama sorgusu boş olamaz")
        }

        // "Spotify'da Tarkan çal": the words alone can't say whether "Tarkan" is an artist
        // or a song. If Spotify has an artist with exactly that name, play the artist.
        if request.kind == .freeText,
           let artist = try? await SpotifyWebAPI.shared.searchTopItem(query: request.freeText, type: .artist),
           SpotifyRequestParser.foldedWords(artist.name) == SpotifyRequestParser.foldedWords(request.freeText) {
            owLog("[SpotifyController] '\(request.freeText)' is an artist name → artist context")
            let result = await playContext(artist, type: .artist)
            if result.succeeded { return result }
        }

        var type = request.catalogType
        var item = await firstSearchHit(queries: queries, type: type)
        if item == nil, type != .track, !request.freeText.isEmpty {
            type = .track
            item = await firstSearchHit(queries: [request.freeText], type: .track)
        }

        guard let item else {
            let shown = request.displayText.isEmpty ? queries[queries.count - 1] : request.displayText
            return openInSpotify(
                "spotify:search:\(shown)",
                message: "Otomatik çalma yapılamadı. \"\(shown)\" için arama ekranı açıldı."
            )
        }

        let result = type == .track ? await playTrack(item) : await playContext(item, type: type)
        if result.succeeded {
            return result
        }
        return openInSpotify(
            item.uri,
            message: "\(result.message). Spotify'da açıldı: \(Self.label(for: item))"
        )
    }

    /// First result across `queries`. Stops early on errors other than "no results":
    /// credentials or network problems won't be fixed by a different query string.
    private func firstSearchHit(queries: [String], type: SpotifyWebAPI.SearchType) async -> SpotifyWebAPI.TrackResult? {
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
            return .failure("Geçersiz Spotify şarkı adresi")
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
            return "Sıraya eklendi, önünde \(ahead) şarkı var: \(message)"
        }
    }

    private func queuePosition(of uri: String) async -> Int? {
        (try? await SpotifyWebAPI.shared.fetchQueueURIs())?.firstIndex(of: uri)
    }

    /// Plays an artist, album or playlist as a context, so Spotify keeps going through it.
    func playContext(_ item: SpotifyWebAPI.TrackResult, type: SpotifyWebAPI.SearchType) async -> SpotifyActionResult {
        guard Self.isValidContextURI(item.uri) else {
            return .failure("Geçersiz Spotify adresi")
        }
        let message: String
        switch type {
        case .artist: message = "♪ \(item.name) — popüler şarkılar"
        case .album: message = "💿 \(Self.label(for: item))"
        case .playlist, .track: message = "📃 \(item.name)"
        }
        return await perform(
            "Çalma",
            web: {
                try await self.withDeviceFallback {
                    try await SpotifyWebAPI.shared.startPlayback(contextURI: item.uri, deviceID: $0)
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
            return .failure("Spotify açılamadı")
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
            return .failure("Şu an çalan bir şarkı bulunamadı")
        }

        do {
            try await SpotifyWebAPI.shared.saveToLibrary(uri: trackURI)
            let name = trackName.map { "\"\($0)\"" } ?? "Çalan şarkı"
            return .success("\(name) Beğenilen Şarkılar'a eklendi ❤️")
        } catch {
            return .failure("Beğenilenlere eklenemedi: \(Self.reason(for: error))")
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
                    return .failure("\(action) başarısız: \(webFailure!)")
                }
            }
        } else if webAPIPlayerUnavailable, !readOnly {
            webFailure = SpotifyWebAPI.SpotifyAPIError.premiumRequired.userMessage
        }

        guard Self.appleScriptFallbackEnabled else {
            let reason = webFailure ?? SpotifyWebAPI.SpotifyAPIError.notConnected.userMessage
            return .failure("\(action) başarısız: \(reason)")
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
                return "Spotify kontrolü için izin gerekli — Sistem Ayarları > Gizlilik ve Güvenlik > Otomasyon > OpenWhisper > Spotify açık olmalı."
            case .appNotRunning:
                return "Spotify çalışmıyor görünüyor."
            case .other(let number, _):
                return "Spotify komutu başarısız oldu (\(number))."
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
