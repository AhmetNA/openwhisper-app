import XCTest
@testable import OpenWhisper

/// Rows of the `SpotifyManager.decide` table, with hand-written Ollama answers so they
/// don't depend on a running model.
final class SpotifyDecisionTests: XCTestCase {
    private typealias Parse = SpotifyRequestParser.OllamaParse

    private func decide(_ text: String, _ parse: Parse?) -> SpotifyManager.ExplicitSpotifyIntent? {
        SpotifyManager.decide(rules: SpotifyManager.explicitIntent(in: text), parse: parse, text: text)
    }

    func testWithoutOllamaTheRulesDecide() {
        XCTAssertEqual(decide("Müziği durdur", nil), .pause)
        XCTAssertNil(decide("Hadise Düm Tek Tek çal", nil))
    }

    func testVetoOnlyAppliesToBroadIntentsWithoutSpotifyAddress() {
        let none = Parse(intent: .none)
        XCTAssertNil(decide("Müziği durdur", none))
        XCTAssertEqual(decide("Spotify'ı durdur", none), .pause)
        // Narrow gates survive a veto: these used to be pasted as dictation under Gemma.
        XCTAssertEqual(decide("Müziğin sesini 50'ye indir", none), .setVolume(50))
        XCTAssertEqual(decide("Şu an hangi şarkı çalıyor", none), .currentTrack)
        XCTAssertEqual(decide("Çalan şarkıyı beğenilerime ekle", none), .likeCurrentTrack)
    }

    func testLikedSongsPlayTheUsersOwnCollection() {
        let strangersPlaylist = Parse(intent: .search, kind: .playlist, title: "beğendiğim şarkılar", artist: "")
        for text in ["Spotify'da beğendiğim şarkıları aç", "Beğendiğim şarkıları çal", "Beğenilen şarkıları çal",
                     "Sevdiğim şarkıları çal", "Beğendiklerimi çal", "beğenilerimin listesini aç",
                     "Beğendiğim şarkıları çalar mısın"] {
            XCTAssertEqual(decide(text, nil), .playLikedSongs, text)
            // The LLM's playlist search never wins: it found a stranger's "Beğenilen Şarkılarım".
            XCTAssertEqual(decide(text, strangersPlaylist), .playLikedSongs, text)
            XCTAssertEqual(decide(text, Parse(intent: .none)), .playLikedSongs, text)
        }
        XCTAssertEqual(decide("Çalan şarkıyı beğenilerime ekle", nil), .likeCurrentTrack)
        // Nothing named: Liked Songs. Only "devam et" resumes what was paused.
        for text in ["Şarkı aç", "Müzik çal", "Spotify'da müzik aç"] {
            XCTAssertEqual(decide(text, nil), .playLikedSongs, text)
            XCTAssertEqual(decide(text, Parse(intent: .play)), .playLikedSongs, text)
        }
        XCTAssertEqual(decide("Müziğe devam et", nil), .play)
        XCTAssertEqual(decide("Müziğe devam et", Parse(intent: .play)), .play)
        XCTAssertNil(SpotifyManager.explicitIntent(in: "Beğendiğim şarkıları arkadaşıma çaldım"))
        XCTAssertNotEqual(SpotifyManager.explicitIntent(in: "Tarkan'ın beğendiğim şarkısını çal"), .playLikedSongs)
    }

    func testLikedSongsNamesAreRecognizedInSearches() {
        XCTAssertTrue(SpotifyRequestParser.namesLikedSongs("Beğenilen Şarkılarım"))
        XCTAssertTrue(SpotifyRequestParser.namesLikedSongs("beğendiğim"  + " şarkılar"))
        XCTAssertTrue(SpotifyRequestParser.namesLikedSongs("Liked Songs"))
        XCTAssertFalse(SpotifyRequestParser.namesLikedSongs("sakin"))
        XCTAssertFalse(SpotifyRequestParser.namesLikedSongs("Türkçe Pop Hits"))
    }

    func testAgreementKeepsRulesIntent() {
        XCTAssertEqual(decide("Sonraki şarkıya geç", Parse(intent: .next)), .next)
        XCTAssertEqual(decide("Spotify'da sesi 30 yap", Parse(intent: .volume)), .setVolume(30))
    }

    func testUnevidencedOllamaIntentDoesNotOverrideRules() {
        // "play" needs nothing left to search for, so a named artist stays a search.
        guard case .search(let request)? = decide("Spotify'da Tarkan çal", Parse(intent: .play)) else {
            return XCTFail("expected a search")
        }
        XCTAssertEqual(request.freeText, "tarkan")
        XCTAssertEqual(decide("Müziği durdur", Parse(intent: .volume)), .pause)
    }

    func testSearchCarriesOllamaSplit() {
        let parse = Parse(intent: .search, kind: .track, title: "Şımarık", artist: "Tarkan")
        guard case .search(let request)? = decide("Spotify'da Tarkan'ın Şımarık şarkısını çal", parse) else {
            return XCTFail("expected a search")
        }
        XCTAssertEqual(request.kind, .track)
        XCTAssertEqual(request.displayText, "Tarkan — Şımarık")
    }

    func testPlaylistWithoutPlaylistWordsIsSearchedAsTrack() {
        let parse = Parse(intent: .search, kind: .playlist, title: "mor ve ötesi bir derdim var")
        guard case .search(let request)? = decide("Spotify'da mor ve ötesi bir derdim var çal", parse) else {
            return XCTFail("expected a search")
        }
        XCTAssertEqual(request.kind, .track)
        XCTAssertEqual(request.catalogType, .track)
    }

    func testOllamaMayPromoteShortGroundedPlayPhrase() {
        let parse = Parse(intent: .search, kind: .track, title: "Düm Tek Tek", artist: "Hadise")
        guard case .search(let request)? = decide("Hadise Düm Tek Tek çal", parse) else {
            return XCTFail("expected a promoted search")
        }
        XCTAssertEqual(request.displayText, "Hadise — Düm Tek Tek")
    }

    func testPromotionLimits() {
        let search = Parse(intent: .search, kind: .track, title: "Düm Tek Tek", artist: "Hadise")
        // Ungrounded names.
        XCTAssertNil(decide("Hadise düm tek tek çal", Parse(intent: .search, kind: .track, title: "Kuzu Kuzu", artist: "Tarkan")))
        // No names at all.
        XCTAssertNil(decide("Hadise düm tek tek çal", Parse(intent: .search)))
        // Not a search.
        XCTAssertNil(decide("Hadise düm tek tek çal", Parse(intent: .pause)))
        // "aç" and "koy" endings are never promotion candidates.
        XCTAssertNil(decide("Dosyayı aç", Parse(intent: .search, kind: .track, title: "Dosyayı")))
        XCTAssertNil(decide("Kitabı masaya koy", Parse(intent: .search, kind: .track, title: "Kitabı")))
        // A mood/playlist is never promoted.
        XCTAssertNil(decide("Çocuklar için bir ninni çal", Parse(intent: .search, kind: .playlist, title: "ninni")))
        // Too long, or quoting someone.
        XCTAssertNil(decide("Dün akşam arabada Hadise düm tek tek çal", search))
        XCTAssertNil(decide("Hadise düm tek tek çal dedi", search))
    }

    func testPromotionCandidateFilter() {
        XCTAssertTrue(SpotifyManager.isPromotionCandidate("Hadise Düm Tek Tek çal"))
        XCTAssertTrue(SpotifyManager.isPromotionCandidate("Coldplay Yellow çal lütfen"))
        XCTAssertFalse(SpotifyManager.isPromotionCandidate("çal"))
        XCTAssertFalse(SpotifyManager.isPromotionCandidate("Bateri çal"))
        XCTAssertFalse(SpotifyManager.isPromotionCandidate("Onun parasını çal"))
        XCTAssertFalse(SpotifyManager.isPromotionCandidate("Chrome'u aç"))
        XCTAssertFalse(SpotifyManager.isPromotionCandidate("Zili çal"))
        XCTAssertFalse(SpotifyManager.isPromotionCandidate("Komşunun kapısını çal"))
        XCTAssertFalse(SpotifyManager.isPromotionCandidate("Biraz gitar çal"))
        XCTAssertTrue(SpotifyManager.isPromotionCandidate("Paramore Misery Business çal"))
        XCTAssertFalse(SpotifyManager.isPromotionCandidate("Bugün toplantıda deploy işini konuştuk"))
    }
}

/// TEST-HATALARI 2026-09-27 #2: "Müziğe devam et" was pasted as dictation.
final class SpotifyResumeDecisionTests: XCTestCase {
    private typealias Parse = SpotifyRequestParser.OllamaParse

    private func decide(_ text: String, _ parse: Parse?, commandMode: Bool = false) -> SpotifyManager.ExplicitSpotifyIntent? {
        SpotifyManager.decide(rules: SpotifyManager.explicitIntent(in: text), parse: parse, text: text, commandMode: commandMode)
    }

    func testResumeWithMusicWordPlays() {
        for text in ["Müziğe devam et", "Şarkıya devam et lütfen", "Spotify'da kaldığı yerden devam et",
                     "Müziği sürdür", "müziğe devam ettir"] {
            XCTAssertEqual(SpotifyManager.explicitIntent(in: text), .play, text)
            XCTAssertEqual(decide(text, Parse(intent: .play)), .play, text)
            XCTAssertEqual(decide(text, Parse(intent: .play), commandMode: true), .play, text)
        }
    }

    func testResumeWithoutMusicWordStaysDictation() {
        for text in ["Toplantıya devam edelim", "Devam et", "Müziğe devam ettik dün akşam"] {
            XCTAssertNil(SpotifyManager.explicitIntent(in: text), text)
            XCTAssertNil(decide(text, Parse(intent: .play)), text)
        }
        XCTAssertNil(decide("Toplantıya devam edelim", Parse(intent: .play), commandMode: true))
    }
}
