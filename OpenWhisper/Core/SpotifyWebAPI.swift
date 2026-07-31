import Foundation
import Security
import Network
import AppKit

/// Keychain-backed storage for the user's Spotify Client ID/Secret and (once the user
/// connects their account) their OAuth refresh token. Never touches UserDefaults,
/// Info.plist, or any file on disk — everything here lives only in the macOS Keychain
/// (`kSecClassGenericPassword`), which is the one place appropriate for secrets.
enum SpotifyCredentialsStore {

    struct Credentials {
        let clientID: String
        let clientSecret: String
    }

    private static let service = "com.openwhisper.app.spotify"
    private static let clientIDAccount = "client_id"
    private static let clientSecretAccount = "client_secret"
    private static let refreshTokenAccount = "refresh_token"

    /// Loads both values from the Keychain. Returns nil if either is missing.
    static func load() -> Credentials? {
        guard let id = readString(account: clientIDAccount),
              let secret = readString(account: clientSecretAccount),
              !id.isEmpty, !secret.isEmpty else {
            return nil
        }
        return Credentials(clientID: id, clientSecret: secret)
    }

    /// Reads just the Client ID, for populating the Settings text field on appear.
    static func loadClientID() -> String {
        readString(account: clientIDAccount) ?? ""
    }

    /// Returns whether a client secret is currently stored, without exposing its value.
    static func hasClientSecret() -> Bool {
        readString(account: clientSecretAccount)?.isEmpty == false
    }

    /// Returns whether both values were actually persisted. The caller must surface a
    /// failure here — a silent no-op would leave the user thinking credentials are saved
    /// when they aren't, and every later command would fail with a confusing
    /// "missing credentials" message instead of the real cause.
    @discardableResult
    static func save(clientID: String, clientSecret: String) -> Bool {
        let idOK = writeString(clientID, account: clientIDAccount)
        let secretOK = writeString(clientSecret, account: clientSecretAccount)
        Task { await SpotifyWebAPI.shared.invalidateAllCaches() }
        return idOK && secretOK
    }

    static func clear() {
        deleteItem(account: clientIDAccount)
        deleteItem(account: clientSecretAccount)
        deleteItem(account: refreshTokenAccount)
        Task { await SpotifyWebAPI.shared.invalidateAllCaches() }
    }

    // MARK: - User account connection (refresh token)

    /// Whether the user has connected their Spotify account (Authorization Code flow).
    /// This is the source of truth the Settings UI shows "Bağlı" / "Bağlantı yok" from.
    static func hasRefreshToken() -> Bool {
        readString(account: refreshTokenAccount)?.isEmpty == false
    }

    static func loadRefreshToken() -> String? {
        let value = readString(account: refreshTokenAccount)
        return (value?.isEmpty == false) ? value : nil
    }

    @discardableResult
    static func saveRefreshToken(_ token: String) -> Bool {
        writeString(token, account: refreshTokenAccount)
    }

    /// Called when a refresh attempt comes back "invalid_grant" (token revoked/expired) —
    /// the connection is dead and the user needs to reconnect via Settings.
    static func clearRefreshToken() {
        deleteItem(account: refreshTokenAccount)
    }

    // MARK: - Keychain primitives

    private static func readString(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns whether the value was actually persisted (update or add succeeded).
    @discardableResult
    private static func writeString(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributesToUpdate: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)

        if updateStatus == errSecSuccess {
            return true
        }

        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Client for the Spotify Web API used for track search and (when the user has connected
/// their account) prioritizing their Liked Songs among search results. Playback itself is
/// always done locally via AppleScript in `SpotifyManager`; this type never touches
/// `/v1/me/player/*` — only `/v1/search` and `/v1/me/tracks/contains`, the latter guarded
/// by the read-only `user-library-read` scope.
///
/// Token strategy (no separate "search token" cache — one path per token kind):
/// - If the user has connected their account, their OAuth access token (refreshed via the
///   stored refresh token as needed) is used for search AND to check Liked Songs.
/// - Otherwise, or if anything about the user-token path fails for any reason, this falls
///   back to the app-only client-credentials token (search only, no liked-song info) —
///   today's original behavior.
/// - If even that fails (no app credentials, network down, etc.), the error propagates to
///   the caller (`SpotifyManager`), which has its own final fallback of opening the plain
///   `spotify:search:` screen. No layer in this chain is allowed to dead-end silently.
actor SpotifyWebAPI {

    static let shared = SpotifyWebAPI()

    private init() {}

    // MARK: - Errors

    enum SpotifyAPIError: Error {
        case missingCredentials
        case invalidCredentials      // 401 on token request — bad client ID/secret
        case rateLimited             // 429
        case network(Error)
        case noResults
        case notConnected            // no user refresh token stored
        case authorizationFailed(String)
        case alreadyInProgress       // a connect attempt is already waiting on the listener
        case unexpected(String)

        var userMessage: String {
            switch self {
            case .missingCredentials:
                return "Spotify Client ID/Secret girilmemiş, Ayarlar > Spotify'dan ekle"
            case .invalidCredentials:
                return "Spotify kimlik bilgileri hatalı"
            case .rateLimited:
                return "Spotify API çok fazla istek nedeniyle geçici olarak kısıtladı"
            case .network:
                return "Ağ hatası"
            case .noResults:
                return "Sonuç bulunamadı"
            case .notConnected:
                return "Bu komut için Ayarlar > Spotify'dan hesabını bağlaman gerekiyor"
            case .authorizationFailed(let detail):
                return "Bağlantı başarısız: \(detail)"
            case .alreadyInProgress:
                return "Zaten bir bağlantı denemesi sürüyor — tarayıcıda tamamlayın ya da birkaç dakika bekleyin"
            case .unexpected(let detail):
                return "Beklenmeyen hata: \(detail)"
            }
        }
    }

    struct TrackResult {
        let uri: String
        let name: String
        let artist: String
    }

    /// One search result plus its raw track ID — the ID (not the `spotify:track:` URI) is
    /// what `/v1/me/tracks/contains` requires.
    private struct SearchItem {
        let id: String
        let uri: String
        let name: String
        let artist: String
    }

    // MARK: - OAuth configuration

    /// Fixed loopback redirect URI. Spotify requires this to match the value registered
    /// in the app dashboard byte-for-byte (including the trailing path, no trailing
    /// slash difference) and, per current Spotify loopback rules, an explicit
    /// `127.0.0.1` rather than `localhost`. Shown (copyable) in Settings so the user can
    /// paste the exact same string into the dashboard.
    static let redirectURI = "http://127.0.0.1:8888/callback"
    private static let redirectPort: UInt16 = 8888
    private static let userScope = "user-library-read"
    /// 5 minutes: a user who doesn't already have a Spotify session in their default
    /// browser needs time to log in (plus 2FA) before consenting. The original 2-minute
    /// window was routinely too short for that and indistinguishable from every other
    /// silent failure mode on this path (see the `owLog` tracing added throughout this
    /// flow — dead air with no log line was the actual reported bug this fixes).
    private static let authorizationTimeout: TimeInterval = 300

    // MARK: - Token cache

    private struct CachedToken {
        let value: String
        let expiresAt: Date
    }

    /// True while `connectUserAccount()` has a listener bound to `redirectPort`. Settings
    /// is a MenuBarExtra popover (`.menuBarExtraStyle(.window)`): opening the system
    /// browser via `NSWorkspace.shared.open` steals focus and closes it, which resets its
    /// `@State` — so on reopen the button reads "Spotify hesabını bağla" again even while
    /// the original attempt is still waiting on its listener. Without this guard, tapping
    /// it again would start a second `NWListener` on the same port and both would fail
    /// with a confusing "port meşgul" error caused by nothing the user did wrong.
    private var isConnecting = false

    private var cachedClientCredentialsToken: CachedToken?
    private var inFlightClientCredentialsTask: Task<String, Error>?

    private var cachedUserToken: CachedToken?
    private var inFlightUserTokenTask: Task<String, Error>?

    private let requestTimeout: TimeInterval = 8

    // MARK: - Public API — Search

    /// Searches for a track and returns the best result. Throws `SpotifyAPIError` with a
    /// user-presentable reason only when NO path could produce a result at all (see the
    /// type-level doc comment for the fallback chain).
    func searchTopTrack(query: String) async throws -> TrackResult {
        // 1. Preferred path: user's own token, search + Liked Songs prioritization.
        if let userToken = await validUserAccessToken() {
            do {
                return try await searchWithLikedPriority(query: query, token: userToken)
            } catch SpotifyAPIError.noResults {
                // A genuinely empty result isn't going to become non-empty by retrying
                // with a different (less-privileged) token — surface it directly instead
                // of doing the same search again over client-credentials.
                throw SpotifyAPIError.noResults
            } catch {
                // Anything else on the user-token path (network hiccup, unexpected API
                // shape, expired-mid-flight token, etc.) — fall through to client
                // credentials rather than failing the whole command. The user's
                // connection itself isn't necessarily broken.
            }
        }

        // 2. Fallback: app-only client-credentials token, plain top result (no liked info).
        let ccToken = try await validClientCredentialsToken()
        let items = try await performSearch(query: query, token: ccToken, limit: 1)
        guard let first = items.first else { throw SpotifyAPIError.noResults }
        return TrackResult(uri: first.uri, name: first.name, artist: first.artist)
    }

    /// Fetches a fresh app token purely to validate stored client ID/Secret (used by the
    /// Settings "Bağlantıyı test et" button for the search credentials).
    func testConnection() async throws {
        _ = try await validClientCredentialsToken()
    }

    /// Fetches up to 50 of the user's Liked Songs and returns one at random (chosen
    /// client-side, not via the API — there is no "random saved track" endpoint). Random
    /// selection also means a rejected/unsupported playback context (see
    /// `SpotifyManager.playLikedTrack`) still results in a different song each time the
    /// command is used, rather than always the same most-recently-liked track.
    ///
    /// Requires the user's own token — this is `/v1/me/tracks`, `user-library-read` scope,
    /// which a client-credentials (app-only) token cannot access at all. Throws
    /// `.notConnected` immediately rather than attempting the request and getting a
    /// confusing 401 back.
    func fetchRandomLikedTrack() async throws -> TrackResult {
        guard let token = await validUserAccessToken() else {
            throw SpotifyAPIError.notConnected
        }

        var components = URLComponents(string: "https://api.spotify.com/v1/me/tracks")!
        components.queryItems = [URLQueryItem(name: "limit", value: "50")]
        guard let url = components.url else {
            throw SpotifyAPIError.unexpected("invalid liked tracks URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyAPIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SpotifyAPIError.unexpected("no HTTP response")
        }

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw SpotifyAPIError.invalidCredentials
        case 429:
            throw SpotifyAPIError.rateLimited
        default:
            throw SpotifyAPIError.unexpected("liked tracks HTTP \(http.statusCode)")
        }

        // Each item is a SavedTrackObject: { "added_at": ..., "track": { "id", "uri",
        // "name", "artists": [...] } } — the track fields are nested one level deeper
        // than in a /v1/search response.
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawItems = json["items"] as? [[String: Any]]
        else {
            throw SpotifyAPIError.unexpected("malformed liked tracks response")
        }

        let tracks: [SearchItem] = rawItems.compactMap { item in
            guard let track = item["track"] as? [String: Any],
                  let id = track["id"] as? String,
                  let uri = track["uri"] as? String,
                  let name = track["name"] as? String else { return nil }
            let artists = track["artists"] as? [[String: Any]]
            let artist = (artists?.first?["name"] as? String) ?? ""
            return SearchItem(id: id, uri: uri, name: name, artist: artist)
        }

        guard let chosen = tracks.randomElement() else {
            throw SpotifyAPIError.noResults
        }
        return TrackResult(uri: chosen.uri, name: chosen.name, artist: chosen.artist)
    }

    /// Clears every cached token (app + user), e.g. after the user edits stored
    /// credentials. Does NOT remove the stored refresh token — that's a separate, explicit
    /// disconnect action.
    func invalidateAllCaches() {
        cachedClientCredentialsToken = nil
        inFlightClientCredentialsTask?.cancel()
        inFlightClientCredentialsTask = nil

        cachedUserToken = nil
        inFlightUserTokenTask?.cancel()
        inFlightUserTokenTask = nil
    }

    // MARK: - Public API — Account connection (Authorization Code flow)

    /// Runs the full "connect my Spotify account" flow: opens the system browser to
    /// Spotify's consent screen, listens on the fixed loopback redirect for the resulting
    /// authorization code, exchanges it for tokens, and stores the refresh token in the
    /// Keychain. Throws on any failure (missing app credentials, user denied consent,
    /// state mismatch, network error, timeout) — the caller (Settings) is expected to
    /// show `error.userMessage`.
    func connectUserAccount() async throws {
        // Settings is a MenuBarExtra popover that closes (and resets its @State) the
        // instant the browser takes focus below — see `isConnecting`'s doc comment. This
        // guard is what actually prevents the resulting double-listener-on-8888 failure,
        // independent of whatever the (possibly already-dismissed) UI shows.
        guard !isConnecting else {
            owLog("[Spotify OAuth] connect: zaten sürüyor, ikinci deneme reddedildi")
            throw SpotifyAPIError.alreadyInProgress
        }
        isConnecting = true
        defer { isConnecting = false }

        guard let credentials = SpotifyCredentialsStore.load() else {
            owLog("[Spotify OAuth] connect: Client ID/Secret kayıtlı değil, akış başlatılamadı")
            throw SpotifyAPIError.missingCredentials
        }

        let expectedState = UUID().uuidString

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.userScope),
            URLQueryItem(name: "state", value: expectedState)
        ]
        guard let authURL = components.url else {
            owLog("[Spotify OAuth] connect: authorize URL oluşturulamadı")
            throw SpotifyAPIError.unexpected("invalid authorize URL")
        }

        owLog("[Spotify OAuth] connect: akış başlatılıyor, yerel dinleyici kuruluyor")

        // Start the local listener first so it's already bound by the time the browser
        // redirects back to it. This is a structured child task (async let), so if the
        // caller cancels the outer Task (e.g. the user taps "İptal" in Settings), that
        // cancellation propagates here automatically and unwinds the listener too.
        async let codeTask = Self.captureAuthorizationCode(expectedState: expectedState)
        try? await Task.sleep(nanoseconds: 200_000_000)

        owLog("[Spotify OAuth] connect: authorize URL tarayıcıda açılıyor")
        NSWorkspace.shared.open(authURL)

        let code: String
        do {
            code = try await codeTask
        } catch is CancellationError {
            owLog("[Spotify OAuth] connect: kullanıcı tarafından iptal edildi")
            throw CancellationError()
        } catch let error as SpotifyAPIError {
            owLog("[Spotify OAuth] connect: authorization code alınamadı — \(error)")
            throw error
        }

        owLog("[Spotify OAuth] connect: authorization code alındı, token değişimi başlıyor")
        do {
            try await exchangeCodeForTokens(code: code, clientID: credentials.clientID, clientSecret: credentials.clientSecret)
            owLog("[Spotify OAuth] connect: bağlantı başarılı")
        } catch {
            owLog("[Spotify OAuth] connect: token değişimi başarısız")
            throw error
        }
    }

    /// Disconnects the user's account: clears the cached user token and removes the
    /// stored refresh token. Search immediately falls back to client-credentials.
    func disconnectUserAccount() {
        cachedUserToken = nil
        inFlightUserTokenTask?.cancel()
        inFlightUserTokenTask = nil
        SpotifyCredentialsStore.clearRefreshToken()
    }

    // MARK: - Search + Liked Songs prioritization

    /// Searches with the user's token (top 10 candidates) and, among those, plays whichever
    /// one is highest-ranked AND in the user's Liked Songs — e.g. preferring a saved studio
    /// version over an unsaved live/remaster that happens to rank first. Falls back to the
    /// plain top result if none of the candidates are liked, or if the Liked-Songs check
    /// itself fails for any reason (best-effort layer, never blocks the search).
    private func searchWithLikedPriority(query: String, token: String) async throws -> TrackResult {
        let items = try await performSearch(query: query, token: token, limit: 10)
        guard let first = items.first else { throw SpotifyAPIError.noResults }

        if items.count > 1, let likedIndex = await firstLikedIndex(items: items, token: token) {
            let liked = items[likedIndex]
            return TrackResult(uri: liked.uri, name: liked.name, artist: liked.artist)
        }

        return TrackResult(uri: first.uri, name: first.name, artist: first.artist)
    }

    /// Returns the index of the first (highest-ranked) item the user has saved to Liked
    /// Songs, or nil if none are saved or the check couldn't be completed. Never throws —
    /// this is a "nice to have" ranking signal, not something that should fail a search.
    private func firstLikedIndex(items: [SearchItem], token: String) async -> Int? {
        // /v1/me/tracks/contains allows up to 50 IDs per call; our candidate list (limit
        // 10) is always well under that, so a single request suffices.
        var components = URLComponents(string: "https://api.spotify.com/v1/me/tracks/contains")!
        components.queryItems = [URLQueryItem(name: "ids", value: items.map(\.id).joined(separator: ","))]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse,
            http.statusCode == 200,
            let flags = try? JSONSerialization.jsonObject(with: data) as? [Bool]
        else {
            return nil
        }

        return flags.firstIndex(of: true)
    }

    private func performSearch(query: String, token: String, limit: Int) async throws -> [SearchItem] {
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "market", value: "TR")
        ]
        guard let url = components.url else {
            throw SpotifyAPIError.unexpected("invalid search URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = requestTimeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyAPIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SpotifyAPIError.unexpected("no HTTP response")
        }

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw SpotifyAPIError.invalidCredentials
        case 429:
            throw SpotifyAPIError.rateLimited
        default:
            throw SpotifyAPIError.unexpected("search HTTP \(http.statusCode)")
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tracksObj = json["tracks"] as? [String: Any],
            let rawItems = tracksObj["items"] as? [[String: Any]]
        else {
            throw SpotifyAPIError.noResults
        }

        let items: [SearchItem] = rawItems.compactMap { item in
            guard let id = item["id"] as? String,
                  let uri = item["uri"] as? String,
                  let name = item["name"] as? String else { return nil }
            let artists = item["artists"] as? [[String: Any]]
            let artist = (artists?.first?["name"] as? String) ?? ""
            return SearchItem(id: id, uri: uri, name: name, artist: artist)
        }

        guard !items.isEmpty else { throw SpotifyAPIError.noResults }
        return items
    }

    // MARK: - Client-credentials token acquisition (app-level, no user context)

    private func validClientCredentialsToken() async throws -> String {
        if let cached = cachedClientCredentialsToken, cached.expiresAt > Date() {
            return cached.value
        }

        if let existing = inFlightClientCredentialsTask {
            return try await existing.value
        }

        let task = Task<String, Error> {
            try await fetchNewClientCredentialsToken()
        }
        inFlightClientCredentialsTask = task

        do {
            let token = try await task.value
            inFlightClientCredentialsTask = nil
            return token
        } catch {
            inFlightClientCredentialsTask = nil
            throw error
        }
    }

    private func fetchNewClientCredentialsToken() async throws -> String {
        guard let credentials = SpotifyCredentialsStore.load() else {
            throw SpotifyAPIError.missingCredentials
        }

        var request = tokenRequest(clientID: credentials.clientID, clientSecret: credentials.clientSecret)
        request.httpBody = "grant_type=client_credentials".data(using: .utf8)

        let (data, http) = try await sendTokenRequest(request)

        switch http.statusCode {
        case 200:
            break
        case 400, 401:
            throw SpotifyAPIError.invalidCredentials
        case 429:
            throw SpotifyAPIError.rateLimited
        default:
            throw SpotifyAPIError.unexpected("token HTTP \(http.statusCode)")
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = json["access_token"] as? String,
            let expiresIn = json["expires_in"] as? Int
        else {
            throw SpotifyAPIError.unexpected("malformed token response")
        }

        // Refresh a bit early (60s margin) so we never race a request against expiry.
        let expiresAt = Date().addingTimeInterval(TimeInterval(max(expiresIn - 60, 30)))
        cachedClientCredentialsToken = CachedToken(value: accessToken, expiresAt: expiresAt)
        return accessToken
    }

    // MARK: - User token acquisition (Authorization Code + refresh)

    /// Returns a valid user access token, refreshing via the stored refresh token if
    /// needed — or nil if the user isn't connected, or the refresh fails for any reason
    /// (including a rejected/revoked refresh token, in which case the stored refresh
    /// token is cleared so Settings shows "yeniden bağlan"). Never throws: this is the
    /// entry point `searchTopTrack` uses to decide whether to even attempt the user path,
    /// and a failure here should silently mean "fall back to client credentials".
    private func validUserAccessToken() async -> String? {
        if let cached = cachedUserToken, cached.expiresAt > Date() {
            return cached.value
        }

        guard let credentials = SpotifyCredentialsStore.load(),
              let refreshToken = SpotifyCredentialsStore.loadRefreshToken() else {
            return nil
        }

        if let existing = inFlightUserTokenTask {
            return try? await existing.value
        }

        let task = Task<String, Error> {
            try await self.refreshUserToken(refreshToken: refreshToken, clientID: credentials.clientID, clientSecret: credentials.clientSecret)
        }
        inFlightUserTokenTask = task

        let token = try? await task.value
        inFlightUserTokenTask = nil
        return token
    }

    private func refreshUserToken(refreshToken: String, clientID: String, clientSecret: String) async throws -> String {
        var request = tokenRequest(clientID: clientID, clientSecret: clientSecret)
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken)
        ]
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

        let (data, http) = try await sendTokenRequest(request)

        switch http.statusCode {
        case 200:
            break
        case 400, 401:
            // invalid_grant: the refresh token was revoked or expired. The connection is
            // dead — clear it so Settings reflects reality and the user can reconnect.
            SpotifyCredentialsStore.clearRefreshToken()
            throw SpotifyAPIError.invalidCredentials
        case 429:
            throw SpotifyAPIError.rateLimited
        default:
            throw SpotifyAPIError.unexpected("refresh HTTP \(http.statusCode)")
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = json["access_token"] as? String,
            let expiresIn = json["expires_in"] as? Int
        else {
            throw SpotifyAPIError.unexpected("malformed refresh response")
        }

        // A new refresh token isn't always returned — keep the existing one when omitted.
        // If Spotify DID rotate it and the Keychain write fails, don't fail this refresh
        // (the access token we just got is still good for ~1 hour) — but log it, since the
        // stale refresh token left in the Keychain will fail at the *next* refresh instead.
        if let newRefreshToken = json["refresh_token"] as? String,
           !SpotifyCredentialsStore.saveRefreshToken(newRefreshToken) {
            owLog("[Spotify] Failed to persist rotated refresh token to Keychain")
        }

        let expiresAt = Date().addingTimeInterval(TimeInterval(max(expiresIn - 60, 30)))
        cachedUserToken = CachedToken(value: accessToken, expiresAt: expiresAt)
        return accessToken
    }

    private func exchangeCodeForTokens(code: String, clientID: String, clientSecret: String) async throws {
        var request = tokenRequest(clientID: clientID, clientSecret: clientSecret)
        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI)
        ]
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

        let (data, http) = try await sendTokenRequest(request)
        owLog("[Spotify OAuth] token exchange HTTP \(http.statusCode)")

        switch http.statusCode {
        case 200:
            break
        case 400, 401:
            // Most common real-world cause: the redirect URI registered in the Spotify
            // Dashboard doesn't byte-for-byte match `redirectURI` above.
            throw SpotifyAPIError.authorizationFailed("kimlik bilgileri veya redirect URI hatalı (Dashboard'daki Redirect URI birebir eşleşmiyor olabilir)")
        case 429:
            throw SpotifyAPIError.rateLimited
        default:
            throw SpotifyAPIError.unexpected("token exchange HTTP \(http.statusCode)")
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = json["access_token"] as? String,
            let expiresIn = json["expires_in"] as? Int,
            let refreshToken = json["refresh_token"] as? String
        else {
            throw SpotifyAPIError.unexpected("malformed token response")
        }

        // A failed Keychain write here must not look like success: the in-memory access
        // token would work for ~1 hour and then the connection would silently vanish on
        // the next refresh (or the next app launch) with no error anywhere. Surface it now.
        guard SpotifyCredentialsStore.saveRefreshToken(refreshToken) else {
            throw SpotifyAPIError.unexpected("refresh token Keychain'e yazılamadı")
        }

        let expiresAt = Date().addingTimeInterval(TimeInterval(max(expiresIn - 60, 30)))
        cachedUserToken = CachedToken(value: accessToken, expiresAt: expiresAt)
    }

    // MARK: - Shared token-request plumbing

    private func tokenRequest(clientID: String, clientSecret: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        let authString = "\(clientID):\(clientSecret)"
        let basicAuth = Data(authString.utf8).base64EncodedString()
        request.setValue("Basic \(basicAuth)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestTimeout
        return request
    }

    private func sendTokenRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SpotifyAPIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SpotifyAPIError.unexpected("no HTTP response")
        }
        return (data, http)
    }

    // MARK: - Local loopback listener (captures the OAuth redirect)

    /// Starts a one-shot HTTP listener on `127.0.0.1:8888`, waits for Spotify's redirect
    /// carrying `?code=...&state=...`, validates `state`, replies with a minimal "you can
    /// close this window" page, and returns the authorization code.
    ///
    /// Every meaningful transition here is `owLog`ged (listener bound / browser opened /
    /// callback received / outcome) — without that, a bind failure (port already held by
    /// a leftover listener from a previous attempt), a user tapping "Cancel" on Spotify's
    /// consent screen, and an honest 5-minute wait for 2FA were all completely
    /// indistinguishable: all three produced total silence followed by the same generic
    /// timeout message. Never logs the authorization code, `state` value, or any token.
    ///
    /// `.failed`/`.waiting` on the listener are treated as immediate, distinct failures —
    /// most commonly a leftover listener from an earlier attempt still holding the port —
    /// rather than being left to run out the clock alongside every other silent failure.
    /// Cancellable: cancelling the enclosing `Task` (e.g. the user tapping "İptal" in
    /// Settings) tears down the listener and resumes with `CancellationError` instead of
    /// leaking a bound socket for the remainder of the timeout window.
    private static func captureAuthorizationCode(expectedState: String) async throws -> String {
        let box = OAuthCaptureBox()
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    box.setContinuation(continuation)
                    let resume = { (result: Result<String, Error>) in box.resume(result) }

                    guard let port = NWEndpoint.Port(rawValue: redirectPort) else {
                        resume(.failure(SpotifyAPIError.unexpected("invalid redirect port")))
                        return
                    }

                    // Plain TCP listener on the fixed port; NWListener binds all local
                    // interfaces (including loopback) by default, which matches
                    // http://127.0.0.1:8888 fine — `requiredLocalEndpoint` is for outbound
                    // connections, not listeners, and setting it here would only risk a
                    // spurious bind failure.
                    guard let listener = try? NWListener(using: .tcp, on: port) else {
                        owLog("[Spotify OAuth] listener: NWListener oluşturulamadı")
                        resume(.failure(SpotifyAPIError.unexpected("127.0.0.1:8888 dinlenemedi — port meşgul olabilir")))
                        return
                    }
                    box.setListener(listener)

                    let timeoutTask = Task {
                        try? await Task.sleep(nanoseconds: UInt64(authorizationTimeout * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        owLog("[Spotify OAuth] listener: zaman aşımı (\(Int(authorizationTimeout))s), callback gelmedi")
                        listener.cancel()
                        resume(.failure(SpotifyAPIError.authorizationFailed(
                            "zaman aşımı — tarayıcıda Spotify girişi/onayı tamamlanmadı. En olası neden: " +
                            "\(redirectURI) adresi Spotify Dashboard > Settings > Redirect URIs listesine " +
                            "birebir eklenmemiş (bu durumda tarayıcı \"INVALID_CLIENT: Invalid redirect URI\" gösterir " +
                            "ve bu uygulamaya hiç geri dönmez)."
                        )))
                    }
                    box.setTimeoutTask(timeoutTask)

                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            owLog("[Spotify OAuth] listener: 127.0.0.1:8888 üzerinde hazır, callback bekleniyor")
                        case .waiting(let error):
                            // NWListener enters .waiting (rather than .failed) for a bind
                            // it can't currently satisfy — most commonly the port already
                            // held by a leftover listener from a previous attempt. Report
                            // immediately rather than let this sit until the timeout.
                            owLog("[Spotify OAuth] listener: waiting (\(error.localizedDescription)) — port muhtemelen meşgul")
                            timeoutTask.cancel()
                            listener.cancel()
                            resume(.failure(SpotifyAPIError.unexpected("127.0.0.1:8888 dinlenemedi — port meşgul olabilir (önceki bir bağlantı denemesi hâlâ açık olabilir, uygulamayı yeniden başlatmayı deneyin)")))
                        case .failed(let error):
                            owLog("[Spotify OAuth] listener: failed (\(error.localizedDescription))")
                            timeoutTask.cancel()
                            listener.cancel()
                            resume(.failure(SpotifyAPIError.unexpected("127.0.0.1:8888 dinlenemedi — port meşgul olabilir")))
                        default:
                            break
                        }
                    }

                    listener.newConnectionHandler = { connection in
                        owLog("[Spotify OAuth] listener: callback bağlantısı alındı")
                        box.setConnection(connection)
                        connection.start(queue: .main)
                        receiveHTTPRequestLine(on: connection) { requestLine in
                            listener.cancel()
                            timeoutTask.cancel()

                            guard let requestLine,
                                  let path = requestLine.split(separator: " ", maxSplits: 2).dropFirst().first,
                                  let url = URL(string: "http://127.0.0.1\(path)"),
                                  let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                                owLog("[Spotify OAuth] callback: istek ayrıştırılamadı")
                                resume(.failure(SpotifyAPIError.unexpected("redirect isteği ayrıştırılamadı")))
                                return
                            }

                            let params = urlComponents.queryItems ?? []
                            if let deniedReason = params.first(where: { $0.name == "error" })?.value {
                                let description = params.first(where: { $0.name == "error_description" })?.value
                                owLog("[Spotify OAuth] callback: Spotify 'error=\(deniedReason)' döndürdü")
                                resume(.failure(SpotifyAPIError.authorizationFailed(friendlyAuthorizeError(code: deniedReason, description: description))))
                                return
                            }
                            guard let state = params.first(where: { $0.name == "state" })?.value, state == expectedState else {
                                owLog("[Spotify OAuth] callback: state uyuşmuyor")
                                resume(.failure(SpotifyAPIError.authorizationFailed("state uyuşmuyor")))
                                return
                            }
                            guard let code = params.first(where: { $0.name == "code" })?.value else {
                                owLog("[Spotify OAuth] callback: code parametresi eksik")
                                resume(.failure(SpotifyAPIError.authorizationFailed("code parametresi eksik")))
                                return
                            }
                            owLog("[Spotify OAuth] callback: authorization code alındı")
                            resume(.success(code))
                        }
                    }

                    listener.start(queue: .main)
                }
            },
            onCancel: {
                owLog("[Spotify OAuth] connect: iptal edildi, dinleyici kapatılıyor")
                box.cancelAll()
                box.resume(.failure(CancellationError()))
            }
        )
    }

    /// Turns Spotify's `error` (and optional `error_description`) redirect parameters
    /// into a message the user can actually act on. `access_denied` and `server_error`
    /// have specific, common, fixable causes worth naming explicitly rather than just
    /// echoing Spotify's machine-readable code back at the user.
    private static func friendlyAuthorizeError(code: String, description: String?) -> String {
        let detail = description.map { " (\($0))" } ?? ""
        switch code {
        case "access_denied":
            return "Spotify izni reddedildi — onay ekranında \"İzin Ver\" yerine \"İptal\" seçilmiş olabilir\(detail)"
        case "server_error":
            return "Spotify sunucu hatası döndürdü\(detail) — Dashboard'da uygulamanın \"User Management\" listesine bu Spotify hesabını eklediğinizden (Development Mode'da API erişimi sadece izinli hesaplarla çalışır) ve Web API erişiminin açık olduğundan emin olun"
        case "invalid_scope":
            return "İstenen izin (user-library-read) reddedildi\(detail)"
        case "temporarily_unavailable":
            return "Spotify şu anda geçici olarak erişilemez durumda\(detail) — birazdan tekrar deneyin"
        default:
            return "\(code)\(detail)"
        }
    }

    private static func receiveHTTPRequestLine(on connection: NWConnection, completion: @escaping (String?) -> Void) {
        var buffer = Data()
        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    buffer.append(data)
                }
                if let text = String(data: buffer, encoding: .utf8),
                   text.contains("\r\n\r\n") || text.contains("\n\n") {
                    let firstLine = text.components(separatedBy: "\n").first?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    sendClosePage(on: connection)
                    completion(firstLine)
                    return
                }
                if isComplete || error != nil || buffer.count > 16384 {
                    sendClosePage(on: connection)
                    completion(nil)
                    return
                }
                receiveMore()
            }
        }
        receiveMore()
    }

    private static func sendClosePage(on connection: NWConnection) {
        let body = "<html><body><p>OpenWhisper: Spotify bağlantısı tamamlandı, bu pencereyi kapatabilirsiniz.</p></body></html>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Resumes a `CheckedContinuation` at most once, safely from multiple concurrent
/// callers (the listener's timeout task, its state handler, and its connection handler
/// can all race to be the one that finishes the OAuth redirect capture). The lock makes
/// this safely `@unchecked Sendable`: all mutable state is only ever touched while held.
private final class OAuthCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private var continuation: CheckedContinuation<String, Error>?
    private var listener: NWListener?
    private var timeoutTask: Task<Void, Never>?
    /// Strong reference to the accepted redirect connection, held for the same reason as
    /// `listener` below: nothing else in the process keeps it alive once the synchronous
    /// setup closure that created it returns, and letting it deallocate mid-read would
    /// silently drop the callback.
    private var connection: NWConnection?
    /// Holds a result that arrived (e.g. via `onCancel`, which `withTaskCancellationHandler`
    /// may invoke concurrently with — or even fractionally before — the operation closure
    /// that calls `setContinuation`) before the continuation itself was set. Delivered as
    /// soon as `setContinuation` runs, instead of being silently dropped.
    private var pendingResult: Result<String, Error>?

    /// Set once, right after the continuation is created — needed so `onCancel` (which
    /// fires on a different, arbitrary queue/thread than the continuation body) can also
    /// resume it.
    func setContinuation(_ continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        if let pending = pendingResult {
            pendingResult = nil
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setListener(_ listener: NWListener) {
        lock.lock()
        self.listener = listener
        lock.unlock()
    }

    /// Retains only the first accepted connection. A browser can open more than one
    /// connection to the same URL (preconnect, a favicon fetch, etc.) — overwriting on a
    /// later call would drop the strong reference this exists to provide for whichever
    /// connection is actually mid-read.
    func setConnection(_ connection: NWConnection) {
        lock.lock()
        if self.connection == nil {
            self.connection = connection
        }
        lock.unlock()
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        self.timeoutTask = task
        lock.unlock()
    }

    /// Tears down the listener and timeout timer without resuming — used from
    /// `onCancel`, which resumes separately via `resume(.failure(CancellationError()))`.
    func cancelAll() {
        lock.lock()
        let listenerToCancel = listener
        let taskToCancel = timeoutTask
        lock.unlock()
        listenerToCancel?.cancel()
        taskToCancel?.cancel()
    }

    /// Resumes the continuation at most once, safely from multiple concurrent callers
    /// (the listener's timeout task, its state handler, its connection handler, and
    /// `withTaskCancellationHandler`'s `onCancel` can all race to be the one that
    /// finishes the OAuth redirect capture). The lock makes this safely
    /// `@unchecked Sendable`: all mutable state is only ever touched while held.
    func resume(_ result: Result<String, Error>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        guard let continuation else {
            // Continuation isn't set yet (see `pendingResult` doc comment) — stash it
            // rather than dropping it; `setContinuation` delivers it immediately.
            pendingResult = result
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
