import Foundation
import AppKit
import UserNotifications

final class SpotifyManager: @unchecked Sendable {

    static let shared = SpotifyManager()

    private init() {}

    // MARK: - Shared Command Table
    //
    // NOTE: only the gate (`isSpotifyCommand`, via `hasCommandPrefix`) reads this table.
    // `handleCommand` routes through `explicitIntent(in:)`, which matches on its own `normalized.contains(...)`
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

    /// The only intents allowed to reach `SpotifyController`'s side effects. Keeping the
    /// recognition result structured prevents the handler from turning arbitrary residue
    /// into a search request when no real Spotify action was recognized.
    private enum ExplicitSpotifyIntent {
        case pause
        case play
        case next
        case previous
        case setVolume(Int)
        case currentTrack
        case search(SpotifySearchRequest)
        case likeCurrentTrack
    }

    private static let musicContextWords: Set<String> = [
        "müzik", "müziği", "müziğin", "müziğe", "muzik", "muzigi",
        "şarkı", "şarkıyı", "şarkıya", "şarkının", "şarkısını", "şarkılar", "şarkıları",
        "sarki", "sarkiyi", "sarkiya", "sarkisini", "sarkilar", "sarkilari",
        "parça", "parçayı", "parçaya", "parçasını", "parçalar", "parçaları",
        "parca", "parcayi", "parcaya", "parcasini", "parcalar", "parcalari",
        "playlist", "playlisti", "playlistini", "albüm", "albümü", "albümünü", "album",
        "beğenilenler", "beğendiklerim", "liked"
    ]

    private static let mentionOrNegationWords: Set<String> = [
        "istemiyorum", "istemem", "istemedim", "değil", "degil", "olmasın", "olmasin",
        "demiyorum", "demedim", "bahsediyorum", "bahsettim", "hakkında", "hakkinda",
        "kelimesi", "kelimesini", "komutu", "komutunu", "konuşalım", "konusalim",
        // "şey"/"şeyler" and ASCII "sakin" are deliberately absent: "sakin bir şeyler çal"
        // (play something calm) is a real request, and the prose they used to catch ("şarkı
        // aç gibi şeyler demiyorum") is still vetoed by "gibi"/"demiyorum".
        "sakın", "gibi", "dedi", "dedim", "demek", "diye"
    ]

    private static let commandTailWords: Set<String> = [
        "lütfen", "lutfen", "şimdi", "simdi", "hemen", "artık", "artik", "bakalım", "bakalim"
    ]

    /// Colloquial play verbs, mapped to the canonical verb the gate checks for.
    /// "koy" ("Tarkan koy") only ever counts next to a Spotify/music word, like every verb.
    static let playVerbAliases: [String: String] = [
        "çalsana": "çal", "calsana": "çal",
        "açsana": "aç", "acsana": "aç",
        "oynatsana": "oynat",
        "koy": "çal", "koysana": "çal",
        "dinleyelim": "dinlet", "dinletsene": "dinlet"
    ]

    /// "çalar mısın", "açabilir misin": these stems are verbs only when a question particle
    /// follows — alone, "müzik çalar" is the noun "music player", not a request.
    static let questionFormPlayVerbs: [String: String] = [
        "çalar": "çal", "calar": "çal", "çalabilir": "çal", "calabilir": "çal",
        "açar": "aç", "acar": "aç", "açabilir": "aç", "acabilir": "aç",
        "koyar": "çal", "koyabilir": "çal",
        "oynatır": "oynat", "oynatir": "oynat", "oynatabilir": "oynat"
    ]
    static let questionParticles: Set<String> = ["mısın", "misin", "musun", "müsün", "misiniz", "mısınız"]

    /// Rewrites colloquial verb forms to the canonical verbs below, so "Barış Manço
    /// çalsana" and "Tarkan'ı çalar mısın" are gated exactly like "... çal".
    private static func canonicalizeVerbs(_ words: [String]) -> [String] {
        var result: [String] = []
        var index = words.startIndex
        while index < words.endIndex {
            let word = words[index]
            let next = index + 1 < words.endIndex ? words[index + 1] : nil
            if let canonical = questionFormPlayVerbs[word], let next, questionParticles.contains(next) {
                result.append(canonical)
                index += 2
                continue
            }
            result.append(playVerbAliases[word] ?? word)
            index += 1
        }
        return result
    }

    /// Spoken words, with "çalar mısın"-style verb + particle pairs counted once.
    private static func spokenWordCount(_ normalized: String) -> Int {
        let spoken = normalized.split(whereSeparator: { $0.isWhitespace })
        return spoken.count - spoken.filter { questionParticles.contains(String($0)) }.count
    }

    /// Question particles that turn a leading "müzik dinleyelim" into a question about
    /// options ("müzik dinleyelim mi yoksa film mi") rather than a request.
    private static let yesNoParticles: Set<String> = ["mı", "mi", "mu", "mü", "yoksa"]

    /// Words allowed before a leading play verb in "Müzik çal Manga'nın We Could Be The
    /// Same": a music noun (required) plus optional filler.
    private static let leadingVerbPrefixFillers: Set<String> = ["hadi", "bana", "bir"]

    /// Verb-first form: "(hadi) müzik çal <query>". The verb must directly follow a prefix
    /// made only of music nouns and filler, with at least one music noun, and something
    /// must come after it. Without that prefix a leading verb is still rejected, so
    /// "çal bunu yarın konuşuruz"-style prose stays dictation.
    private static func hasLeadingVerb(_ verbs: Set<String>, in words: [String]) -> Bool {
        guard let verbIndex = words.firstIndex(where: verbs.contains),
              verbIndex > 0, verbIndex + 1 < words.count else { return false }
        guard yesNoParticles.isDisjoint(with: words[(verbIndex + 1)...]) else { return false }
        let prefix = words[..<verbIndex]
        return prefix.contains(where: musicContextWords.contains)
            && prefix.allSatisfy { musicContextWords.contains($0) || leadingVerbPrefixFillers.contains($0) }
    }

    /// Tokenizes punctuation as separators, which gives exact word-boundary behavior for
    /// cases such as `ses` versus `sesim` and `spotify'da` versus an unrelated substring.
    private static func intentWords(_ normalized: String) -> [String] {
        normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func addressesSpotify(_ text: String) -> Bool {
        intentWords(normalize(text)).contains(where: isSpotifyWord)
    }

    private static func isSpotifyWord(_ word: String) -> Bool {
        word == "spotify" || ["spotifyda", "spotifyde", "spotifydan", "spotifyden", "spotifya", "spotifye"].contains(word)
    }

    /// Without an explicit `Spotify` address, a control verb must be in command position:
    /// at the end of the utterance, apart from harmless politeness/timing words. This keeps
    /// phrases that merely discuss an action from becoming playback commands.
    private static func hasCommandPositionVerb(_ verbs: Set<String>, in words: [String]) -> Bool {
        guard let verbIndex = words.lastIndex(where: verbs.contains) else { return false }
        return words[words.index(after: verbIndex)...].allSatisfy(commandTailWords.contains)
    }

    /// Conservative, deterministic gate that must pass before Ollama is even consulted.
    /// A music noun by itself is never a command, and a generic word such as `sesim` cannot
    /// become a Spotify volume operation. Ollama may veto a candidate but cannot promote
    /// ordinary dictation into a side-effecting intent.
    private static func explicitIntent(in text: String) -> ExplicitSpotifyIntent? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }

        let words = canonicalizeVerbs(intentWords(normalized))
        // Counted on whitespace, not on `words`: the apostrophe split turns "Spotify'da" and
        // "Manga'nın" into two tokens each, which pushed ordinary 7-word commands over.
        guard !words.isEmpty, spokenWordCount(normalized) <= maxCommandWordCount else { return nil }

        let wordSet = Set(words)
        guard mentionOrNegationWords.isDisjoint(with: wordSet) else { return nil }

        let hasSpotifyContext = words.contains(where: isSpotifyWord)
        // "çalma listesi" is only music as a pair; "listesini aç" alone is everyday prose.
        let hasMusicContext = !musicContextWords.isDisjoint(with: wordSet)
            || normalized.contains("çalma liste")
        let hasExplicitTarget = hasSpotifyContext || hasMusicContext

        // Queries about the current track are explicit even without saying Spotify, but
        // only these established phrases qualify. A loose `contains("şu an ne")` made
        // ordinary questions eligible previously.
        if hasExplicitTarget,
           (normalized.contains("ne çalıyor") ||
            normalized.contains("hangi şarkı çalıyor") ||
            normalized.contains("hangi parça çalıyor") ||
            normalized.contains("çalan şarkı ne") ||
            normalized.contains("çalan parça ne")) {
            return .currentTrack
        }

        // Spotify volume needs an actual Spotify/music target, an exact volume noun, a
        // numeric value, and an adjustment verb. `sesim`, `sesimi`, and "ses kontrol"
        // therefore remain dictation.
        let volumeWords: Set<String> = ["ses", "sesi", "sesini", "volume"]
        let volumeVerbs: Set<String> = ["yap", "ayarla", "getir", "çıkar", "cikar", "indir", "artır", "artir", "azalt", "set"]
        if hasExplicitTarget,
           !volumeWords.isDisjoint(with: wordSet),
           !volumeVerbs.isDisjoint(with: wordSet),
           let volume = words.compactMap(Int.init).first,
           (0...100).contains(volume) {
            return .setVolume(volume)
        }

        guard hasExplicitTarget else { return nil }

        // Playing the whole Liked Songs collection has no controller operation yet. Do not
        // silently reinterpret it as a text search.
        guard !isLikedSongsPlaybackCommand(normalized) else { return nil }

        let likeVerbs: Set<String> = ["ekle", "beğen", "begen", "like"]
        if !likeVerbs.isDisjoint(with: wordSet),
           (normalized.contains("çalan şarkı") || normalized.contains("çalan parça") ||
            normalized.contains("beğenilenlerime") || normalized.contains("beğendiklerime")) {
            return .likeCurrentTrack
        }

        let nextWords: Set<String> = ["sonraki", "next"]
        let transitionVerbs: Set<String> = ["geç", "gec", "atla", "skip"]
        if !nextWords.isDisjoint(with: wordSet),
           (hasSpotifyContext || hasCommandPositionVerb(transitionVerbs, in: words)) {
            return .next
        }

        let previousWords: Set<String> = ["önceki", "onceki", "previous", "prev"]
        if !previousWords.isDisjoint(with: wordSet),
           (hasSpotifyContext || hasCommandPositionVerb(transitionVerbs, in: words)) {
            return .previous
        }

        let pauseVerbs: Set<String> = ["durdur", "kapat", "duraklat", "pause"]
        if !pauseVerbs.isDisjoint(with: wordSet),
           (hasSpotifyContext || hasCommandPositionVerb(pauseVerbs, in: words)) {
            return .pause
        }

        let playVerbs: Set<String> = ["çal", "cal", "aç", "ac", "oynat", "başlat", "baslat", "dinlet", "play", "resume"]
        if !playVerbs.isDisjoint(with: wordSet),
           (hasSpotifyContext
            || hasCommandPositionVerb(playVerbs, in: words)
            || hasLeadingVerb(playVerbs, in: words)) {
            let query = shared.extractSearchQuery(normalized)
            return query.isEmpty ? .play : .search(SpotifyRequestParser.requestFromRules(normalized))
        }

        let searchVerbs: Set<String> = ["ara", "bul", "search"]
        if hasSpotifyContext, hasCommandPositionVerb(searchVerbs, in: words) {
            let query = shared.extractSearchQuery(normalized)
            if !query.isEmpty { return .search(SpotifyRequestParser.requestFromRules(normalized)) }
        }

        return nil
    }

    /// Check if transcribed text is a Spotify voice command.
    /// When Ollama is available, one structured call both verifies the intent (it can only
    /// veto the deterministic gate, never promote dictation) and splits song/artist for the
    /// search. The split is cached for the `handleCommand` call that follows, so a command
    /// costs a single Ollama round trip.
    static func isSpotifyCommand(_ text: String, ollamaAvailable: Bool = false) async -> Bool {
        guard explicitIntent(in: text) != nil else { return false }

        if ollamaAvailable,
           let parse = await SpotifyRequestParser.queryOllama(transcript: text, model: selectedOllamaModel) {
            owLog("[Spotify] Ollama parse for '\(text)': \(parse)")
            ollamaParseCache.store(parse, for: text)
            // The veto exists for ambiguous phrasing. A transcript that names Spotify is
            // unambiguous, and llama3.2:3b has vetoed plain "Spotify'da Tarkan çal".
            if !parse.isMusicCommand, addressesSpotify(text) {
                owLog("[Spotify] Ignoring Ollama veto: transcript addresses Spotify explicitly")
                return true
            }
            return parse.isMusicCommand
        }

        // With Ollama unavailable or timed out, the deterministic explicit-intent gate is
        // already sufficient. It is deliberately fail-closed rather than keyword-based.
        return true
    }

    /// The model the user picked in Settings (AppState.ollamaModel, UserDefaults key
    /// "ollamaModel", default LLMCleanup.defaultModel). SpotifyManager is a standalone singleton with no
    /// AppState reference, so it reads the same UserDefaults key directly rather than
    /// hardcoding a model. See ReminderManager's identical `selectedOllamaModel`.
    private static var selectedOllamaModel: String {
        UserDefaults.standard.string(forKey: "ollamaModel") ?? LLMCleanup.defaultModel
    }

    private static let ollamaParseCache = OllamaParseCache()

    /// Holds the Ollama parse of the most recent transcript between `isSpotifyCommand` and
    /// `handleCommand`, which AppState calls back to back with the same text.
    private final class OllamaParseCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (text: String, parse: SpotifyRequestParser.OllamaParse)?

        func store(_ parse: SpotifyRequestParser.OllamaParse, for text: String) {
            lock.withLock { entry = (text, parse) }
        }

        func take(for text: String) -> SpotifyRequestParser.OllamaParse? {
            lock.withLock {
                defer { entry = nil }
                return entry?.text == text ? entry?.parse : nil
            }
        }
    }

    // MARK: - Command Handler

    /// Handles a transcript already identified as a Spotify command. The explicit-intent
    /// gate below is the only way into `SpotifyController`, whose methods have side effects.
    func handleCommand(text: String, targetApp: NSRunningApplication? = nil) async -> Bool {
        let activeApp = targetApp ?? NSWorkspace.shared.frontmostApplication
        guard let intent = Self.explicitIntent(in: text) else {
            owLog("[SpotifyManager] Refused non-explicit Spotify intent: '\(text)'")
            return false
        }
        owLog("[SpotifyManager] Handling command: '\(text)'")

        let ollamaParse = Self.ollamaParseCache.take(for: text)
        let controller = SpotifyController.shared
        let result: SpotifyActionResult
        switch intent {
        case .pause:
            result = await controller.pause()
        case .play:
            result = await controller.play()
        case .next:
            result = await controller.nextTrack()
        case .previous:
            result = await controller.previousTrack()
        case .setVolume(let volume):
            result = await controller.setVolume(volume)
        case .currentTrack:
            result = await controller.getCurrentTrack()
        case .search(let rules):
            var request = rules
            if let ollamaParse {
                request = SpotifyRequestParser.request(from: ollamaParse, transcript: text, rules: rules)
            }
            owLog("[SpotifyManager] Search request: \(request)")
            result = await controller.searchAndPlay(request)
        case .likeCurrentTrack:
            result = await controller.likeCurrentTrack()
        }

        sendNotification(title: "🎵 Spotify", body: result.message)

        if result.succeeded {
            keepInBackground(targetApp: activeApp)
        }

        // Refusals and failures are not successful handling. AppState will preserve the
        // transcript through the normal dictation fallback instead of swallowing it as
        // though Spotify acted.
        return result.succeeded
    }

    private func keepInBackground(targetApp: NSRunningApplication?) {
        // Only if Spotify actually stole focus (e.g. cold launch) do we restore focus to targetApp.
        // Plain background commands to a running Spotify do not steal focus, so avoiding
        // unnecessary activate() calls eliminates the Alt+Tab flicker completely.
        guard let spotify = NSWorkspace.shared.frontmostApplication,
              spotify.bundleIdentifier == SpotifyController.spotifyBundleID else { return }
        // NSRunningApplication.hide() needs no Automation permission (the old
        // System Events script did), so this also works in the sandboxed build.
        spotify.hide()
        if let targetApp, targetApp.bundleIdentifier != SpotifyController.spotifyBundleID {
            targetApp.activate()
        }
    }

    // MARK: - Search Query Extraction

    // Internal (not private) so the standalone Tools/main.swift harness can call it
    // directly — it's a pure function of `SpotifyRequestParser.searchJunkWords`, safe to exercise in isolation.
    func extractSearchQuery(_ residue: String) -> String {
        SpotifyRequestParser.freeTextQuery(residue)
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
