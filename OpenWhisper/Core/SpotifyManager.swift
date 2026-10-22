import Foundation
import os
import AppKit
import UserNotifications

final class SpotifyManager: @unchecked Sendable {

    static let shared = SpotifyManager()

    private init() {}

    /// Content-based (not prefix-based) matching for "play my Liked Songs". A word-boundary
    /// prefix like "beğenilen şarkılar" would never match "beğenilen şarkıları aç" (next char
    /// is "ı", not a space), so the nouns are checked with plain `.contains` against
    /// `Self.normalize`d text. "beğendiğim" / "sevdiğim" only count with plural "şarkılar":
    /// "beğendiğim şarkıyı çal" names one song.
    private static let likedSongsNouns: Set<String> = [
        "beğenilen", "beğendiklerim", "beğenilerim", "beğendiğim şarkılar", "sevdiğim şarkılar",
        "favori şarkılar", "favorilerim", "liked songs"
    ]
    private static let likedSongsVerbs: Set<String> = ["çal", "aç", "oynat", "başlat", "dinlet"]

    /// True for "beğendiğim şarkıları çal", "beğenilerimin listesini aç", "Spotify'da
    /// beğenilenleri oynat", etc. The verb must close the command (or Spotify be named), so
    /// "beğendiğim şarkıları arkadaşıma çaldım" stays dictation. Anything containing "ekle"
    /// ("çalan şarkıyı beğenilerime ekle") is the Like command instead.
    private static func isLikedSongsPlaybackCommand(_ normalized: String, words: [String]) -> Bool {
        guard !normalized.contains("ekle"), likedSongsNouns.contains(where: normalized.contains),
              !likedSongsVerbs.isDisjoint(with: words) else { return false }
        return words.contains(where: isSpotifyWord) || hasCommandPositionVerb(likedSongsVerbs, in: words)
    }

    private static let maxCommandWordCount = 8

    // MARK: - Normalization

    static func normalize(_ text: String) -> String {
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
        /// The user's own Liked Songs, shuffled, as a queue.
        case playLikedSongs
        // Rule-only (`SpotifyExtendedCommands.swift`).
        case setShuffle(Bool)
        case setRepeat(SpotifyRepeatMode)
        case seek(SpotifySeek)
        /// Adds a song after the current one without interrupting it.
        case queue(SpotifySearchRequest)
        case unlikeCurrentTrack
        /// Spotify's own volume slider, only when asked for by name.
        case setSpotifyVolume(Int)
        case playOwnPlaylist(String)
        case addCurrentTrackToPlaylist(String)
        case playSavedAlbum
        case playFollowedArtist
        case playRecentTrack
        case transferPlayback(SpotifyDeviceKind)
        case question(SpotifyQuestion)
        /// Pauses Spotify after this many seconds.
        case sleepTimer(Int)
        case cancelSleepTimer

        /// Decided by the rules alone: the models don't know these labels.
        var isRuleOnly: Bool {
            switch self {
            case .pause, .play, .next, .previous, .setVolume, .adjustVolume, .currentTrack, .search, .likeCurrentTrack:
                return false
            default:
                return true
            }
        }

        /// What Jarvis says is the command's own result ("3 dakika 20 saniye kaldı"), not
        /// a plain ack; and when it fails he says why instead of typing the words out.
        var speaksResult: Bool {
            switch self {
            case .currentTrack, .question, .sleepTimer, .cancelSleepTimer, .queue, .addCurrentTrackToPlaylist,
                 .unlikeCurrentTrack, .transferPlayback:
                return true
            default:
                return false
            }
        }

        /// Replaces what plays, so a correction can put the old song back.
        var replacesPlayback: Bool {
            switch self {
            case .pause, .play, .next, .previous, .search, .playLikedSongs, .seek, .playOwnPlaylist,
                 .playSavedAlbum, .playFollowedArtist, .playRecentTrack:
                return true
            default:
                return false
            }
        }
    }

    /// No quoting or negation word ("… diye", "istemiyorum").
    static func mentionVetoAllows(_ normalized: String) -> Bool {
        mentionOrNegationWords.isDisjoint(with: Set(intentWords(normalized)))
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
        "dinleyelim": "dinlet", "dinletsene": "dinlet",
        // Hortative, plural, "-ıver" and future forms ("biraz müzik açalım", "eğlenceli bir
        // şeyler açacağız"): heard in voice sessions on 25 Sep 2026 and pasted as dictation.
        "açalım": "aç", "acalim": "aç", "açın": "aç", "acin": "aç", "açıver": "aç", "aciver": "aç",
        "açacağız": "aç", "acacagiz": "aç", "açacağım": "aç", "acacagim": "aç",
        "çalalım": "çal", "calalim": "çal", "çalın": "çal", "calin": "çal", "çalıver": "çal", "caliver": "çal",
        "çalacağız": "çal", "calacagiz": "çal", "çalacağım": "çal", "calacagim": "çal",
        "oynatalım": "oynat", "oynatalim": "oynat", "başlatalım": "başlat", "baslatalim": "başlat"
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

    /// Canonical token for "devam et" / "sürdür": resume what was paused. Never a search,
    /// and only a command next to a music or Spotify word ("toplantıya devam edelim" is prose).
    private static let resumeVerb = "resume"
    private static let resumeAuxiliaries: Set<String> = ["et", "ettir", "etsene", "ettirsene", "edelim", "edin"]
    private static let resumeAliases: Set<String> = ["sürdür", "surdur", "sürdürsene", "surdursene"]

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
            // "müziğe devam et", "şarkıya devam ettir": one resume verb, so the gate's
            // command-position check sees "devam et" as the closing verb.
            if word == "devam", let next, resumeAuxiliaries.contains(next) {
                result.append(resumeVerb)
                index += 2
                continue
            }
            result.append(resumeAliases.contains(word) ? resumeVerb : playVerbAliases[word] ?? word)
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

        if mentionVetoAllows(normalized),
           let extended = extendedIntent(normalized) ?? queueIntentFromRules(normalized) {
            return extended
        }
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

        // Before the target check: "beğendiklerimi çal" names the music by itself. Never a
        // text search, which found someone else's "Beğenilen Şarkılarım" playlist.
        if isLikedSongsPlaybackCommand(normalized, words: words) { return .playLikedSongs }

        guard hasExplicitTarget else { return nil }

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

        if hasCommandPositionVerb([resumeVerb], in: words) { return .play }

        let playVerbs: Set<String> = ["çal", "cal", "aç", "ac", "oynat", "başlat", "baslat", "dinlet", "play", "resume"]
        if !playVerbs.isDisjoint(with: wordSet),
           (hasSpotifyContext
            || hasCommandPositionVerb(playVerbs, in: words)
            || hasLeadingVerb(playVerbs, in: words)) {
            // "Şarkı aç", "müzik çal": nothing named, so the user's Liked Songs. Only "devam et"
            // (above) resumes what was paused.
            let query = shared.extractSearchQuery(normalized)
            return query.isEmpty ? .playLikedSongs : .search(SpotifyRequestParser.requestFromRules(normalized))
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
            guard !wordSet.isDisjoint(with: playVerbs) else { return false }
            // "Müziğe devam et": resuming has no title to search for.
            if wordSet.contains(resumeVerb) {
                return addressesSpotify(text) || !musicContextWords.isDisjoint(with: wordSet)
            }
            // Nothing left to search for; otherwise this is a search, not a resume.
            if shared.extractSearchQuery(normalized).isEmpty { return true }
            // A voice command naming Spotify with a play verb, where Ollama found no title:
            // the leftover words are filler ("şimdi de şu anda arkada Spotify'da şarkı aç").
            return natural && addressesSpotify(text)
                && SpotifyRequestParser.cleanOllamaName(parse.title).isEmpty
                && SpotifyRequestParser.cleanOllamaName(parse.artist).isEmpty
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
        case .play: return isResume(text) ? .play : .playLikedSongs
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

    /// "Müziğe devam et", "sürdür": go on with what was paused, not start Liked Songs.
    private static func isResume(_ text: String) -> Bool {
        canonicalizeVerbs(intentWords(normalize(text))).contains(resumeVerb)
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
        spotifyPlaying: Bool = false,
        commandMode: Bool = false
    ) -> ExplicitSpotifyIntent? {
        // The LLM would read Liked Songs as a playlist search and play a stranger's list,
        // and it doesn't know the rule-only intents at all.
        if let rules, rules == .playLikedSongs || rules.isRuleOnly { return rules }
        guard let parse else { return rules }

        guard let rules else {
            if commandMode { return commandIntent(parse, text: text) }
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

    /// A voice-started session ("Jarvis", Vocal Shortcuts) is a request to *do* something,
    /// so the dictation guards — music noun, named item only, Spotify already playing — are
    /// dropped. Evidence still applies: the words themselves must carry the intent (a play
    /// verb for a search, a loudness cue for volume), so plain speech keeps being pasted.
    private static func commandIntent(_ parse: SpotifyRequestParser.OllamaParse, text: String) -> ExplicitSpotifyIntent? {
        let text = repairCommandVerbMishearing(text)
        // "Piyanosal bir şeyler Spotify'da": naming Spotify is the request, verb or not.
        let spotifySearch = parse.intent == .search && addressesSpotify(text)
            && !searchRequest(for: normalize(text), parse: parse).searchQueries.isEmpty
        guard parse.intent != .none, spotifySearch || hasEvidence(for: parse, in: text, natural: true),
              let result = intent(from: parse, text: text) else { return nil }
        owLog("[Spotify] Voice command '\(text)' → \(result)")
        return result
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
    private static let quieterWords: Set<String> = ["kis", "kisar", "kissana", "kisalim", "kisin", "kisabilir", "kisiver", "yukseldi"]
    /// "aç" means louder only next to a volume noun or an amount ("müziği biraz aç");
    /// "müziği aç" alone is resume.
    private static let openWords: Set<String> = ["ac", "acsana", "acar", "acabilir", "aciver"]
    private static let smallAmountWords: Set<String> = ["biraz", "azicik", "azcik", "hafif", "hafifce", "tik"]
    private static let largeAmountWords: Set<String> = ["cok", "asiri", "baya", "bayagi", "epey", "iyice", "fazla"]
    private static let maxVolumePhrases: [String] = ["sonuna kadar", "son ses", "en yuksek", "maksimum", "full"]
    /// Max volume only next to a volume noun; matched as word starts ("seviyeye").
    private static let maxVolumeNounPhrases: [String] = ["sona getir", "sona cek", "sona kadar", "son seviye", "en son seviye"]

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
        guard !lowering else { return nil }
        // Word-bounded, so "son" can't match inside another word.
        let joined = " " + cues.joined(separator: " ") + " "
        func says(_ phrase: String) -> Bool { joined.contains(" " + phrase) }
        if maxVolumePhrases.contains(where: says) { return 100 }
        // "sesi sona getir", "sesi son seviyeye çıkar" (10 Oct 2026, both pasted as dictation):
        // only next to a volume noun, so "listeyi sona getir" stays dictation.
        guard !volumeNouns.isDisjoint(with: cues), maxVolumeNounPhrases.contains(where: says) else { return nil }
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
    /// It also spells "sesi fulle" as "Ses fülle", which Ollama can't tie to "full";
    /// there "fülle"/"fülla"/"füll" can only be "fulle"/"full".
    static func repairVolumeMishearing(_ text: String) -> String {
        let folded = cueWords(normalize(text))
        guard !volumeNouns.isDisjoint(with: folded) || folded.contains(where: { word in naturalTopicStems.contains { word.hasPrefix($0) } })
        else { return text }
        var repaired = text
        if folded.contains(where: { ["kiz", "kizsana"].contains($0) }) {
            repaired = repaired.replacingOccurrences(
                of: "\\b([Kk])[ıi]z(sana)?\\b", with: "$1ıs$2", options: .regularExpression
            )
        }
        if folded.contains(where: { ["fulle", "fulla", "full"].contains($0) }) {
            repaired = repaired
                .replacingOccurrences(of: "\\b([Ff])[üu]ll[ea]\\b", with: "$1ulle", options: .regularExpression)
                .replacingOccurrences(of: "\\b([Ff])üll\\b", with: "$1ull", options: .regularExpression)
        }
        return repaired
    }

    /// Whisper sometimes ends a command with "çalk" ("Eğlenceli bir şeyler çalk"). No Turkish
    /// word ends an utterance that way, so a closing "çalk"/"çalg" can only be "çal".
    static func repairPlayVerbMishearing(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\b([ÇçCc])al[kg]([.!?]*)\\s*$", with: "$1al$2", options: .regularExpression
        )
    }

    /// In a voice session Whisper turns spoken command verbs into past or converb forms
    /// ("Piyano tarzı bir şey açtık Spotify'da", "Piyano müziği açıp Spotify'da": 26 Sep
    /// 2026, both pasted as dictation). Nobody tells Jarvis what they already did, so these
    /// count as the imperative there; dictation never goes through this. It also restores
    /// "Spotify dur" → "durdur", "şarkac" → "şarkı aç" and spelled-out percentages.
    static func repairCommandVerbMishearing(_ text: String) -> String {
        let stems = "[ÇçCc]al|[Aa][çc]|[Dd]urdur|[Kk]apat|[Gg]e[çc]|[Aa]tla|[Kk][ıi]s|[Yy][üu]kselt"
            + "|[Aa]zalt|[Aa]rt[ıi]r|[Dd][üu][şs][üu]r|[Ii]ndir|[Bb]a[şs]lat|[Oo]ynat|[Dd]uraklat"
        var repaired = text
            .replacingOccurrences(
                of: "\\b(\(stems))(?:[dt][ıiuü](?:k|m|n|n[ıiuü]z)?|[ıiuü]p)\\b",
                with: "$1", options: .regularExpression
            )
            .replacingOccurrences(of: "\\b([Çç])ağırsana\\b", with: "$1alsana", options: .regularExpression)
            .replacingOccurrences(of: "\\b([Şş])ark[aı][cç]\\b", with: "$1arkı aç", options: .regularExpression)
            .replacingOccurrences(of: "\\b([Dd])ur([.!?]*)\\s*$", with: "$1urdur$2", options: .regularExpression)
        repaired = digitizeSpelledPercent(repaired)
        return repaired
    }

    /// A voice session's transcript as commands read it: a leading "Hey Jarvis" dropped (a
    /// reply follow-up keeps it: "Hey Javis, sesi son seviyeye çıkar", 10 Oct 2026) and
    /// mangled command verbs repaired.
    static func commandModeText(_ text: String) -> String {
        repairCommandVerbMishearing(WakeWordVerifier.strippingLeadingWakeWord(text))
    }

    /// "sesi yüzde elli yap" → "sesi yüzde 50 yap": volume targets are read as digits.
    static func digitizeSpelledPercent(_ text: String) -> String {
        let tens = ["on": 10, "yirmi": 20, "otuz": 30, "kırk": 40, "elli": 50, "altmış": 60,
                    "yetmiş": 70, "seksen": 80, "doksan": 90, "yüz": 100]
        let units = ["bir": 1, "iki": 2, "üç": 3, "dört": 4, "beş": 5, "altı": 6, "yedi": 7, "sekiz": 8, "dokuz": 9]
        let locale = Locale(identifier: "tr_TR")
        // A number word, optionally with a dative ending ("elliye", "yüze") and punctuation.
        func number(_ word: String, in table: [String: Int]) -> (value: Int, rest: String)? {
            let lower = word.lowercased(with: locale)
            for (name, value) in table where lower.hasPrefix(name) {
                let rest = String(lower.dropFirst(name.count))
                let ending = rest.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
                if ["", "ye", "ya", "e", "a", "'ye", "'ya", "'e", "'a"].contains(ending) { return (value, rest) }
            }
            return nil
        }
        var words = text.components(separatedBy: " ")
        var index = 0
        while index < words.count {
            defer { index += 1 }
            guard words[index].lowercased(with: locale) == "yüzde", index + 1 < words.count else { continue }
            var value = 0, rest = "", end = index + 1
            if let ten = number(words[end], in: tens) {
                value = ten.value; rest = ten.rest; end += 1
                if ten.rest.isEmpty, end < words.count, let unit = number(words[end], in: units) {
                    value += unit.value; rest = unit.rest; end += 1
                }
            } else if let unit = number(words[end], in: units) {
                value = unit.value; rest = unit.rest; end += 1
            } else { continue }
            guard value <= 100 else { continue }
            let suffix = rest.first.map { ".,!?'".contains($0) } ?? true ? rest : "'" + rest
            words.replaceSubrange((index + 1)..<end, with: ["\(value)\(suffix)"])
        }
        return words.joined(separator: " ")
    }

    /// Short, not quoting or negating anything: what a voice-started session sends to Ollama.
    static func isCommandCandidate(_ text: String) -> Bool {
        let normalized = normalize(text)
        return spokenWordCount(normalized) <= maxNaturalWordCount
            && mentionOrNegationWords.isDisjoint(with: Set(intentWords(normalized)))
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
    ///
    /// `commandMode` marks a voice-started session: see `commandIntent`.
    static func isSpotifyCommand(_ transcript: String, ollamaAvailable: Bool = false, commandMode: Bool = false) async -> Bool {
        let heard = repairPlayVerbMishearing(repairVolumeMishearing(transcript))
        let text = commandMode ? commandModeText(heard) : heard
        var rules = explicitIntent(in: text)
        // Only a Jarvis session: with the dictation keys "konuyu sıraya ekle" is text to type.
        if rules == nil, commandMode, let candidate = runtimeCandidate(text) {
            rules = await confirm(candidate)
        }
        if let rules, rules.isRuleOnly || rules == .playLikedSongs {
            owLog("[Spotify] Rules alone: '\(text)' → \(rules)")
            decisionCache.store(rules, for: transcript)
            return true
        }
        // With Jarvis's chat on the cloud, the cloud model parses instead of Ollama, so Gemma
        // stays unloaded; if it fails, the rules and SetFit decide alone.
        let cloud = ChatBackend.selected == .cloud ? CloudLLM.client() : nil
        let llmAvailable = ollamaAvailable || cloud != nil
        // SetFit (Settings › Karar motoru) can read the intent even when Ollama is down.
        let modelAvailable = llmAvailable || SetFitDecider.isActive
        let command = commandMode && rules == nil && modelAvailable && isCommandCandidate(text)
        let promotion = rules == nil && modelAvailable && isPromotionCandidate(text)
        // Cheapest checks first: the word test, then the playback query (which never
        // launches Spotify), and only then Ollama.
        let natural = rules == nil && modelAvailable && isNaturalCandidate(text)
        var spotifyPlaying = false
        if natural {
            spotifyPlaying = await SpotifyController.shared.isPlayingLocally()
        }
        guard rules != nil || command || promotion || (natural && (spotifyPlaying || mentionsVolume(text))) else { return false }

        // Ollama starts at the same time as SetFit, so a search or an unsure SetFit answer costs
        // one Ollama round trip, not SetFit + Ollama. A confident SetFit answer cancels it.
        // A voice session warms the model when it starts, but a cold load still takes
        // several seconds; dictation keeps the short timeout so pasting isn't held up.
        let model = selectedOllamaModel
        let timeout: TimeInterval = commandMode ? 15 : 3
        let llm: Task<SpotifyRequestParser.OllamaParse?, Never>? = if let (client, cloudModel) = cloud {
            Task { await SpotifyRequestParser.queryCloud(transcript: text, client: client, model: cloudModel, timeout: timeout) }
        } else if ollamaAvailable {
            Task { await SpotifyRequestParser.queryOllama(transcript: text, model: model, timeout: timeout) }
        } else {
            nil
        }
        let llmName = cloud == nil ? "Ollama" : "Cloud"
        var parse = SetFitDecider.isActive ? await setFitParse(text, ollamaAvailable: llmAvailable) : nil
        if parse != nil {
            llm?.cancel()
        } else if let llm {
            parse = await llm.value
            if let parse { owLog("[Spotify] \(llmName) parse for '\(text)': \(parse)") }
            // A search SetFit left to the LLM goes ahead with the rule-based split.
            if parse == nil, cloud != nil, SetFitDecider.isActive {
                parse = await setFitParse(text, ollamaAvailable: false)
            }
        }
        let decision = decide(rules: rules, parse: parse, text: text, spotifyPlaying: spotifyPlaying, commandMode: commandMode)
        if let decision { decisionCache.store(decision, for: transcript) }
        return decision != nil
    }

    /// Whether `candidate` is a command right now (see `RuntimeCandidate`).
    private static func confirm(_ candidate: RuntimeCandidate) async -> ExplicitSpotifyIntent? {
        let controller = SpotifyController.shared
        switch candidate {
        case .queue(let request):
            guard !request.searchQueries.isEmpty, await controller.isPlayingLocally() else { return nil }
            return .queue(request)
        case .ownPlaylist(let name):
            guard await controller.ownPlaylist(named: name, writable: false) != nil else { return nil }
            return .playOwnPlaylist(name)
        case .addToPlaylist(let name):
            guard await controller.isPlayingLocally(),
                  await controller.ownPlaylist(named: name, writable: true) != nil else { return nil }
            return .addCurrentTrackToPlaylist(name)
        }
    }

    /// SetFit's intent as an `OllamaParse`, so `decide` applies the same evidence rules to it as
    /// to Ollama's. Nil (→ ask Ollama) when SetFit is off, unsure, or says "search" while
    /// Ollama is up and the rules can't split it: SetFit only classifies, and a bare
    /// "Coldplay Yellow" still needs Ollama's title/artist split.
    /// Without Ollama a search goes ahead with the rule-based split.
    private static func setFitParse(_ text: String, ollamaAvailable: Bool) async -> SpotifyRequestParser.OllamaParse? {
        guard let decision = await SetFitDecider.decide(.spotifyIntent, text: text), decision.confident,
              let intent = SpotifyRequestParser.OllamaIntent(rawValue: decision.label)
        else { return nil }
        if intent == .search && ollamaAvailable && !rulesSplitSearch(text) { return nil }
        return SpotifyRequestParser.OllamaParse(intent: intent)
    }

    /// Whether the rules already split this search from grammar alone (genitive artist,
    /// ablative artist, album or playlist noun, a mood with "bir şeyler"). Ollama only
    /// re-confirms those and costs ~2 s ("Eğlenceli bir şeyler çal", 15 Oct 2026); a kind-less
    /// SetFit parse makes `searchRequest` use the same rules.
    static func rulesSplitSearch(_ text: String) -> Bool {
        SpotifyRequestParser.requestFromRules(normalize(text)).kind != .freeText
    }

    /// The model the user picked in Settings (AppState.ollamaModel, UserDefaults key
    /// "ollamaModel", default LLMCleanup.defaultModel). SpotifyManager is a standalone singleton with no
    /// AppState reference, so it reads the same UserDefaults key directly rather than
    /// hardcoding a model. See ReminderManager's identical `selectedOllamaModel`.
    static var selectedOllamaModel: String {
        UserDefaults.standard.string(forKey: "ollamaModel") ?? LLMCleanup.defaultModel
    }

    private static let decisionCache = DecisionCache()

    /// Whether media paused for a voice command may play again once `text` was handled.
    /// Playback commands decide what plays next ("durdur" keeps it paused, "X çal" starts
    /// something else); volume, track info and like leave the paused media as it was.
    /// Must be called before `handleCommand`, which consumes the cached decision.
    static func resumesPausedMedia(afterCommand text: String) -> Bool {
        guard let intent = decisionCache.peek(for: text) ?? explicitIntent(in: text) else { return true }
        switch intent {
        // Resuming here would pull the music back from the phone.
        case .transferPlayback: return false
        default: return !intent.replacesPlayback
        }
    }

    /// Whether Jarvis says the command's own result (see `ExplicitSpotifyIntent.speaksResult`).
    /// Like `resumesPausedMedia`, call it before `handleCommand`.
    static func speaksResult(afterCommand text: String) -> Bool {
        (decisionCache.peek(for: text) ?? explicitIntent(in: text))?.speaksResult ?? false
    }

    /// Whether a failure is said aloud rather than the words typed out: these are commands
    /// by their wording alone, so typing them would only hide that nothing happened.
    static func speaksFailure(afterCommand text: String) -> Bool {
        guard let intent = decisionCache.peek(for: text) ?? explicitIntent(in: text) else { return false }
        return intent.speaksResult || intent.isRuleOnly || intent == .playLikedSongs
    }

    /// Whether `text` starts the user's Liked Songs, so Jarvis says so instead of a plain ack.
    /// Like `resumesPausedMedia`, call it before `handleCommand`.
    static func playsLikedSongs(afterCommand text: String) -> Bool {
        (decisionCache.peek(for: text) ?? explicitIntent(in: text)) == .playLikedSongs
    }

    /// Holds the decision for the most recent transcript between `isSpotifyCommand` and
    /// `handleCommand`, which AppState calls back to back with the same text.
    private final class DecisionCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (text: String, intent: ExplicitSpotifyIntent)?

        func store(_ intent: ExplicitSpotifyIntent, for text: String) {
            lock.withLock { entry = (text, intent) }
        }

        func peek(for text: String) -> ExplicitSpotifyIntent? {
            lock.withLock { entry?.text == text ? entry?.intent : nil }
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
    ///
    /// `recordUndo` saves what the command changes first, so `rerunIfCorrected` can undo it.
    func handleCommand(text: String, targetApp: NSRunningApplication? = nil, recordUndo: Bool = false) async -> Bool {
        let activeApp = targetApp ?? NSWorkspace.shared.frontmostApplication
        // The decision made by `isSpotifyCommand`; without one (called directly), only the
        // rule gate can authorize a side effect.
        guard let intent = Self.decisionCache.take(for: text) ?? Self.explicitIntent(in: text) else {
            owLog("[SpotifyManager] Refused non-explicit Spotify intent: '\(text)'")
            return false
        }
        owLog("[SpotifyManager] Handling command: '\(text)' → \(intent)")

        let controller = SpotifyController.shared
        var playerBefore: SpotifyController.PlayerSnapshot?
        if recordUndo, intent.replacesPlayback {
            playerBefore = controller.playerSnapshot()
        }
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
        case .playLikedSongs:
            result = await controller.playLikedSongs()
        case .setShuffle(let on):
            result = await controller.setShuffle(on)
        case .setRepeat(let mode):
            result = await controller.setRepeat(mode)
        case .seek(let seek):
            result = await controller.seek(seek)
        case .queue(let request):
            result = await controller.queue(request)
        case .unlikeCurrentTrack:
            result = await controller.unlikeCurrentTrack()
        case .setSpotifyVolume(let volume):
            result = await controller.setVolume(volume)
        case .playOwnPlaylist(let name):
            result = await controller.playOwnPlaylist(named: name)
        case .addCurrentTrackToPlaylist(let name):
            result = await controller.addCurrentTrack(toPlaylistNamed: name)
        case .playSavedAlbum:
            result = await controller.playSavedAlbum()
        case .playFollowedArtist:
            result = await controller.playFollowedArtist()
        case .playRecentTrack:
            result = await controller.playRecentTrack()
        case .transferPlayback(let device):
            result = await controller.transferPlayback(to: device)
        case .question(let question):
            result = await controller.answer(question)
        case .sleepTimer(let seconds):
            result = startSleepTimer(seconds)
        case .cancelSleepTimer:
            result = cancelSleepTimer()
        }
        lastResult.withLock { $0 = (text, result) }

        switch intent {
        case .setVolume, .adjustVolume:
            sendNotification(title: "🔊 Ses", body: result.message)
        default:
            sendNotification(title: "🎵 Spotify", body: result.message)
        }

        if result.succeeded {
            keepInBackground(targetApp: activeApp)
        }
        if recordUndo {
            let undo: CommandUndo?
            switch intent {
            case .setVolume, .adjustVolume:
                undo = SystemVolume.lastChange.map { .volume(from: $0.from, to: $0.to) }
            case _ where intent.replacesPlayback:
                undo = playerBefore.map { .player($0) }
            case .currentTrack, .question:
                undo = .nothing
            default:
                // Unliking could remove a song the user had liked long before; the other
                // changes (shuffle, a playlist, another device) have no snapshot to restore.
                undo = nil
            }
            lastCommand.withLock { $0 = result.succeeded ? LastCommand(text: text, intent: intent, undo: undo, date: Date()) : nil }
        }

        // Refusals and failures are not successful handling. AppState will preserve the
        // transcript through the normal dictation fallback instead of swallowing it as
        // though Spotify acted.
        return result.succeeded
    }

    /// The message of the last `handleCommand(text:)`, for Jarvis to say.
    private let lastResult = OSAllocatedUnfairLock<(text: String, result: SpotifyActionResult)?>(initialState: nil)

    func takeResultMessage(for text: String) -> String? {
        lastResult.withLock { state in
            defer { state = nil }
            return state?.text == text ? state?.result.message : nil
        }
    }

    // MARK: - Sleep timer

    private let sleepTimer = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    private func startSleepTimer(_ seconds: Int) -> SpotifyActionResult {
        let task = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            let result = await SpotifyController.shared.pause()
            owLog("[SpotifyManager] Sleep timer fired: \(result.message)")
            self.sleepTimer.withLock { $0 = nil }
        }
        sleepTimer.withLock { old in
            old?.cancel()
            old = task
        }
        owLog("[SpotifyManager] Sleep timer: pause in \(seconds) s")
        return .success("Müzik \(SpotifyController.spokenDuration(seconds)) sonra kapanacak")
    }

    private func cancelSleepTimer() -> SpotifyActionResult {
        let task = sleepTimer.withLock { old -> Task<Void, Never>? in
            defer { old = nil }
            return old
        }
        guard let task else { return .failure("kurulu bir müzik zamanlayıcısı yok") }
        task.cancel()
        return .success("Müzik zamanlayıcısı iptal edildi")
    }

    // MARK: - Re-run after correction

    /// How to take back a command so a corrected one can replace it.
    private enum CommandUndo {
        case volume(from: Float, to: Float)
        case player(SpotifyController.PlayerSnapshot)
        /// Nothing changed (e.g. "ne çalıyor").
        case nothing
    }

    /// The last command run with `recordUndo`, and how to undo it (nil: it can't be undone).
    private let lastCommand = OSAllocatedUnfairLock<LastCommand?>(initialState: nil)

    private struct LastCommand {
        let text: String
        let intent: ExplicitSpotifyIntent
        let undo: CommandUndo?
        let date: Date
    }

    /// A correction arriving later than this leaves the command alone: by then the user may
    /// have changed the song or volume by hand, and a restore would overwrite that.
    private static let correctionWindow: TimeInterval = 15

    /// Called once `corrected` (the cleaned version of `original`) was confirmed as a command
    /// by `isSpotifyCommand`. If it asks for something else than what `original` did, undoes
    /// that first and runs the corrected command. Returns whether it ran.
    func rerunIfCorrected(original: String, corrected: String, targetApp: NSRunningApplication?) async -> Bool {
        guard let newIntent = Self.decisionCache.peek(for: corrected) else { return false }
        guard let last = lastCommand.withLock({ state -> LastCommand? in
            defer { state = nil }
            return state
        }), last.text == original, Date().timeIntervalSince(last.date) < Self.correctionWindow else {
            _ = Self.decisionCache.take(for: corrected)
            return false
        }
        guard newIntent != last.intent else {
            owLog("[SpotifyManager] Correction '\(corrected)' asks for the same command, nothing to redo")
            _ = Self.decisionCache.take(for: corrected)
            return false
        }
        if Self.correctionNeedsUndo(of: last.intent, before: newIntent) {
            guard let undo = last.undo, undoCommand(undo) else {
                owLog("[SpotifyManager] Correction '\(corrected)' → \(newIntent), but '\(original)' can't be undone; keeping it")
                _ = Self.decisionCache.take(for: corrected)
                return false
            }
            owLog("[SpotifyManager] Undid '\(original)' (\(last.intent)); running corrected '\(corrected)'")
        } else {
            owLog("[SpotifyManager] Corrected '\(corrected)' replaces '\(original)' outright")
        }
        return await handleCommand(text: corrected, targetApp: targetApp)
    }

    /// Whether `old` must be undone before its correction `new` runs. A search replaces what
    /// plays and an absolute volume replaces the level, so undoing first would only make the
    /// old song or level flash back; everything else would stack ("biraz kıs" twice).
    static func correctionNeedsUndo(of old: ExplicitSpotifyIntent, before new: ExplicitSpotifyIntent) -> Bool {
        switch (old, new) {
        case (.search, .search), (.setVolume, .setVolume), (.adjustVolume, .setVolume): return false
        default: return true
        }
    }

    private func undoCommand(_ undo: CommandUndo) -> Bool {
        switch undo {
        case .volume(let from, let to): return SystemVolume.revert(from: from, to: to)
        case .player(let snapshot): return SpotifyController.shared.restore(snapshot)
        case .nothing: return true
        }
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
