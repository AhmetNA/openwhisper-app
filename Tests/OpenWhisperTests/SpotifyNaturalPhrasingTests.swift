import XCTest
@testable import OpenWhisper

/// Natural phrasing ("müziğin sesi çok kısık ya") through `SpotifyManager.decide`, with
/// hand-written Ollama answers. Volume (the system's) works any time; skipping, pausing
/// and mood searches only while Spotify is playing.
final class SpotifyNaturalPhrasingTests: XCTestCase {
    private typealias Parse = SpotifyRequestParser.OllamaParse

    private func decide(_ text: String, _ parse: Parse?, playing: Bool = true) -> SpotifyManager.ExplicitSpotifyIntent? {
        SpotifyManager.decide(
            rules: SpotifyManager.explicitIntent(in: text), parse: parse, text: text, spotifyPlaying: playing
        )
    }

    private let naturalCommands: [(String, SpotifyRequestParser.OllamaIntent, SpotifyManager.ExplicitSpotifyIntent)] = [
        ("Müziğin sesi çok kısık ya", .volumeUp, .adjustVolume(30)),
        ("Şarkının sesi biraz az", .volumeUp, .adjustVolume(10)),
        ("Müziğin sesi duyulmuyor", .volumeUp, .adjustVolume(20)),
        ("Müziği biraz aç", .volumeUp, .adjustVolume(10)),
        ("Müziğin sesini yükselt", .volumeUp, .adjustVolume(20)),
        ("muzigin sesi cok kisik", .volumeUp, .adjustVolume(30)),
        ("Müzik çok yüksek ya", .volumeDown, .adjustVolume(-30)),
        ("Şarkının sesini biraz kıs", .volumeDown, .adjustVolume(-10)),
        ("Müziğin sesi çok bağırıyor", .volumeDown, .adjustVolume(-30)),
        ("Müziği sonuna kadar aç", .volume, .setVolume(100)),
        ("Bu şarkıdan sıkıldım", .next, .next),
        ("Bu şarkı olmadı ya", .next, .next),
        ("Bir önceki şarkı daha iyiydi", .previous, .previous),
        ("Müziği bir sustur", .pause, .pause),
    ]

    func testNaturalCommandsWhileSpotifyPlays() {
        for (text, llm, expected) in naturalCommands {
            XCTAssertEqual(decide(text, Parse(intent: llm)), expected, text)
        }
    }

    private let volumeIntents: Set<SpotifyRequestParser.OllamaIntent> = [.volume, .volumeUp, .volumeDown]

    /// With no music on, skip/pause stay dictation; volume commands still work.
    func testOnlyVolumeWorksWhenSpotifyIsNotPlaying() {
        for (text, llm, expected) in naturalCommands where SpotifyManager.explicitIntent(in: text) == nil {
            if volumeIntents.contains(llm) {
                XCTAssertEqual(decide(text, Parse(intent: llm), playing: false), expected, text)
            } else {
                XCTAssertNil(decide(text, Parse(intent: llm), playing: false), text)
            }
        }
    }

    func testMentionsVolume() {
        XCTAssertTrue(SpotifyManager.mentionsVolume("Sesi biraz yükseltelim"))
        XCTAssertTrue(SpotifyManager.mentionsVolume("Müzik çok yüksek ya"))
        XCTAssertFalse(SpotifyManager.mentionsVolume("Bu şarkıdan sıkıldım"))
        // "sesim" is the speaker's own voice: never a candidate, so never sent to Ollama.
        XCTAssertFalse(SpotifyManager.isNaturalCandidate("Sesim bugün çok kısık"))
    }

    /// Whisper wrote "Sesi baya bir kız." for "sesi baya bi kıs".
    func testKizMishearingIsRepairedNextToVolume() {
        XCTAssertEqual(SpotifyManager.repairVolumeMishearing("Sesi baya bir kız."), "Sesi baya bir kıs.")
        XCTAssertEqual(SpotifyManager.repairVolumeMishearing("Spotify'da ses baya bir kız."), "Spotify'da ses baya bir kıs.")
        XCTAssertEqual(SpotifyManager.repairVolumeMishearing("Kız kardeşim geldi"), "Kız kardeşim geldi")
        let repaired = SpotifyManager.repairVolumeMishearing("Sesi baya bir kız.")
        XCTAssertEqual(decide(repaired, Parse(intent: .volumeDown), playing: false), .adjustVolume(-30))
        XCTAssertEqual(
            decide("Spotify'da ses baya bir kıs.", Parse(intent: .volumeDown), playing: false), .adjustVolume(-30)
        )
    }

    /// Whisper wrote "Ses fülle." for "sesi fulle".
    func testFulleMishearingIsRepairedNextToVolume() {
        XCTAssertEqual(SpotifyManager.repairVolumeMishearing("Ses fülle."), "Ses fulle.")
        XCTAssertEqual(SpotifyManager.repairVolumeMishearing("Müziğin sesini füll yap"), "Müziğin sesini full yap")
        XCTAssertEqual(SpotifyManager.repairVolumeMishearing("Fülle geldi"), "Fülle geldi")
        let repaired = SpotifyManager.repairVolumeMishearing("Ses fülle.")
        XCTAssertEqual(decide(repaired, Parse(intent: .volume), playing: false), .setVolume(100))
    }

    func testSesiBirazYukseltelimWithoutMusic() {
        XCTAssertEqual(decide("Sesi biraz yükseltelim.", Parse(intent: .volumeUp), playing: false), .adjustVolume(10))
    }

    func testMoodSearchFromNaturalPhrasing() {
        let parse = Parse(intent: .search, kind: .playlist, title: "sakin")
        guard case .search(let request)? = decide("Biraz sakin bir şeyler dinleyelim", parse) else {
            return XCTFail("expected a playlist search")
        }
        XCTAssertEqual(request.kind, .playlist)
        XCTAssertNil(decide("Biraz sakin bir şeyler dinleyelim", parse, playing: false))
    }

    func testOllamaMustAgree() {
        XCTAssertNil(decide("Müziğin sesi çok kısık ya", Parse(intent: .none)))
        XCTAssertNil(decide("Müziğin sesi çok kısık ya", nil))
    }

    func testDirectionNeedsItsOwnCue() {
        XCTAssertNil(decide("Müziğin sesi çok kısık ya", Parse(intent: .volumeDown)))
        XCTAssertNil(decide("Müzik çok yüksek ya", Parse(intent: .volumeUp)))
        // Natural-only intents need the transcript's own evidence too.
        XCTAssertNil(decide("Müziğin sesi çok kısık ya", Parse(intent: .next)))
        XCTAssertNil(decide("Bu şarkıdan sıkıldım", Parse(intent: .pause)))
    }

    func testNaturalPathNeverPlaysLikesOrReports() {
        XCTAssertNil(decide("Bu şarkı çok güzel", Parse(intent: .like)))
        XCTAssertNil(decide("Bu şarkı çok güzel", Parse(intent: .play)))
        XCTAssertNil(decide("Bu şarkı çok güzel", Parse(intent: .current)))
    }

    func testDictationStaysDictationEvenWhilePlaying() {
        let volumeUp = Parse(intent: .volumeUp)
        // Negation / quoting.
        XCTAssertNil(decide("Müziğin sesini aç demiyorum", volumeUp))
        XCTAssertNil(decide("Sesini biraz kıs dedim ona", Parse(intent: .volumeDown)))
        // "sesim" is the speaker's own voice, and no music word is present.
        XCTAssertNil(decide("Sesim bugün çok kısık", volumeUp))
        XCTAssertNil(decide("Kulağım patladı", Parse(intent: .volumeDown)))
        XCTAssertNil(decide("Bunu biraz aç", volumeUp))
        // Too long.
        XCTAssertNil(decide("Dün akşam konserde şarkının sesi çok kısıktı ve arkada hiç duyamadık", volumeUp))
    }

    func testNumberedVolumeIsNeverRelative() {
        XCTAssertEqual(decide("Müziğin sesini 40'a yükselt", Parse(intent: .volumeUp)), .setVolume(40))
        XCTAssertEqual(decide("Spotify'ın sesini 20'ye düşür", Parse(intent: .volumeDown)), .setVolume(20))
    }

    func testVolumeWithoutNumberNeverMutes() {
        XCTAssertNil(decide("Müziğin sesi çok kısık ya", Parse(intent: .volume)))
        XCTAssertNil(decide("Müziği sonuna kadar kıs", Parse(intent: .volume)))
        XCTAssertEqual(decide("Müziği sonuna kadar kıs", Parse(intent: .volumeDown)), .adjustVolume(-20))
    }

    /// Ollama may rescue "müziği biraz aç" from the rules' resume/search reading, but a
    /// plain "müziği aç" stays resume even if the model says louder.
    func testOverrideOfRuleResult() {
        XCTAssertEqual(decide("Müziği biraz aç", Parse(intent: .volumeUp), playing: false), .adjustVolume(10))
        XCTAssertEqual(decide("Müziği aç", Parse(intent: .volumeUp)), .play)
        // Broad natural cues never override a rules search: "geç" in a title stays a search.
        guard case .search? = decide("Spotify'da Geç Olmadan çal", Parse(intent: .next)) else {
            return XCTFail("expected the rules search to stand")
        }
    }

    func testVolumeStep() {
        XCTAssertEqual(SpotifyManager.volumeStep(in: "sesi biraz aç"), 10)
        XCTAssertEqual(SpotifyManager.volumeStep(in: "sesi bir tık aç"), 10)
        XCTAssertEqual(SpotifyManager.volumeStep(in: "sesi çok kısık"), 30)
        XCTAssertEqual(SpotifyManager.volumeStep(in: "sesi kısık"), 20)
    }

    func testSystemVolumeHelpers() {
        XCTAssertEqual(SystemVolume.clamped(120), 100)
        XCTAssertEqual(SystemVolume.clamped(-5), 0)
        XCTAssertEqual(SystemVolume.percent(0.456), 46)
        XCTAssertEqual(SystemVolume.changeMessage(from: 45, to: 75), "Ses %45 → %75")
        XCTAssertEqual(SystemVolume.changeMessage(from: 100, to: 100), "Ses zaten %100")
    }

    func testDecodesNewOllamaIntents() {
        XCTAssertEqual(
            SpotifyRequestParser.decodeOllamaResponse(#"{"intent":"volume_up","type":"none","title":"","artist":""}"#)?.intent,
            .volumeUp
        )
        XCTAssertEqual(
            SpotifyRequestParser.decodeOllamaResponse(#"{"intent":"volume_down","type":"none","title":"","artist":""}"#)?.intent,
            .volumeDown
        )
    }
}
