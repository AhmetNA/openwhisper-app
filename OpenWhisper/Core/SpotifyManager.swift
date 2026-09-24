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
    enum ExplicitSpotifyIntent: Equatable {
        case pause
        case play
        case next
        case previous
        /// System output volume, in percent (not Spotify's own slider; see `SystemVolume`).
        case setVolume(Int)
        /// Relative system volume change ("müziğin sesi çok kısık" → +30).
        case adjustVolume(Int)
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
    static func explicitIntent(in text: String) -> ExplicitSpotifyIntent? {
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
        let volumeVerbs: Set<String> = [
            "yap", "ayarla", "getir", "çıkar", "cikar", "indir", "artır", "artir", "azalt",
            "düşür", "dusur", "yükselt", "yukselt", "set"
        ]
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

    // MARK: - Decision

    /// Raw last words that may end a Spotify search spoken without "Spotify" or a music noun
    /// ("Hadise Düm Tek Tek çal"). Deliberately excludes "aç" ("dosyayı aç", "Chrome'u aç")
    /// and the "koy" alias ("masaya koy"): those end far too much ordinary dictation, and
    /// every candidate costs an Ollama round trip before the text can be pasted.
    private static let promotionVerbs: Set<String> = [
        "çal", "cal", "çalsana", "calsana", "oynat", "oynatsana", "dinlet", "dinletsene"
    ]
    private static let maxPromotionWordCount = 6

    /// "çal" also means ring, knock and play an instrument ("zili çal", "kapıyı çal",
    /// "gitar çal"); models happily read the object as a song title. Matched as word
    /// prefixes so inflected forms ("kapısını", "gitarı") are caught too — so only stems
    /// long/distinct enough not to start band or song names belong here (not "para": Paramore).
    private static let nonMusicPlayObjects: [String] = [
        "kapı", "zil", "korna", "alarm", "telefon",
        "gitar", "piyano", "keman", "davul", "bağlama", "flüt", "enstrüman",
        // A tune/lullaby to hum or an instrument, not a Spotify title: the model promoted
        // these ("şu melodiyi çal", "biraz saz çal") once the prompt grew natural examples.
        "saz", "melodi", "ninni"
    ]

    /// Personal pronouns mark ordinary sentences ("onun parasını çal", "ona bir şarkı çal"):
    /// a spoken "<artist> <song> çal" request doesn't contain them.
    private static let pronouns: Set<String> = [
        "ben", "sen", "o", "biz", "siz", "onlar", "beni", "seni", "onu", "bizi", "sizi", "onları",
        "bana", "sana", "ona", "bize", "size", "onlara", "benim", "senin", "onun", "bizim", "sizin", "onların"
    ]

    /// A transcript the rules rejected that Ollama may still promote to a search: short,
    /// at least two words before a closing play verb (one bare noun — "bateri çal" — is far
    /// more often an instrument or object than a song), and not quoting/negating anything.
    static func isPromotionCandidate(_ text: String) -> Bool {
        let normalized = normalize(text)
        let spoken = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard spoken.count >= 3, spoken.count <= maxPromotionWordCount,
              let last = spoken.last(where: { !commandTailWords.contains($0) }),
              promotionVerbs.contains(last) else { return false }
        let words = intentWords(normalized)
        guard !words.contains(where: { word in nonMusicPlayObjects.contains { word.hasPrefix($0) } }),
              pronouns.isDisjoint(with: words) else { return false }
        return mentionOrNegationWords.isDisjoint(with: Set(words))
    }

    /// Whether the transcript itself supports what Ollama claims. The model's label alone
    /// never causes a side effect; each intent needs its own words in the text.
    ///
    /// `natural` widens transport intents to conversational cues ("bu şarkıdan sıkıldım").
    /// It is only set on the natural-phrasing path, never when Ollama would override a
    /// rule-gate result, so a song title containing "geç" can't turn a search into a skip.
    private static func hasEvidence(for parse: SpotifyRequestParser.OllamaParse, in text: String, natural: Bool = false) -> Bool {
        let normalized = normalize(text)
        let words = canonicalizeVerbs(intentWords(normalized))
        let wordSet = Set(words)
        let playVerbs: Set<String> = ["çal", "cal", "aç", "ac", "oynat", "başlat", "baslat", "dinlet", "play", "resume"]
        let cues = cueWords(normalized)
        switch parse.intent {
        case .pause:
            return !wordSet.isDisjoint(with: ["durdur", "kapat", "duraklat", "pause"])
                || (natural && !Set(cues).isDisjoint(with: naturalPauseCues))
        case .play:
            // Nothing left to search for; otherwise this is a search, not a resume.
            return !wordSet.isDisjoint(with: playVerbs) && shared.extractSearchQuery(normalized).isEmpty
        case .next:
            return !wordSet.isDisjoint(with: ["sonraki", "next", "atla", "skip"])
                || (natural && (!Set(cues).isDisjoint(with: naturalNextWords)
                    || cues.contains { word in naturalNextStems.contains { word.hasPrefix($0) } }))
        case .previous:
            return !wordSet.isDisjoint(with: ["önceki", "onceki", "previous", "prev"])
        case .volume:
            return volumeTarget(in: text) != nil
        case .volumeUp:
            return relativeVolumeCueDirection(in: text, up: true)
        case .volumeDown:
            return relativeVolumeCueDirection(in: text, up: false)
        case .current:
            return ["ne çalıyor", "hangi şarkı çalıyor", "hangi parça çalıyor", "çalan şarkı ne", "çalan parça ne"]
                .contains { normalized.contains($0) }
        case .like:
            return !wordSet.isDisjoint(with: ["ekle", "beğen", "begen", "like"])
                && (normalized.contains("çalan") || normalized.contains("beğenilenlerime")
                    || normalized.contains("beğendiklerime") || normalized.contains("beğenilerime"))
        case .search:
            let request = searchRequest(for: normalized, parse: parse)
            return !wordSet.isDisjoint(with: playVerbs.union(["ara", "bul", "search"]))
                && !request.searchQueries.isEmpty
        case .none:
            return false
        }
    }

    private static func searchRequest(for text: String, parse: SpotifyRequestParser.OllamaParse?) -> SpotifySearchRequest {
        let rules = SpotifyRequestParser.requestFromRules(normalize(text))
        guard let parse, parse.intent == .search else { return rules }
        return SpotifyRequestParser.request(from: parse, transcript: text, rules: rules)
    }

    /// Nil when the intent can't be carried out from this text — a volume with neither a
    /// number nor "sonuna kadar" must never default to muting Spotify.
    private static func intent(from parse: SpotifyRequestParser.OllamaParse, text: String) -> ExplicitSpotifyIntent? {
        switch parse.intent {
        case .pause: return .pause
        case .play: return .play
        case .next: return .next
        case .previous: return .previous
        case .volume: return volumeTarget(in: text).map { .setVolume($0) }
        case .volumeUp: return .adjustVolume(volumeStep(in: text))
        case .volumeDown: return .adjustVolume(-volumeStep(in: text))
        case .current: return .currentTrack
        case .like: return .likeCurrentTrack
        case .search, .none: return .search(searchRequest(for: text, parse: parse))
        }
    }

    private static func sameKind(_ a: ExplicitSpotifyIntent, _ b: ExplicitSpotifyIntent) -> Bool {
        switch (a, b) {
        case (.search, .search), (.setVolume, .setVolume), (.adjustVolume, .adjustVolume): return true
        default: return a == b
        }
    }

    /// One decision from the rule gate (`rules`) and Ollama's reading (`parse`, nil when
    /// Ollama is unavailable or timed out):
    ///
    /// | rules | Ollama                    | result                                             |
    /// |-------|---------------------------|----------------------------------------------------|
    /// | any   | unavailable               | rules (unchanged fail-closed behavior)             |
    /// | R     | same intent               | R (a search gets Ollama's title/artist split)      |
    /// | R     | none                      | R if Spotify is named or R is volume/current/like, |
    /// |       |                           | whose gate is already narrow; else dictation       |
    /// | R     | other intent, evidenced   | Ollama's intent                                     |
    /// | R     | other intent, no evidence | R                                                  |
    /// | nil   | search, evidenced,        | search — limited to short "… çal" phrases          |
    /// |       | promotion candidate       |                                                    |
    /// | nil   | volume, evidenced,        | that intent — natural phrasing ("müziğin sesi çok  |
    /// |       | natural candidate         | kısık"); acts on the system volume                 |
    /// | nil   | skip/pause/mood,          | that intent, only while Spotify is playing on this |
    /// |       | evidenced, natural cand.  | Mac ("bu şarkıdan sıkıldım")                       |
    /// | nil   | anything else             | dictation                                          |
    static func decide(
        rules: ExplicitSpotifyIntent?,
        parse: SpotifyRequestParser.OllamaParse?,
        text: String,
        spotifyPlaying: Bool = false
    ) -> ExplicitSpotifyIntent? {
        guard let parse else { return rules }

        guard let rules else {
            if let promoted = promotedSearch(parse, text: text) { return promoted }
            guard isNaturalCandidate(text) else { return nil }
            return naturalIntent(parse, text: text, spotifyPlaying: spotifyPlaying)
        }

        if parse.intent == .none {
            switch rules {
            case .setVolume, .currentTrack, .likeCurrentTrack:
                return rules
            default:
                if addressesSpotify(text) {
                    owLog("[Spotify] Ignoring Ollama veto: transcript addresses Spotify explicitly")
                    return rules
                }
                return nil
            }
        }

        guard let llmIntent = intent(from: parse, text: text) else { return rules }
        if sameKind(llmIntent, rules) {
            if case .search = rules { return llmIntent }  // carries Ollama's split
            return rules
        }
        if hasEvidence(for: parse, in: text) {
            owLog("[Spotify] Ollama intent \(parse.intent) overrides rules for '\(text)'")
            return llmIntent
        }
        return rules
    }

    /// Rule-rejected text Ollama may turn into a search of a named song/artist/album.
    private static func promotedSearch(_ parse: SpotifyRequestParser.OllamaParse, text: String) -> ExplicitSpotifyIntent? {
        // Only named items: a mood/playlist reading ("bir ninni çal") is too loose to
        // turn dictation into playback.
        guard parse.intent == .search, [.track, .artist, .album].contains(parse.kind),
              isPromotionCandidate(text), hasEvidence(for: parse, in: text) else { return nil }
        // Promotion needs Ollama to have named something, and every name to appear in
        // the transcript; there is no rule-gate result to fall back on.
        let title = SpotifyRequestParser.cleanOllamaName(parse.title)
        let artist = SpotifyRequestParser.cleanOllamaName(parse.artist)
        guard !(title.isEmpty && artist.isEmpty),
              SpotifyRequestParser.isGrounded(title, in: text),
              SpotifyRequestParser.isGrounded(artist, in: text) else { return nil }
        let request = searchRequest(for: text, parse: parse)
        owLog("[Spotify] Ollama promoted '\(text)' to a search: \(request)")
        return .search(request)
    }

    /// Natural phrasing the rules rejected. Only intents that are cheap to undo qualify;
    /// play/current/like keep needing the rule gate's explicit wording. Volume works any
    /// time (it is the system volume); the Spotify-specific ones only while it plays.
    private static func naturalIntent(
        _ parse: SpotifyRequestParser.OllamaParse, text: String, spotifyPlaying: Bool
    ) -> ExplicitSpotifyIntent? {
        switch parse.intent {
        case .volume, .volumeUp, .volumeDown:
            guard hasEvidence(for: parse, in: text, natural: true) else { return nil }
        case .next, .previous, .pause:
            guard spotifyPlaying, hasEvidence(for: parse, in: text, natural: true) else { return nil }
        case .search:
            // Moods only ("biraz sakin bir şeyler dinleyelim"); named songs go through promotion.
            guard spotifyPlaying, parse.kind == .playlist, SpotifyRequestParser.hasPlaylistEvidence(text),
                  hasEvidence(for: parse, in: text, natural: true),
                  case .search(let request)? = intent(from: parse, text: text),
                  request.kind == .playlist else { return nil }
        case .play, .current, .like, .none:
            return nil
        }
        let result = intent(from: parse, text: text)
        if let result { owLog("[Spotify] Natural phrasing '\(text)' → \(result)") }
        return result
    }

    // MARK: - Natural phrasing

    private static let maxNaturalWordCount = 10

    /// Word starts (folded, see `cueWords`) that put an utterance on the subject of music.
    private static let naturalTopicStems: [String] = ["muzi", "sarki", "parca", "spotify", "dinle"]
    private static let volumeNouns: Set<String> = ["ses", "sesi", "sesini", "sesin", "volume"]

    /// Lowercased words with every diacritic removed, including dotless "ı" (which
    /// Foundation's diacritic folding leaves alone), so cue lists need a single spelling
    /// that also matches Whisper's ASCII output ("kisik").
    private static func cueWords(_ text: String) -> [String] {
        SpotifyRequestParser.foldedWords(text).map { $0.replacingOccurrences(of: "ı", with: "i") }
    }

    /// A short utterance about music or its volume, not quoting or negating anything. Such
    /// text reaches Ollama when it mentions volume, or otherwise while Spotify is playing on
    /// this Mac (see `isSpotifyCommand`). `sesim` ("my voice") is deliberately not a volume noun.
    static func isNaturalCandidate(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard spokenWordCount(normalized) <= maxNaturalWordCount,
              mentionOrNegationWords.isDisjoint(with: Set(intentWords(normalized))) else { return false }
        let cues = cueWords(normalized)
        return !volumeNouns.isDisjoint(with: cues)
            || cues.contains { word in naturalTopicStems.contains { word.hasPrefix($0) } }
    }

    // Loudness cues, matched as word starts so "kısık", "kısıktı", "yükseltir misin" all count.
    private static let louderStems: [String] = [
        "kisik", "kisil", "dusuk", "duyulmu", "duyam", "duymuyor", "yukselt", "artir", "arttir"
    ]
    private static let quieterStems: [String] = [
        "yuksek", "azalt", "dusur", "indir", "bagir", "patla", "patli", "gurultu", "fazla"
    ]
    /// Exact words only: as word starts "az" would match "azalt" and "kıs" would match "kısık".
    private static let louderWords: Set<String> = ["az"]
    private static let quieterWords: Set<String> = ["kis", "kisar", "kissana", "kisalim", "kisin", "kisabilir", "kisiver"]
    /// "aç" means louder only next to a volume noun or an amount ("müziği biraz aç");
    /// "müziği aç" alone is resume.
    private static let openWords: Set<String> = ["ac", "acsana", "acar", "acabilir", "aciver"]
    private static let smallAmountWords: Set<String> = ["biraz", "azicik", "azcik", "hafif", "hafifce", "tik"]
    private static let largeAmountWords: Set<String> = ["cok", "asiri", "baya", "bayagi", "epey", "iyice", "fazla"]
    private static let maxVolumePhrases: [String] = ["sonuna kadar", "son ses", "en yuksek", "maksimum", "full"]

    private static let naturalPauseCues: Set<String> = [
        "sustur", "sustursana", "durdursana", "kapatsana", "kapatir", "durdurur", "duraklatir"
    ]
    private static let naturalNextWords: Set<String> = ["gec", "gecsene", "gecelim", "gecer", "degistir", "degistirsene", "olmadi"]
    private static let naturalNextStems: [String] = ["sikil", "sikici", "begenmedim", "sevmedim"]

    private static func hasNumber(_ text: String) -> Bool {
        intentWords(normalize(text)).compactMap(Int.init).contains { (0...100).contains($0) }
    }

    /// Whether the text itself says which way the volume should go. A number always
    /// means an absolute setting, so "sesini 40'a yükselt" can never become +20.
    private static func relativeVolumeCueDirection(in text: String, up: Bool) -> Bool {
        guard !hasNumber(text) else { return false }
        let cues = cueWords(normalize(text))
        let cueSet = Set(cues)
        if up {
            let amountOrNoun = !cueSet.isDisjoint(with: smallAmountWords.union(largeAmountWords).union(volumeNouns).union(["daha"]))
            return cues.contains { word in louderStems.contains { word.hasPrefix($0) } }
                || !cueSet.isDisjoint(with: louderWords)
                || (!cueSet.isDisjoint(with: openWords) && amountOrNoun)
        }
        return cues.contains { word in quieterStems.contains { word.hasPrefix($0) } }
            || !cueSet.isDisjoint(with: quieterWords)
    }

    /// The absolute volume a `volume` intent asks for: the spoken number, or 100 for
    /// "sonuna kadar aç". Nil otherwise — including "sonuna kadar kıs", which is not max.
    private static func volumeTarget(in text: String) -> Int? {
        let normalized = normalize(text)
        let words = intentWords(normalized)
        if !volumeNouns.isDisjoint(with: words), let number = words.compactMap(Int.init).first(where: { (0...100).contains($0) }) {
            return number
        }
        let cues = cueWords(normalized)
        // Only lowering verbs veto: "en yüksek" itself contains the "too loud" cue.
        let lowering = !Set(cues).isDisjoint(with: quieterWords)
            || cues.contains { word in ["azalt", "dusur", "indir"].contains { word.hasPrefix($0) } }
        guard maxVolumePhrases.contains(where: cues.joined(separator: " ").contains), !lowering else { return nil }
        return 100
    }

    /// A volume noun or a loudness cue: worth asking Ollama about even with no music on.
    static func mentionsVolume(_ text: String) -> Bool {
        !volumeNouns.isDisjoint(with: cueWords(normalize(text)))
            || relativeVolumeCueDirection(in: text, up: true)
            || relativeVolumeCueDirection(in: text, up: false)
    }

    /// Whisper hears "sesi biraz kıs" as "sesi biraz kız" (girl), which the model then
    /// reads as the opposite direction. Next to a volume noun "kız" can only be "kıs".
    static func repairVolumeMishearing(_ text: String) -> String {
        let folded = cueWords(normalize(text))
        guard !volumeNouns.isDisjoint(with: folded) || folded.contains(where: { word in naturalTopicStems.contains { word.hasPrefix($0) } }),
              folded.contains(where: { ["kiz", "kizsana"].contains($0) }) else { return text }
        return text.replacingOccurrences(
            of: "\\b([Kk])[ıi]z(sana)?\\b", with: "$1ıs$2", options: .regularExpression
        )
    }

    /// 10 for "biraz", 30 for "çok", 20 otherwise.
    static func volumeStep(in text: String) -> Int {
        let cues = Set(cueWords(normalize(text)))
        if !cues.isDisjoint(with: smallAmountWords) { return 10 }
        if !cues.isDisjoint(with: largeAmountWords) { return 30 }
        return 20
    }

    /// Check if transcribed text is a Spotify voice command, deciding which one. Text the
    /// rule gate rejects only reaches Ollama when it is a promotion candidate, or a natural
    /// candidate while Spotify is playing on this Mac, so ordinary dictation isn't delayed.
    /// The decision is cached for the `handleCommand` call that follows, so a command
    /// costs a single Ollama round trip.
    static func isSpotifyCommand(_ transcript: String, ollamaAvailable: Bool = false) async -> Bool {
        let text = repairVolumeMishearing(transcript)
        let rules = explicitIntent(in: text)
        let promotion = rules == nil && ollamaAvailable && isPromotionCandidate(text)
        // Cheapest checks first: the word test, then the playback query (which never
        // launches Spotify), and only then Ollama.
        let natural = rules == nil && ollamaAvailable && isNaturalCandidate(text)
        var spotifyPlaying = false
        if natural {
            spotifyPlaying = await SpotifyController.shared.isPlayingLocally()
        }
        guard rules != nil || promotion || (natural && (spotifyPlaying || mentionsVolume(text))) else { return false }

        var parse: SpotifyRequestParser.OllamaParse?
        if ollamaAvailable {
            parse = await SpotifyRequestParser.queryOllama(transcript: text, model: selectedOllamaModel)
            if let parse { owLog("[Spotify] Ollama parse for '\(text)': \(parse)") }
        }
        let decision = decide(rules: rules, parse: parse, text: text, spotifyPlaying: spotifyPlaying)
        if let decision { decisionCache.store(decision, for: transcript) }
        return decision != nil
    }

    /// The model the user picked in Settings (AppState.ollamaModel, UserDefaults key
    /// "ollamaModel", default LLMCleanup.defaultModel). SpotifyManager is a standalone singleton with no
    /// AppState reference, so it reads the same UserDefaults key directly rather than
    /// hardcoding a model. See ReminderManager's identical `selectedOllamaModel`.
    static var selectedOllamaModel: String {
        UserDefaults.standard.string(forKey: "ollamaModel") ?? LLMCleanup.defaultModel
    }

    private static let decisionCache = DecisionCache()

    /// Holds the decision for the most recent transcript between `isSpotifyCommand` and
    /// `handleCommand`, which AppState calls back to back with the same text.
    private final class DecisionCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (text: String, intent: ExplicitSpotifyIntent)?

        func store(_ intent: ExplicitSpotifyIntent, for text: String) {
            lock.withLock { entry = (text, intent) }
        }

        func take(for text: String) -> ExplicitSpotifyIntent? {
            lock.withLock {
                defer { entry = nil }
                return entry?.text == text ? entry?.intent : nil
            }
        }
    }

    // MARK: - Command Handler

    /// Handles a transcript already identified as a Spotify command. The explicit-intent
    /// gate below is the only way into `SpotifyController`, whose methods have side effects.
    func handleCommand(text: String, targetApp: NSRunningApplication? = nil) async -> Bool {
        let activeApp = targetApp ?? NSWorkspace.shared.frontmostApplication
        // The decision made by `isSpotifyCommand`; without one (called directly), only the
        // rule gate can authorize a side effect.
        guard let intent = Self.decisionCache.take(for: text) ?? Self.explicitIntent(in: text) else {
            owLog("[SpotifyManager] Refused non-explicit Spotify intent: '\(text)'")
            return false
        }
        owLog("[SpotifyManager] Handling command: '\(text)' → \(intent)")

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
            result = SystemVolume.set(volume)
        case .adjustVolume(let delta):
            result = SystemVolume.adjust(by: delta)
        case .currentTrack:
            result = await controller.getCurrentTrack()
        case .search(let request):
            owLog("[SpotifyManager] Search request: \(request)")
            result = await controller.searchAndPlay(request)
        case .likeCurrentTrack:
            result = await controller.likeCurrentTrack()
        }

        switch intent {
        case .setVolume, .adjustVolume:
            sendNotification(title: "🔊 Ses", body: result.message)
        default:
            sendNotification(title: "🎵 Spotify", body: result.message)
        }

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
