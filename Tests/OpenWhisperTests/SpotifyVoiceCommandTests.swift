import XCTest
@testable import OpenWhisper

/// Voice-started sessions ("Jarvis"): real transcripts from the log, with gemma4's actual
/// answers, so a wake-word command isn't pasted into the frontmost app as dictation.
final class SpotifyVoiceCommandTests: XCTestCase {
    private typealias Parse = SpotifyRequestParser.OllamaParse
    private let moodParse = Parse(intent: .search, kind: .playlist, title: "eğlenceli bir şeyler", artist: "")

    private func decide(_ transcript: String, _ parse: Parse, commandMode: Bool) -> SpotifyManager.ExplicitSpotifyIntent? {
        let text = SpotifyManager.repairPlayVerbMishearing(transcript)
        return SpotifyManager.decide(
            rules: SpotifyManager.explicitIntent(in: text), parse: parse, text: text, commandMode: commandMode
        )
    }

    func testMoodRequestPlaysAPlaylistInCommandMode() {
        for transcript in ["Eğlenceli bir şeyler çal.", "Eğlenceli bir şeyler çalk."] {
            guard case .search(let request)? = decide(transcript, moodParse, commandMode: true) else {
                return XCTFail("expected a playlist search for '\(transcript)'")
            }
            XCTAssertEqual(request.kind, .playlist)
            XCTAssertTrue(SpotifyManager.isCommandCandidate(transcript))
        }
    }

    func testDictationKeepsTheStrictGate() {
        XCTAssertNil(decide("Eğlenceli bir şeyler çal.", moodParse, commandMode: false))
        XCTAssertNil(decide("Eğlenceli bir şeyler çalk.", moodParse, commandMode: false))
    }

    func testCommandModeStillNeedsEvidenceInTheWords() {
        // Ollama's label alone never plays music: no play verb, no search.
        XCTAssertNil(decide("Bu şarkıyı çok seviyorum", moodParse, commandMode: true))
        XCTAssertNil(decide("Yarın toplantı var", Parse(intent: .none), commandMode: true))
    }

    func testFutureAndHortativePlayVerbsCount() {
        // 25 Sep 2026: gemma4 answered a playlist search, but "açacağız" wasn't a play verb.
        let parse = Parse(intent: .search, kind: .playlist, title: "eğlenceli", artist: "")
        for transcript in ["Eğlenceli bir şeyler açacağız biraz.", "Biraz eğlenceli bir şeyler açalım", "Eğlenceli bir şeyler çalalım"] {
            guard case .search? = decide(transcript, parse, commandMode: true) else {
                return XCTFail("expected a search for '\(transcript)'")
            }
        }
    }

    func testMisheardPastAndConverbPlayVerbsCountInCommandMode() {
        // 26 Sep 2026: "aç" came out of Whisper as "açtık" / "açıp" and both were pasted.
        let cases: [(String, Parse)] = [
            ("Piyano tarzı bir şey açtık Spotify'da.", Parse(intent: .search, kind: .playlist, title: "Piyano", artist: "")),
            ("Piyano müziği açıp Spotify'da", Parse(intent: .search, kind: .playlist, title: "Piyano müziği", artist: ""))
        ]
        for (transcript, parse) in cases {
            guard case .search? = decide(transcript, parse, commandMode: true) else {
                return XCTFail("expected a search for '\(transcript)'")
            }
            XCTAssertNil(decide(transcript, parse, commandMode: false))
        }
        XCTAssertEqual(SpotifyManager.repairCommandVerbMishearing("Tarkan çaldık"), "Tarkan çal")
        XCTAssertEqual(SpotifyManager.repairCommandVerbMishearing("Kapı açık kaldı"), "Kapı açık kaldı")
        XCTAssertEqual(SpotifyManager.repairCommandVerbMishearing("Çalışıyor"), "Çalışıyor")
    }

    func testCommandVerbRepairCoversEveryControlVerb() {
        let repair = SpotifyManager.repairCommandVerbMishearing
        XCTAssertEqual(repair("Şarkıyı durdurdun"), "Şarkıyı durdur")
        XCTAssertEqual(repair("Müziği kapattık"), "Müziği kapat")
        XCTAssertEqual(repair("Sesi kıstık"), "Sesi kıs")
        XCTAssertEqual(repair("Şarkıyı geçtik"), "Şarkıyı geç")
        XCTAssertEqual(repair("spotfader dur"), "spotfader durdur")
        XCTAssertEqual(repair("Kutfaida şarkac."), "Kutfaida şarkı aç.")
        XCTAssertEqual(repair("Bir şarkı çağırsana"), "Bir şarkı çalsana")
        // Words that merely start like a verb stay as they are.
        XCTAssertEqual(repair("Müziğin sesi çok kısık"), "Müziğin sesi çok kısık")
        XCTAssertEqual(repair("Kısa bir durum"), "Kısa bir durum")
    }

    func testSpelledPercentBecomesDigits() {
        XCTAssertEqual(SpotifyManager.digitizeSpelledPercent("Sesi yüzde elli yap"), "Sesi yüzde 50 yap")
        XCTAssertEqual(SpotifyManager.digitizeSpelledPercent("Sesi yüzde yetmiş beşe çıkar"), "Sesi yüzde 75'e çıkar")
        XCTAssertEqual(SpotifyManager.digitizeSpelledPercent("sesi yüzde yüz."), "sesi yüzde 100.")
        XCTAssertEqual(SpotifyManager.digitizeSpelledPercent("yüzde biraz"), "yüzde biraz")
        let parse = Parse(intent: .volume)
        XCTAssertEqual(decide(SpotifyManager.repairCommandVerbMishearing("Sesi yüzde elli yap"), parse, commandMode: true), .setVolume(50))
    }

    func testVerblessSpotifyRequestSearchesInCommandMode() {
        // 26 Sep 2026: "Piyanosal bir şeyler Spotify'da." was pasted as dictation.
        let parse = Parse(intent: .search, kind: .playlist, title: "Piyanosal", artist: "")
        guard case .search? = decide("Piyanosal bir şeyler Spotify'da.", parse, commandMode: true) else {
            return XCTFail("expected a search")
        }
        XCTAssertNil(decide("Piyanosal bir şeyler Spotify'da.", parse, commandMode: false))
    }

    func testFirstSentenceCommandIsACandidate() {
        XCTAssertTrue(SpotifyManager.isCommandCandidate("Şarkıyı durdur."))
        XCTAssertEqual(decide("Şarkıyı durdur.", Parse(intent: .pause), commandMode: true), .pause)
    }

    func testCommandModeSkipsWithoutSpotifyPlayingCheck() {
        XCTAssertEqual(decide("Bu şarkıdan sıkıldım", Parse(intent: .next), commandMode: true), .next)
    }

    func testPlayVerbRepairOnlyTouchesTheClosingWord() {
        XCTAssertEqual(SpotifyManager.repairPlayVerbMishearing("Eğlenceli bir şeyler çalk."), "Eğlenceli bir şeyler çal.")
        XCTAssertEqual(SpotifyManager.repairPlayVerbMishearing("çalkala bunu"), "çalkala bunu")
        XCTAssertEqual(SpotifyManager.repairPlayVerbMishearing("Kod çalışıyor"), "Kod çalışıyor")
    }

    func testRepeatedWordHallucinationIsDetected() {
        XCTAssertTrue(AudioSegmentation.isRepetitionHallucination("Bu Bu Bu Bu Bu Bu"))
        XCTAssertFalse(AudioSegmentation.isRepetitionHallucination("Hayır hayır"))
        XCTAssertFalse(AudioSegmentation.isRepetitionHallucination("evet evet evet tamam"))
    }
}
