import Foundation

/// What to search Spotify for: a song, an artist, an album or a playlist, with the
/// artist split out where the transcript allows it.
struct SpotifySearchRequest: Equatable, Sendable {
    enum Kind: String, Sendable {
        case track
        case artist
        case album
        case playlist
        case freeText
    }

    let kind: Kind
    /// Song, album or playlist name (for a playlist, possibly a mood such as "sakin").
    let title: String
    let artist: String
    /// The rule-based residue of the whole command. Always the last query tried, so a
    /// wrong split can never do worse than searching everything the user said.
    let freeText: String

    static func freeText(_ query: String) -> SpotifySearchRequest {
        SpotifySearchRequest(kind: .freeText, title: "", artist: "", freeText: query)
    }

    /// Which Spotify catalog `searchQueries` are meant for.
    var catalogType: SpotifyWebAPI.SearchType {
        switch kind {
        case .track, .freeText: return .track
        case .artist: return .artist
        case .album: return .album
        case .playlist: return .playlist
        }
    }

    /// Queries (for `catalogType`) to try in order until one returns a result. Field
    /// filters (`track:`, `artist:`, `album:`) pin down "Tarkan'ın Şımarık'ı" to that exact
    /// song instead of whatever ranks first for the loose words. Track searches end with
    /// the free text; for the other kinds the controller falls back to a track search of
    /// the free text itself.
    var searchQueries: [String] {
        var queries: [String]
        switch kind {
        case .track where !artist.isEmpty:
            queries = ["track:\"\(title)\" artist:\"\(artist)\"", "\(artist) \(title)", freeText]
        case .track:
            queries = [title, freeText]
        case .artist:
            queries = [artist]
        case .album where !artist.isEmpty:
            queries = ["album:\"\(title)\" artist:\"\(artist)\"", "\(artist) \(title)"]
        case .album, .playlist:
            queries = [title]
        case .freeText:
            queries = [freeText]
        }
        var seen = Set<String>()
        return queries
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Human-readable form for notifications ("Tarkan — Şımarık").
    var displayText: String {
        switch kind {
        case .track, .album:
            return artist.isEmpty ? title : "\(artist) — \(title)"
        case .playlist:
            return title
        case .artist:
            return artist
        case .freeText:
            return freeText
        }
    }
}

/// Turns a Spotify search command into a `SpotifySearchRequest`, via Ollama when it is
/// available and deterministic Turkish-suffix rules otherwise.
///
/// Ollama only ever *refines* a command the deterministic gate in `SpotifyManager` has
/// already accepted as a search: it cannot turn dictation into a command (its
/// `is_music_command` can only veto), and every name it returns must be grounded in the
/// transcript (`isGrounded`) or the rule-based result is used instead.
enum SpotifyRequestParser {

    // MARK: - Rules

    /// Words stripped from a search-query residue. Filtered as whole words (not substring
    /// replacement) so we don't mangle artist/song names that happen to contain these
    /// letter sequences (e.g. "açık", "ağaç").
    // "şarkı ..." inflections are stripped as whole words too — the trade-off is that a
    // track literally titled just one of these words (e.g. "Şarkı Söylemek") would have
    // that word stripped from its own search query. Accepted trade-off per product call.
    static let searchJunkWords: Set<String> = Set([
        "spotifyda", "spotifydan", "spotifya", "spotify",
        "bana", "lütfen", "şarkısını", "şarkısı", "parçasını", "müziğini",
        "çal", "aç", "oynat", "başlat", "dinlet", "play", "adlı",
        "şarkıyı", "şarkıya", "şarkısına", "şarkısıyla", "şarkı", "şarkılar",
        "şarkıları", "şarkılarını", "parçayı", "parça", "müzik", "müziği",
        "hadi", "bakalım", "bakalim"
    ]).union(SpotifyManager.playVerbAliases.keys)
     .union(SpotifyManager.questionFormPlayVerbs.keys)
     .union(SpotifyManager.questionParticles)

    /// Genitive ("Tarkan'ın Şımarık şarkısı") marks the word as the artist of what follows;
    /// ablative ("Sezen Aksu'dan bir şarkı") means "something by this artist".
    private static let genitiveSuffixes: Set<String> = ["ın", "in", "un", "ün", "nın", "nin", "nun", "nün"]
    private static let ablativeSuffixes: Set<String> = ["dan", "den", "tan", "ten"]

    /// Filler that can follow an ablative artist without being part of a song title.
    private static let vagueObjectWords: Set<String> = ["bir", "şey", "şeyler", "birşey", "birşeyler", "bişey", "bişeyler"]

    /// Words for an album / a playlist ("… albümünü aç", "spor listesi aç"). Removed from
    /// the title; they decide the request kind.
    static let albumNouns: Set<String> = [
        "albüm", "albümü", "albümünü", "albümden", "albümünden", "album", "albumu", "albumunu"
    ]
    static let playlistNouns: Set<String> = [
        "liste", "listesi", "listesini", "listeyi", "listeden", "listesinden",
        "playlist", "playlisti", "playlistini", "playlistten"
    ]

    private struct Word {
        let stem: String
        let suffix: String?
    }

    /// Splits on whitespace and cuts the case suffix after an apostrophe, so
    /// "Tarkan'ın" searches as "tarkan" rather than the never-matching "tarkanın".
    private static func words(_ residue: String) -> [Word] {
        residue
            .lowercased(with: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "`", with: "'")
            .split(whereSeparator: { $0.isWhitespace })
            .map { raw -> Word in
                let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\""))
                let parts = token.split(separator: "'", maxSplits: 1, omittingEmptySubsequences: false)
                let stem = String(parts[0])
                let suffix = parts.count > 1 ? String(parts[1]) : nil
                return Word(stem: stem, suffix: suffix?.isEmpty == true ? nil : suffix)
            }
            .filter { !$0.stem.isEmpty }
    }

    /// The residue of a search command with command/filler words removed.
    static func freeTextQuery(_ residue: String) -> String {
        words(residue)
            .map(\.stem)
            .filter { !searchJunkWords.contains($0) }
            .joined(separator: " ")
    }

    /// Deterministic fallback used when Ollama is unavailable, times out, or returns a
    /// name that isn't in the transcript.
    static func requestFromRules(_ residue: String) -> SpotifySearchRequest {
        let all = words(residue)
        let isPlaylist = all.contains { playlistNouns.contains($0.stem) }
        let isAlbum = !isPlaylist && all.contains { albumNouns.contains($0.stem) }

        let kept = all.filter { word in
            !searchJunkWords.contains(word.stem)
                && !albumNouns.contains(word.stem)
                && !playlistNouns.contains(word.stem)
                // "çalma listesi" = playlist; "çalma" is part of the noun, not a title word.
                && !(isPlaylist && word.stem == "çalma")
        }
        let freeText = kept.map(\.stem).joined(separator: " ")
        let meaningful = kept.filter { !vagueObjectWords.contains($0.stem) }.map(\.stem).joined(separator: " ")

        if isPlaylist {
            return meaningful.isEmpty
                ? .freeText(freeText)
                : SpotifySearchRequest(kind: .playlist, title: meaningful, artist: "", freeText: freeText)
        }

        if let index = kept.firstIndex(where: { $0.suffix.map(genitiveSuffixes.contains) == true }),
           index + 1 < kept.count {
            let artist = kept[...index].map(\.stem).joined(separator: " ")
            let title = kept[(index + 1)...].map(\.stem).joined(separator: " ")
            return SpotifySearchRequest(kind: isAlbum ? .album : .track, title: title, artist: artist, freeText: freeText)
        }

        if let index = kept.firstIndex(where: { $0.suffix.map(ablativeSuffixes.contains) == true }),
           kept[(index + 1)...].allSatisfy({ vagueObjectWords.contains($0.stem) }) {
            let artist = kept[...index].map(\.stem).joined(separator: " ")
            return SpotifySearchRequest(kind: .artist, title: "", artist: artist, freeText: freeText)
        }

        if isAlbum, !meaningful.isEmpty {
            return SpotifySearchRequest(kind: .album, title: meaningful, artist: "", freeText: freeText)
        }

        // "sakin bir şeyler çal": a mood plus a vague object is a playlist search.
        if kept.contains(where: { vagueObjectWords.contains($0.stem) && $0.stem != "bir" }), !meaningful.isEmpty {
            return SpotifySearchRequest(kind: .playlist, title: meaningful, artist: "", freeText: freeText)
        }

        return .freeText(freeText)
    }

    // MARK: - Ollama

    struct OllamaParse: Equatable, Sendable {
        let isMusicCommand: Bool
        let kind: SpotifySearchRequest.Kind?
        let title: String
        let artist: String
    }

    /// Combines Ollama's split with the rule-based one. Any name Ollama returns that does
    /// not appear in the transcript (a typo like "şmarık" for "Şımarık", or an invented
    /// "correction") discards the whole Ollama result: small models are good at finding
    /// the boundaries between names but must never be trusted to spell them.
    static func request(from parse: OllamaParse, transcript: String, rules: SpotifySearchRequest) -> SpotifySearchRequest {
        let title = cleanOllamaName(parse.title)
        let artist = cleanOllamaName(parse.artist)
        // "Barış Manço çalsana" came back with the same name as both title and artist.
        let kind: SpotifySearchRequest.Kind? = (parse.kind == .track || parse.kind == .album)
            && !artist.isEmpty && foldedWords(title) == foldedWords(artist) ? .artist : parse.kind

        // "Mor ve Ötesi Bir Derdim Var" came back as title "Mor ve ötesi Bir Derdim Var",
        // artist "Bir Derdim Var": one field swallowing the other means the split is wrong.
        if kind != .artist, !title.isEmpty, !artist.isEmpty {
            let titleWords = foldedWords(title), artistWords = foldedWords(artist)
            if Set(artistWords).isSubset(of: titleWords) || Set(titleWords).isSubset(of: artistWords) {
                owLog("[SpotifyParser] Ollama title/artist overlap, using rules: \(parse)")
                return rules
            }
        }

        let result: SpotifySearchRequest
        switch kind {
        case .track? where !title.isEmpty, .album? where !title.isEmpty:
            result = SpotifySearchRequest(kind: kind!, title: title, artist: artist, freeText: rules.freeText)
        case .playlist? where !title.isEmpty:
            result = SpotifySearchRequest(kind: .playlist, title: title, artist: "", freeText: rules.freeText)
        case .artist? where !artist.isEmpty:
            result = SpotifySearchRequest(kind: .artist, title: "", artist: artist, freeText: rules.freeText)
        default:
            return rules
        }

        guard isGrounded(result.title, in: transcript), isGrounded(result.artist, in: transcript) else {
            owLog("[SpotifyParser] Ollama split not grounded in transcript, using rules: \(parse)")
            return rules
        }

        // An artist-only answer must account for everything the user asked for. llama3.2:3b
        // has labeled "Coldplay Yellow" as just the artist, which would play a random
        // Coldplay song; leftover content words mean a title was dropped.
        if result.kind == .artist {
            let artistWords = foldedWords(result.artist)
            let vague = Set(vagueObjectWords.flatMap(foldedWords))
            let leftover = foldedWords(rules.freeText).filter { word in
                !vague.contains(word) && !artistWords.contains { word.hasPrefix($0) }
            }
            if !leftover.isEmpty {
                owLog("[SpotifyParser] Ollama artist-only split drops \(leftover), using rules: \(parse)")
                return rules
            }
        }
        return result
    }

    /// Removes what small models leak into names: stray JSON punctuation ("Manga'}"), a
    /// trailing Turkish case suffix after an apostrophe, and command/collection words
    /// ("çalma listesi" returned as a playlist's name).
    static func cleanOllamaName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "'’&.-"))
        let filtered = String(String.UnicodeScalarView(raw.unicodeScalars.filter(allowed.contains)))
        let noise = searchJunkWords.union(albumNouns).union(playlistNouns).union(["çalma"])
        return filtered
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { token -> String? in
                let stem = token.split(whereSeparator: { $0 == "'" || $0 == "’" }).first.map(String.init) ?? ""
                guard !stem.isEmpty,
                      !noise.contains(stem.lowercased(with: Locale(identifier: "tr_TR"))) else { return nil }
                return stem
            }
            .joined(separator: " ")
    }

    /// True when every word of `value` starts a word of `transcript`, compared without
    /// case or diacritics. Prefix matching lets "Tarkan" match "Tarkan'ın" while still
    /// rejecting anything the transcript doesn't contain. Dropped words are allowed
    /// ("Mor Ötesi" for "Mor ve Ötesi"); the free-text query still covers those.
    static func isGrounded(_ value: String, in transcript: String) -> Bool {
        let transcriptWords = foldedWords(transcript)
        return foldedWords(value).allSatisfy { word in
            transcriptWords.contains { $0.hasPrefix(word) }
        }
    }

    static func foldedWords(_ text: String) -> [String] {
        text
            .lowercased(with: Locale(identifier: "tr_TR"))
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static let ollamaSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "is_music_command": ["type": "boolean"],
            "type": ["type": "string", "enum": ["track", "artist", "album", "playlist", "none"]],
            "title": ["type": "string"],
            "artist": ["type": "string"]
        ],
        "required": ["is_music_command", "type", "title", "artist"]
    ]

    private static func ollamaPrompt(_ transcript: String) -> String {
        let quoted = (try? String(data: JSONSerialization.data(withJSONObject: [transcript]), encoding: .utf8))
            .map { String($0.dropFirst().dropLast()) } ?? "\"\(transcript)\""
        return """
            You extract Spotify requests from Turkish voice transcripts. Return JSON only.
            - is_music_command: true only if the user is asking to play music / control Spotify. Ordinary sentences are false.
            - type: "track" if a specific song is named, "artist" if only a singer/band is named, "album" if an album is requested (albüm), "playlist" if a playlist (liste, çalma listesi, playlist) or a mood/genre ("sakin bir şeyler", "hareketli şarkılar") is requested, "none" otherwise (plain play/pause/next).
            - title: the song, album or playlist name, or the mood words, exactly as spoken, without Turkish suffixes or filler words (şarkısını, albümünü, listesini, çal, aç, bana, lütfen, bir, şeyler). Empty if none.
            - artist: the singer/band exactly as spoken, with the Turkish case suffix removed ('ın, 'nin, 'dan, 'den, ...). Empty if none.
            Never invent, translate or correct names; copy them from the transcript.

            Examples:
            "Spotify'da Tarkan'ın Şımarık şarkısını çal" -> {"is_music_command":true,"type":"track","title":"Şımarık","artist":"Tarkan"}
            "Sezen Aksu'dan bir şarkı aç" -> {"is_music_command":true,"type":"artist","title":"","artist":"Sezen Aksu"}
            "Spotify'da Coldplay Yellow çal" -> {"is_music_command":true,"type":"track","title":"Yellow","artist":"Coldplay"}
            "Spotify'da Bohemian Rhapsody çal" -> {"is_music_command":true,"type":"track","title":"Bohemian Rhapsody","artist":""}
            "Spotify'da Tarkan'ın Karma albümünü aç" -> {"is_music_command":true,"type":"album","title":"Karma","artist":"Tarkan"}
            "Spotify'da sakin bir şeyler çal" -> {"is_music_command":true,"type":"playlist","title":"sakin","artist":""}
            "Spotify'da spor listesi aç" -> {"is_music_command":true,"type":"playlist","title":"spor","artist":""}
            "müziği durdur" -> {"is_music_command":true,"type":"none","title":"","artist":""}
            "bu projeyi yarın başlatacağız" -> {"is_music_command":false,"type":"none","title":"","artist":""}

            Transcript: \(quoted)
            """
    }

    /// One structured-output call (Ollama `format` = JSON schema). Returns nil on any
    /// failure — timeout, model missing, malformed output — so callers fall back to rules.
    static func queryOllama(transcript: String, model: String) async -> OllamaParse? {
        guard let url = URL(string: "http://localhost:11434/api/generate") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3

        let body: [String: Any] = [
            "model": model,
            "prompt": ollamaPrompt(transcript),
            "stream": false,
            // qwen3 (and other "thinking" models) otherwise spend the token budget on a
            // <think> block and leave "response" empty. See ReminderManager.
            "think": false,
            "keep_alive": LLMCleanup.keepAlive,
            "format": ollamaSchema,
            "options": [
                "temperature": 0.0,
                "num_predict": 100
            ]
        ]
        guard let requestData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = requestData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = envelope["response"] as? String else { return nil }
            return decodeOllamaResponse(responseText)
        } catch {
            owLog("[SpotifyParser] Ollama request failed: \(error)")
            return nil
        }
    }

    static func decodeOllamaResponse(_ text: String) -> OllamaParse? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isMusicCommand = json["is_music_command"] as? Bool else { return nil }
        let kind: SpotifySearchRequest.Kind?
        switch json["type"] as? String {
        case "track": kind = .track
        case "artist": kind = .artist
        case "album": kind = .album
        case "playlist": kind = .playlist
        default: kind = nil
        }
        return OllamaParse(
            isMusicCommand: isMusicCommand,
            kind: kind,
            title: (json["title"] as? String) ?? "",
            artist: (json["artist"] as? String) ?? ""
        )
    }
}
