import XCTest
@testable import OpenWhisper

/// Pure parsing tests — no Ollama or Spotify calls.
final class SpotifyRequestParserTests: XCTestCase {

    // MARK: - Rules

    func testGenitiveSplitsArtistAndTrack() {
        let request = SpotifyRequestParser.requestFromRules("spotify'da tarkan'ın şımarık şarkısını çal")
        XCTAssertEqual(request.kind, .track)
        XCTAssertEqual(request.artist, "tarkan")
        XCTAssertEqual(request.title, "şımarık")
        XCTAssertEqual(request.freeText, "tarkan şımarık")
    }

    func testMultiWordArtistBeforeGenitive() {
        let request = SpotifyRequestParser.requestFromRules("spotify'da müslüm gürses'in affet şarkısını aç")
        XCTAssertEqual(request.kind, .track)
        XCTAssertEqual(request.artist, "müslüm gürses")
        XCTAssertEqual(request.title, "affet")
    }

    func testAblativeWithVagueObjectIsArtistOnly() {
        let request = SpotifyRequestParser.requestFromRules("sezen aksu'dan bir şarkı çal")
        XCTAssertEqual(request.kind, .artist)
        XCTAssertEqual(request.artist, "sezen aksu")
    }

    func testTypographicApostropheIsHandled() {
        let request = SpotifyRequestParser.requestFromRules("spotify’da tarkan’ın şımarık şarkısını çal")
        XCTAssertEqual(request.artist, "tarkan")
        XCTAssertEqual(request.title, "şımarık")
    }

    func testNoSuffixFallsBackToFreeText() {
        let request = SpotifyRequestParser.requestFromRules("spotify'da duman bu akşam çal")
        XCTAssertEqual(request, .freeText("duman bu akşam"))
    }

    func testFreeTextQueryStripsCaseSuffixInsteadOfGluingIt() {
        XCTAssertEqual(SpotifyRequestParser.freeTextQuery("tarkan'ın şımarık şarkısını çal"), "tarkan şımarık")
    }

    func testAlbumWithGenitiveArtist() {
        let request = SpotifyRequestParser.requestFromRules("spotify'da tarkan'ın karma albümünü aç")
        XCTAssertEqual(request.kind, .album)
        XCTAssertEqual(request.artist, "tarkan")
        XCTAssertEqual(request.title, "karma")
        XCTAssertEqual(request.searchQueries, ["album:\"karma\" artist:\"tarkan\"", "tarkan karma"])
    }

    func testPlaylistNoun() {
        let request = SpotifyRequestParser.requestFromRules("spotify'da spor listesi aç")
        XCTAssertEqual(request.kind, .playlist)
        XCTAssertEqual(request.title, "spor")
        XCTAssertEqual(request.catalogType, .playlist)
    }

    func testCalmaListesiIsAPlaylistNotATitleWord() {
        let request = SpotifyRequestParser.requestFromRules("spotify'da rock çalma listesini aç")
        XCTAssertEqual(request.kind, .playlist)
        XCTAssertEqual(request.title, "rock")
    }

    func testMoodWithVagueObjectIsPlaylist() {
        let request = SpotifyRequestParser.requestFromRules("spotify'da sakin bir şeyler çal")
        XCTAssertEqual(request.kind, .playlist)
        XCTAssertEqual(request.title, "sakin")
    }

    func testVerbAliasesAreNotSearchedFor() {
        XCTAssertEqual(SpotifyRequestParser.freeTextQuery("spotify'da barış manço çalsana"), "barış manço")
        XCTAssertEqual(SpotifyRequestParser.freeTextQuery("spotify'da tarkan'ı çalar mısın"), "tarkan")
    }

    // MARK: - Query order

    func testSearchQueriesGoFromSpecificToFreeText() {
        let request = SpotifySearchRequest(kind: .track, title: "Şımarık", artist: "Tarkan", freeText: "tarkan şımarık")
        XCTAssertEqual(request.searchQueries, [
            "track:\"Şımarık\" artist:\"Tarkan\"",
            "Tarkan Şımarık",
        ])
    }

    func testArtistQueries() {
        let request = SpotifySearchRequest(kind: .artist, title: "", artist: "Teoman", freeText: "teoman bir şey")
        XCTAssertEqual(request.catalogType, .artist)
        XCTAssertEqual(request.searchQueries, ["Teoman"])
    }

    // MARK: - Ollama grounding

    private let transcript = "Spotify'da Tarkan'ın Şımarık şarkısını çal"
    private var rules: SpotifySearchRequest { SpotifyRequestParser.requestFromRules(transcript.lowercased()) }

    func testGroundedOllamaSplitIsUsed() {
        let parse = SpotifyRequestParser.OllamaParse(intent: .search, kind: .track, title: "Şımarık", artist: "Tarkan")
        let request = SpotifyRequestParser.request(from: parse, transcript: transcript, rules: rules)
        XCTAssertEqual(request.title, "Şımarık")
        XCTAssertEqual(request.artist, "Tarkan")
    }

    /// Real llama3.2:3b output for this transcript dropped a letter.
    func testMisspelledOllamaNameFallsBackToRules() {
        let parse = SpotifyRequestParser.OllamaParse(intent: .search, kind: .track, title: "şmarık", artist: "Tarkan")
        XCTAssertEqual(SpotifyRequestParser.request(from: parse, transcript: transcript, rules: rules), rules)
    }

    func testInventedOllamaNameFallsBackToRules() {
        let parse = SpotifyRequestParser.OllamaParse(intent: .search, kind: .track, title: "Kuzu Kuzu", artist: "Tarkan")
        XCTAssertEqual(SpotifyRequestParser.request(from: parse, transcript: transcript, rules: rules), rules)
    }

    /// Real llama3.2:3b output: the song title was dropped.
    func testArtistOnlySplitThatDropsATitleFallsBackToRules() {
        let text = "Spotify'da Coldplay Yellow çal"
        let rules = SpotifyRequestParser.requestFromRules(text.lowercased())
        let parse = SpotifyRequestParser.OllamaParse(intent: .search, kind: .artist, title: "", artist: "Coldplay")
        XCTAssertEqual(SpotifyRequestParser.request(from: parse, transcript: text, rules: rules), .freeText("coldplay yellow"))
    }

    func testArtistOnlySplitWithOnlyFillerLeftIsKept() {
        let text = "Sezen Aksu'dan bir şarkı çal"
        let rules = SpotifyRequestParser.requestFromRules(text.lowercased(with: Locale(identifier: "tr_TR")))
        let parse = SpotifyRequestParser.OllamaParse(intent: .search, kind: .artist, title: "", artist: "Sezen Aksu")
        let request = SpotifyRequestParser.request(from: parse, transcript: text, rules: rules)
        XCTAssertEqual(request.kind, .artist)
        XCTAssertEqual(request.artist, "Sezen Aksu")
    }

    func testOllamaNoneKindKeepsRules() {
        let parse = SpotifyRequestParser.OllamaParse(intent: .search, kind: nil, title: "", artist: "")
        XCTAssertEqual(SpotifyRequestParser.request(from: parse, transcript: transcript, rules: rules), rules)
    }

    func testGroundingIgnoresCaseAndDiacriticsButNotLetters() {
        XCTAssertTrue(SpotifyRequestParser.isGrounded("Mor Ötesi", in: "spotify'da mor ve ötesi bir derdim var çal"))
        XCTAssertTrue(SpotifyRequestParser.isGrounded("", in: "anything"))
        XCTAssertFalse(SpotifyRequestParser.isGrounded("şmarık", in: transcript))
    }

    func testGroundedOllamaPlaylistIsUsed() {
        let text = "Spotify'da sakin bir şeyler çal"
        let rules = SpotifyRequestParser.requestFromRules(text.lowercased())
        let parse = SpotifyRequestParser.OllamaParse(intent: .search, kind: .playlist, title: "sakin", artist: "")
        let request = SpotifyRequestParser.request(from: parse, transcript: text, rules: rules)
        XCTAssertEqual(request.kind, .playlist)
        XCTAssertEqual(request.title, "sakin")
    }

    /// A translated mood ("calm" for "sakin") is not in the transcript, so rules win.
    func testTranslatedOllamaPlaylistFallsBackToRules() {
        let text = "Spotify'da sakin bir şeyler çal"
        let rules = SpotifyRequestParser.requestFromRules(text.lowercased())
        let parse = SpotifyRequestParser.OllamaParse(intent: .search, kind: .playlist, title: "calm", artist: "")
        XCTAssertEqual(SpotifyRequestParser.request(from: parse, transcript: text, rules: rules), rules)
    }

    /// Real llama3.2:3b outputs.
    func testOllamaNameCleanup() {
        XCTAssertEqual(SpotifyRequestParser.cleanOllamaName("Manga'}"), "Manga")
        XCTAssertEqual(SpotifyRequestParser.cleanOllamaName("çalma listesi"), "")
        XCTAssertEqual(SpotifyRequestParser.cleanOllamaName("Tarkan'ın"), "Tarkan")
        XCTAssertEqual(SpotifyRequestParser.cleanOllamaName("Guns N' Roses"), "Guns N Roses")
    }

    func testSameTitleAndArtistBecomesArtist() {
        let text = "Spotify'da Barış Manço çalsana"
        let rules = SpotifyRequestParser.requestFromRules(text.lowercased())
        let parse = SpotifyRequestParser.OllamaParse(intent: .search, kind: .track, title: "Barış Manço", artist: "Barış Manço")
        let request = SpotifyRequestParser.request(from: parse, transcript: text, rules: rules)
        XCTAssertEqual(request.kind, .artist)
        XCTAssertEqual(request.artist, "Barış Manço")
    }

    func testCollectionNounAsPlaylistTitleFallsBackToRules() {
        let text = "Rock çalma listesini aç"
        let rules = SpotifyRequestParser.requestFromRules(text.lowercased())
        let parse = SpotifyRequestParser.OllamaParse(intent: .search, kind: .playlist, title: "çalma listesi", artist: "")
        XCTAssertEqual(SpotifyRequestParser.request(from: parse, transcript: text, rules: rules), rules)
        XCTAssertEqual(rules.title, "rock")
    }

    /// Real llama3.2:3b output: artist and title swapped/overlapping.
    func testOverlappingTitleAndArtistFallBackToRules() {
        let text = "Spotify'da Mor ve Ötesi Bir Derdim Var çal"
        let rules = SpotifyRequestParser.requestFromRules(text.lowercased())
        let parse = SpotifyRequestParser.OllamaParse(intent: .search, kind: .track, title: "Mor ve ötesi Bir Derdim Var", artist: "Bir Derdim Var")
        XCTAssertEqual(SpotifyRequestParser.request(from: parse, transcript: text, rules: rules), rules)
    }

    func testDecodeOllamaResponse() {
        let parse = SpotifyRequestParser.decodeOllamaResponse(
            #"{"intent":"search","type":"artist","title":"","artist":"Sezen Aksu"}"#
        )
        XCTAssertEqual(parse, SpotifyRequestParser.OllamaParse(intent: .search, kind: .artist, title: "", artist: "Sezen Aksu"))
        XCTAssertNil(SpotifyRequestParser.decodeOllamaResponse("not json"))
        // The pre-intent schema must not decode as a command.
        XCTAssertNil(SpotifyRequestParser.decodeOllamaResponse(#"{"is_music_command":true,"type":"none","title":"","artist":""}"#))
    }
}
